//
//  DriverCommandProtocol.swift
//  Binder
//
//  Created by Alsey Coleman Miller on 7/5/25.
//

import CBinder

public typealias DriverCommandProtocol = binder_driver_command_protocol

public extension DriverCommandProtocol {
    
    static var transaction: DriverCommandProtocol { BC_TRANSACTION }
    static var reply: DriverCommandProtocol { BC_REPLY }
    static var acquireResult: DriverCommandProtocol { BC_ACQUIRE_RESULT }
    static var freeBuffer: DriverCommandProtocol { BC_FREE_BUFFER }
    static var incRefs: DriverCommandProtocol { BC_INCREFS }
    static var acquire: DriverCommandProtocol { BC_ACQUIRE }
    static var release: DriverCommandProtocol { BC_RELEASE }
    static var decRefs: DriverCommandProtocol { BC_DECREFS }
    static var incRefsDone: DriverCommandProtocol { BC_INCREFS_DONE }
    static var acquireDone: DriverCommandProtocol { BC_ACQUIRE_DONE }
    static var attemptAcquire: DriverCommandProtocol { BC_ATTEMPT_ACQUIRE }
    static var registerLooper: DriverCommandProtocol { BC_REGISTER_LOOPER }
    static var enterLooper: DriverCommandProtocol { BC_ENTER_LOOPER }
    static var exitLooper: DriverCommandProtocol { BC_EXIT_LOOPER }
    static var requestDeathNotification: DriverCommandProtocol { BC_REQUEST_DEATH_NOTIFICATION }
    static var clearDeathNotification: DriverCommandProtocol { BC_CLEAR_DEATH_NOTIFICATION }
    static var deadBinderDone: DriverCommandProtocol { BC_DEAD_BINDER_DONE }
    static var transactionSg: DriverCommandProtocol { BC_TRANSACTION_SG }
    static var replySg: DriverCommandProtocol { BC_REPLY_SG }
    static var requestFreezeNotification: DriverCommandProtocol { BC_REQUEST_FREEZE_NOTIFICATION }
    static var clearFreezeNotification: DriverCommandProtocol { BC_CLEAR_FREEZE_NOTIFICATION }
    static var freezeNotificationDone: DriverCommandProtocol { BC_FREEZE_NOTIFICATION_DONE }
}
