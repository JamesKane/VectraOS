// SPDX-License-Identifier: BSD-3-Clause

// What a Directory or File channel does: Node's batch, wstat and memory,
// and Attributes', which both compose, then each one's own: a directory's
// listings (whole ones kept while the volume doesn't change), renames,
// queries, live queries and indices; a file's resize and map. A batch runs
// its operations on a current node, which starts at the channel's, as
// NodeTree's do. Every change to a file's bytes, name or life keeps its
// mapping current (MappedFiles.swift).

import Fs
import IPC
import Node
import Sys
import Taisce

/// Node's and Attributes' methods, for files and directories alike.
protocol NodeSession: NodeIPC.NodeHandler, FsIPC.AttributesHandler {
  var session: FsSession { get }
}

extension NodeSession {
  var service: FsService { session.service }
  var ino: UInt64 { session.ino }

  // MARK: Node

  mutating func batch(_ ops: [NodeIPC.Op], open: Bool) -> NodeIPC.Reply {
    var at = ino
    var reached: FsService.Reached? = nil
    return run(ops, open: open, at: &at, reached: &reached)
  }

  /// The batch, and a file's first bytes: a volume's reads change nothing
  /// and wait for nothing. None for a directory (Taisce's read refuses it).
  mutating func openAhead(_ ops: [NodeIPC.Op], max: UInt32) -> NodeIPC.Ahead {
    var at = ino
    var reached: FsService.Reached? = nil
    let reply = run(ops, open: true, at: &at, reached: &reached)
    guard reply.failure == nil, max > 0 else { return NodeIPC.Ahead(reply) }
    return NodeIPC.Ahead(reply, data: try? read(at, offset: 0, max: max, reached))
  }

  // MARK: Fids

  /// The batch, its node kept as fid `fid` of this channel's: a session
  /// with no channel of its own. And a file's first bytes, as `openAhead`.
  mutating func openFid(_ ops: [NodeIPC.Op], fid: UInt32, ahead: UInt32, clunk: [UInt32]) throws(NodeError)
    -> NodeIPC.Ahead
  {
    service.clunk(clunk, of: session)
    guard session.fid(fid) == nil else { throw .exists }
    var at = ino
    var reached: FsService.Reached? = nil
    let reply = run(ops, open: true, at: &at, fid: fid, reached: &reached)
    guard reply.failure == nil, ahead > 0 else { return NodeIPC.Ahead(reply) }
    return NodeIPC.Ahead(reply, data: try? read(at, offset: 0, max: ahead, reached))
  }

  /// A batch from fid `fid`'s node, as the fid's session (its rights).
  mutating func fidBatch(_ fid: UInt32, _ ops: [NodeIPC.Op], open: Bool, clunk: [UInt32]) throws(NodeError)
    -> NodeIPC.Reply
  {
    service.clunk(clunk, of: session)
    guard let f = session.fid(fid) else { throw .notFound }
    // A watch's changes go out on a channel, which a fid hasn't.
    for op in ops { if case .watch = op { throw .unsupported } }
    var on = FidSession(session: f)
    var at = f.ino
    var reached: FsService.Reached? = nil
    return on.run(ops, open: open, at: &at, reached: &reached)
  }

  mutating func clunk(_ fids: [UInt32]) throws(NodeError) { service.clunk(fids, of: session) }

  /// The channel's node, with its rights, on the caller's channel.
  mutating func clone(_ channel: consuming Handle) {
    _ = try? service.serve(channel, ino, writable: session.writable, confined: session.confined,
                           isDirectory: !session.file)
  }

