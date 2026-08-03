//
//  BinderError.swift
//  Binder
//

import SystemPackage

/// Why a binder operation did not complete.
///
/// Deliberately not a flat list of errno values. A transaction can fail in ways
/// the file-descriptor layer has no vocabulary for — the peer process died, the
/// driver refused the transaction, the reply did not decode — and collapsing
/// those into `Errno` would leave a caller unable to tell "retry later" from
/// "this object is gone forever".
// Equatable but not Hashable: the `unexpectedReturn` case carries a
// `DriverReturnProtocol`, a C-imported type that auto-conforms to Hashable on
// newer Swift but not on 6.0.x, so requiring Hashable here fails to build
// there. Nothing hashes a BinderError, so Equatable is enough.
public enum BinderError: Error, Equatable, Sendable {

    /// An ioctl or other system call failed.
    case system(Errno)

    /// The reply could not be decoded.
    case parcel(ParcelError)

    /// The driver's return stream could not be walked.
    case stream(ReturnStreamError)

    /// `BR_DEAD_REPLY`: the process hosting the target is gone.
    ///
    /// Permanent for this handle. Retrying is pointless; the caller has to
    /// look the service up again.
    case deadObject

    /// `BR_FAILED_REPLY`: the driver rejected the transaction.
    ///
    /// Usually a malformed parcel, an unknown handle, or a payload larger than
    /// the receiver's mapped buffer.
    case failedTransaction

    /// `BR_FROZEN_REPLY`: the target process is frozen and cannot be reached.
    ///
    /// Unlike ``deadObject`` this is temporary — the process may thaw.
    case frozen

    /// `BR_ERROR`, carrying the driver's own status value.
    case driver(Int32)

    /// A return command arrived that has no meaning at this point in the
    /// exchange.
    ///
    /// Not folded into a generic failure because it means this code and the
    /// driver disagree about the protocol, which is a bug rather than a
    /// runtime condition.
    case unexpectedReturn(DriverReturnProtocol)

    /// The driver reported a reply larger than the buffer it was mapped into.
    ///
    /// Would mean reading outside the mapping, so it is refused rather than
    /// clamped.
    case replyOutOfBounds

    /// The callee threw, and the reply carries its exception code rather than
    /// the declared return value.
    ///
    /// A protocol-level outcome rather than a transport failure: the
    /// transaction itself succeeded.
    case remoteException(Int32)
}
