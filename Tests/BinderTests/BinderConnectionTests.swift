//
//  BinderConnectionTests.swift
//  Binder
//

import SystemPackage
import Testing

@testable import Binder

/// What can be checked about a connection without a binder device present.
///
/// Opening one requires a driver, so these are the properties that hold before
/// any device is involved: the type's shape, and the constants a caller can
/// read without connecting.
@Suite
struct BinderConnectionTests {

    /// A connection is shared across tasks rather than copied into each, and
    /// the async operations hand work to another thread through an escaping
    /// closure. Both of those stop compiling if it goes back to being a
    /// non-copyable value, so the requirement is pinned here rather than left
    /// to be rediscovered.
    @Test func connectionIsSendable() {
        func requireSendable<T: Sendable>(_: T.Type) {}
        requireSendable(BinderConnection.self)
    }

    @Test func exposesTheMappedBufferSize() {
        #expect(BinderConnection.defaultBufferSize == MappedBuffer.defaultSize)
        #expect(BinderConnection.defaultBufferSize > 0)
    }

    /// libbinder's DEFAULT_MAX_BINDER_THREADS. Services on the other end are
    /// provisioned expecting it.
    @Test func defaultMaxThreadsMatchesLibbinder() {
        #expect(Binder.defaultMaxThreads == 15)
    }

    @Test func defaultPathIsTheBinderDevice() {
        #expect(Binder.path == "/dev/binder")
    }
}

/// Never called — it exists to be compiled.
///
/// Opening a connection needs a driver, so the async surface cannot be
/// exercised at runtime here. What can still be checked is that it type-checks
/// from a caller's position: that the async overloads are reachable, that their
/// errors stay typed as `BinderError` rather than widening to `any Error`, and
/// that a connection can be held across a suspension point without tripping
/// sendability. Each of those has already broken once while this was being
/// written.
private func asyncSurfaceCompiles(_ connection: BinderConnection) async {
    var request = Parcel()
    request.appendInterfaceToken(ServiceManager.descriptor)
    request.append("activity")

    do {
        _ = try await connection.service(named: "activity")
        _ = try await connection.checkService(named: "activity")
        _ = try await connection.services()
        _ = try await connection.transact(with: .contextManager, code: 1, request: request)

        // A looked-up service is an owning reference and is callable directly,
        // with no handle unwrapping at the call site.
        if let service = try await connection.service(named: "activity") {
            _ = try await service.transact(code: 1, request: request)
            // The async call helper returns a whole parcel; results come from
            // resultReader(), the header already consumed.
            let reply = try await service.call(1, interface: "com.example.IThing") {
                $0.append("arg")
            }
            _ = reply.resultReader()
        }
    } catch {
        // Typed: if this ever widens to `any Error`, the pattern stops
        // compiling and the async signatures have silently lost their type.
        let typed: BinderError = error
        _ = typed
    }
}

/// Likewise for the synchronous surface, which the async one delegates to.
///
/// Adding async overloads with the same argument labels risks making the plain
/// calls ambiguous; this fails to compile if that happens.
private func syncSurfaceCompiles(_ connection: BinderConnection) {
    var request = Parcel()
    request.appendInterfaceToken(ServiceManager.descriptor)

    do {
        _ = try connection.service(named: "activity")
        _ = try connection.checkService(named: "activity")
        _ = try connection.services()
        _ = try connection.transact(with: .contextManager, code: 1, request: request)

        if let service = try connection.checkService(named: "activity") {
            _ = try service.transact(code: 1, request: request)
        }

        let object = RemoteObject(handle: 1)
        try connection.acquire(object)
        try connection.release(object)
        try connection.incrementWeak(object)
        try connection.decrementWeak(object)
        _ = connection.adopt(object)
        _ = try connection.retain(object)
        try connection.addService(named: "example", object: object)

        // Hosting an object and serving it. The handler is @Sendable because
        // several threads may serve one connection concurrently.
        let hosted = connection.makeLocalObject(interface: "com.example.IThing") { transaction in
            guard transaction.senderUserID == 1000 else { return nil }
            var reply = Parcel()
            reply.append(Int32(0))
            return reply
        }
        var registration = Parcel()
        registration.append(hosted)

        connection.stopServing()
        _ = connection.isServingTransactions
        try connection.serve(while: { false })
        connection.withdraw(hosted)

        // Liveness, and the standing watch that does not race with it.
        _ = try connection.ping(object)
        _ = connection.isServiceManagerPresent

        let watch = try connection.notifyOnDeath(of: object) {
            // Runs on a serving thread, hence @Sendable.
        }
        try connection.cancel(watch)

        // Publishing a hosted object, and the manual thread-exit for a caller
        // driving transactions from threads it owns.
        try connection.addService(named: "com.example.thing", object: hosted)
        try connection.exitThread()

        // Weak references and promotion.
        let strong = connection.adopt(object)
        let weakRef = try strong.weak()
        if let promoted = try weakRef.promote() {
            _ = try promoted.transact(code: 1, request: request)
        }
        _ = try connection.weakReference(to: object)

        // File-descriptor passing (writing does not throw) and the failure
        // diagnostic. Reading an fd throws ParcelError and is exercised in
        // FileDescriptorObjectTests, so it is kept out of this BinderError block.
        var withFd = Parcel()
        withFd.append(fileDescriptor: FileDescriptor(rawValue: 1))
        _ = try connection.lastError()

        // A scatter-gather request: an inline header plus an out-of-line
        // buffer, sent through the same transact entry point.
        var sgRequest = Parcel()
        sgRequest.appendInterfaceToken("android.hardware.foo@1.0::IFoo")
        sgRequest.append(buffer: [0xAA, 0xBB])
        _ = try connection.transact(with: object, code: 1, request: sgRequest)

        // The call helpers, which write the envelope so a method supplies only
        // its code and arguments. Reading from the returned reader throws
        // ParcelError and is exercised in CallTests, so it is kept out of this
        // BinderError block.
        let proxy = connection.adopt(object)
        _ = try proxy.call(1, interface: "com.example.IThing") { $0.append("arg") }
        try proxy.post(2, interface: "com.example.IThing") { $0.append(Int32(1)) }

        // Becoming the context manager, the one binder role beyond calling and
        // serving.
        try connection.becomeContextManager()
        try connection.becomeContextManager(securityContext: true)
    } catch {
        let typed: BinderError = error
        _ = typed
    }
}
