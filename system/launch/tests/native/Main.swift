// SPDX-License-Identifier: BSD-3-Clause

// bin/launch-test: the launcher natively (V2's item 4). bin/launcher
// starts it from its manifest (manifests/launch-test.manifest) beside
// services a and b (bin/launch-service), and exits with its code
// (launcher.until=launch-test, the boot-launch test). It reads its
// namespace from its Startup (D65), reads every /svc/*/status, reaches a
// through b, kills a through /svc/launcher/ctl and reaches its next
// instance by the same paths, and reads UTC from the page every process
// is given (D48), the RTC's on amd64. It exits 0 if every check passed.

import Node
import Sys

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var checks = 0

func check(_ condition: Bool, _ name: StaticString) {
  checks += 1
  if !condition {
    failures += 1
    print("launch-test: FAILED: \(name)")
  }
}

/// A String's bytes are `text`'s.
func same(_ string: String, _ text: StaticString) -> Bool {
  unsafe string.utf8.elementsEqual(UnsafeBufferPointer(start: text.utf8Start, count: text.utf8CodeUnitCount))
}

/// The text at `path`, if it can be read.
func readText(_ ns: Namespace, _ path: String) -> String? {
  guard var c = try? ns.open(path) else { return nil }
  return try? c.readText()
}

/// Whether `text` has the line `line` (bytes).
func hasLine(_ text: String, _ line: StaticString) -> Bool {
  var current: [UInt8] = []
  for b in text.utf8 {
    if b == 0x0A {
      if same(String(decoding: current, as: UTF8.self), line) { return true }
      current = []
    } else {
      current.append(b)
    }
  }
  return false
}

/// The last word of `text`, as a decimal number.
func lastNumber(_ text: String) -> Int64? {
  var n: Int64 = 0, digits = 0
  for b in text.utf8 {
    if b >= 0x30 && b <= 0x39 {
      n = n * 10 + Int64(b - 0x30)
      digits += 1
    } else if b == 0x20 {
      n = 0
      digits = 0
    }
  }
  return digits > 0 ? n : nil
}

/// rc from bootfs, given this process's /svc, a job and bootfs for its
/// programs, and stdio: `script` run by `rc -c`, which must write
/// `expected` and exit 0.
func rcRuns(_ rc: ProgramEntry, _ script: String, _ expected: [UInt8], _ ns: Namespace, job: borrowing Handle,
            bootfs: borrowing Handle, _ name: StaticString) {
  do throws(Status) {
    let startup = Startup(args: ["rc", "-c", script])
    guard let svc = try? ns.connect("/svc") else { return check(false, name) }
    startup.mount(svc, at: "/svc")
    startup.add(try Job.create(parent: job), info: HandleType.info(HandleType.jobDefault))
    startup.add(try bootfs.duplicate(), info: HandleType.info(HandleType.vmoBootfs))
    let stdio = try ChildStdio(for: startup)
    let process = try Process.create(job: job, name: "rc")
    let thread = try Process.start(process, entry: rc, startup)
    try stdio.closeInput(deadline: Clock.monotonic() + 5_000_000_000)
    let out = try stdio.readAll(deadline: Clock.monotonic() + 10_000_000_000)
    _ = try process.wait(for: Signals.terminated, deadline: Clock.monotonic() + 5_000_000_000)
    let code = try Process.info(process).returnCode
    print("launch-test: rc -c '\(script)' wrote \(out.count) bytes, exited \(code)")
    check(code == 0 && out == expected, name)
    _ = consume thread
  } catch {
    check(false, name)
    print("launch-test: rc: \(error.rawValue)")
  }
}

