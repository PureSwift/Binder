//
//  DeathNotification.swift
//  Binder
//

import Synchronization
import CBinder

/// A standing request to be told when a remote object's process dies.
///
/// The only way to learn that a peer has gone. A handle does not become
/// detectably invalid — transactions to a dead object fail, but nothing arrives
/// to say so until one is attempted, and a client that is merely holding a
/// reference would never find out. Worse, the driver may reissue the handle
/// number for a different object once the reference count drops, so polling by
/// pinging is not equivalent.
///
/// Registration is per `(object, cookie)` pair, which is why this is a distinct
/// object rather than a closure on ``RemoteObject``: the same remote object can
/// be watched several times independently, and cancelling one watch must not
/// cancel the others.
public final class DeathNotification: Sendable {

    /// The object being watched.
    public let object: RemoteObject

    /// What the driver hands back to identify this registration.
    internal let cookie: UInt64

    internal let handler: @Sendable () -> Void

    internal init(
        object: RemoteObject,
        cookie: UInt64,
        handler: @escaping @Sendable () -> Void
    ) {
        self.object = object
        self.cookie = cookie
        self.handler = handler
    }
}

/// The death notifications a connection has registered, keyed by cookie.
internal final class DeathRegistry: Sendable {

    private let state = Mutex<State>(State())

    private struct State {
        var notifications: [UInt64: DeathNotification] = [:]
        /// Cookies start at one so that zero stays available as "no cookie".
        var nextCookie: UInt64 = 1
    }

    func register(
        object: RemoteObject,
        handler: @escaping @Sendable () -> Void
    ) -> DeathNotification {
        state.withLock { state in
            let cookie = state.nextCookie
            state.nextCookie += 1
            let notification = DeathNotification(
                object: object,
                cookie: cookie,
                handler: handler
            )
            state.notifications[cookie] = notification
            return notification
        }
    }

    func notification(for cookie: UInt64) -> DeathNotification? {
        state.withLock { $0.notifications[cookie] }
    }

    func remove(cookie: UInt64) -> DeathNotification? {
        state.withLock { $0.notifications.removeValue(forKey: cookie) }
    }

    var count: Int {
        state.withLock { $0.notifications.count }
    }
}

// MARK: - Registration

public extension BinderConnection {

    /// Ask to be told when a remote object's hosting process dies.
    ///
    /// - Parameters:
    ///   - object: the object to watch. A reference to it must be held for the
    ///     watch to mean anything; watching a handle whose count has reached
    ///     zero watches whatever the driver reissues that number to.
    ///   - handler: runs on a serving thread. Nothing is delivered unless a
    ///     serving loop is running — see ``serve(while:)`` — because the
    ///     notification arrives as a command in the return stream like any
    ///     other.
    ///
    /// - Returns: the registration, needed to cancel it.
    func notifyOnDeath(
        of object: RemoteObject,
        handler: @escaping @Sendable () -> Void
    ) throws(BinderError) -> DeathNotification {
        let notification = deaths.register(object: object, handler: handler)

        var payload = binder_handle_cookie()
        payload.handle = object.handle
        payload.cookie = binder_uintptr_t(notification.cookie)

        var commands = CommandStream()
        commands.append(.requestDeathNotification, payload: payload)
        try send(commands)

        return notification
    }

    /// Cancel a death notification.
    ///
    /// The registration is not forgotten here. The driver confirms with
    /// `BR_CLEAR_DEATH_NOTIFICATION_DONE`, and a death already on its way can
    /// still arrive first; dropping the record now would leave that arrival
    /// unattributable, and the driver waiting on a `BC_DEAD_BINDER_DONE` that
    /// never comes.
    func cancel(_ notification: DeathNotification) throws(BinderError) {
        var payload = binder_handle_cookie()
        payload.handle = notification.object.handle
        payload.cookie = binder_uintptr_t(notification.cookie)

        var commands = CommandStream()
        commands.append(.clearDeathNotification, payload: payload)
        try send(commands)
    }
}

// MARK: - Liveness

public extension BinderConnection {

    /// The transaction code every binder object answers.
    ///
    /// `IBinder::PING_TRANSACTION`, which is the four characters `_PNG` packed
    /// into an integer rather than a small number — transaction codes are
    /// interface-defined, so the universal ones are placed far away from the
    /// range an interface would use.
    static var pingTransaction: UInt32 { 0x5F50_4E47 }

    /// Ask an object whether it is still there.
    ///
    /// - Returns: `true` if it answered.
    ///
    /// A negative answer is only a snapshot: the peer can die immediately
    /// afterwards, so this cannot be built into a reliable liveness check.
    /// ``notifyOnDeath(of:handler:)`` is the mechanism that does not race.
    func ping(_ object: RemoteObject) throws(BinderError) -> Bool {
        do {
            _ = try transact(with: object, code: Self.pingTransaction, request: Parcel())
            return true
        } catch .deadObject {
            return false
        } catch .failedTransaction {
            return false
        }
    }

    /// Whether the context manager is answering.
    ///
    /// Worth checking before a lookup: on a system where the service manager
    /// has not started, ``service(named:)`` blocks in the driver for five
    /// seconds per call before giving up, which reads as a hang.
    var isServiceManagerPresent: Bool {
        (try? ping(.contextManager)) ?? false
    }
}
