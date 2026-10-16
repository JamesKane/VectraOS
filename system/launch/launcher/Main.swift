// SPDX-License-Identifier: BSD-3-Clause

// bin/launcher, natively (V2's item 4): the program userboot starts. Its
// programs are bootfs's `bin/NAME`, its manifests bootfs's
// `etc/manifests/*.manifest`; it launches every service in a job and a
// process of its own, loaded from bootfs (Process.start), and supervises
// them for good, or, given `launcher.until=SERVICE` on the kernel's
// command line (userboot passes it as the environment), until that
// service ends, and exits with its return code: how a boot test runs
// a client to its end.

import Launch
import Node
import Sys

func fail(_ what: String) -> Never {
  print("launcher: \(what)")
  Process.exit(code: 1)
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
    else { fail("started without a job or bootfs") }

    var programs: [(name: String, entry: ProgramEntry)] = []
    var manifests: [(path: String, text: String)] = []
    do throws(Status) {
      for file in try ProgramEntry.bootfs(bootfs) {
        if let name = dropping("bin/", file.name) {
          programs.append((name, file))
        } else if dropping("etc/manifests/", file.name) != nil, file.name.utf8.reversed().starts(with: ".manifest".utf8.reversed()) {
          // Read through a mapping of its pages (V1 cut vmo_read, D37).
          let first = file.offset & ~4095
          let mapping = try VMO.map(bootfs, offset: first, length: file.offset + file.length - first, writable: false)
          manifests.append((file.name, String(decoding: mapping.read(at: file.offset - first, count: file.length),
                                              as: UTF8.self)))
        }
      }
    } catch {
      fail("can't read bootfs: \(error.rawValue)")
    }
    guard !manifests.isEmpty else { fail("no manifests in bootfs (etc/manifests)") }
    print("launcher: \(programs.count) program(s), \(manifests.count) manifest(s) in bootfs")

    let launcher: Launcher
    do throws(Status) {
      launcher = try Launcher(programs: programs, rootJob: job)
    } catch {
      fail("can't start: \(error.rawValue)")
    }
    // What manifests may grant: userboot's ranged root resources, bootfs
    // and the boot data.
    for kind in [ResourceKind.mmio, .irq, .ioport, .smc, .system] {
      if let r = start.take(HandleType.info(HandleType.resource(kind))) { launcher.allow(resource: kind, r) }
    }
    if let copy = try? bootfs.duplicate() { launcher.allow(bootfs: copy) }
    if let data = start.take(HandleType.info(HandleType.vmoBootData)) { launcher.allow(bootData: data) }
    do throws(LaunchError) {
      try launcher.start(manifests)
    } catch {
      fail(error.description)
    }
    print("launcher: started")
    for line in lines(launcher.status) { print("launcher:   \(line)") }

    guard let until = start.value("launcher.until") else {
      // Supervises for good.
      while true { sleep(until: Int64.max) }
    }
    let code: Int64
    do throws(LaunchError) {
      code = try launcher.waitForExit(until)
    } catch {
      fail(error.description)
    }
    print("launcher: \(until) exited with \(code)")
    for line in lines(launcher.status) { print("launcher:   \(line)") }
    print("launcher: shutting down")
    launcher.stop()
    _ = consume bootfs
    Process.exit(code: code)
  }

  /// `text`'s lines (bytes: String's split needs Unicode tables).
  static func lines(_ text: String) -> [String] {
    var out: [String] = [], line: [UInt8] = []
    for b in text.utf8 {
      if b == 0x0A {
        out.append(String(decoding: line, as: UTF8.self))
        line = []
      } else {
        line.append(b)
      }
    }
    if !line.isEmpty { out.append(String(decoding: line, as: UTF8.self)) }
    return out
  }
}
