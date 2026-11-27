//
//  Transaction+Async.swift
//  Binder
//

import Dispatch

/// Async forms of the blocking operations.
///
/// A synchronous binder transaction has no non-blocking form: the driver parks
/// the calling thread until the peer replies, and there is no way to ask it for
/// "whatever is ready now". So these are not natively asynchronous — they move
/// the blocking call onto a thread that is allowed to block, and suspend the
/// caller until it finishes.
///
/// That distinction matters. Swift's cooperative pool has roughly one thread per
/// core and expects tasks to yield rather than block; a binder call that waits
/// on a slow service would take a core out of circulation for the duration. Any
/// number of these can be in flight at once — they run on ``BinderConnection``'s
/// own concurrent queue.
///
/// ## Driver thread state
///
/// The kernel keeps a `binder_thread` for every thread that has issued an ioctl
/// on the device, and frees it when that thread sends `BINDER_THREAD_EXIT` or
/// when the device is closed. Work here runs on Dispatch's worker threads, whose
/// exit this code cannot observe, so those structures accumulate — one per
/// distinct worker thread that has carried a transaction — until the connection
/// is released. Dispatch's pool is bounded, so this is bounded too, but it is
/// the reason a long-lived process should hold one connection rather than
/// opening one per call.
public extension BinderConnection {

    /// Send a transaction and suspend until the reply arrives.
    ///
    /// The async counterpart of
    /// ``BinderConnection/transact(with:code:request:flags:)``.
    ///
    /// - Note: cancelling the surrounding task does not cancel the transaction.
    ///   Once the driver has taken it there is no way to withdraw it, and the
    ///   peer will reply or die; abandoning the wait would leak the reply
    ///   buffer, since nothing would be left to hand it back with
    ///   `BC_FREE_BUFFER`.
    func transact(
        with target: RemoteObject,
        code: UInt32,
        request: Parcel,
        flags: TransactionFlags = .acceptFds
    ) async throws(BinderError) -> Parcel {
        try await detached { () throws(BinderError) -> Parcel in
            try self.transact(
                with: target,
                code: code,
                request: request,
                flags: flags
            )
        }
    }

    /// Look up a service, suspending until it is found or the lookup gives up.
    ///
    /// Blocks in the *server* for up to five seconds if the service is not yet
    /// registered, so this can suspend for that long.
    func service(
        named name: String,
        header: RPCHeader = .system
    ) async throws(BinderError) -> RemoteProxy? {
        try await detached { () throws(BinderError) -> RemoteProxy? in
            try self.service(named: name, header: header)
        }
    }

    /// Look up a service without waiting for it to appear.
    func checkService(
        named name: String,
        header: RPCHeader = .system
    ) async throws(BinderError) -> RemoteProxy? {
        try await detached { () throws(BinderError) -> RemoteProxy? in
            try self.checkService(named: name, header: header)
        }
    }

    /// List the names of every registered service.
    func services(
        priority: ServiceManager.DumpPriority = .all,
        header: RPCHeader = .system
    ) async throws(BinderError) -> [String] {
        try await detached { () throws(BinderError) -> [String] in
            try self.services(priority: priority, header: header)
        }
    }
}

internal extension BinderConnection {

    /// Run a blocking binder operation off the cooperative pool.
    ///
    /// The result travels back as a `Result` rather than through a throwing
    /// continuation so that the error type survives: a throwing continuation
    /// erases to `any Error`, and rethrowing that would widen every one of
    /// these signatures away from ``BinderError``.
    func detached<Success: Sendable>(
        _ work: @escaping @Sendable () throws(BinderError) -> Success
    ) async throws(BinderError) -> Success {
        let outcome: Result<Success, BinderError> = await withCheckedContinuation { continuation in
            queue.async {
                let outcome: Result<Success, BinderError>
                do {
                    outcome = .success(try work())
                } catch let error as BinderError {
                    outcome = .failure(error)
                } catch {
                    // Unreachable: `work` is declared throws(BinderError), so
                    // nothing else can come out of it. Swift still requires the
                    // arm because the enclosing Dispatch closure is untyped.
                    preconditionFailure("unexpected error type: \(error)")
                }
                continuation.resume(returning: outcome)
            }
        }

        switch outcome {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        }
    }
}
