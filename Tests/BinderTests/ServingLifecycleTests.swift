//
//  ServingLifecycleTests.swift
//  Binder
//

import CBinder
import Testing

@testable import Binder

@Suite
struct ServingLifecycleTests {

    // MARK: - Registering a hosted object

    /// Publishing a hosted object writes it as a node, so the service manager
    /// receives a handle pointing back here rather than a forwarded reference.
    @Test func addServiceForALocalObjectSendsANode() throws {
        let registry = LocalObjectRegistry()
        let object = registry.register(interfaceDescriptor: "com.example.IThing") { _ in nil }

        var request = Parcel()
        request.appendInterfaceToken(ServiceManager.descriptor)
        request.append("example")
        request.append(object)
        request.append(false)
        request.append(ServiceManager.DumpPriority.default.rawValue)

        #expect(request.objectOffsets.count == 1)
        // A hosted object is a node, not a remote reference, so it must not
        // turn up as something to acquire.
        #expect(request.objects.isEmpty)

        let flat = request.bytes[request.objectOffsets[0]...]
            .withUnsafeBytes { $0.loadUnaligned(as: flat_binder_object.self) }
        #expect(flat.hdr.type == BinderType.binder.rawValue)
        #expect(flat.binder == binder_uintptr_t(object.id))
    }

    /// A forwarded reference is written as a handle, which is the difference
    /// that decides whether the driver keeps the node here or rewrites it.
    @Test func addServiceForARemoteObjectSendsAHandle() throws {
        var request = Parcel()
        request.appendInterfaceToken(ServiceManager.descriptor)
        request.append("example")
        request.append(RemoteObject(handle: 9))
        request.append(false)
        request.append(ServiceManager.DumpPriority.default.rawValue)

        #expect(request.objects == [RemoteObject(handle: 9)])
        let flat = request.bytes[request.objectOffsets[0]...]
            .withUnsafeBytes { $0.loadUnaligned(as: flat_binder_object.self) }
        #expect(flat.hdr.type == BinderType.handle.rawValue)
    }

    // MARK: - Thread exit

    @Test func threadExitIsAScopedCommand() {
        #expect(BinderCommand.threadExit.rawValue == numericCast(BINDER_THREAD_EXIT))
    }

    // MARK: - Security-context transactions

    /// binder_transaction_data_secctx is a plain transaction with a context
    /// pointer appended, and the transaction is at offset zero. If that layout
    /// changed, dispatching the prefix would read a shifted structure.
    @Test func secctxWrapsAPlainTransactionAtOffsetZero() {
        #expect(MemoryLayout<binder_transaction_data_secctx>.size
                == MemoryLayout<binder_transaction_data>.size
                 + MemoryLayout<binder_uintptr_t>.size)
        #expect(MemoryLayout.offset(of: \binder_transaction_data_secctx.transaction_data) == 0)
    }

    @Test func secctxAndPlainTransactionAreDistinctReturns() {
        #expect(DriverReturnProtocol.transaction != DriverReturnProtocol.transactionSecCtx)
        #expect(DriverReturnProtocol.transactionSecCtx.payloadSize
                == MemoryLayout<binder_transaction_data_secctx>.size)
        #expect(DriverReturnProtocol.transaction.payloadSize
                == MemoryLayout<binder_transaction_data>.size)
    }

    /// The prefix of a secctx structure decodes as the same transaction a plain
    /// BR_TRANSACTION would carry, which is what lets one dispatch path serve
    /// both.
    @Test func secctxPrefixDecodesAsThePlainTransaction() {
        var wrapped = binder_transaction_data_secctx()
        wrapped.transaction_data.code = 5
        wrapped.transaction_data.sender_pid = 4321
        wrapped.transaction_data.sender_euid = 10099
        wrapped.secctx = 0xDEAD_BEEF

        let bytes = withUnsafeBytes(of: wrapped) { Array($0) }
        let prefix = bytes.prefix(MemoryLayout<binder_transaction_data>.size)
            .withUnsafeBytes { $0.loadUnaligned(as: binder_transaction_data.self) }

        #expect(prefix.code == 5)
        #expect(prefix.sender_pid == 4321)
        #expect(prefix.sender_euid == 10099)
    }
}
