// SPDX-License-Identifier: BSD-3-Clause

// The SDK helper that publishes a tree over Node (architecture §4, the
// equivalent of lib9p's in-memory file tree). A service builds the tree,
// with text leaves for `status` and `ctl`, and serves channels to it:
//
//     let dispatcher = try IPCDispatcher()
//     let tree = NodeTree(dispatcher: dispatcher)
//     tree.text("status") { "running \(jobs) jobs\n" }
//     tree.text("ctl", read: { "" }, write: { command throws(NodeIPC.NodeError) in try run(command) })
//     tree.service("device") { channel in try serveDevice(channel) }
//     try tree.serve(channel)
//     try dispatcher.run()
//
// Batches are served on the dispatcher's thread, an operation at a time on
// a current node (D64); one that walks into another service's node (a
// mount) hands it the rest of the batch. The service may change the tree
// from any thread; watchers hear of it. Names are compared as bytes
// (NodeIPC.same).

import IPC

public typealias NodeError = NodeIPC.NodeError

/// A node of a NodeTree.
public final class TreeNode: @unchecked Sendable {
  enum Content {
    case directory(allowsCreate: Bool)
    case bytes([UInt8], writable: Bool)
    case text(read: @Sendable () -> String, write: (@Sendable (String) throws(NodeError) -> Void)?)
    /// Another service's node: a batch that walks into it goes on there.
    case remote(Remote)
    /// A typed protocol: opening it gets a channel `connect` serves.
    case service(connect: (consuming Handle) throws(Status) -> Void)
  }

  public let name: String
  let path: UInt64
  var version: UInt32 = 0
  var content: Content
  /// Strong: Embedded Swift has no weak references. The cycle with
  /// `children` is broken when the node leaves the tree (removeLocked) or
  /// the tree goes (NodeTree's deinit).
  var parent: TreeNode?
  var children: [TreeNode] = []
  var modified = realtime()
  var attributes: [NodeIPC.Attribute] = []
  /// Made by a client, so a client may remove it.
  var removable = false
  var detached = false
  var watchers: [Watcher] = []
  /// The last changes watchers heard, for watch(since:); `lostThrough` is
  /// the newest one dropped from it.
  var log: [NodeIPC.Change] = []
  var lostThrough: UInt64 = 0

  init(name: String, path: UInt64, content: Content) {
    self.name = name
    self.path = path
    self.content = content
  }

  var kind: NodeIPC.NodeKind {
    switch content {
    case .directory, .remote: .directory
    case .bytes, .text: .file
    case .service: .service
    }
  }
  var qid: NodeIPC.Qid { NodeIPC.Qid(path: path, version: version, kind: kind) }

  /// The child called `name`, if there is one.
  func child(_ name: some StringProtocol) -> TreeNode? {
    children.first { $0.name.utf8.elementsEqual(name.utf8) }
  }
}

/// A channel to another service's node, which a tree forwards batches to.
final class Remote: @unchecked Sendable {
  let mutex = Lock()
  var client: NodeIPC.NodeClient
  /// Whether the node goes when the other service does (a post on a
  /// board), or stays to be given a new channel (a launcher's /svc).
  let removeWhenGone: Bool

  init(_ channel: consuming Handle, removeWhenGone: Bool) {
    client = NodeIPC.NodeClient(channel: channel)
    self.removeWhenGone = removeWhenGone
  }

  /// Runs a batch at the remote node, one caller at a time.
  func batch(_ ops: [NodeIPC.Op], open: Bool) throws(IPCError<Never>) -> NodeIPC.Reply {
    mutex.lock()
    defer { mutex.unlock() }
    return try client.batch(ops, open: open)
  }
}

/// A session watching a node; it goes once the session has closed.
final class Watcher: @unchecked Sendable {
  let session: SessionState
  init(_ session: SessionState) { self.session = session }
}

/// What a session shares with the tree: its dispatcher id, its queue, and
/// whether it has closed (no weak references in Embedded Swift, so
/// watchers ask).
final class SessionState: @unchecked Sendable {
  var id: UInt64 = 0
  var pending: [NodeIPC.Change] = []
  var closed = false
}

/// Held only by a session's server: when the dispatcher drops the server
/// (its channel closed), this marks the session closed.
final class SessionEnd: @unchecked Sendable {
  let tree: NodeTree
  let state: SessionState
  init(_ tree: NodeTree, _ state: SessionState) {
    self.tree = tree
    self.state = state
  }
  deinit { tree.locked { state.closed = true } }
}

