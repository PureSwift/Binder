//
//  Transaction.swift
//  Binder
//

import SystemPackage
import Socket
import CBinder

public extension BinderConnection {

    /// Send a transaction to a remote object and wait for its reply.
    ///
    /// - Parameters:
    ///   - handle: the target's handle. `0` is always the context manager.
    ///   - code: the interface-defined transaction code.
    ///   - request: the payload.
    ///   - flags: `acceptFds` by default, matching libbinder. Adding `oneWay`
    ///     makes the call return as soon as the driver has taken the
    ///     transaction, with an empty parcel.
    ///
    /// - Returns: the reply parcel, copied out of the mapped buffer.
    ///
    /// Blocks the calling thread. A synchronous transaction has no
    /// non-blocking form — the driver parks the thread until the peer replies —
    /// so this must not be called from a thread something else needs.
    func transact(
        handle: UInt32,
        code: UInt32,
        request: Parcel,
        flags: TransactionFlags = .acceptFds
    ) throws(BinderError) -> Parcel {
        // The driver reads the request through the pointer in
        // binder_transaction_data rather than from a copy, so the bytes need an
        // address that stays put for the whole exchange. A Swift array cannot
        // promise that outside a `withUnsafe...` closure, and a closure would
        // put the blocking wait somewhere errors cannot be typed, so the
        // request is staged in memory this function owns.
        let staged = UnsafeMutableBufferPointer<UInt8>
            .allocate(capacity: Swift.max(request.bytes.count, 1))
        defer { staged.deallocate() }
        _ = staged.initialize(fromContentsOf: request.bytes)

        var data = binder_transaction_data()
        data.target.handle = handle
        data.cookie = 0
        data.code = code
        data.flags = flags.rawValue
        data.data_size = binder_size_t(request.bytes.count)
        // No binder objects are placed in the parcel yet, so there are no
        // offsets for the driver to translate.
        data.offsets_size = 0
        data.data.ptr.buffer = binder_uintptr_t(UInt(bitPattern: staged.baseAddress))
        data.data.ptr.offsets = 0

        var commands = CommandStream()
        commands.append(.transaction, payload: data)

        return try waitForResponse(commands, isOneWay: flags.contains(.oneWay))
    }
}

internal extension BinderConnection {

    /// Drive the exchange until a command arrives that ends it.
    ///
    /// The driver does not answer a transaction with a reply; it answers with a
    /// stream in which the reply may be several commands in, or may not have
    /// arrived yet at all. Bookkeeping commands are consumed and ignored here
    /// rather than surfaced, because a caller waiting on a reply has nothing
    /// useful to do with `BR_NOOP`.
    func waitForResponse(
        _ commands: CommandStream,
        isOneWay: Bool
    ) throws(BinderError) -> Parcel {
        // libbinder reads into 256 bytes. A reply's payload does not travel
        // here — it lands in the mapped buffer and only its descriptor comes
        // through this stream — so this holds commands, not data.
        let readBuffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: 256)
        defer { readBuffer.deallocate() }
        readBuffer.initialize(repeating: 0)

        var pending = commands

