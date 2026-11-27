import Testing
import Binder

@Test func frameworkInterfaceTokenWireFormat() throws {
    var parcel = Parcel()
    try parcel.writeInterfaceToken("A😀")
    #expect(parcel.bytes == [
        0, 0, 0, 0x80, // StrictMode penalty gather
        0xFF, 0xFF, 0xFF, 0xFF, // No propagated WorkSource
        0x54, 0x53, 0x59, 0x53, // SYST header
        3, 0, 0, 0, 0x41, 0, 0x3D, 0xD8, 0, 0xDE, 0, 0,
    ])
    try parcel.setDataPosition(0)
    try parcel.enforceInterface("A😀")
    #expect(parcel.dataAvailable == 0)
    try parcel.setDataPosition(0)
    #expect(throws: ParcelError.interfaceMismatch(expected: "other", actual: "A😀")) {
        try parcel.enforceInterface("other")
    }
}

@Test func parcelStringFramingAndBounds() throws {
    var parcel = Parcel()
    try parcel.writeString16("AB")
    try parcel.writeString16(nil)
    parcel.writeInt64(-12)
    #expect(parcel.bytes.prefix(12).elementsEqual([2, 0, 0, 0, 65, 0, 66, 0, 0, 0, 0, 0]))
    try parcel.setDataPosition(0)
    #expect(try parcel.readString16() == "AB")
    #expect(try parcel.readString16() == nil)
    #expect(try parcel.readInt64() == -12)
    #expect(throws: ParcelError.truncated) { try parcel.readInt32() }

    var truncated = Parcel(bytes: [255, 255, 255, 127])
    #expect(throws: ParcelError.truncated) { try truncated.readString16() }
}

@Test func parcelReadsReplyHeadersAndServiceFailure() throws {
    var reply = Parcel()
    reply.writeInt32(-127)
    reply.writeInt32(8)
    reply.writeInt32(0)
    reply.writeInt32(-8)
    try reply.writeString16("failed")
    reply.writeInt32(0)
    reply.writeInt32(42)
    try reply.setDataPosition(0)
    #expect(throws: ParcelError.remoteException(code: -8, message: "failed", serviceCode: 42)) {
        try reply.readException()
    }
    #expect(reply.dataAvailable == 0)
}

@Test func localStubDispatchesStandardTransactions() async throws {
    let stub = BinderStub(descriptor: "demo.IExample")
    var reply = try await stub.transact(code: BinderConstants.interfaceTransaction, data: Parcel(), flags: [])
    #expect(try reply.readString16() == "demo.IExample")
    let ping = try await stub.transact(code: BinderConstants.pingTransaction, data: Parcel(), flags: [])
    #expect(ping.dataSize == 0)
    await #expect(throws: BinderTransactionError.unknownTransaction(42)) {
        try await stub.transact(code: 42, data: Parcel(), flags: [])
    }
}

@Test func localProxyAndStubRoundTrip() async throws {
    let stub = EchoStub()
    let proxy = EchoProxy(remote: stub)
    #expect(proxy.asBinder() === stub)
    #expect(try await proxy.echo(42) == 42)
}

private struct EchoProxy: BinderProxy {
    static let descriptor = "demo.IEcho"
    let remote: any IBinder

    func echo(_ value: Int32) async throws -> Int32 {
        var request = Parcel()
        try request.writeInterfaceToken(Self.descriptor)
        request.writeInt32(value)
        var reply = try await remote.transact(code: BinderConstants.firstCallTransaction, data: request, flags: [])
        try reply.readException()
        return try reply.readInt32()
    }
}

private final class EchoStub: BinderStub, @unchecked Sendable {
    init() {
        super.init(descriptor: EchoProxy.descriptor)
    }

    override func onTransact(
        code: UInt32, data: inout Parcel, reply: inout Parcel, flags: TransactionFlags
    ) async throws -> Bool {
        guard code == BinderConstants.firstCallTransaction else {
            return try await super.onTransact(code: code, data: &data, reply: &reply, flags: flags)
        }
        try data.enforceInterface(interfaceDescriptor)
        let value = try data.readInt32()
        reply.writeNoException()
        reply.writeInt32(value)
        return true
    }
}
