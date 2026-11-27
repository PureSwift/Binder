//
//  DeathNotificationTests.swift
//  Binder
//

import CBinder
import Synchronization
import Testing

@testable import Binder

@Suite
struct DeathNotificationTests {

    // MARK: - Payload layout

    /// `binder_handle_cookie` is declared `__attribute__((packed))`: a 4-byte
    /// handle followed immediately by an 8-byte cookie, 12 bytes rather than
    /// the 16 alignment would otherwise produce. If Swift ever imports it
    /// unpacked, every registration sends the driver a structure it reads
    /// differently — and the mismatch is silent, because the command still has
    /// a plausible shape.
    @Test func handleCookieIsPacked() {
        #expect(MemoryLayout<binder_handle_cookie>.size == 12)
        #expect(DriverCommandProtocol.requestDeathNotification.payloadSize == 12)
        #expect(DriverCommandProtocol.clearDeathNotification.payloadSize == 12)
        #expect(MemoryLayout<binder_handle_cookie>.size
                == DriverCommandProtocol.requestDeathNotification.payloadSize)
    }

    @Test func deathCommandsCarryABareCookie() {
        #expect(DriverReturnProtocol.deadBinder.payloadSize
                == MemoryLayout<binder_uintptr_t>.size)
        #expect(DriverReturnProtocol.clearDeathNotificationDone.payloadSize
                == MemoryLayout<binder_uintptr_t>.size)
        #expect(DriverCommandProtocol.deadBinderDone.payloadSize
                == MemoryLayout<binder_uintptr_t>.size)
    }

    @Test func encodesARegistration() {
        var payload = binder_handle_cookie()
        payload.handle = 7
        payload.cookie = 0x1234_5678

        var stream = CommandStream()
        stream.append(.requestDeathNotification, payload: payload)
        #expect(stream.count == 4 + 12)

        let decoded = Array(stream.bytes.dropFirst(4))
            .withUnsafeBytes { $0.loadUnaligned(as: binder_handle_cookie.self) }
        #expect(decoded.handle == 7)
        #expect(decoded.cookie == 0x1234_5678)
    }

    // MARK: - Registry

    @Test func registersAndFindsANotification() {
        let registry = DeathRegistry()
        let notification = registry.register(object: RemoteObject(handle: 3)) { }

        #expect(registry.count == 1)
        #expect(registry.notification(for: notification.cookie) === notification)
        #expect(notification.object == RemoteObject(handle: 3))
    }

    /// Zero stays available as "no cookie".
    @Test func cookiesStartAtOne() {
        let registry = DeathRegistry()
        #expect(registry.register(object: RemoteObject(handle: 1)) { }.cookie == 1)
    }

    /// The same object can be watched several times, and cancelling one watch
    /// must not cancel the others — which is why registration is keyed on a
    /// cookie rather than on the handle.
    @Test func watchesOnTheSameObjectAreIndependent() {
        let registry = DeathRegistry()
        let object = RemoteObject(handle: 5)
        let first = registry.register(object: object) { }
        let second = registry.register(object: object) { }

        #expect(first.cookie != second.cookie)
        #expect(registry.count == 2)

        _ = registry.remove(cookie: first.cookie)
        #expect(registry.notification(for: second.cookie) === second)
        #expect(registry.count == 1)
    }

    @Test func cookiesAreNotReusedAfterRemoval() {
        let registry = DeathRegistry()
        let first = registry.register(object: RemoteObject(handle: 1)) { }
        _ = registry.remove(cookie: first.cookie)
        let second = registry.register(object: RemoteObject(handle: 1)) { }

        #expect(second.cookie != first.cookie)
    }

    @Test func registrationIsSafeUnderConcurrency() async {
        let registry = DeathRegistry()

        await withTaskGroup(of: UInt64.self) { group in
            for handle in 0 ..< 100 {
                group.addTask {
                    registry.register(object: RemoteObject(handle: UInt32(handle))) { }.cookie
                }
            }
            var cookies = Set<UInt64>()
            for await cookie in group { cookies.insert(cookie) }
            #expect(cookies.count == 100)
        }
        #expect(registry.count == 100)
    }

    // MARK: - Delivery

    /// A death fires the handler registered for that cookie, and only that one.
    @Test func deliversToTheMatchingCookie() {
        let registry = DeathRegistry()
        let firedFirst = Mutex(false)
        let firedSecond = Mutex(false)

        let first = registry.register(object: RemoteObject(handle: 1)) {
            firedFirst.withLock { $0 = true }
        }
        _ = registry.register(object: RemoteObject(handle: 2)) {
            firedSecond.withLock { $0 = true }
        }

        registry.notification(for: first.cookie)?.handler()

        #expect(firedFirst.withLock { $0 })
        #expect(firedSecond.withLock { $0 } == false)
    }

    /// A death arriving for a cookie already retired must not crash the loop;
    /// it still has to be acknowledged or the driver keeps the recipient.
    @Test func anUnknownCookieHasNoHandler() {
        let registry = DeathRegistry()
        #expect(registry.notification(for: 999) == nil)
    }

    /// Cancelling does not retire the record — a death may already be in
    /// flight, and BR_CLEAR_DEATH_NOTIFICATION_DONE is what actually retires
    /// it. Dropping it at cancel time would leave that arrival unattributable
    /// and the driver waiting on an acknowledgement that never came.
    @Test func removalIsDrivenByTheConfirmation() {
        let registry = DeathRegistry()
        let notification = registry.register(object: RemoteObject(handle: 1)) { }

        #expect(registry.count == 1)
        let removed = registry.remove(cookie: notification.cookie)
        #expect(removed === notification)
        #expect(registry.count == 0)
        #expect(registry.remove(cookie: notification.cookie) == nil)
    }

    // MARK: - Ping

    /// IBinder::PING_TRANSACTION, the four characters `_PNG` packed into an
    /// integer. Transaction codes are interface-defined, so the universal ones
    /// sit far outside the range an interface would choose.
    @Test func pingTransactionIsPackedCharacters() {
        #expect(BinderConnection.pingTransaction == 0x5F50_4E47)

        let characters = [UInt8(ascii: "_"), UInt8(ascii: "P"),
                          UInt8(ascii: "N"), UInt8(ascii: "G")]
        let packed = characters.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        #expect(BinderConnection.pingTransaction == packed)
    }
}
