// SPDX-License-Identifier: BSD-3-Clause

// The swarm service (D152): the swarm file, this node's roles in it, and
// the members. At its start it reads the swarm file from the node's
// volume, finds this node's entry by its key, and starts what the
// entry's roles name: for `file`, 9gate's listener on tcp!*!564,
// exporting the entry's `export=` (/data without one). `cpu` is only
// reported: the cpu server runs where the image has it. Its files:
//
//     file       the swarm file; a write replaces it, whole, once checked
//     ctl        push: the file to every other member
//     status     this node's name and roles, what they started, and
//                each member's last push
//     nodes/SYS  each member's entry
//
// It listens on tcp!*!17020 for members only (Noise IK through factotum,
// prologue "swarm") and exports `file` alone there: a push is another
// member's write of it. A file taken is written to the volume, then cs is
// told to reread it.

import Gate
import IPC
import NdbFile
import NineP
import Node
import Noise
import Sys

public final class SwarmService: @unchecked Sendable {
  public static let port = 17020
  public static let prologue = Array("swarm".utf8)

  let tree: NodeTree
  let namespace: Namespace
  let identity: Identity
  let path: String
  let gate: String
  let log: @Sendable (String) -> Void
  let lock = Lock()
  var text: [UInt8] = []
  var nodes: [TreeNode] = []
  var started: [String] = []
  var pushes: [(sys: String, outcome: String)] = []
  var exporting = false

  /// Serves the swarm's files in `tree`, and `file` alone in `remote`,
  /// which `namespace` has at /remote for the listener to export; the
  /// swarm file is at `path` in `namespace`, 9gate's files at `gate`.
  public init(tree: NodeTree, remote: NodeTree, namespace: Namespace, identity: Identity,
              path: String = "/data/lib/ndb/swarm", gate: String = "/svc/9gate",
              log: @escaping @Sendable (String) -> Void = { print("swarm: \($0)") }) {
    self.tree = tree
    self.namespace = namespace
    self.identity = identity
    self.path = path
    self.gate = gate
    self.log = log
    if let t = namespace.readText(path) { text = Array(t.utf8) }
    let file = { @Sendable [self] () -> String in String(decoding: lock.withLock { text }, as: UTF8.self) }
    let take = { @Sendable [self] (written: String) throws(NodeError) in try self.take(Array(written.utf8)) }
    tree.text("file", read: file, write: take)
    remote.text("file", read: file, write: take)
    tree.text("status", read: { [self] in status })
    tree.text("ctl", read: { "" }, write: { [self] line throws(NodeError) in
      let words = line.utf8.split { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A }
      guard words.count == 1, words[0].elementsEqual("push".utf8) else { throw .invalid }
      do throws(Status) {
        _ = try Thread.spawn { [self] in push() }.release()
      } catch { throw .io }
    })
    _ = tree.directory("nodes")
    apply()
  }

  // MARK: The file

  /// The entries of `text`, if it is a swarm file: each entry a member,
  /// with one `sys` and one `key`, 64 lowercase hex digits, and no two
  /// with the same name or key.
  public static func members(_ text: [UInt8]) -> [NdbEntry]? {
    let entries = NdbDatabase(parsing: text).entries
    var names: [[UInt8]] = [], keys: [[UInt8]] = []
    for e in entries {
      let sys = e.values("sys"), key = e.values("key")
      guard sys.count == 1, key.count == 1, !sys[0].isEmpty, !sys[0].utf8.contains(0x2F), isKey(key[0]) else {
        return nil
      }
      let n = Array(sys[0].utf8), k = Array(key[0].utf8)
      guard !names.contains(n), !keys.contains(k) else { return nil }
      names.append(n)
      keys.append(k)
    }
    return entries
  }

  static func isKey(_ text: String) -> Bool {
    text.utf8.count == 2 * Noise.keySize && text.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
  }

  /// Takes `new` as the swarm file: checked, kept on the volume, reread
  /// by cs, and this node's roles applied.
  func take(_ new: [UInt8]) throws(NodeError) {
    guard Self.members(new) != nil else { throw .invalid }
    try keep(new)
    lock.withLock { text = new }
    _ = namespace.writeText("/net/cs", "refresh")
    log("took a swarm file of \(Self.members(new)?.count ?? 0) members")
    apply()
  }

  /// Writes `new` to the volume: over the file, then cut to its length.
  func keep(_ new: [UInt8]) throws(NodeError) {
    var dir = ""
    for part in path.utf8.split(separator: 0x2F).dropLast() {
      dir += "/" + String(decoding: part, as: UTF8.self)
      if (try? namespace.open(dir)) == nil { _ = try? namespace.create(dir, kind: .directory) }
    }
    do throws(NamespaceError) {
      var f: NodeIPC.NodeClient
      if let opened = try? namespace.open(path) { f = opened } else { f = try namespace.create(path, kind: .file) }
      do throws(NodeIPC.NodeClient.Failure) { _ = try f.write(offset: 0, new) } catch { throw NamespaceError(error) }
      try namespace.wstat(path, NodeIPC.Wstat(size: UInt64(new.count)))
    } catch {
      log("can't keep the swarm file: \(error.text)")
      throw .io
    }
  }

  // MARK: Roles

