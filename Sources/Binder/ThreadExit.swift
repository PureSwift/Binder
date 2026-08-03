//
//  ThreadExit.swift
//  Binder
//

import SystemPackage
import Socket
import CBinder

internal extension Binder {

    /// The `BINDER_THREAD_EXIT` payload — a `__s32` the driver ignores.
    ///
    /// The command is thread-scoped with no argument of substance; the value
    /// exists because every ioctl needs one.
    struct ThreadExit {

        var value: Int32 = 0
    }
}

extension Binder.ThreadExit: IOControlValue {

    static var id: BinderCommand { .threadExit }

    mutating func withUnsafeMutablePointer<Result>(
        _ body: (UnsafeMutableRawPointer) throws -> (Result)
    ) rethrows -> Result {
        try Swift.withUnsafeMutableBytes(of: &self) { buffer in
            try body(buffer.baseAddress!)
        }
    }
}

public extension BinderConnection {

    /// Tell the driver the calling thread is done with binder.
    ///
    /// The kernel keeps a `binder_thread` for every thread that has ever
    /// issued an ioctl on the device, and frees it on this command or when the
    /// device closes. For threads whose exit this library controls that
    /// housekeeping is automatic — ``serve(while:)`` sends it as the loop
    /// unwinds. It is public for the case the library cannot see: a caller
    /// driving transactions from threads it manages itself, which would
    /// otherwise accumulate driver state that outlives each thread's useful
    /// life.
    ///
    /// Scoped to the calling thread. Calling it from a thread that then
    /// transacts again is harmless — the driver simply allocates fresh state —
    /// so a mistimed call costs a little memory churn rather than correctness.
    func exitThread() throws(BinderError) {
        var value = Binder.ThreadExit()
        do {
            #if ENABLE_MOCKING
            assert(type(of: value).id.rawValue == BINDER_THREAD_EXIT)
            #else
            try device.handle.fileDescriptor.inputOutput(&value)
            #endif
        } catch {
            throw BinderError.system(error)
        }
    }
}
