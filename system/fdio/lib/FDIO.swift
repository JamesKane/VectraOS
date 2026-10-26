// SPDX-License-Identifier: BSD-3-Clause

// fdio (M6g, decided 2026-10-12): POSIX's file descriptors over the Node
// and fs protocols, after Fuchsia's fdio. A descriptor is a channel to a
// node of the process's namespace, an offset and the flags it was opened
// with; paths are cleaned as the namespace cleans them (Plan 9's way), from
// a current directory fdio keeps. Natively (tier 1, system/fdio/native)
// they're exported under their C names, so C, C++ and Swift (Foundation's
// POSIX branches) all reach files this way; hosted, the suites compare
// each call with Linux's on the same scenario.
//
// What a node lacks, fdio doesn't pretend: there are no permissions (every
// file reads 0644, every directory 0755), no owners, links or symbolic
// links, and one time (the modification time) for all three. Directory
// entries list "." and ".." first, as Linux's do. A rename over an
// existing file removes it first: not atomic yet.
//
// Every call returns its result or an Errno (Linux's numbers, which our
// libc's <errno.h> has); the exports set errno.

import IPC
import Node
import Fs
import Sys

/// An errno value fdio returns (Linux's numbers).
public struct Errno: Error, Equatable, Sendable {
  public let code: Int32
  public init(_ code: Int32) { self.code = code }

  /// What Plan 9's error string says, as rc and the commands print it.
  public var text: String {
    switch code {
    case 2: "file does not exist"
    case 9: "fd out of range or not open"
    case 1, 13, 95: "permission denied"
    case 17: "file already exists"
    case 20: "not a directory"
    case 21: "file is a directory"
    case 22: "bad arg in system call"
    case 28: "file system full"
    case 30: "file system read only"
    case 36: "file name too long"
    case 39: "directory not empty"
    default: "i/o error"
    }
  }

  public static let notPermitted = Errno(1)  // EPERM
  public static let noEntry = Errno(2)  // ENOENT
  public static let io = Errno(5)  // EIO
  public static let badDescriptor = Errno(9)  // EBADF
  public static let denied = Errno(13)  // EACCES
  public static let busy = Errno(16)  // EBUSY
  public static let exists = Errno(17)  // EEXIST
  public static let crossDevice = Errno(18)  // EXDEV
  public static let notDirectory = Errno(20)  // ENOTDIR
  public static let isDirectory = Errno(21)  // EISDIR
  public static let invalid = Errno(22)  // EINVAL
  public static let tooMany = Errno(24)  // EMFILE
  public static let noSpace = Errno(28)  // ENOSPC
  public static let readOnly = Errno(30)  // EROFS
  public static let nameTooLong = Errno(36)  // ENAMETOOLONG
  public static let notEmpty = Errno(39)  // ENOTEMPTY
  public static let notSupported = Errno(95)  // EOPNOTSUPP

  static func of(_ e: NodeIPC.NodeError) -> Errno {
    switch e {
    case .notFound: noEntry
    case .notDirectory: notDirectory
    case .isDirectory: isDirectory
    case .exists: exists
    case .denied: denied
    case .badName: invalid
    case .tooManyNames: nameTooLong
    case .notEmpty: notEmpty
    case .unsupported: notSupported
    case .invalid: invalid
    case .io: io
    case .tooManyOps: invalid
    }
  }

  static func of(_ e: NodeIPC.NodeClient.Failure) -> Errno {
    if case .remote(let n) = e { return of(n) }
    return io
  }

  static func of(_ e: NamespaceError) -> Errno {
    switch e {
    case .badPath: invalid
    case .notFound: noEntry
    case .sealed, .unionFull, .cantCreate: denied
    case .node(let n): of(n)
    case .transport, .wire: io
    }
  }

  static func of(_ e: IPCError<FsIPC.FsError>) -> Errno {
    guard case .remote(let f) = e else { return io }
    switch f {
    case .notFound: return noEntry
    case .exists: return exists
    case .notDirectory: return notDirectory
    case .isDirectory: return isDirectory
    case .notEmpty: return notEmpty
    case .badName, .invalid, .badQuery, .needsIndex: return invalid
    case .noSpace, .tooLarge: return noSpace
    case .readOnly: return readOnly
    case .io, .cold: return io
    case .unsupported: return notSupported
    }
  }
}

