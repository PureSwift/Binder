//
//  Parcel.swift
//  Binder
//

/// A binder parcel: the serialised payload of a transaction.
///
/// The layout is Android's, because the process on the other end is Android's.
/// Three rules govern all of it:
///
/// - Every write is padded to a 4-byte boundary, and the padding is zeroed.
///   `Parcel.cpp` does this by masking the trailing word; appending zero bytes
///   is the same thing.
/// - Values are written in the **host's** byte order, not a fixed one. A parcel
///   is shared memory between two processes on one machine, never a network
///   format, so `memcpy` semantics are what the other side expects.
/// - `Bool`, `Int8` and `UTF16.CodeUnit` are all widened to `Int32` on the
///   wire. There is no one-byte encoding of a scalar in a parcel.
///
/// `Int64` is the trap in that scheme: it occupies 8 bytes but is only ever
/// 4-byte aligned, because nothing pads to 8. Reading it as an aligned 64-bit
/// load is undefined behaviour on the receiving side, and it is why this type
/// copies bytes rather than binding memory.
public struct Parcel: Equatable, Hashable, Sendable {

    /// The serialised bytes, including any trailing padding.
    public private(set) var bytes: [UInt8]

    /// An empty parcel.
    public init() {
        self.bytes = []
    }

    /// A parcel wrapping bytes already received from the driver.
    public init(bytes: [UInt8]) {
        self.bytes = bytes
    }
}

// MARK: - Layout

public extension Parcel {

    /// The number of bytes written so far.
    var count: Int {
        bytes.count
    }

    var isEmpty: Bool {
        bytes.isEmpty
    }

    /// Round a length up to the next 4-byte boundary.
    ///
    /// `PAD_SIZE_UNSAFE` in `Parcel.cpp`.
    static func paddedSize(_ length: Int) -> Int {
        (length + 3) & ~3
    }
}

// MARK: - Writing

public extension Parcel {

    /// Append a value's raw bytes, padded out to a 4-byte boundary.
    ///
    /// Host byte order, matching the `memcpy` in `Parcel::writeAligned`.
    mutating func append<T>(bitPattern value: T) {
        withUnsafeBytes(of: value) { bytes.append(contentsOf: $0) }
        pad()
    }

    mutating func append(_ value: Int32) {
        append(bitPattern: value)
    }

    /// Append a 64-bit integer.
    ///
    /// Occupies 8 bytes at 4-byte alignment. Nothing aligns a parcel to 8, so a
    /// reader must not assume it can load this as an aligned `Int64`.
    mutating func append(_ value: Int64) {
        append(bitPattern: value)
    }

    /// Append a boolean, widened to `Int32` as `Parcel::writeBool` does.
    mutating func append(_ value: Bool) {
        append(Int32(value ? 1 : 0))
    }

    /// Append a signed byte, widened to `Int32` as `Parcel::writeByte` does.
    ///
    /// Note this costs four bytes on the wire, not one. For a run of bytes use
    /// ``append(bytes:)``, which does not widen.
    mutating func append(byte value: Int8) {
        append(Int32(value))
    }

    /// Append a UTF-16 code unit, widened to `Int32` as `Parcel::writeChar`.
    mutating func append(character value: UTF16.CodeUnit) {
        append(Int32(value))
    }

    /// Append a string in Android's `String16` encoding.
    ///
    /// A length in **UTF-16 code units** — not bytes, and not characters —
    /// followed by that many code units plus a NUL terminator, padded to 4.
    /// The terminator is included in the bytes but not in the length, and the
    /// receiver validates that it is there.
    mutating func append(_ value: String) {
        let units = Array(value.utf16)
        append(Int32(units.count))
        for unit in units {
            withUnsafeBytes(of: unit) { bytes.append(contentsOf: $0) }
        }
        withUnsafeBytes(of: UTF16.CodeUnit(0)) { bytes.append(contentsOf: $0) }
        pad()
    }

    /// Append a null string, which is a length of `-1` and nothing else.
    ///
    /// Distinct from the empty string, which writes a length of `0` and a
    /// terminator. A reader can tell them apart and the difference is
    /// meaningful to AIDL, so it is not collapsed here.
    mutating func appendNullString() {
        append(Int32(-1))
    }

    /// Append a length-prefixed run of bytes, not widened.
    mutating func append(bytes value: [UInt8]) {
        append(Int32(value.count))
        bytes.append(contentsOf: value)
        pad()
    }

    /// Append a null byte array, which is a length of `-1`.
    mutating func appendNullBytes() {
        append(Int32(-1))
    }

    /// Zero-fill up to the next 4-byte boundary.
    private mutating func pad() {
        let padded = Parcel.paddedSize(bytes.count)
        bytes.append(contentsOf: repeatElement(0, count: padded - bytes.count))
    }
}

// MARK: - Errors

/// A parcel could not be decoded.
public enum ParcelError: Error, Equatable, Hashable, Sendable {

