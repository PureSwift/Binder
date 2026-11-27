//
//  NestedBufferTests.swift
//  Binder
//

import CBinder
import Testing

@testable import Binder

@Suite
struct NestedBufferTests {

    /// A top-level buffer returns its object index, which a child names as its
    /// parent. The index is into the offsets array, counting every object, not
    /// only buffers.
    @Test func topLevelBufferReturnsItsObjectIndex() {
        var parcel = Parcel()
        parcel.append(RemoteObject(handle: 1))       // object 0
        let outer = parcel.append(buffer: [0, 0, 0, 0, 0, 0, 0, 0])  // object 1
        #expect(outer == 1)
    }

    /// A child buffer carries the parent flag, the parent index, and the offset
    /// within the parent where the driver writes its address. Getting any of
    /// the three wrong sends the driver to the wrong place, or has it treat a
    /// nested buffer as top-level and never relocate it into the parent.
    @Test func nestedBufferCarriesParentLinkage() {
        var parcel = Parcel()
        // A parent whose payload has an 8-byte hole at offset 0 for the child's
        // pointer.
        let parent = parcel.append(buffer: [UInt8](repeating: 0, count: 8))
        parcel.append(buffer: [1, 2, 3], parent: parent, parentOffset: 0)

        // Decode the child descriptor, the second buffer object.
        let childOffset = parcel.objectOffsets.last!
        let child = parcel.bytes[childOffset...]
            .withUnsafeBytes { $0.loadUnaligned(as: binder_buffer_object.self) }

        #expect(child.hdr.type == BinderType.pointer.rawValue)
        #expect((child.flags & 0x01) == 0x01)          // BINDER_BUFFER_FLAG_HAS_PARENT
        #expect(child.parent == binder_size_t(parent))
        #expect(child.parent_offset == 0)
        #expect(child.length == 3)
    }

    /// A top-level buffer has no parent, so the flag stays clear — otherwise the
    /// driver would look for a parent that is not there.
    @Test func topLevelBufferHasNoParentFlag() {
        var parcel = Parcel()
        parcel.append(buffer: [1, 2, 3])
        let object = parcel.bytes.withUnsafeBytes {
            $0.loadUnaligned(as: binder_buffer_object.self)
        }
        #expect((object.flags & 0x01) == 0)
        #expect(object.parent == 0)
        #expect(object.parent_offset == 0)
    }

    /// Both buffers count toward the parcel's object offsets and its reserved
    /// size, parent and child alike.
    @Test func bothBuffersAreTrackedAndReserved() {
        var parcel = Parcel()
        let parent = parcel.append(buffer: [UInt8](repeating: 0, count: 8))   // -> 8
        parcel.append(buffer: [1, 2, 3], parent: parent, parentOffset: 0)     // -> 8

        #expect(parcel.objectOffsets.count == 2)
        #expect(parcel.buffersSize == 16)
        #expect(parcel.hasBuffers)
    }

    /// The shape of a hidl_vec<hidl_string> with two elements: an outer buffer
    /// of two 16-byte string structs, each with a child buffer holding its
    /// characters, linked at the offset of that struct's pointer field.
    @Test func laysOutAVectorOfStrings() {
        // Two hidl_string structs, 16 bytes each: a pointer (8) and a size (8),
        // pointer at the start of each. Placeholders for the pointers.
        var parcel = Parcel()
        let vector = parcel.append(buffer: [UInt8](repeating: 0, count: 32))

        // First element's characters, pointer at offset 0 of the vector.
        parcel.append(buffer: Array("ab".utf8), parent: vector, parentOffset: 0)
        // Second element's characters, pointer at offset 16.
        parcel.append(buffer: Array("cde".utf8), parent: vector, parentOffset: 16)

        #expect(parcel.objectOffsets.count == 3)
        // 32 (aligned) + 8 ("ab"→8) + 8 ("cde"→8).
        #expect(parcel.buffersSize == 48)

        // Both children name the vector as parent, at their own offsets.
        let children = parcel.objectOffsets.dropFirst().map { offset in
            parcel.bytes[offset...].withUnsafeBytes {
                $0.loadUnaligned(as: binder_buffer_object.self)
            }
        }
        #expect(children.allSatisfy { $0.parent == binder_size_t(vector) })
        #expect(children.map(\.parent_offset) == [0, 16])
    }
}