  /// A batch from the channel's node; `at`, the node it ended at. With
  /// `open` and `fid`, the node is kept as that fid, not given a channel.
  /// Runs `ops` from `at`, leaving it where they end; `reached`, what the
  /// last walk reached, while nothing since has changed it.
  mutating func run(_ ops: [NodeIPC.Op], open: Bool, at: inout UInt64, fid: UInt32? = nil,
                    reached: inout FsService.Reached?) -> NodeIPC.Reply
  {
    var results: [NodeIPC.Outcome] = []
    guard ops.count <= NodeIPC.maxOps else { return failed(results, 0, .tooManyOps) }
    var walkedKind: NodeIPC.NodeKind? = nil  // `at`'s, as the walk that reached it found it
    for i in ops.indices {
      do throws(NodeError) {
        switch ops[i] {
        case .walk(let names):
          // A confined file (the chooser's) reaches nothing but itself.
          if session.confined, !names.isEmpty { throw .denied }
          let (qids, end, r) = try service.walk(from: at, names)
          results.append(.walked(qids))
          at = end
          if let r { reached = r }
          walkedKind = qids.last?.kind
        case .stat(let fields):
          results.append(.stat(try stat(at, fields, reached)))
        case .readdir(let cursor, let max, let fields):
          results.append(.dir(try readdir(at, cursor: cursor, max: max, fields: fields)))
        case .read(let offset, let max):
          results.append(.data(try read(at, offset: offset, max: max, reached)))
        case .write(let offset, let data):
          reached = nil
          results.append(.wrote(try write(at, offset: offset, data)))
        case .watch(let since):
          results.append(.watching(service.watch(session, at, since: since)))
        case .create(let name, let kind):
          walkedKind = nil
          reached = nil
          at = try create(at, name, kind: kind)
          results.append(.created(try service.node { (s: FsService) throws(TaisceError) in try s.qid(at) }))
        case .remove:
          walkedKind = nil
          reached = nil
          try remove(at)
          results.append(.removed)
        }
      } catch {
        return failed(results, i, error)
      }
    }
    guard open else { return NodeIPC.Reply(results: results, failure: nil, node: nil) }
    do throws(NodeError) {
      if let fid {
        try service.openFid(fid, at, of: session, isDirectory: walkedKind.map { $0 == .directory })
        return NodeIPC.Reply(results: results, failure: nil, node: nil)
      }
      return NodeIPC.Reply(results: results, failure: nil,
                           node: try service.channel(at, writable: session.writable, confined: session.confined,
                                                     isDirectory: walkedKind.map { $0 == .directory }))
    } catch {
      return failed(results, ops.count, error)  // the open itself
    }
  }

  func failed(_ results: [NodeIPC.Outcome], _ index: Int, _ error: NodeError) -> NodeIPC.Reply {
    NodeIPC.Reply(results: results, failure: NodeIPC.Failure(index: UInt32(index), code: error.rawValue), node: nil)
  }

  /// The node's stat; `reached`, what a walk just read of it, if it is
  /// that node (its name, if the node has no other).
  func stat(_ ino: UInt64, _ fields: UInt32, _ reached: FsService.Reached? = nil) throws(NodeError) -> NodeIPC.Stat {
    try service.node { (s: FsService) throws(TaisceError) in
      let known = reached?.ino == ino ? reached : nil
      let inode: Inode
      if let k = known { inode = k.inode } else { inode = try s.fs.stat(ino) }
      let name: String
      if ino == FileSystem<VolumeDevice>.root {
        name = ""
      } else if let walked = known?.name, inode.links == 1 {
        name = walked
      } else {
        name = try s.fs.firstName(ino).map { String(decoding: $0.name, as: UTF8.self) } ?? ""
      }
      let attributes = fields & NodeIPC.Fields.attributes == 0 ? [] : try s.attributes(ino).map {
        NodeIPC.Attribute(name: $0.name, kind: $0.kind, value: $0.value)
      }
      return NodeIPC.Stat(qid: FsService.qid(ino, inode), name: name,
                          size: fields & NodeIPC.Fields.size != 0 ? inode.size : 0,
                          modified: fields & NodeIPC.Fields.modified != 0 ? Int64(inode.mtime) : 0,
                          attributes: attributes)
    }
  }

