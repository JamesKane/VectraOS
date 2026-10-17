// SPDX-License-Identifier: BSD-3-Clause

// rc's machine on croi (M6j part 2c; V2: on rings, D46): its programs are
// its namespace's (D71: /bin, the bootfs service's), started in a job of its own, each with its descriptors
// (Sys's ChildStdio: a ring per descriptor, one way) and rc's namespace in
// its Startup (D65). A child gets each descriptor rc's table has for it,
// fd 2 and any above it too (up to td_stdio.h's limits); one writer per
// ring: rc relays, a thread a descriptor, between a child's ring and the
// stream rc's descriptor names (a pipe, a file, a backquote's capture,
// rc's own). A pipe is a channel pair of rc's own, its writer's closing
// its reader's end. A child given rc's own stdin reads an empty one, since
// a relay would take the terminal's next line from rc (rc on a /dev/cons
// shares its terminal: Terminal.swift, which lends it to the program
// instead). <{} and >{} name a pipe's end /dev/fd/N, N one
// of rc's numbers (32 to 63), which the child is given at N.

import FDIO
import Fs
import IPC
import Node
import Rc
import Sys
import TDNative

/// A handle a class keeps: lent out by `with`, closed by `close` (or its
/// end). Its number is kept, not a `Handle?`: a class's noncopyable
/// optional can't be unwrapped without moving it.
final class Owned: @unchecked Sendable {
  private(set) var raw: UInt32
  init(_ h: consuming Handle) { raw = h.release() }
  deinit { close() }
  func close() {
    if raw != 0 { _ = Handle(raw: raw) }  // dropped: closed
    raw = 0
  }
  /// `body` with the handle, borrowed; nil once it's closed.
  func with<R>(_ body: (borrowing Handle) -> R) -> R? {
    guard raw != 0 else { return nil }
    let h = Handle(raw: raw)
    let r = body(h)
    _ = h.release()
    return r
  }
}

/// One end of a pipe: a channel end of rc's own. Writes go as messages,
/// reads wait for one; the other end's closing is the end. Its holders are
/// counted: rc, which drops its hold once the program writing the pipe is
/// started, and that program's relay, which writes on until the program's
/// output ends. The channel end closes with the last (a channel handle
/// can't be duplicated: an endpoint has one reader, as in Zircon).
final class PipeStream: RcStream, @unchecked Sendable {
  let owned: Owned
  let lock = Lock()
  var holders = 1
  /// Its reading end (a program given it reads it).
  let source: Bool?
  init(_ h: consuming Handle, reads: Bool) {
    owned = Owned(h)
    source = reads
  }

  /// One more holder, which will `close` it once.
  func hold() { lock.withLock { holders += 1 } }

  func write(_ bytes: [UInt8]) {
    var at = 0
    while at < bytes.count {
      let n = min(32_768, bytes.count - at)
      let ok = owned.with { h in (try? Channel.write(h, bytes: Array(bytes[at..<(at + n)]))) != nil } ?? false
      if !ok { return }  // the reader has gone
      at += n
    }
  }

  func read() -> [UInt8]? {
    owned.with { h -> [UInt8]? in
      while true {
        do throws(Status) {
          let m = try Channel.read(h)
          if !m.bytes.isEmpty { return m.bytes }
        } catch .shouldWait {
          _ = try? h.wait(for: Signals.readable | Signals.peerClosed)
        } catch {
          return nil  // the writer closed: the end
        }
      }
    } ?? nil
  }

  /// Drops a hold: the last closes the channel end.
  func close() {
    let last = lock.withLock { () -> Bool in
      holders -= 1
      return holders == 0
    }
    if last { owned.close() }
  }
}

