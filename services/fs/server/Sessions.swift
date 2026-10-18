// SPDX-License-Identifier: BSD-3-Clause

// What a Directory or File channel does: Node's batch, wstat and memory,
// and Attributes', which both compose, then each one's own. A batch runs
// its operations on a current node, which starts at the channel's, as
// NodeTree's do. Queries, live queries, indices, mapped files and whole
// listings aren't served yet: they fail with `unsupported`.

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
    var results: [NodeIPC.Outcome] = []
    guard ops.count <= NodeIPC.maxOps else { return failed(results, 0, .tooManyOps) }
    var at = ino
    for i in ops.indices {
      do throws(NodeError) {
        switch ops[i] {
        case .walk(let names):
          let (qids, end) = try service.walk(from: at, names)
          results.append(.walked(qids))
          at = end
        case .stat(let fields):
          results.append(.stat(try stat(at, fields)))
        case .readdir(let cursor, let max, let fields):
          results.append(.dir(try readdir(at, cursor: cursor, max: max, fields: fields)))
        case .read(let offset, let max):
          results.append(.data(try read(at, offset: offset, max: max)))
        case .write(let offset, let data):
          results.append(.wrote(try write(at, offset: offset, data)))
        case .watch(let since):
          results.append(.watching(service.watch(session, at, since: since)))
        case .create(let name, let kind):
          at = try create(at, name, kind: kind)
          results.append(.created(try service.node { (s: FsService) throws(TaisceError) in try s.qid(at) }))
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
      return NodeIPC.Reply(results: results, failure: nil, node: try service.channel(at))
    } catch {
      return failed(results, ops.count, error)  // the open itself
    }
  }

  func failed(_ results: [NodeIPC.Outcome], _ index: Int, _ error: NodeError) -> NodeIPC.Reply {
    NodeIPC.Reply(results: results, failure: NodeIPC.Failure(index: UInt32(index), code: error.rawValue), node: nil)
  }

  func stat(_ ino: UInt64, _ fields: UInt32) throws(NodeError) -> NodeIPC.Stat {
    try service.node { (s: FsService) throws(TaisceError) in
      let inode = try s.fs.stat(ino)
      let name = ino == FileSystem<NodeDevice>.root ? "" : try s.fs.names(ino).first.map { String(decoding: $0.name, as: UTF8.self) } ?? ""
      let attributes = fields & NodeIPC.Fields.attributes == 0 ? [] : try s.attributes(ino).map {
        NodeIPC.Attribute(name: $0.name, kind: $0.kind, value: $0.value)
      }
      return NodeIPC.Stat(qid: try s.qid(ino), name: name,
                          size: fields & NodeIPC.Fields.size != 0 ? inode.size : 0,
                          modified: fields & NodeIPC.Fields.modified != 0 ? Int64(inode.mtime) : 0,
                          attributes: attributes)
    }
  }

  func readdir(_ ino: UInt64, cursor: UInt64, max: UInt32, fields: UInt32) throws(NodeError) -> NodeIPC.DirBatch {
    let listing: FsIPC.Listing
    do throws(FsIPC.FsError) {
      listing = try service.list(ino, cursor: cursor, max: max, attributes: fields & NodeIPC.Fields.attributes != 0 ? nil : [])
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

  func read(_ ino: UInt64, offset: UInt64, max: UInt32) throws(NodeError) -> [UInt8] {
    try service.node { (s: FsService) throws(TaisceError) in
      guard try s.fs.stat(ino).type != .directory else { throw .isDirectory }
      return try s.fs.read(ino, offset: offset, count: Swift.min(Int(max), NodeIPC.maxIO))
    }
  }

  func write(_ ino: UInt64, offset: UInt64, _ data: [UInt8]) throws(NodeError) -> UInt32 {
    guard data.count <= NodeIPC.maxIO else { throw .invalid }
    try service.node { (s: FsService) throws(TaisceError) in
      guard try s.fs.stat(ino).type != .directory else { throw .isDirectory }
      try s.fs.write(ino, offset: offset, data, now: FsService.now)
    }
    service.changed()
    return UInt32(data.count)
  }

  func create(_ dir: UInt64, _ name: String, kind: NodeIPC.NodeKind) throws(NodeError) -> UInt64 {
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
    guard ino != FileSystem<NodeDevice>.root else { throw .denied }
    try service.node { (s: FsService) throws(TaisceError) in
      guard let (dir, name) = try s.fs.names(ino).first else { throw .notFound }
      if try s.fs.stat(ino).type == .directory {
        try s.fs.rmdir(dir, name, now: FsService.now)
      } else {
        try s.fs.unlink(dir, name, now: FsService.now)
      }
    }
    service.changed()
  }

  /// A ring for the channel's file (D103): each entry read or written on
  /// the dispatcher's thread, the volume's, and answered at once.
  mutating func attach(_ bulk: consuming NodeIPC.Bulk) throws(NodeError) {
    guard session.ring == nil else { throw .exists }
    let service = self.service, ino = self.ino
    session.ring = unsafe try NodeRing(bulk, dispatcher: service.dispatcher) { op, offset, data, done in
      do throws(NodeError) {
        if op == NodeBulk.read {
          let bytes = try service.node { (s: FsService) throws(TaisceError) in
            guard try s.fs.stat(ino).type != .directory else { throw .isDirectory }
            return try s.fs.read(ino, offset: offset, count: data.count)
          }
          unsafe bytes.withUnsafeBytes { b in unsafe data.baseAddress!.copyMemory(from: b.baseAddress!, byteCount: b.count) }
          done(.success(UInt32(bytes.count)))
        } else {
          let bytes = unsafe Array(UnsafeRawBufferPointer(data))
          try service.node { (s: FsService) throws(TaisceError) in
            guard try s.fs.stat(ino).type != .directory else { throw .isDirectory }
            try s.fs.write(ino, offset: offset, bytes, now: FsService.now)
          }
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
      return try s.fs.read(ino, offset: 0, count: Int(inode.size))
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
    let ino = self.ino
    if let name = change.name, !NodeIPC.isValidName(name) || NodeIPC.same(name, "..") { throw .badName }
    // The root has no name to change, nor is it the client's to touch.
    if change.name != nil || change.modified != nil, ino == FileSystem<NodeDevice>.root { throw .denied }
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
      if let size = change.size { try s.fs.truncate(ino, size: size, now: now) }
      if let modified = change.modified { try s.fs.setAttributes(ino, mtime: UInt64(clamping: modified), now: now) }
      if let (dir, old) = place, let name = change.name { try s.fs.rename(dir, old, dir, Array(name.utf8), now: now) }
    }
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
    guard let value = FsService.decode(attribute.kind, attribute.value) else { throw .invalid }
    let ino = self.ino
    try service.call { (s: FsService) throws(TaisceError) in
      try s.fs.setAttribute(ino, Array(attribute.name.utf8), value, now: FsService.now)
    }
    service.changed()
  }

  mutating func removeAttribute(_ name: String) throws(FsIPC.FsError) {
    let ino = self.ino
    let removed = try service.call { (s: FsService) throws(TaisceError) in
      try s.fs.removeAttribute(ino, Array(name.utf8), now: FsService.now)
    }
    guard removed else { throw .notFound }
    service.changed()
  }
}

struct DirectorySession: NodeSession, FsIPC.DirectoryHandler {
  let session: FsSession
  let end: FsSessionEnd

  mutating func list(cursor: UInt64, max: UInt32, attributes: [String]) throws(FsIPC.FsError) -> FsIPC.Listing {
    try service.list(ino, cursor: cursor, max: max, attributes: attributes)
  }

  mutating func wholeListing(attributes: [String]) throws(FsIPC.FsError) -> Handle { throw .unsupported }

  mutating func rename(_ from: String, to: String) throws(FsIPC.FsError) {
    let (fromDir, fromName) = try service.parent(of: from, below: ino)
    let (toDir, toName) = try service.parent(of: to, below: ino)
    try service.call { (s: FsService) throws(TaisceError) in
      try s.fs.rename(fromDir, fromName, toDir, toName, now: FsService.now)
    }
    service.changed()
  }

  mutating func query(_ text: String, scan: Bool) throws(FsIPC.FsError) -> [FsIPC.Match] { throw .unsupported }

  mutating func live(_ text: String, scan: Bool) throws(FsIPC.FsError) -> Handle { throw .unsupported }

  mutating func declareIndex(_ name: String, kind: UInt8, caseless: Bool) throws(FsIPC.FsError) {
    throw .unsupported
  }

  mutating func indices() -> [FsIPC.IndexInfo] { [] }

  mutating func sync() throws(FsIPC.FsError) {
    try service.call { (s: FsService) throws(TaisceError) in try s.commit() }
  }
}

struct FileSession: NodeSession, FsIPC.FileHandler {
  let session: FsSession
  let end: FsSessionEnd

  mutating func resize(_ size: UInt64) throws(FsIPC.FsError) {
    let ino = self.ino
    try service.call { (s: FsService) throws(TaisceError) in try s.fs.truncate(ino, size: size, now: FsService.now) }
    service.changed()
  }

  mutating func map() throws(FsIPC.FsError) -> Handle { throw .unsupported }

  mutating func sync() throws(FsIPC.FsError) {
    try service.call { (s: FsService) throws(TaisceError) in try s.fs.fsync() }
  }
}

extension FsService {
  /// Entries of directory `ino` from `cursor` (0: the start; else one more
  /// than the last listed's hash), with the attributes named (nil: all).
  /// A batch ends at a hash boundary, so entries that share one come
  /// together, and stays well inside one message.
  func list(_ ino: UInt64, cursor: UInt64, max: UInt32, attributes names: [String]?) throws(FsIPC.FsError)
    -> FsIPC.Listing
  {
    let limit = Int(Swift.max(1, Swift.min(max, 256)))
    do throws(TaisceError) {
      let found = try fs.list(ino, after: cursor == 0 ? nil : cursor - 1, limit: limit)
      var entries: [FsIPC.Entry] = []
      var bytes = 0
      var last: UInt64?
      var done = true
      for (e, cookie) in found {
        if bytes >= 32_768, cookie != last {
          done = false
          break
        }
        let inode = try fs.stat(e.ino)
        let entry = FsIPC.Entry(name: String(decoding: e.name, as: UTF8.self), node: e.ino, kind: e.type.rawValue,
                                size: inode.size, modified: Int64(inode.mtime),
                                attributes: names?.isEmpty == true ? [] : try attributes(e.ino, only: names))
        bytes += 64 + entry.name.utf8.count + entry.attributes.reduce(0) { $0 + 48 + $1.name.utf8.count + $1.value.count }
        entries.append(entry)
        last = cookie
      }
      if done {
        let buckets = found.reduce(into: [UInt64]()) { if $0.last != $1.cookie { $0.append($1.cookie) } }
        done = buckets.count < limit
      }
      return FsIPC.Listing(entries: entries, next: (last ?? cursor &- 1) &+ 1, done: done)
    } catch {
      throw Self.fsError(error)
    }
  }
}
