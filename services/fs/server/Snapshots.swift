// SPDX-License-Identifier: BSD-3-Clause

// The volume's snapshots (S2, D153): `snap/YYYY/MMDD[.N]/`, each the volume
// as a commit left it, read-only, as Plan 9's dump is; and `ctl`'s `snap`
// and `unsnap`. Served on the volume's thread, which alone touches the
// volume, by Node alone: walks, stats, listings and reads. A snapshot is
// found again by its txg at each request, so one deleted under a channel
// says notFound from then on.

import Fs
import IPC
import Node
import Sys
import Taisce

/// What `ctl` asks of the volume's thread.
enum SnapshotRequest {
  case snap
  case unsnap([UInt8])
}

/// Where a snapshot channel is: the years, a year's days, or a node in one
/// snapshot.
enum SnapshotPlace {
  case top
  case year([UInt8])
  case node(txg: UInt64, ino: UInt64)
}

extension FsService {
  /// A `ctl` line, on the tree's thread: `snap`, or `unsnap` and a
  /// snapshot's name. Run on the volume's thread; `status` says how it went.
  public func control(_ line: String) throws(NodeError) {
    let words = line.utf8.split(whereSeparator: { $0 == 0x20 || $0 == 0x0A || $0 == 0x09 }).map { Array($0) }
    let request: SnapshotRequest
    if words.count == 1, words[0] == Array("snap".utf8) {
      request = .snap
    } else if words.count == 2, words[0] == Array("unsnap".utf8) {
      request = .unsnap(words[1])
    } else {
      throw .invalid
    }
    lock.withLock { requests.append(request) }
    try? Counter.add(requestBell, 1)
  }

  /// Runs what `ctl` asked, on the volume's thread.
  func runRequests() {
    let asked = lock.withLock { () -> [SnapshotRequest] in
      defer { requests = [] }
      return requests
    }
    for request in asked {
      switch request {
      case .snap:
        // Writes behind first: a snapshot is what's committed.
        let failed = writeBackAll()
        do throws(TaisceError) {
          let s = try fs.takeSnapshot(now: Self.now)
          cleaned()
          commits += 1
          noteSnapshot("snap " + String(decoding: s.name, as: UTF8.self) + (failed == nil ? " taken" : " taken, without a write behind that failed"))
        } catch {
          noteSnapshot("snap failed: " + Self.words(error))
        }
      case .unsnap(let name):
        do throws(TaisceError) {
          guard let s = try fs.snapshots().first(where: { $0.name == name }) else { throw .notFound }
          try fs.deleteSnapshot(s)
          commits += 1
          noteSnapshot("unsnap " + String(decoding: name, as: UTF8.self) + " deleted")
        } catch {
          noteSnapshot("unsnap " + String(decoding: name, as: UTF8.self) + " failed: " + Self.words(error))
        }
      }
    }
    render()
  }

  /// `status`'s last few lines about snapshots, and their count.
  func noteSnapshot(_ line: String) {
    let count = (try? fs.snapshots().count) ?? 0
    lock.withLock {
      shown.snapshots = count
      shown.snapshotLines.append(line)
      if shown.snapshotLines.count > 4 { shown.snapshotLines.removeFirst() }
    }
  }

  static func words(_ e: TaisceError) -> String {
    switch e {
    case .notFound: "no such snapshot"
    case .noSpace: "no space"
    case .readOnly: "the volume takes no changes"
    case .tooLarge: "too large"
    case .corrupt: "the volume is damaged"
    case .io: "an I/O error"
    default: "an error"
    }
  }

  /// A channel to the snapshots' top directory.
  public func snapshotRoot() throws(NodeError) -> Handle { try snapshotChannel(.top) }

  func snapshotChannel(_ place: SnapshotPlace) throws(NodeError) -> Handle {
    do throws(Status) {
      let ends = try Channel.create()
      try dispatcher.add(NodeIPC.NodeServer(channel: ends.b, impl: SnapshotSession(service: self, place: place)))
      return ends.a
    } catch {
      throw .io
    }
  }

  // MARK: Reading them

  func snapshotList() -> [SnapshotRecord] { (try? fs.snapshots()) ?? [] }

  static func year(_ name: [UInt8]) -> [UInt8] { Array(name.prefix { $0 != 0x2F }) }
  static func day(_ name: [UInt8]) -> [UInt8] {
    guard let slash = name.firstIndex(of: 0x2F) else { return name }
    return Array(name[(slash + 1)...])
  }

  /// The years with snapshots, in order.
  func snapshotYears() -> [[UInt8]] {
    var out: [[UInt8]] = []
    for s in snapshotList() where !out.contains(Self.year(s.name)) { out.append(Self.year(s.name)) }
    return out
  }

  /// A year's snapshots, oldest first.
  func snapshots(in year: [UInt8]) -> [SnapshotRecord] { snapshotList().filter { Self.year($0.name) == year } }

