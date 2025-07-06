//
//  WriteReadTransaction.swift
//  Binder
//
//  Created by Alsey Coleman Miller on 7/5/25.
//

import SystemPackage
import Socket
import CBinder

public typealias WriteReadTransaction = binder_write_read

// MARK: - IOControlValue

extension WriteReadTransaction: @retroactive IOControlValue {
    
    public static var id: BinderCommand { .writeRead }
    
    public mutating func withUnsafeMutablePointer<Result>(_ body: (UnsafeMutableRawPointer) throws -> (Result)) rethrows -> Result {
        try Swift.withUnsafeMutableBytes(of: &self) { buffer in
            try body(buffer.baseAddress!)
        }
    }
}

// MARK: - Mock

#if ENABLE_MOCKING
internal extension WriteReadTransaction {
    
    nonisolated(unsafe) static var mock: WriteReadTransaction = WriteReadTransaction()
}
#endif

internal extension Binder.Handle {
    
    func inputOutput(_ value: inout WriteReadTransaction) throws(Errno) {
        #if ENABLE_MOCKING
        value = WriteReadTransaction.mock
        #else
        try fileDescriptor.inputOutput(&value)
        #endif
    }
}