  func readdir(_ ino: UInt64, cursor: UInt64, max: UInt32, fields: UInt32) throws(NodeError) -> NodeIPC.DirBatch {
    let listing: FsIPC.Listing
    do throws(FsIPC.FsError) {
      listing = try service.list(ino, cursor: cursor, max: max, attributes: fields & NodeIPC.Fields.attributes != 0 ? nil : [],
                                 status: fields & (NodeIPC.Fields.size | NodeIPC.Fields.modified) != 0)
    } catch .notDirectory {
      throw .notDirectory
    } catch {
      throw .io
    }
    let entries = listing.entries.map { e in
      NodeIPC.Stat(qid: NodeIPC.Qid(path: e.node, version: 0, kind: e.kind == NodeType.directory.rawValue ? .directory : .file),
                   name: e.name, size: fields & NodeIPC.Fields.size != 0 ? e.size : 0,
                   modified: fields & NodeIPC.Fields.modified != 0 ? e.modified : 0,
                   attributes: e.attributes.map { NodeIPC.Attribute(name: $0.name, kind: $0.kind, value: $0.value) })
    }
    return NodeIPC.DirBatch(entries: entries, next: listing.next, done: listing.done)
  }

  func read(_ ino: UInt64, offset: UInt64, max: UInt32, _ reached: FsService.Reached? = nil) throws(NodeError)
    -> [UInt8]
  {
    // Taisce's read says .isDirectory itself, from the one stat it makes
    // or the one a walk just made.
    try service.node { (s: FsService) throws(TaisceError) in
      let count = Swift.min(Int(max), NodeIPC.maxIO)
      if let r = reached, r.ino == ino { return try s.readCached(ino, offset: offset, count: count, r.inode) }
      return try s.readCached(ino, offset: offset, count: count)
    }
  }

  func write(_ ino: UInt64, offset: UInt64, _ data: [UInt8]) throws(NodeError) -> UInt32 {
    guard session.writable else { throw .denied }
    guard data.count <= NodeIPC.maxIO else { throw .invalid }
    try service.node { (s: FsService) throws(TaisceError) in try s.writeCached(ino, offset: offset, data) }
    service.changed()
    return UInt32(data.count)
  }

  func create(_ dir: UInt64, _ name: String, kind: NodeIPC.NodeKind) throws(NodeError) -> UInt64 {
    guard session.writable, !session.confined else { throw .denied }
    guard NodeIPC.isValidName(name), !NodeIPC.same(name, "..") else { throw .badName }
    guard kind != .service else { throw .unsupported }
    let child = try service.node { (s: FsService) throws(TaisceError) in
      try s.fs.create(dir, Array(name.utf8), kind == .directory ? .directory : .file,
                      mode: kind == .directory ? 0o755 : 0o644, now: FsService.now)
    }
    service.changed()
    return child
  }

  func remove(_ ino: UInt64) throws(NodeError) {
    guard session.writable, !session.confined, ino != FileSystem<VolumeDevice>.root else { throw .denied }
    try service.node { (s: FsService) throws(TaisceError) in
      guard let (dir, name) = try s.fs.names(ino).first else { throw .notFound }
      if try s.fs.stat(ino).type == .directory {
        try s.fs.rmdir(dir, name, now: FsService.now)
      } else {
        try s.fs.unlink(dir, name, now: FsService.now)
      }
    }
    service.cacheGone(ino)
    service.changed()
  }

  /// A ring for the channel's file (D103): each entry read or written on
  /// the dispatcher's thread, the volume's, and answered at once.
  mutating func attach(_ bulk: consuming NodeIPC.Bulk) throws(NodeError) {
    guard session.ring == nil else { throw .exists }
    let service = self.service, ino = self.ino, writable = session.writable
    session.ring = unsafe try NodeRing(bulk, dispatcher: service.dispatcher) { op, offset, data, done in
      do throws(NodeError) {
        if op == NodeBulk.read {
          // Straight into the entry's chunk (D127 finding 6).
          let count = try service.node { (s: FsService) throws(TaisceError) in
            try unsafe s.readCached(ino, offset: offset, into: data)
          }
          done(.success(UInt32(count)))
        } else {
          guard writable else { throw .denied }
          let bytes = unsafe Array(UnsafeRawBufferPointer(data))
          try service.node { (s: FsService) throws(TaisceError) in try s.writeCached(ino, offset: offset, bytes) }
          service.changed()
          done(.success(UInt32(bytes.count)))
        }
      } catch {
        done(.failure(error))
      }
    }
  }

