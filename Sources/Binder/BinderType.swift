//
//  BinderType.swift
//  Binder
//
//  Created by Alsey Coleman Miller on 7/5/25.
//

import CBinder

/// Android Binder Type
public enum BinderType: Equatable, Hashable, Sendable, CaseIterable {
    
    case binder
    case weakBinder
    case handle
    case weakHandle
    case fd
    case fda
    case ptr
}

// MARK: - RawRepresentable

extension BinderType: RawRepresentable {
    
    public init?(rawValue: UInt32) {
        guard let value = Self.allCases.first(where: { $0.rawValue == rawValue }) else {
            return nil
        }
        self = value
    }
    
    public var rawValue: UInt32 {
        switch self {
        case .binder:
            UInt32(BINDER_TYPE_BINDER)
        case .weakBinder:
            UInt32(BINDER_TYPE_WEAK_BINDER)
        case .handle:
            UInt32(BINDER_TYPE_HANDLE)
        case .weakHandle:
            UInt32(BINDER_TYPE_WEAK_HANDLE)
        case .fd:
            UInt32(BINDER_TYPE_FD)
        case .fda:
            UInt32(BINDER_TYPE_FDA)
        case .ptr:
            UInt32(BINDER_TYPE_PTR)
        }
    }
}

// MARK: - Extensions

public extension binder_object_header {
    
    init(type: BinderType) {
        self.init(type: type.rawValue)
    }
}
