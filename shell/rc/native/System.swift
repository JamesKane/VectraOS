// SPDX-License-Identifier: BSD-3-Clause

// rc's machine on croi (M6j part 2c; V2: on rings, D46): its programs are
// bootfs's `bin/`, started in a job of its own, each with stdio of its own
// (Sys's ChildStdio: its stdin and stdout rings) and rc's namespace in its
// Startup (D65). One writer per ring: rc relays, a thread a direction,
// between a child's rings and the streams its descriptors name (a pipe, a
// file, a backquote's capture, rc's own stdout). A pipe is a channel pair
// of rc's own, its writer's closing its reader's end. A child's stderr is
// its stdout (the floor's), so `>[2]` goes with fd 1; a child given rc's
// own stdin reads an empty one, since a relay would take the terminal's
// next line from rc (the pty shares a terminal, V2's item 6).

import FDIO
import Fs
import IPC
import Node
import Rc
import Sys

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
  init(_ h: consuming Handle) { owned = Owned(h) }

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
  init(_ fd: Int32) { self.fd = fd }
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

/// A started program, its stdio, and the threads relaying it.
final class Job: RcJob {
  let process: Owned
  let stdio: ChildStdio
  var relays: [Owned]
  init(process: consuming Handle, stdio: ChildStdio, relays: [Owned]) {
    self.process = Owned(process)
    self.stdio = stdio
    self.relays = relays
  }
  func wait() -> String {
    let code = process.with { p -> Int64 in
      _ = try? p.wait(for: Signals.terminated)
      return (try? Process.info(p).returnCode) ?? 0
    } ?? 0
    for t in relays { t.with { h in try? Thread.join(h) } }
    relays.removeAll()
    return code == 0 ? "" : String(code)
  }
}

/// rc's machine. Its programs are bootfs's `bin/NAME`, which rc finds as
/// `/bin/NAME` ($path is Plan 9's `(. /bin)`; the namespace has no /bin
/// yet, so only rc sees them there). A file starting `#!` runs as a
/// kernel's exec runs one: its interpreter, an argument if the line has
/// one, the file, then the rest. A child that is rc (a script's
/// interpreter, or rc run by name) is given what a manifest's `programs`
/// gives: a job under rc's and bootfs, until /bin is a directory of the
/// namespace's.
final class CroiSystem: RcSystem {
  let job: Handle
  let bootfs: Owned
  let programs: [(name: String, entry: ProgramEntry)]

  init(job: consuming Handle, bootfs: consuming Handle, programs: [(name: String, entry: ProgramEntry)]) {
    self.job = job
    self.bootfs = Owned(bootfs)
    self.programs = programs
  }

  func open(_ path: String, _ mode: RcOpen) -> RcStream? {
    let flags: Int32
    switch mode {
    case .read: flags = OpenFlags.readOnly
    case .write: flags = OpenFlags.writeOnly | OpenFlags.create | OpenFlags.truncate
    case .append: flags = OpenFlags.writeOnly | OpenFlags.create | OpenFlags.append
    }
    guard case .success(let fd) = FDIO.open(path, flags: flags) else { return nil }
    return FileStream(fd)
  }

  func pipe() -> (RcStream, RcStream) {
    guard let ends = try? Channel.create() else { return (PipeStream(Handle(raw: 0)), PipeStream(Handle(raw: 0))) }
    return (PipeStream(ends.a), PipeStream(ends.b))
  }

