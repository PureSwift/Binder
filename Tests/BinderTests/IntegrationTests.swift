//
//  IntegrationTests.swift
//  Binder
//

import CBinder
import SystemPackage
import Testing

@testable import Binder

/// Full request→reply round trips through the real encode and decode paths.
///
/// A binder parcel is host-order shared memory, not a network format, so a
/// request one side writes and the other reads is byte-for-byte what would
/// cross the kernel — the driver only copies those bytes and translates object
/// handles and offsets. That makes a same-process round trip a faithful test of
/// everything except the handle translation itself: the interface token, the
/// argument order, the reply's exception header, the object and buffer
/// encodings, and the way they compose.
///
/// The piecewise unit tests cover each of those alone. These cover them
/// together, which is where the integration bugs found while building this
/// library actually lived — a field written in the wrong order, an offset not
/// recorded, a reference dropped before it was read.
@Suite
struct IntegrationTests {

    // MARK: - Peers, written the way a real one would decode and reply

    /// Stands in for `servicemanager`: decodes a lookup and answers with an
    /// object or a null binder, exactly as the real one does.
    private func serviceManagerReply(
        to request: Parcel,
        registry: [String: UInt32]
    ) throws -> Parcel {
        var reader = request.reader()
        let descriptor = try reader.readInterfaceToken()
        #expect(descriptor == ServiceManager.descriptor)
        let name = try #require(try reader.readString())

        var reply = Parcel()
        reply.append(Int32(0))   // exception: none
        if let handle = registry[name] {
            reply.append(RemoteObject(handle: handle))
        } else {
            // A null binder: type is a binder, handle zero.
            var null = flat_binder_object()
            null.hdr = binder_object_header(type: .binder)
            reply.append(bitPattern: null)
        }
        return reply
    }

    // MARK: - Service manager lookup

    @Test func looksUpAServiceAndDecodesItsHandle() throws {
        // What lookUp(_:using:header:) builds for getService.
        var request = Parcel()
        request.appendInterfaceToken(ServiceManager.descriptor)
        request.append("activity")

        let reply = try serviceManagerReply(to: request, registry: ["activity": 42])

        var reader = reply.reader()
        #expect(try reader.readInt32() == 0)
        #expect(try reader.readObject() == RemoteObject(handle: 42))
    }

    @Test func absentServiceComesBackAsNull() throws {
        var request = Parcel()
        request.appendInterfaceToken(ServiceManager.descriptor)
        request.append("nonesuch")

        let reply = try serviceManagerReply(to: request, registry: [:])

        var reader = reply.reader()
        #expect(try reader.readInt32() == 0)
        // The null binder decodes as absence, not as handle zero.
        #expect(try reader.readObject() == nil)
    }

    // MARK: - An AIDL method with mixed arguments

    /// The shape of a real call: interface token, then arguments in declaration
    /// order, answered with an exception header and the return values. Every
    /// field is checked on the far side, so a mis-ordered write or a wrong
    /// width fails here rather than silently shifting everything after it.
    @Test func roundTripsAnAIDLMethod() throws {
        // Client encodes: setThing(int id, String name, boolean enabled, long ts)
        var request = Parcel()
        request.appendInterfaceToken("com.example.IThing")
        request.append(Int32(7))
        request.append("widget")
        request.append(true)
        request.append(Int64(1_700_000_000_000))

        // Service decodes in the same order.
        var reader = request.reader()
        #expect(try reader.readInterfaceToken() == "com.example.IThing")
        let id = try reader.readInt32()
        let name = try #require(try reader.readString())
        let enabled = try reader.readBool()
        let timestamp = try reader.readInt64()
        #expect(id == 7)
        #expect(name == "widget")
        #expect(enabled == true)
        #expect(timestamp == 1_700_000_000_000)
        #expect(reader.isAtEnd)

        // Service replies: no exception, then (String result, int code).
        var reply = Parcel()
        reply.append(Int32(0))
        reply.append("ok:\(name)")
        reply.append(id * 2)

        var replyReader = reply.reader()
        #expect(try replyReader.readInt32() == 0)
        #expect(try replyReader.readString() == "ok:widget")
        #expect(try replyReader.readInt32() == 14)
        #expect(replyReader.isAtEnd)
    }

    /// A thrown service-specific error: the reply's exception header is
    /// non-zero and the client stops before reading a return value that is not
    /// there.
    @Test func remoteExceptionIsSeenBeforeDecodingAResult() throws {
        var reply = Parcel()
        reply.append(Int32(-8))   // EX_SERVICE_SPECIFIC

        var reader = reply.reader()
        let exception = try reader.readInt32()
        #expect(exception != 0)
        // A client stops here; there is no return value to read.
    }

    // MARK: - A hosted object, through the real handler path

