//
//  LooperTests.swift
//  Binder
//

import CBinder
import Testing

@testable import Binder

/// The registry and the local-object encoding, which need no driver.
///
/// The serving loop's ioctls cannot run here, but what goes wrong in a loop is
/// almost never the ioctl — it is answering the wrong command, or failing to
/// answer one the driver is waiting on. Those decisions live in
/// `action(for:)`, which needs a connection, so the parts reachable without one
/// are covered here and the rest is left to a device.
@Suite
struct LocalObjectTests {

    // MARK: - Registry

    @Test func registersAndFindsAnObject() {
        let registry = LocalObjectRegistry()
        let object = registry.register(interfaceDescriptor: "com.example.IThing") { _ in nil }

        #expect(registry.count == 1)
        #expect(registry.object(for: object.id) === object)
        #expect(object.interfaceDescriptor == "com.example.IThing")
    }

    /// Zero is a null binder on the wire, so no object may be given that id.
    @Test func idsStartAtOne() {
        let registry = LocalObjectRegistry()
        let first = registry.register(interfaceDescriptor: "a") { _ in nil }
        #expect(first.id == 1)
    }

    /// The driver keys its node on this value, so two live objects sharing one
    /// would send every transaction for either to whichever was registered
    /// second.
    @Test func idsAreUnique() {
        let registry = LocalObjectRegistry()
        let ids = (0 ..< 50).map { _ in
            registry.register(interfaceDescriptor: "a") { _ in nil }.id
        }
        #expect(Set(ids).count == ids.count)
    }

    @Test func withdrawnObjectsAreNotFound() {
        let registry = LocalObjectRegistry()
        let object = registry.register(interfaceDescriptor: "a") { _ in nil }
        registry.remove(object)

        #expect(registry.count == 0)
        #expect(registry.object(for: object.id) == nil)
    }

    /// Ids are not reused after a withdrawal. Reusing one would let a
    /// transaction already in flight for the old object arrive at a new one.
    @Test func idsAreNotReusedAfterWithdrawal() {
        let registry = LocalObjectRegistry()
        let first = registry.register(interfaceDescriptor: "a") { _ in nil }
        registry.remove(first)
        let second = registry.register(interfaceDescriptor: "a") { _ in nil }

        #expect(second.id != first.id)
    }

    /// The registry is reached from every serving thread at once.
    @Test func registrationIsSafeUnderConcurrency() async {
        let registry = LocalObjectRegistry()

        await withTaskGroup(of: UInt64.self) { group in
            for _ in 0 ..< 100 {
                group.addTask {
                    registry.register(interfaceDescriptor: "a") { _ in nil }.id
                }
            }
            var ids = Set<UInt64>()
            for await id in group { ids.insert(id) }
            #expect(ids.count == 100)
        }
        #expect(registry.count == 100)
    }

    // MARK: - Encoding

    /// BINDER_TYPE_BINDER is what tells the driver the object lives here: it
    /// creates a node and hands the receiver a handle pointing back. Writing
    /// BINDER_TYPE_HANDLE instead would claim to be forwarding a reference to
    /// somewhere else.
    @Test func localObjectsAreWrittenAsNodesNotHandles() {
        let registry = LocalObjectRegistry()
        let object = registry.register(interfaceDescriptor: "a") { _ in nil }

        var parcel = Parcel()
        parcel.append(object)

        #expect(parcel.objectOffsets == [0])
        #expect(parcel.count == MemoryLayout<flat_binder_object>.size)

        let flat = parcel.bytes.withUnsafeBytes {
            $0.loadUnaligned(as: flat_binder_object.self)
        }
        #expect(flat.hdr.type == BinderType.binder.rawValue)
        #expect(flat.binder == binder_uintptr_t(object.id))
        #expect(flat.cookie == binder_uintptr_t(object.id))
    }

