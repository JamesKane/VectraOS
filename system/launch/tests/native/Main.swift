// SPDX-License-Identifier: BSD-3-Clause

// bin/launch-test: the launcher natively (V2's item 4). bin/launcher
// starts it from its manifest (manifests/launch-test.manifest) beside
// services a and b (bin/launch-service), and exits with its code
// (launcher.until=launch-test, the boot-launch test). It reads its
// namespace from its Startup (D65), reads every /svc/*/status, reaches a
// through b, kills a through /svc/launcher/ctl and reaches its next
// instance by the same paths, and reads UTC from the page every process
// is given (D48), the RTC's on amd64. It exits 0 if every check passed.

import IPC
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
    // stdin, stdout, and a stderr of its own (D46: a ring per descriptor).
    let stdio = try ChildStdio(for: startup, descriptors: [(0, true), (1, false), (2, false)])
    let process = try Process.create(job: job, name: "rc")
    let thread = try Process.start(process, entry: rc, startup)
    try stdio.closeInput(deadline: Clock.monotonic() + 5_000_000_000)
    let out = try stdio.readAll(deadline: Clock.monotonic() + 10_000_000_000)
    let err = try stdio.stream(2)!.readAll(deadline: Clock.monotonic() + 5_000_000_000)
    _ = try process.wait(for: Signals.terminated, deadline: Clock.monotonic() + 5_000_000_000)
    let code = try Process.info(process).returnCode
    print("launch-test: rc -c '\(script)' wrote \(out.count) bytes, exited \(code)")
    if !err.isEmpty { print("launch-test:   its stderr: \(String(decoding: err, as: UTF8.self))") }
    check(code == 0 && out == expected, name)
    _ = consume thread
  } catch {
    check(false, name)
    print("launch-test: rc: \(error.rawValue)")
  }
}

