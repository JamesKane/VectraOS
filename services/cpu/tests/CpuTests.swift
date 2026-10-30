// SPDX-License-Identifier: BSD-3-Clause

// cpu's two ends against each other (D77): vx cpu's terminal (tools/cpu)
// calls the node's server over a channel, sealed by Noise IK; the
// session's program, standing in for rc, reads and writes /dev/cons (the
// terminal's console), reads and writes the dev machine's files under
// /mnt/term/root, and takes the terminal's ^C as a note. A terminal
// with the wrong key gets no session; a call from off the link is told
// from one on it; the command record is checked.

import CpuProtocol
import CpuServer
import CpuTerminal
import Foundation
import Gate
import IPC
import Node
import Noise
import Sys
import Testing

/// A channel's end as the terminal's link.
func link(_ s: ByteStream) -> Link {
  Link(read: { max in (try? s.read(max)) ?? [] },
       write: { (b: [UInt8]) throws(TerminalError) in
         do throws(GateError) { try s.write(b) } catch { throw TerminalError("closed") }
       },
       close: { s.close() })
}

/// A queue one side fills and the other waits on; nil once closed.
final class Queue<T: Sendable>: @unchecked Sendable {
  let condition = NSCondition()
  var items: [T] = []
  var closed = false

  func put(_ t: T) {
    condition.withLock {
      items.append(t)
      condition.signal()
    }
  }

  func close() {
    condition.withLock {
      closed = true
      condition.broadcast()
    }
  }

  func take() -> T? {
    condition.withLock {
      while items.isEmpty && !closed { condition.wait() }
      return items.isEmpty ? nil : items.removeFirst()
    }
  }
}

/// A node's cpu server and a terminal, joined by a channel. The
/// session's program is `program`, run on a thread with the session's
/// namespace and command.
final class Session: @unchecked Sendable {
  let serverKey = StaticKey(privateKey: Array(repeating: 3, count: 32))
  let terminalKey = StaticKey(privateKey: Array(repeating: 4, count: 32))
  let imports: IPCDispatcher
  let typed = Queue<String>()
  let notes = Queue<String>()
  let shown = Locked<[UInt8]>([])
  let posted = Locked<[String]>([])
  let log = Locked<[String]>([])
  let root: String
  var server: CpuServer!

  init(pinned: [UInt8]? = nil, program: @escaping @Sendable (Namespace, String) -> String) throws {
    imports = try IPCDispatcher()
    let d = imports
    _ = try Thread.spawn { try? d.run() }.release()
    root = NSTemporaryDirectory() + "cpu-test-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    try Data("from the dev machine\n".utf8).write(to: URL(fileURLWithPath: root + "/motd"))
    let n = Locked<UInt8>(0)
    let identity = Identity.local(serverKey) {
      Array(repeating: n.withLock { (n: inout UInt8) -> UInt8 in
        n &+= 1
        return n
      }, count: 32)
    }
    let posted = self.posted, log = self.log
    server = CpuServer(namespace: Namespace(), identity: identity, terminals: [pinned ?? terminalKey.publicKey],
                       imports: imports, log: { line in log.withLock { $0.append(line) } }) { ns, command in
      let done = Locked<String?>(nil)
      let ended = NSCondition()
      Thread.detachNewThread {
        let status = program(ns, command)
        ended.withLock {
          done.withLock { $0 = status }
          ended.broadcast()
        }
      }
      return CpuProgram(
        wait: {
          ended.withLock {
            while done.withLock({ $0 }) == nil { ended.wait() }
            return done.withLock { $0 } ?? ""
          }
        },
        note: { note in posted.withLock { $0.append(note) } })
    }
  }

  var console: Console {
    let typed = self.typed, notes = self.notes, shown = self.shown
    return Console(read: { max in Array((typed.take() ?? "").utf8.prefix(max)) },
                   write: { b in shown.withLock { $0 += b } },
                   note: { notes.take() })
  }