  func snapshot(_ txg: UInt64) throws(NodeError) -> SnapshotRecord {
    guard let s = snapshotList().first(where: { $0.txg == txg }) else { throw .notFound }
    return s
  }

  /// `body` on the volume as snapshot `txg` keeps it.
  func inSnapshot<T>(_ txg: UInt64, _ body: (inout FileSystem<NodeDevice>) throws(TaisceError) -> T)
    throws(NodeError) -> T
  {
    let s = try snapshot(txg)
    do throws(TaisceError) { return try fs.withSnapshot(s, body) } catch { throw Self.nodeError(error) }
  }

  /// A place's qid: the top and the years apart from the nodes, each
  /// node's path its inode with the snapshot's txg above it, so two
  /// snapshots' copies of one file differ.
  static func snapshotQid(_ place: SnapshotPlace, _ inode: Inode? = nil) -> NodeIPC.Qid {
    switch place {
    case .top: return NodeIPC.Qid(path: 1 << 63, version: 0, kind: .directory)
    case .year(let y):
      return NodeIPC.Qid(path: 1 << 63 | 1 << 62 | y.reduce(0) { $0 << 8 | UInt64($1) }, version: 0, kind: .directory)
    case .node(let txg, let ino):
      return NodeIPC.Qid(path: (txg & 0x7FFF) << 48 | ino, version: UInt32(truncatingIfNeeded: inode?.version ?? 0),
                         kind: inode?.type == .directory ? .directory : .file)
    }
  }
}

/// One channel into the snapshots, at `place`: read-only.
struct SnapshotSession: NodeIPC.NodeHandler {
  let service: FsService
  let place: SnapshotPlace

  mutating func batch(_ ops: [NodeIPC.Op], open: Bool) -> NodeIPC.Reply {
    var results: [NodeIPC.Outcome] = []
    guard ops.count <= NodeIPC.maxOps else { return failed(results, 0, .tooManyOps) }
    var at = place
    for i in ops.indices {
      do throws(NodeError) {
        switch ops[i] {
        case .walk(let names):
          var qids: [NodeIPC.Qid] = []
          for name in names {
            at = try step(at, name)
            qids.append(try stat(at, 0).qid)
          }
          results.append(.walked(qids))
        case .stat(let fields): results.append(.stat(try stat(at, fields)))
        case .readdir(let cursor, let max, let fields): results.append(.dir(try readdir(at, cursor, max, fields)))
        case .read(let offset, let max): results.append(.data(try read(at, offset, max)))
        case .watch: throw .unsupported
        case .write, .create, .remove: throw .denied
        }
      } catch {
        return failed(results, i, error)
      }
    }
    guard open else { return NodeIPC.Reply(results: results, failure: nil, node: nil) }
    do throws(NodeError) {
      return NodeIPC.Reply(results: results, failure: nil, node: try service.snapshotChannel(at))
    } catch {
      return failed(results, ops.count, error)
    }
  }

  func failed(_ results: [NodeIPC.Outcome], _ index: Int, _ error: NodeError) -> NodeIPC.Reply {
    NodeIPC.Reply(results: results, failure: NodeIPC.Failure(index: UInt32(index), code: error.rawValue), node: nil)
  }

  mutating func openAhead(_ ops: [NodeIPC.Op], max: UInt32) -> NodeIPC.Ahead { NodeIPC.Ahead(batch(ops, open: true)) }

  /// No fids: a client opens channels, as into a NodeTree.
  func openFid(_ ops: [NodeIPC.Op], fid: UInt32, ahead: UInt32, clunk: [UInt32]) throws(NodeError) -> NodeIPC.Ahead {
    throw .unsupported
  }
  func fidBatch(_ fid: UInt32, _ ops: [NodeIPC.Op], open: Bool, clunk: [UInt32]) throws(NodeError) -> NodeIPC.Reply {
    throw .unsupported
  }
  func clunk(_ fids: [UInt32]) throws(NodeError) { throw .unsupported }
  func attach(_ bulk: consuming NodeIPC.Bulk) throws(NodeError) { throw .unsupported }
  func memory(executable: Bool) throws(NodeError) -> NodeIPC.Memory { throw .unsupported }
  func wstat(_ change: NodeIPC.Wstat) throws(NodeError) { throw .denied }

  func clone(_ channel: consuming Handle) {
    _ = try? service.dispatcher.add(NodeIPC.NodeServer(channel: channel, impl: SnapshotSession(service: service, place: place)))
  }

  /// One name walked from `at`.
  func step(_ at: SnapshotPlace, _ name: String) throws(NodeError) -> SnapshotPlace {
    let up = NodeIPC.same(name, "..")
    guard up || NodeIPC.isValidName(name) else { throw .badName }
    let bytes = Array(name.utf8)
    switch at {
    case .top:
      if up { return .top }
      guard service.snapshotYears().contains(bytes) else { throw .notFound }
      return .year(bytes)
    case .year(let y):
      if up { return .top }
      guard let s = service.snapshots(in: y).first(where: { FsService.day($0.name) == bytes }) else { throw .notFound }
      return .node(txg: s.txg, ino: FileSystem<NodeDevice>.root)
    case .node(let txg, let ino):
      if up, ino == FileSystem<NodeDevice>.root { return .year(FsService.year(try service.snapshot(txg).name)) }
      let next = try service.inSnapshot(txg) { (v: inout FileSystem<NodeDevice>) throws(TaisceError) in
        up ? try v.stat(ino).parent : try v.lookup(ino, bytes)
      }
      return .node(txg: txg, ino: next)
    }
  }

