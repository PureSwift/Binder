//
//  Looper.swift
//  Binder
//

import Synchronization
import CBinder

/// What a command arriving from the driver requires in response.
///
/// Separated from the sending so that the decision is testable on its own. What
/// goes wrong in a serving loop is almost never the ioctl — it is answering the
/// wrong command, or failing to answer one the driver is waiting on, and both
/// are visible here.
///
/// Not `Equatable`: the payloads are C structs containing unions, which Swift
/// cannot synthesise a comparison for. Tests pattern-match instead.
internal enum IncomingAction {

    /// Reply to a synchronous transaction and release its buffer.
    case reply(Parcel, to: binder_transaction_data)

    /// A one-way transaction: release the buffer, send nothing back.
    ///
    /// Replying to one is a protocol error — the caller is not waiting and the
    /// driver has no transaction to match the reply against.
    case free(binder_uintptr_t)

    /// The driver is taking a reference to one of our objects and waiting to be
    /// told we have noted it.
    ///
    /// Not optional. The driver blocks the node's reference transition until
    /// the matching `*_DONE` arrives, so skipping this stalls whoever is trying
    /// to acquire the object.
    case acknowledge(DriverCommandProtocol, binder_ptr_cookie)

    /// A watched object's process has died and its handler has run.
    ///
    /// The driver keeps the death recipient alive until `BC_DEAD_BINDER_DONE`
    /// arrives, so this must go back even though nothing is waiting on it.
    case deathAcknowledged(binder_uintptr_t)

    /// Bookkeeping that needs no response.
    case ignore
}

// MARK: - Deciding

internal extension BinderConnection {

    /// Work out what a command from the driver requires, running any handler it
    /// implies.
    func action(for element: ReturnStream.Element) throws(BinderError) -> IncomingAction {
        switch element.command {
        case .transaction:
            guard let data = element.decode(as: binder_transaction_data.self) else {
                throw BinderError.unexpectedReturn(element.command)
            }
            return try dispatch(data)

        case .transactionSecCtx:
            // Delivered instead of BR_TRANSACTION when the target node was
            // registered with FLAG_TXN_SECURITY_CTX. The structure is a plain
            // binder_transaction_data with a security-context pointer appended,
            // and the transaction sits at offset zero, so the same dispatch
            // handles it once the trailing pointer is dropped. The context
            // string itself is not surfaced yet; sender_pid and sender_euid,
            // which a permission check actually needs, are already in the
            // transaction.
            guard let data = element.decode(as: binder_transaction_data_secctx.self) else {
                throw BinderError.unexpectedReturn(element.command)
            }
            return try dispatch(data.transaction_data)

        case .incRefs:
            // BC_INCREFS_DONE answers BR_INCREFS.
            guard let cookie = element.decode(as: binder_ptr_cookie.self) else {
                throw BinderError.unexpectedReturn(element.command)
            }
            return .acknowledge(.incRefsDone, cookie)

        case .acquire:
            guard let cookie = element.decode(as: binder_ptr_cookie.self) else {
                throw BinderError.unexpectedReturn(element.command)
            }
            return .acknowledge(.acquireDone, cookie)

        case .release, .decRefs:
            // The driver is dropping a reference it holds. Nothing is expected
            // back; the object stays hosted until it is withdrawn.
            return .ignore

        case .noop, .spawnLooper, .transactionComplete, .onewaySpamSuspect,
             .finished, .ok:
            return .ignore

        case .deadBinder:
            guard let cookie = element.decode(as: binder_uintptr_t.self) else {
                throw BinderError.unexpectedReturn(element.command)
            }
            // The handler runs before the acknowledgement rather than after, so
            // that a client which reacts by dropping its reference has already
            // done so when the driver tears the recipient down.
            //
            // The registration is left in place: a cancel may be in flight, and
            // BR_CLEAR_DEATH_NOTIFICATION_DONE is what actually retires it.
            deaths.notification(for: UInt64(cookie))?.handler()
            return .deathAcknowledged(cookie)

        case .clearDeathNotificationDone:
            guard let cookie = element.decode(as: binder_uintptr_t.self) else {
                throw BinderError.unexpectedReturn(element.command)
            }
            // The driver has confirmed the cancel, so nothing further can
            // arrive for this cookie and the record can go.
            _ = deaths.remove(cookie: UInt64(cookie))
            return .ignore

        case .error:
            throw BinderError.driver(element.decode(as: Int32.self) ?? 0)

        case .failedReply:
            throw BinderError.failedTransaction

        case .deadReply:
            throw BinderError.deadObject

        default:
            throw BinderError.unexpectedReturn(element.command)
        }
    }

