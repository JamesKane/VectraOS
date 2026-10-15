// SPDX-License-Identifier: BSD-3-Clause

// Running a program while reading its output as it comes: for boots that
// never end by themselves (QEMU), judged from the console.

import FoundationEssentials
import Glibc

/// Runs `arguments` in a session of its own, its stdout and stderr copied
/// to `log`, until `judge` (given the output so far, whole lines only)
/// returns a verdict, the program exits, or `timeout` seconds pass. Then
/// the whole session is killed. Returns the verdict (nil if there was
/// none), the last 64 KiB of output, and the time taken.
func watch(_ arguments: [String], log: String, timeout: Double,
           judge: ([UInt8]) -> Bool?) -> (verdict: Bool?, output: [UInt8], seconds: Double) {
  var pipeFds: [Int32] = [0, 0]
  guard pipe(&pipeFds) == 0 else { fail("pipe failed") }
  var actions = posix_spawn_file_actions_t()
  posix_spawn_file_actions_init(&actions)
  defer { posix_spawn_file_actions_destroy(&actions) }
  posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
  posix_spawn_file_actions_adddup2(&actions, pipeFds[1], 1)
  posix_spawn_file_actions_adddup2(&actions, pipeFds[1], 2)
  posix_spawn_file_actions_addclose(&actions, pipeFds[0])
  posix_spawn_file_actions_addclose(&actions, pipeFds[1])
  var attributes = posix_spawnattr_t()
  posix_spawnattr_init(&attributes)
  defer { posix_spawnattr_destroy(&attributes) }
  posix_spawnattr_setflags(&attributes, 0x80)  // POSIX_SPAWN_SETSID (glibc), not imported

  var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
  defer { for p in argv { free(p) } }
  let start = now()
  var pid = pid_t()
  guard posix_spawnp(&pid, arguments[0], &actions, &attributes, &argv, environ) == 0 else {
    fail("can't run \(arguments[0])")
  }
  close(pipeFds[1])
  let logFd = open(log, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
  defer { close(logFd) }

  var seen: [UInt8] = []
  var verdict: Bool?
  var chunk = [UInt8](repeating: 0, count: 65536)
  func readSome() -> Int {
    let n = chunk.withUnsafeMutableBytes { read(pipeFds[0], $0.baseAddress, $0.count) }
    if n > 0 {
      _ = chunk.withUnsafeBytes { write(logFd, $0.baseAddress, n) }
      seen += chunk[..<n]
      if seen.count > 65536 { seen.removeFirst(seen.count - 65536) }
    }
    return n
  }
  while verdict == nil, now() - start < timeout {
    var p = pollfd(fd: pipeFds[0], events: Int16(POLLIN), revents: 0)
    guard poll(&p, 1, 50) >= 0 || errno == EINTR else { break }
    if p.revents == 0 { continue }
    if readSome() <= 0 { break }  // the program closed its output: it ended
    if let lastNewline = seen.lastIndex(of: 0x0A) { verdict = judge(Array(seen[...lastNewline])) }
  }
  kill(-pid, SIGKILL)
  var status: Int32 = 0
  while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
  while readSome() > 0 {}
  close(pipeFds[0])
  // It ended before a verdict: judge everything it wrote.
  if verdict == nil { verdict = judge(seen) }
  return (verdict, seen, now() - start)
}

extension Array where Element == UInt8 {
  func contains(_ text: String) -> Bool {
    let needle = Array(text.utf8)
    guard !needle.isEmpty, count >= needle.count else { return needle.isEmpty }
    for i in 0...(count - needle.count) where self[i] == needle[0] && Array(self[i..<i + needle.count]) == needle {
      return true
    }
    return false
  }
}
