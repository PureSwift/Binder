//
//  DriverStreamTests.swift
//  Binder
//

import CBinder
import Testing

@testable import Binder

@Suite
struct DriverStreamTests {

    // MARK: - Payload sizes

    /// The size embedded in each command code must equal the structure it
    /// names. This is what lets the stream be walked without a hand-written
    /// table, so it is asserted against `MemoryLayout` rather than assumed.
    @Test func returnCommandSizesMatchTheirStructures() {
        #expect(DriverReturnProtocol.reply.payloadSize
                == MemoryLayout<binder_transaction_data>.size)
        #expect(DriverReturnProtocol.transaction.payloadSize
                == MemoryLayout<binder_transaction_data>.size)
        #expect(DriverReturnProtocol.incRefs.payloadSize
                == MemoryLayout<binder_ptr_cookie>.size)
        #expect(DriverReturnProtocol.deadBinder.payloadSize
                == MemoryLayout<binder_uintptr_t>.size)
        #expect(DriverReturnProtocol.error.payloadSize == MemoryLayout<Int32>.size)
    }

    @Test func commandsWithoutPayloadsReportZero() {
        #expect(DriverReturnProtocol.noop.payloadSize == 0)
        #expect(DriverReturnProtocol.transactionComplete.payloadSize == 0)
        #expect(DriverReturnProtocol.deadReply.payloadSize == 0)
        #expect(DriverReturnProtocol.failedReply.payloadSize == 0)
        #expect(DriverCommandProtocol.enterLooper.payloadSize == 0)
    }

    @Test func driverCommandSizesMatchTheirStructures() {
        #expect(DriverCommandProtocol.transaction.payloadSize
                == MemoryLayout<binder_transaction_data>.size)
        #expect(DriverCommandProtocol.freeBuffer.payloadSize
                == MemoryLayout<binder_uintptr_t>.size)
        #expect(DriverCommandProtocol.acquire.payloadSize == MemoryLayout<UInt32>.size)
    }

    // MARK: - Writing commands

    /// A command is a bare 32-bit code with no framing around it.
    @Test func appendsCommandCodeWithNoFraming() {
        var stream = CommandStream()
        stream.append(.enterLooper)
        #expect(stream.count == 4)
        #expect(stream.bytes == withUnsafeBytes(of: BC_ENTER_LOOPER.rawValue) { Array($0) })
    }

    /// The payload follows the code immediately: no padding, no length.
    @Test func appendsPayloadImmediatelyAfterTheCode() {
        var stream = CommandStream()
        let pointer = binder_uintptr_t(0xDEADBEEF)
        stream.append(.freeBuffer, payload: pointer)

        #expect(stream.count == 4 + MemoryLayout<binder_uintptr_t>.size)
        let code = stream.bytes.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        #expect(code == BC_FREE_BUFFER.rawValue)
        let value = Array(stream.bytes.dropFirst(4))
            .withUnsafeBytes { $0.loadUnaligned(as: binder_uintptr_t.self) }
        #expect(value == pointer)
    }

    @Test func packsSeveralCommandsBackToBack() {
        var stream = CommandStream()
        stream.append(.enterLooper)
        stream.append(.freeBuffer, payload: binder_uintptr_t(1))
        stream.append(.exitLooper)
        #expect(stream.count == 4 + (4 + 8) + 4)
    }

    // MARK: - Reading returns

    /// Build a driver-style stream by hand, the way the kernel would.
    private func encoded(_ commands: [(UInt32, [UInt8])]) -> [UInt8] {
        var bytes = [UInt8]()
        for (code, payload) in commands {
            withUnsafeBytes(of: code) { bytes.append(contentsOf: $0) }
            bytes.append(contentsOf: payload)
        }
        return bytes
    }

    /// The realistic shape: a reply is preceded by bookkeeping commands that
    /// have nothing to do with it.
    @Test func walksNoopAndCompleteBeforeAReply() throws {
        let reply = [UInt8](repeating: 0xAB, count: MemoryLayout<binder_transaction_data>.size)
        var stream = ReturnStream(bytes: encoded([
            (BR_NOOP.rawValue, []),
            (BR_TRANSACTION_COMPLETE.rawValue, []),
            (BR_REPLY.rawValue, reply),
        ]))

        let first = try stream.next()
        #expect(first?.command == .noop)
        #expect(first?.payload.isEmpty == true)

        let second = try stream.next()
        #expect(second?.command == .transactionComplete)

        let third = try stream.next()
        #expect(third?.command == .reply)
        #expect(third?.payload.count == MemoryLayout<binder_transaction_data>.size)

        #expect(stream.isAtEnd)
        #expect(try stream.next() == nil)
    }

    @Test func decodesAPayloadAsItsStructure() throws {
        var data = binder_transaction_data()
        data.code = 42
        data.flags = TransactionFlags.acceptFds.rawValue
        let payload = withUnsafeBytes(of: data) { Array($0) }

        var stream = ReturnStream(bytes: encoded([(BR_REPLY.rawValue, payload)]))
        let element = try #require(try stream.next())
        let decoded = try #require(element.decode(as: binder_transaction_data.self))

        #expect(decoded.code == 42)
        #expect(decoded.flags == TransactionFlags.acceptFds.rawValue)
    }

    @Test func decodeRejectsAMismatchedSize() throws {
        var stream = ReturnStream(bytes: encoded([(BR_ERROR.rawValue, [1, 0, 0, 0])]))
        let element = try #require(try stream.next())
        #expect(element.decode(as: Int32.self) == 1)
        #expect(element.decode(as: binder_transaction_data.self) == nil)
    }

    @Test func reportsTruncationPartWayThroughAPayload() {
        // BR_REPLY promises 64 bytes; supply 8.
        var stream = ReturnStream(bytes: encoded([
            (BR_REPLY.rawValue, [UInt8](repeating: 0, count: 8)),
        ]))
        #expect(throws: ReturnStreamError.truncated) { try stream.next() }
    }

    @Test func reportsTruncationPartWayThroughACode() {
        var stream = ReturnStream(bytes: [0x01, 0x02])
        #expect(throws: ReturnStreamError.truncated) { try stream.next() }
    }

    /// An unrecognised command has an unknown payload length, so the rest of
    /// the stream cannot be walked. Failing beats skipping and producing
    /// plausible nonsense from then on.
    @Test func refusesToGuessPastAnUnknownCommand() throws {
        var stream = ReturnStream(bytes: encoded([
            (BR_NOOP.rawValue, []),
            (0xDEAD_BEEF, []),
        ]))
        #expect(try stream.next()?.command == .noop)
        #expect(throws: ReturnStreamError.unknownCommand(0xDEAD_BEEF)) { try stream.next() }
    }

    @Test func emptyStreamYieldsNothing() throws {
        var stream = ReturnStream(bytes: [])
        #expect(stream.isAtEnd)
        #expect(try stream.next() == nil)
    }

    /// BR_TRANSACTION and BR_TRANSACTION_SEC_CTX share an ioctl number and are
    /// told apart only by the size of the structure they carry. If those ever
    /// collided, a security-context transaction would decode as a plain one.
    @Test func transactionAndSecCtxAreDistinctCodes() {
        #expect(DriverReturnProtocol.transaction != DriverReturnProtocol.transactionSecCtx)
        #expect(DriverReturnProtocol.transaction.payloadSize
                != DriverReturnProtocol.transactionSecCtx.payloadSize)
    }
}