/// rc's `cat /svc/*/status` (V2's exit test), and a pipeline of programs
/// (each a child of rc's, rc relaying between them), checked against the
/// statuses read here.
func runRc(_ start: Startup, _ ns: Namespace, _ names: [String]) {
  guard let job = start.take(HandleType.info(HandleType.jobDefault)),
    let bootfs = start.take(HandleType.info(HandleType.vmoBootfs)), let files = try? ProgramEntry.bootfs(bootfs)
  else { return check(false, "a job and bootfs to start rc with") }
  guard let rc = files.first(where: { same($0.name, "bin/rc") }) else {
    print("launch-test: no bin/rc (tier 1 isn't built here): rc's checks skipped")
    return
  }
  // The glob's order: the names' bytes.
  let sorted = names.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
  var all: [UInt8] = []
  for name in sorted { all += Array((readText(ns, "/svc/" + name + "/status") ?? "").utf8) }
  rcRuns(rc, "cat /svc/*/status", all, ns, job: job, bootfs: bootfs, "rc runs cat /svc/*/status")
  let ab = Array(((readText(ns, "/svc/a/status") ?? "") + (readText(ns, "/svc/b/status") ?? "")).utf8)
  rcRuns(rc, "cat /svc/a/status /svc/b/status | cat | cat", ab, ns, job: job, bootfs: bootfs,
         "rc pipes program to program")
  rcRuns(rc, "x=b; cat <<EOF\na $x c\nEOF", Array("a b c\n".utf8), ns, job: job, bootfs: bootfs,
         "rc gives a program a here document")
  rcRuns(rc, "{ cat /svc/a/status } & wait", Array((readText(ns, "/svc/a/status") ?? "").utf8), ns, job: job,
         bootfs: bootfs, "rc runs a compound command in the background")
  // Programs by $path: /bin/NAME is bootfs's bin/NAME; an rc started by
  // rc can start programs too, and its exit code is its status.
  let a = Array((readText(ns, "/svc/a/status") ?? "").utf8)
  rcRuns(rc, "/bin/cat /svc/a/status", a, ns, job: job, bootfs: bootfs, "rc runs a program by its path")
  rcRuns(rc, "path=() whatis cat || echo none", Array("none\n".utf8), ns, job: job, bootfs: bootfs,
         "rc finds nothing on an empty $path")
  rcRuns(rc, "rc -c 'cat /svc/a/status'; rc -c 'exit 3'; echo $status", a + Array("3\n".utf8), ns, job: job,
         bootfs: bootfs, "rc runs rc, which runs programs and exits with its status")
  _ = consume bootfs
}

@main struct LaunchTest {
  static func main() {
    let start = Startup.current
    let ns: Namespace
    do throws(NamespaceError) {
      ns = try Namespace(start)
    } catch {
      print("launch-test: FAILED: no namespace")
      Process.exit(code: 1)
    }
    check(ns.mountPoints.count == 1 && same(ns.mountPoints[0], "/svc"), "the namespace is /svc alone")

    // cat /svc/*/status
    let names = ((try? ns.list("/svc")) ?? []).map { $0.name }
    #if arch(x86_64)
      let expected = 4  // and the time service
    #else
      let expected = 3
    #endif
    check(names.count == expected && names.contains { same($0, "a") } && names.contains { same($0, "b") }
            && names.contains { same($0, "launcher") }, "/svc holds what the manifest uses")
    for name in names {
      let status = readText(ns, "/svc/" + name + "/status")
      check(status != nil, "each /svc/*/status reads")
      if let status { print("launch-test: /svc/\(name)/status: \(status)") }
    }
    check(readText(ns, "/svc/a/status").map { same($0, "a first\n") } ?? false, "a's status")
    check(readText(ns, "/svc/b/peer").map { same($0, "a first\n") } ?? false, "b reaches a through its own /svc")
    let status = readText(ns, "/svc/launcher/status") ?? ""
    check(hasLine(status, "a running restarts 0") && hasLine(status, "b running restarts 0")
            && hasLine(status, "launch-test running restarts 0"), "the launcher's status")

    // UTC (D48): the page every process maps, at least the launcher's
    // backstop; on amd64, the RTC's reading, which the time service set.
    let backstop: Int64 = 1_767_225_600 * 1_000_000_000
    let utc = Clock.realtime()
    check(utc >= backstop, "UTC reads the page, at least its backstop")
    #if arch(x86_64)
      let time = readText(ns, "/svc/time/status") ?? ""
      check(time.utf8.starts(with: "set from rtc ".utf8), "the time service set UTC from the RTC")
      if let set = lastNumber(time) {
        check(utc >= set && utc - set < 60_000_000_000, "UTC follows the RTC's reading")
      } else {
        check(false, "UTC follows the RTC's reading")
      }
    #endif

    // rc runs `cat /svc/*/status` (V2's exit test): rc from bootfs, given
    // this process's /svc, a job and bootfs for its programs, and stdio;
    // what it writes is every status, in the glob's order. Tier 1: not on
    // rv64 yet.
    runRc(start, ns, names)

    // A crash, as the launcher's ctl makes one: a restarts (`restart always`).
    if var ctl = try? ns.open("/svc/launcher/ctl") {
      check((try? ctl.writeText("kill a")) != nil, "ctl kills a")
    } else {
      check(false, "ctl kills a")
    }
    var restarted = false
    let deadline = Clock.monotonic() + 5_000_000_000
    while !restarted && Clock.monotonic() < deadline {
      restarted = hasLine(readText(ns, "/svc/launcher/status") ?? "", "a running restarts 1")
      if !restarted { sleep(until: Clock.monotonic() + 10_000_000) }
    }
    check(restarted, "a restarted")
    check(readText(ns, "/svc/a/status").map { same($0, "a first\n") } ?? false, "the new a, by the same path")
    check(readText(ns, "/svc/b/peer").map { same($0, "a first\n") } ?? false, "and through b")

    print("launch-test: \(checks - failures) of \(checks) checks passed")
    Process.exit(code: failures == 0 ? 0 : 1)
  }
}
