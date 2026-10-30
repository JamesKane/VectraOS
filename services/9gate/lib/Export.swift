// SPDX-License-Identifier: BSD-3-Clause

// A namespace's subtree served in 9P2000, as Plan 9's exportfs serves
// one: each fid a Node channel to its file and the file's path under the
// root, walked a name at a time through the namespace (so its mounts are
// seen, and ".." stops at the root), so a walk that stops partway says
// where. Reads and writes run on
// threads of their own, since a stream's may wait (D84, D94); the rest
// are answered in order as they come. A directory's reads are its
// entries as stats, whole ones, from where the last read ended. Node
// has no owners or permissions, so every file is the export's `owner`'s
// and its mode says only what it is.

import NineP
import Node
import Sys

/// Plan 9's error strings for Node's errors, both ways (Import reads
/// them back). Where Plan 9's servers differ, the one Linux's v9fs knows
/// (it matches whole strings, and makes any other ESERVERFAULT); the
/// spellings sent before are still read back.
enum Errors {
  static let table: [(NodeIPC.NodeError, String)] = [
    (.notFound, "file does not exist"), (.notDirectory, "not a directory"), (.isDirectory, "is a directory"),
    (.exists, "file already exists"), (.denied, "permission denied"), (.badName, "bad character in file name"),
    (.tooManyNames, "too many names in walk"), (.notEmpty, "directory is not empty"),
    (.unsupported, "Operation not supported"), (.invalid, "bad arg in system call"), (.io, "i/o error"),
    (.tooManyOps, "too many operations"),
    (.notEmpty, "directory not empty"), (.unsupported, "operation not supported"),
  ]

  static func text(_ e: NodeIPC.NodeError) -> String { table.first { $0.0 == e }?.1 ?? "i/o error" }

  static func code(_ text: String) -> NodeIPC.NodeError {
    table.first { NodeIPC.same($0.1, text) }?.0 ?? .io
  }

  static func text(_ e: NodeIPC.NodeClient.Failure) -> String {
    if case .remote(let r) = e { return text(r) }
    return "i/o error"
  }
}

/// A fid: a channel to its file, and what reading a directory needs.
final class ExportFid: @unchecked Sendable {
  let file: Shared
  /// Its path's names under the export's root.
  let path: [String]
  var qid: Qid
  var open = false
  var removeOnClunk = false
  /// A directory's reads: the offset the next one starts at, Node's
  /// cursor, stats read but not yet sent, and whether the listing ended.
  var dirOffset: UInt64 = 0
  var cursor: UInt64 = 0
  var left: [UInt8] = []
  var listed = false

  init(_ client: consuming NodeIPC.NodeClient, path: [String], qid: Qid) {
    file = Shared(client)
    self.path = path
    self.qid = qid
  }

  var isDir: Bool { qid.type & QidType.dir != 0 }
}

public final class Export: @unchecked Sendable {
  let namespace: Namespace
  let root: String
  let owner: String
  /// Whether `9P2000.vx` is spoken if asked, and who hears each
  /// Tattach's uname.
  let extended: Bool
  let attached: @Sendable (String) -> Void
  let messages: MessageStream
  let lock = Lock()
  var fids: [(fid: UInt32, file: ExportFid)] = []
  /// Requests in flight on threads, which a Tflush waits for.
  var inflight: [(tag: UInt16, done: Lock)] = []
  /// The threads its reads and writes run on.
  let workers = Workers()

  init(_ stream: ByteStream, namespace: Namespace, root: String, owner: String, msize: UInt32, extended: Bool,
       attached: @escaping @Sendable (String) -> Void) {
    self.namespace = namespace
    self.root = root
    self.owner = owner
    self.extended = extended
    self.attached = attached
    messages = MessageStream(stream, msize: msize)
  }

  /// Serves `root` of `namespace` on `stream` until it closes: why it did.
  /// Files are `owner`'s; `extended` false speaks only plain 9P2000, and
  /// `attached` is given each Tattach's uname. The msize offered is at most what one of Node's
  /// reads fills, so a client's full-sized read comes back whole: a
  /// client taking a short read as a file's end, or reading ahead by
  /// whole reads, would otherwise ask again for what it had.
  public static func serve(_ stream: ByteStream, namespace: Namespace, root: String, owner: String = "none",
                           msize: UInt32 = UInt32(NodeIPC.maxIO) + NineP.ioHeader, extended: Bool = true,
                           attached: @escaping @Sendable (String) -> Void = { _ in }) -> GateError {
    let e = Export(stream, namespace: namespace, root: root, owner: owner, msize: msize, extended: extended,
                   attached: attached)
    let why = e.run()
    stream.close()
    return why
  }

