// SPDX-License-Identifier: BSD-3-Clause

// 9gate's files (D77, D78): this node's Noise IK key (factotum's, D75:
// 9gate runs each handshake through it and never holds the key), the
// keys that may call it, its listeners, which export a subtree of its namespace to
// trusted callers, and its imports, each a remote tree at n/NAME. Every
// connection is sealed by Noise IK, prologue "9gate", its payloads
// empty, but a plain listener's (Plain.swift), which foreign peers call.
// Nothing listens until ctl says so.
//
//     key       this node's public key, hex
//     ctl       trust KEY | listen ADDR ROOT | plain ADDR ROOT ALLOW... |
//               import ADDR KEY NAME [ANAME]
//     status    the trusted keys, listeners, plain listeners and their
//               callers, and imports
//     n/NAME    an imported tree
//
// Dialing and accepting wait on the network, so they run on threads of
// their own; ctl answers at once, and status says how each went.
// Imports are served on a dispatcher of their own: a walk into n/NAME
// is forwarded from this tree's dispatcher, which waits for the answer.

import IPC
import Node
import Noise
import Sys

public final class GateService: @unchecked Sendable {
  public static let prologue = Array("9gate".utf8)

  let tree: NodeTree
  let namespace: Namespace
  let identity: Identity
  let imports: IPCDispatcher
  let lock = Lock()
  var trusted: [[UInt8]] = []
  var listeners: [(address: String, root: String, state: String)] = []
  var plains: [PlainListener] = []
  var imported: [(name: String, address: String, state: String)] = []
  let onChange: @Sendable () -> Void

  /// Serves 9gate's files at `path` in `tree`; `namespace` is what it
  /// dials through (its /net) and exports from; `imports` serves imported
  /// trees (a dispatcher not the tree's); `identity` runs the handshakes.
  public init(tree: NodeTree, at path: String, namespace: Namespace, identity: Identity, imports: IPCDispatcher,
              changed: @escaping @Sendable () -> Void = {}) {
    self.tree = tree
    self.namespace = namespace
    self.identity = identity
    self.imports = imports
    onChange = changed
    let dir = path.isEmpty ? "" : path + "/"
    let publicKey = hex(identity.publicKey) + "\n"
    tree.text(dir + "key", read: { publicKey })
    tree.text(dir + "status", read: { [self] in status })
    tree.text(dir + "ctl", read: { "" }, write: { [self] (line: String) throws(NodeError) in try command(line) })
    _ = tree.directory(dir + "n")
    nPath = dir + "n/"
  }

  var nPath = ""

  public var status: String {
    lock.withLock {
      var out = ""
      for k in trusted { out += "trust \(hex(k))\n" }
      for l in listeners { out += "listen \(l.address) \(l.root) \(l.state)\n" }
      out += plainStatus
      for i in imported { out += "import \(i.name) \(i.address) \(i.state)\n" }
      return out
    }
  }

  /// A ctl line.
  public func command(_ line: String) throws(NodeError) {
    // Split on bytes: Characters would need Unicode's tables (tier 0).
    let w = line.utf8.split(whereSeparator: { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A })
      .map { String(decoding: $0, as: UTF8.self) }
    guard let verb = w.first else { throw .invalid }
    if NodeIPC.same(verb, "trust"), w.count == 2 {
      guard let k = unhex(w[1]), k.count == Noise.keySize else { throw .invalid }
      lock.withLock { if !trusted.contains(k) { trusted.append(k) } }
    } else if NodeIPC.same(verb, "listen"), w.count == 3 {
      try listen(w[1], root: w[2])
    } else if NodeIPC.same(verb, "plain"), w.count >= 4 {
      try plain(w[1], root: w[2], allow: Array(w[3...]))
    } else if NodeIPC.same(verb, "import"), w.count >= 3, w.count <= 5 {
      // `import ADDR KEY NAME [ANAME]`, or without the KEY for a member of
      // the swarm file (D152), whose entry gives it.
      if let k = unhex(w[2]), k.count == Noise.keySize, w.count >= 4 {
        guard NodeIPC.isValidName(w[3]) else { throw .invalid }
        try importTree(w[1], key: k, name: w[3], aname: w.count == 5 ? w[4] : "")
      } else {
        guard w.count <= 4, NodeIPC.isValidName(w[2]) else { throw .invalid }
        try importTree(w[1], key: nil, name: w[2], aname: w.count == 4 ? w[3] : "")
      }
    } else {
      throw .invalid
    }
  }

  func setListener(_ address: String, _ state: String) {
    lock.withLock {
      if let i = listeners.firstIndex(where: { NodeIPC.same($0.address, address) }) { listeners[i].state = state }
    }
    onChange()
  }

  func setImport(_ name: String, _ state: String) {
    lock.withLock {
      if let i = imported.firstIndex(where: { NodeIPC.same($0.name, name) }) { imported[i].state = state }
    }
    onChange()
  }

  // MARK: Listening

