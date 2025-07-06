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
        assert(rawValue != 0)
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
    
    /// Binder Protocol Version in NDK headers
    static var compiledVersion: BinderVersion {
        return .init(rawValue: BINDER_CURRENT_PROTOCOL_VERSION)
    }
    
    /// Read current Binder version from device.
    static var current: BinderVersion {
        get throws(Errno) {
            #if canImport(Darwin)
            compiledVersion
            #else
            try Self.read()
            #endif
        }
    }
}

public extension BinderVersion {
    
    static func read(
        _ path: String = Binder.path
    ) throws(Errno) -> BinderVersion {
        let device = try Binder(
            path: path,
            isReadOnly: true
        )
        return try device.version
    }
}

extension BinderVersion: @retroactive IOControlValue {
    
    public static var id: BinderCommand { .version }
    
    public mutating func withUnsafeMutablePointer<Result>(_ body: (UnsafeMutableRawPointer) throws -> (Result)) rethrows -> Result {
        try Swift.withUnsafeMutableBytes(of: &self) { buffer in
            try body(buffer.baseAddress!)
        }
    }
}
