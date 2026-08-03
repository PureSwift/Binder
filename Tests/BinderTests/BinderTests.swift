import SystemPackage
import Testing
import CBinder
@testable import Binder

@Suite
struct BinderTests {

    /// Whether these tests can reach a binder device.
    ///
    /// Mocking is compiled in on macOS, so the device path is never touched
    /// there. Everywhere else these two tests need a real driver, and a Linux
    /// host without the binder module loaded has no /dev/binder — which is the
    /// common case for a development machine and for CI. Reporting that as a
    /// failure trains people to ignore a red suite; skipping says what is
    /// actually true.
    static var hasDevice: Bool {
        #if ENABLE_MOCKING
        return true
        #else
        guard let device = try? FileDescriptor.open(Binder.path, .readOnly) else {
            return false
        }
        try? device.close()
        return true
        #endif
    }

    @Test(.enabled(if: BinderTests.hasDevice, "no binder device at \(Binder.path)"))
    func device() throws {
        let device = try Binder()
        #if ENABLE_MOCKING
        #expect(device.handle.fileDescriptor.rawValue == 0)
        #endif
    }

    @Test(.enabled(if: BinderTests.hasDevice, "no binder device at \(Binder.path)"))
    func version() throws {
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
