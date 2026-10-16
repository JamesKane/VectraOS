// SPDX-License-Identifier: BSD-3-Clause

// vx rc-oracle [CASE...]: our rc against 9front's (D70). Each case of
// shell/rc/tests/oracle (NAME.rc) runs through 9front's rc, built from
// tools/rc-oracle/9front by the toolchain's clang, and through rcport (our
// rc on Linux, tools/rc-oracle/port), each in a fresh directory with an
// empty stdin; their stdout, exit status and whether they wrote to stderr
// must agree. A case whose first line is `#flags: -e -x` runs with those
// flags in both, and `$rcoracle` runs its shell again. known.tsv names the cases that differ today: one that differs
// and isn't named fails, and so does one named that now agrees, so the
// list stays exactly what is left. Everything goes to .build/rc-oracle.

import FoundationEssentials
import Glibc

let oracleSources = "tools/rc-oracle/9front"
let oracleCases = "shell/rc/tests/oracle"
let oracleOut = ".build/rc-oracle"

/// 9front's rc, built when missing or older than a source of it.
func buildOracle() -> String? {
  let binary = "\(oracleOut)/rc"
  guard let names = try? FileManager.default.contentsOfDirectory(atPath: oracleSources) else { return nil }
  let sources = names.filter { $0.hasSuffix(".c") }.sorted()
  func modified(_ path: String) -> Double {
    var st = stat()
    return stat(path, &st) == 0 ? Double(st.st_mtim.tv_sec) + Double(st.st_mtim.tv_nsec) / 1e9 : 0
  }
  let built = modified(binary)
  if built > 0 && names.allSatisfy({ modified("\(oracleSources)/\($0)") < built }) { return binary }
  makeDirectory("\(oracleOut)/obj")
  let log = "\(logs)/rc-oracle-build.log"
  makeDirectory(logs)
  removeTree(log)
  var objects: [String] = []
  for s in sources {
    let o = "\(oracleOut)/obj/\(s.dropLast(2)).o"
    // 9front's C, as its Makefile builds it (unix.c's PREFIX: rcmain is given with -m).
    guard run(["clang", "-std=gnu99", "-O1", "-w", "-DPREFIX=\"/usr/local\"", "-I", oracleSources, "-c",
               "\(oracleSources)/\(s)", "-o", o], log: log).ok
    else {
      showTail(log)
      return nil
    }
    objects.append(o)
  }
  guard run(["clang", "-o", binary] + objects, log: log).ok else {
    showTail(log)
    return nil
  }
  return binary
}

/// What a shell did with a case.
struct Outcome: Equatable {
  var stdout: [UInt8]
  var status: Int32
  var wroteErrors: Bool
}

