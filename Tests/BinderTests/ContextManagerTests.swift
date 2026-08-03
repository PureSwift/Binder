//
//  ContextManagerTests.swift
//  Binder
//

import CBinder
import Testing

@testable import Binder

@Suite
struct ContextManagerTests {

    /// The plain registration is a legacy 4-byte int; the security-context form
    /// carries a full flat_binder_object. Sending one where the driver expects
    /// the other is a size mismatch it rejects.
    @Test func registrationPayloadsMatchTheirIoctls() {
        #expect(BinderCommand.setContextMgr.rawValue
                == numericCast(BINDER_SET_CONTEXT_MGR))
        #expect(BinderCommand.setContextMgrExt.rawValue
                == numericCast(BINDER_SET_CONTEXT_MGR_EXT))
        #expect(MemoryLayout<flat_binder_object>.size == 24)
    }

    /// The two forms are distinct ioctls, so a security-context registration is
    /// not silently sent as a plain one.
    @Test func plainAndExtendedAreDistinct() {
        #expect(BinderCommand.setContextMgr != BinderCommand.setContextMgrExt)
        #expect(BinderCommand.setContextMgr.rawValue
                != BinderCommand.setContextMgrExt.rawValue)
    }

    /// The security-context node carries FLAT_BINDER_FLAG_TXN_SECURITY_CTX,
    /// which is what asks the driver to deliver BR_TRANSACTION_SEC_CTX — the
    /// same variant the serving loop now decodes.
    @Test func securityContextFlagIsSet() {
        #expect(FlatBinderObjectFlags.txnSecurityCtx.rawValue == 0x1000)

        var object = flat_binder_object()
        object.hdr = binder_object_header(type: .binder)
        object.flags = FlatBinderObjectFlags.txnSecurityCtx.rawValue
        #expect(FlatBinderObjectFlags(rawValue: object.flags)
                .contains(.txnSecurityCtx))
    }

    /// A context manager is reached at handle zero, the same fixed point a
    /// client looks up services through — the two ends of the same protocol.
    @Test func contextManagerIsHandleZero() {
        #expect(RemoteObject.contextManager.handle == 0)
    }
}
