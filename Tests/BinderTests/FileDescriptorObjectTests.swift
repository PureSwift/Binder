//
//  FileDescriptorObjectTests.swift
//  Binder
//

import CBinder
import SystemPackage
import Testing

@testable import Binder

@Suite
struct FileDescriptorObjectTests {

    /// A binder_fd_object shares the 24-byte envelope of a binder object, with
    /// the descriptor in the union at offset 8. If that shifted, the driver
    /// would translate the wrong word.
    @Test func fdObjectSharesTheObjectEnvelope() {
        #expect(MemoryLayout<binder_fd_object>.size
                == MemoryLayout<flat_binder_object>.size)
    }

    /// A descriptor is written at a declared offset, like any object, so the
    /// driver knows to dup it rather than pass the number through as data.
    @Test func writesADescriptorAsAnObject() {
        var parcel = Parcel()
        parcel.append(fileDescriptor: FileDescriptor(rawValue: 7))

        #expect(parcel.objectOffsets == [0])
        #expect(parcel.count == MemoryLayout<binder_fd_object>.size)

        let object = parcel.bytes.withUnsafeBytes {
            $0.loadUnaligned(as: binder_fd_object.self)
        }
        #expect(object.hdr.type == BinderType.fileDescriptor.rawValue)
        #expect(object.fd == 7)
    }

    @Test func roundTripsADescriptor() throws {
        var parcel = Parcel()
        parcel.append(fileDescriptor: FileDescriptor(rawValue: 42))

        var reader = parcel.reader()
        let fd = try reader.readFileDescriptor()
        #expect(fd?.rawValue == 42)
        #expect(reader.isAtEnd)
    }

    /// A descriptor is not a binder object reference, so enumerating a parcel's
    /// remote objects must not turn it up — acquiring it would be meaningless
    /// and freeing the reply would try to drop a reference that was never taken.
    @Test func fileDescriptorsAreNotRemoteObjects() {
        var parcel = Parcel()
        parcel.append(fileDescriptor: FileDescriptor(rawValue: 3))
        #expect(parcel.objects.isEmpty)
    }

    /// Reading an object as a descriptor, or the reverse, returns nil rather
    /// than a wrong answer — the header type is checked, not assumed.
    @Test func readFileDescriptorRejectsANonDescriptorObject() throws {
        var parcel = Parcel()
        parcel.append(RemoteObject(handle: 9))

        var reader = parcel.reader()
        #expect(try reader.readFileDescriptor() == nil)
    }

    @Test func readObjectRejectsADescriptor() throws {
        var parcel = Parcel()
        parcel.append(fileDescriptor: FileDescriptor(rawValue: 4))

        var reader = parcel.reader()
        #expect(try reader.readObject() == nil)
    }

    /// A negative descriptor round-trips unchanged: the union stores the raw
    /// bit pattern, and -1 is a legitimate "no descriptor" sentinel a sender
    /// may use.
    @Test func preservesTheDescriptorBitPattern() throws {
        var parcel = Parcel()
        parcel.append(fileDescriptor: FileDescriptor(rawValue: -1))

        var reader = parcel.reader()
        #expect(try reader.readFileDescriptor()?.rawValue == -1)
    }
}
