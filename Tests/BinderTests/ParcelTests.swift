//
//  ParcelTests.swift
//  Binder
//

import Testing

@testable import Binder

@Suite
struct ParcelTests {

    // MARK: - Layout

    @Test(arguments: [(0, 0), (1, 4), (2, 4), (3, 4), (4, 4), (5, 8), (7, 8), (8, 8), (9, 12)])
    func padsToFourByteBoundary(_ length: Int, _ expected: Int) {
        #expect(Parcel.paddedSize(length) == expected)
    }

    // MARK: - Scalars

    /// Expected bytes are written out rather than produced by the encoder, so
    /// the test fails if the encoding changes rather than agreeing with it.
    @Test func appendsInt32AsFourBytes() {
        var parcel = Parcel()
        parcel.append(Int32(1))
        #expect(parcel.bytes == [0x01, 0x00, 0x00, 0x00])
        #expect(parcel.count == 4)
    }

    @Test func appendsInt64AsEightBytes() {
        var parcel = Parcel()
        parcel.append(Int64(1))
        #expect(parcel.bytes == [0x01, 0, 0, 0, 0, 0, 0, 0])
    }

    /// Int64 sits at 4-byte alignment, never 8. If this ever pads to 8 the
    /// parcel silently desynchronises against every Android reader.
    @Test func doesNotAlignInt64ToEightBytes() throws {
        var parcel = Parcel()
        parcel.append(Int32(0x11111111))
        parcel.append(Int64(0x2222222233333333))
        #expect(parcel.count == 12)

        var reader = parcel.reader()
        #expect(try reader.readInt32() == 0x11111111)
        #expect(try reader.readInt64() == 0x2222222233333333)
        #expect(reader.isAtEnd)
    }

    /// Bool, Int8 and UTF-16 code units are all widened to Int32 on the wire.
    @Test func widensSmallScalarsToInt32() {
        var parcel = Parcel()
        parcel.append(true)
        parcel.append(byte: -1)
        parcel.append(character: 0x41)
        #expect(parcel.count == 12)
        #expect(Array(parcel.bytes.prefix(4)) == [0x01, 0x00, 0x00, 0x00])
        #expect(Array(parcel.bytes.dropFirst(4).prefix(4)) == [0xFF, 0xFF, 0xFF, 0xFF])
    }

    @Test func roundTripsScalars() throws {
        var parcel = Parcel()
        parcel.append(Int32.min)
        parcel.append(Int64.max)
        parcel.append(false)
        parcel.append(byte: Int8.min)
        parcel.append(character: 0xFFFF)

        var reader = parcel.reader()
        #expect(try reader.readInt32() == Int32.min)
        #expect(try reader.readInt64() == Int64.max)
        #expect(try reader.readBool() == false)
        #expect(try reader.readByte() == Int8.min)
        #expect(try reader.readCharacter() == 0xFFFF)
        #expect(reader.isAtEnd)
    }

    /// A sender is not obliged to normalise a boolean to 1.
    @Test func readsAnyNonZeroAsTrue() throws {
        var parcel = Parcel()
        parcel.append(Int32(42))
        var reader = parcel.reader()
        #expect(try reader.readBool() == true)
    }

    // MARK: - Strings