  func run() -> GateError {
    // Tversion first; any other message before it is refused.
    do throws(GateError) {
      let m = try messages.receive()
      guard case .tversion(let msize, let version) = m.fcall,
            let agreed = Version.answer(version, msize: msize, ours: messages.msize, extended: extended)
      else { throw .protocolError("expected Tversion") }
      try messages.send(Message(tag: m.tag, .rversion(msize: agreed.msize, version: agreed.version)))
      messages.msize = agreed.msize
    } catch { return error }
    while true {
      let m: Message
      do throws(GateError) { m = try messages.receive() } catch { return error }
      switch m.fcall {
      case .tread, .twrite, .tflush:
        let done = Lock()
        done.lock()
        lock.withLock { inflight.append((m.tag, done)) }
        do throws(Status) {
          try workers.run { [self] in
            answer(m)
            lock.withLock { inflight.removeAll { $0.tag == m.tag } }
            done.unlock()
          }
        } catch {
          lock.withLock { inflight.removeAll { $0.tag == m.tag } }
          reply(m.tag, .rerror(ename: "i/o error"))
        }
      default:
        answer(m)
      }
    }
  }

  func reply(_ tag: UInt16, _ f: Fcall) { try? messages.send(Message(tag: tag, f)) }

  func answer(_ m: Message) {
    do throws(Refusal) {
      reply(m.tag, try handle(m))
    } catch {
      reply(m.tag, .rerror(ename: error.text))
    }
  }

  struct Refusal: Error {
    var text: String
    init(_ text: String) { self.text = text }
    init(_ e: NodeIPC.NodeError) { text = Errors.text(e) }
    init(_ e: NodeIPC.NodeClient.Failure) { text = Errors.text(e) }
    init(_ e: NamespaceError) {
      switch e {
      case .notFound: text = Errors.text(.notFound)
      case .badPath: text = Errors.text(.badName)
      case .node(let n): text = Errors.text(n)
      default: text = Errors.text(.io)
      }
    }
  }

  func file(_ fid: UInt32) throws(Refusal) -> ExportFid {
    guard let f = lock.withLock({ fids.first { $0.fid == fid }?.file }) else { throw Refusal("unknown fid") }
    return f
  }

  func add(_ fid: UInt32, _ f: ExportFid) throws(Refusal) {
    try lock.withLock { () throws(Refusal) in
      guard !fids.contains(where: { $0.fid == fid }) else { throw Refusal("fid in use") }
      fids.append((fid, f))
    }
  }

  func drop(_ fid: UInt32) { lock.withLock { fids.removeAll { $0.fid == fid } } }

  var iounit: UInt32 { min(messages.msize - NineP.ioHeader, UInt32(NodeIPC.maxIO)) }

