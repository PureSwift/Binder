//
//  RemoteObject.swift
//  Binder
//

import CBinder

/// A reference to an object living in another process.
///
/// Just a handle. The number is meaningful only to the driver and only for the
/// process that received it: the same remote object has different handles in
/// different processes, and a handle passed between processes as an integer
/// refers to nothing. The driver translates handles when a
/// ``flat_binder_object`` crosses a transaction boundary, which is why sending
/// one has to go through ``Parcel/append(_:)-(RemoteObject)`` rather than
/// writing the number.
///
/// This type is the plain value — it does **not** own a reference. A handle is
/// only valid while this process holds a reference to it, and the driver may
/// reissue the number for a different object once the count reaches zero, so a
/// bare `RemoteObject` kept across time can silently start addressing something
/// else. ``RemoteProxy`` is the owning form; this one is for parcelling,
/// comparison, and passing to ``BinderConnection/adopt(_:)``.
public struct RemoteObject: Equatable, Hashable, Sendable {

    /// The driver's handle for this object in this process.
    public let handle: UInt32

    public init(handle: UInt32) {
        self.handle = handle
    }
}

public extension RemoteObject {

    /// The context manager, which is always handle zero.
    ///
    /// Fixed by the protocol rather than discovered: a process has no way to
    /// look up the service manager, because looking anything up requires
    /// talking to it first.
    static var contextManager: RemoteObject {
        RemoteObject(handle: 0)
    }
}

// MARK: - Parcelling

public extension Parcel {

    /// Append a reference to a remote object.
    ///
    /// Written as a `flat_binder_object` inline in the payload, and its
    /// position recorded in ``objectOffsets``. The driver rewrites the handle
    /// for the receiving process, but only at positions the transaction names —
    /// it cannot find objects by scanning, since a payload is opaque bytes to
    /// it and an integer that happens to look like an object header would be
    /// indistinguishable from one. An object written without its offset
    /// recorded arrives as a number addressing something else entirely.
    mutating func append(_ value: RemoteObject) {
        var object = flat_binder_object()
        object.hdr = binder_object_header(type: .handle)
        object.flags = FlatBinderObjectFlags.acceptsFDs.rawValue
        object.handle = value.handle
        object.cookie = 0

        recordObjectOffset()
        append(bitPattern: object)
    }
}

public extension Parcel {

    /// Every binder object this parcel carries, in wire order.
    ///
    /// For a reply, these are the objects the driver translated into this
    /// process, each of which arrived holding a strong reference.
    var objects: [RemoteObject] {
        objectOffsets.compactMap { offset in
            let size = MemoryLayout<flat_binder_object>.size
            guard offset >= 0, offset + size <= bytes.count else { return nil }
            let object = Array(bytes[offset ..< offset + size])
                .withUnsafeBytes { $0.loadUnaligned(as: flat_binder_object.self) }
            guard let type = BinderType(rawValue: object.hdr.type) else { return nil }
            switch type {
            case .handle, .weakHandle:
                return RemoteObject(handle: object.handle)
            default:
                return nil
            }
        }
    }
}

public extension Parcel.Reader {

    /// Read a reference to a remote object.
    ///
    /// - Returns: the object, or `nil` if the sender wrote a null binder — a
    ///   `flat_binder_object` whose handle is zero and whose type is a binder
    ///   rather than a handle. A null binder is how a service manager says "no
    ///   such service", so it is a normal answer rather than an error.
    mutating func readObject() throws(ParcelError) -> RemoteObject? {
        let slice = try read(count: MemoryLayout<flat_binder_object>.size)
        let object = Array(slice).withUnsafeBytes {
            $0.loadUnaligned(as: flat_binder_object.self)
        }

        guard let type = BinderType(rawValue: object.hdr.type) else {
            return nil
        }
        switch type {
        case .handle, .weakHandle:
            return RemoteObject(handle: object.handle)
        default:
            // A local binder pointer, a file descriptor or a buffer. None of
            // those is a remote object reference, and guessing a handle out of
            // the union would produce a number that addresses something else.
            return nil
        }
    }
}