  /// The file's bytes copied into a VMO, which can't run.
  func memory(executable: Bool) throws(NodeError) -> NodeIPC.Memory {
    let ino = self.ino
    let bytes = try service.node { (s: FsService) throws(TaisceError) in
      let inode = try s.fs.stat(ino)
      guard inode.type != .directory else { throw .isDirectory }
      return try s.readCached(ino, offset: 0, count: Int(inode.size), inode)
    }
    guard !executable else { throw .denied }
    do throws(Status) {
      let vmo = try VMO.create(size: Swift.max(bytes.count, 1))
      if !bytes.isEmpty {
        let m = try VMO.map(vmo, length: (bytes.count + 4095) & ~4095)
        m.write(bytes, at: 0)
      }
      return NodeIPC.Memory(vmo: try vmo.replace([.basic, .read, .map, .getProperty]), size: UInt64(bytes.count))
    } catch {
      throw .io
    }
  }

  /// Plan 9's wstat, all or none: a new name in its directory (none
  /// there by it), a time, a file's length.
  func wstat(_ change: NodeIPC.Wstat) throws(NodeError) {
    guard session.writable else { throw .denied }
    if session.confined, change.name != nil { throw .denied }
    let ino = self.ino
    if let name = change.name, !NodeIPC.isValidName(name) || NodeIPC.same(name, "..") { throw .badName }
    // The root has no name to change, nor is it the client's to touch.
    if change.name != nil || change.modified != nil, ino == FileSystem<VolumeDevice>.root { throw .denied }
    try service.node { (s: FsService) throws(TaisceError) in
      let inode = try s.fs.stat(ino)
      var place: (dir: UInt64, name: [UInt8])?
      if let name = change.name {
        guard let (dir, old) = try s.fs.names(ino).first else { throw .notFound }
        let new = Array(name.utf8)
        if new != old {
          do throws(TaisceError) {
            _ = try s.fs.lookup(dir, new)
            throw .exists
          } catch .notFound {}
          place = (dir, old)
        }
      }
      if change.size != nil { guard inode.type != .directory else { throw .isDirectory } }
      let now = FsService.now
      if let size = change.size { try s.resizeFile(ino, to: size, now: now) }
      if let modified = change.modified { try s.fs.setAttributes(ino, mtime: UInt64(clamping: modified), now: now) }
      if let (dir, old) = place, let name = change.name { try s.fs.rename(dir, old, dir, Array(name.utf8), now: now) }
    }
    if change.name != nil { service.cacheRenamed() }  // any mapped file's path may have moved
    service.changed()
  }

  // MARK: Attributes

  mutating func getAttribute(_ name: String) throws(FsIPC.FsError) -> FsIPC.Attribute {
    let ino = self.ino
    let value = try service.call { (s: FsService) throws(TaisceError) in try s.fs.attribute(ino, Array(name.utf8)) }
    guard let value else { throw .notFound }
    let (kind, bytes) = FsService.encode(value)
    return FsIPC.Attribute(name: name, kind: kind, value: bytes)
  }

  mutating func setAttribute(_ attribute: FsIPC.Attribute) throws(FsIPC.FsError) {
    guard session.writable else { throw .readOnly }
    guard let value = FsService.decode(attribute.kind, attribute.value) else { throw .invalid }
    let ino = self.ino
    try service.call { (s: FsService) throws(TaisceError) in
      try s.fs.setAttribute(ino, Array(attribute.name.utf8), value, now: FsService.now)
    }
    service.changed()
  }

