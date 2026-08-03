//
//  RemoteProxy.swift
//  Binder
//

/// An owned strong reference to a remote object.
///
/// A ``RemoteObject`` is just a handle — a number the driver assigned, valid
/// only in this process and only while this process holds a reference to it.
/// Nothing about the value says who is responsible for that reference. This
/// type is what makes it accountable: it holds one strong reference for its
/// lifetime and releases it on `deinit`, so the driver's count and Swift's
/// object graph agree without anyone having to remember.
///
/// Getting that wrong is not a leak in the ordinary sense. Releasing once too
/// often lets the driver reclaim the handle and hand the same number to a
/// *different* object, so a stale proxy silently starts calling something else.
/// Releasing once too rarely keeps the target process alive indefinitely.
/// Neither shows up where it was caused, which is why the pairing is mechanical
/// here rather than left to call sites.
///
/// ## Adoption, not acquisition
///
/// The initialiser **adopts** an existing reference rather than taking a new
/// one. Objects arrive from the driver already holding a strong reference —
/// ``BinderConnection`` takes one for every object in a reply before releasing
/// the transaction buffer — so acquiring again here would double the count and
/// keep the target alive forever. Use ``BinderConnection/adopt(_:)`` on an
/// object that came out of a reply, and ``BinderConnection/retain(_:)`` on one
/// obtained some other way.
public final class RemoteProxy {

    /// The underlying handle, for parcelling or comparison.
    ///
    /// Passing this somewhere that outlives the proxy reintroduces exactly the
    /// problem the proxy exists to solve.
    public let object: RemoteObject

    internal let connection: BinderConnection

    /// Adopt a strong reference that has already been taken.
    internal init(adopting object: RemoteObject, connection: BinderConnection) {
        self.object = object
        self.connection = connection
    }

    deinit {
        // Nothing useful can be done with a failure here and `deinit` cannot
        // throw. A failed release means the driver already dropped this
        // process's reference, which is a bug in this type's accounting rather
        // than a runtime condition.
        try? connection.release(object)
    }
}

extension RemoteProxy: @unchecked Sendable {}

public extension RemoteProxy {

    /// The handle the driver assigned.
    var handle: UInt32 {
        object.handle
    }

    /// Send a transaction to this object and wait for its reply.
    ///
    /// See ``BinderConnection/transact(with:code:request:flags:)`` for what the
    /// reply's own objects require.
    func transact(
        code: UInt32,
        request: Parcel,
        flags: TransactionFlags = .acceptFds
    ) throws(BinderError) -> Parcel {
        try connection.transact(
            with: object,
            code: code,
            request: request,
            flags: flags
        )
    }

    /// Send a transaction and suspend until the reply arrives.
    func transact(
        code: UInt32,
        request: Parcel,
        flags: TransactionFlags = .acceptFds
    ) async throws(BinderError) -> Parcel {
        try await connection.transact(
            with: object,
            code: code,
            request: request,
            flags: flags
        )
    }

    /// A weak reference to the same object.
    ///
    /// Holds its own weak count, independent of this strong one, so it outlives
    /// this proxy and can be promoted again later — as long as the object is
    /// still alive when it is.
    func weak() throws(BinderError) -> WeakProxy {
        try connection.weakReference(to: object)
    }
}

public extension BinderConnection {

    /// Take ownership of a reference this connection already holds.
    ///
    /// For objects read out of a reply, whose reference was taken when the
    /// reply's buffer was released.
    func adopt(_ object: RemoteObject) -> RemoteProxy {
        RemoteProxy(adopting: object, connection: self)
    }

    /// Take a new strong reference and own it.
    ///
    /// For a handle obtained some way other than from a reply — reconstructed
    /// from a stored number, say. Acquiring a handle this process does not
    /// already hold a reference to is rejected by the driver.
    func retain(_ object: RemoteObject) throws(BinderError) -> RemoteProxy {
        try acquire(object)
        return RemoteProxy(adopting: object, connection: self)
    }
}