  func listen(_ address: String, root: String) throws(NodeError) {
    try lock.withLock { () throws(NodeError) in
      guard !listeners.contains(where: { NodeIPC.same($0.address, address) }),
            !plains.contains(where: { NodeIPC.same($0.address, address) })
      else { throw .exists }
      listeners.append((address, root, "announcing"))
    }
    do throws(Status) {
      _ = try Thread.spawn { [self] in serveCalls(address, root: root) }.release()
    } catch { throw .io }
  }

  func serveCalls(_ address: String, root: String) {
    let a: NetAnnouncement
    do throws(DialError) { a = try namespace.announce(address) } catch {
      return setListener(address, "failed: \(error.reason)")
    }
    setListener(address, "listening")
    while true {
      let call: NetCall
      do throws(DialError) { call = try namespace.listen(a) } catch {
        return setListener(address, "failed: \(error.reason)")
      }
      let c: NetConnection
      do throws(DialError) { c = try namespace.accept(call) } catch { continue }
      guard let stream = Self.stream(namespace, c) else { continue }
      do throws(Status) {
        _ = try Thread.spawn { [self] in
          // Only a trusted key gets the handshake's reply.
          let sealed: ByteStream
          do throws(GateError) {
            sealed = try identity.respond(stream, Self.prologue) { [self] caller in lock.withLock { trusted.contains(caller) } }.0
          } catch { return }
          _ = Export.serve(sealed, namespace: namespace, root: root)
        }
      } catch { stream.close() }
    }
  }

  // MARK: Importing

  func importTree(_ address: String, key given: [UInt8]?, name: String, aname: String) throws(NodeError) {
    try lock.withLock { () throws(NodeError) in
      guard !imported.contains(where: { NodeIPC.same($0.name, name) }) else { throw .exists }
      imported.append((name, address, "dialing"))
    }
    do throws(Status) {
      _ = try Thread.spawn { [self] in
        // A member's key from the swarm file, by its dial string's host.
        let parts = address.utf8.split(separator: 0x21).map { String(decoding: $0, as: UTF8.self) }
        let host = parts.count >= 2 ? parts[1] : address
        guard let remote = given ?? namespace.ndbValue(sys: host, attr: "key").flatMap({ unhex($0) }),
              remote.count == Noise.keySize
        else { return setImport(name, "failed: no key for \(host) in the swarm file") }
        let c: NetConnection
        do throws(DialError) { c = try namespace.dial(address) } catch {
          return setImport(name, "failed: \(error.reason)")
        }
        guard let stream = Self.stream(namespace, c) else { return setImport(name, "failed: no data") }
        do throws(GateError) {
          let sealed = try identity.initiate(stream, remote, Self.prologue)
          let gate = Import(try NinePClient(sealed), dispatcher: imports)
          let root = try gate.attach(aname: aname)
          tree.mount(nPath + name, root)
          setImport(name, "ready")
        } catch {
          setImport(name, "failed: \(Self.text(error))")
        }
      }
    } catch { throw .io }
  }

  /// A conversation as a stream: reads on one data channel, writes on
  /// another, hung up through its ctl. They are opened anew by its
  /// directory before `c`'s close: the last channel to close ends it.
  public static func stream(_ ns: Namespace, _ c: consuming NetConnection) -> ByteStream? {
    let dir = c.dir
    guard let reader = try? ns.open(dir + "/data"), let writer = try? ns.open(dir + "/data"),
          let control = try? ns.open(dir + "/ctl")
    else { return nil }
    _ = consume c
    let ctl = Shared(control)
    return ByteStream.node(read: reader, write: writer, close: {
      _ = try? ctl.call { (f: inout NodeIPC.NodeClient) throws(NodeIPC.NodeClient.Failure) in
        try f.writeText("hangup")
      }
    })
  }

  public static func text(_ e: GateError) -> String {
    switch e {
    case .closed: "connection closed"
    case .protocolError(let why): why
    case .error(let why): why
    }
  }
}

/// Lowercase hex.
public func hex(_ bytes: [UInt8]) -> String {
  let digits = Array("0123456789abcdef".utf8)
  var out: [UInt8] = []
  for b in bytes { out += [digits[Int(b >> 4)], digits[Int(b & 15)]] }
  return String(decoding: out, as: UTF8.self)
}

/// Hex's bytes, or nil if it isn't hex.
public func unhex(_ text: String) -> [UInt8]? {
  let b = Array(text.utf8)
  guard b.count % 2 == 0 else { return nil }
  func v(_ c: UInt8) -> UInt8? {
    switch c {
    case 0x30...0x39: c - 0x30
    case 0x61...0x66: c - 0x57
    case 0x41...0x46: c - 0x37
    default: nil
    }
  }
  var out: [UInt8] = []
  var i = 0
  while i < b.count {
    guard let hi = v(b[i]), let lo = v(b[i + 1]) else { return nil }
    out.append(hi << 4 | lo)
    i += 2
  }
  return out
}
