// SPDX-License-Identifier: BSD-3-Clause

// bin/rc (M6j part 2c): the shell on croi, in full Swift (tier 1). Started
// with stdio rings as its descriptors 0-2 (D46: a terminal's pty, or its
// parent's), with none and a /dev/cons (the console's shell, kbdfs's), or
// with the debuglog alone: it prompts with $prompt(1) (or
// $prompt(2) inside an unfinished construct), reads lines until what it
// has parses, and runs it; `rc -c COMMAND` runs one, and `rc FILE ARG...`
// runs a script ($0 the file, $* the rest: a `#!/bin/rc` script's too),
// found along $path; it takes 9front's flags (RcArguments) and prompts
// only when interactive (-i, or a terminal without -I). It ends with its
// status as its exit string (D72: none if true). Its programs are
// its namespace's (/bin: D71), started in its Startup's job, its files
// fdio's, its namespace its Startup's (D65). On a terminal
// (`TERM` in its environment) it says its directory before a prompt when
// it changed, as OSC 7 (file://PATH): Terminal routes a word from the
// screen from there (M6k).

import FDIO
import LibSys
import Rc
import Sys
import TDFloor
import TDNative
import VectraOSLibc

/// A descriptor of the process's own (the floor's: a ring, or the
/// debuglog): 0 to 2, or one above it was started with (D46).
final class Standard: RcStream {
  let fd: Int32
  init(_ fd: Int32) { self.fd = fd }
  /// fd 0, or one above 2 it was given to read.
  var source: Bool? {
    var reads = false
    return fd == 0 || (fd > 2 && td_stdio_has(fd, &reads) && reads)
  }
  func write(_ bytes: [UInt8]) {
    bytes.withUnsafeBytes { b in
      guard let p = b.baseAddress, !b.isEmpty else { return }
      if fd == 2 { td_stderr_write(p, b.count) } else if fd > 2 { _ = td_stdio_write_fd(fd, p, UInt64(b.count)) } else {
        td_stdout_write(p, b.count)
        td_stdout_flush()
      }
    }
  }
  func read() -> [UInt8]? {
    // On a pty, stdin is the terminal's, which rc shares with its
    // programs (Terminal.swift).
    if fd == 0, let t = Terminal.current { return t.read() }
    var buffer = [UInt8](repeating: 0, count: 1024)
    let n = buffer.withUnsafeMutableBytes { b in
      fd > 2 ? Int(td_stdio_read_fd(fd, b.baseAddress!, UInt64(b.count))) : td_stdin_read(b.baseAddress!, b.count)
    }
    return n > 0 ? Array(buffer[0..<n]) : nil
  }
  func close() { if fd > 2 { td_stdio_end_fd(fd) } }
}

@main struct RcMain {
  static func main() {
    let start = Startup.current
    guard let job = start.take(HandleType.info(HandleType.jobDefault)) else {
      print("rc: no job to start programs in (its manifest's `programs`)")
      exit(1)
    }
    NoteQueue.shared.start()  // its notes (D87)
    run(CroiSystem(job: job))
  }

