//
//  ReturnStream.swift
//  Binder
//

import CBinder

/// A cursor over the `BR_*` commands the driver wrote into the read buffer.
///
/// The driver answers a `BINDER_WRITE_READ` with a stream, not a result. A
/// single reply is routinely preceded by `BR_NOOP` and
/// `BR_TRANSACTION_COMPLETE`, and may be interleaved with reference-count
/// commands and `BR_SPAWN_LOOPER` that have nothing to do with the transaction
/// being waited on. So the caller cannot read "the answer" — it has to walk the
/// stream and decide which command ends its wait.
///
/// Unknown commands are a decode failure rather than something to step over: a
/// command this build does not recognise has an unknown payload length, so
/// there is no way to find where the next one starts. Guessing would turn one
/// unknown command into a stream of plausible nonsense.
public struct ReturnStream: Equatable, Hashable, Sendable {

    internal let bytes: [UInt8]

    /// The offset of the next command.
    public private(set) var offset: Int

    public init(bytes: [UInt8]) {
        self.bytes = bytes
        self.offset = 0
    }

    public var isAtEnd: Bool {
        offset >= bytes.count
    }
}

/// A `BR_*` command could not be decoded.
public enum ReturnStreamError: Error, Equatable, Hashable, Sendable {

    /// The stream ended part-way through a command or its payload.
    case truncated

    /// A command code this build does not know.
    ///
    /// Its payload length is unknown, so the rest of the stream cannot be
    /// walked. Usually means the driver is newer than these headers.
    case unknownCommand(UInt32)
}

public extension ReturnStream {

    /// One command and its payload bytes.
    ///
    /// Equatable but not Hashable: `command` is a C-imported `DriverReturnProtocol`,
    /// which is not Hashable on Swift 6.0.x, and nothing hashes an element.
    struct Element: Equatable, Sendable {

        public let command: DriverReturnProtocol

        /// The payload, empty for commands that carry none.
        public let payload: [UInt8]

        /// Decode the payload as the structure the command declares.
        ///
        /// The size is checked against the command code rather than trusted,
        /// and the load is unaligned because the payload sits at whatever
        /// offset the previous command left behind.
        public func decode<T>(as type: T.Type) -> T? {
            guard payload.count == MemoryLayout<T>.size else { return nil }
            return payload.withUnsafeBytes { $0.loadUnaligned(as: T.self) }
        }
    }

    /// Advance to the next command, or `nil` at the end of the stream.
    mutating func next() throws(ReturnStreamError) -> Element? {
        guard !isAtEnd else { return nil }

        let codeSize = MemoryLayout<UInt32>.size
        guard offset + codeSize <= bytes.count else {
            throw .truncated
        }

        let raw = bytes[offset ..< offset + codeSize]
            .withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        let command = DriverReturnProtocol(rawValue: raw)

        guard Self.isKnown(command) else {
            throw .unknownCommand(raw)
        }

        let size = command.payloadSize
        guard offset + codeSize + size <= bytes.count else {
            throw .truncated
        }

        let payload = Array(bytes[offset + codeSize ..< offset + codeSize + size])
        offset += codeSize + size
        return Element(command: command, payload: payload)
    }

    /// Whether this build recognises a return command.
    ///
    /// Enumerated rather than range-checked because the codes are `_IOC`
    /// values, not consecutive integers, and an unrecognised one cannot be
    /// skipped safely.
    private static func isKnown(_ command: DriverReturnProtocol) -> Bool {
        switch command {
        case .error, .ok, .transactionSecCtx, .transaction, .reply,
             .acquireResult, .deadReply, .transactionComplete, .incRefs,
             .acquire, .release, .decRefs, .attemptAcquire, .noop,
             .spawnLooper, .finished, .deadBinder,
             .clearDeathNotificationDone, .failedReply, .frozenReply,
             .onewaySpamSuspect, .transactionPendingFrozen:
            return true
        default:
            return false
        }
    }
}