        while true {
            let returned = try talkWithDriver(&pending, into: readBuffer)
            var stream = ReturnStream(bytes: returned)

            while true {
                let element: ReturnStream.Element?
                do {
                    element = try stream.next()
                } catch {
                    throw BinderError.stream(error)
                }
                guard let element else { break }

                switch element.command {
                case .noop, .spawnLooper, .onewaySpamSuspect,
                     .transactionPendingFrozen:
                    // Bookkeeping. BR_SPAWN_LOOPER is the driver asking for
                    // another service thread; ignoring it is correct for a
                    // client that serves nothing.
                    continue

                case .transactionComplete:
                    // The driver has taken the transaction. For a one-way call
                    // that is the whole exchange.
                    if isOneWay {
                        return Parcel()
                    }

                case .deadReply:
                    throw BinderError.deadObject

                case .failedReply:
                    throw BinderError.failedTransaction

                case .frozenReply:
                    throw BinderError.frozen

                case .error:
                    throw BinderError.driver(element.decode(as: Int32.self) ?? 0)

                case .reply:
                    guard let data = element.decode(as: binder_transaction_data.self) else {
                        throw BinderError.unexpectedReturn(element.command)
                    }
                    let reply = try copyReply(data)
                    // The payload stays checked out of the mapping until it is
                    // handed back. Returning without this leaks the mapping one
                    // transaction at a time, until the process can no longer
                    // receive anything at all.
                    try freeBuffer(data.data.ptr.buffer)
                    return reply

                default:
                    throw BinderError.unexpectedReturn(element.command)
                }
            }
        }
    }

    /// One `BINDER_WRITE_READ`: hand over pending commands, take back returns.
    func talkWithDriver(
        _ commands: inout CommandStream,
        into readBuffer: UnsafeMutableBufferPointer<UInt8>
    ) throws(BinderError) -> [UInt8] {
        let staged = UnsafeMutableBufferPointer<UInt8>
            .allocate(capacity: Swift.max(commands.count, 1))
        defer { staged.deallocate() }
        _ = staged.initialize(fromContentsOf: commands.bytes)

        var transaction = WriteReadTransaction()
        transaction.write_size = binder_size_t(commands.count)
        transaction.write_consumed = 0
        transaction.write_buffer = binder_uintptr_t(UInt(bitPattern: staged.baseAddress))
        transaction.read_size = binder_size_t(readBuffer.count)
        transaction.read_consumed = 0
        transaction.read_buffer = binder_uintptr_t(UInt(bitPattern: readBuffer.baseAddress))

        do {
            try device.handle.inputOutput(&transaction)
        } catch {
            throw BinderError.system(error)
        }

        // Anything the driver took must not be sent again. It reports this
        // separately from write_size precisely because it is allowed to take
        // less than was offered.
        let consumed = Int(transaction.write_consumed)
        if consumed >= commands.count {
            commands = CommandStream()
        } else if consumed > 0 {
            commands.removeFirst(consumed)
        }

        let count = Int(transaction.read_consumed)
        guard count <= readBuffer.count else {
            throw BinderError.replyOutOfBounds
        }
        return Array(UnsafeRawBufferPointer(rebasing: UnsafeRawBufferPointer(readBuffer)[0 ..< count]))
    }

    /// Copy a reply's payload out of the mapped buffer.
    ///
    /// The driver hands back a pointer into the mapping rather than a copy, so
    /// the bytes are valid only until the buffer is released. Copying here
    /// means a returned ``Parcel`` outlives the transaction that produced it,
    /// which is what a caller expects of a value type.
    func copyReply(_ data: binder_transaction_data) throws(BinderError) -> Parcel {
        let size = Int(data.data_size)
        guard size >= 0 else {
            throw BinderError.replyOutOfBounds
        }
        guard size > 0 else {
            return Parcel()
        }

        let start = UInt(data.data.ptr.buffer)
        let mapping = UInt(bitPattern: buffer.address)
        // The payload must lie inside the region we mapped. A descriptor
        // pointing outside it would mean reading unmapped memory, so it is
        // refused rather than trusted — this is data from another process.
        guard start >= mapping,
              start &+ UInt(size) <= mapping &+ UInt(buffer.size) else {
            throw BinderError.replyOutOfBounds
        }

        guard let pointer = UnsafeRawPointer(bitPattern: start) else {
            throw BinderError.replyOutOfBounds
        }
        return Parcel(bytes: Array(UnsafeRawBufferPointer(start: pointer, count: size)))
    }

    /// Hand a received buffer back to the driver.
    func freeBuffer(_ pointer: binder_uintptr_t) throws(BinderError) {
        var commands = CommandStream()
        commands.append(.freeBuffer, payload: pointer)

        let readBuffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: 256)
        defer { readBuffer.deallocate() }
        readBuffer.initialize(repeating: 0)

        // Sent on its own rather than batched onto the next transaction:
        // holding it back would keep the mapping checked out indefinitely if
        // the caller never transacts again.
        _ = try talkWithDriver(&commands, into: readBuffer)
    }
}

internal extension CommandStream {

    /// Drop commands the driver has already consumed.
    mutating func removeFirst(_ count: Int) {
        self = CommandStream(bytes: Array(bytes.dropFirst(count)))
    }
}