/// One of fdio's files.
final class FileStream: RcStream {
  var fd: Int32
  let source: Bool?
  init(_ fd: Int32, reads: Bool?) {
    self.fd = fd
    source = reads
  }
  func write(_ bytes: [UInt8]) {
    guard fd >= 0 else { return }
    bytes.withUnsafeBytes { b in _ = FDIO.write(fd, b) }
  }
  func read() -> [UInt8]? {
    guard fd >= 0 else { return nil }
    var buffer = [UInt8](repeating: 0, count: 8192)
    let n = buffer.withUnsafeMutableBytes { b in (try? FDIO.read(fd, into: b).get()) ?? 0 }
    return n > 0 ? Array(buffer[0..<n]) : nil
  }
  func close() {
    if fd >= 0 { _ = FDIO.close(fd) }
    fd = -1
  }
}

/// A started program, its stdio, the threads relaying it, and its exit
/// string's page (D72).
final class Job: RcJob {
  let process: Owned
  let stdio: ChildStdio
  var relays: [Owned]
  let said: ExitString
  /// Its name, as Plan 9's kernel keeps a process's text.
  let name: String
  /// Its process's koid ($apid).
  let id: UInt64
  /// Its stdin, while it has the terminal (Terminal.swift).
  var lent: ChildStream? = nil
  init(process: consuming Handle, name: String, stdio: ChildStdio, relays: [Owned], said: consuming ExitString) {
    id = (try? process.info().koid) ?? 0
    self.process = Owned(process)
    self.name = name
    self.stdio = stdio
    self.relays = relays
    self.said = said
  }
  /// Its status as Plan 9's wait message gives it: "" if it succeeded,
  /// else `name pid: why`, why its exit string (or, if it said none, its
  /// code, or `killed`).
  func wait() -> String {
    let code = process.with { p -> Int64 in
      _ = try? p.wait(for: Signals.terminated)
      return (try? Process.info(p).returnCode) ?? 0
    } ?? 0
    if let lent { Terminal.current?.reclaim(lent) }
    lent = nil
    for t in relays { t.with { h in try? Thread.join(h) } }
    relays.removeAll()
    var why = said.read()
    if why.isEmpty && code != 0 { why = code == -1024 ? "killed" : String(code) }  // TASK_RETCODE_SYSCALL_KILL
    return why.isEmpty ? "" : name + " " + String(id) + ": " + why
  }
}

/// rc's machine. A program is a file of its namespace that gives memory to
/// run (Node's `memory`, D71): /bin's, the bootfs service's, as $path is
/// Plan 9's `(. /bin)`. A file starting `#!` runs as a kernel's exec runs
/// one: its interpreter, an argument if the line has one, the file, then
/// the rest. A child that is rc (a script's interpreter, or rc run by
/// name) is given a job under rc's, to start its own.
///
/// Where 9front forks (a backquote, a subshell, a pipeline's earlier
/// stage, `&`, <{}), rc runs a copy of itself on a fork of this: its own
/// directory, and its namespace shared until it does `rfork n`, as a Plan 9
/// fork's are. Paths are resolved here against them, and FDIO given them
/// absolute (its directory and namespace are the process's).
final class CroiSystem: RcSystem {
  /// What rc and its forks share: the job programs start in, the jobs
  /// `rfork s` made (kept while rc lives), and the streams numbered for
  /// <{} and >{}.
  final class Shared: @unchecked Sendable {
    let job: Handle
    var groups: [UInt32] = []
    let lock = Lock()
    var numbered: [Int32: RcStream] = [:]
    var nextNumber: Int32 = 32
    init(job: consuming Handle) { self.job = job }
  }
  let shared: Shared
  /// This rc's directory and namespace, and the job its programs start in:
  /// its note group (proc(4)'s notepg), a new one after `rfork s`.
  var cwd: String
  var namespace: Namespace?
  var job: UInt32

  init(job: consuming Handle) {
    shared = Shared(job: job)
    cwd = FDIO.currentDirectory
    namespace = FDIO.namespace
    self.job = shared.job.raw
  }

  init(_ shared: Shared, cwd: String, namespace: Namespace?, job: UInt32) {
    self.shared = shared
    self.cwd = cwd
    self.namespace = namespace
    self.job = job
  }

