// SPDX-License-Identifier: BSD-3-Clause

// bin/cpu (D77): the node's cpu server (cpu(8)), in an image built with
// vx boot --cpu KEY, which puts the terminal's key at lib/cpu/terminal.
// It listens on tcp!*!17019 through factotum's noise-ik key, and runs
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

func fail(_ what: String) -> Never {
  print("cpu: \(what)")
  Process.exit(code: 1)
}

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
  static func main() {
    let start = Startup.current
    guard start.args.count == 1 else { fail("usage: cpu") }
    let ns: Namespace
    do throws(NamespaceError) { ns = try Namespace(start) } catch { fail("no namespace") }
    guard let job = start.take(HandleType.info(HandleType.jobDefault)) else {
      fail("no job to start sessions in (its manifest's `programs`)")
    }
    var keyFile: NodeIPC.NodeClient
    do throws(NamespaceError) { keyFile = try ns.open("/lib/cpu/terminal") } catch {
      fail("no terminal key at /lib/cpu/terminal: the image wasn't built with --cpu")
    }
    let text: String
    do throws(NodeIPC.NodeClient.Failure) { text = try keyFile.readText() } catch { fail("can't read the terminal key") }
    guard let terminal = unhex(String(decoding: text.utf8.prefix { $0 != 0x0A && $0 != 0x20 }, as: UTF8.self)),
          terminal.count == 32
    else { fail("/lib/cpu/terminal: not a key") }
    let imports: IPCDispatcher
    do throws(Status) {
      imports = try IPCDispatcher()
      _ = try Thread.spawn { try? imports.run() }.release()
    } catch { fail("can't start the imports' dispatcher") }
    let identity: Identity
    do throws(GateError) { identity = try Identity.factotum(ns, at: "/svc/factotum/auth") } catch {
      fail("no key from factotum")
    }
    // The sessions' parent job, held for good.
    let parent = job.release()
    let server = CpuServer(namespace: ns, identity: identity, terminal: terminal, imports: imports) { session, command in
      startRc(session, command, parent: parent, notes: ns)
    }
    fail("can't listen: \(server.listen().reason)")
  }
}
