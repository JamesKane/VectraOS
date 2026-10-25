// SPDX-License-Identifier: BSD-3-Clause

// bin/launcher, natively (V2's item 4): the program userboot starts. Its
// programs are bootfs's `bin/NAME`, its manifests bootfs's
// `etc/manifests/*.manifest`; it launches every service in a job and a
// process of its own, loaded from bootfs (Process.start), and supervises
// them for good, or, given `launcher.until=SERVICE` on the kernel's
// command line (userboot passes it as the environment), until that
// service ends, and exits with its return code: how a boot test runs
// a client to its end.

import Directives
import IPC
import Launch
import Node
import Sys

/// UTC's backstop: the earliest it may read (2026-01-01T00:00:00Z, in ns),
/// until the time service sets it (D48). Fuchsia's is its build's time;
/// ours is moved forward now and then.
let utcBackstop: Int64 = 1_767_225_600 * 1_000_000_000

/// Push and run, where bootfs has `etc/launcher/push` (a cpu image's):
/// its first line, `SERVICE PATH`, names a directory of that service's tree
/// (`fs volume/bin`), made once the service has answered. A program
/// there is started in place of bootfs's `bin/` one of its name: its
/// bytes, given as memory, made runnable here with the VMEX resource, so
/// no other service holds the right to make code.
final class Push: @unchecked Sendable {
  let service: String
  let path: String
  let vmex: UInt32
  let launcher: Launcher
  /// Each pushed build's VMO, the latest of each name, kept while
  /// processes start from it.
  let held = Locked<[(name: String, vmo: UInt32)]>([])

  @discardableResult
  init(_ text: String, vmex: UInt32, launcher: Launcher) {
    // Its first line with words, `#` comments dropped.
    let words = Directives.lines(Array(text.utf8)).map { Directives.words($0) }.first { !$0.isEmpty } ?? []
    service = words.first ?? "fs"
    path = words.count > 1 ? words[1] : "volume/bin"
    self.vmex = vmex
    self.launcher = launcher
    print("launcher: programs pushed to \(service)/\(path) run before bootfs's")
    launcher.readied = { [self] name in if NodeIPC.same(name, service) { made() } }
    launcher.pushed = { [self] name in program(name) }
  }

  /// The directory, made if it isn't there.
  func made() {
    guard var root = try? launcher.open(service), (try? root.walk(path)) == nil else { return }
    var names = NodeIPC.names(path)
    guard let last = names.popLast() else { return }
    _ = try? root.create(last, kind: .directory, in: names.joined(separator: "/"))
  }

  /// The pushed build of `name`, if there is one.
  func program(_ name: String) -> ProgramEntry? {
    guard NodeIPC.isValidName(name), var root = try? launcher.open(service),
      var file = try? root.open(path + "/" + name)
    else { return nil }
    do throws(IPCError<NodeIPC.NodeError>) {
      let memory = try file.memory(executable: false)
      let size = Int(memory.size)
      let vmex = Handle(raw: self.vmex)  // borrowed
      var made: UInt32?
      do throws(Status) { made = try VMO.executable(try memory.vmo.duplicate(), vmex: vmex).release() } catch {}
      _ = vmex.release()
      guard let image = made else { return nil }
      // Named, so its mappings say they are a pushed build's (D102).
      let named = Handle(raw: image)
      try? named.setName("push:" + name)
      _ = named.release()
      let old = held.withLock { h -> UInt32? in
        let i = h.firstIndex { NodeIPC.same($0.name, name) }
        let old = i.map { h[$0].vmo }
        if let i { h.remove(at: i) }
        h.append((name, image))
        return old
      }
      if let old { _ = Handle(raw: old) }  // closed: what started from it maps it still
      return ProgramEntry(image: image, offset: 0, length: size, name: name)
    } catch {
      return nil
    }
  }
}

/// Whether `name` starts with `prefix`, and the rest (bytes).
func dropping(_ prefix: StaticString, _ name: String) -> String? {
  let p = unsafe UnsafeBufferPointer(start: prefix.utf8Start, count: prefix.utf8CodeUnitCount)
  guard unsafe name.utf8.starts(with: p) else { return nil }
  return String(decoding: name.utf8.dropFirst(prefix.utf8CodeUnitCount), as: UTF8.self)
}