/// open's flags (Linux's values, as our libc's <fcntl.h>).
public enum OpenFlags {
  public static let accessMode: Int32 = 0o3
  public static let readOnly: Int32 = 0
  public static let writeOnly: Int32 = 0o1
  public static let readWrite: Int32 = 0o2
  public static let create: Int32 = 0o100
  public static let exclusive: Int32 = 0o200
  public static let truncate: Int32 = 0o1000
  public static let append: Int32 = 0o2000
  public static let directory: Int32 = 0o200000
}

/// What stat says of a node.
public struct FileStatus: Equatable, Sendable {
  public var isDirectory: Bool
  public var size: UInt64
  /// Nanoseconds since the Unix epoch; 0 if unknown.
  public var modified: Int64
  /// The node's qid path: unique in its tree, never reused.
  public var id: UInt64

  public init(isDirectory: Bool, size: UInt64, modified: Int64, id: UInt64) {
    self.isDirectory = isDirectory
    self.size = size
    self.modified = modified
    self.id = id
  }

  init(_ s: NodeIPC.Stat) {
    self.init(isDirectory: s.qid.kind == .directory, size: s.size, modified: s.modified, id: s.qid.path)
  }
}

/// A directory's entry, as readdir gives it.
public struct DirectoryEntry: Equatable, Sendable {
  public var name: String
  public var isDirectory: Bool
  public var id: UInt64

  public init(name: String, isDirectory: Bool, id: UInt64) {
    self.name = name
    self.isDirectory = isDirectory
    self.id = id
  }
}

/// An open file description: what a descriptor names, shared by dup's
/// copies (none yet). Its calls go one at a time.
final class Description: @unchecked Sendable {
  let lock = Lock()
  var file: FsIPC.FileClient
  let isDirectory: Bool
  let flags: Int32
  /// The path it was opened by, cleaned.
  let path: String
  var offset: UInt64 = 0
  /// Its data's reads and writes (D103): messages, then the file's ring
  /// once it moves bulk, writes sent behind.
  var data = NodeFileIO()
  /// The file's bytes from `aheadAt` as they were when it was opened,
  /// sent with the open (`openAhead`): each taken once, by the read that
  /// reaches it, while the process has written no file since
  /// (`aheadWrites`). `aheadEnds`: the file ended where they do.
  var ahead: [UInt8] = []
  var aheadAt: UInt64 = 0
  var aheadEnds = false
  var aheadWrites: UInt64 = 0

  init(_ file: consuming FsIPC.FileClient, isDirectory: Bool, flags: Int32, path: String) {
    self.file = file
    self.isDirectory = isDirectory
    self.flags = flags
    self.path = path
  }

  /// Up to `buffer.count` bytes at `offset` from `ahead`, the rest of it
  /// kept for the reads after; nothing (and none kept) for a read
  /// elsewhere, or once the process has written.
  func takeAhead(_ offset: UInt64, _ buffer: UnsafeMutableRawBufferPointer) -> Int {
    defer { if ahead.isEmpty { aheadEnds = false } }
    guard offset >= aheadAt, offset < aheadAt + UInt64(ahead.count), FDIO.writes == aheadWrites else {
      ahead = []
      return 0
    }
    let from = Int(offset - aheadAt)
    let n = min(buffer.count, ahead.count - from)
    unsafe ahead.withUnsafeBytes { b in
      unsafe UnsafeMutableRawBufferPointer(rebasing: buffer[0..<n]).copyMemory(
        from: UnsafeRawBufferPointer(rebasing: b[from..<(from + n)]))
    }
    ahead.removeFirst(from + n)
    aheadAt = offset + UInt64(n)
    return n
  }

  var readable: Bool { flags & OpenFlags.accessMode != OpenFlags.writeOnly }
  var writable: Bool { flags & OpenFlags.accessMode != OpenFlags.readOnly }

  func node<R>(_ body: (inout NodeIPC.NodeClient) throws(NodeIPC.NodeClient.Failure) -> R) -> Result<R, Errno> {
    do throws(NodeIPC.NodeClient.Failure) {
      return .success(try file.node(body))
    } catch {
      return .failure(Errno.of(error))
    }
  }

