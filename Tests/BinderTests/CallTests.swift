//
//  CallTests.swift
//  Binder
//

import CBinder
import Testing

@testable import Binder

/// The call helpers, exercised as a full round trip between the two sides.
///
/// The value they add is that the envelope — interface token, exception header,
/// reader positioning — is written once rather than at every method. So the
/// tests drive both halves through the helpers and check that a request built by
/// `call`'s framing decodes through `arguments`, and a reply built by `reply`
/// decodes through what `call` leaves the caller.
@Suite
struct CallTests {

    // MARK: - Request framing

    /// `call` writes the interface token before the caller's arguments, so a
    /// request it builds is what `arguments` expects to read.
    @Test func callFramesARequestThatArgumentsCanRead() throws {
        // The request half of RemoteProxy.call, without a connection: the same
        // parcel it would build.
        var request = Parcel()
        request.appendInterfaceToken("com.example.IThing")
        request.append(Int32(7))
        request.append("widget")

        // The serving half.
        let transaction = LocalObject.Transaction(
            code: 1,
            request: request,
            flags: .acceptFds,
            senderProcessID: 1,
            senderUserID: 1000
        )
        var reader = try transaction.arguments(interface: "com.example.IThing")
        #expect(try reader.readInt32() == 7)
        #expect(try reader.readString() == "widget")
        #expect(reader.isAtEnd)
    }

    /// A request for the wrong interface is rejected before any argument is
    /// read, and distinctly from a build-marker mismatch.
    @Test func argumentsRejectsTheWrongInterface() {
        var request = Parcel()
        request.appendInterfaceToken("com.example.IOther")
        request.append(Int32(1))

        let transaction = LocalObject.Transaction(
            code: 1, request: request, flags: [],
            senderProcessID: 1, senderUserID: 1000
        )
        #expect(throws: ParcelError.wrongInterface(
            expected: "com.example.IThing",
            found: "com.example.IOther"
        )) {
            try transaction.arguments(interface: "com.example.IThing")
        }
    }

    // MARK: - Reply framing

    /// `reply` writes the EX_NONE header before results; `resultReader` skips it
    /// so the caller reads results directly — the two are matched.
    @Test func replyAndResultReaderAreMatched() throws {
        let reply = Parcel.reply {
            $0.append("ok")
            $0.append(Int32(14))
        }

        var reader = reply.resultReader()
        #expect(try reader.readString() == "ok")
        #expect(try reader.readInt32() == 14)
        #expect(reader.isAtEnd)
    }

    /// The success header is present and zero.
    @Test func replyOpensWithANoneException() throws {
        let reply = Parcel.reply { $0.append(Int32(99)) }
        var reader = reply.reader()
        #expect(try reader.readInt32() == 0)   // EX_NONE
        #expect(try reader.readInt32() == 99)
    }

    @Test func exceptionReplyCarriesTheCode() throws {
        let reply = Parcel.exception(-8)   // EX_SERVICE_SPECIFIC
        var reader = reply.reader()
        #expect(try reader.readInt32() == -8)
    }

    // MARK: - A whole exchange through the helpers

    /// Build the request as `call` frames it, dispatch through a handler that
    /// uses `arguments` and `reply`, and read the result as `call` leaves it —
    /// the envelope handled entirely by the helpers on both sides.
    @Test func roundTripsThroughTheHelpers() throws {
        let registry = LocalObjectRegistry()
        let echo = registry.register(interfaceDescriptor: "com.example.IEcho") { transaction in
            do {
                var args = try transaction.arguments(interface: "com.example.IEcho")
                let message = try args.readString() ?? ""
                return Parcel.reply { $0.append("echo:\(message)") }
            } catch {
                return Parcel.exception(-1)
            }
        }

        // Request framing, as RemoteProxy.call builds it.
        var request = Parcel()
        request.appendInterfaceToken("com.example.IEcho")
        request.append("hi")

        let transaction = LocalObject.Transaction(
            code: 1, request: request, flags: .acceptFds,
            senderProcessID: 1, senderUserID: 1000
        )
        let reply = try #require(try echo.handler(transaction))

        // Result reading, as RemoteProxy.call leaves it: header consumed.
        var reader = reply.resultReader()
        #expect(try reader.readString() == "echo:hi")
        #expect(reader.isAtEnd)
    }

    /// A handler that rejects the interface answers with an exception the caller
    /// side surfaces, rather than a decode error.
    @Test func mismatchedInterfaceBecomesAnExceptionReply() throws {
        let registry = LocalObjectRegistry()
        let object = registry.register(interfaceDescriptor: "com.example.IEcho") { transaction in
            do {
                _ = try transaction.arguments(interface: "com.example.IEcho")
                return Parcel.reply()
            } catch {
                return Parcel.exception(-1)
            }
        }

        var request = Parcel()
        request.appendInterfaceToken("com.example.IWrong")

        let transaction = LocalObject.Transaction(
            code: 1, request: request, flags: [],
            senderProcessID: 1, senderUserID: 1000
        )
        let reply = try #require(try object.handler(transaction))
        var reader = reply.reader()
        #expect(try reader.readInt32() == -1)
    }
}