  /// Runs a session to its end: what the terminal saw, or why it failed.
  func run(_ command: String, key: StaticKey? = nil) throws -> String {
    let ends = try Channel.create()
    let node = ByteStream.channel(ends.b), terminal = ByteStream.channel(ends.a)
    let s = server!
    _ = try Thread.spawn { s.session(node, from: "test") }.release()
    var m: UInt8 = 100
    try CpuTerminal.run(link(terminal), key: key ?? terminalKey, node: serverKey.publicKey, command: command,
                        tree: TerminalTree(root: root, console: console)) {
      m &+= 1
      return Array(repeating: m, count: 32)
    }
    notes.close()
    return String(decoding: shown.withLock { $0 }, as: UTF8.self)
  }

  deinit {
    imports.stop()
    try? FileManager.default.removeItem(atPath: root)
  }
}

/// A file's text in `ns`, or why not.
func text(_ ns: Namespace, _ path: String) -> String {
  guard var f = try? ns.open(path) else { return "no \(path)" }
  return (try? f.readText()) ?? "can't read \(path)"
}

func say(_ ns: Namespace, _ text: String) {
  guard var cons = try? ns.open("/dev/cons") else { return }
  _ = try? cons.write(offset: 0, Array(text.utf8))
}

func line(_ ns: Namespace) -> String? {
  guard var cons = try? ns.open("/dev/cons"), let b = try? cons.read(offset: 0, max: 1024), !b.isEmpty else {
    return nil
  }
  return String(decoding: b, as: UTF8.self)
}

