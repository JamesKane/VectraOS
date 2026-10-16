// SPDX-License-Identifier: BSD-3-Clause

// bin/rc (M6j part 2c): the shell on croi, in full Swift (tier 1). Started
// with stdio rings as its descriptors 0-2 (D46: a terminal's pty, or its
// parent's), or with the debuglog alone: it prompts with $prompt(1) (or
// $prompt(2) inside an unfinished construct), reads lines until what it
// has parses, and runs it; `rc -c COMMAND` runs one, and `rc FILE ARG...`
// runs a script ($0 the file, $* the rest: a `#!/bin/rc` script's too).
// Its exit code is its status: 0 if true, a number as itself, else 1. Its programs are
// bootfs's `bin/` (its Startup's bootfs and job: a manifest's `programs`),
// its files fdio's, its namespace its Startup's (D65). On a terminal
// (`TERM` in its environment) it says its directory before a prompt when
// it changed, as OSC 7 (file://PATH): Terminal routes a word from the
// screen from there (M6k).

import LibSys
import Rc
import Sys
import TDFloor
import VectraOSLibc

/// A descriptor of the process's own (the floor's: a ring, or the
/// debuglog).
final class Standard: RcStream {
  let fd: Int32
  init(_ fd: Int32) { self.fd = fd }
  func write(_ bytes: [UInt8]) {
    bytes.withUnsafeBytes { b in
      guard let p = b.baseAddress, !b.isEmpty else { return }
      if fd == 2 { td_stderr_write(p, b.count) } else {
        td_stdout_write(p, b.count)
        td_stdout_flush()
      }
    }
  }
  func read() -> [UInt8]? {
    var buffer = [UInt8](repeating: 0, count: 1024)
    let n = buffer.withUnsafeMutableBytes { b in td_stdin_read(b.baseAddress!, b.count) }
    return n > 0 ? Array(buffer[0..<n]) : nil
  }
  func close() {}
}

@main struct RcMain {
  static func main() {
    let start = Startup.current
    guard let job = start.take(HandleType.info(HandleType.jobDefault)),
      let bootfs = start.take(HandleType.info(HandleType.vmoBootfs)), let files = try? ProgramEntry.bootfs(bootfs)
    else {
      print("rc: no job or bootfs to start programs from (its manifest's `programs`)")
      exit(1)
    }
    var programs: [(name: String, entry: ProgramEntry)] = []
    for f in files where f.name.hasPrefix("bin/") { programs.append((String(f.name.dropFirst(4)), f)) }
    // bootfs stays open all along: programs load from it.
    run(CroiSystem(job: job, bootfs: bootfs, programs: programs))
  }

  static func run(_ system: CroiSystem) {
    var args = Array(Arguments.strings.dropFirst())
    let fds: [Int32: RcStream] = [0: Standard(0), 1: Standard(1), 2: Standard(2)]
    if args.first == "-c" {
      let shell = Rc(system: system, arguments: Array(args.dropFirst(2)))
      shell.run(args.count > 1 ? args[1] : "", fds: fds)
      exit(exitCode(shell))
    }
    if let file = args.first {
      let shell = Rc(system: system, name: file, arguments: Array(args.dropFirst()))
      guard let s = system.open(file, .read) else {
        fds[2]!.write(Array(("rc: can't open " + file + "\n").utf8))
        exit(1)
      }
      var text: [UInt8] = []
      while let b = s.read() { text += b }
      s.close()
      shell.run(String(decoding: text, as: UTF8.self), fds: fds)
      exit(exitCode(shell))
    }
    let shell = Rc(system: system, arguments: args)
    args.removeAll()
    // A starting directory (M6l: Terminal opened here by Tracker's add-on).
    if let d = Environment.value("PWD"), !d.isEmpty { _ = system.changeDirectory(d) }
    shell.variables["prompt"] = ["% ", "\t"]
    shell.variables["home"] = ["/"]
    var pending: [UInt8] = []
    var text = ""
    let input = fds[0]!
    let terminal = Environment.value("TERM") != nil
    var told = ""
    while true {
      if terminal && text.isEmpty && system.directory != told {
        told = system.directory
        fds[1]!.write(Array("\u{1B}]7;file://".utf8) + percentEncoded(told) + Array("\u{1B}\\".utf8))
      }
      let prompt = shell.variables["prompt"] ?? ["% "]
      let p = text.isEmpty || prompt.count < 2 ? (prompt.first ?? "") : prompt[1]
      fds[1]!.write(Array(p.utf8))
      // A line.
      var line: [UInt8]? = nil
      while line == nil {
        if let nl = pending.firstIndex(of: 0x0A) {
          line = Array(pending[...nl])
          pending.removeSubrange(...nl)
        } else if let more = input.read() {
          pending += more
        } else {
          exit(exitCode(shell))  // the end of input
        }
      }
      text += String(decoding: line!, as: UTF8.self)
      do throws(RcSyntaxError) {
        _ = try Parser.parse(text)
      } catch {
        if error.incomplete { continue }
      }
      let script = text
      text = ""
      if !shell.run(script, fds: fds) { exit(exitCode(shell)) }
    }
  }
}

/// rc's exit code: 0 if its status is true, a status that is a number
/// as itself (what Job.wait gives a parent rc back), any other 1.
func exitCode(_ shell: Rc) -> Int32 {
  if shell.succeeded { return 0 }
  if let n = Int32(shell.status), n > 0, n < 256 { return n }
  return 1
}

/// A path for a URL: what isn't unreserved or `/` as %XX.
func percentEncoded(_ path: String) -> [UInt8] {
  var out: [UInt8] = []
  let digits = Array("0123456789ABCDEF".utf8)
  for b in path.utf8 {
    switch b {
    case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
      UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"), UInt8(ascii: "/"):
      out.append(b)
    default: out += [UInt8(ascii: "%"), digits[Int(b >> 4)], digits[Int(b & 0xF)]]
    }
  }
  return out
}
