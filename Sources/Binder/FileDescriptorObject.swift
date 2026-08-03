//
//  FileDescriptorObject.swift
//  Binder
//

import SystemPackage
import CBinder

/// Passing an open file descriptor through a transaction.
///
/// A file descriptor is a number that means something only inside one process's
/// table, so it cannot simply be written as an integer — the same number names
/// a different file, or nothing, in the receiver. Binder handles this the way it
/// handles object handles: the descriptor travels as a `binder_fd_object` at a
/// declared offset, and the driver `dup`s it into the receiving process,
/// yielding a new number there that refers to the same open file.
///
/// ## Ownership crosses
///
/// The sender keeps its descriptor; the driver duplicates rather than moves. The
/// **receiver** owns the number it is given and must close it — the driver
/// installs it and then forgets it, so a receiver that reads an fd out of a
/// parcel and drops it leaks a descriptor in its own table, one per transaction,
/// until it runs out. This is the one place decoding a parcel has a side effect
/// the reader is responsible for cleaning up.
///
/// ## Only if the transaction allows it
///
/// The driver refuses to translate a descriptor unless the transaction carries
/// `TF_ACCEPT_FDS` and the receiving node was created accepting them. A parcel
/// with a descriptor sent without `acceptFds` fails as a whole, rather than
/// arriving with the fd silently dropped.
public extension Parcel {

    /// Append an open file descriptor for the receiver to inherit a copy of.
    ///
    /// The descriptor is not consumed: the caller still owns and must close its
    /// own. What the receiver gets is a duplicate.
    mutating func append(fileDescriptor: FileDescriptor) {
        var object = binder_fd_object()
        object.hdr = binder_object_header(type: .fileDescriptor)
        object.pad_flags = 0
        object.fd = UInt32(bitPattern: fileDescriptor.rawValue)
        object.cookie = 0

        recordObjectOffset()
        append(bitPattern: object)
    }
}

public extension Parcel.Reader {

    /// Read a file descriptor the driver installed into this process.
    ///
    /// - Returns: the descriptor, or `nil` if the object at the cursor is not a
    ///   file descriptor.
    ///
    /// - Important: the returned descriptor is **owned by the caller**. The
    ///   driver has already placed it in this process's table; nothing else
    ///   will close it. Read it exactly once and close it when done, or it
    ///   leaks.
    mutating func readFileDescriptor() throws(ParcelError) -> FileDescriptor? {
        let slice = try read(count: MemoryLayout<binder_fd_object>.size)
        let object = Array(slice).withUnsafeBytes {
            $0.loadUnaligned(as: binder_fd_object.self)
        }

        guard object.hdr.type == BinderType.fileDescriptor.rawValue else {
            return nil
        }
        return FileDescriptor(rawValue: CInt(bitPattern: object.fd))
    }
}