@Test func aSessionRunsWithTheTerminalsConsoleAndFiles() throws {
  let s = try Session { ns, command in
    say(ns, "command: \(command)\n")
    // What the terminal types, a line a read; ^D is an empty read.
    while let l = line(ns) { say(ns, "you said: \(l)") }
    say(ns, text(ns, "/mnt/term/root/motd"))
    // A file made on the dev machine, and listed.
    if var out = try? ns.create("/mnt/term/root/out", kind: .file) { _ = try? out.write(offset: 0, Array("made".utf8)) }
    let names = (try? ns.list("/mnt/term/root").map { $0.name }.sorted()) ?? []
    say(ns, names.joined(separator: " ") + "\n")
    say(ns, ((try? ns.list("/mnt/term/dev").map { $0.name }.sorted()) ?? []).joined(separator: " ") + "\n")
    return "done"
  }
  s.typed.put("echo hi\n")
  s.typed.put("ls\n")
  s.typed.put("")
  let seen = try s.run("date")
  #expect(seen == """
    command: date
    you said: echo hi
    you said: ls
    from the dev machine
    motd out
    cons cpunote

    """)
  #expect(try String(contentsOfFile: s.root + "/out", encoding: .utf8) == "made")
  #expect(s.log.withLock { $0 } == ["session from test", "session from test ended: done"])
}

@Test func theTerminalsInterruptIsANote() throws {
  let s = try Session { ns, _ in
    say(ns, "waiting\n")
    _ = line(ns)  // until the test has sent the note
    return ""
  }
  let notes = s.notes, typed = s.typed, posted = s.posted
  _ = try Thread.spawn {
    notes.put("interrupt")
    // The note's way is its own thread's: wait for it to arrive.
    while posted.withLock({ $0.isEmpty }) { sleep(until: Clock.monotonic() + 1_000_000) }
    typed.put("")
  }.release()
  #expect(try s.run("") == "waiting\n")
  // Then `hangup`, once the terminal has gone, if it came before this.
  let got = posted.withLock { $0 }
  #expect(got.first == "interrupt" && got.dropFirst().allSatisfy { $0 == "hangup" } && got.count <= 2)
}

@Test func anotherTerminalGetsNoSession() throws {
  let s = try Session { ns, _ in
    say(ns, "should not run\n")
    return ""
  }
  let stranger = StaticKey(privateKey: Array(repeating: 5, count: 32))
  #expect(throws: TerminalError.self) { _ = try s.run("", key: stranger) }
  #expect(s.shown.withLock { $0 }.isEmpty)
  #expect(s.log.withLock { $0 } == ["refused test: caller refused"])
}

@Test func onlyCallsFromTheLinkAreTaken() {
  let routes = """
    0.0.0.0         /96  10.0.2.2        4    none   0 0.0.0.0         /96
    10.0.2.0        /120 10.0.2.0        4i   none   0 0.0.0.0         /96
    10.0.2.15       /128 10.0.2.15       4u   none   0 0.0.0.0         /96
    fe80::          /64  fe80::          6i   none   0 ::              /0

    """
  #expect(CpuServer.onLink("10.0.2.2!40000\n", routes: routes))
  #expect(CpuServer.onLink("10.0.2.200!1", routes: routes))
  #expect(!CpuServer.onLink("10.0.3.2!40000", routes: routes))
  #expect(!CpuServer.onLink("192.168.1.10!22", routes: routes))
  #expect(CpuServer.onLink("fe80::1!5000", routes: routes))
  #expect(!CpuServer.onLink("2001:db8::1!5000", routes: routes))
  #expect(!CpuServer.onLink("", routes: routes))
  #expect(!CpuServer.onLink("10.0.2.2!1", routes: ""))
}

@Test func theCommandRecord() {
  let r = CpuProtocol.record(Array("ls /".utf8))
  #expect(r == [4, 0, 0, 0] + Array("ls /".utf8))
  #expect(CpuProtocol.command(Array(r!.prefix(5))) == .partial)
  #expect(CpuProtocol.command(r! + [9, 9]) == .whole(Array("ls /".utf8), used: 8))
  #expect(CpuProtocol.command([0, 0, 0, 0]) == .whole([], used: 4))
  #expect(CpuProtocol.command([0xff, 0xff, 0, 0]) == .invalid)
  #expect(CpuProtocol.record([UInt8](repeating: 0x61, count: CpuProtocol.maxCommand + 1)) == nil)
}

@Test func theTestsTerminalKeyIsWhole() throws {
  // boot-cpu's terminal: its key, and the public half the test image pins.
  let dir = String(#filePath.utf8.prefix(upTo: #filePath.utf8.lastIndex(of: 0x2F)!))!
  let key = try TerminalKey.load(dir + "/terminal.key")
  #expect(try String(contentsOfFile: dir + "/terminal.pub", encoding: .utf8) == Gate.hex(key.publicKey) + "\n")
}

/// A listener on the dev machine's 127.0.0.1, which answers one call:
/// `pong:` and what it was sent, then the end. Its port.
func answeringListener() throws -> UInt16 {
  let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
  var address = sockaddr_in()
  address.sin_family = sa_family_t(AF_INET)
  address.sin_addr.s_addr = inet_addr("127.0.0.1")
  var size = socklen_t(MemoryLayout<sockaddr_in>.size)
  let bound = withUnsafeMutablePointer(to: &address) { p in
    p.withMemoryRebound(to: sockaddr.self, capacity: 1) { a in
      bind(fd, a, size) == 0 && listen(fd, 1) == 0 && getsockname(fd, a, &size) == 0
    }
  }
  #expect(bound)
  Thread.detachNewThread {
    let call = accept(fd, nil, nil)
    Glibc.close(fd)
    var buffer = [UInt8](repeating: 0, count: 64)
    let got = buffer.withUnsafeMutableBytes { recv(call, $0.baseAddress, 64, 0) }
    let reply = Array("pong:".utf8) + buffer.prefix(max(got, 0))
    _ = reply.withUnsafeBytes { send(call, $0.baseAddress, reply.count, 0) }
    Glibc.close(call)
  }
  return UInt16(bigEndian: address.sin_port)
}

/// A session that binds the terminal's net/ at its /net dials out
/// through the dev machine (D104): names from the terminal's cs
/// (localhost, whose ::1 refuses and whose 127.0.0.1 answers), the
/// conversation's bytes both ways, its files, and its end with its last
/// file; announcing is refused.
@Test func aSessionDialsOutThroughTheTerminalsNet() throws {
  let port = try answeringListener()
  let s = try Session { ns, _ in
    do throws(NamespaceError) { try ns.bind("/mnt/term/net", at: "/net") } catch { return "bind: \(error.text)" }
    do throws(DialError) {
      var c = try ns.dial("tcp!localhost!\(port)")
      say(ns, "remote " + text(ns, c.dir + "/remote"))
      _ = try? c.data.write(offset: 0, Array("ping".utf8))
      var got: [UInt8] = []
      while let b = try? c.data.read(offset: 0, max: 1024), !b.isEmpty { got += b }
      say(ns, String(decoding: got, as: UTF8.self) + "\n")
      say(ns, ((try? ns.list("/net/tcp").map { $0.name }.sorted()) ?? []).joined(separator: " ") + "\n")
      _ = consume c
    } catch {
      return "dial: \(error.reason)"
    }
    say(ns, ((try? ns.list("/net/tcp").map { $0.name }.sorted()) ?? []).joined(separator: " ") + "\n")
    do throws(DialError) {
      _ = try ns.announce("tcp!*!0")
      return "announced"
    } catch {
      say(ns, "announce refused\n")
    }
    return "done"
  }
  s.typed.put("")
  let seen = try s.run("")
  #expect(seen == """
    remote 127.0.0.1!\(port)
    pong:ping
    0 clone
    clone
    announce refused

    """)
  #expect(s.log.withLock { $0 }.last == "session from test ended: done")
}

@Test func aNodesTerminalRunsASessionOnAnother() throws {
  // The node calling: its key one the server's image lists, its own
  // files served as /mnt/term, its /dev/cons a window's.
  let callerKey = StaticKey(privateKey: Array(repeating: 9, count: 32))
  let go = Locked(false)
  let s = try Session(pinned: callerKey.publicKey) { ns, command in
    say(ns, "command: \(command)\n")
    say(ns, text(ns, "/mnt/term/motd"))
    say(ns, ((try? ns.list("/mnt/term/dev").map { $0.name }.sorted()) ?? []).joined(separator: " ") + "\n")
    // Until the test has seen the caller's interrupt arrive as a note.
    let deadline = Clock.monotonic() + 10_000_000_000
    while !go.withLock({ $0 }), Clock.monotonic() < deadline { sleep(until: Clock.monotonic() + 1_000_000) }
    return "done"
  }
  let d = try IPCDispatcher()
  _ = try Thread.spawn { try? d.run() }.release()
  defer { d.stop() }
  let shown = Locked<[UInt8]>([])
  // Its files, and its /dev mounted as a node's is (cpunote goes after).
  let tree = NodeTree(dispatcher: d)
  tree.file("motd", Array("from node a\n".utf8))
  let dev = NodeTree(dispatcher: d)
  dev.stream("cons", NodeStream(take: { _ in [] }, write: { bytes in
    shown.withLock { $0 += bytes }
    return UInt32(bytes.count)
  }))
  let ns = Namespace()
  let ends = try Channel.create(), devEnds = try Channel.create()
  try tree.serve(ends.b)
  try dev.serve(devEnds.b)
  try ns.mount(ends.a, at: "/")
  try ns.mount(devEnds.a, at: "/dev")

  let link = try Channel.create()
  let nodeSide = ByteStream.channel(link.b), callerSide = ByteStream.channel(link.a)
  let server = s.server!
  _ = try Thread.spawn { server.session(nodeSide, from: "node a") }.release()
  let notes = CpuNotes(dispatcher: d)
  notes.post("interrupt")
  let posted = s.posted
  _ = try Thread.spawn {
    while !posted.withLock({ $0.contains("interrupt") }) { sleep(until: Clock.monotonic() + 1_000_000) }
    go.withLock { $0 = true }
  }.release()
  let m = Locked<UInt8>(50)
  let identity = Identity.local(callerKey) {
    Array(repeating: m.withLock { (m: inout UInt8) -> UInt8 in
      m &+= 1
      return m
    }, count: 32)
  }
  let why = CpuClient.session(callerSide, ns, identity: identity, key: s.serverKey.publicKey,
                              command: "date", notes: notes)
  #expect(why == nil)
  #expect(String(decoding: shown.withLock { $0 }, as: UTF8.self) == """
    command: date
    from node a
    cons cpunote

    """)
  #expect(go.withLock { $0 })
  #expect(s.log.withLock { $0 } == ["session from node a", "session from node a ended: done"])
}
