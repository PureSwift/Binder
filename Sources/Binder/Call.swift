//
//  Call.swift
//  Binder
//

/// Making and answering AIDL calls without repeating the envelope.
///
/// Every AIDL method call has the same shape around its arguments: write the
/// interface token, transact, read the reply's exception header, and only then
/// read the return values. Every method that skips or misorders any of that
/// fails in the same hard-to-place way — the callee rejects a request whose
/// token is missing, and a client that forgets to consume the exception header
/// reads it as the first field of the result. These helpers write that envelope
/// once so a caller supplies only what differs: the transaction code and the
/// arguments.
public extension RemoteProxy {

    /// Call a method and return a reader positioned at the first result.
    ///
    /// Writes the interface token, appends the caller's arguments, transacts,
    /// and consumes the reply's exception header — throwing
    /// ``BinderError/remoteException(_:)`` if it is non-zero. The returned
    /// reader is positioned exactly where the return values begin.
    ///
    /// - Parameters:
    ///   - code: the transaction code, offset from `FIRST_CALL_TRANSACTION`.
    ///   - interface: the descriptor the callee will check the token against.
    ///   - header: which build the callee belongs to; ``RPCHeader/system`` for
    ///     an Android container.
    ///   - arguments: appends the method's arguments, in declaration order.
    func call(
        _ code: UInt32,
        interface: String,
        header: RPCHeader = .system,
        _ arguments: (inout Parcel) -> Void = { _ in }
    ) throws(BinderError) -> Parcel.Reader {
        var request = Parcel()
        request.appendInterfaceToken(interface, header: header)
        arguments(&request)

        let reply = try transact(code: code, request: request)

        var reader = reply.reader()
        let exception: Int32
        do {
            exception = try reader.readInt32()
        } catch {
            throw BinderError.parcel(error)
        }
        guard exception == 0 else {
            throw BinderError.remoteException(exception)
        }
        return reader
    }

    /// Call a one-way method, which returns nothing.
    ///
    /// A one-way call carries no reply and therefore no exception header: the
    /// driver returns as soon as it has taken the transaction, and any failure
    /// on the callee's side is unobservable here by design. Do not use it where
    /// a result — or confirmation — is needed.
    func post(
        _ code: UInt32,
        interface: String,
        header: RPCHeader = .system,
        _ arguments: (inout Parcel) -> Void = { _ in }
    ) throws(BinderError) {
        var request = Parcel()
        request.appendInterfaceToken(interface, header: header)
        arguments(&request)

        _ = try transact(code: code, request: request, flags: [.acceptFds, .oneWay])
    }
}

// MARK: - Async

public extension RemoteProxy {

    /// Call a method and suspend until the reply arrives.
    ///
    /// The async counterpart of ``call(_:interface:header:_:)``. A `Parcel`
    /// value is returned rather than a `Reader` because a reader is a
    /// non-`Sendable` cursor; the caller opens one on the result. The exception
    /// header is already consumed, so the returned parcel's reader starts at the
    /// return values via ``resultReader()``.
    func call(
        _ code: UInt32,
        interface: String,
        header: RPCHeader = .system,
        _ arguments: @Sendable (inout Parcel) -> Void = { _ in }
    ) async throws(BinderError) -> Parcel {
        var request = Parcel()
        request.appendInterfaceToken(interface, header: header)
        arguments(&request)

        let reply = try await transact(code: code, request: request)

        var reader = reply.reader()
        let exception: Int32
        do {
            exception = try reader.readInt32()
        } catch {
            throw BinderError.parcel(error)
        }
        guard exception == 0 else {
            throw BinderError.remoteException(exception)
        }
        // The header is validated but the parcel is returned whole; the caller
        // reads results from resultReader(), which skips it again. Returning the
        // reader itself is not possible across the suspension because it is not
        // Sendable.
        return reply
    }
}

public extension Parcel {

    /// A reader positioned just past a reply's exception header.
    ///
    /// For use on the parcel returned by the async ``RemoteProxy/call(_:interface:header:_:)``,
    /// whose header has already been checked. Skips the leading `Int32` so the
    /// cursor starts at the return values.
    func resultReader() -> Reader {
        var reader = self.reader()
        _ = try? reader.readInt32()
        return reader
    }
}

// MARK: - Serving

public extension LocalObject.Transaction {

    /// Read and check the interface token at the front of this request.
    ///
    /// The counterpart of ``RemoteProxy/call(_:interface:header:_:)`` on the
    /// serving side: a handler calls this first to confirm the caller named the
    /// interface it implements, and receives a reader positioned at the
    /// arguments.
    ///
    /// - Returns: a reader positioned at the first argument.
    /// - Throws: ``ParcelError/interfaceMismatch(expected:found:)`` if the
    ///   caller's build marker differs, ``ParcelError/wrongInterface(expected:found:)``
    ///   if the descriptor names a different interface, or
    ///   ``ParcelError/endOfParcel`` if the request has no token — any of which
    ///   a handler should answer as a failed transaction rather than proceeding
    ///   to read arguments that are not there.
    func arguments(
        interface: String,
        header: RPCHeader = .system
    ) throws(ParcelError) -> Parcel.Reader {
        var reader = request.reader()
        let descriptor = try reader.readInterfaceToken(header: header)
        guard descriptor == interface else {
            throw ParcelError.wrongInterface(expected: interface, found: descriptor)
        }
        return reader
    }
}

// MARK: - Building a reply

public extension Parcel {

    /// A reply that carries a successful result.
    ///
    /// Writes the `EX_NONE` exception header every AIDL reply opens with, then
    /// runs the caller's closure to append the return values. A handler that
    /// returns a bare parcel without the header sends its first return value
    /// where the caller expects the exception, so this keeps them from being
    /// separated.
    static func reply(_ results: (inout Parcel) -> Void = { _ in }) -> Parcel {
        var parcel = Parcel()
        parcel.append(Int32(0))
        results(&parcel)
        return parcel
    }

    /// A reply that reports a service-specific error.
    ///
    /// The negative of a Binder exception code — `EX_SERVICE_SPECIFIC` and the
    /// like. A caller sees it as ``BinderError/remoteException(_:)``.
    static func exception(_ code: Int32) -> Parcel {
        var parcel = Parcel()
        parcel.append(code)
        return parcel
    }
}
