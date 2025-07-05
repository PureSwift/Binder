//
//  BinderType.swift
//  Binder
//
//  Created by Alsey Coleman Miller on 7/5/25.
//

import Socket
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

// MARK: - IOControlID

extension BinderType: IOControlID { }

// MARK: - RawRepresentable

extension BinderType: RawRepresentable {
    
    public init?(rawValue: CUnsignedLong) {
        guard let value = Self.allCases.first(where: { $0.rawValue == rawValue }) else {
            return nil
        }
        self = value
    }
    
    public var rawValue: CUnsignedLong {
        switch self {
        case .binder:
            RawValue(BINDER_TYPE_BINDER)
        case .weakBinder:
            RawValue(BINDER_TYPE_WEAK_BINDER)
        case .handle:
            RawValue(BINDER_TYPE_HANDLE)
        case .weakHandle:
            RawValue(BINDER_TYPE_WEAK_HANDLE)
        case .fd:
            RawValue(BINDER_TYPE_FD)
        case .fda:
            RawValue(BINDER_TYPE_FDA)
        case .ptr:
            RawValue(BINDER_TYPE_PTR)
        }
    }
}

// MARK: - Extensions

public extension binder_object_header {
    
    init(type: BinderType) {
        self.init(type: numericCast(type.rawValue))
    }
}
