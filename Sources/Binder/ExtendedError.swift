//
//  ExtendedError.swift
//  Binder
//

import SystemPackage
import Socket
import CBinder

/// The driver's own account of why the last transaction on this thread failed.
///
/// A failed transaction surfaces as `BR_FAILED_REPLY` — a bare command with no
/// detail. The reason lives in per-thread state the driver keeps, and this ioctl
/// reads it: the command that failed, and a status the driver would otherwise
/// only have logged. It is the difference between "the transaction failed" and
/// "the transaction failed because the parcel was too large for the receiver's
/// buffer".
///
/// Thread-scoped, and it reports the *most recent* failure on the calling
/// thread. Read it on the same thread that saw the failure, before doing
/// anything else that transacts, or it describes a later call instead.
public typealias ExtendedError = binder_extended_error

extension ExtendedError: @retroactive IOControlValue {

    public static var id: BinderCommand { .getExtendedError }

    public mutating func withUnsafeMutablePointer<Result>(
        _ body: (UnsafeMutableRawPointer) throws -> (Result)
    ) rethrows -> Result {
        try Swift.withUnsafeMutableBytes(of: &self) { buffer in
            try body(buffer.baseAddress!)
        }
    }
}

public extension ExtendedError {

    /// The command whose failure this describes, as a `BR_*` return code.
    ///
    /// The stored `command` field is the raw `__u32`; this is the typed view of
    /// it.
    var failedCommand: DriverReturnProtocol {
        DriverReturnProtocol(rawValue: command)
    }

    /// The driver's status for the failure. Interpreted as a `binder_status_t`,
    /// most values are negated errnos; see ``BinderError``.
    var status: Int32 {
        param
    }
}

public extension BinderConnection {

    /// Ask the driver why the last transaction on this thread failed.
    ///
    /// Meaningful only straight after a failure, on the thread that saw it. The
    /// initial state before any failure reports success, so a value read out of
    /// order is misleading rather than merely stale.
    func lastError() throws(BinderError) -> ExtendedError {
        var value = ExtendedError()
        do {
            #if ENABLE_MOCKING
            assert(type(of: value).id.rawValue == BINDER_GET_EXTENDED_ERROR)
            #else
            try device.handle.fileDescriptor.inputOutput(&value)
            #endif
        } catch {
            throw BinderError.system(error)
        }
        return value
    }
}