  func handle(_ m: Message) throws(Refusal) -> Fcall {
    switch m.fcall {
    case .tauth: throw Refusal("authentication not required")
    case .tattach(let fid, _, let uname, let aname):
      let path = aname.isEmpty ? [] : NodeIPC.names(aname)
      let o = try opened(path)
      attached(uname)
      let qid = o.qid
      try add(fid, ExportFid(o.client, path: path, qid: qid))
      return .rattach(qid: qid)
    case .tflush(let oldtag):
      // Answered once the request it names is: Node can't take back a
      // read that waits, so the flush waits for it (BUGS).
      let done = lock.withLock { inflight.first { $0.tag == oldtag && $0.tag != m.tag }?.done }
      if let done {
        done.lock()
        done.unlock()
      }
      return .rflush
    case .twalk(let fid, let newfid, let names):
      return try walk(try file(fid), fid, newfid, names)
    case .topen(let fid, let mode):
      let f = try file(fid)
      guard !f.open else { throw Refusal("file already open") }
      if mode & OpenMode.trunc != 0 {
        do throws(NodeIPC.NodeClient.Failure) { try f.file.call { (c: inout NodeIPC.NodeClient) throws(NodeIPC.NodeClient.Failure) in
          try c.wstat(NodeIPC.Wstat(size: 0))
        } } catch { throw Refusal(error) }
      }
      f.open = true
      f.removeOnClunk = mode & OpenMode.rclose != 0
      f.dirOffset = 0
      return .ropen(qid: f.qid, iounit: iounit)
    case .tcreate(let fid, let name, let perm, let mode):
      let f = try file(fid)
      guard f.isDir, !f.open else { throw Refusal(.notDirectory) }
      let kind: NodeIPC.NodeKind = perm & DirMode.dir != 0 ? .directory : .file
      let made = try f.file.call { (c: inout NodeIPC.NodeClient) throws(Refusal) -> NodeIPC.NodeClient in
        do throws(NodeIPC.NodeClient.Failure) { return try NodeIPC.NodeClient(try c.run([.create(name: name, kind: kind)], open: true)) } catch {
          throw Refusal(error)
        }
      }
      let s: NodeIPC.Stat
      var made2 = made
      do throws(NodeIPC.NodeClient.Failure) { s = try made2.stat(fields: 0) } catch { throw Refusal(error) }
      let qid = Self.qid(s.qid)
      let created = ExportFid(made2, path: f.path + [name], qid: qid)
      created.open = true
      created.removeOnClunk = mode & OpenMode.rclose != 0
      drop(fid)
      try add(fid, created)
      return .rcreate(qid: qid, iounit: iounit)
    case .tread(let fid, let offset, let count):
      let f = try file(fid)
      guard f.open else { throw Refusal("file not open") }
      let n = min(count, iounit)
      if f.isDir { return .rread(data: try readDir(f, offset: offset, count: n)) }
      let data = try f.file.call { (c: inout NodeIPC.NodeClient) throws(Refusal) -> [UInt8] in
        do throws(NodeIPC.NodeClient.Failure) { return try c.read(offset: offset, max: n) } catch { throw Refusal(error) }
      }
      return .rread(data: data)
    case .twrite(let fid, let offset, let data):
      let f = try file(fid)
      guard f.open, !f.isDir else { throw Refusal(f.isDir ? .isDirectory : .denied) }
      var at = 0
      while at < data.count {
        let piece = Array(data[at..<at + min(data.count - at, NodeIPC.maxIO)])
        let n = try f.file.call { (c: inout NodeIPC.NodeClient) throws(Refusal) -> UInt32 in
          do throws(NodeIPC.NodeClient.Failure) { return try c.write(offset: offset + UInt64(at), piece) } catch { throw Refusal(error) }
        }
        guard n > 0 else { break }
        at += Int(n)
      }
      return .rwrite(count: UInt32(at))
    case .tclunk(let fid):
      let f = try file(fid)
      drop(fid)
      if f.removeOnClunk { _ = try? remove(f) }
      return .rclunk
    case .tremove(let fid):
      let f = try file(fid)
      drop(fid)
      try remove(f)
      return .rremove
    case .tstat(let fid):
      let f = try file(fid)
      let s = try f.file.call { (c: inout NodeIPC.NodeClient) throws(Refusal) -> NodeIPC.Stat in
        do throws(NodeIPC.NodeClient.Failure) { return try c.stat() } catch { throw Refusal(error) }
      }
      guard let stat = dir(s).encode() else { throw Refusal(.io) }
      return .rstat(stat: stat)
    case .twstat(let fid, let stat):
      let f = try file(fid)
      guard let d = Dir.decode(stat) else { throw Refusal("bad stat") }
      let none = Dir.unchanged
      // Node keeps a name, a time and a size; nothing else changes. The
      // muid is ours to set, so it is ignored, not refused: Linux's v9fs
      // names itself as the muid of every rename.
      guard d.mode == none.mode || d.mode == mode(f.qid), d.uid.isEmpty, d.gid.isEmpty
      else { throw Refusal("wstat prohibited") }
      let change = NodeIPC.Wstat(name: d.name.isEmpty ? nil : d.name,
                                 modified: d.mtime == none.mtime ? nil : Int64(d.mtime) * 1_000_000_000,
                                 size: d.length == none.length ? nil : d.length)
      do throws(NodeIPC.NodeClient.Failure) { try f.file.call { (c: inout NodeIPC.NodeClient) throws(NodeIPC.NodeClient.Failure) in
        try c.wstat(change)
      } } catch { throw Refusal(error) }
      return .rwstat
    default:
      throw Refusal("not a request")
    }
  }

