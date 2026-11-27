# Binder

A Swift client for the Android Binder IPC driver (`/dev/binder`), talking the
same protocol as `libbinder` so it can call, and be called by, Android services
— on Android itself or on desktop Linux driving a container such as Waydroid.

Pure Swift, on `apple/swift-system` and `PureSwift/Socket`. No C++, no
`libbinder`.

## Status

The full protocol layer is implemented and unit-tested: the parcel wire format,
the `BINDER_WRITE_READ` command codec, transactions in both directions, the
service manager, reference counting, hosting local objects, a serving loop, and
death notifications.

**None of it has run against a real driver.** The test host has no binder
kernel module, so every ioctl path is reasoned from the kernel source and
`libbinder` rather than observed. The tests cover encoding, decoding, the object
registries and the loop's dispatch decisions — not the kernel conversation. Treat
this as protocol-complete and field-unproven.

## Calling a service

Every AIDL call has the same envelope around its arguments — interface token,
transact, exception header, then the results. The `call` helper writes that
envelope so a method supplies only its code and arguments:

```swift
let binder = try BinderConnection()

guard let activity = try binder.service(named: "activity") else { return }

var reader = try activity.call(1, interface: "android.app.IActivityManager") {
    $0.append("com.example")
}
let result = try reader.readString()   // reader starts at the results
```

The envelope is still there if you want it. The above is exactly:

```swift
var request = Parcel()
request.appendInterfaceToken("android.app.IActivityManager")
request.append("com.example")

let reply = try activity.transact(code: 1, request: request)
var reader = reply.reader()
let exception = try reader.readInt32()   // non-zero throws remoteException in call()
let result = try reader.readString()
```

`post` is the one-way form (no reply); `call` also has an `async` overload.

`transact`, `service`, `checkService` and `services` each have an `async`
overload. They are not natively asynchronous — a binder transaction blocks in the
driver until the peer replies — so the async forms move that blocking call off
the cooperative pool onto the connection's own queue. See
`Transaction+Async.swift` for what that costs.

A looked-up service is a `RemoteProxy`: it owns one strong reference and releases
it on `deinit`, so the driver's reference count and Swift's object graph stay in
step without manual `acquire`/`release`.

## Hosting a service

```swift
let thing = binder.makeLocalObject(interface: "com.example.IThing") { transaction in
    guard transaction.senderUserID == 1000 else {   // driver-supplied, unforgeable
        return Parcel.exception(-1)                  // EX_SECURITY
    }
    do {
        var args = try transaction.arguments(interface: "com.example.IThing")
        let name = try args.readString() ?? ""
        return Parcel.reply { $0.append("hello:\(name)") }
    } catch {
        return Parcel.exception(-1)
    }
}

try binder.addService(named: "com.example.thing", object: thing)

try binder.serve()   // blocks, dispatching incoming calls
```

`transaction.arguments(interface:)` reads and checks the interface token,
returning a reader at the first argument; `Parcel.reply` / `Parcel.exception`
write the reply's exception header for you.

Register before serving: a caller that finds the service first simply blocks
until the loop starts, rather than failing. Only `transaction.senderProcessID`
and `senderUserID` are trustworthy for a permission check — the driver fills them
in; everything in the request parcel is whatever the caller chose to write.

## Death notifications

The only race-free way to learn a peer has gone — a handle never becomes
detectably invalid on its own, and the driver may reissue a dead handle's number
for a different object.

```swift
let watch = try binder.notifyOnDeath(of: activity.object) {
    // runs on a serving thread
}
try binder.cancel(watch)   // confirmed by the driver, not retired locally
```

## Design

| Type | Role |
|---|---|
| `BinderConnection` | an open, mapped device; the entry point for everything |
| `Parcel` | the serialised payload — read and write, with object offsets tracked |
| `RemoteObject` / `RemoteProxy` | a handle, and an owning strong reference to one |
| `LocalObject` | an object this process hosts for others to call |
| `ServiceManager` | the context manager at handle 0 |
| `DeathNotification` | a standing watch on a remote object's process |
| `CommandStream` / `ReturnStream` | the `BC_*` / `BR_*` codec under `BINDER_WRITE_READ` |

The layering is deliberate. `Binder` is a bare open device — enough to read the
protocol version, nothing more. `BinderConnection` is the usable thing: it maps
the receive buffer, checks the version, and refuses to continue on a mismatch,
in the order `libbinder`'s `ProcessState` does. Deciding what an incoming command
requires (`action(for:)`) is kept separate from sending the response, so the part
where a serving loop actually goes wrong is a pure, testable function.

## Building

```sh
swift build
swift test
```

Requires Swift 6.0+. The two tests that need `/dev/binder` skip when it is
absent, so the suite passes on any host; the rest exercise the protocol layer
directly.

## Not yet implemented

- Arrays of file descriptors (`BINDER_TYPE_FDA`). Single descriptors
  (`BINDER_TYPE_FD`) and scatter-gather buffers, including nested ones, are
  supported.
- The freeze and node-debug maintenance ioctls (`BINDER_FREEZE`,
  `BINDER_GET_NODE_DEBUG_INFO`, `BINDER_GET_NODE_INFO_FOR_REF`).
- `serve()` cannot interrupt itself while parked in the driver; closing the
  connection is what ends a quiet loop.