  /// A fork's: the same namespace (until it forks its own), its own
  /// directory.
  func fork() -> RcSystem { CroiSystem(shared, cwd: cwd, namespace: namespace, job: job) }

  /// `path` absolute against this directory, and cleaned.
  func full(_ path: String) -> String? {
    guard !path.isEmpty else { return nil }
    let abs = path.hasPrefix("/") ? path : (cwd == "/" ? "/" + path : cwd + "/" + path)
    guard let names = try? Namespace.clean(abs) else { return nil }
    return "/" + names.joined(separator: "/")
  }

  /// The node at `path`'s kind, if it's there: a path with mount points
  /// below it and nothing mounted there (/ itself) a directory, as the
  /// namespace lists it.
  func kind(_ path: String) -> NodeIPC.NodeKind? {
    guard let namespace, let p = full(path) else { return nil }
    if var c = try? namespace.open(p) { return (try? c.stat(fields: 0))?.qid.kind }
    return (try? namespace.list(p, fields: 0)) != nil ? .directory : nil
  }

  func open(_ path: String, _ mode: RcOpen) -> RcStream? {
    let flags: Int32
    switch mode {
    case .read: flags = OpenFlags.readOnly
    case .readWrite: flags = OpenFlags.readWrite
    case .write: flags = OpenFlags.writeOnly | OpenFlags.create | OpenFlags.truncate
    case .append: flags = OpenFlags.writeOnly | OpenFlags.create | OpenFlags.append
    }
    // /dev/fd/N: one of rc's own numbered streams (<{}), or a descriptor
    // rc was started with.
    if let n = FDIO.descriptorPath(path) {
      if let s = shared.lock.withLock({ shared.numbered[n] }) { return s }
      if n < 3 || td_stdio_has(n, nil) { return Standard(n) }
    }
    guard let p = full(path), case .success(let fd) = FDIO.open(p, flags: flags, in: namespace) else { return nil }
    return FileStream(fd, reads: mode == .read ? true : mode == .readWrite ? nil : false)
  }

  func pipe() -> (RcStream, RcStream) {
    guard let ends = try? Channel.create() else {
      return (PipeStream(Handle(raw: 0), reads: true), PipeStream(Handle(raw: 0), reads: false))
    }
    return (PipeStream(ends.a, reads: true), PipeStream(ends.b, reads: false))
  }

  /// A number for `s` (32 to 63, round again: below td_stdio.h's limit
  /// and above what a script names), its path /dev/fd/N.
  func descriptor(_ s: RcStream) -> (fd: Int32, path: String)? {
    let n = shared.lock.withLock { () -> Int32 in
      let n = shared.nextNumber
      shared.nextNumber = n == 63 ? 32 : n + 1
      shared.numbered[n] = s
      return n
    }
    return (n, "/dev/fd/\(n)")
  }

  /// The program at `path`: its file's memory, to run, if the namespace's
  /// server gives it.
  func program(_ path: String) -> NodeIPC.Memory? {
    guard let namespace, let p = full(path) else { return nil }
    return try? namespace.memory(p, executable: true)
  }

  /// A script's `#!` line: its interpreter and the argument after it, if
  /// any (the line's first 256 bytes, as Linux reads them).
  func interpreter(_ path: String) -> (path: String, argument: String?)? {
    guard let s = open(path, .read) else { return nil }
    defer { s.close() }
    guard let head = s.read(), head.starts(with: Array("#!".utf8)) else { return nil }
    let line = head.dropFirst(2).prefix(254).prefix { $0 != 0x0A }
    let words = line.split { $0 == 0x20 || $0 == 0x09 }.map { String(decoding: $0, as: UTF8.self) }
    guard let first = words.first else { return nil }
    return (first, words.count > 1 ? words.dropFirst().joined(separator: " ") : nil)
  }

