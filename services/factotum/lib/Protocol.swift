// SPDX-License-Identifier: BSD-3-Clause

// factotum's protocol (D75; todhchai's keyring, after Plan 9's
// factotum). An app starts a session with a key pattern and a role,
// giving the server's end of an `AuthSession` channel; it then asks the
// session what to do (`next`) and feeds it the peer's messages (`feed`),
// passing bytes between the session and its peer. The keys never leave
// factotum: the app gets the result, a session secret (or, for
// `proto=pass` alone, after the user has said yes, the password).
//
// A step that waits on the user (`needKey`, `needConfirm`) ends with the
// session's `answered` event: then ask `next` again.

import IPC
import Sys

@IPCLibrary(id: "todhchai.auth", version: 1)
public enum AuthIPC {
  public enum AuthError: Int32, IPCErrorCode, Sendable {
    /// No key matches, and the user didn't add one.
    case noKey = 1
    /// The user said no.
    case denied
    /// The app's manifest doesn't allow the pattern.
    case notAllowed
    /// A protocol or role factotum doesn't speak.
    case unsupported
    /// The peer broke or failed the protocol (`failure()` says how).
    case peer
    /// A call out of turn, or a malformed pattern.
    case invalid
  }

  public enum Role: UInt8, Sendable {
    case client = 1
    case server
  }

  public enum StepKind: UInt8, Sendable {
    /// Send `bytes` to the peer.
    case send = 1
    /// Feed the peer's next message.
    case need
    /// The user is being asked for a key matching `text`.
    case needKey
    /// The user is being asked to allow the key's use (`text` is the
    /// prompt's).
    case needConfirm
    /// Done: `user`, `peer` and `secret` are the result.
    case done
  }

  /// One step: its kind, and what goes with it.
  public struct Step: Equatable, Sendable {
    public var kind: StepKind
    public var bytes: [UInt8]
    public var text: String
    public var user: String
    public var peer: String
    public var secret: [UInt8]
    public init(kind: StepKind, bytes: [UInt8], text: String, user: String, peer: String, secret: [UInt8]) {
      self.kind = kind
      self.bytes = bytes
      self.text = text
      self.user = user
      self.peer = peer
      self.secret = secret
    }
  }

  public protocol Factotum {
    /// Starts a session for `pattern` (factotum's: `proto=scram-sha-256
    /// server=mail.example user?`) in `role`: `session` is the server's
    /// end of an `AuthSession`.
    func startSession(pattern: String, role: Role, session: consuming Handle) throws(AuthError)
    /// The public half of the key `pattern` names, made if need be:
    /// ed25519's and noise-ik's, for the app to give its peers.
    func publicKey(pattern: String) throws(AuthError) -> [UInt8]
  }

  public protocol AuthSession {
    func next() throws(AuthError) -> Step
    func feed(_ message: [UInt8]) throws(AuthError)
    /// Why the session failed (the peer's error, in words).
    func failure() -> String
    /// The user answered what a `needKey` or `needConfirm` step asked.
    @event func answered()
  }
}