    /// Route an incoming transaction to the object it names.
    private func dispatch(
        _ data: binder_transaction_data
    ) throws(BinderError) -> IncomingAction {
        let isOneWay = TransactionFlags(rawValue: data.flags).contains(.oneWay)

        // The driver returns the value we registered the node with.
        let id = UInt64(data.target.ptr)
        guard let object = localObjects.object(for: id) else {
            // Withdrawn between the driver deciding to deliver and us looking
            // it up, or a node this process never registered. Either way the
            // buffer is still ours to release.
            return isOneWay ? .free(data.data.ptr.buffer) : .reply(Parcel(), to: data)
        }

        let request = try copyReply(data)
        let transaction = LocalObject.Transaction(
            code: data.code,
            request: request,
            flags: TransactionFlags(rawValue: data.flags),
            senderProcessID: data.sender_pid,
            senderUserID: data.sender_euid
        )

        // A handler that throws must not unwind into the loop: the loop cannot
        // report it and would have to stop, taking every other hosted object
        // down with it. The caller is told instead, through the reply.
        let reply: Parcel?
        do {
            reply = try object.handler(transaction)
        } catch {
            return isOneWay ? .free(data.data.ptr.buffer) : .reply(Parcel(), to: data)
        }

        // A one-way caller is not waiting, so any reply is discarded rather
        // than sent — replying would be a protocol error, not merely wasteful.
        return isOneWay
            ? .free(data.data.ptr.buffer)
            : .reply(reply ?? Parcel(), to: data)
    }
}

// MARK: - Performing

internal extension BinderConnection {

    /// Carry out a decided action.
    func perform(_ action: IncomingAction) throws(BinderError) {
        switch action {
        case .ignore:
            return

        case .free(let pointer):
            var commands = CommandStream()
            commands.append(.freeBuffer, payload: pointer)
            try send(commands)

        case .acknowledge(let command, let cookie):
            var commands = CommandStream()
            commands.append(command, payload: cookie)
            try send(commands)

        case .deathAcknowledged(let cookie):
            var commands = CommandStream()
            commands.append(.deadBinderDone, payload: cookie)
            try send(commands)

        case .reply(let parcel, let data):
            try sendReply(parcel, to: data)
        }
    }

    /// Send `BC_REPLY` and release the request's buffer.
    ///
    /// The reply's bytes and offsets are staged in memory this call owns, for
    /// the same reason an outgoing transaction stages its request: the driver
    /// reads them through pointers rather than copying at the time the command
    /// is queued.
    private func sendReply(
        _ parcel: Parcel,
        to request: binder_transaction_data
    ) throws(BinderError) {
        let staged = UnsafeMutableBufferPointer<UInt8>
            .allocate(capacity: Swift.max(parcel.bytes.count, 1))
        defer { staged.deallocate() }
        _ = staged.initialize(fromContentsOf: parcel.bytes)

        let offsets = UnsafeMutableBufferPointer<binder_size_t>
            .allocate(capacity: Swift.max(parcel.objectOffsets.count, 1))
        defer { offsets.deallocate() }
        _ = offsets.initialize(
            fromContentsOf: parcel.objectOffsets.map { binder_size_t($0) }
        )

        // Out-of-line buffers in a reply are staged and fixed up exactly as in
        // an outgoing transaction; they must outlive the ioctl.
        var stagedBuffers: [UnsafeMutableBufferPointer<UInt8>] = []
        defer { stagedBuffers.forEach { $0.deallocate() } }
        for buffer in parcel.scatterGatherBuffers {
            let payload = UnsafeMutableBufferPointer<UInt8>
                .allocate(capacity: Swift.max(buffer.payload.count, 1))
            _ = payload.initialize(fromContentsOf: buffer.payload)
            stagedBuffers.append(payload)

            let address = binder_uintptr_t(UInt(bitPattern: payload.baseAddress))
            withUnsafeBytes(of: address) { source in
                for index in 0 ..< source.count {
                    staged[buffer.offset + 8 + index] = source[index]
                }
            }
        }

        var data = binder_transaction_data()
        // A reply has no target: the driver matches it to the transaction this
        // thread is currently answering.
        data.target.ptr = 0
        data.cookie = 0
        data.code = 0
        data.flags = 0
        data.data_size = binder_size_t(parcel.bytes.count)
        data.offsets_size = binder_size_t(
            parcel.objectOffsets.count * MemoryLayout<binder_size_t>.size
        )
        data.data.ptr.buffer = binder_uintptr_t(UInt(bitPattern: staged.baseAddress))
        data.data.ptr.offsets = binder_uintptr_t(UInt(bitPattern: offsets.baseAddress))

        var commands = CommandStream()
        if parcel.hasBuffers {
            var scatterGather = binder_transaction_data_sg()
            scatterGather.transaction_data = data
            scatterGather.buffers_size = binder_size_t(parcel.buffersSize)
            commands.append(.replySg, payload: scatterGather)
        } else {
            commands.append(.reply, payload: data)
        }
        // The request's buffer goes back in the same stream, after the reply
        // has been queued from it.
        commands.append(.freeBuffer, payload: request.data.ptr.buffer)
        try send(commands)
    }