public final class NodeTree: @unchecked Sendable {
  public let root: TreeNode
  let dispatcher: IPCDispatcher
  let mutex = Lock()
  var lastPath: UInt64 = 1
  var seq: UInt64 = 0
  static let logLength = 64

  public init(dispatcher: IPCDispatcher) {
    self.dispatcher = dispatcher
    root = TreeNode(name: "", path: 1, content: .directory(allowsCreate: false))
  }

  /// Breaks the parent links, so the nodes go with the tree.
  deinit {
    func unlink(_ n: TreeNode) {
      n.parent = nil
      n.children.forEach(unlink)
    }
    unlink(root)
  }

  func locked<R, E: Error>(_ body: () throws(E) -> R) throws(E) -> R {
    mutex.lock()
    defer { mutex.unlock() }
    return try body()
  }

  // MARK: Building

  /// The directory at `path`, made (with any parents) if need be.
  @discardableResult
  public func directory(_ path: String, allowsCreate: Bool = false) -> TreeNode {
    let node = place(path, .directory(allowsCreate: allowsCreate))
    locked { if case .directory = node.content { node.content = .directory(allowsCreate: allowsCreate) } }
    return node
  }

  /// A file holding `bytes`.
  @discardableResult
  public func file(_ path: String, _ bytes: [UInt8], writable: Bool = false) -> TreeNode {
    place(path, .bytes(bytes, writable: writable))
  }

  /// A text leaf: `read` renders it on every read; `write`, if given, takes
  /// each write as one command (a `ctl` leaf).
  @discardableResult
  public func text(_ path: String, read: @escaping @Sendable () -> String,
                   write: (@Sendable (String) throws(NodeError) -> Void)? = nil) -> TreeNode {
    place(path, .text(read: read, write: write))
  }

  /// A typed protocol at `path`: a batch that opens it makes a channel and
  /// hands one end to `connect` (on the dispatcher's thread) to serve, and
  /// the other to the client. Walks can't go through it.
  @discardableResult
  public func service(_ path: String, connect: @escaping (consuming Handle) throws(Status) -> Void) -> TreeNode {
    place(path, .service(connect: connect))
  }

  /// Another service's node at `path`: batches that walk into it go on
  /// there. Mounting again where one is gives it the new channel. If the
  /// other service goes, the node goes too, unless `removeWhenGone` is
  /// false: then batches into it fail with `io` until it is mounted again.
  @discardableResult
  public func mount(_ path: String, _ channel: consuming Handle, removeWhenGone: Bool = true) -> TreeNode {
    let remote = Remote(channel, removeWhenGone: removeWhenGone)
    if let existing = node(path) {
      let replaced = locked { () -> [Watcher]? in
        guard case .remote = existing.content, !existing.detached else { return nil }
        existing.content = .remote(remote)
        return modifiedLocked(existing)
      }
      if let replaced {
        wake(replaced)
        return existing
      }
    }
    return place(path, .remote(remote))
  }

  /// The node at `path`, if there is one.
  public func node(_ path: String) -> TreeNode? {
    locked {
      var at: TreeNode? = root
      for name in NodeIPC.names(path) { at = at?.child(name) }
      return at
    }
  }

  /// Replaces a file's bytes.
  public func setContents(_ node: TreeNode, _ bytes: [UInt8]) {
    let woken = locked {
      if case .bytes(_, let writable) = node.content { node.content = .bytes(bytes, writable: writable) }
      return modifiedLocked(node)
    }
    wake(woken)
  }

  /// Sets a node's attributes.
  public func setAttributes(_ node: TreeNode, _ attributes: [NodeIPC.Attribute]) {
    wake(locked {
      node.attributes = attributes
      return modifiedLocked(node)
    })
  }

  /// Says a node changed (a text leaf whose rendering did): a new version,
  /// and watchers hear of it.
  public func touch(_ node: TreeNode) { wake(locked { modifiedLocked(node) }) }

  /// Removes a node and everything under it.
  public func remove(_ node: TreeNode) { wake(locked { removeLocked(node) }) }

  /// The node at `path`, made with `content` (and parent directories).
  func place(_ path: String, _ content: TreeNode.Content) -> TreeNode {
    let names = NodeIPC.names(path)
    precondition(!names.isEmpty && names.allSatisfy(NodeIPC.isValidName), "bad path")
    var woken: [Watcher] = []
    let node = locked { () -> TreeNode in
      var at = root
      for (i, name) in names.enumerated() {
        if let child = at.child(name) {
          at = child
          continue
        }
        let last = i == names.count - 1
        let (child, w) = addLocked(name, to: at, last ? content : .directory(allowsCreate: false))
        woken += w
        at = child
      }
      return at
    }
    wake(woken)
    return node
  }

