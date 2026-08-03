//
//  BufferObject.swift
//  Binder
//

import CBinder

/// Out-of-line buffers, the scatter-gather half of the protocol.
///
/// Most data goes inline in the parcel, copied as one block. A *buffer object*
/// is different: the parcel holds only a `binder_buffer_object` descriptor —
/// a pointer and a length — and the bytes it names live somewhere else. At send
/// time the driver copies each such region into a separate area of the
/// receiver's mapped space and rewrites the descriptor's pointer to land there.
///
/// This is how HIDL passes anything with its own storage: a `hidl_vec`, a
/// `hidl_string`, a fixed-size array behind a pointer. The vector's elements are
/// a buffer object; the struct that refers to them is inline and carries the
/// offset back to it. Waydroid reaches this whenever it talks to a hardware
/// (`@1.0::IFoo`) service rather than a plain AIDL one.
///
/// ## Why the payload has to be retained
///
/// The descriptor's pointer must be a valid address for the whole ioctl,
/// exactly like the parcel's own bytes. But unlike the inline data it points
/// *outside* the parcel, so the parcel has to keep the payload alive itself and
/// the real address cannot be written until send time — the bytes may move
/// before then. So ``append(buffer:)`` stores the payload and a placeholder
/// pointer, and the transaction path fills the pointer in once the payload is
/// staged at a fixed address.
public extension Parcel {

    /// A flag on a buffer object, mirroring `BINDER_BUFFER_FLAG_HAS_PARENT`.
    private static var bufferHasParent: UInt32 { 0x01 }

    /// Round up to an 8-byte boundary.
    ///
    /// Buffer payloads are copied into the receiver at pointer alignment, and
    /// `buffers_size` — the total the driver reserves — is the sum of the
    /// *aligned* lengths, not the raw ones. Reserving the raw sum would leave
    /// the driver short for all but the last buffer.
    internal static func bufferAlignedSize(_ length: Int) -> Int {
        (length + 7) & ~7
    }

    /// Append an out-of-line buffer.
    ///
    /// The bytes are copied into the parcel's own keeping and sent as a
    /// separate region the receiver reads through the buffer object's offset.
    /// The descriptor is recorded in ``objectOffsets`` like any object, so the
    /// driver processes it; the payload is recorded separately so the transaction
    /// path can stage it and fix up the pointer.
    ///
    /// Only top-level buffers are supported — a buffer that is not itself
    /// pointed at by another buffer. Nested buffers need the parent/parent_offset
    /// fields, which are left zero here.
    mutating func append(buffer bytes: [UInt8]) {
        var object = binder_buffer_object()
        object.hdr = binder_object_header(type: .pointer)
        object.flags = 0
        // Placeholder: the real address is written at send time, once the
        // payload has been staged somewhere that will not move.
        object.buffer = 0
        object.length = binder_size_t(bytes.count)
        object.parent = 0
        object.parent_offset = 0

        // Recorded in both: the descriptor is an object the driver processes
        // (so it goes in the offsets array), and its payload is out of line (so
        // the transaction path can stage it and fix up the pointer). Missing
        // the object offset would leave the driver never looking at the buffer
        // at all.
        recordBuffer(at: self.bytes.count, payload: bytes)
        recordObjectOffset()
        append(bitPattern: object)
    }

    /// Whether this parcel carries any out-of-line buffers, and so must be sent
    /// with `BC_TRANSACTION_SG` rather than `BC_TRANSACTION`.
    var hasBuffers: Bool {
        !scatterGatherBuffers.isEmpty
    }

    /// The total space the driver must reserve for this parcel's buffers.
    ///
    /// The sum of each payload's 8-aligned length, which is what
    /// `binder_transaction_data_sg.buffers_size` carries.
    var buffersSize: Int {
        scatterGatherBuffers.reduce(0) { $0 + Parcel.bufferAlignedSize($1.payload.count) }
    }
}

public extension Parcel.Reader {

    /// Read the payload of an out-of-line buffer.
    ///
    /// The descriptor sits inline at the cursor; the bytes it names were copied
    /// out of the mapping when the reply was received, so this returns them
    /// directly rather than following the descriptor's pointer — which by now
    /// refers to freed shared memory.
    ///
    /// - Returns: the payload, or `nil` if the object at the cursor is not a
    ///   buffer, or if its bytes were not captured (a buffer written locally
    ///   rather than received carries its payload out of band, not here).
    mutating func readBuffer(from parcel: Parcel) throws(ParcelError) -> [UInt8]? {
        // Peek the object header before committing to the 40-byte read. A
        // different object at the cursor is shorter than a buffer descriptor,
        // so reading blindly would either overrun the next value or fail with
        // endOfParcel on a short parcel. The type decides how much to consume.
        let position = offset
        guard position + MemoryLayout<binder_object_header>.size <= bytes.count else {
            throw ParcelError.endOfParcel
        }
        let type = bytes[position ..< position + MemoryLayout<UInt32>.size]
            .withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        guard type == BinderType.pointer.rawValue else {
            return nil
        }

        _ = try read(count: MemoryLayout<binder_buffer_object>.size)
        return parcel.scatterGatherBuffers.first { $0.offset == position }?.payload
    }
}
