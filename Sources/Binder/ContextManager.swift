//
//  ContextManager.swift
//  Binder
//

import SystemPackage
import Socket
import CBinder

internal extension Binder {

    /// The `BINDER_SET_CONTEXT_MGR` payload — a legacy `__s32` the driver reads
    /// but does not use for anything a caller controls.
    struct SetContextManager {

        var value: Int32 = 0
    }
}

extension Binder.SetContextManager: IOControlValue {

    static var id: BinderCommand { .setContextMgr }

    mutating func withUnsafeMutablePointer<Result>(
        _ body: (UnsafeMutableRawPointer) throws -> (Result)
    ) rethrows -> Result {
        try Swift.withUnsafeMutableBytes(of: &self) { buffer in
            try body(buffer.baseAddress!)
        }
    }
}

extension flat_binder_object: @retroactive IOControlValue {

    /// Used only as the `BINDER_SET_CONTEXT_MGR_EXT` payload; the same structure
    /// travels inline in parcels, where it is not an ioctl value.
    public static var id: BinderCommand { .setContextMgrExt }

    public mutating func withUnsafeMutablePointer<Result>(
        _ body: (UnsafeMutableRawPointer) throws -> (Result)
    ) rethrows -> Result {
        try Swift.withUnsafeMutableBytes(of: &self) { buffer in
            try body(buffer.baseAddress!)
        }
    }
}

public extension BinderConnection {

    /// Register this process as the context manager — handle zero.
    ///
    /// There is exactly one context manager per binder context, and every other
    /// process reaches it at handle zero without being told where it is. Calling
    /// this makes *this* process that endpoint: transactions addressed to handle
    /// zero are delivered here, so a lookup service — a `servicemanager` — is
    /// built by becoming the context manager and then serving.
    ///
    /// It fails if a context manager already exists for this context, which is
    /// the usual case on a running Android system. Reserve it for a context you
    /// own: a fresh `binderfs` instance, or a container whose manager has not
    /// started.
    ///
    /// - Parameter securityContext: when true, ask the driver to deliver
    ///   incoming transactions as `BR_TRANSACTION_SEC_CTX` — carrying the
    ///   caller's SELinux context — via `BINDER_SET_CONTEXT_MGR_EXT`. A plain
    ///   registration is used otherwise, which is the widely compatible path.
    ///
    /// Nothing is delivered until a serving loop runs; see ``serve(while:)``.
    func becomeContextManager(securityContext: Bool = false) throws(BinderError) {
        if securityContext {
            var object = flat_binder_object()
            object.hdr = binder_object_header(type: .binder)
            // The manager registers its own node; the security-context flag is
            // what asks the driver for BR_TRANSACTION_SEC_CTX delivery.
            object.flags = FlatBinderObjectFlags.txnSecurityCtx.rawValue
            object.binder = 0
            object.cookie = 0
            #if ENABLE_MOCKING
            assert(type(of: object).id.rawValue == BINDER_SET_CONTEXT_MGR_EXT)
            #else
            do {
                try device.handle.fileDescriptor.inputOutput(&object)
            } catch {
                throw BinderError.system(error)
            }
            #endif
        } else {
            var value = Binder.SetContextManager()
            #if ENABLE_MOCKING
            assert(type(of: value).id.rawValue == BINDER_SET_CONTEXT_MGR)
            #else
            // do/catch inside the real branch: under mocking nothing throws, so
            // a catch would infer `any Error` rather than Errno.
            do {
                try device.handle.fileDescriptor.inputOutput(&value)
            } catch {
                throw BinderError.system(error)
            }
            #endif
        }
    }
}
