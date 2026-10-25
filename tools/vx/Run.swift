// SPDX-License-Identifier: BSD-3-Clause

// Running commands: each with its output in a log file, timed on the
// monotonic clock.

import FoundationEssentials
import Glibc

func say(_ message: String) {
  let line = Array("\(message)\n".utf8)
  _ = line.withUnsafeBytes { write(1, $0.baseAddress, $0.count) }
}

func complain(_ message: String) {
  let line = Array("vx: \(message)\n".utf8)
  _ = line.withUnsafeBytes { write(2, $0.baseAddress, $0.count) }
}

func fail(_ message: String) -> Never {
  complain(message)
  exit(1)
}

func now() -> Double {
  var ts = timespec()
  clock_gettime(CLOCK_MONOTONIC, &ts)
  return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9
}

/// Runs `arguments` (found on PATH) in the current directory, with stdout
/// and stderr appended to `log`, or vx's own if `log` is nil. Returns
/// whether it exited 0, and the time.
@discardableResult
func run(_ arguments: [String], log: String?) -> (ok: Bool, seconds: Double) {
  var actions = posix_spawn_file_actions_t()
  posix_spawn_file_actions_init(&actions)
  defer { posix_spawn_file_actions_destroy(&actions) }
  if let log {
    posix_spawn_file_actions_addopen(&actions, 1, log, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    posix_spawn_file_actions_adddup2(&actions, 1, 2)
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
  }

  var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
  defer { for p in argv { free(p) } }
  let start = now()
  var pid = pid_t()
  guard posix_spawnp(&pid, arguments[0], &actions, nil, &argv, environ) == 0 else {
    return (false, 0)
  }
  var status: Int32 = 0
  while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
  let seconds = now() - start
  let exited = status & 0x7f == 0
  return (exited && (status >> 8) & 0xff == 0, seconds)
}

/// A command's standard output, trimmed, or nil if it failed.
func capture(_ arguments: [String]) -> String? {
  let path = "/tmp/vx-capture-\(getpid())"
  defer { unlink(path) }
  guard run(arguments, log: path).ok, let text = try? String(contentsOfFile: path, encoding: .utf8) else {
    return nil
  }
  return trimmed(text)
}

/// `text` without leading and trailing whitespace.
func trimmed<S: StringProtocol>(_ text: S) -> String {
  String(text.drop { $0.isWhitespace }.reversed().drop { $0.isWhitespace }.reversed())
}

func makeDirectory(_ path: String) {
  try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
}

func removeTree(_ path: String) { try? FileManager.default.removeItem(atPath: path) }

/// Sets a file's modification time to now, as `touch` does.
func touch(_ path: String) { utimensat(AT_FDCWD, path, nil, 0) }

/// The commit `tree` is at, `-dirty` if a tracked file has changed.
func treeCommit(_ tree: String = ".") -> String {
  let sha = capture(["git", "-C", tree, "rev-parse", "--short", "HEAD"]) ?? "unknown"
  let dirty = capture(["git", "-C", tree, "status", "--porcelain", "--untracked-files=no"]) ?? ""
  return sha + (dirty.isEmpty ? "" : "-dirty")
}

func oneDecimal(_ v: Double) -> String { String(Double(Int((v * 10).rounded())) / 10) }

/// The host's name, as gethostname gives it.
func hostName() -> String {
  var name = [CChar](repeating: 0, count: 256)
  gethostname(&name, 255)
  return String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

func cpuCount() -> Int { Int(sysconf(Int32(_SC_NPROCESSORS_ONLN))) }

/// The last minute's load average.
func loadAverage() -> Double {
  var load = [0.0, 0.0, 0.0]
  _ = getloadavg(&load, 3)
  return load[0]
}

/// A machine too busy to time on: load above a quarter of its CPUs.
func isBusy(_ load: Double) -> Bool { load > Double(cpuCount()) / 4 }
