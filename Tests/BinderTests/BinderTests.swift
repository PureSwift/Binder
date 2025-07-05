import Testing
import CBinder
@testable import Binder

@Suite
struct BinderTests {
    
    #if os(Android) || os(Linux)
    @Test func readBinderVersion() throws {
        let version = try BinderVersion.current
        print("Binder version:", version)
    }
    #endif
    
    @Test func binderType() throws {
        #expect(BinderType.binder.rawValue == BINDER_TYPE_BINDER)
        #expect(BinderType(rawValue: BinderType.RawValue(BINDER_TYPE_BINDER)) == .binder)
    }
    
    @Test func driverCommandProtocol() throws {
        #expect(DriverCommandProtocol.transaction == BC_TRANSACTION)
        #expect(DriverCommandProtocol.transaction.rawValue == BC_TRANSACTION.rawValue)
        #expect(DriverCommandProtocol.transaction.description == "BC_TRANSACTION")
        #expect(DriverCommandProtocol(rawValue: 0).description == "DriverCommandProtocol(rawValue: 0)")
    }
    
    @Test func driverReturnProtocol() throws {
        
        #expect(DriverReturnProtocol.error == BR_ERROR)
        #expect(DriverReturnProtocol.ok.rawValue == BR_OK.rawValue)
        #expect(DriverReturnProtocol.finished.description == "BR_FINISHED")
        #expect(DriverReturnProtocol(rawValue: 0).description == "DriverReturnProtocol(rawValue: 0)")
    }
}
