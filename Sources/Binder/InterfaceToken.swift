//
//  InterfaceToken.swift
//  Binder
//

/// The four-character marker that opens every AIDL request.
///
/// The receiver compares this against its own build's value and rejects the
/// whole transaction on a mismatch — `Parcel::enforceInterface` logs "Mixing
/// copies of libbinder?" and returns false. So it is not decoration: send the
/// wrong one and every call fails identically, with a message that points at
/// library packaging rather than at the header.
///
/// Which value is right depends on the process being *talked to*, not on where
/// this code is compiled. A client on desktop Linux driving services inside an
/// Android container wants ``system``, because that is what those services were
/// built with. An off-Android libbinder would send ``unknown``, which is why a
/// naive port of libbinder's own logic fails against a real Android service.
public enum RPCHeader: Int32, Equatable, Hashable, Sendable, CaseIterable {

    /// `SYST` — the Android system image. The default, and what a container's
    /// services expect.
    case system

    /// `VNDR` — a vendor (VNDK) build.
    case vendor

    /// `RECO` — a recovery build.
    case recovery

    /// `UNKN` — kernel binder outside Android. What libbinder itself sends when
    /// built off-Android, and almost never what a real service accepts.
    case unknown
}

public extension RPCHeader {

    /// Pack four characters the way `B_PACK_CHARS` does.
    private static func packed(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> Int32 {
        Int32(bitPattern:
            (UInt32(a) << 24) | (UInt32(b) << 16) | (UInt32(c) << 8) | UInt32(d)
        )
    }

    /// The value written into the parcel.
    var value: Int32 {
        switch self {
        case .system:
            return Self.packed(0x53, 0x59, 0x53, 0x54)   // 'S','Y','S','T'
        case .vendor:
            return Self.packed(0x56, 0x4E, 0x44, 0x52)   // 'V','N','D','R'
        case .recovery:
            return Self.packed(0x52, 0x45, 0x43, 0x4F)   // 'R','E','C','O'
        case .unknown:
            return Self.packed(0x55, 0x4E, 0x4B, 0x4E)   // 'U','N','K','N'
        }
    }
}

public extension Parcel {

    /// The work-source value meaning "not propagating a work source".
    ///
    /// `IPCThreadState::kUnsetWorkSource`.
    static var unsetWorkSource: Int32 { -1 }

    /// Set unconditionally by `writeInterfaceToken`, so that a violation
    /// gathered on the callee's side can be reported back to the caller.
    ///
    /// `STRICT_MODE_PENALTY_GATHER`, which is `1 << 31` and therefore negative
    /// in the `Int32` the parcel carries.
    static var strictModePenaltyGather: Int32 { Int32(bitPattern: 1 << 31) }

    /// Open a request with the header every AIDL interface expects.
    ///
    /// Four fields in a fixed order: strict-mode policy, work source, the
    /// four-character marker, then the interface descriptor. A request that
    /// omits any of them is rejected before the callee looks at its arguments,
    /// which presents as a transaction failure rather than as a decode error
    /// and is correspondingly hard to place.
    ///
    /// - Parameters:
    ///   - descriptor: the interface name, e.g. `android.os.IServiceManager`.
    ///   - header: which build the callee belongs to.
    ///   - strictModePolicy: forwarded to the callee's thread state. Zero is
    ///     right for a caller that is not enforcing a policy of its own.
    ///   - workSource: the uid to attribute the work to, or
    ///     ``unsetWorkSource``.
    mutating func appendInterfaceToken(
        _ descriptor: String,
        header: RPCHeader = .system,
        strictModePolicy: Int32 = 0,
        workSource: Int32 = Parcel.unsetWorkSource
    ) {
        append(strictModePolicy | Parcel.strictModePenaltyGather)
        append(workSource)
        append(header.value)
        append(descriptor)
    }
}

public extension Parcel.Reader {

    /// Check that the request names the interface served by this endpoint.
    mutating func enforceInterface(
        _ descriptor: String, header: RPCHeader = .system
    ) throws(ParcelError) {
        let actual = try readInterfaceToken(header: header)
        guard actual?.utf16.elementsEqual(descriptor.utf16) == true else {
            throw .wrongInterface(expected: descriptor, found: actual)
        }
    }

    /// Read and check the header at the front of an incoming request.
    ///
    /// - Returns: the descriptor, if the marker matched.
    /// - Throws: ``ParcelError/interfaceMismatch(expected:found:)`` when the
    ///   marker disagrees, which means the two sides were built against
    ///   different binder configurations.
    mutating func readInterfaceToken(
        header: RPCHeader = .system
    ) throws(ParcelError) -> String? {
        _ = try readInt32()                      // strict-mode policy
        _ = try readInt32()                      // work source
        let marker = try readInt32()
        guard marker == header.value else {
            throw ParcelError.interfaceMismatch(expected: header.value, found: marker)
        }
        return try readString()
    }
}
