//
//  SocketDescriptor.swift
//  Binder
//
//  Created by Alsey Coleman Miller on 7/5/25.
//

import SystemPackage
import Socket
import CBinder

internal extension Binder.Handle {
    
    func inputOutput(_ value: inout BinderVersion) throws(Errno) {
        assert(value == BinderVersion(), "BinderVersion already initialized: \(value)")
        #if ENABLE_MOCKING
        value = .compiledVersion
        #else
        try fileDescriptor.inputOutput(&value)
        #endif
    }
}