@main struct Main {
  static func main() {
    let start = Startup.current
    guard let job = start.take(HandleType.info(HandleType.jobDefault)),
      let bootfs = start.take(HandleType.info(HandleType.vmoBootfs))
    else { Process.fail("started without a job or bootfs") }

    var programs: [(name: String, entry: ProgramEntry)] = []
    var manifests: [(path: String, text: String)] = []
    var push: String?
    do throws(Status) {
      for file in try ProgramEntry.bootfs(bootfs) {
        // Read through a mapping of its pages (V1 cut vmo_read, D37).
        func text() throws(Status) -> String {
          let first = file.offset & ~4095
          let mapping = try VMO.map(bootfs, offset: first, length: file.offset + file.length - first, writable: false)
          return String(decoding: mapping.read(at: file.offset - first, count: file.length), as: UTF8.self)
        }
        if let name = dropping("bin/", file.name) {
          programs.append((name, file))
        } else if dropping("etc/manifests/", file.name) != nil, file.name.utf8.reversed().starts(with: ".manifest".utf8.reversed()) {
          manifests.append((file.name, try text()))
        } else if dropping("etc/launcher/push", file.name).map({ $0.isEmpty }) ?? false {
          push = try text()
        }
      }
    } catch {
      Process.fail("can't read bootfs: \(error.rawValue)")
    }
    guard !manifests.isEmpty else { Process.fail("no manifests in bootfs (etc/manifests)") }
    print("launcher: \(programs.count) program(s), \(manifests.count) manifest(s) in bootfs")

    // The programs' entries borrow bootfs: the launcher holds it, for
    // restarts long after (its last use here was once a duplicate, after
    // which it closed, and no bootfs program could start again).
    // Named, so a process's mappings of its programs say where they are
    // from (/proc/trace's procs, D102).
    try? bootfs.setName("bootfs")
    let grantable = try? bootfs.duplicate()
    let launcher: Launcher
    do throws(Status) {
      launcher = try Launcher(programs: programs, image: bootfs, rootJob: job)
    } catch {
      Process.fail("can't start: \(error.rawValue)")
    }
    // What manifests may grant: userboot's ranged root resources, bootfs,
    // the boot data and the debuglog.
    var vmex: UInt32?
    for kind in [ResourceKind.mmio, .irq, .ioport, .smc, .system] {
      guard let r = start.take(HandleType.info(HandleType.resource(kind))) else { continue }
      // Push and run's: VMEX alone, to make a pushed build runnable.
      if kind == .system, push != nil {
        vmex = (try? Resource.create(parent: r, kind: .system, base: SystemResource.vmex, size: 1, name: "push"))?.release()
        // `reload`'s, in the same images: hot reload (D122).
        if let reload = try? Resource.create(parent: r, kind: .system, base: SystemResource.vmex, size: 1, name: "reload") {
          launcher.allow(reload: reload)
        }
      }
      // `tracing`'s: the kernel's trace and samples alone (D102).
      if kind == .system,
        let tracing = try? Resource.create(parent: r, kind: .system, base: SystemResource.tracing, size: 1, name: "tracing")
      {
        launcher.allow(tracing: tracing)
      }
      // `info`'s: the CPUs' counts alone (D114).
      if kind == .system,
        let info = try? Resource.create(parent: r, kind: .system, base: SystemResource.info, size: 1, name: "info")
      {
        launcher.allow(info: info)
      }
      launcher.allow(resource: kind, r)
    }
    if let push, let vmex { Push(push, vmex: vmex, launcher: launcher) }
    if let copy = grantable { launcher.allow(bootfs: copy) }
    if let data = start.take(HandleType.info(HandleType.vmoBootData)) { launcher.allow(bootData: data) }
    if let ring = start.take(HandleType.info(HandleType.vmoDebuglog)),
      let counter = start.take(HandleType.info(HandleType.debuglogCounter))
    {
      launcher.allow(debuglog: ring, counter: counter)
    }
    // The UTC page (D48): every process reads it, the time service (`clock`)
    // writes it; until then it reads the backstop.
    launcher.log = { line in print("launcher: \(line)") }
    do throws(Status) {
      launcher.allow(utcPage: try UTCPage.create(backstop: utcBackstop))
    } catch {
      print("launcher: no UTC page: \(error.rawValue)")
    }
    do throws(LaunchError) {
      try launcher.start(manifests)
    } catch {
      Process.fail(error.description)
    }
    print("launcher: started")
    for line in Directives.lines(launcher.status) { print("launcher:   \(line)") }

    guard let until = BootOptions.value("launcher.until") else {
      // Supervises for good.
      while true { sleep(until: Int64.max) }
    }
    let code: Int64
    do throws(LaunchError) {
      code = try launcher.waitForExit(until)
    } catch {
      Process.fail(error.description)
    }
    print("launcher: \(until) exited with \(code)")
    for line in Directives.lines(launcher.status) { print("launcher:   \(line)") }
    print("launcher: shutting down")
    launcher.stop()
    Process.exit(code: code)
  }
}