  mutating func removeAttribute(_ name: String) throws(FsIPC.FsError) {
    guard session.writable else { throw .readOnly }
    let ino = self.ino
    let removed = try service.call { (s: FsService) throws(TaisceError) in
      try s.fs.removeAttribute(ino, Array(name.utf8), now: FsService.now)
    }
    guard removed else { throw .notFound }
    service.changed()
  }
}

/// A fid's batch: Node's operations as the fid's session, which has no
/// channel.
struct FidSession: NodeSession {
  let session: FsSession
}

struct DirectorySession: NodeSession, FsIPC.DirectoryHandler {
  let session: FsSession
  let end: FsSessionEnd

  mutating func list(cursor: UInt64, max: UInt32, attributes: [String]) throws(FsIPC.FsError) -> FsIPC.Listing {
    try service.list(ino, cursor: cursor, max: max, attributes: attributes)
  }

  mutating func wholeListing(attributes: [String]) throws(FsIPC.FsError) -> Handle {
    try service.wholeListing(ino, attributes)
  }

  mutating func rename(_ from: String, to: String) throws(FsIPC.FsError) {
    let (fromDir, fromName) = try service.parent(of: from, below: ino)
    let (toDir, toName) = try service.parent(of: to, below: ino)
    try service.call { (s: FsService) throws(TaisceError) in
      try s.fs.rename(fromDir, fromName, toDir, toName, now: FsService.now)
    }
    service.cacheRenamed()  // any mapped file's path may have moved
    service.changed()
  }

  mutating func query(_ text: String, scan: Bool) throws(FsIPC.FsError) -> [FsIPC.Match] {
    let found = try service.call { (s: FsService) throws(TaisceError) in try s.fs.query(Array(text.utf8), scan: scan) }
    return found.map { FsIPC.Match(node: $0, path: service.path($0)) }
  }

  mutating func live(_ text: String, scan: Bool) throws(FsIPC.FsError) -> Handle { try service.live(text, scan: scan) }

  /// Indexes what was there before it was declared, too, before it answers.
  mutating func declareIndex(_ name: String, kind: UInt8, caseless: Bool) throws(FsIPC.FsError) {
    guard let kind = AttributeKind(rawValue: kind) else { throw .invalid }
    try service.call { (s: FsService) throws(TaisceError) in
      try s.fs.declareIndex(Array(name.utf8), kind, collation: caseless ? .caseFolded : .exact)
      while try !s.fs.backfill(budget: 1024) {}
    }
    service.changed()
  }

  mutating func indices() -> [FsIPC.IndexInfo] {
    service.fs.indices.map {
      FsIPC.IndexInfo(name: String(decoding: $0.name, as: UTF8.self), kind: $0.kind.rawValue,
                      caseless: $0.collation == .caseFolded, building: $0.building)
    }
  }

  mutating func sync() throws(FsIPC.FsError) {
    try service.call { (s: FsService) throws(TaisceError) in try s.commit() }
  }
}

struct FileSession: NodeSession, FsIPC.FileHandler {
  let session: FsSession
  let end: FsSessionEnd

  mutating func resize(_ size: UInt64) throws(FsIPC.FsError) {
    guard session.writable else { throw .readOnly }
    let ino = self.ino
    try service.call { (s: FsService) throws(TaisceError) in try s.resizeFile(ino, to: size, now: FsService.now) }
    service.changed()
  }

  mutating func map() throws(FsIPC.FsError) -> FsIPC.FileMap { try service.mapFile(ino) }

  mutating func capability(writable: Bool) throws(FsIPC.FsError) -> Handle {
    guard !writable || session.writable else { throw .readOnly }
    do throws(NodeError) {
      return try service.channel(ino, writable: writable, confined: true)
    } catch {
      throw .io
    }
  }

  mutating func sync() throws(FsIPC.FsError) {
    try service.call { (s: FsService) throws(TaisceError) in try s.fsync() }
  }
}