  /// Its writes behind done: the first failure, if one failed. Whatever
  /// asks the file what it holds, or ends, comes after it.
  func finish() -> Result<Void, Errno> {
    do throws(NodeIPC.NodeClient.Failure) {
      try data.finish()
      return .success(())
    } catch {
      return .failure(Errno.of(error))
    }
  }

  func status() -> Result<FileStatus, Errno> {
    if case .failure(let e) = finish() { return .failure(e) }
    return node { (c: inout NodeIPC.NodeClient) throws(NodeIPC.NodeClient.Failure) in
      FileStatus(try c.stat(fields: NodeIPC.Fields.size | NodeIPC.Fields.modified))
    }
  }
}

/// A directory opened for reading: its entries, taken when opened.
public final class DirectoryStream: @unchecked Sendable {
  let entries: [DirectoryEntry]
  var next = 0

  init(_ entries: [DirectoryEntry]) { self.entries = entries }

  /// The next entry, or nil at the end.
  public func read() -> DirectoryEntry? {
    guard next < entries.count else { return nil }
    next += 1
    return entries[next - 1]
  }

  public func rewind() { next = 0 }
}

public enum FDIO {
  /// The process's: its namespace, its descriptors (0 to 2 the
  /// process's own), its current directory.
  struct State {
    var installed: Namespace? = nil
    var table: [Description?] = [nil, nil, nil]
    var cwd = "/"
    /// Writes and cuts made through any descriptor: a description's bytes
    /// read ahead are good while this hasn't moved.
    var writes: UInt64 = 0
  }
  static let state = Locked(State())

  static var writes: UInt64 { state.withLock { $0.writes } }

  /// A write or a cut, about to be sent: what was read ahead is stale.
  static func writing() { state.withLock { $0.writes &+= 1 } }

  /// How many of a file's first bytes a read-only open asks for (a page),
  /// so that a small file's first read needs no round trip.
  static let aheadBytes: UInt32 = 4096

  /// The most descriptors open at once.
  public static let maxDescriptors = 1024

  /// Makes `namespace` the one paths resolve in (natively, the process's
  /// Startup's, found on first use when none was installed).
  public static func install(_ namespace: Namespace) {
    state.withLock { s in
      s.installed = namespace
      s.cwd = "/"
    }
  }

  /// Makes `namespace` the one paths resolve in from now on, the current
  /// directory's path kept (rc's `rfork n` and `N`: Plan 9's dot stays).
  public static func replace(_ namespace: Namespace) {
    state.withLock { $0.installed = namespace }
  }

  /// The namespace paths resolve in.
  public static var namespace: Namespace? {
    state.withLock { s in
      if s.installed == nil { s.installed = processNamespace() }
      return s.installed
    }
  }

  // MARK: Paths

  /// `path` made absolute against the current directory.
  static func absolute(_ path: String) -> Result<String, Errno> {
    guard !path.isEmpty else { return .failure(Errno.noEntry) }
    guard !path.utf8.contains(0) else { return .failure(Errno.invalid) }
    if path.utf8.first == 0x2F { return .success(path) }
    let base = state.withLock { $0.cwd }
    return .success(base == "/" ? "/" + path : base + "/" + path)
  }

  /// `path` absolute and cleaned ("." and ".." resolved by name), as "/a/b".
  public static func clean(_ path: String) -> Result<String, Errno> {
    switch absolute(path) {
    case .failure(let e): return .failure(e)
    case .success(let abs):
      do throws(NamespaceError) {
        return .success("/" + (try Namespace.clean(abs)).joined(separator: "/"))
      } catch {
        return .failure(Errno.of(error))
      }
    }
  }

  /// `path` cleaned, in `given` (or the process's namespace).
  static func resolve(_ path: String, in given: Namespace? = nil) -> Result<(Namespace, String), Errno> {
    guard let ns = given ?? namespace else { return .failure(Errno.noEntry) }
    return clean(path).map { (ns, $0) }
  }

