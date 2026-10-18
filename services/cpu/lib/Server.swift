// SPDX-License-Identifier: BSD-3-Clause

// The node's cpu server (D77): Plan 9's cpu, for one pinned terminal.
// It announces tcp!*!17019 through its namespace's /net, takes calls
// only from on the link, and answers only the terminal whose key the
// image pins, through factotum's noise-ik (gate(2)'s Identity, prologue
// `cpu`). Each session then reads the terminal's command (CpuProtocol),
// imports the terminal's tree over the same connection (gate(2)'s
// Import) and runs a program, rc, in a namespace of its own: the
// server's, with the terminal's tree at /mnt/term, its dev/cons over
// /dev/cons and a new /env. The terminal's notes, read from
// /mnt/term/dev/cpunote, are posted to the program's note group; when it
// ends, the server hangs up.

import CpuProtocol
import Gate
import IPC
import Net
import NineP
import Node
import Sys

/// A session's program, started: `wait` returns its exit string once it
/// has ended, and `note` posts a note to its note group.
public struct CpuProgram: Sendable {
  public let wait: @Sendable () -> String
  public let note: @Sendable (String) -> Void

  public init(wait: @escaping @Sendable () -> String, note: @escaping @Sendable (String) -> Void) {
    self.wait = wait
    self.note = note
  }
}

public final class CpuServer: @unchecked Sendable {
  public static let address = "tcp!*!\(CpuProtocol.port)"

  let namespace: Namespace
  let identity: Identity
  let terminal: [UInt8]
  let imports: IPCDispatcher
  let start: @Sendable (Namespace, String) -> CpuProgram?
  let log: @Sendable (String) -> Void

  /// Serves the terminal whose public key is `terminal`; `namespace` is
  /// what sessions start from (and its /net what the server listens on),
  /// `imports` serves the terminals' trees, and `start` runs a session's
  /// program in its namespace with its command.
  public init(namespace: Namespace, identity: Identity, terminal: [UInt8], imports: IPCDispatcher,
              log: @escaping @Sendable (String) -> Void = { print("cpu: \($0)") },
              start: @escaping @Sendable (Namespace, String) -> CpuProgram?) {
    self.namespace = namespace
    self.identity = identity
    self.terminal = terminal
    self.imports = imports
    self.log = log
    self.start = start
  }

  /// Announces `address` and serves its calls, each on a thread of its
  /// own, until the announcement fails.
  public func listen(_ address: String = CpuServer.address) -> DialError {
    let a: NetAnnouncement
    do throws(DialError) { a = try namespace.announce(address) } catch { return error }
    log("listening on \(address), key \(hex(identity.publicKey))")
    while true {
      let call: NetCall
      do throws(DialError) { call = try namespace.listen(a) } catch { return error }
      let dir = call.dir
      let remote = text(dir + "/remote"), routes = text("/net/iproute")
      guard Self.onLink(remote, routes: routes) else {
        log("refused \(Self.trimmed(remote)): not on the link")
        namespace.reject(call)
        continue
      }
      let c: NetConnection
      do throws(DialError) { c = try namespace.accept(call) } catch { continue }
      guard let stream = GateService.stream(namespace, c) else { continue }
      do throws(Status) {
        _ = try Thread.spawn { [self] in session(stream, from: Self.trimmed(remote)) }.release()
      } catch { stream.close() }
    }
  }

  /// A file's text, or nothing.
  func text(_ path: String) -> String {
    guard var f = try? namespace.open(path), let t = try? f.readText() else { return "" }
    return t
  }

  /// One session on `raw`, a call from `caller`, to its end.
  public func session(_ raw: ByteStream, from caller: String = "") {
    let sealed: ByteStream
    do throws(GateError) {
      sealed = try identity.respond(raw, CpuProtocol.prologue) { [terminal] key in key == terminal }.0
    } catch {
      return log("refused \(caller): \(GateService.text(error))")
    }
    defer { sealed.close() }
    let command: [UInt8], stream: ByteStream
    do throws(GateError) { (command, stream) = try Self.command(sealed) } catch {
      return log("\(caller): no command: \(GateService.text(error))")
    }
    let ns: Namespace
    do throws(GateError) {
      let root = try Import(try NinePClient(stream), dispatcher: imports).attach()
      ns = try Self.namespace(namespace, terminal: root)
    } catch {
      return log("\(caller): no terminal tree: \(GateService.text(error))")
    }
    let text = String(decoding: command, as: UTF8.self)
    guard let program = start(ns, text) else { return log("\(caller): can't start the session's program") }
    log("session from \(caller)")
    Self.forwardNotes(ns, program)
    let status = program.wait()
    log("session from \(caller) ended" + (status.isEmpty ? "" : ": " + status))
  }

