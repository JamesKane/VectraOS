// SPDX-License-Identifier: BSD-3-Clause

// The terminal's 9P2000 server: the node is its client, through 9gate's
// import (gate(2)), and walks, opens, reads and writes the terminal's
// tree (Files.swift). Plain 9P2000, with no authentication: the Noise
// session is the authentication. A read of dev/cons or dev/cpunote
// waits for the terminal, so it is answered from a thread of its own;
// a net conversation's reads, and its writes and ctl lines, wait for the
// network, each kind in the order it came, on a thread of the
// conversation's (Net.swift); the rest in order. A flushed request gets
// no reply.

import FoundationEssentials
import Glibc
import NineP

/// A fid: where it is, and once open, how.
final class Fid {
  var place: Place
  var open = false
  var mode: UInt8 = 0
  var fd: Int32 = -1
  var listing: [UInt8] = []
  var removeOnClunk = false
  /// The net conversation it holds open, and net/cs's answers not yet read.
  var conversation: NetConversation?
  var answers: [String] = []

  init(_ place: Place) { self.place = place }
}

public final class TerminalServer: @unchecked Sendable {
  /// The largest message it takes: 64 KiB of data and its header.
  public static let msize: UInt32 = 65536 + NineP.ioHeader

  let tree: TerminalTree
  let read: @Sendable (Int) throws(TerminalError) -> [UInt8]
  let write: @Sendable ([UInt8]) throws(TerminalError) -> Void
  let lock = Lock()
  var fids: [UInt32: Fid] = [:]
  /// Requests not yet answered: a flush takes one away.
  var pending: Set<UInt16> = []
  var msize = TerminalServer.msize

  public init(_ tree: TerminalTree, read: @escaping @Sendable (Int) throws(TerminalError) -> [UInt8],
              write: @escaping @Sendable ([UInt8]) throws(TerminalError) -> Void) {
    self.tree = tree
    self.read = read
    self.write = write
  }

  public convenience init(_ tree: TerminalTree, link: SealedLink) {
    self.init(tree, read: { (n: Int) throws(TerminalError) in try link.read(n) },
              write: { (b: [UInt8]) throws(TerminalError) in try link.write(b) })
  }

  /// Answers requests until the stream ends or breaks.
  public func serve() {
    var buffer: [UInt8] = []
    defer { lock.withLock { for (_, f) in fids { close(f) }; fids = [:] } }
    while true {
      if buffer.count >= 4 {
        guard let size = Message.size(Array(buffer.prefix(4))), size <= Int(Self.msize) else { return }
        if buffer.count >= size {
          let bytes = Array(buffer.prefix(size))
          buffer.removeFirst(size)
          guard let m = Message.decode(bytes), m.fcall.isRequest else { return }
          handle(m)
          continue
        }
      }
      let more: [UInt8]
      do throws(TerminalError) { more = try read(Int(Self.msize)) } catch { return }
      guard !more.isEmpty else { return }
      buffer += more
    }
  }

  func reply(_ tag: UInt16, _ fcall: Fcall) {
    lock.withLock {
      guard pending.remove(tag) != nil, let bytes = Message(tag: tag, fcall).encode() else { return }
      try? write(bytes)
    }
  }

  func handle(_ m: Message) {
    let tag = m.tag
    lock.withLock { _ = pending.insert(tag) }
    if case .tflush(let old) = m.fcall {
      lock.withLock { _ = pending.remove(old) }
      return reply(tag, .rflush)
    }
    // A read that waits for the terminal: from a thread of its own.
    if case .tread(let fid, _, _) = m.fcall, let f = lock.withLock({ fids[fid] }),
       f.place == .cons || f.place == .cpunote
    {
      spawn { [self] in reply(tag, answer(m.fcall)) }
      return
    }
    if let queue = waitsForTheNetwork(m.fcall) {
      queue.run { [self] in reply(tag, answer(m.fcall)) }
      return
    }
    reply(tag, answer(m.fcall))
  }