  func executable(_ path: String) -> Bool {
    if program(path) != nil { return true }  // (its memory closed)
    guard let i = interpreter(path) else { return false }
    return program(i.path) != nil
  }

  /// A thread relaying `body`, kept to be joined.
  static func relay(_ body: @escaping @Sendable () -> Void) -> Owned? {
    guard let thread = try? Thread.spawn(body) else { return nil }
    return Owned(thread)
  }

  func start(_ path: String, _ argv: [String], fds: [Int32: RcStream], environment: [String]) -> RcJob? {
    if let m = program(path) { return start(path, m, argv, fds: fds, environment: environment) }
    guard let i = interpreter(path), let m = program(i.path) else { return nil }
    let args = [i.path] + (i.argument.map { [$0] } ?? []) + [path] + argv.dropFirst()
    return start(i.path, m, args, fds: fds, environment: environment)
  }

  /// Starts the program at `path`, from its memory.
  func start(_ path: String, _ memory: borrowing NodeIPC.Memory, _ argv: [String], fds: [Int32: RcStream],
             environment: [String]) -> RcJob?
  {
    let name = String(path.split(separator: "/").last ?? Substring(path))
    let entry = ProgramEntry(image: memory.vmo.raw, offset: 0, length: Int(memory.size), name: name)
    // Its environment is rc's group, at the /env of rc's namespace (D81),
    // rc's variables written there already; its directory there as $PWD
    // (M6m: the file commands' paths are rc's), written each time, since
    // rc's forks share the group with their own directories.
    try? namespace?.setEnvironment("PWD", Array(cwd.utf8) + [0])
    let startup = Startup(args: argv)
    // rc's namespace whole: each union's members in their order, those
    // marked for creating so marked, sealed if it is.
    if let ns = namespace { try? startup.mount(ns) }
    do throws(Status) {
      if name == "rc" {
        startup.add(try withJob { (j: borrowing Handle) throws(Status) in try Sys.Job.create(parent: j) },
                    info: HandleType.info(HandleType.jobDefault))
      }
      // Each of its descriptors, as many as a child takes: one it reads
      // if its stream is a source (or it is fd 0), one it writes if not.
      let given = fds.filter { $0.key >= 0 && $0.key < Int32(TD_STDIO_FD_LIMIT) }.sorted { $0.key < $1.key }
        .prefix(Int(TD_STDIO_FDS))
      let stdio = try ChildStdio(for: startup, descriptors: given.map { ($0.key, $0.value.source ?? ($0.key == 0)) })
      let said = try ExitString(for: startup)
      let process = try withJob { (j: borrowing Handle) throws(Status) in try Process.create(job: j, name: name) }
      _ = try Process.start(process, entry: entry, startup)
      /// A relay's stream: a pipe held for as long as the relay runs (rc
      /// drops its own hold once the program is started), anything else
      /// rc's.
      final class Box: @unchecked Sendable {
        let ring: ChildStream
        let stream: RcStream?
        let own: Bool
        init(_ ring: ChildStream, _ r: RcStream?) {
          self.ring = ring
          if let pipe = r as? PipeStream {
            pipe.hold()
            stream = pipe
            own = true
          } else {
            stream = r
            own = false
          }
        }
        func done() { if own { stream?.close() } }
      }
      var relays: [Owned] = []
      var lend: ChildStream? = nil
      for (fd, stream) in given {
        guard let ring = stdio.stream(fd) else { continue }
        // rc's own stdin on a terminal: lent (no relay).
        if fd == 0, (stream as? Standard)?.fd == 0, Terminal.current != nil {
          lend = ring
          continue
        }
        if ring.childReads {
          // Into the child: the stream, then the end (none for rc's own
          // stdin).
          let input = Box(ring, (stream as? Standard)?.fd == 0 ? nil : stream)
          if let r = Self.relay({
            defer { input.done() }
            if let s = input.stream {
              while let bytes = s.read() {
                if (try? input.ring.write(bytes)) == nil { return }
              }
            }
            try? input.ring.closeInput()
          }) { relays.append(r) }
        } else {
          // Out of it, into the stream, to its end.
          let output = Box(ring, stream)
          if let r = Self.relay({
            defer { output.done() }
            while let bytes = try? output.ring.read(), !bytes.isEmpty { output.stream?.write(bytes) }
          }) { relays.append(r) }
        }
      }
      let job = Job(process: process, name: name, stdio: stdio, relays: relays, said: said)
      if let lend {
        job.lent = lend
        Terminal.current?.lend(lend, process: job.process)
      }
      return job
    } catch {
      return nil
    }
  }