extension FsService {
  /// Entries of directory `ino` from `cursor` (0: the start; else one more
  /// than the last listed's hash), with the attributes named (nil: all).
  /// A batch ends at a hash boundary, so entries that share one come
  /// together, and stays well inside one message. Without `status` each
  /// entry's size and time are 0: the directory's entries say its node
  /// and kind, and no node is read.
  func list(_ ino: UInt64, cursor: UInt64, max: UInt32, attributes names: [String]?, status: Bool = true)
    throws(FsIPC.FsError) -> FsIPC.Listing
  {
    let limit = Int(Swift.max(1, Swift.min(max, 256)))
    // Warm (M6m): a listing served from the start to its end is kept while
    // the volume is unchanged; the next listing's batches come from it.
    if let k = kept(ino, names, status: status) { return k.batch(from: cursor, limit: limit) }
    let out: FsIPC.Listing
    var cookies: [UInt64] = []
    do throws(TaisceError) {
      let found = try fs.list(ino, after: cursor == 0 ? nil : cursor - 1, limit: limit)
      var entries: [FsIPC.Entry] = []
      var bytes = 0
      var last: UInt64?
      var done = true
      // The entries' nodes in one ordered pass, not a lookup each.
      let inodes = status ? try fs.stats(found.rows.map { $0.ino }) : []
      for (i, e) in found.rows.enumerated() {
        let cookie = e.cookie
        if bytes >= 32_768, cookie != last {
          done = false
          break
        }
        let inode = status ? inodes[i] : nil
        let entry = FsIPC.Entry(name: String(decoding: found.name(i), as: UTF8.self), node: e.ino, kind: e.type.rawValue,
                                size: inode?.size ?? 0, modified: Int64(inode?.mtime ?? 0),
                                attributes: names?.isEmpty == true ? [] : try attributes(e.ino, only: names))
        bytes += 64 + entry.name.utf8.count + entry.attributes.reduce(0) { $0 + 48 + $1.name.utf8.count + $1.value.count }
        entries.append(entry)
        cookies.append(cookie)
        last = cookie
      }
      if done {
        let buckets = found.rows.reduce(into: [UInt64]()) { if $0.last != $1.cookie { $0.append($1.cookie) } }
        done = buckets.count < limit
      }
      out = FsIPC.Listing(entries: entries, next: (last ?? cursor &- 1) &+ 1, done: done)
    } catch {
      throw Self.fsError(error)
    }
    served(ino, names, status: status, cursor: cursor, out, cookies)
    return out
  }
}

/// A directory's listing kept whole (M6m), with each entry's cookie (its
/// name's hash, in order), as long as the volume's journal hasn't moved.
struct KeptListing {
  var ino: UInt64
  var names: [String]?
  /// Whether its entries have their sizes and times.
  var status: Bool
  var seq: UInt64
  var entries: [FsIPC.Entry]
  var cookies: [UInt64]
  /// Its whole listing's VMO, once asked for.
  var vmo: KeptVMO? = nil
  /// While it's being kept: the cursor of the batch that adds to it.
  var next: UInt64 = 0

  /// The batch from `cursor` (one more than the last cookie listed): up to
  /// `limit` entries, and those sharing the last one's cookie.
  func batch(from cursor: UInt64, limit: Int) -> FsIPC.Listing {
    var lo = 0, hi = cookies.count
    while lo < hi {
      let mid = (lo + hi) / 2
      if cookies[mid] < cursor { lo = mid + 1 } else { hi = mid }
    }
    var end = Swift.min(lo + limit, entries.count)
    while end < entries.count && end > lo && cookies[end] == cookies[end - 1] { end += 1 }
    let next = end > lo ? cookies[end - 1] &+ 1 : cursor
    return FsIPC.Listing(entries: Array(entries[lo..<end]), next: next, done: end >= entries.count)
  }

