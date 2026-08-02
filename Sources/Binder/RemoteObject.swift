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
/// This type does **not** hold a reference count. libbinder acquires a strong
/// reference on every handle it hands out and releases it when the last `sp<>`
/// drops; nothing here does that yet, so a handle stays valid only as long as
/// whatever else in the system is keeping the object alive.
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
    /// Written as a `flat_binder_object` inline in the payload. The driver
    /// finds it through the parcel's offsets array and rewrites the handle for
    /// the receiving process — which is why this is not simply an integer, and
    /// why a parcel carrying one needs its offsets declared to the driver.
    ///
    /// - Note: offsets are not yet tracked, so a transaction carrying this will
    ///   not have the object translated. Sending an object is therefore not
    ///   supported end to end; the encoding is here because reading one back
    ///   needs the same layout.
    mutating func append(_ value: RemoteObject) {
        var object = flat_binder_object()
        object.hdr = binder_object_header(type: .handle)
        object.flags = FlatBinderObjectFlags.acceptsFDs.rawValue
        object.handle = value.handle
        object.cookie = 0
        append(bitPattern: object)
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
