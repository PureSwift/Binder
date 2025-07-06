import Testing
import CBinder
@testable import Binder

@Suite
struct BinderTests {
    
    @Test func readBinderVersion() throws {
        let version = try BinderVersion.current
        print("Binder version:", version)
        #expect(version == BinderVersion.compiledVersion)
    }
    
    @Test func binderType() throws {
        #expect(BinderType.binder.rawValue == BINDER_TYPE_BINDER)
        #expect(BinderType(rawValue: BinderType.RawValue(BINDER_TYPE_BINDER)) == .binder)
        #expect(BinderType(rawValue: 0) == nil)
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
    
    @Test func binderCommand() throws {
        
        #expect(BinderCommand.version.rawValue == numericCast(BINDER_VERSION))
        #expect(BinderCommand.writeRead.rawValue == numericCast(BINDER_WRITE_READ))
        #expect("\(BinderCommand.threadExit)" == "threadExit")
        #expect(BinderCommand(rawValue: 0) == nil)
    }
    
    @Test func transactionFlags() throws {
        
        #expect(([] as TransactionFlags).isEmpty)
        #expect(([] as TransactionFlags).description == "[]")
        #expect(([] as TransactionFlags).rawValue == 0)
        #expect(TransactionFlags.oneWay == TF_ONE_WAY)
        #expect(BinderCommand.writeRead.rawValue == numericCast(BINDER_WRITE_READ))
        #expect("\([.oneWay, .rootObject] as TransactionFlags)" == "[.oneWay, .rootObject]")
    }
}
