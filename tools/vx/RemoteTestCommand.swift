// SPDX-License-Identifier: BSD-3-Clause

// vx remote test (D66, vx-remote(1)): the native suite on a board. A cpu
// session warm-boots the node (RemoteBoot, as vx remote boot does) into
// ARCH's kernel and the suite's bootfs, boot-smoke's, with `croi.test=all`
// (Hardware's NativeRun.options): the kernel's self-tests, m2 and every
// Swift suite. The board's serial console, read here, says how it went,
// as qemu.sh reads QEMU's: `userboot: bin/m2 exited with 0` passes, a
// panic or another exit fails, and so does silence for --timeout seconds.
// The budget lines are scraped and listed. The node reboots when done,
// into its firmware's default (`userboot.shutdown=reboot`).
//
//   vx remote test [ARCH] --serial DEV [--timeout SECONDS] [--option WORD]...
//                  [--record] [-k NODEKEY] [--key FILE] PLATFORM NODE
//
// Each --option's WORD joins the test boot's command line.
//
// The console goes to build/vx/remote-test-PLATFORM.log. With --record,
// the run, pass or fail, is written to docs/hardware/runs.tsv for
// PLATFORM (support.tsv's id), at this tree's commit, which must be
// committed.

import CpuTerminal
import FoundationEssentials
import Glibc
import Hardware
import Noise

private let testUsage =
  "usage: vx remote test [ARCH] --serial DEV [--timeout SECONDS] [--option WORD]... [--record] [-k NODEKEY] [--key FILE] PLATFORM NODE"

func remoteTest(_ args: [String]) -> Bool {
  var arch: String?, serial: String?, given: String?, record = false, timeout = 900.0
  var keyPath = TerminalKey.defaultPath
  var names: [String] = [], extra: [String] = []
  var rest = args[...]
  func value() -> String {
    guard let v = rest.popFirst() else { fail(testUsage) }
    return v
  }
  while let a = rest.popFirst() {
    switch a {
    case "--serial": serial = value()
    case "--timeout":
      guard let t = Double(value()), t > 0 else { fail(testUsage) }
      timeout = t
    case "--record": record = true
    case "--option": extra.append(value())
    case "-k": given = value()
    case "--key": keyPath = value()
    default:
      guard !a.hasPrefix("-") else { fail(testUsage) }
      if arch == nil, names.isEmpty, allArches.contains(a) { arch = a } else { names.append(a) }
    }
  }
  guard let serial, names.count == 2, let (host, port) = cpuAddress(names[1]) else { fail(testUsage) }
  let platform = names[0], node = names[1]
  let target = arch ?? "amd64"
  guard FileManager.default.fileExists(atPath: "CMakePresets.json") else {
    fail("remote: run vx remote test from the repository root")
  }
  let commit = treeCommit()
  if record, commit.hasSuffix("-dirty") { fail("remote: --record needs a committed tree (commit first)") }
  let key: StaticKey
  do throws(TerminalError) { key = try TerminalKey.load(keyPath) } catch { fail("remote: \(error)") }

  // The console first: the warm boot's first lines are the old kernel's.
  let fd = open(serial, O_RDONLY | O_NOCTTY | O_NONBLOCK)
  guard fd >= 0 else {
    fail("remote: can't open \(serial): \(String(cString: strerror(errno)))"
      + (errno == EACCES ? " (in its group, dialout? `sg dialout -c 'vx remote test ...'`)" : ""))
  }
  defer { close(fd) }
  var tio = termios()
  guard tcgetattr(fd, &tio) == 0 else { fail("remote: \(serial) isn't a serial port") }
  cfmakeraw(&tio)
  cfsetispeed(&tio, speed_t(B115200))
  cfsetospeed(&tio, speed_t(B115200))
  tio.c_cflag |= tcflag_t(CLOCAL | CREAD)
  guard tcsetattr(fd, TCSANOW, &tio) == 0 else { fail("remote: can't set up \(serial)") }
  tcflush(fd, TCIFLUSH)
  let console = SerialConsole(fd: fd, log: "\(logs)/remote-test-\(platform).log")
  console.start()

  guard build(target) else { return false }
  let root = stageImages([("kernel.elf", "build/\(target)/kernel/kernel.elf"),
                          ("bootfs.img", "build/\(target)/bootfs.img")])
  defer { removeTree(root.path) }
  let options = NativeRun.options + extra
  say("vx remote test: \(platform) at \(node), the native suite (\(options.joined(separator: " ")))")
  do throws(TerminalError) {
    _ = try RemoteBoot.run(
      host: host, port: port, key: key, node: nodeKey(given, host, "remote"), root: root.path,
      kernel: "/mnt/term/root/kernel.elf", bootfs: "/mnt/term/root/bootfs.img", options: options,
      answers: false, output: { b in _ = b.withUnsafeBytes { write(1, $0.baseAddress, $0.count) } })
  } catch {
    complain("remote: \(error)")
    console.stop()
    return false
  }

  // The new boot's console until it says how it went.
  let began = now()
  var lastHeard = began
  var heard = 0
  while true {
    let (verdict, count) = console.state
    if verdict != .running { break }
    if count != heard {
      heard = count
      lastHeard = now()
    }
    if now() - lastHeard > timeout {
      console.fail("nothing on the console for \(Int(timeout)) s")
      break
    }
    usleep(100_000)
  }
  console.stop()
  let run = console.run
  let seconds = now() - began
  let passed = run.verdict == .passed
  switch run.verdict {
  case .passed: say("vx remote test: \(platform): passed, \(run.lines) lines in \(Int(seconds)) s")
  case .failed(let why): complain("vx remote test: \(platform): FAILED: \(why)")
  case .running: break
  }
  let over = run.budgets.filter(\.over)
  say("vx remote test: \(run.budgets.count) budget(s), \(over.count) over (reported, not enforced: see vx bench)")
  for b in run.budgets {
    say("  budget name=\(b.name) value=\(b.value) unit=\(b.unit)" + (b.limit.map { " limit=\($0)" } ?? "")
      + (b.over ? "  OVER" : ""))
  }
  say("vx remote test: the console is in \(logs)/remote-test-\(platform).log")
  if record {
    let date = capture(["date", "+%Y-%m-%d"]).map(trimmed) ?? "unknown"
    let line = Run(date: date, commit: commit, platform: platform, passed: passed, tests: passed ? ["native"] : []).line
    let path = "docs/hardware/runs.tsv"
    var text = (try? String(contentsOfFile: path, encoding: .utf8))
      ?? "# Board runs (D66): date, commit, platform, pass or fail, the tests that passed. Written by vx remote test --record.\n"
    text += line + "\n"
    do { try text.write(toFile: path, atomically: true, encoding: .utf8) } catch { fail("remote: can't write \(path)") }
    say("vx remote test: recorded in \(path): \(line)")
  }
  return passed
}