  /// What's wrong with the directories leading to `path` (cleaned): ENOENT
  /// if one isn't there, ENOTDIR if one is a file (POSIX's pathname
  /// resolution); nil if they're all directories.
  static func parentError(_ ns: Namespace, _ path: String) -> Errno? {
    var names = path.split(separator: "/").map(String.init)
    guard !names.isEmpty else { return nil }
    names.removeLast()
    var prefix = ""
    for name in names {
      prefix += "/" + name
      guard var c = try? ns.open(prefix) else { return Errno.noEntry }
      guard case .success(let s) = status(of: &c) else { return Errno.noEntry }
      if !s.isDirectory { return Errno.notDirectory }
    }
    return nil
  }

  /// Why `path` (cleaned) isn't there: ENOTDIR if a name before its last
  /// is a file, else ENOENT.
  static func missing(_ ns: Namespace, _ path: String) -> Errno { parentError(ns, path) ?? Errno.noEntry }

  /// The node at `path`. A path ending in "/" must name a directory
  /// (ENOTDIR otherwise), as POSIX's pathname resolution has it.
  /// `open(node:)` with the node's stat (`fields`) from the open's own
  /// batch: one round trip where an open and a stat were two.
  static func open(node path: String, in given: Namespace? = nil, stat fields: UInt32, ahead: UInt32 = 0)
    -> Result<NodeIPC.NodeClient.Opened, Errno>
  {
    switch resolve(path, in: given) {
    case .failure(let e): return .failure(e)
    case .success(let (ns, p)):
      // Used inside the `do`: a noncopyable `let` set there and read after
      // crashed 6.4's move-only checker.
      let slash = path.utf8.count > 1 && path.utf8.last == 0x2F
      do throws(NamespaceError) {
        let opened = try ns.open(p, stat: fields, ahead: ahead)
        if slash && !FileStatus(opened.stat).isDirectory { return .failure(Errno.notDirectory) }
        return .success(opened)
      } catch {
        let e = Errno.of(error)
        return .failure(e == Errno.noEntry ? missing(ns, p) : e)
      }
    }
  }

  static func open(node path: String, in given: Namespace? = nil) -> Result<NodeIPC.NodeClient, Errno> {
    switch resolve(path, in: given) {
    case .failure(let e): return .failure(e)
    case .success(let (ns, p)):
      var client: NodeIPC.NodeClient
      do throws(NamespaceError) {
        client = try ns.open(p)
      } catch {
        let e = Errno.of(error)
        return .failure(e == Errno.noEntry ? missing(ns, p) : e)
      }
      if path.utf8.count > 1 && path.utf8.last == 0x2F {
        switch status(of: &client) {
        case .failure(let e): return .failure(e)
        case .success(let s) where !s.isDirectory: return .failure(Errno.notDirectory)
        case .success: break
        }
      }
      return .success(client)
    }
  }

  static var statusFields: UInt32 { NodeIPC.Fields.size | NodeIPC.Fields.modified }

  static func status(of client: inout NodeIPC.NodeClient) -> Result<FileStatus, Errno> {
    do throws(NodeIPC.NodeClient.Failure) {
      return .success(FileStatus(try client.stat(fields: statusFields)))
    } catch {
      return .failure(Errno.of(error))
    }
  }

  // MARK: Descriptors

  static func add(_ d: Description) -> Result<Int32, Errno> {
    state.withLock { s in
      for fd in 3..<s.table.count where s.table[fd] == nil && !inherited(Int32(fd)) {
        s.table[fd] = d
        return .success(Int32(fd))
      }
      while inherited(Int32(s.table.count)) { s.table.append(nil) }
      guard s.table.count < maxDescriptors else { return .failure(Errno.tooMany) }
      s.table.append(d)
      return .success(Int32(s.table.count - 1))
    }
  }

  /// `count` numbers below `limit` that neither a file nor the floor
  /// holds, given to `take` with the table locked, so no open takes them
  /// meanwhile (pipe's, whose ends the floor holds). EMFILE if there
  /// aren't so many.
  public static func reserve(_ count: Int, below limit: Int32,
                             _ take: ([Int32]) -> Result<[Int32], Errno>) -> Result<[Int32], Errno> {
    state.withLock { s in
      var numbers: [Int32] = []
      for fd in Int32(3)..<limit where numbers.count < count && !inherited(fd) {
        if Int(fd) < s.table.count, s.table[Int(fd)] != nil { continue }
        numbers.append(fd)
      }
      guard numbers.count == count else { return .failure(Errno.tooMany) }
      return take(numbers)
    }
  }