  // MARK: Changes (under the lock)

  func addLocked(_ name: String, to parent: TreeNode, _ content: TreeNode.Content) -> (TreeNode, [Watcher]) {
    lastPath += 1
    let child = TreeNode(name: name, path: lastPath, content: content)
    child.parent = parent
    parent.children.append(child)
    parent.version &+= 1
    parent.modified = realtime()
    return (child, notifyLocked(parent, .created, name))
  }

  func modifiedLocked(_ node: TreeNode) -> [Watcher] {
    node.version &+= 1
    node.modified = realtime()
    var woken = notifyLocked(node, .modified, node.name)
    if let parent = node.parent { woken += notifyLocked(parent, .modified, node.name) }
    return woken
  }

  func removeLocked(_ node: TreeNode) -> [Watcher] {
    guard let parent = node.parent, !node.detached else { return [] }
    parent.children.removeAll { $0 === node }
    parent.version &+= 1
    var woken = notifyLocked(node, .removed, node.name) + notifyLocked(parent, .removed, node.name)
    func detach(_ n: TreeNode) {
      n.detached = true
      n.parent = nil  // no cycle keeps a removed subtree alive
      n.children.forEach(detach)
    }
    detach(node)
    for child in node.children { woken += notifyLocked(child, .removed, child.name) }
    return woken
  }

  /// Logs a change to `node` and queues it for its watchers: those to wake.
  func notifyLocked(_ node: TreeNode, _ kind: NodeIPC.ChangeKind, _ name: String) -> [Watcher] {
    seq += 1
    let change = NodeIPC.Change(seq: seq, node: node.path, kind: kind, name: name)
    node.log.append(change)
    if node.log.count > Self.logLength { node.lostThrough = node.log.removeFirst().seq }
    node.watchers.removeAll { $0.session.closed }
    for w in node.watchers { w.session.pending.append(change) }
    return node.watchers
  }

  /// Asks the dispatcher to send what the watchers have queued.
  func wake(_ watchers: [Watcher]) {
    for w in watchers where !w.session.closed { dispatcher.wake(w.session.id) }
  }

  // MARK: Serving

  /// Serves Node on `channel`, at the root.
  public func serve(_ channel: consuming Handle) throws(Status) { try serve(channel, at: root) }

  /// Serves Node on `channel`, at `node`.
  public func serve(_ channel: consuming Handle, at node: TreeNode) throws(Status) {
    let state = SessionState()
    let server = NodeIPC.NodeServer(channel: channel, impl: Session(tree: self, node: node, state: state, end: SessionEnd(self, state)))
    state.id = try dispatcher.add(server) { [self] (s: inout NodeIPC.NodeServer<Session>) throws(IPCError<Never>) in
      let changes = locked { () -> [NodeIPC.Change] in
        defer { state.pending = [] }
        return state.pending
      }
      for c in changes { try s.sendChanged(c) }
    }
  }
}

/// Nanoseconds since the Unix epoch (Sys's clock).
func realtime() -> Int64 { Clock.realtime() }

/// One channel's view of the tree: the node it is at, where each batch
/// starts.
struct Session: NodeIPC.NodeHandler {
  let tree: NodeTree
  let node: TreeNode
  let state: SessionState
  /// Marks the session closed when the server holding this goes.
  let end: SessionEnd

  mutating func batch(_ ops: [NodeIPC.Op], open: Bool) -> NodeIPC.Reply {
    var results: [NodeIPC.Outcome] = []
    guard ops.count <= NodeIPC.maxOps else { return failed(results, 0, .tooManyOps) }
    var at = node
    for i in ops.indices {
      do throws(NodeError) {
        switch ops[i] {
        case .walk(let names):
          let (qids, end, rest) = try walk(names, from: at)
          if case .remote(let remote) = end.content {
            // The rest of the walk, and of the batch, is the other service's.
            return forward([.walk(names: rest)] + ops[(i + 1)...], open: open, to: remote, at: end,
                           after: results, qids: qids, index: i)
          }
          results.append(.walked(qids))
          at = end
        case .stat(let fields):
          results.append(.stat(try tree.locked { () throws(NodeError) in stat(try live(at), fields) }))
        case .readdir(let cursor, let max, let fields):
          results.append(.dir(try readdir(at, cursor: cursor, max: max, fields: fields)))
        case .read(let offset, let max):
          results.append(.data(try read(at, offset: offset, max: max)))
        case .write(let offset, let data):
          results.append(.wrote(try write(at, offset: offset, data)))
        case .watch(let since):
          results.append(.watching(try watch(at, since: since)))
        case .create(let name, let kind):
          at = try create(at, name, kind: kind)
          results.append(.created(at.qid))
        case .remove:
          try remove(at)
          results.append(.removed)
        }
      } catch {
        return failed(results, i, error)
      }
    }
    guard open else { return NodeIPC.Reply(results: results, failure: nil, node: nil) }
    do throws(NodeError) {
      return NodeIPC.Reply(results: results, failure: nil, node: try opened(at))
    } catch {
      return failed(results, ops.count, error)  // the open itself
    }
  }

