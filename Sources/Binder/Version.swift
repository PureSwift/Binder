//
//  Version.swift
//  Binder
//
//  Created by Alsey Coleman Miller on 7/5/25.
//

import SystemPackage
import Socket
import CBinder

public typealias BinderVersion = binder_version

// MARK: - RawRepresentable

extension BinderVersion: @retroactive RawRepresentable {
    
    public init(rawValue: Int32) {
        self.init(protocol_version: rawValue)
    }
    
    public var rawValue: Int32 {
        protocol_version
    }
}

// MARK: - CustomStringConvertible

extension BinderVersion: @retroactive CustomStringConvertible {
    
    public var description: String {
        rawValue.description
    }
}

// MARK: - Equatable

extension BinderVersion: @retroactive Equatable {
    
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.protocol_version == rhs.protocol_version
    }
}

// MARK: - Hashable

extension BinderVersion: @retroactive Hashable {
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(protocol_version)
    }
}

// MARK: - IOCTL

public extension BinderVersion {
    
    static var current: BinderVersion {
        get throws(Errno) {
            try Self.read()
        }
    }
}

internal extension BinderVersion {
    
    static func read() throws(Errno) -> BinderVersion {
        // Open /dev/binder using SystemPackage
        let fileDescriptor: SocketDescriptor
        do {
            let fd = try FileDescriptor.open("/dev/binder", .readOnly)
            fileDescriptor = SocketDescriptor(rawValue: fd.rawValue)
        }
        catch {
            throw error as! Errno
        }
        // Ensure cleanup
        return try fileDescriptor.closeAfter { () throws(Errno) -> (BinderVersion) in
            var version = BinderVersion()
            //try fd.ioctl(raw: CUnsignedLong(BINDER_VERSION), mutablePointer: &version)
            try fileDescriptor.inputOutput(&version)
            return version
        }
    }
}

extension BinderVersion: @retroactive IOControlValue {
    
    public static var id: BinderType { .binder }
    
    public mutating func withUnsafeMutablePointer<Result>(_ body: (UnsafeMutableRawPointer) throws -> (Result)) rethrows -> Result {
        try Swift.withUnsafeMutableBytes(of: &self) { buffer in
            try body(buffer.baseAddress!)
        }
    }
}
