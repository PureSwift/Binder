/// Standard transaction codes shared by Binder endpoints and generated interfaces.
public enum BinderConstants {
    public static let firstCallTransaction: UInt32 = 1
    public static let lastCallTransaction: UInt32 = 0x00ff_ffff
    public static let pingTransaction: UInt32 = 0x5f50_4e47
    public static let interfaceTransaction: UInt32 = 0x5f4e_5446
}

/// An endpoint that can deliver transactions to an interface implementation.
public protocol IBinder: AnyObject, Sendable {
    func transact(code: UInt32, data: Parcel, flags: TransactionFlags) async throws -> Parcel
}

public protocol BinderInterface: Sendable {
    static var descriptor: String { get }

    func asBinder() -> any IBinder
}

public protocol BinderProxy: BinderInterface {
    var remote: any IBinder { get }
}

public extension BinderProxy {
    func asBinder() -> any IBinder { remote }
}

public protocol BinderParcelable: Sendable {
    init(from reader: inout Parcel.Reader) throws

    func write(to parcel: inout Parcel) throws
}

public enum BinderTransactionError: Error, Equatable, Sendable {
    case unknownTransaction(UInt32)
}

/// Base dispatch for local interface implementations and generated stubs.
/// Subclasses that store mutable state must synchronize access from concurrent transactions.
open class BinderStub: IBinder, @unchecked Sendable {
    public let interfaceDescriptor: String

    public init(descriptor: String) {
        self.interfaceDescriptor = descriptor
    }

    public final func transact(code: UInt32, data: Parcel, flags: TransactionFlags) async throws -> Parcel {
        var request = data.reader()
        var reply = Parcel()
        guard try await onTransact(code: code, data: &request, reply: &reply, flags: flags) else {
            throw BinderTransactionError.unknownTransaction(code)
        }
        if flags.contains(.oneWay) { return Parcel() }
        return reply
    }

    open func onTransact(
        code: UInt32, data: inout Parcel.Reader, reply: inout Parcel, flags: TransactionFlags
    ) async throws -> Bool {
        switch code {
        case BinderConstants.interfaceTransaction:
            reply.append(interfaceDescriptor)
        case BinderConstants.pingTransaction:
            break
        default:
            return false
        }
        return true
    }
}
