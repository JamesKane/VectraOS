// SPDX-License-Identifier: BSD-3-Clause

// The fs service's volume (fs(4)): a Taisce volume on a disk's partition,
// served as FsIPC's Directory and File channels, which compose Node, on a
// dispatcher of its own, whose thread alone touches the volume. The
// service's tree mounts the root's channel at `volume`.
//
// Every change is in memory at once; a transaction group commits a second
// after the first change since the last, sooner if many blocks wait, and
// at once on Directory.sync (File.sync writes the intent log instead).
// Watchers hear of changes from the change journal as each operation
// commits in memory, so they may hear of one a crash then loses.

import Fs
import IPC
import Node
import Sys
import Taisce

public final class FsService: @unchecked Sendable {
  var fs: FileSystem<NodeDevice>
  let dispatcher: IPCDispatcher
  /// What `status` calls the device.
  public let device: String
  /// The thread that rings for a commit a second after a change.
  let committer: Committer
  var commitPending = false
  /// The journal records watchers have had.
  var journalSeen: UInt64
  /// The channels watching a node, until they close.
  var watchers: [(session: FsSession, ino: UInt64)] = []
  var sessions = 0
  var commits = 0
  /// `status`, as the volume's thread last left it, for the tree's.
  let lock = Lock()
  var rendered = ""

  /// Groups wait at most this long (and this many dirty blocks).
  static let commitDelay: Int64 = 1_000_000_000
  static let commitBlocks = 4096

  public init(_ fs: consuming FileSystem<NodeDevice>, device: String, dispatcher: IPCDispatcher) throws(Status) {
    self.fs = fs
    self.device = device
    self.dispatcher = dispatcher
    journalSeen = self.fs.nextSeq - 1
    let bell = try Counter.create()
    committer = try Committer(bell: try bell.duplicate(), delay: Self.commitDelay)
    // A strong capture (no weak references in tier 0): the service lasts
    // as long as its process.
    try dispatcher.watch(bell, signals: Signals.positive) { [self] _ in
      if let n = try? Counter.read(committer.bell), n > 0 { try? Counter.add(committer.bell, -n) }
      try? commit()
      return true
    }
    render()
  }

  /// A channel to the volume's root directory.
  public func root() throws(NodeError) -> Handle { try channel(FileSystem<NodeDevice>.root) }

  /// The volume and what is open on it.
  public var status: String { lock.withLock { rendered } }

  func render() {
    let s = fs.engine.store.volume.superblock
    let text = """
      volume \(String(decoding: s.label, as: UTF8.self))
      device \(device)
      txg \(s.txg)
      sessions \(sessions)
      commits \(commits)
      blocks \(s.layout.blockCount) free \(fs.engine.store.volume.allocator.freeCount) size \(Layout.blockSize)

      """
    lock.withLock { rendered = text }
  }

  public static var now: UInt64 { UInt64(clamping: Clock.realtime()) }

  // MARK: Durability

  /// Commits a group now.
  func commit() throws(TaisceError) {
    commitPending = false
    defer { render() }
    try fs.sync()
    commits += 1
  }

  /// After every change: watchers hear of it, and a commit is due.
  func changed() {
    tell()
    if fs.engine.pendingBlocks > Self.commitBlocks {
      try? commit()
    } else if !commitPending {
      commitPending = true
      committer.request()
    }
    render()
  }

  // MARK: Nodes and channels

  func qid(_ ino: UInt64) throws(TaisceError) -> NodeIPC.Qid {
    let inode = try fs.stat(ino)
    return NodeIPC.Qid(path: ino, version: UInt32(truncatingIfNeeded: inode.version),
                       kind: inode.type == .directory ? .directory : .file)
  }

  /// A channel to `ino`: Directory or File, as it is.
  func channel(_ ino: UInt64) throws(NodeError) -> Handle {
    let isDirectory = try node { (s: FsService) throws(TaisceError) in try s.fs.stat(ino).type == .directory }
    do throws(Status) {
      let ends = try Channel.create()
      let session = FsSession(ino: ino, service: self, file: !isDirectory)
      let id: UInt64
      if isDirectory {
        id = try dispatcher.add(FsIPC.DirectoryServer(channel: ends.b, impl: DirectorySession(session: session, end: FsSessionEnd(session)))) {
          (s: inout FsIPC.DirectoryServer<DirectorySession>) throws(IPCError<Never>) in
          for c in session.takePending() { try NodeIPC.NodeEventSender.sendChanged(c, on: s.connection) }
        }
      } else {
        id = try dispatcher.add(FsIPC.FileServer(channel: ends.b, impl: FileSession(session: session, end: FsSessionEnd(session)))) {
          (s: inout FsIPC.FileServer<FileSession>) throws(IPCError<Never>) in
          for c in session.takePending() { try NodeIPC.NodeEventSender.sendChanged(c, on: s.connection) }
        }
        fs.opened(ino)  // an open file outlives its last name (an orphan)
      }
      session.id = id
      sessions += 1
      render()
      return ends.a
    } catch {
      throw .io
    }
  }

