import SystemPackage
import Socket
import CBinder

/// Binder Device
///
/// Maintains an open connection.
public struct Binder: ~Copyable {
    
    internal let handle: Handle
    
    /// Opens a connection to a Binder device.
    public init(
        path: String = Binder.path,
        isReadOnly: Bool = false
    ) throws(Errno) {
        let handle = try Handle.open(path, isReadOnly: isReadOnly)
        self.init(handle: handle)
    }
    
    internal init(handle: Handle) {
        self.handle = handle
    }
    
    deinit {
        #if ENABLE_MOCKING
        assert(handle.fileDescriptor.rawValue == 0, "Not mock device")
        #else
        do {
            try handle.close()
        }
        catch {
            assertionFailure("Unable to close Binder device: \(error)")
        }
        #endif
    }
}

public extension Binder {
    
    /// Default Binder path
    static var path: String {
        "/dev/binder"
    }
}

internal extension Binder {
    
    struct Handle {
        
        let fileDescriptor: SocketDescriptor
    }
}

extension Binder.Handle {
    
    static func open(_ path: String = Binder.path, isReadOnly: Bool) throws(Errno) -> Binder.Handle {
        // Open /dev/binder using SystemPackage
        do {
            let fd = try FileDescriptor.open(path, .readOnly)
            let fileDescriptor = SocketDescriptor(rawValue: fd.rawValue)
            return Binder.Handle(fileDescriptor: fileDescriptor)
        }
        catch {
            throw error as! Errno
        }
    }
    
    consuming func close() throws(Errno) {
        try fileDescriptor.close()
    }
}

// MARK: - Mock

#if ENABLE_MOCKING

internal extension Binder {
    
    static var mock: Binder {
        Binder(handle: .mock)
    }
}

internal extension Binder.Handle {
    
    static var mock: Binder.Handle {
        .init(fileDescriptor: SocketDescriptor(rawValue: 0))
    }
}

#endif