    /// A hosted object is not a remote reference, so enumerating a parcel's
    /// remote objects must not turn one up — acquiring it would be meaningless.
    @Test func localObjectsAreNotRemoteObjects() {
        let registry = LocalObjectRegistry()
        let object = registry.register(interfaceDescriptor: "a") { _ in nil }

        var parcel = Parcel()
        parcel.append(object)

        #expect(parcel.objects.isEmpty)
    }

    // MARK: - Handlers

    @Test func handlerReceivesTheTransaction() throws {
        let registry = LocalObjectRegistry()
        var request = Parcel()
        request.append(Int32(7))

        let object = registry.register(interfaceDescriptor: "a") { transaction in
            #expect(transaction.code == 3)
            #expect(transaction.senderUserID == 1000)
            var reply = Parcel()
            reply.append(Int32(0))
            return reply
        }

        let transaction = LocalObject.Transaction(
            code: 3,
            request: request,
            flags: .acceptFds,
            senderProcessID: 42,
            senderUserID: 1000
        )
        let reply = try #require(try object.handler(transaction))

        var reader = reply.reader()
        #expect(try reader.readInt32() == 0)
    }

    /// The one thing the driver fills in that a caller cannot forge.
    @Test func senderIdentityComesFromTheDriver() {
        var data = binder_transaction_data()
        data.sender_pid = 1234
        data.sender_euid = 10056

        let transaction = LocalObject.Transaction(
            code: 1,
            request: Parcel(),
            flags: [],
            senderProcessID: data.sender_pid,
            senderUserID: data.sender_euid
        )
        #expect(transaction.senderProcessID == 1234)
        #expect(transaction.senderUserID == 10056)
    }

    // MARK: - Acknowledgement commands

    /// The driver blocks a node's reference transition until the matching
    /// *_DONE arrives, so these have to carry a binder_ptr_cookie and be sent.
    @Test(arguments: [DriverCommandProtocol.incRefsDone, .acquireDone])
    func acknowledgementsCarryAPointerAndCookie(_ command: DriverCommandProtocol) {
        #expect(command.payloadSize == MemoryLayout<binder_ptr_cookie>.size)

        var cookie = binder_ptr_cookie()
        cookie.ptr = 0x1111
        cookie.cookie = 0x2222

        var stream = CommandStream()
        stream.append(command, payload: cookie)
        #expect(stream.count == 4 + MemoryLayout<binder_ptr_cookie>.size)

        let decoded = Array(stream.bytes.dropFirst(4))
            .withUnsafeBytes { $0.loadUnaligned(as: binder_ptr_cookie.self) }
        #expect(decoded.ptr == 0x1111)
        #expect(decoded.cookie == 0x2222)
    }

    /// BR_INCREFS is answered by BC_INCREFS_DONE and BR_ACQUIRE by
    /// BC_ACQUIRE_DONE. Crossing them leaves the driver waiting on a transition
    /// that never completes.
    @Test func acknowledgementsPairWithTheirRequests() {
        #expect(DriverReturnProtocol.incRefs.payloadSize
                == DriverCommandProtocol.incRefsDone.payloadSize)
        #expect(DriverReturnProtocol.acquire.payloadSize
                == DriverCommandProtocol.acquireDone.payloadSize)
        #expect(DriverCommandProtocol.incRefsDone != DriverCommandProtocol.acquireDone)
    }

    // MARK: - Looper commands

    @Test func looperCommandsCarryNoPayload() {
        #expect(DriverCommandProtocol.enterLooper.payloadSize == 0)
        #expect(DriverCommandProtocol.exitLooper.payloadSize == 0)
        #expect(DriverCommandProtocol.registerLooper.payloadSize == 0)
    }

    /// A reply carries a full transaction structure, same as a request.
    @Test func replyCarriesATransactionStructure() {
        #expect(DriverCommandProtocol.reply.payloadSize
                == MemoryLayout<binder_transaction_data>.size)
    }
}