  static func description(_ fd: Int32) -> Description? {
    state.withLock { s in fd >= 0 && Int(fd) < s.table.count ? s.table[Int(fd)] : nil }
  }

  /// open: a descriptor for the node at `path`, in `namespace` if given (a
  /// shell's fork resolves in its own: rc's `rfork n`), else the process's.
  public static func open(_ path: String, flags: Int32, mode: UInt32 = 0o644, in namespace: Namespace? = nil)
    -> Result<Int32, Errno>
  {
    // /dev/fd/N: descriptor N itself, one the process was started with
    // (no dup yet: closing it closes N).
    if let n = descriptorPath(path), n < 3 || inherited(n) { return .success(n) }
    let access = flags & OpenFlags.accessMode
    guard access != OpenFlags.accessMode else { return .failure(Errno.invalid) }
    var client: NodeIPC.NodeClient
    var found: FileStatus? = nil  // from the open's own batch, when it found the node
    // A read-only open of a file asks for its first bytes too.
    let ahead = access == OpenFlags.readOnly && flags & OpenFlags.directory == 0 ? aheadBytes : 0
    let writesBefore = ahead == 0 ? 0 : writes
    var read: [UInt8]? = nil
    switch open(node: path, in: namespace, stat: Self.statusFields, ahead: ahead) {
    case .success(let opened):
      if flags & OpenFlags.create != 0 && flags & OpenFlags.exclusive != 0 { return .failure(Errno.exists) }
      found = FileStatus(opened.stat)
      read = opened.ahead
      client = opened.takeClient()
    case .failure(Errno.noEntry) where flags & OpenFlags.create != 0:
      guard case .success(let (ns, p)) = resolve(path, in: namespace) else { return .failure(Errno.noEntry) }
      if flags & OpenFlags.directory != 0 { return .failure(Errno.invalid) }
      do throws(NamespaceError) {
        client = try ns.create(p, kind: .file)
      } catch {
        let e = Errno.of(error)
        return .failure(e == Errno.noEntry ? missing(ns, p) : e)
      }
    case .failure(let e):
      return .failure(e)
    }
    let info: FileStatus
    if let found {
      info = found
    } else {
      switch status(of: &client) {
      case .success(let s): info = s
      case .failure(let e): return .failure(e)
      }
    }
    if info.isDirectory && (access != OpenFlags.readOnly || flags & OpenFlags.create != 0) {
      return .failure(Errno.isDirectory)
    }
    if !info.isDirectory && flags & OpenFlags.directory != 0 { return .failure(Errno.notDirectory) }
    guard case .success(let cleaned) = clean(path) else { return .failure(Errno.noEntry) }
    let d = Description(FsIPC.FileClient(channel: client.takeChannel()), isDirectory: info.isDirectory, flags: flags,
                        path: cleaned)
    if let read, !read.isEmpty, !info.isDirectory {
      d.aheadEnds = read.count < Int(ahead)
      d.ahead = read
      d.aheadWrites = writesBefore
    }
    if flags & OpenFlags.truncate != 0 && access != OpenFlags.readOnly && !info.isDirectory && info.size > 0 {
      writing()
      do throws(IPCError<FsIPC.FsError>) {
        try d.file.resize(0)
      } catch {
        return .failure(Errno.of(error))
      }
    }
    return add(d)
  }

  /// N, for a path /dev/fd/N.
  public static func descriptorPath(_ path: String) -> Int32? {
    guard path.hasPrefix("/dev/fd/") else { return nil }
    return Int32(path.dropFirst(8))
  }

  /// close.
  /// Every open description's writes behind waited for (their failures
  /// dropped): at exit, so what `write` took is in its file, as POSIX
  /// asks, whether or not the program closed it.
  public static func finishAll() {
    let open = state.withLock { s in s.table.compactMap { $0 } }
    for d in open { _ = d.lock.withLock { d.finish() } }
  }

  /// close: its writes behind waited for first, and their failure said.
  public static func close(_ fd: Int32) -> Result<Void, Errno> {
    let closed = state.withLock { s -> Description? in
      guard fd >= 3, Int(fd) < s.table.count, let d = s.table[Int(fd)] else { return nil }
      s.table[Int(fd)] = nil
      return d
    }
    guard let closed else { return .failure(Errno.badDescriptor) }
    return closed.lock.withLock { closed.finish() }
  }

