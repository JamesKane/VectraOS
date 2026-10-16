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

final class CroiSystem: RcSystem {
  let job: Handle
  let programs: [(name: String, entry: ProgramEntry)]

  init(job: consuming Handle, programs: [(name: String, entry: ProgramEntry)]) {
    self.job = job
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

  func exists(_ name: String) -> Bool { programs.contains { $0.name == name } }

  /// A thread relaying `body`, kept to be joined.
  static func relay(_ body: @escaping @Sendable () -> Void) -> Owned? {
    guard let thread = try? Thread.spawn(body) else { return nil }
    return Owned(thread)
  }

  func start(_ argv: [String], fds: [Int32: RcStream], environment: [(String, [String])]) -> RcJob? {
    guard let entry = programs.first(where: { $0.name == argv[0] })?.entry else { return nil }
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
