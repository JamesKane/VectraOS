// SPDX-License-Identifier: BSD-3-Clause

// Who 9gate is: this node's Noise IK public key, and the two halves of a
// handshake run with its private key. factotum holds that key (D75): its
// noise-ik sessions run each handshake, and 9gate passes the messages
// and gets the session's keys, never the node's. A key held in memory
// (`local`) is for tests and hosts without factotum.

import Factotum
import IPC
import Node
import Noise
import Sys

public struct Identity: Sendable {
  public let publicKey: [UInt8]
  /// Answers a caller on `raw`: the sealed stream and the caller's key,
  /// once `accept` has taken it.
  public let respond: @Sendable (ByteStream, [UInt8], @escaping ([UInt8]) -> Bool) throws(GateError) -> (ByteStream, [UInt8])
  /// Calls the node whose key is `remote` on `raw`.
  public let initiate: @Sendable (ByteStream, [UInt8], [UInt8]) throws(GateError) -> ByteStream

  /// A key held in memory; `random` gives each handshake's ephemeral key.
  public static func local(_ key: StaticKey, random: @escaping @Sendable () -> [UInt8]) -> Identity {
    Identity(
      publicKey: key.publicKey,
      respond: { (raw: ByteStream, prologue: [UInt8], accept: @escaping ([UInt8]) -> Bool) throws(GateError) in
        try SealedStream.respond(raw, key: key, ephemeral: random(), prologue: prologue, accept: accept)
      },
      initiate: { (raw: ByteStream, remote: [UInt8], prologue: [UInt8]) throws(GateError) in
        try SealedStream.initiate(raw, key: key, remote: remote, ephemeral: random(), prologue: prologue)
      })
  }

  /// factotum's key `proto=noise-ik`, through the file at `path` in
  /// `namespace` (its AuthIPC.Factotum, a per-client tree's `auth`).
  public static func factotum(_ namespace: Namespace, at path: String) throws(GateError) -> Identity {
    let pattern = "proto=noise-ik"
    var f = try connect(namespace, path)
    let publicKey: [UInt8]
    do throws(IPCError<AuthIPC.AuthError>) { publicKey = try f.publicKey(pattern: pattern) } catch { throw .closed }
    guard publicKey.count == Noise.keySize else { throw .protocolError("factotum's key") }
    return Identity(
      publicKey: publicKey,
      respond: { (raw: ByteStream, prologue: [UInt8], accept: @escaping ([UInt8]) -> Bool) throws(GateError) in
        let frames = Frames(raw)
        do throws(GateError) {
          var s = try session(namespace, path, pattern, .server)
          try expect(.need, &s)
          try feed(prologue, &s)
          try expect(.need, &s)
          try feed(try frames.next(), &s)
          let done = try step(&s)
          guard done.kind == .done, let caller = unhex(done.peer), caller.count == Noise.keySize,
                let session = Session(secret: done.secret)
          else { throw .protocolError("handshake") }
          // A refused caller gets no reply: the stream hangs up.
          guard accept(caller) else { throw .protocolError("caller refused") }
          try raw.write(Frame.wrap(done.bytes))
          return (SealedStream.sealed(raw, frames, session), caller)
        } catch {
          raw.close()
          throw error
        }
      },
      initiate: { (raw: ByteStream, remote: [UInt8], prologue: [UInt8]) throws(GateError) in
        let frames = Frames(raw)
        do throws(GateError) {
          var s = try session(namespace, path, pattern, .client)
          try expect(.need, &s)
          try feed(remote + prologue, &s)
          let first = try step(&s)
          guard first.kind == .send else { throw .protocolError("handshake") }
          try raw.write(Frame.wrap(first.bytes))
          try expect(.need, &s)
          try feed(try frames.next(), &s)
          let done = try step(&s)
          guard done.kind == .done, let session = Session(secret: done.secret) else {
            throw .protocolError("handshake")
          }
          return SealedStream.sealed(raw, frames, session)
        } catch {
          raw.close()
          throw error
        }
      })
  }

  static func connect(_ namespace: Namespace, _ path: String) throws(GateError) -> AuthIPC.FactotumClient {
    do throws(NamespaceError) {
      return AuthIPC.FactotumClient(channel: try namespace.open(path).takeChannel())
    } catch { throw .protocolError("no factotum at \(path)") }
  }

  /// A noise-ik session of factotum's, a channel of its own.
  static func session(_ namespace: Namespace, _ path: String, _ pattern: String, _ role: AuthIPC.Role)
    throws(GateError) -> AuthIPC.AuthSessionClient
  {
    var f = try connect(namespace, path)
    let ends: Ends
    do throws(Status) { ends = try Channel.create() } catch { throw .closed }
    let mine = ends.a, theirs = ends.b
    do throws(IPCError<AuthIPC.AuthError>) {
      try f.startSession(pattern: pattern, role: role, session: theirs)
    } catch { throw .protocolError("factotum refused the session") }
    return AuthIPC.AuthSessionClient(channel: mine)
  }

  static func step(_ s: inout AuthIPC.AuthSessionClient) throws(GateError) -> AuthIPC.Step {
    do throws(IPCError<AuthIPC.AuthError>) { return try s.next() } catch { throw .protocolError("handshake") }
  }

  static func expect(_ kind: AuthIPC.StepKind, _ s: inout AuthIPC.AuthSessionClient) throws(GateError) {
    guard try step(&s).kind == kind else { throw .protocolError("handshake") }
  }

  static func feed(_ message: [UInt8], _ s: inout AuthIPC.AuthSessionClient) throws(GateError) {
    do throws(IPCError<AuthIPC.AuthError>) { try s.feed(message) } catch { throw .protocolError("handshake") }
  }
}