  /// read (`at` nil) or pread: up to `buffer.count` bytes.
  public static func read(_ fd: Int32, into buffer: UnsafeMutableRawBufferPointer, at offset: Int64? = nil)
    -> Result<Int, Errno>
  {
    guard let d = description(fd), d.readable else { return .failure(Errno.badDescriptor) }
    guard !d.isDirectory else { return .failure(Errno.isDirectory) }
    if let offset, offset < 0 { return .failure(Errno.invalid) }
    return d.lock.withLock {
      var at = offset.map { UInt64($0) } ?? d.offset
      var done = 0
      if !d.ahead.isEmpty {
        let ended = d.aheadEnds
        done = unsafe d.takeAhead(at, buffer)
        at += UInt64(done)
        // All it asked for, or the file's end as it was opened.
        if done > 0, done == buffer.count || ended && d.ahead.isEmpty {
          if offset == nil { d.offset = at }
          return .success(done)
        }
      }
      while done < buffer.count {
        let want = min(buffer.count - done, NodeFile.preferredIO)
        let start = at
        let onRing = d.data.onRing
        let got = d.node { (c: inout NodeIPC.NodeClient) throws(NodeIPC.NodeClient.Failure) in
          try d.data.read(&c, offset: start, max: want)
        }
        guard case .success(let bytes) = got else {
          if done > 0 { break }
          if case .failure(let e) = got { return .failure(e) }
          break
        }
        unsafe bytes.withUnsafeBytes { b in
          unsafe UnsafeMutableRawBufferPointer(rebasing: buffer[done..<(done + b.count)]).copyMemory(from: b)
        }
        done += bytes.count
        at += UInt64(bytes.count)
        // The end of the file: nothing, or on messages less than a
        // message's worth (a ring's read gives an entry's rest at most).
        if bytes.isEmpty || !onRing && bytes.count < min(want, NodeIPC.maxIO) { break }
      }
      if offset == nil { d.offset = at }
      return .success(done)
    }
  }

  /// write (`at` nil) or pwrite.
  public static func write(_ fd: Int32, _ buffer: UnsafeRawBufferPointer, at offset: Int64? = nil) -> Result<Int, Errno> {
    guard let d = description(fd), d.writable else { return .failure(Errno.badDescriptor) }
    if let offset, offset < 0 { return .failure(Errno.invalid) }
    return d.lock.withLock {
      var at: UInt64
      if let offset {
        at = UInt64(offset)
      } else if d.flags & OpenFlags.append != 0 {
        switch d.status() {
        case .success(let s): at = s.size
        case .failure(let e): return .failure(e)
        }
      } else {
        at = d.offset
      }
      // All of it, through the file's data (D103): on its ring, sent
      // behind, a failure said by a later write or by close.
      writing()
      let bytes = unsafe Array(buffer)
      let start = at
      let wrote = d.node { (c: inout NodeIPC.NodeClient) throws(NodeIPC.NodeClient.Failure) in
        try d.data.write(&c, offset: start, bytes)
      }
      if case .failure(let e) = wrote { return .failure(e) }
      at += UInt64(bytes.count)
      if offset == nil { d.offset = at }
      return .success(bytes.count)
    }
  }

  /// lseek: whence 0 (SEEK_SET), 1 (SEEK_CUR) or 2 (SEEK_END).
  public static func seek(_ fd: Int32, _ offset: Int64, whence: Int32) -> Result<Int64, Errno> {
    guard let d = description(fd) else { return .failure(Errno.badDescriptor) }
    return d.lock.withLock {
      let base: Int64
      switch whence {
      case 0: base = 0
      case 1: base = Int64(d.offset)
      case 2:
        guard !d.isDirectory else { return .failure(Errno.invalid) }  // as Linux's
        switch d.status() {
        case .success(let s): base = Int64(s.size)
        case .failure(let e): return .failure(e)
        }
      default: return .failure(Errno.invalid)
      }
      let (to, overflow) = base.addingReportingOverflow(offset)
      guard !overflow, to >= 0 else { return .failure(Errno.invalid) }
      d.offset = UInt64(to)
      return .success(to)
    }
  }

