//
//  BinderConnection.swift
//  Binder
//

import SystemPackage
import Socket
import CBinder

/// A binder device that is ready to carry transactions.
///
/// Separate from ``Binder`` because opening the device and being able to *use*
/// it are different things. A bare ``Binder`` is an open file descriptor: enough
/// to ask the driver its protocol version, and nothing else. Transacting also
/// needs a mapped receive buffer, a protocol version that matches, and a
/// thread-pool bound the driver has been told about. Those are what this type
/// establishes, in the order libbinder's `ProcessState` establishes them:
///
/// 1. open the device
/// 2. read `BINDER_VERSION` and refuse to continue on a mismatch
/// 3. `BINDER_SET_MAX_THREADS`
/// 4. `mmap` the receive buffer
///
/// Keeping the two apart means ``BinderVersion/read(_:)`` does not have to map
/// a megabyte of address space to answer one ioctl, and it means a value of
/// this type cannot exist without a buffer behind it.
public struct BinderConnection: ~Copyable {

    /// The open device.
    internal let device: Binder

    /// The region the driver writes incoming transactions into.
    ///
    /// Never read directly by this type. It exists to be kept alive: the
    /// pointers a transaction hands back point into it, and unmapping it while
    /// a reply is outstanding invalidates them.
    internal let buffer: MappedBuffer

    /// The receive-buffer size libbinder maps, and therefore the size services
    /// on the other end are provisioned to expect.
    ///
    /// One megabyte less two pages — the kernel accounts its own overhead
    /// inside the mapping, so a round megabyte yields less usable space than
    /// callers assume.
    public static var defaultBufferSize: Int {
        MappedBuffer.defaultSize
    }

    /// Open a binder device and prepare it for transactions.
    ///
    /// - Parameters:
    ///   - path: the device to open, `/dev/binder` by default. Android also
    ///     exposes `/dev/hwbinder` and `/dev/vndbinder`, which speak the same
    ///     protocol on separate contexts.
    ///   - maxThreads: how many threads the driver may ask this process to
    ///     spawn to service incoming transactions.
    ///   - bufferSize: bytes of receive buffer to map.
    ///
    /// - Throws: `Errno.protocolNotSupported` if the driver's protocol version
    ///   differs from the one these headers were built against. Continuing
    ///   past that would put mismatched structures on the wire, so it is
    ///   refused here rather than failing confusingly at the first transaction.
    public init(
        path: String = Binder.path,
        maxThreads: UInt32 = Binder.defaultMaxThreads,
        bufferSize: Int = BinderConnection.defaultBufferSize
    ) throws(Errno) {
        let device = try Binder(path: path, mode: .readWrite)

        let version = try device.version
        guard version == .compiledVersion else {
            throw .protocolNotSupported
        }

        // Advisory: the driver logs and carries on if it refuses this, and so
        // does libbinder. A process that cannot raise the bound still works,
        // it just serialises incoming work.
        try? device.setMaxThreads(maxThreads)

        let buffer = try MappedBuffer.map(
            FileDescriptor(rawValue: device.handle.fileDescriptor.rawValue),
            size: bufferSize
        )

        self.device = device
        self.buffer = buffer
    }
}

public extension BinderConnection {

    /// The protocol version the driver reported when this connection opened.
    ///
    /// Always equal to ``BinderVersion/compiledVersion``; a mismatch would have
    /// prevented the connection from being created.
    var version: BinderVersion {
        .compiledVersion
    }

    /// The size of the mapped receive buffer.
    ///
    /// The upper bound on a single incoming transaction's payload. A service
    /// sending more than this gets a failed transaction, so it is worth knowing
    /// when sizing bulk transfers.
    var bufferSize: Int {
        buffer.size
    }
}