  func changeDirectory(_ path: String) -> Bool {
    guard kind(path) == .directory, let p = full(path) else { return false }
    cwd = p
    return true
  }

  var directory: String { cwd }

  /// The notes posted to rc (NoteQueue, D87).
  func takeNotes() -> [String] { NoteQueue.shared.take() }

  /// `body` given this rc's job, which stays rc's (Shared's).
  func withJob(_ body: (borrowing Handle) throws(Status) -> Handle) throws(Status) -> Handle {
    let j = Handle(raw: job)
    let made: Handle
    do throws(Status) {
      made = try body(j)
    } catch {
      _ = j.release()
      throw error
    }
    _ = j.release()
    return made
  }

  /// rfork s: what rc starts from now on starts in a new job under the
  /// one it used, a note group of its own.
  func forkNoteGroup() -> Bool {
    guard let group = try? withJob({ (j: borrowing Handle) throws(Status) in try Sys.Job.create(parent: j) }) else {
      return false
    }
    job = group.release()
    shared.lock.withLock { shared.groups.append(job) }
    return true
  }

  /// rfork n, N and m: this rc's namespace (which its programs get) a
  /// clone of itself or a new empty one, sealed as before (Plan 9's
  /// noattach is inherited), then sealed if asked.
  func forkNamespace(clean: Bool, seal: Bool) -> Bool {
    guard let ns = namespace else { return false }
    let next: Namespace
    if clean {
      next = Namespace(sealed: ns.sealed)
    } else {
      guard let copy = try? ns.clone() else { return false }
      next = copy
    }
    if seal { next.seal() }
    namespace = next
    return true
  }

  /// /env's files (D81): none if rc was given no /env.
  func environmentFiles() -> [(name: String, bytes: [UInt8])]? {
    guard let ns = namespace, let entries = try? ns.list("/env") else { return [] }
    return entries.compactMap { e in
      guard var c = try? ns.open("/env/" + e.name), let bytes = try? c.readAll() else { return nil }
      return (e.name, bytes)
    }
  }

  func setEnvironmentFile(_ name: String, _ bytes: [UInt8]) { try? namespace?.setEnvironment(name, bytes) }

  /// rfork e and E: a new group from /svc/env's `new` (the launcher's,
  /// D81), mounted at /env, with e what the group held copied into it. The
  /// group is in rc's namespace, so this makes the namespace rc's own, as
  /// `rfork n` does.
  func forkEnvironment(clean: Bool) -> Bool {
    guard let ns = namespace, let next = try? ns.clone(), let group = try? ns.connect("/svc/env/new") else {
      return false
    }
    let copied = clean ? [] : environmentFiles() ?? []
    guard (try? next.mount(group, at: "/env")) != nil else { return false }
    for f in copied { try? next.setEnvironment(f.name, f.bytes) }
    namespace = next
    return true
  }

  /// A thread of rc's, joined by its job, its status what it returned;
  /// its koid is $apid.
  final class ThreadJob: RcJob, @unchecked Sendable {
    var thread: Owned? = nil
    var id: UInt64 = 0
    var status = ""
    func wait() -> String {
      thread?.with { h in try? Thread.join(h) }
      thread?.close()
      return status
    }
  }