  /// The reply to a batch whose operation `index` failed.
  func failed(_ results: [NodeIPC.Outcome], _ index: Int, _ error: NodeError) -> NodeIPC.Reply {
    NodeIPC.Reply(results: results, failure: NodeIPC.Failure(index: UInt32(index), code: error.rawValue), node: nil)
  }

  /// The node, if it is still in the tree.
  func live(_ node: TreeNode) throws(NodeError) -> TreeNode {
    guard !node.detached else { throw .notFound }
    return node
  }

  /// Walks `names` from `start`: the qids, the node reached, and the names
  /// left when it is another service's node.
  func walk(_ names: [String], from start: TreeNode) throws(NodeError) -> ([NodeIPC.Qid], TreeNode, [String]) {
    guard names.count <= NodeIPC.maxWalk else { throw .tooManyNames }
    guard names.allSatisfy({ NodeIPC.same($0, "..") || NodeIPC.isValidName($0) }) else { throw .badName }
    return try tree.locked { () throws(NodeError) -> ([NodeIPC.Qid], TreeNode, [String]) in
      var at = try live(start)
      var qids: [NodeIPC.Qid] = []
      for (i, name) in names.enumerated() {
        if case .remote = at.content { return (qids, at, Array(names[i...])) }
        if NodeIPC.same(name, "..") {
          at = at.parent ?? at
        } else {
          guard at.kind == .directory else { throw .notDirectory }
          guard let next = at.child(name) else { throw .notFound }
          at = next
        }
        qids.append(at.qid)
      }
      return (qids, at, [])
    }
  }

  /// Hands the rest of a batch to another service, whose node `end` is,
  /// and joins its reply to this one's: its first result (the walk's
  /// rest) to the walk's qids, its failure counted from `index`.
  func forward(_ ops: [NodeIPC.Op], open: Bool, to remote: Remote, at end: TreeNode, after results: [NodeIPC.Outcome],
               qids: [NodeIPC.Qid], index: Int) -> NodeIPC.Reply
  {
    let reply: NodeIPC.Reply
    do throws(IPCError<Never>) {
      reply = try remote.batch(ops, open: open)
    } catch {
      // The other service is gone: so is its node, or it waits for another.
      guard remote.removeWhenGone else { return failed(results, index, .io) }
      tree.remove(end)
      return failed(results, index, .notFound)
    }
    var joined = results
    var theirs = reply.results[...]
    if case .walked(let more)? = theirs.first {
      joined.append(.walked(qids + more))
      theirs = theirs.dropFirst()
    }
    joined += theirs
    let failure = reply.failure.map { NodeIPC.Failure(index: $0.index + UInt32(index), code: $0.code) }
    let node = reply.node
    return NodeIPC.Reply(results: joined, failure: failure, node: node)
  }

  /// A channel to `node` for the client: Node served at it, or for a
  /// service node, its own protocol.
  func opened(_ node: TreeNode) throws(NodeError) -> Handle {
    let content = try tree.locked { () throws(NodeError) in try live(node).content }
    do throws(Status) {
      let ends = try Channel.create()
      if case .service(let connect) = content {
        try connect(ends.b)
      } else {
        try tree.serve(ends.b, at: node)
      }
      return ends.a
    } catch {
      throw .io
    }
  }

  func stat(_ node: TreeNode, _ fields: UInt32) -> NodeIPC.Stat {
    var size: UInt64 = 0
    if fields & NodeIPC.Fields.size != 0, case .bytes(let b, _) = node.content { size = UInt64(b.count) }
    return NodeIPC.Stat(
      qid: node.qid, name: node.name, size: size,
      modified: fields & NodeIPC.Fields.modified != 0 ? node.modified : 0,
      attributes: fields & NodeIPC.Fields.attributes != 0 ? node.attributes : [])
  }