  /// Whether it's the listing of `ino` with these attributes and status.
  func isFor(_ ino: UInt64, _ names: [String]?, status: Bool) -> Bool {
    self.ino == ino && self.status == status && FsService.sameNames(self.names, names)
  }
}

/// A kept listing's VMO (ListingVMO's format), closed with it.
final class KeptVMO {
  let vmo: Handle
  init(_ vmo: consuming Handle) { self.vmo = vmo }
}

extension FsService {
  static let keptListings = 4

  /// Whether two lists of attribute names are the same (nil: all).
  static func sameNames(_ a: [String]?, _ b: [String]?) -> Bool {
    guard let a, let b else { return a == nil && b == nil }
    return a.count == b.count && zip(a, b).allSatisfy { NodeIPC.same($0, $1) }
  }

  /// The whole listing of `ino` with these attributes, in a VMO of its
  /// own: built once from the kept listing, then shared read-only; `cold`
  /// if none is kept.
  func wholeListing(_ ino: UInt64, _ names: [String]) throws(FsIPC.FsError) -> Handle {
    guard let i = listings.firstIndex(where: { $0.isFor(ino, names, status: true) && $0.seq == fs.nextSeq })
    else { throw .cold }
    do throws(Status) {
      if listings[i].vmo == nil {
        var b = ListingVMO.Builder(names: names, capacity: listings[i].entries.count)
        for e in listings[i].entries {
          var attributes: [(name: Int, kind: UInt8, value: [UInt8])] = []
          for a in e.attributes {
            if let n = names.firstIndex(where: { NodeIPC.same($0, a.name) }) { attributes.append((n, a.kind, a.value)) }
          }
          b.add(name: e.name.utf8, node: e.node, kind: e.kind, size: e.size, modified: e.modified,
                attributes: attributes)
        }
        let bytes = b.finish()
        let vmo = try VMO.create(size: Swift.max(bytes.count, 1))
        if !bytes.isEmpty { try VMO.map(vmo, length: (bytes.count + 4095) & ~4095).write(bytes, at: 0) }
        listings[i].vmo = KeptVMO(vmo)
      }
      return try listings[i].vmo!.vmo.duplicate([.transfer, .duplicate, .wait, .inspect, .read, .map, .getProperty])
    } catch {
      throw .noSpace
    }
  }

  /// The kept listing of `ino` with these attributes, if the volume hasn't
  /// changed since; one with status serves a listing without.
  func kept(_ ino: UInt64, _ names: [String]?, status: Bool) -> KeptListing? {
    listings.first { $0.isFor(ino, names, status: status) && $0.seq == fs.nextSeq }
      ?? (status ? nil : listings.first { $0.isFor(ino, names, status: true) && $0.seq == fs.nextSeq })
  }

  /// A batch served: a listing from the start begins being kept, the
  /// next batch of one adds to it (the volume unchanged), and its last
  /// keeps it whole (the oldest kept one let go).
  func served(_ ino: UInt64, _ names: [String]?, status: Bool, cursor: UInt64, _ batch: FsIPC.Listing,
              _ cookies: [UInt64]) {
    building.removeAll { $0.seq != fs.nextSeq }
    let i: Int
    if cursor == 0 {
      building.removeAll { $0.isFor(ino, names, status: status) }
      if building.count >= Self.keptListings { building.removeFirst() }
      building.append(KeptListing(ino: ino, names: names, status: status, seq: fs.nextSeq, entries: [], cookies: []))
      i = building.count - 1
    } else {
      guard let at = building.firstIndex(where: { $0.isFor(ino, names, status: status) && $0.next == cursor })
      else { return }
      i = at
    }
    building[i].entries += batch.entries
    building[i].cookies += cookies
    building[i].next = batch.next
    if batch.done {
      let k = building.remove(at: i)
      listings.removeAll { $0.isFor(ino, names, status: status) }
      if listings.count >= Self.keptListings { listings.removeFirst() }
      listings.append(k)
    }
  }
}
