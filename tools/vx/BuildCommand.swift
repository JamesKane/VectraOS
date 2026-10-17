// SPDX-License-Identifier: BSD-3-Clause

// vx build, test and ci: CMake's per-arch trees (CMakePresets.json) and
// SwiftPM's host tests, each step's output in build/vx/<step>.log and only
// its tail shown when it fails.

import FoundationEssentials
import Glibc

let logs = "build/vx"

/// Runs one step with its output in build/vx/<name>.log; says how it went.
@discardableResult
func step(_ name: String, _ arguments: [String]) -> Bool {
  makeDirectory(logs)
  let log = "\(logs)/\(name).log"
  removeTree(log)
  let r = run(arguments, log: log)
  say("vx: \(name) \(r.ok ? "ok" : "FAILED") (\(formatSeconds(r.seconds)))")
  if !r.ok { showTail(log) }
  return r.ok
}

func formatSeconds(_ s: Double) -> String { "\(Int(s.rounded())) s" }

/// The last lines of a failed step's log, which is where the reason is.
func showTail(_ path: String, lines: Int = 30) {
  guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
  for line in text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines) { say("  \(line)") }
  say("  (all of it in \(path))")
}

func build(_ arch: String) -> Bool {
  if !FileManager.default.fileExists(atPath: "build/\(arch)/build.ninja") {
    guard step("\(arch)-configure", ["cmake", "--preset", arch]) else { return false }
  }
  return step("\(arch)-build", ["cmake", "--build", "--preset", arch])
}

/// One arch's QEMU tests. Arches run one after another: under the load of
/// two suites at once, rv64's TCG boots outlast their timeouts.
func test(_ arch: String) -> Bool {
  step("\(arch)-test", ["ctest", "--preset", arch])
}

func ci(_ args: [String]) -> Bool {
  var bench = true
  for a in args {
    switch a {
    case "--no-bench": bench = false
    default: fail("unknown option \(a)")
    }
  }
  var ok = step("host-test", ["swift", "test"])
  ok = rcOracleCommand([]) && ok  // rc against 9front's (D70)
  // Every arch builds; rv64's suite is off until full Swift runs there.
  for arch in allArches { ok = build(arch) && (!testedArches.contains(arch) || test(arch)) && ok }
  for arch in allArches where !testedArches.contains(arch) { say("vx: \(arch)-test skipped: off until full Swift runs there") }
  ok = locCommand(["--check"]) && ok
  ok = manCommand(["--check"]) && ok  // after the builds: their images' programs need pages (D86)
  ok = hardwareCommand(["--check"]) && ok
  if bench {
    if FileManager.default.fileExists(atPath: "/dev/kvm") {
      _ = benchCommand([])  // advisory on a shared machine (docs/performance.md)
    } else {
      say("vx: bench skipped: it needs KVM (/dev/kvm)")
    }
  }
  say(ok ? "vx: ci passed" : "vx: ci FAILED")
  return ok
}
