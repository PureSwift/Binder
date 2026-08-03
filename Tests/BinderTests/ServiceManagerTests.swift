//
//  ServiceManagerTests.swift
//  Binder
//

import CBinder
import Testing

@testable import Binder

@Suite
struct ServiceManagerTests {

    // MARK: - RPC header

    /// The receiver compares this value and rejects the whole transaction on a
    /// mismatch, so the packing is pinned here rather than trusted.
    @Test func packsHeaderMarkersAsFourCharacters() {
        #expect(RPCHeader.system.value == 0x5359_5354)    // 'S','Y','S','T'
        #expect(RPCHeader.vendor.value == 0x564E_4452)    // 'V','N','D','R'
        #expect(RPCHeader.recovery.value == 0x5245_434F)  // 'R','E','C','O'
        #expect(RPCHeader.unknown.value == 0x554E_4B4E)   // 'U','N','K','N'
    }

    /// A client driving Android services wants SYST. An off-Android libbinder
    /// build would send UNKN, which those services reject — the distinction is
    /// the whole reason this is configurable.
    @Test func headersAreAllDistinct() {
        let values = Set(RPCHeader.allCases.map(\.value))
        #expect(values.count == RPCHeader.allCases.count)
    }

    // MARK: - Interface token

    /// Four fields in a fixed order before the descriptor. Getting the count
    /// wrong shifts every argument and the callee rejects the request before
    /// looking at them.
    @Test func writesTokenFieldsInOrder() throws {
        var parcel = Parcel()
        parcel.appendInterfaceToken("android.os.IServiceManager")

        var reader = parcel.reader()
        #expect(try reader.readInt32() == Parcel.strictModePenaltyGather)
        #expect(try reader.readInt32() == Parcel.unsetWorkSource)
        #expect(try reader.readInt32() == RPCHeader.system.value)
        #expect(try reader.readString() == "android.os.IServiceManager")
        #expect(reader.isAtEnd)
    }

    /// STRICT_MODE_PENALTY_GATHER is 1 << 31, which is negative in the Int32
    /// the parcel carries. Writing it as a UInt32 would be a different value.
    @Test func strictModeGatherIsTheSignBit() {
        #expect(Parcel.strictModePenaltyGather == Int32.min)
        #expect(Parcel.unsetWorkSource == -1)
    }

    @Test func orsTheCallersStrictModePolicyIntoTheFlag() throws {
        var parcel = Parcel()
        parcel.appendInterfaceToken("x", strictModePolicy: 0x11)

        var reader = parcel.reader()
        #expect(try reader.readInt32() == (0x11 | Int32.min))
    }

    @Test func roundTripsAToken() throws {
        var parcel = Parcel()
        parcel.appendInterfaceToken("android.os.IServiceManager")

        var reader = parcel.reader()
        #expect(try reader.readInterfaceToken() == "android.os.IServiceManager")
    }

