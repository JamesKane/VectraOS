// SPDX-License-Identifier: BSD-3-Clause

// bin/cpu (D75, D77): Plan 9's cpu, both ends. `cpu -h NODE -k KEY [-c
// CMD]` is the terminal (cpu(1)): rc on that node, with this namespace at
// its /mnt/term (CpuClient). `cpu -R` is the node's server (cpu(8)), run
// by its manifest in an image built with vx boot --cpu KEY, which puts
// the keys it answers at lib/cpu/terminal, one a line: the dev
// machine's, and other nodes'.
// The server listens on tcp!*!17019 through factotum's noise-ik key, and runs
// each session's rc in a job of its own (its note group), under its
// manifest's `programs` job, with the session's namespace: its own, the
// terminal's tree at /mnt/term and its dev/cons over /dev/cons. rc, with
// no descriptors, takes /dev/cons as its terminal. A note from the
// terminal goes to /proc/N/notepg; when rc ends, the rest of its job is
// killed and the session hangs up.

import CpuServer
import Gate
import IPC
import Node
import Sys

/// A session's rc: its process and job, held until both are done with.
final class Running: @unchecked Sendable {
  let process: UInt32
  let job: UInt32
  let pid: UInt64
  let status: ExitString

  init(process: consuming Handle, job: consuming Handle, pid: UInt64, status: consuming ExitString) {
    self.process = process.release()
    self.job = job.release()
    self.pid = pid
    self.status = status
  }

  /// Waits for rc to end, kills what it left running, and says how it ended.
  func wait() -> String {
    let p = Handle(raw: process)
    _ = try? p.wait(for: Signals.terminated)
    _ = p.release()
    let j = Handle(raw: job)
    try? kill(j)
    _ = j.release()
    return status.read()
  }

  deinit { Sys.close(raw: [process, job]) }
}

/// Starts rc in `ns`, with `command` for -c, in a new job under the job
/// `parent` (a raw handle, the process's for good).
func startRc(_ ns: Namespace, _ command: String, parent: UInt32, notes: Namespace) -> CpuProgram? {
  do throws(Status) {
    guard let rc = try? ns.memory("/bin/rc", executable: true) else { return nil }
    var entry = ProgramEntry(image: rc.vmo.raw, offset: 0, length: Int(rc.size), name: "rc")
    entry.libraries = ns.libraries
    let p = Handle(raw: parent)
    let made = Result { () throws(Status) in try Job.create(parent: p) }
    _ = p.release()
    let job = try made.get()
    let startup = Startup(args: command.isEmpty ? ["rc", "-i"] : ["rc", "-c", command])
    do throws(NamespaceError) { try startup.mount(ns) } catch { return nil }
    // Its programs start in its own job: interrupts reach all of them.
    startup.add(try job.duplicate(), info: HandleType.info(HandleType.jobDefault))
    let status = try ExitString(for: startup)
    let process = try Process.create(job: job, name: "rc")
    let pid = try process.info().koid
    _ = try Process.start(process, entry: entry, startup)
    _ = consume rc
    let running = Running(process: process, job: job, pid: pid, status: status)
    return CpuProgram(
      wait: { running.wait() },
      note: { note in
        if var group = try? notes.open("/proc/\(running.pid)/notepg") { try? group.writeText(note) }
      })
  } catch {
    return nil
  }
}

@main struct CpuMain {
  static let usage = "usage: cpu -h node -k key [-c command ...] | cpu -R"

  static func main() {
    let start = Startup.current
    let args = Array(start.args.dropFirst())
    if args.count == 1, NodeIPC.same(args[0], "-R") { serve(start) }
    terminal(start, args)
  }

  /// The terminal: rc on the node `-h` names, whose key `-k` gives, its
  /// text this namespace's /dev/cons; `-c` runs the rest of the line.
  static func terminal(_ start: Startup, _ args: [String]) {
    var host: String?, key: [UInt8]?, command = ""
    var i = 0
    while i < args.count {
      if NodeIPC.same(args[i], "-c") {
        command = args[(i + 1)...].joined(separator: " ")
        break
      }
      guard i + 1 < args.count else { Process.fail(usage) }
      if NodeIPC.same(args[i], "-h") {
        host = args[i + 1]
      } else if NodeIPC.same(args[i], "-k") {
        guard let k = unhex(args[i + 1]), k.count == 32 else { Process.fail("cpu: -k: not a key") }
        key = k
      } else {
        Process.fail(usage)
      }
      i += 2
    }
    guard let host, let key else { Process.fail(usage) }
    let ns: Namespace
    do throws(NamespaceError) { ns = try Namespace(start) } catch { Process.fail("cpu: no namespace") }
    let identity: Identity
    do throws(GateError) { identity = try Identity.factotum(ns, at: "/svc/factotum/auth") } catch {
      Process.fail("cpu: no key from factotum")
    }
    let dispatcher: IPCDispatcher
    do throws(Status) {
      dispatcher = try IPCDispatcher()
      _ = try Thread.spawn { try? dispatcher.run() }.release()
    } catch { Process.fail("cpu: can't start the notes' dispatcher") }
    let notes = CpuNotes(dispatcher: dispatcher)
    // The window's interrupt goes to the other node's rc; any other note
    // ends the session here.
    do throws(Status) {
      try Note.notify { note in
        guard NodeIPC.same(note, "interrupt") else { return false }
        notes.post(note)
        return true
      }
    } catch { Process.fail("cpu: can't take notes") }
    if let why = CpuClient.run(ns, identity: identity, host: host, key: key, command: command, notes: notes) {
      Process.fail("cpu: \(host): \(why)")
    }
  }

  /// The server: the sessions of the terminals /lib/cpu/terminal lists.
  static func serve(_ start: Startup) -> Never {
    let ns: Namespace
    do throws(NamespaceError) { ns = try Namespace(start) } catch { Process.fail("no namespace") }
    guard let job = start.take(HandleType.info(HandleType.jobDefault)) else {
      Process.fail("no job to start sessions in (its manifest's `programs`)")
    }
    var keyFile: NodeIPC.NodeClient
    do throws(NamespaceError) { keyFile = try ns.open("/lib/cpu/terminal") } catch {
      Process.fail("no terminal key at /lib/cpu/terminal: the image wasn't built with --cpu")
    }
    let text: String
    do throws(NodeIPC.NodeClient.Failure) { text = try keyFile.readText() } catch { Process.fail("can't read the terminal keys") }
    var terminals: [[UInt8]] = []
    for line in text.utf8.split(separator: 0x0A) {
      let word = line.prefix { $0 != 0x20 && $0 != 0x09 }
      guard !word.isEmpty else { continue }
      guard let k = unhex(String(decoding: word, as: UTF8.self)), k.count == 32 else {
        Process.fail("/lib/cpu/terminal: not a key")
      }
      terminals.append(k)
    }
    guard !terminals.isEmpty else { Process.fail("/lib/cpu/terminal: no key") }
    let imports: IPCDispatcher
    do throws(Status) {
      imports = try IPCDispatcher()
      _ = try Thread.spawn { try? imports.run() }.release()
    } catch { Process.fail("can't start the imports' dispatcher") }
    let identity: Identity
    do throws(GateError) { identity = try Identity.factotum(ns, at: "/svc/factotum/auth") } catch {
      Process.fail("no key from factotum")
    }
    // The sessions' parent job, held for good.
    let parent = job.release()
    let server = CpuServer(namespace: ns, identity: identity, terminals: terminals, imports: imports) { session, command in
      startRc(session, command, parent: parent, notes: ns)
    }
    Process.fail("can't listen: \(server.listen().reason)")
  }
}