  /// The queue a request on a net conversation waits in: its reads of
  /// data, or its writes of data and ctl (a connect waits for the call).
  func waitsForTheNetwork(_ fcall: Fcall) -> InOrder? {
    let n: UInt32, reading: Bool
    switch fcall {
    case .tread(let fid, _, _): (n, reading) = (fid, true)
    case .twrite(let fid, _, _): (n, reading) = (fid, false)
    default: return nil
    }
    guard let f = lock.withLock({ fids[n] }), let c = f.conversation, case .netFile(_, let file) = f.place else {
      return nil
    }
    if reading { return file == .data ? c.reads : nil }
    return file == .data || file == .ctl ? c.writes : nil
  }

  func answer(_ fcall: Fcall) -> Fcall {
    do throws(Refusal) { return try run(fcall) } catch { return .rerror(ename: error.text) }
  }

  func fid(_ n: UInt32) throws(Refusal) -> Fid {
    guard let f = lock.withLock({ fids[n] }) else { throw Refusal("unknown fid") }
    return f
  }

  func run(_ fcall: Fcall) throws(Refusal) -> Fcall {
    switch fcall {
    case .tversion(let size, let version):
      guard let (v, agreed) = Version.answer(version, msize: size, ours: Self.msize, extended: false) else {
        throw Refusal("msize too small")
      }
      lock.withLock {
        for (_, f) in fids { close(f) }
        fids = [:]
        msize = agreed
      }
      return .rversion(msize: agreed, version: v)
    case .tauth:
      throw Refusal("authentication not required")
    case .tattach(let fid, _, _, let aname):
      var place = Place.top
      for name in aname.split(separator: "/") { place = try tree.walk(place, String(name)) }
      let qid = try tree.qid(place)
      try lock.withLock { () throws(Refusal) in
        guard fids[fid] == nil else { throw Refusal("fid in use") }
        fids[fid] = Fid(place)
      }
      return .rattach(qid: qid)
    case .twalk(let fid, let newfid, let names):
      let f = try self.fid(fid)
      guard !f.open else { throw Refusal("fid open") }
      guard names.count <= NineP.maxWalk else { throw Refusal("too many names in walk") }
      var place = f.place
      var qids: [Qid] = []
      for name in names {
        do throws(Refusal) {
          place = try tree.walk(place, name)
          qids.append(try tree.qid(place))
        } catch {
          if qids.isEmpty { throw error }
          return .rwalk(qids: qids)
        }
      }
      try lock.withLock { () throws(Refusal) in
        if newfid != fid, fids[newfid] != nil { throw Refusal("fid in use") }
        fids[newfid] = Fid(place)
      }
      return .rwalk(qids: qids)
    case .topen(let fid, let mode):
      let f = try self.fid(fid)
      guard !f.open else { throw Refusal("fid open") }
      try open(f, mode)
      return .ropen(qid: try tree.qid(f.place), iounit: 0)
    case .tcreate(let fid, let name, let perm, let mode):
      let f = try self.fid(fid)
      guard !f.open, case .host(let names) = f.place else { throw f.open ? Refusal("fid open") : .denied }
      guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { throw .badName }
      let place = Place.host(names + [name])
      let path = tree.path(names + [name])
      if perm & DirMode.dir != 0 {
        guard mkdir(path, mode_t(perm & 0o777)) == 0 else { throw Refusal.errno() }
        f.place = place
        try open(f, OpenMode.read)
      } else {
        let fd = Glibc.open(path, Self.flags(mode) | O_CREAT | O_EXCL, mode_t(perm & 0o777))
        guard fd >= 0 else { throw Refusal.errno() }
        f.place = place
        f.fd = fd
        f.open = true
        f.mode = mode
        f.removeOnClunk = mode & OpenMode.rclose != 0
      }
      return .rcreate(qid: try tree.qid(place), iounit: 0)
    case .tread(let fid, let offset, let count):
      let f = try self.fid(fid)
      guard f.open, f.mode & 3 != OpenMode.write else { throw Refusal("fid not open for reading") }
      let n = Int(min(count, lock.withLock { msize } - NineP.ioHeader))
      switch f.place {
      case .cons: return .rread(data: tree.console.read(n))
      case .cpunote: return .rread(data: tree.console.note().map { Array($0.utf8.prefix(n)) } ?? [])
      case .top, .dev, .net, .tcp, .conversation: return .rread(data: try entries(f, offset: offset, max: n))
      case .clone: throw .invalid
      case .cs:
        // An answer a read, as ndb(8)'s cs gives them.
        let next = lock.withLock { () -> String? in f.answers.isEmpty ? nil : f.answers.removeFirst() }
        return .rread(data: next.map { Array($0.utf8.prefix(n)) } ?? [])
      case .netFile(_, let file):
        guard let c = f.conversation else { throw .notFound }
        if file == .data { return .rread(data: try tree.net.read(c, max: n)) }
        let text = Array(tree.net.text(c, file).utf8)
        let at = Int(clamping: offset)
        return .rread(data: at >= text.count ? [] : Array(text[at..<Swift.min(text.count, at + n)]))
      case .host:
        if f.fd < 0 { return .rread(data: try entries(f, offset: offset, max: n)) }
        var buffer = [UInt8](repeating: 0, count: n)
        let got = buffer.withUnsafeMutableBytes { pread(f.fd, $0.baseAddress, n, off_t(offset)) }
        guard got >= 0 else { throw Refusal.errno() }
        if got == 0, case .host(let names) = f.place { tree.readToEnd?(names) }
        return .rread(data: Array(buffer[0..<got]))
      }
    case .twrite(let fid, let offset, let data):
      let f = try self.fid(fid)
      guard f.open, f.mode & 3 != OpenMode.read, f.mode & 3 != OpenMode.exec else {
        throw Refusal("fid not open for writing")
      }
      switch f.place {
      case .cons:
        tree.console.write(data)
        return .rwrite(count: UInt32(data.count))
      case .netFile(_, .ctl):
        guard let c = f.conversation else { throw .notFound }
        try tree.net.control(c, String(decoding: data, as: UTF8.self))
        return .rwrite(count: UInt32(data.count))
      case .netFile(_, .data):
        guard let c = f.conversation else { throw .notFound }
        return .rwrite(count: try tree.net.write(c, data))
      case .cs:
        let query = String(decoding: data.split(whereSeparator: { $0 == 0x0A || $0 == 0x20 }).first ?? [], as: UTF8.self)
        let answers = try tree.net.translate(query)
        lock.withLock { f.answers = answers }
        return .rwrite(count: UInt32(data.count))
      case .host where f.fd >= 0:
        let n = data.withUnsafeBytes { pwrite(f.fd, $0.baseAddress, data.count, off_t(offset)) }
        guard n >= 0 else { throw Refusal.errno() }
        return .rwrite(count: UInt32(n))
      default:
        throw .denied
      }
    case .tclunk(let fid):
      let f = try self.fid(fid)
      lock.withLock { _ = fids.removeValue(forKey: fid) }
      close(f)
      if f.removeOnClunk { try? remove(f.place) }
      return .rclunk
    case .tremove(let fid):
      let f = try self.fid(fid)
      lock.withLock { _ = fids.removeValue(forKey: fid) }
      close(f)
      try remove(f.place)
      return .rremove
    case .tstat(let fid):
      guard let bytes = try tree.dir(try self.fid(fid).place).encode() else { throw .io }
      return .rstat(stat: bytes)
    case .twstat(let fid, let stat):
      let f = try self.fid(fid)
      guard let d = Dir.decode(stat) else { throw .invalid }
      try wstat(f, d)
      return .rwstat
    default:
      throw Refusal("bad message")
    }
  }