/// rc on a pty, as a terminal runs it (D46): rc given the pty's client
/// end as its descriptors 0 to 2 and its Control, typed to here. It
/// prompts, runs a line, lends the terminal to a program reading it
/// (cat, ended by ^D), and exits.
func rcOnPty(_ rc: ProgramEntry, _ ns: Namespace, job: borrowing Handle, bootfs: borrowing Handle) {
  guard let channel = try? ns.connect("/svc/pty/pty") else { return check(false, "/svc/pty/pty for rc") }
  var factory = PtyIPC.FactoryClient(channel: channel)
  do {
    let opened = try factory.open(size: PtyIPC.WindowSize(columns: 80, rows: 24))
    try opened.take {
      (k: consuming PtyIPC.Descriptor, s: consuming PtyIPC.Descriptor, device: consuming Handle) throws in
      let keys = try AttachedStream(k.parts(childReads: false))
      let screen = try AttachedStream(s.parts(childReads: true))
      var dev = PtyIPC.DeviceClient(channel: device)
      let startup = Startup(args: ["rc"])
      guard let svc = try? ns.connect("/svc") else { return check(false, "rc on a pty: /svc") }
      startup.mount(svc, at: "/svc")
      startup.add(try Job.create(parent: job), info: HandleType.info(HandleType.jobDefault))
      startup.add(try bootfs.duplicate(), info: HandleType.info(HandleType.vmoBootfs))
      try dev.client().take {
        (i: consuming PtyIPC.Descriptor, o: consuming PtyIPC.Descriptor, e: consuming PtyIPC.Descriptor,
         c: consuming Handle) in
        startup.add(i.parts(childReads: true), fd: 0)
        startup.add(o.parts(childReads: false), fd: 1)
        startup.add(e.parts(childReads: false), fd: 2)
        startup.add(c, info: HandleType.info(HandleType.ptyControl))
      }
      let process = try Process.create(job: job, name: "rc")
      let thread = try Process.start(process, entry: rc, startup)
      check(contains(readUntil(screen, Array("% ".utf8)), Array("% ".utf8)), "rc on a pty prompts")
      try keys.write(Array("echo hi\r".utf8))
      check(contains(readUntil(screen, Array("hi\r\n% ".utf8)), Array("echo hi\r\nhi\r\n% ".utf8)),
            "rc on a pty runs a typed line")
      // A program given rc's stdin has the terminal while it runs.
      try keys.write(Array("cat\r".utf8))
      _ = readUntil(screen, Array("cat\r\n".utf8))
      sleep(until: Clock.monotonic() + 500_000_000)  // cat started
      try keys.write(Array("typed\r".utf8))
      let echoed = readUntil(screen, Array("typed\r\n".utf8))
      // ^D: cat's input ends, and it writes what it read (the commands
      // write at their end: nothing streams yet), then rc prompts.
      try keys.write([0x04])
      let after = readUntil(screen, Array("% ".utf8))
      check(contains(echoed + after, Array("typed\r\ntyped\r\n% ".utf8)), "rc lends the terminal to the program it runs")
      check(contains(after, Array("% ".utf8)), "^D ends the program's input, not rc's")
      // ^C: rc kills the program that has the terminal.
      try keys.write(Array("cat\r".utf8))
      _ = readUntil(screen, Array("cat\r\n".utf8))
      sleep(until: Clock.monotonic() + 500_000_000)  // cat started
      try keys.write([0x03])
      check(contains(readUntil(screen, Array("% ".utf8)), Array("% ".utf8)), "^C kills the program, and rc prompts")
      try keys.write(Array("exit ''\r".utf8))  // $status is the killed cat's
      _ = try process.wait(for: Signals.terminated, deadline: Clock.monotonic() + 5_000_000_000)
      check(try Process.info(process).returnCode == 0, "rc on a pty exits")
      _ = consume thread
    }
  } catch {
    print("launch-test: rc on a pty: \(error)")
    check(false, "rc on a pty")
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
  rcRuns(rc, "rc -e -c 'echo a; ~ a b; echo never'; echo $status", Array("a\n1\n".utf8), ns, job: job,
         bootfs: bootfs, "rc -e stops at a command that fails")
  rcRuns(rc, "x=(a 'b c'); fn f { echo f $* }; rc -c 'echo $#x; f z'", Array("2\nf z\n".utf8), ns, job: job,
         bootfs: bootfs, "rc passes rc its lists and functions")
  // Split at : alone, the status keeps its newline.
  rcRuns(rc, "x=(a b); n=x; echo $$n; echo `:{cat /svc/a/status}", Array("a b\na first\n\n".utf8), ns, job: job,
         bootfs: bootfs, "rc takes $$x and `split{}")
  // Descriptors of their own (D46): a program's stderr apart from its
  // stdout, fds above 2, and <{} as /dev/fd/N.
  rcRuns(rc, "x=`{cat /nope}; echo $#x; y=`{cat /nope >[2=1]}; ~ $#y 0 || echo caught", Array("0\ncaught\n".utf8),
         ns, job: job, bootfs: bootfs, "rc gives a program a stderr of its own")
  rcRuns(rc, "cat /dev/fd/3 <[3]/svc/a/status", a, ns, job: job, bootfs: bootfs, "rc gives a program fd 3")
  rcRuns(rc, "cat <{cat /svc/a/status} <{echo two}", a + Array("two\n".utf8), ns, job: job, bootfs: bootfs,
         "rc runs <{} on the device")
  rcOnPty(rc, ns, job: job, bootfs: bootfs)
  _ = consume bootfs
}

/// What `s` gives until it has `want` in it, its end, or 5 s.
func readUntil(_ s: AttachedStream, _ want: [UInt8]) -> [UInt8] {
  var seen: [UInt8] = []
  let end = Clock.monotonic() + 5_000_000_000
  while !contains(seen, want) {
    guard let more = try? s.read(deadline: end), !more.isEmpty else { break }
    seen += more
  }
  return seen
}

func contains(_ bytes: [UInt8], _ part: [UInt8]) -> Bool {
  guard part.count <= bytes.count else { return part.isEmpty }
  for i in 0...(bytes.count - part.count) where Array(bytes[i..<(i + part.count)]) == part { return true }
  return false
}

/// A pty from /svc/pty/pty (D46): this process its terminal and its
/// program both, each side's rings attached here.
func runPty(_ ns: Namespace) {
  guard let channel = try? ns.connect("/svc/pty/pty") else { return check(false, "/svc/pty/pty") }
  var factory = PtyIPC.FactoryClient(channel: channel)
  do {
    let opened = try factory.open(size: PtyIPC.WindowSize(columns: 80, rows: 24))
    try opened.take {
      (k: consuming PtyIPC.Descriptor, s: consuming PtyIPC.Descriptor, device: consuming Handle) throws in
      let keys = try AttachedStream(k.parts(childReads: false))
      let screen = try AttachedStream(s.parts(childReads: true))
      var dev = PtyIPC.DeviceClient(channel: device)
      let client = try dev.client()
      try client.take {
        (i: consuming PtyIPC.Descriptor, o: consuming PtyIPC.Descriptor, e: consuming PtyIPC.Descriptor,
         c: consuming Handle) throws in
        let input = try AttachedStream(i.parts(childReads: true))
        let output = try AttachedStream(o.parts(childReads: false))
        let errors = try AttachedStream(e.parts(childReads: false))
        var control = PtyIPC.ControlClient(channel: c)
        check(try control.mode().canonical && control.windowSize() == PtyIPC.WindowSize(columns: 80, rows: 24),
              "a pty's program sees its mode and the window's size")
        // Keys: echoed to the screen (CR NL), a line to the program.
        try keys.write(Array("hello\r".utf8))
        check(readUntil(input, Array("\n".utf8)) == Array("hello\n".utf8), "a pty gives its program a typed line")
        check(readUntil(screen, Array("\r\n".utf8)) == Array("hello\r\n".utf8), "and echoes it to the terminal")
        // Output and errors: CR NL on the screen.
        try output.write(Array("out\n".utf8))
        check(readUntil(screen, Array("\r\n".utf8)) == Array("out\r\n".utf8), "a pty shows its program's output")
        try errors.write(Array("err\n".utf8))
        check(readUntil(screen, Array("\r\n".utf8)) == Array("err\r\n".utf8), "and its errors")
        // ^C: the control hears it.
        try keys.write([0x03])
        if case .event(.interrupt) = try control.nextEvent(deadline: Clock.monotonic() + 5_000_000_000) {
          check(true, "a pty's ^C is an interrupt for the control")
        } else {
          check(false, "a pty's ^C is an interrupt for the control")
        }
        _ = readUntil(screen, Array("^C\r\n".utf8))
        // ^D on an empty line, no controller taking it: the program's end.
        try keys.write([0x04])
        check((try? input.read(deadline: Clock.monotonic() + 5_000_000_000)) == [], "a pty's ^D ends its program's stdin")
      }
    }
  } catch {
    print("launch-test: a pty: \(error)")
    check(false, "a pty opened, typed to and shown")
  }
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
      let expected = 5  // and the time service
    #else
      let expected = 4
    #endif
    check(names.count == expected && names.contains { same($0, "a") } && names.contains { same($0, "b") }
            && names.contains { same($0, "launcher") } && names.contains { same($0, "pty") },
          "/svc holds what the manifest uses")
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
    runPty(ns)
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