  /// The program at `path`: bootfs's `bin/NAME` at `/bin/NAME`.
  func program(_ path: String) -> (name: String, entry: ProgramEntry)? {
    guard path.hasPrefix("/bin/") else { return nil }
    let name = path.dropFirst(5)
    return programs.first { $0.name == name }
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

  /// Another handle to bootfs, for a child rc.
  func duplicateBootfs() -> Handle? {
    let raw = bootfs.with { h -> UInt32 in
      guard let d = try? h.duplicate() else { return 0 }
      return d.release()
    } ?? 0
    return raw == 0 ? nil : Handle(raw: raw)
  }

  func executable(_ path: String) -> Bool {
    if program(path) != nil { return true }
    guard let i = interpreter(path) else { return false }
    return program(i.path) != nil
  }

  /// A thread relaying `body`, kept to be joined.
  static func relay(_ body: @escaping @Sendable () -> Void) -> Owned? {
    guard let thread = try? Thread.spawn(body) else { return nil }
    return Owned(thread)
  }

  func start(_ path: String, _ argv: [String], fds: [Int32: RcStream], environment: [(String, [String])]) -> RcJob? {
    if let p = program(path) { return start(p, argv, fds: fds, environment: environment) }
    guard let i = interpreter(path), let p = program(i.path) else { return nil }
    let args = [i.path] + (i.argument.map { [$0] } ?? []) + [path] + argv.dropFirst()
    return start(p, args, fds: fds, environment: environment)
  }

  func start(_ program: (name: String, entry: ProgramEntry), _ argv: [String], fds: [Int32: RcStream],
             environment: [(String, [String])]) -> RcJob?
  {
    let entry = program.entry
    // Its directory too, as PWD (M6m: the file commands' paths are rc's).
    let env = environment.filter { $0.0 != "*" && $0.0 != "status" && $0.0 != "PWD" }
      .map { $0.0 + "=" + $0.1.joined(separator: " ") } + ["PWD=" + FDIO.currentDirectory]
    let startup = Startup(args: argv, environment: env)
    // rc's namespace, each mount point's root again.
    if let ns = FDIO.namespace {
      for p in ns.mountPoints {
        if let node = try? ns.connect(p) { startup.mount(node, at: p) }
      }
    }
    do throws(Status) {
      if program.name == "rc", let b = duplicateBootfs() {
        startup.add(try Sys.Job.create(parent: job), info: HandleType.info(HandleType.jobDefault))
        startup.add(b, info: HandleType.info(HandleType.vmoBootfs))
      }
      let stdio = try ChildStdio(for: startup)
      let process = try Process.create(job: job, name: argv[0])
      _ = try Process.start(process, entry: entry, startup)
      /// A relay's stream: a pipe held for as long as the relay runs (rc
      /// drops its own hold once the program is started), anything else
      /// rc's.
      final class Box: @unchecked Sendable {
        let stdio: ChildStdio
        let stream: RcStream?
        let own: Bool
        init(_ s: ChildStdio, _ r: RcStream?) {
          stdio = s
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
      // Into the child: its stdin's stream, then the end (none for rc's own).
      let input = Box(stdio, fds[0] is Standard ? nil : fds[0])
      if let r = Self.relay({
        defer { input.done() }
        if let stream = input.stream {
          while let bytes = stream.read() {
            if (try? input.stdio.write(bytes)) == nil { return }
          }
        }
        try? input.stdio.closeInput()
      }) { relays.append(r) }
      // Out of it: its stdout (and stderr) into fd 1's stream, to its end.
      let output = Box(stdio, fds[1])
      if let r = Self.relay({
        defer { output.done() }
        while let bytes = try? output.stdio.read(), !bytes.isEmpty { output.stream?.write(bytes) }
      }) { relays.append(r) }
      return Job(process: process, stdio: stdio, relays: relays)
    } catch {
      return nil
    }
  }

  func changeDirectory(_ path: String) -> Bool {
    if case .success = FDIO.changeDirectory(path) { return true }
    return false
  }

  var directory: String { FDIO.currentDirectory }

  /// A thread of rc's, joined by its job.
  final class ThreadJob: RcJob {
    let thread: Owned
    init(_ thread: Owned) { self.thread = thread }
    func wait() -> String {
      thread.with { h in try? Thread.join(h) }
      thread.close()
      return ""
    }
  }

  func spawn(_ body: @escaping @Sendable () -> Void) -> RcJob? { Self.relay(body).map { ThreadJob($0) } }

  /// rc's koid, which croi never reuses.
  var processID: UInt64 { (try? Process.current().info().koid) ?? 1 }

  // Attributes, through the fs service (M6j, `attr`): Node's stat lists
  // them; the Attributes calls (a file's and a directory's alike) change
  // them.
  func node(_ path: String) -> Handle? {
    guard let ns = FDIO.namespace, case .success(let full) = FDIO.realPath(path) else { return nil }
    return try? ns.connect(full)
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
    guard case .success(let d) = FDIO.openDirectory(directory) else { return nil }
    var names: [String] = []
    while let e = d.read() {
      if e.name != "." && e.name != ".." { names.append(e.name) }
    }
    return names
  }
}