    /// A mismatched marker is reported distinctly, because it means the two
    /// sides were built against different binder configurations rather than
    /// that the parcel is corrupt.
    @Test func rejectsAMismatchedMarker() {
        var parcel = Parcel()
        parcel.appendInterfaceToken("x", header: .vendor)

        var reader = parcel.reader()
        #expect(throws: ParcelError.interfaceMismatch(
            expected: RPCHeader.system.value,
            found: RPCHeader.vendor.value
        )) {
            try reader.readInterfaceToken(header: .system)
        }
    }

    // MARK: - Transaction codes

    /// Positional, from the declaration order in IServiceManager.aidl. Not
    /// values anyone chose, and not stable under reordering upstream.
    @Test func transactionCodesMatchTheAIDLOrder() {
        #expect(ServiceManager.Transaction.getService.rawValue == 1)
        #expect(ServiceManager.Transaction.checkService.rawValue == 2)
        #expect(ServiceManager.Transaction.addService.rawValue == 3)
        #expect(ServiceManager.Transaction.listServices.rawValue == 4)
    }

    @Test func descriptorIsTheAIDLInterfaceName() {
        #expect(ServiceManager.descriptor == "android.os.IServiceManager")
    }

    @Test func contextManagerIsHandleZero() {
        #expect(RemoteObject.contextManager.handle == 0)
    }

    // MARK: - Dump priorities

    @Test func dumpPriorityAllCoversEveryFlag() {
        #expect(ServiceManager.DumpPriority.all.rawValue == 0b1111)
        #expect(ServiceManager.DumpPriority.all.contains(.critical))
        #expect(ServiceManager.DumpPriority.all.contains(.high))
        #expect(ServiceManager.DumpPriority.all.contains(.normal))
        #expect(ServiceManager.DumpPriority.all.contains(.default))
    }

    // MARK: - Remote objects

    /// A flat_binder_object is 24 bytes and is not length-prefixed, so the
    /// reader has to know the size exactly.
    @Test func remoteObjectIsAFlatBinderObject() throws {
        var parcel = Parcel()
        parcel.append(RemoteObject(handle: 42))
        #expect(parcel.count == MemoryLayout<flat_binder_object>.size)

        var reader = parcel.reader()
        #expect(try reader.readObject() == RemoteObject(handle: 42))
        #expect(reader.isAtEnd)
    }

    /// A null binder is how the service manager says "no such service", so it
    /// has to decode as absence rather than as handle zero — which is the
    /// context manager and very much a real object.
    @Test func readsANullBinderAsAbsent() throws {
        var object = flat_binder_object()
        object.hdr = binder_object_header(type: .binder)
        object.binder = 0
        object.cookie = 0

        var parcel = Parcel()
        parcel.append(bitPattern: object)

        var reader = parcel.reader()
        #expect(try reader.readObject() == nil)
    }

    @Test func readsAFileDescriptorObjectAsNotARemoteObject() throws {
        var object = flat_binder_object()
        object.hdr = binder_object_header(type: .fileDescriptor)
        object.handle = 3

        var parcel = Parcel()
        parcel.append(bitPattern: object)

        var reader = parcel.reader()
        #expect(try reader.readObject() == nil)
    }

    // MARK: - Whole requests

    /// The exact bytes a getService call puts on the wire.
    @Test func encodesAGetServiceRequest() throws {
        var request = Parcel()
        request.appendInterfaceToken(ServiceManager.descriptor)
        request.append("activity")

        var reader = request.reader()
        #expect(try reader.readInterfaceToken() == "android.os.IServiceManager")
        #expect(try reader.readString() == "activity")
        #expect(reader.isAtEnd)
    }

    @Test func encodesAListServicesRequest() throws {
        var request = Parcel()
        request.appendInterfaceToken(ServiceManager.descriptor)
        request.append(ServiceManager.DumpPriority.all.rawValue)

        var reader = request.reader()
        #expect(try reader.readInterfaceToken() == "android.os.IServiceManager")
        #expect(try reader.readInt32() == 0b1111)
        #expect(reader.isAtEnd)
    }

    /// The reply shape both lookups decode: exception code, then the object.
    @Test func decodesAGetServiceReply() throws {
        var reply = Parcel()
        reply.append(Int32(0))
        reply.append(RemoteObject(handle: 7))

        var reader = reply.reader()
        #expect(try reader.readInt32() == 0)
        #expect(try reader.readObject() == RemoteObject(handle: 7))
    }

    @Test func decodesAListServicesReply() throws {
        var reply = Parcel()
        reply.append(Int32(0))
        reply.append(Int32(2))
        reply.append("activity")
        reply.append("package")

        var reader = reply.reader()
        #expect(try reader.readInt32() == 0)
        let count = try reader.readInt32()
        #expect(count == 2)
        var names = [String]()
        for _ in 0 ..< count {
            if let name = try reader.readString() { names.append(name) }
        }
        #expect(names == ["activity", "package"])
        #expect(reader.isAtEnd)
    }
}
