import SystemPackage
import Socket
import CBinder

/// Binder Device
///
/// Maintains an open connection.
public struct Binder: ~Copyable {
    
    let handle: Handle
    
    /// Opens a connection to a Binder device.
    public init(
        path: String = Binder.path,
        isReadOnly: Bool = false
    ) throws(Errno) {
        self.handle = try .open(path, isReadOnly: isReadOnly)
    }
    
    deinit {
        do {
            try handle.close()
        }
        catch {
            assertionFailure("Unable to close Binder device: \(error)")
        }
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