  func walk(_ f: ExportFid, _ fid: UInt32, _ newfid: UInt32, _ names: [String]) throws(Refusal) -> Fcall {
    guard !f.open else { throw Refusal("walk of an open file") }
    guard names.count <= NineP.maxWalk else { throw Refusal(.tooManyNames) }
    guard newfid == fid || lock.withLock({ !fids.contains { $0.fid == newfid } }) else { throw Refusal("fid in use") }
    var path = f.path
    var qids: [Qid] = []
    var last: NodeIPC.NodeClient? = nil
    if names.isEmpty {
      // A clone: a channel of its own to the same file.
      let o = try opened(path)
      last = consume o.client
    }
    for (i, name) in names.enumerated() {
      guard NodeIPC.same(name, "..") || NodeIPC.isValidName(name) else {
        if i == 0 { throw Refusal(.badName) }
        return .rwalk(qids: qids)
      }
      // ".." at the root is the root, as Plan 9's is.
      if NodeIPC.same(name, "..") { path = Array(path.dropLast()) } else { path.append(name) }
      do throws(Refusal) {
        let o = try opened(path)
        qids.append(o.qid)
        last = consume o.client
      } catch {
        // The first name not there is an error; a later one, a short walk.
        if i == 0 { throw error }
        return .rwalk(qids: qids)
      }
    }
    guard let client = last.take() else { throw Refusal(.io) }
    let walked = ExportFid(client, path: path, qid: qids.last ?? f.qid)
    if newfid == fid { drop(fid) }
    try add(newfid, walked)
    return .rwalk(qids: qids)
  }

  /// A channel to a file, and its qid.
  struct Opened: ~Copyable {
    var client: NodeIPC.NodeClient
    var qid: Qid
  }

  /// A channel to the file at `path` under the root, and its qid.
  func opened(_ path: [String]) throws(Refusal) -> Opened {
    var full = root
    for n in path { full += (full.utf8.last == UInt8(ascii: "/") ? "" : "/") + n }
    var client: NodeIPC.NodeClient
    do throws(NamespaceError) { client = try namespace.open(full) } catch { throw Refusal(error) }
    let s: NodeIPC.Stat
    do throws(NodeIPC.NodeClient.Failure) { s = try client.stat(fields: 0) } catch { throw Refusal(error) }
    return Opened(client: client, qid: Self.qid(s.qid))
  }

  func remove(_ f: ExportFid) throws(Refusal) {
    try f.file.call { (c: inout NodeIPC.NodeClient) throws(Refusal) in
      do throws(NodeIPC.NodeClient.Failure) { _ = try c.run([.remove]) } catch { throw Refusal(error) }
    }
  }

  /// Whole stats from `offset`, which must be 0 (from the start) or
  /// where the last read ended, as Plan 9's directory reads are.
  func readDir(_ f: ExportFid, offset: UInt64, count: UInt32) throws(Refusal) -> [UInt8] {
    if offset == 0 {
      f.dirOffset = 0
      f.cursor = 0
      f.left = []
      f.listed = false
    } else if offset != f.dirOffset {
      throw Refusal("bad offset in directory read")
    }
    var out: [UInt8] = []
    while true {
      // What's held first, whole stats only.
      var r = 0
      while r + 2 <= f.left.count {
        let n = Int(f.left[r]) | Int(f.left[r + 1]) << 8
        guard out.count + 2 + n <= Int(count) else { break }
        out += f.left[r..<r + 2 + n]
        r += 2 + n
      }
      f.left.removeFirst(r)
      if !f.left.isEmpty || f.listed { break }
      let batch = try f.file.call { (c: inout NodeIPC.NodeClient) throws(Refusal) -> NodeIPC.DirBatch in
        do throws(NodeIPC.NodeClient.Failure) { return try c.readdir(cursor: f.cursor, max: 64) } catch { throw Refusal(error) }
      }
      for s in batch.entries { if let b = dir(s).encode() { f.left += b } }
      f.cursor = batch.next
      f.listed = batch.done
      if batch.entries.isEmpty && !batch.done { break }
    }
    if out.isEmpty, !f.left.isEmpty { throw Refusal("directory entry too large") }
    f.dirOffset += UInt64(out.count)
    return out
  }

  static func qid(_ q: NodeIPC.Qid) -> Qid {
    Qid(type: q.kind == .directory ? QidType.dir : QidType.file, version: q.version, path: q.path)
  }

  func mode(_ q: Qid) -> UInt32 { q.type & QidType.dir != 0 ? DirMode.dir | 0o775 : 0o664 }

  func dir(_ s: NodeIPC.Stat) -> Dir {
    let qid = Self.qid(s.qid)
    let seconds = UInt32(truncatingIfNeeded: max(0, s.modified) / 1_000_000_000)
    return Dir(qid: qid, mode: mode(qid), length: qid.type & QidType.dir != 0 ? 0 : s.size, name: s.name,
               uid: owner, atime: seconds, mtime: seconds)
  }
}