    /// The parcel ended before the requested value did.
    ///
    /// Reached whenever a reader is pointed at a reply that is shorter than the
    /// interface says it should be — a version mismatch between the two sides,
    /// most often.
    case endOfParcel

    /// A length prefix was negative where null is not permitted, or large
    /// enough that reading it would run past the end.
    case invalidLength(Int32)

    /// A `String16` was not NUL-terminated.
    ///
    /// Android treats this as a security event rather than a plain decode
    /// failure, because it means the length prefix and the payload disagree.
    case unterminatedString
}

// MARK: - Reading

public extension Parcel {

    /// A cursor over a parcel's contents.
    ///
    /// A separate type rather than a mutating position on `Parcel` so that a
    /// received parcel stays immutable while it is being decoded, and so two
    /// readers over one parcel cannot interfere.
    struct Reader: Equatable, Hashable, Sendable {

        internal let bytes: [UInt8]

        /// The offset of the next byte to be read.
        public private(set) var offset: Int

        internal init(bytes: [UInt8]) {
            self.bytes = bytes
            self.offset = 0
        }

        /// Whether every byte has been consumed.
        ///
        /// Padding counts as consumed, so a fully-decoded parcel reports true.
        public var isAtEnd: Bool {
            offset >= bytes.count
        }

        /// The number of bytes not yet read.
        public var remaining: Int {
            bytes.count - offset
        }
    }

    /// A cursor positioned at the start of this parcel.
    func reader() -> Reader {
        Reader(bytes: bytes)
    }
}

public extension Parcel.Reader {

    /// Consume `length` bytes, plus whatever padding follows them.
    ///
    /// The padding is stepped over here rather than by each caller, because
    /// forgetting it desynchronises the cursor and every subsequent read
    /// returns plausible garbage rather than failing.
    mutating func read(count length: Int) throws(ParcelError) -> ArraySlice<UInt8> {
        let padded = Parcel.paddedSize(length)
        guard length >= 0, offset + padded <= bytes.count else {
            throw ParcelError.endOfParcel
        }
        let value = bytes[offset ..< offset + length]
        offset += padded
        return value
    }

    /// Read a value's raw bytes in host order.
    mutating func read<T>(bitPattern type: T.Type) throws(ParcelError) -> T {
        let slice = try read(count: MemoryLayout<T>.size)
        return Array(slice).withUnsafeBytes { $0.loadUnaligned(as: T.self) }
    }

    mutating func readInt32() throws(ParcelError) -> Int32 {
        try read(bitPattern: Int32.self)
    }

    /// Read a 64-bit integer.
    ///
    /// Loaded unaligned on purpose: the value sits at 4-byte alignment and an
    /// aligned load would be undefined behaviour.
    mutating func readInt64() throws(ParcelError) -> Int64 {
        try read(bitPattern: Int64.self)
    }

    /// Read a boolean.
    ///
    /// Any non-zero value is true, matching how the Java and native readers
    /// treat it. A sender is not obliged to normalise to 1.
    mutating func readBool() throws(ParcelError) -> Bool {
        try readInt32() != 0
    }

    /// Read a signed byte from its widened `Int32` encoding.
    mutating func readByte() throws(ParcelError) -> Int8 {
        Int8(truncatingIfNeeded: try readInt32())
    }

    /// Read a UTF-16 code unit from its widened `Int32` encoding.
    mutating func readCharacter() throws(ParcelError) -> UTF16.CodeUnit {
        UTF16.CodeUnit(truncatingIfNeeded: try readInt32())
    }

    /// Read a string in Android's `String16` encoding.
    ///
    /// Returns `nil` for a null string, which is encoded as a length of `-1`
    /// and is distinct from the empty string.
    mutating func readString() throws(ParcelError) -> String? {
        let length = try readInt32()
        guard length != -1 else { return nil }
        guard length >= 0, length < Int32.max else {
            throw ParcelError.invalidLength(length)
        }

        // The terminator is on the wire but not in the length.
        let count = Int(length) + 1
        let slice = try read(count: count * MemoryLayout<UTF16.CodeUnit>.size)

        var units = [UTF16.CodeUnit]()
        units.reserveCapacity(count)
        Array(slice).withUnsafeBytes { buffer in
            for index in 0 ..< count {
                units.append(buffer.loadUnaligned(
                    fromByteOffset: index * MemoryLayout<UTF16.CodeUnit>.size,
                    as: UTF16.CodeUnit.self
                ))
            }
        }

        guard units.last == 0 else {
            throw ParcelError.unterminatedString
        }
        return String(decoding: units.dropLast(), as: UTF16.self)
    }

    /// Read a length-prefixed run of bytes.
    ///
    /// Returns `nil` for a null array, encoded as a length of `-1`.
    mutating func readBytes() throws(ParcelError) -> [UInt8]? {
        let length = try readInt32()
        guard length != -1 else { return nil }
        guard length >= 0 else { throw ParcelError.invalidLength(length) }
        return Array(try read(count: Int(length)))
    }
}
