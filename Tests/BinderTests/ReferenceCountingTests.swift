//
//  ReferenceCountingTests.swift
//  Binder
//

import CBinder
import Testing

@testable import Binder

/// The parts of reference counting that hold without a driver.
///
/// The commands themselves need a device, but what a reference count *depends*
/// on — that objects are found at declared offsets, that a reply's objects can
/// be enumerated, and that the acquire commands are encoded where the driver
/// expects them — is checkable here, and is where the mistakes are.
@Suite
struct ReferenceCountingTests {

    // MARK: - Offsets

    /// The driver rewrites handles only at positions the transaction names. An
    /// object written without its offset recorded crosses as plain data and
    /// arrives as a number addressing something else in the receiver.
    @Test func recordsAnObjectsOffset() {
        var parcel = Parcel()
        parcel.append(Int32(1))
        parcel.append(RemoteObject(handle: 9))

        #expect(parcel.objectOffsets == [4])
        #expect(parcel.count == 4 + MemoryLayout<flat_binder_object>.size)
    }

    @Test func recordsSeveralObjectsInWireOrder() {
        var parcel = Parcel()
        parcel.append("name")
        parcel.append(RemoteObject(handle: 1))
        parcel.append(Int32(0))
        parcel.append(RemoteObject(handle: 2))

        #expect(parcel.objectOffsets.count == 2)
        #expect(parcel.objectOffsets == parcel.objectOffsets.sorted())
        #expect(parcel.objects == [RemoteObject(handle: 1), RemoteObject(handle: 2)])
    }

    /// Plain data must not be mistaken for an object, however much it looks
    /// like one. Only declared offsets count.
    @Test func doesNotFindObjectsThatWereNotDeclared() {
        var parcel = Parcel()
        // The bit pattern of a real flat_binder_object, written as raw bytes.
        var object = flat_binder_object()
        object.hdr = binder_object_header(type: .handle)
        object.handle = 7
        parcel.append(bitPattern: object)

        #expect(parcel.objectOffsets.isEmpty)
        #expect(parcel.objects.isEmpty)
    }

    @Test func parcelsWithoutObjectsDeclareNoOffsets() {
        var parcel = Parcel()
        parcel.append(Int32(1))
        parcel.append("two")
        parcel.append(bytes: [3])
        #expect(parcel.objectOffsets.isEmpty)
        #expect(parcel.objects.isEmpty)
    }

    /// An offsets array from another process is not trusted: one naming a
    /// position that runs off the end must not send the object reader past it.
    @Test func ignoresOffsetsThatRunPastTheEnd() {
        let parcel = Parcel(bytes: [UInt8](repeating: 0, count: 8), objectOffsets: [4])
        #expect(parcel.objects.isEmpty)
    }

    @Test func ignoresNegativeOffsets() {
        let parcel = Parcel(
            bytes: [UInt8](repeating: 0, count: 64),
            objectOffsets: [-8]
        )
        #expect(parcel.objects.isEmpty)
    }

    // MARK: - Which objects hold references

    /// Only handles are references this process owns. A local binder pointer,
    /// a file descriptor or a buffer is not something to acquire — and taking
    /// the handle out of the union would produce a number addressing something
    /// unrelated.
    @Test(arguments: [BinderType.fileDescriptor, .fileDescriptorArray, .pointer, .binder])
    func doesNotTreatNonHandlesAsReferences(_ type: BinderType) {
        var object = flat_binder_object()
        object.hdr = binder_object_header(type: type)
        object.handle = 5

        var parcel = Parcel()
        parcel.recordObjectOffset()
        parcel.append(bitPattern: object)

        #expect(parcel.objects.isEmpty)
    }

    @Test(arguments: [BinderType.handle, .weakHandle])
    func treatsHandlesAsReferences(_ type: BinderType) {
        var object = flat_binder_object()
        object.hdr = binder_object_header(type: type)
        object.handle = 5

        var parcel = Parcel()
        parcel.recordObjectOffset()
        parcel.append(bitPattern: object)

        #expect(parcel.objects == [RemoteObject(handle: 5)])
    }

    // MARK: - Command encoding

    /// All four reference commands carry a bare handle, not a structure.
    @Test(arguments: [
        DriverCommandProtocol.acquire,
        .release,
        .incRefs,
        .decRefs,
    ])
    func referenceCommandsCarryABareHandle(_ command: DriverCommandProtocol) {
        #expect(command.payloadSize == MemoryLayout<UInt32>.size)

        var stream = CommandStream()
        stream.append(command, payload: UInt32(0x2A))
        #expect(stream.count == 4 + 4)

        let handle = Array(stream.bytes.dropFirst(4))
            .withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        #expect(handle == 0x2A)
    }

    /// Acquires must precede the free in the stream the driver consumes.
    ///
    /// The driver ties the reference it granted for each object to the buffer
    /// and drops it in `binder_transaction_buffer_release`, so a free that went
    /// first would leave every handle in the reply already dead — and reusable
    /// by the driver for a different object.
    @Test func acquiresAreOrderedBeforeTheFree() {
        var reply = Parcel()
        reply.append(RemoteObject(handle: 1))
        reply.append(RemoteObject(handle: 2))

        var stream = CommandStream()
        for object in reply.objects {
            stream.append(.acquire, payload: object.handle)
        }
        stream.append(.freeBuffer, payload: binder_uintptr_t(0xF00D))

        var offset = 0
        func nextCode() -> UInt32 {
            let code = Array(stream.bytes[offset ..< offset + 4])
                .withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            offset += 4
            return code
        }

        #expect(nextCode() == BC_ACQUIRE.rawValue)
        offset += DriverCommandProtocol.acquire.payloadSize
        #expect(nextCode() == BC_ACQUIRE.rawValue)
        offset += DriverCommandProtocol.acquire.payloadSize
        #expect(nextCode() == BC_FREE_BUFFER.rawValue)
    }

    // MARK: - addService

    /// Registration carries the object inline, so its offset has to be declared
    /// or the service manager receives a handle meaningless in its process.
    @Test func addServiceRequestDeclaresTheObjectsOffset() throws {
        var request = Parcel()
        request.appendInterfaceToken(ServiceManager.descriptor)
        request.append("example")
        request.append(RemoteObject(handle: 3))
        request.append(false)
        request.append(ServiceManager.DumpPriority.default.rawValue)

        #expect(request.objectOffsets.count == 1)
        #expect(request.objects == [RemoteObject(handle: 3)])

        var reader = request.reader()
        #expect(try reader.readInterfaceToken() == ServiceManager.descriptor)
        #expect(try reader.readString() == "example")
        #expect(try reader.readObject() == RemoteObject(handle: 3))
        #expect(try reader.readBool() == false)
        #expect(try reader.readInt32() == 0b1000)
        #expect(reader.isAtEnd)
    }
}
