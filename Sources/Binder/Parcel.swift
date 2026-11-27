/// Errors reported while encoding or decoding an Android Binder parcel.
public enum ParcelError: Error, Equatable, Sendable {
    case invalidPosition(Int)
    case truncated
    case invalidLength(Int32)
    case invalidString
    case invalidInterfaceHeader(Int32)
    case interfaceMismatch(expected: String, actual: String?)
    case remoteException(code: Int32, message: String?, serviceCode: Int32?)
}

/// The byte payload and cursor for a kernel Binder parcel.
public struct Parcel: Sendable {
    public private(set) var bytes: [UInt8]
    public private(set) var dataPosition = 0

    public var dataSize: Int { bytes.count }
    public var dataAvailable: Int { dataSize - dataPosition }

    public init(bytes: [UInt8] = []) {
        self.bytes = bytes
    }

    public mutating func setDataPosition(_ position: Int) throws {
        guard (0...dataSize).contains(position) else { throw ParcelError.invalidPosition(position) }
        dataPosition = position
    }

    public mutating func writeInt32(_ value: Int32) { writeInteger(value) }
    public mutating func writeInt64(_ value: Int64) { writeInteger(value) }
    public mutating func writeFloat(_ value: Float) { writeInteger(value.bitPattern) }
    public mutating func writeDouble(_ value: Double) { writeInteger(value.bitPattern) }
    public mutating func writeBool(_ value: Bool) { writeInt32(value ? 1 : 0) }

    public mutating func readInt32() throws -> Int32 { try readInteger() }
    public mutating func readInt64() throws -> Int64 { try readInteger() }
    public mutating func readFloat() throws -> Float { try Float(bitPattern: readInteger()) }
    public mutating func readDouble() throws -> Double { try Double(bitPattern: readInteger()) }
    public mutating func readBool() throws -> Bool { try readInt32() != 0 }

    public mutating func writeString16(_ value: String?) throws {
        guard let value else {
            writeInt32(-1)
            return
        }
        guard let count = Int32(exactly: value.utf16.count) else { throw ParcelError.invalidLength(.max) }
        writeInt32(count)
        for unit in value.utf16 { writeInteger(unit) }
        writeInteger(UInt16(0))
        if count.isMultiple(of: 2) { writeInteger(UInt16(0)) }
    }

    public mutating func readString16() throws -> String? {
        let count = try readInt32()
        if count == -1 { return nil }
        guard count >= 0 else { throw ParcelError.invalidLength(count) }
        let totalUnits = Int(count) + (count.isMultiple(of: 2) ? 2 : 1)
        guard totalUnits <= dataAvailable / 2 else { throw ParcelError.truncated }

        var units: [UInt16] = []
        units.reserveCapacity(Int(count))
        for _ in 0..<count { units.append(try readInteger()) }
        let terminator: UInt16 = try readInteger()
        guard terminator == 0 else { throw ParcelError.invalidString }
        if count.isMultiple(of: 2) { dataPosition += 2 }
        return String(decoding: units, as: UTF16.self)
    }

    public mutating func writeInterfaceToken(
        _ descriptor: String, strictModePolicy: Int32 = 0, workSourceUID: Int32 = -1
    ) throws {
        writeInt32(strictModePolicy | .min)
        writeInt32(workSourceUID)
        writeInt32(Self.systemHeader)
        try writeString16(descriptor)
    }

    public mutating func enforceInterface(_ descriptor: String) throws {
        _ = try readInt32() // StrictMode policy
        _ = try readInt32() // WorkSource UID
        let header = try readInt32()
        guard header == Self.systemHeader else { throw ParcelError.invalidInterfaceHeader(header) }
        let actual = try readString16()
        guard actual?.utf16.elementsEqual(descriptor.utf16) == true else {
            throw ParcelError.interfaceMismatch(expected: descriptor, actual: actual)
        }
    }

    public mutating func writeNoException() {
        writeInt32(0)
    }

    public mutating func readException() throws {
        var code = try readInt32()
        if code == -127 { // AppOps header followed by the usual exception code.
            try skipSizedHeader()
            code = try readInt32()
        }
        if code == -128 { // StrictMode header occupies the success status.
            try skipSizedHeader()
            return
        }
        guard code != 0 else { return }
        let message = try readString16()
        try skipSizedHeader() // Remote stack trace, if present.
        let serviceCode = code == -8 ? try readInt32() : nil
        if code == -9 { try skipSizedHeader() }
        throw ParcelError.remoteException(code: code, message: message, serviceCode: serviceCode)
    }

    private static let systemHeader: Int32 = 0x5359_5354 // SYST

    private mutating func skipSizedHeader() throws {
        let start = dataPosition
        let size = try readInt32()
        if size == 0 { return }
        guard size >= 4, size.isMultiple(of: 4) else { throw ParcelError.invalidLength(size) }
        guard Int(size) <= dataSize - start else { throw ParcelError.truncated }
        dataPosition = start + Int(size)
    }

    private mutating func writeInteger<T: FixedWidthInteger>(_ value: T) {
        var wire = value.littleEndian
        withUnsafeBytes(of: &wire) { buffer in
            let end = dataPosition + buffer.count
            bytes.replaceSubrange(dataPosition..<min(end, bytes.count), with: buffer)
            dataPosition = end
        }
    }

    private mutating func readInteger<T: FixedWidthInteger>() throws -> T {
        let size = MemoryLayout<T>.size
        guard size <= dataAvailable else { throw ParcelError.truncated }
        let value = bytes.withUnsafeBytes { buffer in
            buffer.loadUnaligned(fromByteOffset: dataPosition, as: T.self)
        }
        dataPosition += size
        return T(littleEndian: value)
    }
}