  /// This node's entry, by its key.
  func own(_ entries: [NdbEntry]) -> NdbEntry? {
    let key = hex(identity.publicKey)
    return entries.first { e in e.values("key").contains { $0.utf8.elementsEqual(key.utf8) } }
  }

  static func roles(_ e: NdbEntry) -> [String] {
    e.values("roles").flatMap { $0.utf8.split(separator: 0x2C).map { String(decoding: $0, as: UTF8.self) } }
  }

  static func has(_ roles: [String], _ role: String) -> Bool { roles.contains { $0.utf8.elementsEqual(role.utf8) } }

  /// Rebuilds nodes/ and starts what this node's roles name that isn't
  /// started yet.
  func apply() {
    let entries = Self.members(lock.withLock { text }) ?? []
    let old = lock.withLock { () -> [TreeNode] in
      defer { nodes = [] }
      return nodes
    }
    for n in old { tree.remove(n) }
    var made: [TreeNode] = []
    for e in entries {
      guard let sys = e.value("sys") else { continue }
      made.append(tree.file("nodes/" + sys, Array((e.lines.joined(separator: "\n") + "\n").utf8)))
    }
    lock.withLock { nodes = made }
    guard let me = own(entries) else { return }
    let roles = Self.roles(me)
    if Self.has(roles, "file"), !lock.withLock({ exporting }) {
      let root = me.value("export") ?? "/data"
      let line = "listen tcp!*!564 \(root)"
      let asked = namespace.writeText(gate + "/ctl", line)
      lock.withLock {
        exporting = asked
        started.append(asked ? "file: asked 9gate to \(line)" : "file: 9gate refused \(line)")
      }
    }
  }

  var status: String {
    let entries = Self.members(lock.withLock { text }) ?? []
    var out = ""
    if let me = own(entries) {
      out += "node \(me.value("sys") ?? "") roles \(Self.roles(me).joined(separator: ","))\n"
    } else {
      out += entries.isEmpty ? "no swarm file\n" : "not a member\n"
    }
    lock.withLock {
      for s in started { out += s + "\n" }
      for p in pushes { out += "push \(p.sys) \(p.outcome)\n" }
    }
    return out
  }

  // MARK: Pushing

  /// Sends the swarm file to every other member with an `ip`, one after
  /// another, and records how each went.
  func push() {
    let file = lock.withLock { text }
    guard let entries = Self.members(file) else { return }
    let me = own(entries)
    lock.withLock { pushes = [] }
    for e in entries {
      guard let sys = e.value("sys"), let key = e.value("key").flatMap({ unhex($0) }) else { continue }
      if let me, me.value("sys").map({ $0.utf8.elementsEqual(sys.utf8) }) ?? false { continue }
      let outcome: String
      if let ip = e.value("ip") {
        outcome = send(file, to: "tcp!\(ip)!\(Self.port)", key: key)
      } else {
        outcome = "skipped: no ip"
      }
      lock.withLock { pushes.append((sys, outcome)) }
      log("push \(sys) \(outcome)")
    }
  }

  /// Writes `file` to the member at `address` whose key is `key`: "ok", or
  /// why not.
  func send(_ file: [UInt8], to address: String, key: [UInt8]) -> String {
    let c: NetConnection
    do throws(DialError) { c = try namespace.dial(address) } catch { return "failed: \(error.reason)" }
    guard let stream = GateService.stream(namespace, c) else { return "failed: no data" }
    do throws(GateError) {
      let sealed = try identity.initiate(stream, key, Self.prologue)
      defer { sealed.close() }
      let client = try NinePClient(sealed)
      guard file.count <= Int(client.iounit) else { return "failed: the file is larger than a message" }
      let root = client.fid(), fid = client.fid()
      _ = try client.attach(root, uname: "none", aname: "")
      _ = try client.walk(root, fid, ["file"])
      _ = try client.open(fid, mode: OpenMode.write)
      _ = try client.write(fid, offset: 0, file)
      client.clunk(fid)
      client.clunk(root)
      return "ok"
    } catch {
      return "failed: \(GateService.text(error))"
    }
  }

  // MARK: Listening

  /// Announces tcp!*!17020 and serves each member's call, exporting
  /// `root` of the namespace (the remote tree's mount), until the
  /// announcement fails.
  public func listen(root: String = "/remote") -> DialError {
    let a: NetAnnouncement
    do throws(DialError) { a = try namespace.announce("tcp!*!\(Self.port)") } catch { return error }
    log("listening on tcp!*!\(Self.port)")
    while true {
      let call: NetCall
      do throws(DialError) { call = try namespace.listen(a) } catch { return error }
      let c: NetConnection
      do throws(DialError) { c = try namespace.accept(call) } catch { continue }
      guard let stream = GateService.stream(namespace, c) else { continue }
      do throws(Status) {
        _ = try Thread.spawn { [self] in
          let sealed: ByteStream
          do throws(GateError) {
            sealed = try identity.respond(stream, Self.prologue) { [self] caller in
              namespace.swarmRoles(of: caller) != nil
            }.0
          } catch { return }
          _ = Export.serve(sealed, namespace: namespace, root: root)
        }.release()
      } catch { stream.close() }
    }
  }
}