  static func flags(_ mode: UInt8) -> Int32 {
    var flags: Int32 = switch mode & 3 {
    case OpenMode.write: O_WRONLY
    case OpenMode.rdwr: O_RDWR
    default: O_RDONLY
    }
    if mode & OpenMode.trunc != 0 { flags |= O_TRUNC }
    return flags | O_CLOEXEC
  }

  func open(_ f: Fid, _ mode: UInt8) throws(Refusal) {
    switch f.place {
    case .top, .dev:
      guard mode & 3 == OpenMode.read || mode & 3 == OpenMode.exec else { throw .isDirectory }
    case .cons:
      break
    case .cpunote:
      guard mode & 3 == OpenMode.read else { throw .denied }
    case .net, .tcp, .conversation:
      guard mode & 3 == OpenMode.read || mode & 3 == OpenMode.exec else { throw .isDirectory }
    case .cs:
      break
    case .clone:
      // A new conversation: the fid is its ctl from now on.
      let c = tree.net.clone()
      f.conversation = c
      f.place = .netFile(c.number, .ctl)
    case .netFile(let n, _):
      guard let c = tree.net.conversation(n) else { throw .notFound }
      tree.net.hold(c)
      f.conversation = c
    case .host(let names):
      let s = try tree.hostStat(names)
      if s.st_mode & S_IFMT == S_IFDIR {
        guard mode & 3 == OpenMode.read || mode & 3 == OpenMode.exec else { throw .isDirectory }
        // Can the directory be read at all?
        guard let d = opendir(tree.path(names)) else { throw Refusal.errno() }
        closedir(d)
      } else {
        let fd = Glibc.open(tree.path(names), Self.flags(mode))
        guard fd >= 0 else { throw Refusal.errno() }
        f.fd = fd
      }
    }
    f.open = true
    f.mode = mode
    f.removeOnClunk = mode & OpenMode.rclose != 0
  }