  /// A session's end, on the dispatcher's thread.
  func ended(_ session: FsSession) {
    session.closed = true
    sessions -= 1
    if session.file { try? fs.closed(session.ino) }
    render()
  }

  /// Walks `names` from `ino`, every one there (`..` above the root stays
  /// at the root): a qid for each, and where it ended.
  func walk(from ino: UInt64, _ names: [String]) throws(NodeError) -> ([NodeIPC.Qid], UInt64) {
    guard names.count <= NodeIPC.maxWalk else { throw .tooManyNames }
    guard names.allSatisfy({ NodeIPC.same($0, "..") || NodeIPC.isValidName($0) }) else { throw .badName }
    var at = ino
    var qids: [NodeIPC.Qid] = []
    for name in names {
      at = try node { (s: FsService) throws(TaisceError) in
        let inode = try s.fs.stat(at)
        if NodeIPC.same(name, "..") { return at == FileSystem<NodeDevice>.root ? at : inode.parent }
        guard inode.type == .directory else { throw .notDirectory }
        return try s.fs.lookup(at, Array(name.utf8))
      }
      qids.append(try node { (s: FsService) throws(TaisceError) in try s.qid(at) })
    }
    return (qids, at)
  }

  /// The directory a path below `ino` names, and its last name.
  func parent(of path: String, below ino: UInt64) throws(FsIPC.FsError) -> (UInt64, [UInt8]) {
    var names = NodeIPC.names(path)
    guard let last = names.popLast(), NodeIPC.isValidName(last), !NodeIPC.same(last, "..") else { throw .badName }
    var at = ino
    for name in names {
      guard NodeIPC.same(name, "..") || NodeIPC.isValidName(name) else { throw .badName }
      do throws(TaisceError) {
        at = NodeIPC.same(name, "..") ? try fs.stat(at).parent : try fs.lookup(at, Array(name.utf8))
      } catch {
        throw Self.fsError(error)
      }
    }
    return (at, Array(last.utf8))
  }

  /// Runs a Taisce operation for Node.
  func node<T>(_ body: (FsService) throws(TaisceError) -> T) throws(NodeError) -> T {
    do throws(TaisceError) { return try body(self) } catch { throw Self.nodeError(error) }
  }

  /// Runs a Taisce operation for FsIPC.
  func call<T>(_ body: (FsService) throws(TaisceError) -> T) throws(FsIPC.FsError) -> T {
    do throws(TaisceError) { return try body(self) } catch { throw Self.fsError(error) }
  }

  // MARK: Watches

  /// Passes on what the journal has gained.
  func tell() {
    guard let records = try? fs.journal(after: journalSeen), let last = records.last else { return }
    journalSeen = last.seq
    watchers.removeAll { $0.session.closed }
    var woken: [FsSession] = []
    for r in records {
      for w in watchers {
        if let change = Self.change(r, for: w.ino) {
          w.session.pending.append(change)
          if !woken.contains(where: { $0 === w.session }) { woken.append(w.session) }
        }
      }
    }
    for s in woken { dispatcher.wake(s.id) }
  }

  /// What record `r` means to a watcher of `ino`, if anything.
  static func change(_ r: JournalEntry, for ino: UInt64) -> NodeIPC.Change? {
    let name = String(decoding: r.name, as: UTF8.self)
    if r.parent == ino && r.ino != ino {
      let kind: NodeIPC.ChangeKind =
        !r.reasons.isDisjoint(with: [.created, .linked]) ? .created
        : !r.reasons.isDisjoint(with: [.removed, .unlinked]) ? .removed : .modified
      return NodeIPC.Change(seq: r.seq, node: ino, kind: kind, name: name)
    }
    if r.ino == ino {
      return NodeIPC.Change(seq: r.seq, node: ino, kind: r.reasons.contains(.removed) ? .removed : .modified, name: name)
    }
    return nil
  }

  /// `session` watches `ino`, from the records after `seq` (0: none).
  func watch(_ session: FsSession, _ ino: UInt64, since seq: UInt64) -> UInt64 {
    if !watchers.contains(where: { $0.session === session && $0.ino == ino }) { watchers.append((session, ino)) }
    let now = fs.nextSeq - 1
    guard seq > 0, seq < now else { return now }
    do throws(TaisceError) {
      let records = try fs.journal(after: seq)
      guard records.first?.seq == seq + 1 else { throw .journalTrimmed }
      session.pending += records.prefix { $0.seq <= journalSeen }.compactMap { Self.change($0, for: ino) }
    } catch {
      session.pending.append(NodeIPC.Change(seq: now, node: ino, kind: .overflow, name: ""))
    }
    // Sent once this reply has gone.
    if !session.pending.isEmpty { dispatcher.wake(session.id) }
    return now
  }