/// The tree's commit, `-dirty` if it has changes.

/// A board's console: read on a thread of its own, a line at a time, into
/// the log and the run's judge.
private final class SerialConsole: @unchecked Sendable {
  let fd: Int32
  let log: UnsafeMutablePointer<FILE>?
  var mutex = pthread_mutex_t()
  var judged = NativeRun()
  var lines = 0
  var stopping = false
  var forced: String?

  init(fd: Int32, log: String) {
    self.fd = fd
    makeDirectory(logs)
    self.log = fopen(log, "w")
    pthread_mutex_init(&mutex, nil)
  }

  func locked<R>(_ body: () -> R) -> R {
    pthread_mutex_lock(&mutex)
    defer { pthread_mutex_unlock(&mutex) }
    return body()
  }

  var state: (NativeRun.Verdict, Int) { locked { (forced.map { .failed($0) } ?? judged.verdict, lines) } }
  var run: NativeRun { locked { judged } }

  func fail(_ why: String) { locked { forced = why } }
  func stop() { locked { stopping = true } }

  func start() {
    let me = Unmanaged.passRetained(self).toOpaque()
    var thread = pthread_t()
    _ = pthread_create(&thread, nil, { p in
      let console = Unmanaged<SerialConsole>.fromOpaque(p!).takeRetainedValue()
      console.read()
      return nil
    }, me)
    pthread_detach(thread)
  }

  /// Lines until stopped; CR LF is one line end (a serial console's).
  private func read() {
    var line: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 4096)
    while !locked({ stopping }) {
      var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
      guard poll(&p, 1, 100) > 0 else { continue }
      let n = buffer.withUnsafeMutableBytes { Glibc.read(fd, $0.baseAddress, $0.count) }
      guard n > 0 else { continue }
      if let log { _ = buffer.withUnsafeBytes { fwrite($0.baseAddress, 1, n, log) }; fflush(log) }
      for byte in buffer[0..<n] {
        if byte == 0x0A || byte == 0x0D {
          if !line.isEmpty {
            let text = String(decoding: line, as: UTF8.self)
            locked {
              lines += 1
              _ = judged.feed(text)
            }
            line.removeAll(keepingCapacity: true)
          }
        } else {
          line.append(byte)
        }
      }
    }
    if let log { fclose(log) }
  }
}