  static func run(_ system: CroiSystem) {
    // 0 to 2, and any above it was started with.
    var fds: [Int32: RcStream] = [0: Standard(0), 1: Standard(1), 2: Standard(2)]
    for n in 3..<Int32(TD_STDIO_FD_LIMIT) where td_stdio_has(n, nil) { fds[n] = Standard(n) }
    let argv = Arguments.strings
    guard let a = RcArguments(Array(argv.dropFirst())) else {
      fds[2]!.write(Array((RcArguments.usage + "\n").utf8))
      exit(1)
    }
    // On a pty, its controller (CROI_PA_PTY_CONTROL), sharing it.
    if let control = Startup.current.take(HandleType.info(HandleType.ptyControl)) {
      Terminal.current = Terminal(control: control)
    } else if !td_stdio_has(0, nil) && !td_stdio_has(1, nil),
      case .success(let input) = FDIO.open("/dev/cons", flags: OpenFlags.readOnly),
      case .success(let output) = FDIO.open("/dev/cons", flags: OpenFlags.writeOnly)
    {
      // On the console: no stdio, and a /dev/cons, its terminal for 0 to
      // 2, as Plan 9's init opens #c/cons (Terminal.swift).
      Terminal.current = Terminal(cons: input)
      fds[1] = FileStream(output, reads: false)
      fds[2] = FileStream(output, reads: false)
    }
    let shell = Rc(system: system, arguments: a.rest)
    shell.take(a, name: argv.first ?? "rc")
    shell.takeEnvironmentFiles()  // its /env (D81)
    shell.functions["sigexit"] = nil  // rcmain's `fn sigexit`: not one inherited
    // Plan 9's rcmain's, where the environment gave none.
    if (shell.variables["home"] ?? []).isEmpty { shell.variables["home"] = ["/"] }
    if a.flags.contains("p") { shell.variables["path"] = ["/bin"] }
    // -l: a login rc, Plan 9's profile first.
    if a.flags.contains("l") { shell.run(". -q /lib/profile", fds: fds) }
    // Its end, as rcmain's: sigexit unless rc exited already.
    shell.interactive = a.flags.contains("i")
    if let c = a.command {
      if shell.run(c, fds: fds) { shell.end() }
      exits(shell)
    }
    if let file = a.rest.first, !a.flags.contains("i") {
      if shell.run(file: file, arguments: Array(a.rest.dropFirst()), fds: fds) { shell.end() }
      exits(shell)
    }
    // Lines from stdin: prompted when interactive (-i, or a terminal's,
    // `TERM` set, without -I), as rcmain has it.
    let terminal = shell.variables["TERM"] != nil
    let interactive = a.flags.contains("i") || ((terminal || Terminal.current != nil) && !a.flags.contains("I"))
    shell.interactive = interactive
    // A starting directory (M6l: Terminal opened here by Tracker's add-on).
    if let d = shell.variables["PWD"]?.first, !d.isEmpty { _ = system.changeDirectory(d) }
    shell.variables["prompt"] = ["% ", "\t"]
    var pending: [UInt8] = []
    var text = ""
    let input = fds[0]!
    var told = ""
    reading: while true {
      if terminal && text.isEmpty && system.directory != told {
        told = system.directory
        fds[1]!.write(Array("\u{1B}]7;file://".utf8) + percentEncoded(told) + Array("\u{1B}\\".utf8))
      }
      let prompt = shell.variables["prompt"] ?? ["% "]
      let p = text.isEmpty || prompt.count < 2 ? (prompt.first ?? "") : prompt[1]
      if interactive { fds[1]!.write(Array(p.utf8)) }
      // A line.
      var line: [UInt8]? = nil
      while line == nil {
        if let nl = pending.firstIndex(of: 0x0A) {
          line = Array(pending[...nl])
          pending.removeSubrange(...nl)
        } else if let more = Terminal.current?.read(notes: true) ?? input.read() {
          guard more.isEmpty else {
            pending += more
            continue
          }
          // Notes came while rc waited (on a pty): an interrupt drops the
          // line being typed, as 9front's Xrdcmds does (with no newline of
          // rc's: the pty has echoed ^C and one).
          switch shell.takeNotes(fds: fds) {
          case .exit: exits(shell)
          case .interrupted:
            (pending, text) = ([], "")
            continue reading
          case .none: break
          }
        } else {
          shell.end()  // the end of input
          exits(shell)
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
      if !shell.run(script, fds: fds) { exits(shell) }
    }
  }
}

/// Ends rc with its status as its exit string, as 9front's rc does
/// (D72): none if it is true.
func exits(_ shell: Rc) -> Never {
  let status = shell.succeeded ? "" : (shell.status.isEmpty ? "false" : shell.status)
  status.withCString { td_exits($0) }
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
