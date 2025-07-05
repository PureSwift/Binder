//
//  Version.swift
//  Binder
//
//  Created by Alsey Coleman Miller on 7/5/25.
//

import CBinder

public typealias BinderVersion = binder_version

// MARK: - RawRepresentable

extension BinderVersion: @retroactive RawRepresentable {
    
    public init(rawValue: __s32) {
        self.init(protocol_version: rawValue)
    }
    
    public var rawValue: RawValue {
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