  /// The command record at the start of `sealed`, and the stream after it.
  static func command(_ sealed: ByteStream) throws(GateError) -> ([UInt8], ByteStream) {
    var bytes: [UInt8] = []
    while true {
      switch CpuProtocol.command(bytes) {
      case .invalid: throw .protocolError("bad command record")
      case .whole(let command, let used):
        return (command, Self.prefixed(Array(bytes[used...]), sealed))
      case .partial:
        let more = try sealed.read(4096)
        guard !more.isEmpty else { throw .closed }
        bytes += more
      }
    }
  }

  /// `stream`, with `first` read before it.
  static func prefixed(_ first: [UInt8], _ stream: ByteStream) -> ByteStream {
    guard !first.isEmpty else { return stream }
    let left = Locked(first)
    return ByteStream(
      read: { (max: Int) throws(GateError) -> [UInt8] in
        let had = left.withLock { (b: inout [UInt8]) -> [UInt8] in
          let n = min(max, b.count)
          defer { b.removeFirst(n) }
          return Array(b.prefix(n))
        }
        return had.isEmpty ? try stream.read(max) : had
      },
      write: stream.write, close: stream.close)
  }

  /// A session's namespace: `base`'s, with the terminal's tree at
  /// /mnt/term, its dev/cons over /dev/cons, and an environment group of
  /// its own at /env, if `base` has /svc/env's.
  static func namespace(_ base: Namespace, terminal root: consuming Handle) throws(GateError) -> Namespace {
    do throws(NamespaceError) {
      let ns = try base.clone()
      try ns.mount(root, at: "/mnt/term")
      try ns.bind("/mnt/term/dev/cons", at: "/dev/cons")
      if let group = try? ns.connect("/svc/env/new") { try ns.mount(group, at: "/env") }
      return ns
    } catch {
      throw .protocolError("namespace: \(error.text)")
    }
  }

  /// Posts each note the terminal sends to `program`'s group, from a
  /// thread that ends with the connection, posting `hangup`, as Plan 9
  /// does when a terminal goes (once rc has ended, to no one).
  static func forwardNotes(_ ns: Namespace, _ program: CpuProgram) {
    guard let f = try? ns.open("/mnt/term/dev/cpunote") else { return }
    let file = NoteFile(f.takeChannel())
    do throws(Status) {
      _ = try Thread.spawn {
        while let note = file.read(), !note.isEmpty { program.note(note) }
        program.note("hangup")
      }.release()
    } catch {}
  }

  /// Whether `remote` (`address!port`) is on one of the links `routes`
  /// (/net/iproute's text) reaches without a router: a route whose type
  /// has `i`.
  public static func onLink(_ remote: String, routes: String) -> Bool {
    let host = Array(remote.utf8.prefix { $0 != 0x21 && $0 != 0x0A })
    guard let address = ip(host) else { return false }
    for line in routes.utf8.split(separator: 0x0A) {
      let w = line.split(whereSeparator: { $0 == 0x20 || $0 == 0x09 })
      guard w.count >= 4, w[3].contains(0x69), let target = ip(Array(w[0])), w[1].first == 0x2F,
            let length = Int(String(decoding: w[1].dropFirst(), as: UTF8.self)), length <= 128
      else { continue }
      if prefix(address, length) == prefix(target, length) { return true }
    }
    return false
  }

  static func ip(_ bytes: [UInt8]) -> IPv6Address? {
    let text = String(decoding: bytes, as: UTF8.self)
    if let v4 = IPv4Address(text) { return IPv6Address(mapping: v4) }
    return IPv6Address(text)
  }

  static func prefix(_ a: IPv6Address, _ length: Int) -> (UInt64, UInt64) {
    func mask(_ bits: Int) -> UInt64 { bits <= 0 ? 0 : bits >= 64 ? .max : ~(UInt64.max >> UInt64(bits)) }
    return (a.hi & mask(length), a.lo & mask(length - 64))
  }

  static func trimmed(_ s: String) -> String {
    String(decoding: s.utf8.prefix { $0 != 0x0A }, as: UTF8.self)
  }
}

/// dev/cpunote, read from the notes' thread.
final class NoteFile: @unchecked Sendable {
  var client: NodeIPC.NodeClient
  let lock = Lock()

  init(_ channel: consuming Handle) { client = NodeIPC.NodeClient(channel: channel) }

  /// The next read's text; nil once the file fails (the connection gone).
  func read() -> String? {
    lock.withLock { () -> String? in
      guard let bytes = try? client.read(offset: 0, max: 256) else { return nil }
      return String(decoding: bytes, as: UTF8.self)
    }
  }
}