  /// fstat.
  public static func status(_ fd: Int32) -> Result<FileStatus, Errno> {
    guard let d = description(fd) else { return .failure(Errno.badDescriptor) }
    return d.lock.withLock { d.status() }
  }

  /// ftruncate.
  public static func truncate(_ fd: Int32, to size: Int64) -> Result<Void, Errno> {
    guard let d = description(fd) else { return .failure(Errno.badDescriptor) }
    // Not open for writing: EINVAL, as Linux says (POSIX allows EBADF too).
    guard d.writable, !d.isDirectory else { return .failure(Errno.invalid) }
    guard size >= 0 else { return .failure(Errno.invalid) }
    return d.lock.withLock {
      if case .failure(let e) = d.finish() { return .failure(e) }
      writing()
      do throws(IPCError<FsIPC.FsError>) {
        try d.file.resize(UInt64(size))
        return .success(())
      } catch {
        return .failure(Errno.of(error))
      }
    }
  }

  /// fsync: what was written made durable (the volume's intent log).
  public static func sync(_ fd: Int32) -> Result<Void, Errno> {
    guard let d = description(fd) else { return .failure(Errno.badDescriptor) }
    // A directory's channel speaks Directory: its sync, through a channel
    // of its own (Taisce's commits the whole volume either way).
    if d.isDirectory {
      switch open(node: d.path) {
      case .failure(let e): return .failure(e)
      case .success(let c):
        var dir = FsIPC.DirectoryClient(channel: c.takeChannel())
        do throws(IPCError<FsIPC.FsError>) {
          try dir.sync()
          return .success(())
        } catch {
          return .failure(Errno.of(error))
        }
      }
    }
    return d.lock.withLock {
      if case .failure(let e) = d.finish() { return .failure(e) }
      do throws(IPCError<FsIPC.FsError>) {
        try d.file.sync()
        return .success(())
      } catch {
        return .failure(Errno.of(error))
      }
    }
  }

  // MARK: Paths' calls

  /// stat (and lstat: there are no symbolic links).
  public static func status(_ path: String) -> Result<FileStatus, Errno> {
    switch open(node: path) {
    case .failure(let e): return .failure(e)
    case .success(var c): return status(of: &c)
    }
  }

  /// mkdir.
  public static func makeDirectory(_ path: String) -> Result<Void, Errno> {
    switch open(node: path) {
    case .success: return .failure(Errno.exists)
    case .failure(let e) where e != Errno.noEntry: return .failure(e)
    case .failure: break
    }
    switch resolve(path) {
    case .failure(let e): return .failure(e)
    case .success(let (ns, p)):
      guard p != "/" else { return .failure(Errno.exists) }
      do throws(NamespaceError) {
        _ = try ns.create(p, kind: .directory)
        return .success(())
      } catch {
        let e = Errno.of(error)
        return .failure(e == Errno.noEntry ? missing(ns, p) : e)
      }
    }
  }

  static func remove(_ path: String, directory: Bool) -> Result<Void, Errno> {
    guard case .success(let p) = clean(path) else { return .failure(Errno.noEntry) }
    if p == "/" { return .failure(directory ? Errno.busy : Errno.isDirectory) }
    switch open(node: path) {
    case .failure(let e): return .failure(e)
    case .success(var c):
      switch status(of: &c) {
      case .failure(let e): return .failure(e)
      case .success(let s):
        if directory && !s.isDirectory { return .failure(Errno.notDirectory) }
        if !directory && s.isDirectory { return .failure(Errno.isDirectory) }
      }
      do throws(NodeIPC.NodeClient.Failure) {
        try c.remove()
        return .success(())
      } catch {
        return .failure(Errno.of(error))
      }
    }
  }

  /// unlink.
  public static func unlink(_ path: String) -> Result<Void, Errno> { remove(path, directory: false) }

  /// rmdir.
  public static func removeDirectory(_ path: String) -> Result<Void, Errno> { remove(path, directory: true) }

