//
//  CommandStream.swift
//  Binder
//

import CBinder

/// The size of a command's payload, taken from the command code itself.
///
/// `BC_*` and `BR_*` are not small integers: each is a full `_IOC` value, and
/// the size of the structure that follows it in the stream is encoded in bits
/// 16-29 of that value by the same macros the kernel uses. Reading the size
/// back out means a payload length can never disagree with the kernel's idea of
/// it, which a hand-written table of sizes eventually would.
internal protocol DriverProtocolCommand {
    var rawValue: UInt32 { get }
}

internal extension DriverProtocolCommand {

    var payloadSize: Int {
        #if canImport(Darwin)
        // sys/ioccom.h uses a 13-bit size field; linux/ioctl.h uses 14. Binder
        // is a Linux driver, so this arm only matters to the macOS mock build.
        return Int((rawValue >> 16) & 0x1fff)
        #else
        return Int((rawValue >> 16) & 0x3fff)
        #endif
    }
}

extension DriverCommandProtocol: DriverProtocolCommand {}
extension DriverReturnProtocol: DriverProtocolCommand {}

/// A sequence of `BC_*` commands bound for the driver's write buffer.
///
/// A `BINDER_WRITE_READ` ioctl does not carry one command. It carries a byte
/// stream of them: each a 32-bit code, immediately followed by that command's
/// payload with no padding and no framing. The driver consumes as many as it
/// can and reports back how many bytes it took, which is why
/// ``WriteReadTransaction`` has a `write_consumed` field separate from
/// `write_size`.
public struct CommandStream: Equatable, Hashable, Sendable {

    /// The encoded stream.
    public private(set) var bytes: [UInt8]

    public init() {
        self.bytes = []
    }

    public var isEmpty: Bool {
        bytes.isEmpty
    }

    public var count: Int {
        bytes.count
    }
}

public extension CommandStream {

    /// Append a command that carries no payload, such as `BC_ENTER_LOOPER`.
    mutating func append(_ command: DriverCommandProtocol) {
        assert(command.payloadSize == 0, "\(command) carries a payload")
        appendRaw(command.rawValue)
    }

    /// Append a command and the structure that belongs to it.
    ///
    /// The payload goes in verbatim, in host layout. These structures are
    /// shared with the kernel by pointer elsewhere in the same protocol, so
    /// their in-memory form *is* the wire form.
    mutating func append<Payload>(_ command: DriverCommandProtocol, payload: Payload) {
        assert(
            command.payloadSize == MemoryLayout<Payload>.size,
            "\(command) expects \(command.payloadSize) bytes, got \(MemoryLayout<Payload>.size)"
        )
        appendRaw(command.rawValue)
        withUnsafeBytes(of: payload) { bytes.append(contentsOf: $0) }
    }

    private mutating func appendRaw(_ value: UInt32) {
        withUnsafeBytes(of: value) { bytes.append(contentsOf: $0) }
    }
}
