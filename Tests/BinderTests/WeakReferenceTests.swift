//
//  WeakReferenceTests.swift
//  Binder
//

import CBinder
import Testing

@testable import Binder

@Suite
struct WeakReferenceTests {

    /// Weak and strong references travel as distinct commands. Crossing them
    /// would keep an object alive that should be collectable, or fail to keep
    /// one alive that a caller is relying on.
    @Test func weakAndStrongUseDistinctCommands() {
        #expect(DriverCommandProtocol.incRefs != DriverCommandProtocol.acquire)
        #expect(DriverCommandProtocol.decRefs != DriverCommandProtocol.release)
    }

    /// All four reference commands carry a bare handle.
    @Test(arguments: [
        DriverCommandProtocol.incRefs,
        .decRefs,
        .acquire,
        .release,
    ])
    func referenceCommandsCarryABareHandle(_ command: DriverCommandProtocol) {
        #expect(command.payloadSize == MemoryLayout<UInt32>.size)

        var stream = CommandStream()
        stream.append(command, payload: UInt32(11))
        let handle = Array(stream.bytes.dropFirst(4))
            .withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        #expect(handle == 11)
    }

    // MARK: - Extended error

    /// binder_extended_error is three 32-bit fields: an id, the failed BR_*
    /// command, and a status. If the layout drifted, a diagnostic read would
    /// report the wrong command for a failure.
    @Test func extendedErrorHasThreeWords() {
        #expect(MemoryLayout<ExtendedError>.size == 12)
        #expect(BinderCommand.getExtendedError.rawValue
                == numericCast(BINDER_GET_EXTENDED_ERROR))
    }

    /// The typed view of the failed-command field reads back the raw BR_* code.
    @Test func extendedErrorTypesTheFailedCommand() {
        var error = ExtendedError()
        error.command = BR_FAILED_REPLY.rawValue
        error.param = -22   // -EINVAL

        #expect(error.failedCommand == .failedReply)
        #expect(error.status == -22)
    }

    /// The initial state before any failure describes success, which is why
    /// the value is only meaningful straight after a failure on the same
    /// thread.
    @Test func extendedErrorDefaultsToSuccess() {
        let error = ExtendedError()
        #expect(error.status == 0)
    }
}