  func readdir(_ node: TreeNode, cursor: UInt64, max: UInt32, fields: UInt32) throws(NodeError) -> NodeIPC.DirBatch {
    try tree.locked { () throws(NodeError) in
      let at = try live(node)
      guard at.kind == .directory else { throw .notDirectory }
      var entries: [NodeIPC.Stat] = []
      var i = Int(clamping: cursor)
      var bytes = 0
      // A page stays well inside one message.
      while i < at.children.count, entries.count < Int(Swift.max(1, Swift.min(max, 256))), bytes < 32_768 {
        let s = stat(at.children[i], fields)
        bytes += 64 + s.name.utf8.count + s.attributes.reduce(0) { $0 + 48 + $1.name.utf8.count + $1.value.count }
        entries.append(s)
        i += 1
      }
      return NodeIPC.DirBatch(entries: entries, next: UInt64(i), done: i >= at.children.count)
    }
  }

  func read(_ node: TreeNode, offset: UInt64, max: UInt32) throws(NodeError) -> [UInt8] {
    let content = try tree.locked { () throws(NodeError) in try live(node).content }
    let bytes: [UInt8]
    switch content {
    case .directory, .remote: throw .isDirectory
    case .service: throw .unsupported
    case .bytes(let b, _): bytes = b
    case .text(let render, _): bytes = Array(render().utf8)  // outside the lock: it's the service's code
    }
    guard offset < UInt64(bytes.count) else { return [] }
    let start = Int(offset)
    return Array(bytes[start..<Swift.min(bytes.count, start + Swift.min(Int(max), NodeIPC.maxIO))])
  }

  func write(_ node: TreeNode, offset: UInt64, _ data: [UInt8]) throws(NodeError) -> UInt32 {
    guard data.count <= NodeIPC.maxIO else { throw .invalid }
    let content = try tree.locked { () throws(NodeError) in try live(node).content }
    switch content {
    case .directory, .remote:
      throw .isDirectory
    case .service:
      throw .unsupported
    case .text(_, let write):
      guard let write else { throw .unsupported }
      guard let command = String(validating: data, as: UTF8.self) else { throw .invalid }
      try write(command)
    case .bytes:
      let woken = try tree.locked { () throws(NodeError) -> [Watcher] in
        guard case .bytes(var bytes, let writable) = node.content, !node.detached else { throw .notFound }
        guard writable else { throw .unsupported }
        guard offset <= UInt64(bytes.count) + UInt64(NodeIPC.maxIO) else { throw .invalid }
        let start = Int(offset)
        if bytes.count < start + data.count { bytes += [UInt8](repeating: 0, count: start + data.count - bytes.count) }
        bytes.replaceSubrange(start..<(start + data.count), with: data)
        node.content = .bytes(bytes, writable: writable)
        return tree.modifiedLocked(node)
      }
      tree.wake(woken)
    }
    return UInt32(data.count)
  }

  func watch(_ node: TreeNode, since seq: UInt64) throws(NodeError) -> UInt64 {
    let state = self.state
    let (now, replay) = try tree.locked { () throws(NodeError) -> (UInt64, Bool) in
      let at = try live(node)
      if !at.watchers.contains(where: { $0.session === state }) { at.watchers.append(Watcher(state)) }
      guard seq > 0 else { return (tree.seq, false) }
      if at.lostThrough > seq {
        state.pending.append(NodeIPC.Change(seq: tree.seq, node: at.path, kind: .overflow, name: at.name))
      }
      state.pending += at.log.filter { $0.seq > seq }
      return (tree.seq, !state.pending.isEmpty)
    }
    // Sent once this reply has gone.
    if replay { tree.dispatcher.wake(state.id) }
    return now
  }

  func create(_ node: TreeNode, _ name: String, kind: NodeIPC.NodeKind) throws(NodeError) -> TreeNode {
    guard NodeIPC.isValidName(name) else { throw .badName }
    guard kind != .service else { throw .unsupported }
    let (child, woken) = try tree.locked { () throws(NodeError) -> (TreeNode, [Watcher]) in
      let at = try live(node)
      guard case .directory(let allowsCreate) = at.content else { throw .notDirectory }
      guard allowsCreate else { throw .unsupported }
      guard at.child(name) == nil else { throw .exists }
      let content: TreeNode.Content = kind == .directory ? .directory(allowsCreate: true) : .bytes([], writable: true)
      let (child, woken) = tree.addLocked(name, to: at, content)
      child.removable = true
      return (child, woken)
    }
    tree.wake(woken)
    return child
  }

  func remove(_ node: TreeNode) throws(NodeError) {
    let woken = try tree.locked { () throws(NodeError) -> [Watcher] in
      let at = try live(node)
      guard at.removable else { throw .denied }
      guard at.children.isEmpty else { throw .notEmpty }
      return tree.removeLocked(at)
    }
    tree.wake(woken)
  }
}