    /// Register a real `LocalObject`, build the request a client would send,
    /// and drive it through the object's own handler — the same closure the
    /// serving loop invokes — then decode the reply as the client would.
    @Test func dispatchesToAHostedObjectsHandler() throws {
        let registry = LocalObjectRegistry()
        let object = registry.register(interfaceDescriptor: "com.example.IEcho") { transaction in
            // Only a trusted caller, checked on driver-supplied identity.
            guard transaction.senderUserID == 1000 else {
                var denied = Parcel()
                denied.append(Int32(-1))   // EX_SECURITY
                return denied
            }
            var body = transaction.request.reader()
            _ = try? body.readInterfaceToken(header: .system)
            let message = (try? body.readString()) ?? nil

            var reply = Parcel()
            reply.append(Int32(0))
            reply.append("echo:\(message ?? "")")
            return reply
        }

        // Client side.
        var request = Parcel()
        request.appendInterfaceToken("com.example.IEcho")
        request.append("hello")

        // The loop builds this from binder_transaction_data; here it is built
        // directly with the driver-supplied identity a real transaction carries.
        let transaction = LocalObject.Transaction(
            code: 1,
            request: request,
            flags: .acceptFds,
            senderProcessID: 4321,
            senderUserID: 1000
        )
        let reply = try #require(try object.handler(transaction))

        var reader = reply.reader()
        #expect(try reader.readInt32() == 0)
        #expect(try reader.readString() == "echo:hello")
    }

    @Test func hostedObjectRejectsAnUntrustedCaller() throws {
        let registry = LocalObjectRegistry()
        let object = registry.register(interfaceDescriptor: "com.example.IEcho") { transaction in
            guard transaction.senderUserID == 1000 else {
                var denied = Parcel()
                denied.append(Int32(-1))
                return denied
            }
            return Parcel()
        }

        let transaction = LocalObject.Transaction(
            code: 1,
            request: Parcel(),
            flags: [],
            senderProcessID: 9,
            senderUserID: 2000   // not the trusted uid
        )
        let reply = try #require(try object.handler(transaction))

        var reader = reply.reader()
        #expect(try reader.readInt32() == -1)
    }

    // MARK: - A HIDL-shaped call carrying an out-of-line buffer

    /// A request with an inline header and a vector passed as a buffer, decoded
    /// the way a received parcel presents it: the payload captured out of band,
    /// read back through the buffer's offset.
    @Test func roundTripsAnOutOfLineBuffer() throws {
        var request = Parcel()
        request.appendInterfaceToken("android.hardware.foo@1.0::IFoo")
        request.append(Int32(3))                 // element count
        request.append(buffer: [10, 20, 30])     // the vector's bytes

        #expect(request.hasBuffers)
        #expect(request.buffersSize == 8)         // 3 bytes, aligned to 8

        // Reconstruct the parcel as copyReply hands it over: inline bytes and
        // offsets unchanged, each buffer's payload captured separately.
        let received = Parcel(
            bytes: request.bytes,
            objectOffsets: request.objectOffsets,
            scatterGatherBuffers: request.scatterGatherBuffers
        )

        var reader = received.reader()
        #expect(try reader.readInterfaceToken() == "android.hardware.foo@1.0::IFoo")
        #expect(try reader.readInt32() == 3)
        #expect(try reader.readBuffer(from: received) == [10, 20, 30])
        #expect(reader.isAtEnd)
    }

    // MARK: - Objects and descriptors crossing together

    /// A reply that returns both a binder and a file descriptor, at their own
    /// offsets, each decoded by the right reader and not mistaken for the other.
    @Test func roundTripsAnObjectAndADescriptorTogether() throws {
        var reply = Parcel()
        reply.append(Int32(0))
        reply.append(RemoteObject(handle: 5))
        reply.append(fileDescriptor: FileDescriptor(rawValue: 9))

        #expect(reply.objectOffsets.count == 2)
        // Only the binder is a reference to be acquired; the fd is not.
        #expect(reply.objects == [RemoteObject(handle: 5)])

        var reader = reply.reader()
        #expect(try reader.readInt32() == 0)
        #expect(try reader.readObject() == RemoteObject(handle: 5))
        #expect(try reader.readFileDescriptor()?.rawValue == 9)
        #expect(reader.isAtEnd)
    }

    // MARK: - Truncated reply

    /// A reply shorter than the interface promises fails at the first read past
    /// the end, rather than returning a plausible value — the case a version
    /// skew between the two sides produces.
    @Test func aShortReplyFailsRatherThanInventingData() throws {
        var reply = Parcel()
        reply.append(Int32(0))   // exception only; the promised string is missing

        var reader = reply.reader()
        #expect(try reader.readInt32() == 0)
        #expect(throws: ParcelError.endOfParcel) { try reader.readString() }
    }
}
