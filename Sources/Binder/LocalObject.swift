//
//  LocalObject.swift
//  Binder
//

import Synchronization
import CBinder

/// An object this process hosts, which other processes can call.
///
/// The mirror of ``RemoteProxy``. A proxy is a reference to something living
/// elsewhere; this is the something, seen from the side that implements it.
///
/// Identity is a number, not a pointer. The driver keys its node on the
/// `binder` field of the `flat_binder_object` that first introduced the object,
/// and hands that value back on every incoming transaction. libbinder puts a
/// real object pointer there; this uses an opaque id and a registry instead,
/// because a raw pointer into a Swift heap object would have to outlive
/// whatever ARC decided, and a transaction arriving after that is a use of
/// freed memory rather than a lookup that fails.
public final class LocalObject: Sendable {

    /// An incoming call.
    public struct Transaction: Sendable {

        /// The interface-defined transaction code.
        public let code: UInt32

        /// The caller's arguments.
        public let request: Parcel

        /// Flags the caller sent. `oneWay` means no reply is expected, and any
        /// parcel returned from the handler is discarded.
        public let flags: TransactionFlags

        /// The calling process, as the *driver* reports it.
        ///
        /// Not attacker-controlled: the kernel fills these in, so they are the
        /// only trustworthy thing in an incoming transaction and the right
        /// basis for a permission check. Everything in ``request`` is whatever
        /// the caller chose to write.
        public let senderProcessID: Int32

        /// The calling process's effective uid, as the driver reports it.
        public let senderUserID: UInt32
    }

    /// Handles an incoming call.
    ///
    /// Returning `nil` replies with an empty parcel. Throwing reports the error
    /// to the caller as a failed transaction rather than unwinding into the
    /// serving loop, which has no way to report it and could not continue.
    public typealias Handler = @Sendable (Transaction) throws(BinderError) -> Parcel?

    /// The interface this object implements, as the caller must name it.
    public let interfaceDescriptor: String

    /// The driver's key for this object.
    internal let id: UInt64

    internal let handler: Handler

    internal init(id: UInt64, interfaceDescriptor: String, handler: @escaping Handler) {
        self.id = id
        self.interfaceDescriptor = interfaceDescriptor
        self.handler = handler
    }
}

// MARK: - Registry

/// The objects a connection is hosting, keyed by the id the driver returns.
///
/// Holds them strongly. An object registered with the driver must stay callable
/// until it is withdrawn, and the driver has no way to consult Swift's object
/// graph before delivering a transaction — so lifetime here is decided by
/// registration, not by whether anything else still refers to it.
internal final class LocalObjectRegistry: Sendable {

    private let state = Mutex<State>(State())

    private struct State {
        var objects: [UInt64: LocalObject] = [:]
        /// Ids start at one; the driver treats zero as a null binder.
        var nextID: UInt64 = 1
    }

    func register(interfaceDescriptor: String, handler: @escaping LocalObject.Handler) -> LocalObject {
        state.withLock { state in
            let id = state.nextID
            state.nextID += 1
            let object = LocalObject(
                id: id,
                interfaceDescriptor: interfaceDescriptor,
                handler: handler
            )
            state.objects[id] = object
            return object
        }
    }

    func object(for id: UInt64) -> LocalObject? {
        state.withLock { $0.objects[id] }
    }

    func remove(_ object: LocalObject) {
        state.withLock { _ = $0.objects.removeValue(forKey: object.id) }
    }

    var count: Int {
        state.withLock { $0.objects.count }
    }
}

// MARK: - Connection

public extension BinderConnection {

    /// Create an object other processes can call, and start hosting it.
    ///
    /// The object is callable as soon as a reference to it reaches another
    /// process — by being written into a parcel — and stays callable until
    /// ``withdraw(_:)``. Nothing is delivered to it until a serving loop is
    /// running; see ``serve(while:)``.
    ///
    /// - Parameters:
    ///   - interface: the descriptor callers will send in their interface
    ///     token.
    ///   - handler: runs on a serving thread, not the caller's. It may run
    ///     concurrently with itself if more than one thread is serving.
    func makeLocalObject(
        interface: String,
        handler: @escaping LocalObject.Handler
    ) -> LocalObject {
        localObjects.register(interfaceDescriptor: interface, handler: handler)
    }

    /// Stop hosting an object.
    ///
    /// Transactions already in flight still run. Ones arriving afterwards are
    /// answered with a failed transaction, because the driver has no way to
    /// know the object is gone until it tries to deliver to it.
    func withdraw(_ object: LocalObject) {
        localObjects.remove(object)
    }
}

// MARK: - Parcelling

public extension Parcel {

    /// Append a reference to an object this process hosts.
    ///
    /// Written as `BINDER_TYPE_BINDER`, which is what tells the driver the
    /// object lives *here*: it creates a node on first sight and hands the
    /// receiving process a handle pointing back at it. Sending the same object
    /// again reuses that node.
    ///
    /// The `flags` field carries the node's scheduling priority in its low bits
    /// as well as `acceptsFDs`; zero priority means the node inherits the
    /// caller's, which is what a plain service wants.
    mutating func append(_ value: LocalObject) {
        var object = flat_binder_object()
        object.hdr = binder_object_header(type: .binder)
        object.flags = FlatBinderObjectFlags.acceptsFDs.rawValue
        object.binder = binder_uintptr_t(value.id)
        object.cookie = binder_uintptr_t(value.id)

        recordObjectOffset()
        append(bitPattern: object)
    }
}