  // MARK: Attributes

  static func encode(_ v: AttributeValue) -> (kind: UInt8, value: [UInt8]) {
    func le<T: FixedWidthInteger>(_ x: T) -> [UInt8] { withUnsafeBytes(of: x.littleEndian) { unsafe Array($0) } }
    let value: [UInt8] = switch v {
    case .string(let b), .bytes(let b), .type(let b): b
    case .int64(let x), .time(let x): le(x)
    case .uint64(let x), .ref(let x): le(x)
    case .double(let d): le(d.bitPattern)
    case .bool(let b): [b ? 1 : 0]
    }
    return (v.kind.rawValue, value)
  }

  static func decode(_ kind: UInt8, _ b: [UInt8]) -> AttributeValue? {
    guard let kind = AttributeKind(rawValue: kind) else { return nil }
    func u64() -> UInt64? { b.count == 8 ? b.reversed().reduce(0) { $0 << 8 | UInt64($1) } : nil }
    switch kind {
    case .string: return .string(b)
    case .bytes: return .bytes(b)
    case .type: return .type(b)
    case .bool: return b.count == 1 ? .bool(b[0] != 0) : nil
    case .int64: return u64().map { .int64(Int64(bitPattern: $0)) }
    case .time: return u64().map { .time(Int64(bitPattern: $0)) }
    case .uint64: return u64().map { .uint64($0) }
    case .ref: return u64().map { .ref($0) }
    case .double: return u64().map { .double(Double(bitPattern: $0)) }
    }
  }

  /// `ino`'s attributes, those named only if `names` is given.
  func attributes(_ ino: UInt64, only names: [String]? = nil) throws(TaisceError) -> [FsIPC.Attribute] {
    var out: [FsIPC.Attribute] = []
    for (name, _) in try fs.attributes(ino) {
      let text = String(decoding: name, as: UTF8.self)
      if let names, !names.contains(where: { NodeIPC.same($0, text) }) { continue }
      guard let v = try fs.attribute(ino, name) else { continue }
      let (kind, value) = Self.encode(v)
      out.append(FsIPC.Attribute(name: text, kind: kind, value: value))
    }
    return out
  }

  // MARK: Errors

  static func nodeError(_ e: TaisceError) -> NodeError {
    switch e {
    case .notFound: .notFound
    case .exists: .exists
    case .notDirectory: .notDirectory
    case .isDirectory: .isDirectory
    case .notEmpty: .notEmpty
    case .nameTooLong: .badName
    case .invalid: .invalid
    default: .io
    }
  }

  static func fsError(_ e: TaisceError) -> FsIPC.FsError {
    switch e {
    case .notFound: .notFound
    case .exists: .exists
    case .notDirectory: .notDirectory
    case .isDirectory: .isDirectory
    case .notEmpty: .notEmpty
    case .nameTooLong: .badName
    case .invalid: .invalid
    case .noSpace: .noSpace
    case .readOnly: .readOnly
    case .badQuery: .badQuery
    case .needsIndex: .needsIndex
    case .tooLarge: .tooLarge
    default: .io
    }
  }
}

/// One channel to a node.
final class FsSession {
  let ino: UInt64
  let service: FsService
  /// A file's, which Taisce counts open.
  let file: Bool
  var id: UInt64 = 0
  var pending: [NodeIPC.Change] = []
  /// Set when its server goes: watchers drop it then (no weak references
  /// in tier 0).
  var closed = false
  /// Its ring, if one is attached (D103).
  var ring: NodeRing?

  init(ino: UInt64, service: FsService, file: Bool) {
    self.ino = ino
    self.service = service
    self.file = file
  }

  func takePending() -> [NodeIPC.Change] {
    defer { pending = [] }
    return pending
  }
}

/// Held only by a session's server: when the dispatcher drops the server
/// (its channel closed), the session ends.
final class FsSessionEnd {
  let session: FsSession
  init(_ session: FsSession) { self.session = session }
  deinit {
    session.ring?.close()
    session.service.ended(session)
  }
}

/// Rings `bell` `delay` after each request: a thread, asleep in the
/// kernel while no commit is due, so an idle volume arms nothing.
final class Committer: @unchecked Sendable {
  let requests: Handle
  let bell: Handle
  let delay: Int64

  init(bell: consuming Handle, delay: Int64) throws(Status) {
    requests = try Counter.create()
    self.bell = bell
    self.delay = delay
    _ = try Thread.spawn { [self] in run() }.release()
  }

  func request() { try? Counter.add(requests, 1) }

  func run() {
    var asked: Int64 = 0
    while true {
      guard (try? Counter.wait(requests, until: asked + 1)) != nil else { return }
      asked = (try? Counter.read(requests)) ?? asked + 1
      sleep(until: Clock.monotonic() + delay)
      try? Counter.add(bell, 1)
    }
  }
}
