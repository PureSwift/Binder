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
    ///   - target: the object to call. ``RemoteObject/contextManager`` is
    ///     always reachable; anything else has to be obtained from it first.
    ///   - code: the interface-defined transaction code.
    ///   - request: the payload.
    ///   - flags: `acceptFds` by default, matching libbinder. Adding `oneWay`
    ///     makes the call return as soon as the driver has taken the
    ///     transaction, with an empty parcel.
    ///
    /// - Returns: the reply parcel, copied out of the mapped buffer.
    ///
    ///   Any binder object in the reply arrives holding a **strong reference**
    ///   that this connection took on the caller's behalf. Adopt it with
    ///   ``adopt(_:)`` to have it released automatically, or release it by hand
    ///   with ``release(_:)``. Dropping the parcel without doing either leaks
    ///   the reference and keeps the target process alive.
    ///
    /// Blocks the calling thread. A synchronous transaction has no
    /// non-blocking form — the driver parks the thread until the peer replies —
    /// so this must not be called from a thread something else needs.
    func transact(
        with target: RemoteObject,
        code: UInt32,
        request: Parcel,
        flags: TransactionFlags = .acceptFds
    ) throws(BinderError) -> Parcel {
        // The driver reads the request through the pointers in
        // binder_transaction_data rather than from a copy, so the bytes and the
        // offsets both need addresses that stay put for the whole exchange. A
        // Swift array cannot promise that outside a `withUnsafe...` closure, and
        // a closure would put the blocking wait somewhere errors cannot be
        // typed, so both are staged in memory this function owns.
        let staged = UnsafeMutableBufferPointer<UInt8>
            .allocate(capacity: Swift.max(request.bytes.count, 1))
        defer { staged.deallocate() }
        _ = staged.initialize(fromContentsOf: request.bytes)

        // The driver rewrites handles only at the positions named here.
        let offsets = UnsafeMutableBufferPointer<binder_size_t>
            .allocate(capacity: Swift.max(request.objectOffsets.count, 1))
        defer { offsets.deallocate() }
        _ = offsets.initialize(
            fromContentsOf: request.objectOffsets.map { binder_size_t($0) }
        )

        // Out-of-line buffers live outside the parcel bytes, so each payload is
        // staged separately and its address written into its descriptor. The
        // staged buffers must outlive the ioctl, so they are freed only after
        // the exchange, not on the way out of this scope.
        var stagedBuffers: [UnsafeMutableBufferPointer<UInt8>] = []
        defer { stagedBuffers.forEach { $0.deallocate() } }
        for buffer in request.scatterGatherBuffers {
            let payload = UnsafeMutableBufferPointer<UInt8>
                .allocate(capacity: Swift.max(buffer.payload.count, 1))
            _ = payload.initialize(fromContentsOf: buffer.payload)
            stagedBuffers.append(payload)

            // Overwrite the placeholder pointer in the descriptor's `buffer`
            // field, at offset 8 within the binder_buffer_object.
            let address = binder_uintptr_t(UInt(bitPattern: payload.baseAddress))
            withUnsafeBytes(of: address) { source in
                for index in 0 ..< source.count {
                    staged[buffer.offset + Self.bufferObjectPointerOffset + index] = source[index]
                }
            }
        }

        var data = binder_transaction_data()
        data.target.handle = target.handle
        data.cookie = 0
        data.code = code
        data.flags = flags.rawValue
        data.data_size = binder_size_t(request.bytes.count)
        data.offsets_size = binder_size_t(
            request.objectOffsets.count * MemoryLayout<binder_size_t>.size
        )
        data.data.ptr.buffer = binder_uintptr_t(UInt(bitPattern: staged.baseAddress))
        data.data.ptr.offsets = binder_uintptr_t(UInt(bitPattern: offsets.baseAddress))

        var commands = CommandStream()
        if request.hasBuffers {
            // BC_TRANSACTION_SG wraps the same transaction with the total space
            // the driver must reserve for the out-of-line buffers.
            var scatterGather = binder_transaction_data_sg()
            scatterGather.transaction_data = data
            scatterGather.buffers_size = binder_size_t(request.buffersSize)
            commands.append(.transactionSg, payload: scatterGather)
        } else {
            commands.append(.transaction, payload: data)
        }

        return try waitForResponse(commands, isOneWay: flags.contains(.oneWay))
    }

    /// Offset of the `buffer` pointer within a `binder_buffer_object`.
    ///
    /// Named rather than literal because it is written into staged bytes by
    /// hand, where a wrong value corrupts the descriptor silently.
    fileprivate static var bufferObjectPointerOffset: Int { 8 }
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
                    // Acquiring and freeing go out together, acquires first.
                    //
                    // The driver ties the reference it granted for each object
                    // in this reply to the buffer, and drops it in
                    // binder_transaction_buffer_release. So a handle decoded
                    // from the reply is already dead if the buffer went back
                    // first — and worse than dead, because the driver is free
                    // to reissue that number for a different object.
                    //
                    // The payload also stays checked out of the mapping until
                    // the free. Skipping it leaks the mapping one transaction
                    // at a time, until the process can no longer receive
                    // anything at all.
                    try adoptObjectsAndFree(in: reply, buffer: data.data.ptr.buffer)
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

        let payload = try copyFromMapping(
            at: data.data.ptr.buffer,
            count: size,
            as: UInt8.self
        )

        // The offsets array lives in the mapping too, alongside the payload.
        let offsetCount = Int(data.offsets_size) / MemoryLayout<binder_size_t>.size
        var offsets: [Int] = []
        if offsetCount > 0 {
            let raw = try copyFromMapping(
                at: data.data.ptr.offsets,
                count: offsetCount,
                as: binder_size_t.self
            )
            // An offset naming a position outside the payload would send the
            // object reader off the end, so they are filtered here rather than
            // trusted — this array came from another process.
            offsets = raw
                .map { Int($0) }
                .filter { $0 >= 0 && $0 + MemoryLayout<flat_binder_object>.size <= size }
        }

        // A received buffer object's descriptor points into the mapping, which
        // is about to be released, so each out-of-line payload is copied out
        // now — the same reason the inline bytes are. Without this a reader
        // would follow a dangling pointer into freed shared memory.
        var buffers: [(offset: Int, payload: [UInt8])] = []
        for offset in offsets {
            guard offset + MemoryLayout<binder_buffer_object>.size <= size else { continue }
            let descriptor = Array(payload[offset ..< offset + MemoryLayout<binder_buffer_object>.size])
                .withUnsafeBytes { $0.loadUnaligned(as: binder_buffer_object.self) }
            guard descriptor.hdr.type == BinderType.pointer.rawValue else { continue }

            let length = Int(descriptor.length)
            let data = try copyFromMapping(at: descriptor.buffer, count: length, as: UInt8.self)
            buffers.append((offset: offset, payload: data))
        }

        return Parcel(bytes: payload, objectOffsets: offsets, scatterGatherBuffers: buffers)
    }

    /// Copy a run of values out of the mapped region, bounds-checked.
    ///
    /// Every descriptor checked here arrives from another process, so none of
    /// it is trusted: a pointer outside the mapping would mean reading unmapped
    /// memory, and is refused rather than clamped.
    private func copyFromMapping<T>(
        at address: binder_uintptr_t,
        count: Int,
        as type: T.Type
    ) throws(BinderError) -> [T] {
        let size = count * MemoryLayout<T>.size
        let start = UInt(address)
        let mapping = UInt(bitPattern: buffer.address)

        guard count >= 0,
              start >= mapping,
              start &+ UInt(size) <= mapping &+ UInt(buffer.size),
              let pointer = UnsafeRawPointer(bitPattern: start) else {
            throw BinderError.replyOutOfBounds
        }

        let raw = UnsafeRawBufferPointer(start: pointer, count: size)
        return (0 ..< count).map {
            raw.loadUnaligned(fromByteOffset: $0 * MemoryLayout<T>.size, as: T.self)
        }
    }

    /// Take a strong reference to each object in a reply, then hand the buffer
    /// back.
    ///
    /// One command stream, acquires ahead of the free, because the ordering is
    /// the whole point: the driver applies them in the order it consumes them,
    /// and the free is what drops the references the acquires are replacing.
    func adoptObjectsAndFree(
        in reply: Parcel,
        buffer pointer: binder_uintptr_t
    ) throws(BinderError) {
        var commands = CommandStream()
        for object in reply.objects {
            commands.append(.acquire, payload: object.handle)
        }
        commands.append(.freeBuffer, payload: pointer)

        let readBuffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: 256)
        defer { readBuffer.deallocate() }
        readBuffer.initialize(repeating: 0)

        // Sent now rather than batched onto the next transaction: holding it
        // back would keep the mapping checked out indefinitely if the caller
        // never transacts again.
        _ = try talkWithDriver(&commands, into: readBuffer)
    }
}

internal extension CommandStream {

    /// Drop commands the driver has already consumed.
    mutating func removeFirst(_ count: Int) {
        self = CommandStream(bytes: Array(bytes.dropFirst(count)))
    }
}