  func spawn(_ body: @escaping @Sendable () -> String) -> RcJob? {
    let job = ThreadJob()
    guard let thread = Self.relay({ job.status = body() }) else { return nil }
    job.id = thread.with { h in (try? h.info().koid) ?? 0 } ?? 0
    job.thread = thread
    return job
  }

  /// rc's koid, which croi never reuses.
  var processID: UInt64 { (try? Process.current().info().koid) ?? 1 }

  // Attributes, through the fs service (M6j, `attr`): Node's stat lists
  // them; the Attributes calls (a file's and a directory's alike) change
  // them.
  func node(_ path: String) -> Handle? {
    guard let namespace, let p = full(path) else { return nil }
    return try? namespace.connect(p)
  }

  func attributes(_ path: String) -> [(name: String, value: AttributeText)]? {
    guard let ch = node(path) else { return nil }
    var n = NodeIPC.NodeClient(channel: ch)
    guard let st = try? n.stat(fields: NodeIPC.Fields.attributes) else { return nil }
    return st.attributes.map { a in
      func integer() -> Int64 { Int64(bitPattern: a.value.prefix(8).reversed().reduce(0) { $0 << 8 | UInt64($1) }) }
      switch a.kind {
      case 1, 9: return (a.name, .string(String(decoding: a.value, as: UTF8.self)))
      case 2 where a.value.count == 8: return (a.name, .int(integer()))
      case 6 where a.value.count == 1: return (a.name, .bool(a.value[0] != 0))
      case 5 where a.value.count == 8: return (a.name, .other("time " + String(integer())))
      default: return (a.name, .other("(\(a.value.count) bytes, kind \(a.kind))"))
      }
    }
  }

  func setAttribute(_ path: String, _ name: String, _ value: AttributeText?) -> Bool {
    guard let ch = node(path) else { return false }
    var f = FsIPC.FileClient(channel: ch)
    guard let value else { return (try? f.removeAttribute(name)) != nil }
    let attribute: FsIPC.Attribute
    switch value {
    case .int(let v):
      let u = UInt64(bitPattern: v)
      attribute = FsIPC.Attribute(name: name, kind: 2, value: (0..<8).map { UInt8(truncatingIfNeeded: u >> (8 * UInt64($0))) })
    case .bool(let b): attribute = FsIPC.Attribute(name: name, kind: 6, value: [b ? 1 : 0])
    case .string(let s), .other(let s): attribute = FsIPC.Attribute(name: name, kind: 1, value: Array(s.utf8))
    }
    return (try? f.setAttribute(attribute)) != nil
  }

  func list(_ directory: String) -> [String]? {
    guard let namespace, let p = full(directory), let entries = try? namespace.list(p, fields: 0) else { return nil }
    return entries.map { $0.name }
  }
}

/// rc's notes (D87), as 9front's notifyf takes them: a note starting with
/// one of syssigname's is kept for rc as its trap's name (`interrupt` as
/// `sigint`), an interrupt only if none waits already; any other ends rc,
/// a note's default.
final class NoteQueue: @unchecked Sendable {
  static let shared = NoteQueue()
  static let traps: [(note: String, trap: String)] = [
    ("hangup", "sighup"), ("interrupt", "sigint"), ("quit", "sigquit"), ("alarm", "sigalrm"), ("kill", "sigkill"),
    ("sys: fp: ", "sigfpe"), ("term", "sigterm"),
  ]
  let lock = Lock()
  var pending: [String] = []

  /// From now on rc takes its notes.
  func start() {
    try? Note.notify { [self] note in
      guard let t = Self.traps.first(where: { note.hasPrefix($0.note) }) else { return false }
      lock.withLock { if t.trap != "sigint" || !pending.contains("sigint") { pending.append(t.trap) } }
      Terminal.current?.bump()  // rc waiting for a line on the console
      return true
    }
  }

  /// Whether notes wait to be taken.
  var waiting: Bool { lock.withLock { !pending.isEmpty } }

  func take() -> [String] {
    lock.withLock {
      defer { pending = [] }
      return pending
    }
  }
}
