// SPDX-License-Identifier: BSD-3-Clause

// The fs service's volume (fs(4)): a Taisce volume on a disk's partition,
// served as FsIPC's Directory and File channels, which compose Node, on a
// dispatcher of its own, whose thread alone touches the volume. The
// service's tree mounts the root's channel at `volume`.
//
// Every change is in memory at once; a transaction group commits a second
// after the first change since the last, sooner if many blocks wait, and
// at once on Directory.sync (File.sync writes the intent log instead).
// Watchers and live queries hear of changes from the change journal as
// each operation commits in memory, so they may hear of one a crash then
// loses. Files' bytes are read and written through VMOs (FileVMOs.swift),
// which clients map: a write's pages reach the volume at the next commit
// or File.sync, with the size and times it made. A directory listed from start to end is kept whole while
// the volume doesn't change (Sessions.swift).

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
  /// What checking the volume as it was mounted found (`--check`), or "".
  var checked: String
  /// The nodes the last check counted.
  public private(set) var nodes = 0
  /// The thread that rings for a commit a second after a change.
  let committer: Committer
  var commitPending = false
  /// The journal records watchers have had.
  var journalSeen: UInt64
  /// The channels watching a node, until they close.
  var watchers: [(session: FsSession, ino: UInt64)] = []
  /// Live queries, until their channels close.
  var lives: [LiveState] = []
  /// The files' VMOs its reads go through (FileVMOs.swift, D131).
  var files: FileVMOs
  /// Directories' listings kept whole while the volume hasn't changed,
  /// the last few, and those being kept as their batches are served.
  var listings: [KeptListing] = []
  var building: [KeptListing] = []
  var sessions = 0
  var commits = 0
  /// `status`'s numbers, as the volume's thread last left them, for the
  /// tree's, which makes the text when it is read: an open and a close
  /// each leave them, and formatting the text there was a twentieth of a
  /// small file's open, read and close.
  let lock = Lock()
  var shown = Shown()
  /// The files' VMOs' committed bytes, and when they were last asked.
  var resident = 0
  var residentAt: Int64? = nil
  /// What `ctl` asked, for the volume's thread, and the bell that wakes it
  /// (Snapshots.swift).
  var requests: [SnapshotRequest] = []
  let requestBell: Handle
  static let residentEvery: Int64 = 1_000_000_000

  struct Shown {
    var label = ""
    var txg: UInt64 = 0
    var sessions = 0
    var lives = 0
    var resident = 0
    var dirty = 0
    var files = 0
    var paged = false
    var commits = 0
    var blocks: UInt64 = 0
    var free: UInt64 = 0
    var checked = ""
    var snapshots = 0
    var snapshotLines: [String] = []
  }

  /// Groups wait at most this long (and this many dirty blocks).
  static let commitDelay: Int64 = 1_000_000_000
  static let commitBlocks = 4096

  /// With `pager`, files' VMOs are a pager's, filled by a thread of
  /// their own through the device's second channel (NodeDevice's
  /// `readsConcurrently`); else each is filled whole when made.
  public init(_ fs: consuming FileSystem<NodeDevice>, device: String, dispatcher: IPCDispatcher,
              checked: String = "", pager: Bool = false) throws(Status) {
    var volume = fs
    var thread: PagerThread? = nil
    if pager, let reader = volume.reader(cacheNodes: 64, sharedNodes: 64) {
      thread = try? PagerThread(reader: reader)
    }
    files = FileVMOs(pager: thread)
    self.fs = volume
    self.device = device
    self.checked = checked
    self.dispatcher = dispatcher
    journalSeen = self.fs.nextSeq - 1
    let bell = try Counter.create()
    committer = try Committer(bell: try bell.duplicate(), delay: Self.commitDelay)
    let asked = try Counter.create()
    requestBell = try asked.duplicate()
    // A strong capture (no weak references in tier 0): the service lasts
    // as long as its process.
    try dispatcher.watch(bell, signals: Signals.positive) { [self] _ in
      if let n = try? Counter.read(committer.bell), n > 0 { try? Counter.add(committer.bell, -n) }
      try? commit()
      return true
    }
    try dispatcher.watch(asked, signals: Signals.positive) { [self] _ in
      if let n = try? Counter.read(requestBell), n > 0 { try? Counter.add(requestBell, -n) }
      runRequests()
      return true
    }
    let snapshots = (try? self.fs.snapshots().count) ?? 0
    lock.withLock { shown.snapshots = snapshots }
    render()
  }

  /// A channel to the volume's root directory.
  public func root() throws(NodeError) -> Handle { try channel(FileSystem<NodeDevice>.root) }

  /// The volume and what is open on it.
  public var status: String {
    let s = lock.withLock { shown }
    return """
      volume \(s.label)
      device \(device)
      txg \(s.txg)
      sessions \(s.sessions)
      live-queries \(s.lives)
      files \(s.files) resident \(s.resident) dirty \(s.dirty)\(s.paged ? " paged" : "")
      commits \(s.commits)
      blocks \(s.blocks) free \(s.free) size \(Layout.blockSize)
      snapshots \(s.snapshots)

      """ + s.snapshotLines.map { $0 + "\n" }.joined() + (s.checked.isEmpty ? "" : s.checked + "\n")
  }

  /// Every invariant checked (FileSystem.check), on the volume's thread
  /// before it serves: the fault, or nil.
  public func checkVolume() -> TaisceError? {
    do throws(TaisceError) {
      nodes = try fs.check()
      return nil
    } catch {
      return error
    }
  }

  /// What `status` says of the check.
  public func setChecked(_ text: String) {
    lock.withLock { checked = text }
    render()
  }

  func render() {
    let s = fs.engine.store.volume.superblock
    let free = fs.engine.store.volume.allocator.freeCount
    let (sessions, lives, commits, checked) = (self.sessions, self.lives.count, self.commits, self.checked)
    let (fileCount, paged) = (files.entries.count, files.pager != nil)
    let dirty = files.entries.reduce(0) { $0 + FileVMOs.pages($1.dirty) + FileVMOs.pages($1.cleaning) } * 4096
    // What is resident asks the kernel of each file's VMO, so at most
    // once a second: an open and a close each render.
    let now = Clock.monotonic()
    if residentAt.map({ now - $0 >= Self.residentEvery }) ?? true {
      residentAt = now
      resident = files.entries.reduce(0) { $0 + ((try? VMO.committedBytes($1.vmo)) ?? 0) }
    }
    let resident = self.resident
    lock.withLock {
      if shown.label.isEmpty { shown.label = String(decoding: s.label, as: UTF8.self) }
      shown.txg = s.txg
      shown.sessions = sessions
      shown.lives = lives
      shown.files = fileCount
      shown.resident = resident
      shown.dirty = dirty
      shown.paged = paged
      shown.commits = commits
      shown.blocks = s.layout.blockCount
      shown.free = free
      shown.checked = checked
    }
  }

  public static var now: UInt64 { UInt64(clamping: Clock.realtime()) }

  // MARK: Durability

  /// Commits a group now.
  func commit() throws(TaisceError) {
    commitPending = false
    defer { render() }
    let failed = writeBackAll()
    try fs.sync()
    cleaned()
    commits += 1
    if let failed { throw failed }
  }

  /// Makes everything so far durable through the intent log (File.sync).
  func fsync() throws(TaisceError) {
    let failed = writeBackAll()
    try fs.fsync()
    cleaned()
    if let failed { throw failed }
  }

  /// After every change: watchers and live queries hear of it, and a
  /// commit is due.
  func changed() {
    tell()
    if fs.engine.pendingBlocks + files.dirtyPages > Self.commitBlocks {
      try? commit()
    } else if !commitPending {
      commitPending = true
      committer.request()
    }
    render()
  }

  // MARK: Nodes and channels

  func qid(_ ino: UInt64) throws(TaisceError) -> NodeIPC.Qid { Self.qid(ino, try fs.stat(ino)) }

  static func qid(_ ino: UInt64, _ inode: Inode) -> NodeIPC.Qid {
    NodeIPC.Qid(path: ino, version: UInt32(truncatingIfNeeded: inode.version),
                kind: inode.type == .directory ? .directory : .file)
  }

  /// A channel to `ino`: Directory or File, as it is (`isDirectory`, if
  /// the caller has just looked).
  func channel(_ ino: UInt64, writable: Bool = true, confined: Bool = false, isDirectory known: Bool? = nil)
    throws(NodeError) -> Handle
  {
    let isDirectory: Bool
    if let known {
      isDirectory = known
    } else {
      isDirectory = try node { (s: FsService) throws(TaisceError) in try s.fs.stat(ino).type == .directory }
    }
    do throws(Status) {
      let ends = try Channel.create()
      try serve(ends.b, ino, writable: writable, confined: confined, isDirectory: isDirectory)
      return ends.a
    } catch {
      throw .io
    }
  }

  /// Serves `ino` on `channel`: Directory or File, as `isDirectory` says.
  func serve(_ channel: consuming Handle, _ ino: UInt64, writable: Bool, confined: Bool, isDirectory: Bool)
    throws(Status)
  {
    let session = FsSession(ino: ino, service: self, file: !isDirectory, writable: writable, confined: confined)
    let id: UInt64
    if isDirectory {
      id = try dispatcher.add(FsIPC.DirectoryServer(channel: channel, impl: DirectorySession(session: session, end: FsSessionEnd(session)))) {
        (s: inout FsIPC.DirectoryServer<DirectorySession>) throws(IPCError<Never>) in
        for c in session.takePending() { try NodeIPC.NodeEventSender.sendChanged(c, on: s.connection) }
      }
    } else {
      id = try dispatcher.add(FsIPC.FileServer(channel: channel, impl: FileSession(session: session, end: FsSessionEnd(session)))) {
        (s: inout FsIPC.FileServer<FileSession>) throws(IPCError<Never>) in
        for c in session.takePending() { try NodeIPC.NodeEventSender.sendChanged(c, on: s.connection) }
      }
      fs.opened(ino)  // an open file outlives its last name (an orphan)
    }
    session.id = id
    sessions += 1
    render()
  }

  /// Fid `fid` of `owner`'s channel, at `ino`: a session of its own, with
  /// the channel's rights and no channel (`isDirectory`, if the caller
  /// has just looked).
  func openFid(_ fid: UInt32, _ ino: UInt64, of owner: FsSession, isDirectory known: Bool? = nil) throws(NodeError) {
    let isDirectory: Bool
    if let known {
      isDirectory = known
    } else {
      isDirectory = try node { (s: FsService) throws(TaisceError) in try s.fs.stat(ino).type == .directory }
    }
    let session = FsSession(ino: ino, service: self, file: !isDirectory, writable: owner.writable,
                            confined: owner.confined)
    owner.fids.append((fid, session))
    if !isDirectory { fs.opened(ino) }
    sessions += 1
    render()
  }

  /// Lets `owner`'s fids `fids` go (those it hasn't, ignored).
  func clunk(_ fids: [UInt32], of owner: FsSession) {
    for fid in fids {
      if let i = owner.fids.firstIndex(where: { $0.fid == fid }) { ended(owner.fids.remove(at: i).session) }
    }
  }

  /// A session's end, on the dispatcher's thread.
  func ended(_ session: FsSession) {
    session.closed = true
    sessions -= 1
    if session.file { try? fs.closed(session.ino) }
    render()
  }

  /// A node a walk reached: its inode as the walk read it, and the name
  /// it was reached by (nil by `..`).
  struct Reached {
    var ino: UInt64
    var inode: Inode
    var name: String?
  }

  /// Walks `names` from `ino`, every one there (`..` above the root stays
  /// at the root): a qid for each, where it ended, and what it reached
  /// there (nil for no names).
  func walk(from ino: UInt64, _ names: [String]) throws(NodeError) -> ([NodeIPC.Qid], UInt64, Reached?) {
    guard names.count <= NodeIPC.maxWalk else { throw .tooManyNames }
    guard names.allSatisfy({ NodeIPC.same($0, "..") || NodeIPC.isValidName($0) }) else { throw .badName }
    // Each node's inode read once: the next name's step reuses it. The
    // first node's is read only if a step needs it: `..`, or a lookup
    // that fails, which says notDirectory for a file.
    var at = ino
    var inode: Inode? = nil
    var qids: [NodeIPC.Qid] = []
    qids.reserveCapacity(names.count)
    for name in names {
      let (here, from) = (inode, at)
      at = try node { (s: FsService) throws(TaisceError) in
        if NodeIPC.same(name, "..") {
          if from == FileSystem<NodeDevice>.root { return from }
          if let here { return here.parent }
          return try s.fs.stat(from).parent
        }
        if let here, here.type != .directory { throw .notDirectory }
        do throws(TaisceError) {
          return try s.fs.lookup(from, Array(name.utf8))
        } catch {
          if here == nil, error == .notFound, try s.fs.stat(from).type != .directory { throw .notDirectory }
          throw error
        }
      }
      let reached = try node { (s: FsService) throws(TaisceError) in try s.fs.stat(at) }
      inode = reached
      qids.append(Self.qid(at, reached))
    }
    guard let inode, let last = names.last else { return (qids, at, nil) }
    return (qids, at, Reached(ino: at, inode: inode, name: NodeIPC.same(last, "..") ? nil : last))
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
    lives.removeAll { $0.closed }
    for live in lives { update(live) }
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

  // MARK: Live queries

  /// `ino`'s path in the volume, or none if it has none now.
  func path(_ ino: UInt64) -> String {
    guard let p = try? fs.path(ino) else { return "" }
    return String(decoding: p, as: UTF8.self)
  }

  /// Starts a live query: the client's end of its channel, which hears
  /// the matches now, then `current`, then each change.
  func live(_ text: String, scan: Bool) throws(FsIPC.FsError) -> Handle {
    let query = try call { (s: FsService) throws(TaisceError) in try s.fs.live(Array(text.utf8), scan: scan) }
    do throws(Status) {
      let ends = try Channel.create()
      let state = LiveState(query: query, text: text, scan: scan)
      state.pending = query.results.map { added($0, seq: query.seq) }
        + [FsIPC.QueryChange(kind: .current, node: 0, path: "", seq: query.seq)]
      state.id = try dispatcher.add(FsIPC.LiveQueryServer(channel: ends.b, impl: LiveSession(state: state))) {
        (s: inout FsIPC.LiveQueryServer<LiveSession>) throws(IPCError<Never>) in
        let changes = state.pending
        state.pending = []
        for c in changes { try s.sendChanged(c) }
      }
      lives.append(state)
      dispatcher.wake(state.id)
      render()
      return ends.a
    } catch {
      throw .io
    }
  }

  func added(_ ino: UInt64, seq: UInt64) -> FsIPC.QueryChange {
    FsIPC.QueryChange(kind: .added, node: ino, path: path(ino), seq: seq)
  }

  /// Brings a live query up to date; if the journal no longer reaches it,
  /// runs it again: `reset`, its matches, `current`.
  func update(_ live: LiveState) {
    var changes: [FsIPC.QueryChange] = []
    do throws(TaisceError) {
      for u in try fs.update(&live.query) {
        switch u {
        case .added(let ino, let seq): changes.append(added(ino, seq: seq))
        case .removed(let ino, let seq): changes.append(FsIPC.QueryChange(kind: .removed, node: ino, path: path(ino), seq: seq))
        case .changed(let ino, let seq): changes.append(FsIPC.QueryChange(kind: .changed, node: ino, path: path(ino), seq: seq))
        }
      }
    } catch {
      guard let again = try? fs.live(Array(live.text.utf8), scan: live.scan) else { return }
      live.query = again
      changes = [FsIPC.QueryChange(kind: .reset, node: 0, path: "", seq: again.seq)]
        + again.results.map { added($0, seq: again.seq) }
        + [FsIPC.QueryChange(kind: .current, node: 0, path: "", seq: again.seq)]
    }
    guard !changes.isEmpty else { return }
    live.pending += changes
    dispatcher.wake(live.id)
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

/// One channel to a node, or one fid on a channel.
final class FsSession {
  let ino: UInt64
  let service: FsService
  /// A file's, which Taisce counts open.
  let file: Bool
  /// Whether writes, resizes and attribute changes are allowed.
  let writable: Bool
  /// A capability from the file chooser (D111): cannot remove or rename
  /// itself in its parent directory.
  let confined: Bool
  var id: UInt64 = 0
  var pending: [NodeIPC.Change] = []
  /// Set when its server goes: watchers drop it then (no weak references
  /// in tier 0).
  var closed = false
  /// Its ring, if one is attached (D103).
  var ring: NodeRing?
  /// The fids open on its channel, each a session of its own, in no
  /// order: a process's few open files.
  var fids: [(fid: UInt32, session: FsSession)] = []

  init(ino: UInt64, service: FsService, file: Bool, writable: Bool = true, confined: Bool = false) {
    self.ino = ino
    self.service = service
    self.file = file
    self.writable = writable
    self.confined = confined
  }

  /// Its fid `fid`'s session, if open.
  func fid(_ fid: UInt32) -> FsSession? {
    for f in fids where f.fid == fid { return f.session }
    return nil
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
    // Its channel's fids go with it.
    for f in session.fids { session.service.ended(f.session) }
    session.fids = []
    session.service.ended(session)
  }
}

/// A live query and what its channel hasn't sent yet.
final class LiveState {
  var query: LiveQuery
  let text: String
  let scan: Bool
  var id: UInt64 = 0
  var pending: [FsIPC.QueryChange] = []
  var closed = false

  init(query: LiveQuery, text: String, scan: Bool) {
    self.query = query
    self.text = text
    self.scan = scan
  }
}

/// A live query's channel takes no requests; when it goes, so does the query.
struct LiveSession: FsIPC.LiveQueryHandler {
  let owner: LiveOwner
  init(state: LiveState) { owner = LiveOwner(state) }
}

final class LiveOwner {
  let state: LiveState
  init(_ state: LiveState) { self.state = state }
  deinit { state.closed = true }
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
