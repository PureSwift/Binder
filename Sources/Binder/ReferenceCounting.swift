//
//  ReferenceCounting.swift
//  Binder
//

import CBinder

/// Reference counts on remote handles.
///
/// A handle is not a pointer the holder can keep indefinitely. The driver
/// maintains a per-process reference count for every handle it has issued, and
/// reclaims the handle — making it available for reuse by a *different* object —
/// once the count reaches zero. A handle held without a reference is therefore
/// worse than dangling: it may silently start addressing something else.
///
/// The counts are two, not one. A strong reference keeps the target object
/// alive; a weak reference only keeps the handle from being recycled, and can
/// be promoted to strong if the target is still there. This mirrors `sp<>` and
/// `wp<>` in libbinder.
///
/// ## Who owns what
///
/// When the driver delivers a transaction containing a binder object, it takes
/// a strong reference on the receiver's behalf and ties it to the *buffer* —
/// `binder_transaction_buffer_release` drops it when the buffer is handed back
/// with `BC_FREE_BUFFER`. So a handle read out of a reply is only valid until
/// that free, and anything wanting to keep it must take its own reference
/// first. ``BinderConnection`` does that automatically for every object in a
/// reply, before releasing the buffer; the resulting reference is what
/// ``RemoteProxy`` adopts and eventually releases.
public extension BinderConnection {

    /// Take a strong reference to a handle.
    ///
    /// Keeps the target object alive, not merely the handle.
    func acquire(_ object: RemoteObject) throws(BinderError) {
        try send(.acquire, handle: object.handle)
    }

    /// Drop a strong reference previously taken with ``acquire(_:)``.
    ///
    /// Releasing more times than acquired corrupts the driver's accounting for
    /// this process and will eventually invalidate an unrelated handle, so the
    /// pairing is worth keeping mechanical — see ``RemoteProxy``.
    func release(_ object: RemoteObject) throws(BinderError) {
        try send(.release, handle: object.handle)
    }

    /// Take a weak reference to a handle.
    ///
    /// Stops the handle being recycled but does not keep the target alive.
    func incrementWeak(_ object: RemoteObject) throws(BinderError) {
        try send(.incRefs, handle: object.handle)
    }

    /// Drop a weak reference previously taken with ``incrementWeak(_:)``.
    func decrementWeak(_ object: RemoteObject) throws(BinderError) {
        try send(.decRefs, handle: object.handle)
    }

    /// Send one reference-counting command.
    ///
    /// These carry a bare `__u32` handle and produce no reply, so there is
    /// nothing to wait for — the driver applies them as it consumes the write
    /// buffer.
    private func send(
        _ command: DriverCommandProtocol,
        handle: UInt32
    ) throws(BinderError) {
        var commands = CommandStream()
        commands.append(command, payload: handle)

        let readBuffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: 256)
        defer { readBuffer.deallocate() }
        readBuffer.initialize(repeating: 0)

        _ = try talkWithDriver(&commands, into: readBuffer)
    }
}
