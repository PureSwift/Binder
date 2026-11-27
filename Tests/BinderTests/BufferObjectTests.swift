//
//  BufferObjectTests.swift
//  Binder
//

import CBinder
import Testing

@testable import Binder

@Suite
struct BufferObjectTests {

    // MARK: - Layout

    /// binder_buffer_object is 40 bytes with the out-of-line pointer at offset
    /// 8. The transaction path writes that pointer into staged bytes by hand,
    /// so a shift here would corrupt every buffer silently.
    @Test func bufferObjectLayoutIsStable() {
        #expect(MemoryLayout<binder_buffer_object>.size == 40)
        #expect(MemoryLayout<binder_transaction_data_sg>.size
                == MemoryLayout<binder_transaction_data>.size
                 + MemoryLayout<binder_size_t>.size)
        #expect(DriverCommandProtocol.transactionSg.payloadSize
                == MemoryLayout<binder_transaction_data_sg>.size)
        #expect(DriverCommandProtocol.replySg.payloadSize
                == MemoryLayout<binder_transaction_data_sg>.size)
    }

    // MARK: - Writing

    /// A buffer descriptor is written inline as BINDER_TYPE_PTR, at a declared
    /// offset, with the payload held out of band and a placeholder pointer.
    @Test func writesADescriptorWithAPlaceholderPointer() {
        var parcel = Parcel()
        parcel.append(buffer: [1, 2, 3, 4, 5])

        #expect(parcel.hasBuffers)
        #expect(parcel.objectOffsets == [0])
        #expect(parcel.count == MemoryLayout<binder_buffer_object>.size)

        let object = parcel.bytes.withUnsafeBytes {
            $0.loadUnaligned(as: binder_buffer_object.self)
        }
        #expect(object.hdr.type == BinderType.pointer.rawValue)
        #expect(object.length == 5)
        // The pointer is filled in only at send time.
        #expect(object.buffer == 0)
    }

    /// The inline descriptor is fixed size; the payload does not inflate it.
    @Test func payloadDoesNotAffectTheInlineSize() {
        var small = Parcel()
        small.append(buffer: [0])
        var large = Parcel()
        large.append(buffer: [UInt8](repeating: 0, count: 4096))
        #expect(small.count == large.count)
    }

    /// A buffer object is not a remote reference, so reference-count enumeration
    /// must not turn it up — acquiring or releasing it would be meaningless.
    @Test func buffersAreNotRemoteObjects() {
        var parcel = Parcel()
        parcel.append(buffer: [1, 2, 3])
        #expect(parcel.objects.isEmpty)
    }

    // MARK: - buffers_size

    /// The reserved size is the sum of 8-aligned payload lengths, not the raw
    /// sum. Reserving the raw sum leaves the driver short for every buffer but
    /// the last.
    @Test func buffersSizeSumsAlignedLengths() {
        var parcel = Parcel()
        parcel.append(buffer: [UInt8](repeating: 0, count: 5))   // -> 8
        parcel.append(buffer: [UInt8](repeating: 0, count: 8))   // -> 8
        parcel.append(buffer: [UInt8](repeating: 0, count: 1))   // -> 8
        #expect(parcel.buffersSize == 24)
    }

    @Test func emptyBufferStillReservesNothingButCounts() {
        var parcel = Parcel()
        parcel.append(buffer: [])
        #expect(parcel.hasBuffers)
        #expect(parcel.buffersSize == 0)
    }

    @Test(arguments: [(0, 0), (1, 8), (7, 8), (8, 8), (9, 16), (16, 16), (17, 24)])
    func alignsToEightBytes(_ length: Int, _ expected: Int) {
        #expect(Parcel.bufferAlignedSize(length) == expected)
    }

    // MARK: - Mixed parcels

    /// A realistic HIDL-shaped request: an inline header, then a vector as a
    /// buffer. Both the object offset and the buffer are tracked, and a plain
    /// parcel without buffers is not sent down the SG path.
    @Test func tracksInlineDataAlongsideABuffer() {
        var parcel = Parcel()
        parcel.appendInterfaceToken("android.hardware.foo@1.0::IFoo")
        parcel.append(Int32(1))
        let headerSize = parcel.count
        parcel.append(buffer: [0xAA, 0xBB, 0xCC])

        #expect(parcel.hasBuffers)
        #expect(parcel.objectOffsets == [headerSize])
        #expect(parcel.buffersSize == 8)
    }

    @Test func plainParcelDoesNotUseScatterGather() {
        var parcel = Parcel()
        parcel.append(Int32(1))
        parcel.append("two")
        #expect(parcel.hasBuffers == false)
        #expect(parcel.buffersSize == 0)
    }

    // MARK: - Reading a received buffer

    /// A received parcel carries its buffer payloads out of band, since the
    /// descriptor's pointer refers to freed shared memory by the time a reader
    /// runs. readBuffer returns the captured bytes.
    @Test func readsAReceivedBufferPayload() throws {
        // Build the parcel the way copyReply does: a descriptor inline, the
        // payload captured separately at the same offset.
        var descriptorParcel = Parcel()
        descriptorParcel.append(buffer: [0xDE, 0xAD, 0xBE, 0xEF])
        let received = Parcel(
            bytes: descriptorParcel.bytes,
            objectOffsets: descriptorParcel.objectOffsets,
            scatterGatherBuffers: [(offset: 0, payload: [0xDE, 0xAD, 0xBE, 0xEF])]
        )

        var reader = received.reader()
        #expect(try reader.readBuffer(from: received) == [0xDE, 0xAD, 0xBE, 0xEF])
        #expect(reader.isAtEnd)
    }

    /// Reading a buffer where the object at the cursor is not one returns nil
    /// rather than a wrong answer.
    @Test func readBufferRejectsANonBuffer() throws {
        var parcel = Parcel()
        parcel.append(RemoteObject(handle: 1))
        var reader = parcel.reader()
        #expect(try reader.readBuffer(from: parcel) == nil)
    }

    /// Equality and hashing fold in the out-of-line payloads, so two parcels
    /// with identical descriptors but different buffer contents are distinct.
    @Test func equalityIncludesBufferPayloads() {
        var a = Parcel()
        a.append(buffer: [1, 2, 3])
        var b = Parcel()
        b.append(buffer: [1, 2, 3])
        var c = Parcel()
        c.append(buffer: [9, 9, 9])

        #expect(a == b)
        #expect(a != c)
    }
}
