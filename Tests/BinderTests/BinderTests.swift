import Testing
import CBinder
@testable import Binder

@Suite
struct BinderTests {
    
    @Test func binderType() async throws {
        #expect(BinderType.binder.rawValue == BINDER_TYPE_BINDER)
        #expect(BinderType(rawValue: UInt32(BINDER_TYPE_BINDER)) == .binder)
    }
}

