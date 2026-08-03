//
//  MappedBuffer.swift
//  Binder
//

import SystemPackage

// mmap/munmap/sysconf come from the platform C library, which is a different
// module on each. Android is the point of this library, so its Bionic module
// has to be here — without it `canImport(Glibc)` is false on Android and none
// of these symbols resolve. The module is spelled `Android` on the swift.org
// Android SDK and `Bionic` on some toolchains, so both are covered.
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Android)
import Android
#elseif canImport(Bionic)
import Bionic
#elseif canImport(Darwin)
import Darwin
#endif

/// The region of memory the driver delivers incoming transactions into.
///
/// Binder does not copy transaction payloads into a buffer the caller supplies.
/// It writes them into a mapping the caller established up front, and hands
/// back pointers into that mapping. So the mapping is not an optimisation that
/// can be added later: until it exists the driver has nowhere to put a reply,
/// and every transaction fails.
///
/// The mapping is read-only by design. Userspace never writes here — outgoing
/// data travels in the write buffer of a `BINDER_WRITE_READ` ioctl, and the
/// kernel is the only writer of this region. Asking for `PROT_WRITE` fails.
///
/// Ownership: the mapping lives exactly as long as the ``Binder`` that made it,
/// which is why this is a non-copyable type that unmaps on `deinit` rather than
/// something a caller could duplicate.
internal struct MappedBuffer: ~Copyable {

    /// The start of the mapping.
    internal let address: UnsafeMutableRawPointer

    /// The length of the mapping, needed again to unmap it.
    internal let size: Int

    private init(address: UnsafeMutableRawPointer, size: Int) {
        self.address = address
        self.size = size
    }

    deinit {
        // Nothing useful can be done if this fails, and throwing is not
        // possible from deinit. A failure here means the address or length no
        // longer describes a mapping, which is a bug in this type rather than
        // a runtime condition.
        assert(munmap(address, size) == 0, "Unable to unmap binder buffer")
    }
}

internal extension MappedBuffer {

    /// The size libbinder maps, and therefore the size the driver and every
    /// service on the other end expect.
    ///
    /// One megabyte less two pages. The subtraction is not decoration: the
    /// kernel accounts its own overhead inside the mapping, and a process that
    /// asks for a round megabyte gets less usable space than services assume.
    static var defaultSize: Int {
        (1 * 1024 * 1024) - (Int(sysconf(Int32(_SC_PAGESIZE))) * 2)
    }

    /// Map a binder device's transaction buffer.
    ///
    /// - Parameters:
    ///   - fileDescriptor: an open binder device.
    ///   - size: bytes to map, defaulting to ``defaultSize``.
    static func map(
        _ fileDescriptor: FileDescriptor,
        size: Int = MappedBuffer.defaultSize
    ) throws(Errno) -> MappedBuffer {
        // MAP_NORESERVE because the mapping is large and almost never fully
        // used; reserving swap for all of it would charge every binder client
        // a megabyte of commit it will not touch.
        let address = mmap(
            nil,
            size,
            PROT_READ,
            MAP_PRIVATE | MAP_NORESERVE,
            fileDescriptor.rawValue,
            0
        )

        guard let address, address != MAP_FAILED else {
            throw Errno(rawValue: errno)
        }

        return MappedBuffer(address: address, size: size)
    }
}
