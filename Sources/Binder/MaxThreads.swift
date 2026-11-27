//
//  MaxThreads.swift
//  Binder
//

import SystemPackage
import Socket
import CBinder

internal extension Binder {

    /// The `BINDER_SET_MAX_THREADS` payload.
    ///
    /// A plain `__u32` on the wire. It needs a type of its own only because the
    /// ioctl wrapper dispatches on `IOControlValue.id`, which is how the
    /// request number gets attached to the value being sent.
    struct MaxThreads {

        var value: UInt32

        init(_ value: UInt32) {
            self.value = value
        }
    }
}

extension Binder.MaxThreads: IOControlValue {

    static var id: BinderCommand { .setMaxThreads }

    mutating func withUnsafeMutablePointer<Result>(
        _ body: (UnsafeMutableRawPointer) throws -> (Result)
    ) rethrows -> Result {
        try Swift.withUnsafeMutableBytes(of: &self) { buffer in
            try body(buffer.baseAddress!)
        }
    }
}

public extension Binder {

    /// The thread-pool size libbinder requests, and therefore what services on
    /// the other end are provisioned to expect.
    ///
    /// This caps how many threads the *driver* will ask this process to spawn
    /// to service incoming transactions. It does not start any threads.
    static var defaultMaxThreads: UInt32 { 15 }

    /// Tell the driver how many threads it may ask this process to spawn.
    ///
    /// Raising it past what the process can actually service does not help:
    /// the driver will hand out work to threads that do not exist and callers
    /// will block. Lowering it below what a busy service needs serialises
    /// incoming transactions.
    func setMaxThreads(_ count: UInt32) throws(Errno) {
        try handle.setMaxThreads(count)
    }
}

internal extension Binder.Handle {

    func setMaxThreads(_ count: UInt32) throws(Errno) {
        var value = Binder.MaxThreads(count)
        #if ENABLE_MOCKING
        assert(type(of: value).id == .setMaxThreads)
        assert(type(of: value).id.rawValue == BINDER_SET_MAX_THREADS)
        #else
        try fileDescriptor.inputOutput(&value)
        #endif
    }
}
