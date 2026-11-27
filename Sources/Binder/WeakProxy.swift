//
//  WeakProxy.swift
//  Binder
//

/// A weak reference to a remote object.
///
/// The `wp<>` to ``RemoteProxy``'s `sp<>`. A weak reference keeps the *handle*
/// from being recycled — so the number will not silently come to mean a
/// different object — but does not keep the target alive. It is what you hold
/// for something you want to reach if it is still there, without being the
/// reason it stays there: a cache of proxies, a back-reference, an observer that
/// should not prevent teardown.
///
/// The only thing you can do with a weak reference is try to ``promote()`` it to
/// a strong one. If the target is still alive, that yields a ``RemoteProxy``
/// that keeps it alive for as long as it is held; if the target is gone, it
/// yields `nil`.
///
/// ## Promotion is a snapshot, not a subscription
///
/// A successful ``promote()`` means the object was alive at that instant. It can
/// die immediately after, so a promoted proxy is not a guarantee of liveness for
/// any later call — those can still fail with ``BinderError/deadObject``.
/// ``BinderConnection/notifyOnDeath(of:handler:)`` is the mechanism that tells
/// you *when* it dies; promotion only tells you whether it is dead *now*.
public final class WeakProxy {

    /// The object this refers to.
    public let object: RemoteObject

    private let connection: BinderConnection

    internal init(object: RemoteObject, connection: BinderConnection) {
        self.object = object
        self.connection = connection
    }

    deinit {
        // Release the weak reference taken when this was created. A failure
        // means the driver already dropped it, which is an accounting bug in
        // this type rather than a runtime condition; deinit cannot throw.
        try? connection.decrementWeak(object)
    }
}

extension WeakProxy: @unchecked Sendable {}

public extension WeakProxy {

    /// The handle the driver assigned.
    var handle: UInt32 {
        object.handle
    }

    /// Try to obtain a strong reference to the target.
    ///
    /// - Returns: an owning ``RemoteProxy`` if the object is still alive, or
    ///   `nil` if it has died.
    ///
    /// Attempts to take a strong reference. The driver grants it only while the
    /// target node still exists, so a rejection is read as "gone" rather than as
    /// an error — anything else the driver reports is surfaced as thrown.
    func promote() throws(BinderError) -> RemoteProxy? {
        do {
            try connection.acquire(object)
        } catch .deadObject, .failedTransaction {
            // The node is gone. The weak reference this proxy holds is still
            // valid — the handle is not recycled until it too is dropped — so
            // there is nothing to undo here.
            return nil
        }
        return connection.adopt(object)
    }
}

public extension BinderConnection {

    /// Take a weak reference to an object and own it.
    ///
    /// The object must be one this process already holds a reference to — a
    /// live ``RemoteProxy``'s ``RemoteProxy/object`` — since the driver rejects
    /// a weak increment on a handle the process does not already hold.
    ///
    /// The returned proxy holds the weak reference for its lifetime and drops it
    /// on `deinit`.
    func weakReference(to object: RemoteObject) throws(BinderError) -> WeakProxy {
        try incrementWeak(object)
        return WeakProxy(object: object, connection: self)
    }
}
