import SystemPackage
import Testing
import CBinder
@testable import Binder

@Suite
struct BinderTests {
    
    @Test func device() throws {
        let device = try openDevice()
        #if ENABLE_MOCKING
        #expect(device.handle.fileDescriptor.rawValue == 0)
        #endif
    }
    
    @Test func version() throws {
        #if ENABLE_MOCKING
        let device = try openDevice() // open mock device
        let version = try device.version
        #else
        let version = try BinderVersion.current
        #endif
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
        #expect("\([.oneWay, .rootObject] as TransactionFlags)" == "[.oneWay, .rootObject]")
    }
    
    @Test func flatBinderObjectFlags() throws {
        
        #expect(([] as FlatBinderObjectFlags).isEmpty)
        #expect(([] as FlatBinderObjectFlags).description == "[]")
        #expect(([] as FlatBinderObjectFlags).rawValue == 0)
        #expect(FlatBinderObjectFlags.priorityMask == FLAT_BINDER_FLAG_PRIORITY_MASK)
        #expect(FlatBinderObjectFlags.acceptsFDs.rawValue == FLAT_BINDER_FLAG_ACCEPTS_FDS.rawValue)
        #expect("\([.inheritRT, .txnSecurityCtx] as FlatBinderObjectFlags)" == "[.inheritRT, .txnSecurityCtx]")
    }
}

private extension BinderTests {
    
    func openDevice(path: String = Binder.path, isReadOnly: Bool = false) throws(Errno) -> Binder {
        #if ENABLE_MOCKING
        .mock
        #else
        try Binder(path: path, isReadOnly: isReadOnly)
        #endif
    }
}
