//
//  DriverCommandProtocol.swift
//  Binder
//
//  Created by Alsey Coleman Miller on 7/5/25.
//

import CBinder

public typealias DriverCommandProtocol = binder_driver_command_protocol

extension DriverCommandProtocol {
    
    static var transaction: DriverCommandProtocol { BC_TRANSACTION }
    
    static var reply: DriverCommandProtocol { BC_REPLY }
}
