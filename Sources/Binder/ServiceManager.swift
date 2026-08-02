//
//  ServiceManager.swift
//  Binder
//

/// The context manager: the one object whose handle every process knows.
///
/// Bootstrapping binder requires exactly one fixed point, because looking up a
/// service means transacting with something, and the only handle a fresh
/// process has is zero. Everything else in the system is reached by asking this
/// object for it.
public enum ServiceManager {

    /// The interface descriptor every request to it must carry.
    public static var descriptor: String { "android.os.IServiceManager" }

    /// Transaction codes, offset from `FIRST_CALL_TRANSACTION`.
    ///
    /// Positional: they are the declaration order of the methods in
    /// `IServiceManager.aidl`, not values anyone chose. Inserting a method
    /// upstream would renumber everything after it, which is why AIDL forbids
    /// reordering rather than treating these as stable identifiers.
    public enum Transaction: UInt32, Equatable, Hashable, Sendable, CaseIterable {

        /// Blocks for up to five seconds waiting for the service to appear.
        case getService = 1

        /// Returns immediately, null if the service is not registered.
        case checkService = 2

        case addService = 3

        case listServices = 4
    }

    /// Which services `listServices` should report.
    ///
    /// A bitmask of dump priorities. Services register with one, and the
    /// listing is filtered by it — asking for the wrong priority returns a
    /// short list rather than an error, which reads as "the service is
    /// missing" and sends people looking in the wrong place.
    public struct DumpPriority: OptionSet, Equatable, Hashable, Sendable {

        public let rawValue: Int32

        public init(rawValue: Int32) {
            self.rawValue = rawValue
        }

        public static var critical: DumpPriority { DumpPriority(rawValue: 1 << 0) }
        public static var high: DumpPriority { DumpPriority(rawValue: 1 << 1) }
        public static var normal: DumpPriority { DumpPriority(rawValue: 1 << 2) }
        public static var `default`: DumpPriority { DumpPriority(rawValue: 1 << 3) }

        /// Every priority. What `listServices` uses when not told otherwise.
        public static var all: DumpPriority { [.critical, .high, .normal, .default] }
    }
}

public extension BinderConnection {

    /// Look up a service, waiting for it to appear.
    ///
    /// Blocks in the *server* for up to five seconds if the service is not yet
    /// registered — a deliberate part of the protocol, not a timeout of ours.
    /// Prefer ``checkService(named:header:)`` when the caller can handle
    /// absence itself, since a stall here is indistinguishable from a hung
    /// service manager.
    ///
    /// - Returns: the service, or `nil` if it never appeared.
    func service(
        named name: String,
        header: RPCHeader = .system
    ) throws(BinderError) -> RemoteObject? {
        try lookUp(name, using: .getService, header: header)
    }

    /// Look up a service without waiting.
    ///
    /// - Returns: the service, or `nil` if it is not currently registered.
    func checkService(
        named name: String,
        header: RPCHeader = .system
    ) throws(BinderError) -> RemoteObject? {
        try lookUp(name, using: .checkService, header: header)
    }

    private func lookUp(
        _ name: String,
        using transaction: ServiceManager.Transaction,
        header: RPCHeader
    ) throws(BinderError) -> RemoteObject? {
        var request = Parcel()
        request.appendInterfaceToken(ServiceManager.descriptor, header: header)
        request.append(name)

        let reply = try transact(
            handle: RemoteObject.contextManager.handle,
            code: transaction.rawValue,
            request: request
        )

        var reader = reply.reader()

        // Every AIDL reply opens with an exception code. A non-zero value means
        // the callee threw, and the rest of the parcel describes that rather
        // than holding the declared return value — so it is checked before
        // anything else is decoded.
        let exception: Int32
        do {
            exception = try reader.readInt32()
        } catch {
            throw BinderError.parcel(error)
        }
        guard exception == 0 else {
            throw BinderError.remoteException(exception)
        }

        do {
            return try reader.readObject()
        } catch {
            throw BinderError.parcel(error)
        }
    }

    /// Register a service under a name.
    ///
    /// - Note: not usable yet. A registration has to carry the object being
    ///   registered as a `flat_binder_object`, and the driver only translates
    ///   one if the parcel declares its offset — which ``Parcel`` does not
    ///   track. The encoding is correct; the transaction will be rejected.
    ///   See ``BinderError/objectOffsetsUnsupported``.
    func addService(
        named name: String,
        object: RemoteObject,
        allowIsolated: Bool = false,
        dumpPriority: ServiceManager.DumpPriority = .default,
        header: RPCHeader = .system
    ) throws(BinderError) -> Never {
        throw BinderError.objectOffsetsUnsupported
    }

    /// List the names of every registered service.
    ///
    /// - Parameter priority: which registrations to report. Defaults to all of
    ///   them; narrowing it silently shortens the list.
    func services(
        priority: ServiceManager.DumpPriority = .all,
        header: RPCHeader = .system
    ) throws(BinderError) -> [String] {
        var request = Parcel()
        request.appendInterfaceToken(ServiceManager.descriptor, header: header)
        request.append(priority.rawValue)

        let reply = try transact(
            handle: RemoteObject.contextManager.handle,
            code: ServiceManager.Transaction.listServices.rawValue,
            request: request
        )

        var reader = reply.reader()

        let exception: Int32
        do {
            exception = try reader.readInt32()
        } catch {
            throw BinderError.parcel(error)
        }
        guard exception == 0 else {
            throw BinderError.remoteException(exception)
        }

        do {
            let count = try reader.readInt32()
            // A null list is -1 and is not the same as an empty one, though
            // both mean "nothing to report" here.
            guard count > 0 else { return [] }

            var names = [String]()
            names.reserveCapacity(Int(count))
            for _ in 0 ..< count {
                if let name = try reader.readString() {
                    names.append(name)
                }
            }
            return names
        } catch {
            throw BinderError.parcel(error)
        }
    }
}