  /// A directory's entries from `offset`, as many whole ones as `max`
  /// bytes hold; read again from the start at offset 0.
  func entries(_ f: Fid, offset: UInt64, max: Int) throws(Refusal) -> [UInt8] {
    if offset == 0 { f.listing = try tree.listing(f.place) }
    let at = Int(clamping: offset)
    var end = at
    guard at <= f.listing.count else { return [] }
    while end + 2 <= f.listing.count {
      let size = 2 + (Int(f.listing[end]) | Int(f.listing[end + 1]) << 8)
      guard end + size - at <= max else { break }
      end += size
    }
    if end == at, at < f.listing.count { throw Refusal("buffer too small") }
    return Array(f.listing[at..<end])
  }

  func close(_ f: Fid) {
    if f.fd >= 0 { Glibc.close(f.fd) }
    f.fd = -1
    f.open = false
    if let c = f.conversation { tree.net.release(c) }
    f.conversation = nil
  }

  func remove(_ p: Place) throws(Refusal) {
    guard case .host(let names) = p, !names.isEmpty else { throw .denied }
    let path = tree.path(names)
    let s = try tree.hostStat(names)
    let r = s.st_mode & S_IFMT == S_IFDIR ? rmdir(path) : unlink(path)
    guard r == 0 else { throw Refusal.errno() }
  }

  /// Twstat: what `d` changes (Dir.unchanged's fields stay as they are).
  func wstat(_ f: Fid, _ d: Dir) throws(Refusal) {
    let keep = Dir.unchanged
    guard case .host(let names) = f.place else {
      // The synthetic files take a change of nothing, as a sync.
      guard d.name.isEmpty, d.length == keep.length, d.mode == keep.mode, d.mtime == keep.mtime else { throw .denied }
      return
    }
    let path = tree.path(names)
    if d.length != keep.length {
      guard truncate(path, off_t(clamping: d.length)) == 0 else { throw Refusal.errno() }
    }
    if d.mode != keep.mode {
      guard chmod(path, mode_t(d.mode & 0o777)) == 0 else { throw Refusal.errno() }
    }
    if d.mtime != keep.mtime {
      // The access time UTIME_OMIT (Linux's, which Swift doesn't import).
      var times = [timespec(tv_sec: 0, tv_nsec: (1 << 30) - 2), timespec(tv_sec: Int(d.mtime), tv_nsec: 0)]
      guard utimensat(AT_FDCWD, path, &times, 0) == 0 else { throw Refusal.errno() }
    }
    if !d.name.isEmpty, names.last != d.name {
      guard !names.isEmpty, !d.name.contains("/"), d.name != ".", d.name != ".." else { throw .badName }
      let renamed = Array(names.dropLast()) + [d.name]
      guard rename(path, tree.path(renamed)) == 0 else { throw Refusal.errno() }
      f.place = .host(renamed)
    }
  }
}