    /// Hand commands to the driver without waiting for anything in particular.
    func send(_ commands: CommandStream) throws(BinderError) {
        var pending = commands
        let readBuffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: 256)
        defer { readBuffer.deallocate() }
        readBuffer.initialize(repeating: 0)

        _ = try talkWithDriver(&pending, into: readBuffer)
    }
}

// MARK: - The loop

public extension BinderConnection {

    /// Serve incoming transactions on the calling thread until told to stop.
    ///
    /// Blocks. The driver parks the thread whenever there is nothing to deliver,
    /// which is what makes this cheap to leave running, and also what makes it
    /// impossible for the loop to stop itself — ``stopServing()`` sets the flag,
    /// but the thread stays parked until the next command arrives. A loop with
    /// no traffic can therefore outlive the request to stop; closing the
    /// connection is what guarantees it ends.
    ///
    /// More than one thread may serve the same connection. Handlers then run
    /// concurrently with themselves, which is the normal arrangement for a
    /// binder service and the reason ``LocalObject/Handler`` is `@Sendable`.
    ///
    /// - Parameter shouldContinue: consulted between commands, in addition to
    ///   the connection's own serving flag.
    func serve(while shouldContinue: @Sendable () -> Bool = { true }) throws(BinderError) {
        isServing.withLock { $0 = true }

        // Registers this thread as one the driver may deliver transactions to.
        var enter = CommandStream()
        enter.append(.enterLooper)
        try send(enter)

        defer {
            var exit = CommandStream()
            exit.append(.exitLooper)
            try? send(exit)
            // Release the driver's per-thread state now that this thread is
            // leaving binder. BC_EXIT_LOOPER only tells the driver to stop
            // delivering transactions here; the binder_thread itself lives
            // until BINDER_THREAD_EXIT or device close.
            try? exitThread()
        }

        let readBuffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: 256)
        defer { readBuffer.deallocate() }
        readBuffer.initialize(repeating: 0)

        while isServing.withLock({ $0 }) && shouldContinue() {
            var empty = CommandStream()
            let returned = try talkWithDriver(&empty, into: readBuffer)
            var stream = ReturnStream(bytes: returned)

            while true {
                let element: ReturnStream.Element?
                do {
                    element = try stream.next()
                } catch {
                    throw BinderError.stream(error)
                }
                guard let element else { break }

                try perform(try action(for: element))
            }
        }
    }

    /// Ask every serving loop on this connection to stop.
    ///
    /// Takes effect when each loop next returns from the driver, which may be
    /// not at all if nothing is being delivered — see ``serve(while:)``.
    func stopServing() {
        isServing.withLock { $0 = false }
    }

    /// Whether a serving loop has been started and not yet asked to stop.
    var isServingTransactions: Bool {
        isServing.withLock { $0 }
    }
}
