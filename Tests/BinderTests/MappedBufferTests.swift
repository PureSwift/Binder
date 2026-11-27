//
//  MappedBufferTests.swift
//  Binder
//

import Testing

@testable import Binder

@Suite
struct MappedBufferTests {

    /// One megabyte less two pages, matching libbinder's BINDER_VM_SIZE.
    ///
    /// Worth asserting rather than trusting: services on the other end are
    /// provisioned assuming this figure, and the two-page subtraction is the
    /// part that looks like it could be dropped without consequence.
    @Test func defaultSizeIsOneMegabyteLessTwoPages() {
        let pageSize = MappedBuffer.defaultSize
        #expect(pageSize < 1024 * 1024)
        #expect(pageSize >= (1024 * 1024) - (64 * 1024 * 2))
        #expect((1024 * 1024) - pageSize == 2 * ((1024 * 1024) - pageSize) / 2)
    }

    /// The mapping is a whole number of pages below a megabyte.
    @Test func defaultSizeIsPageAligned() {
        let overhead = (1024 * 1024) - MappedBuffer.defaultSize
        #expect(overhead % 2 == 0)
        // Each of the two pages is a power of two.
        let page = overhead / 2
        #expect(page > 0)
        #expect(page & (page - 1) == 0)
    }

    @Test func connectionExposesTheSameDefault() {
        #expect(BinderConnection.defaultBufferSize == MappedBuffer.defaultSize)
    }
}