/// Runs `shell` with `flags` on `script` in a fresh `directory`, stdin
/// empty, for at most 20 s: what it wrote and how it ended. Its
/// environment has `rcoracle`, the shell (a list, ^A between its words, as
/// rc's environment has them), for a case to run it again.
func runCase(_ shell: [String], _ flags: [String], _ script: String, in directory: String) -> Outcome {
  removeTree(directory)
  makeDirectory(directory)
  let out = "\(directory).out", err = "\(directory).err"
  var actions = posix_spawn_file_actions_t()
  posix_spawn_file_actions_init(&actions)
  defer { posix_spawn_file_actions_destroy(&actions) }
  posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
  posix_spawn_file_actions_addopen(&actions, 1, out, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
  posix_spawn_file_actions_addopen(&actions, 2, err, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
  let arguments = ["env", "-C", directory, "rcoracle=" + shell.joined(separator: "\u{1}"), "timeout", "20"] + shell
    + flags + [script]
  var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
  defer { for p in argv { free(p) } }
  var pid = pid_t()
  var status: Int32 = 0
  if posix_spawnp(&pid, "env", &actions, nil, &argv, environ) == 0 {
    while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
  } else {
    status = 127 << 8
  }
  func bytes(_ path: String) -> [UInt8] { FileManager.default.contents(atPath: path).map { Array($0) } ?? [] }
  let code = status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
  return Outcome(stdout: bytes(out), status: code, wroteErrors: !bytes(err).isEmpty)
}

/// A case's flags: the words of a first line `#flags: ...`.
func caseFlags(_ script: String) -> [String] {
  guard let text = try? String(contentsOfFile: script, encoding: .utf8),
    let first = text.split(separator: "\n", maxSplits: 1).first, first.hasPrefix("#flags:")
  else { return [] }
  return first.dropFirst(7).split(separator: " ").map(String.init)
}

/// known.tsv: case, kind and why, for each case that differs today.
func knownDivergences() -> [String: (kind: String, why: String)] {
  guard let text = try? String(contentsOfFile: "\(oracleCases)/known.tsv", encoding: .utf8) else { return [:] }
  var known: [String: (kind: String, why: String)] = [:]
  for line in text.split(separator: "\n") where !line.hasPrefix("#") {
    let fields = line.split(separator: "\t", maxSplits: 2).map(String.init)
    if fields.count == 3 { known[fields[0]] = (fields[1], fields[2]) }
  }
  return known
}

func rcOracleCommand(_ args: [String]) -> Bool {
  guard let oracle = buildOracle() else {
    complain("rc-oracle: can't build 9front's rc (\(logs)/rc-oracle-build.log)")
    return false
  }
  guard step("rc-oracle-rcport", ["swift", "build", "--product", "rcport"]) else { return false }
  let rcport = ".build/debug/rcport"
  let cwd = FileManager.default.currentDirectoryPath
  guard let names = try? FileManager.default.contentsOfDirectory(atPath: oracleCases) else {
    complain("rc-oracle: no cases in \(oracleCases)")
    return false
  }
  var cases = names.filter { $0.hasSuffix(".rc") }.map { String($0.dropLast(3)) }.sorted()
  if !args.isEmpty {
    for a in args where !cases.contains(a) { fail("rc-oracle: no case \(a)") }
    cases = args
  }
  let known = knownDivergences()
  for name in known.keys where !cases.contains(name) && args.isEmpty {
    complain("rc-oracle: known.tsv names \(name), which isn't a case")
  }
  var matched = 0, expected = 0, failures: [String] = []
  for name in cases {
    let script = "\(cwd)/\(oracleCases)/\(name).rc"
    let flags = caseFlags(script)
    let theirs = runCase(["\(cwd)/\(oracle)", "-m", "\(cwd)/\(oracleSources)/rcmain.unix"], flags, script,
                         in: "\(cwd)/\(oracleOut)/work/9front/\(name)")
    let ours = runCase(["\(cwd)/\(rcport)"], flags, script, in: "\(cwd)/\(oracleOut)/work/port/\(name)")
    let same = theirs == ours
    switch (same, known[name]) {
    case (true, nil): matched += 1
    case (false, .some): expected += 1
    case (true, .some(let k)):
      failures.append("\(name): agrees with 9front now (known.tsv: \(k.kind), \(k.why)): take its line out")
    case (false, nil):
      var how: [String] = []
      if theirs.stdout != ours.stdout { how.append("stdout") }
      if theirs.status != ours.status { how.append("status \(theirs.status) vs \(ours.status)") }
      if theirs.wroteErrors != ours.wroteErrors { how.append("stderr \(theirs.wroteErrors) vs \(ours.wroteErrors)") }
      failures.append("\(name): differs from 9front (\(how.joined(separator: ", "))): \(oracleOut)/work/{9front,port}/\(name).*")
    }
  }
  for f in failures { say("vx: rc-oracle: \(f)") }
  let port = known.values.filter { $0.kind == "port" }.count
  say("vx: rc-oracle: \(cases.count) cases, \(matched) agree, \(expected) known divergences "
      + "(\(port) port, \(known.count - port) linux)\(failures.isEmpty ? "" : ", \(failures.count) FAILED")")
  return failures.isEmpty
}