  func stat(_ at: SnapshotPlace, _ fields: UInt32) throws(NodeError) -> NodeIPC.Stat {
    switch at {
    case .top:
      return NodeIPC.Stat(qid: FsService.snapshotQid(at), name: "snap", size: 0, modified: 0, attributes: [])
    case .year(let y):
      return NodeIPC.Stat(qid: FsService.snapshotQid(at), name: String(decoding: y, as: UTF8.self), size: 0,
                          modified: 0, attributes: [])
    case .node(let txg, let ino):
      let s = try service.snapshot(txg)
      return try service.inSnapshot(txg) { (v: inout FileSystem<NodeDevice>) throws(TaisceError) in
        let name = ino == FileSystem<NodeDevice>.root ? FsService.day(s.name) : try v.firstName(ino)?.name ?? []
        return try Self.stat(&v, txg, ino, try v.stat(ino), name, fields)
      }
    }
  }

  /// A node's stat, read in a snapshot's view.
  static func stat(_ v: inout FileSystem<NodeDevice>, _ txg: UInt64, _ ino: UInt64, _ inode: Inode, _ name: [UInt8],
                   _ fields: UInt32) throws(TaisceError) -> NodeIPC.Stat {
    var attributes: [NodeIPC.Attribute] = []
    if fields & NodeIPC.Fields.attributes != 0 {
      for a in try v.attributes(ino) {
        guard let value = try v.attribute(ino, a.name) else { continue }
        let (kind, bytes) = FsService.encode(value)
        attributes.append(NodeIPC.Attribute(name: String(decoding: a.name, as: UTF8.self), kind: kind, value: bytes))
      }
    }
    return NodeIPC.Stat(qid: FsService.snapshotQid(.node(txg: txg, ino: ino), inode), name: String(decoding: name, as: UTF8.self),
                        size: fields & NodeIPC.Fields.size != 0 ? inode.size : 0,
                        modified: fields & NodeIPC.Fields.modified != 0 ? Int64(inode.mtime) : 0,
                        attributes: attributes)
  }

  func readdir(_ at: SnapshotPlace, _ cursor: UInt64, _ max: UInt32, _ fields: UInt32) throws(NodeError)
    -> NodeIPC.DirBatch
  {
    let limit = Int(Swift.max(1, Swift.min(max, 64)))
    switch at {
    case .top, .year:
      let names: [[UInt8]]
      if case .year(let y) = at {
        names = service.snapshots(in: y).map { FsService.day($0.name) }
      } else {
        names = service.snapshotYears()
      }
      let from = Int(clamping: cursor), to = Swift.min(names.count, from + limit)
      var entries: [NodeIPC.Stat] = []
      for i in from..<Swift.max(from, to) {
        let child = try step(at, String(decoding: names[i], as: UTF8.self))
        entries.append(try stat(child, fields))
      }
      return NodeIPC.DirBatch(entries: entries, next: UInt64(Swift.max(from, to)), done: to >= names.count)
    case .node(let txg, let ino):
      // The cursor is one past the last entry's cookie, as fs's listings.
      let (found, entries) = try service.inSnapshot(txg) {
        (v: inout FileSystem<NodeDevice>) throws(TaisceError) -> (DirectoryListing, [NodeIPC.Stat]) in
        let found = try v.list(ino, after: cursor == 0 ? nil : cursor - 1, limit: limit)
        let inodes = try v.stats(found.rows.map { $0.ino })
        var entries: [NodeIPC.Stat] = []
        for i in found.indices {
          entries.append(try Self.stat(&v, txg, found.rows[i].ino, inodes[i], Array(found.name(i)), fields))
        }
        return (found, entries)
      }
      let buckets = found.rows.reduce(into: [UInt64]()) { if $0.last != $1.cookie { $0.append($1.cookie) } }
      let next = (found.rows.last?.cookie ?? cursor &- 1) &+ 1
      return NodeIPC.DirBatch(entries: entries, next: next, done: buckets.count < limit)
    }
  }

  func read(_ at: SnapshotPlace, _ offset: UInt64, _ max: UInt32) throws(NodeError) -> [UInt8] {
    guard case .node(let txg, let ino) = at else { throw .isDirectory }
    return try service.inSnapshot(txg) { (v: inout FileSystem<NodeDevice>) throws(TaisceError) in
      try v.read(ino, offset: offset, count: Swift.min(Int(max), NodeIPC.maxIO))
    }
  }
}