  /// rename: within one mount (EXDEV across two), replacing a file at `to`.
  public static func rename(_ from: String, to: String) -> Result<Void, Errno> {
    guard let ns = namespace else { return .failure(Errno.noEntry) }
    let source: (mount: String, rest: [String])
    let target: (mount: String, rest: [String])
    do throws(NamespaceError) {
      guard case .success(let f) = clean(from), case .success(let t) = clean(to) else { return .failure(Errno.noEntry) }
      source = try ns.locate(f)
      target = try ns.locate(t)
    } catch {
      return .failure(Errno.of(error))
    }
    // As Linux checks: both paths' directories, the source, a directory
    // moved into itself, then what's at the target.
    guard case .success(let f) = clean(from), case .success(let t) = clean(to) else { return .failure(Errno.noEntry) }
    if let e = parentError(ns, f) ?? parentError(ns, t) { return .failure(e) }
    let moving: FileStatus
    switch status(from) {
    case .failure(let e): return .failure(e)
    case .success(let s): moving = s
    }
    guard source.mount == target.mount else { return .failure(Errno.crossDevice) }
    guard !source.rest.isEmpty, !target.rest.isEmpty else { return .failure(Errno.busy) }
    if source.rest == target.rest { return .success(()) }
    let inside = target.rest.count > source.rest.count && Array(target.rest.prefix(source.rest.count)) == source.rest
    if inside && moving.isDirectory { return .failure(Errno.invalid) }
    switch status(to) {
    case .success(let existing):
      if existing.isDirectory && !moving.isDirectory { return .failure(Errno.isDirectory) }
      if !existing.isDirectory && moving.isDirectory { return .failure(Errno.notDirectory) }
      if case .failure(let e) = remove(to, directory: existing.isDirectory) { return .failure(e) }
    case .failure(let e) where e != Errno.noEntry:
      return .failure(e)
    case .failure:
      break  // nothing there; its directories were checked
    }
    switch open(node: source.mount) {
    case .failure(let e): return .failure(e)
    case .success(let root):
      var dir = FsIPC.DirectoryClient(channel: root.takeChannel())
      do throws(IPCError<FsIPC.FsError>) {
        try dir.rename(source.rest.joined(separator: "/"), to: target.rest.joined(separator: "/"))
        return .success(())
      } catch {
        return .failure(Errno.of(error))
      }
    }
  }

  /// access: whether the node exists (there are no permissions to check).
  public static func access(_ path: String) -> Result<Void, Errno> { status(path).map { _ in () } }

  /// getcwd.
  public static var currentDirectory: String { state.withLock { $0.cwd } }

  /// chdir.
  public static func changeDirectory(_ path: String) -> Result<Void, Errno> {
    switch clean(path) {
    case .failure(let e): return .failure(e)
    case .success(let p):
      switch status(p) {
      case .failure(let e): return .failure(e)
      case .success(let s):
        guard s.isDirectory else { return .failure(Errno.notDirectory) }
        state.withLock { $0.cwd = p }
        return .success(())
      }
    }
  }

  /// realpath: absolute and cleaned, and there (no links to follow).
  public static func realPath(_ path: String) -> Result<String, Errno> {
    clean(path).flatMap { p in status(p).map { _ in p } }
  }

  /// opendir: the directory's entries, "." and ".." first.
  public static func openDirectory(_ path: String) -> Result<DirectoryStream, Errno> {
    switch listing(path, fields: 0) {
    case .failure(let e): return .failure(e)
    case .success(let (s, listed)):
      var entries = [DirectoryEntry(name: ".", isDirectory: true, id: s.id),
                     DirectoryEntry(name: "..", isDirectory: true, id: 0)]
      for e in listed { entries.append(DirectoryEntry(name: e.name, isDirectory: e.qid.kind == .directory, id: e.qid.path)) }
      return .success(DirectoryStream(entries))
    }
  }

  /// The directory at `path` (its status) and its entries, with `fields`
  /// of each one's stat: a walk asks for `statusFields`, and so needs no
  /// stat of each entry by its path.
  static func listing(_ path: String, fields: UInt32) -> Result<(FileStatus, [NodeIPC.Stat]), Errno> {
    switch resolve(path) {
    case .failure(let e): return .failure(e)
    case .success(let (ns, p)):
      switch status(p) {
      case .failure(let e): return .failure(e)
      case .success(let s):
        guard s.isDirectory else { return .failure(Errno.notDirectory) }
        do throws(NamespaceError) {
          return .success((s, try ns.list(p, fields: fields)))
        } catch {
          return .failure(Errno.of(error))
        }
      }
    }
  }
}