    /// Length in UTF-16 code units, then the units, then a NUL terminator that
    /// is not counted in the length, then padding.
    @Test func encodesString16WithTerminatorOutsideTheLength() {
        var parcel = Parcel()
        parcel.append("Hi")
        #expect(parcel.bytes == [
            0x02, 0x00, 0x00, 0x00,  // length: 2 code units
            0x48, 0x00,              // 'H'
            0x69, 0x00,              // 'i'
            0x00, 0x00,              // NUL terminator
            0x00, 0x00,              // padding to 12
        ])
    }

    @Test func encodesEmptyStringAsLengthZeroPlusTerminator() {
        var parcel = Parcel()
        parcel.append("")
        #expect(parcel.bytes == [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
    }

    /// Null and empty are different values on the wire and AIDL cares.
    @Test func distinguishesNullStringFromEmptyString() throws {
        var parcel = Parcel()
        parcel.appendNullString()
        parcel.append("")

        #expect(Array(parcel.bytes.prefix(4)) == [0xFF, 0xFF, 0xFF, 0xFF])

        var reader = parcel.reader()
        #expect(try reader.readString() == nil)
        #expect(try reader.readString() == "")
    }

    @Test(arguments: ["", "a", "ab", "abc", "hello world", "café", "日本語", "🙂"])
    func roundTripsStrings(_ value: String) throws {
        var parcel = Parcel()
        parcel.append(value)
        var reader = parcel.reader()
        #expect(try reader.readString() == value)
        #expect(reader.isAtEnd)
    }

    /// An emoji is one Character but two UTF-16 code units, and the length
    /// prefix counts code units.
    @Test func countsSurrogatePairsAsTwoCodeUnits() throws {
        var parcel = Parcel()
        parcel.append("🙂")
        var reader = parcel.reader()
        #expect(try reader.readInt32() == 2)
    }

    @Test func rejectsUnterminatedString() {
        // Length 1, then a code unit, then a non-zero where the terminator
        // should be.
        let parcel = Parcel(bytes: [0x01, 0, 0, 0, 0x41, 0x00, 0x42, 0x00])
        var reader = parcel.reader()
        #expect(throws: ParcelError.unterminatedString) { try reader.readString() }
    }

    // MARK: - Byte arrays

    /// Byte arrays are not widened; only the length prefix is.
    @Test func encodesByteArrayWithoutWidening() {
        var parcel = Parcel()
        parcel.append(bytes: [0xDE, 0xAD, 0xBE])
        #expect(parcel.bytes == [
            0x03, 0x00, 0x00, 0x00,
            0xDE, 0xAD, 0xBE,
            0x00,  // padding
        ])
    }

    @Test(arguments: [[], [0x01], [0x01, 0x02], [0x01, 0x02, 0x03], [0x01, 0x02, 0x03, 0x04]])
    func roundTripsByteArrays(_ value: [UInt8]) throws {
        var parcel = Parcel()
        parcel.append(bytes: value)
        var reader = parcel.reader()
        #expect(try reader.readBytes() == value)
        #expect(reader.isAtEnd)
    }

    @Test func distinguishesNullByteArrayFromEmpty() throws {
        var parcel = Parcel()
        parcel.appendNullBytes()
        parcel.append(bytes: [])

        var reader = parcel.reader()
        #expect(try reader.readBytes() == nil)
        #expect(try reader.readBytes() == [])
    }

    /// Padding must be zeroed, not left as whatever was in the buffer.
    /// Upstream masks the trailing word for the same reason.
    @Test func zeroesPaddingBytes() {
        var parcel = Parcel()
        parcel.append(bytes: [0xFF])
        #expect(parcel.bytes == [0x01, 0x00, 0x00, 0x00, 0xFF, 0x00, 0x00, 0x00])
    }

    // MARK: - Truncation

    @Test func reportsEndOfParcelRatherThanReturningGarbage() {
        let parcel = Parcel(bytes: [0x01, 0x00])
        var reader = parcel.reader()
        #expect(throws: ParcelError.endOfParcel) { try reader.readInt32() }
    }

    @Test func reportsEndOfParcelWhenStringRunsPastTheEnd() {
        // Claims 100 code units in an 8-byte parcel.
        let parcel = Parcel(bytes: [0x64, 0x00, 0x00, 0x00, 0x41, 0x00, 0x00, 0x00])
        var reader = parcel.reader()
        #expect(throws: ParcelError.endOfParcel) { try reader.readString() }
    }

    @Test func reportsInvalidLengthForNegativeByteArray() {
        let parcel = Parcel(bytes: [0xFE, 0xFF, 0xFF, 0xFF])
        var reader = parcel.reader()
        #expect(throws: ParcelError.invalidLength(-2)) { try reader.readBytes() }
    }

    /// A reader must not advance past a failed read, or a caller that catches
    /// and retries would see a cursor pointing into the middle of a value.
    @Test func leavesCursorUnmovedAfterFailedRead() {
        let parcel = Parcel(bytes: [0x01, 0x00])
        var reader = parcel.reader()
        #expect(throws: ParcelError.endOfParcel) { try reader.readInt32() }
        #expect(reader.offset == 0)
    }

    // MARK: - A realistic exchange

    /// The shape every Waydroid call has: a status header, then the payload.
    @Test func roundTripsAnAIDLStyleReply() throws {
        var reply = Parcel()
        reply.append(Int32(0))          // exception code: none
        reply.append("com.example")     // a returned string
        reply.append(Int32(7))
        reply.append(true)

        var reader = reply.reader()
        #expect(try reader.readInt32() == 0)
        #expect(try reader.readString() == "com.example")
        #expect(try reader.readInt32() == 7)
        #expect(try reader.readBool() == true)
        #expect(reader.isAtEnd)
    }
}
