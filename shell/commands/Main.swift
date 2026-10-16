// SPDX-License-Identifier: BSD-3-Clause

// bin/ls, cat, mkdir, rm, mv, cp, touch (M6m part m5): the shell's file
// commands, one program each from this file, its command its name (rc's
// argv[0]); the work is Commands' (lib/Commands.swift), from rc's
// directory (PWD), in the namespace its Startup gives (D65). Output goes
// to stdout as bytes, complaints to stderr. Tier 1, as rc is.

import Commands
import LibSys
import Node
import Sys
import TDFloor
import VectraOSLibc

@main struct Command {
  static func main() {
    let start = Startup.current
    guard let ns = try? Namespace(start), let argv0 = start.args.first else {
      print("no namespace")
      exit(1)
    }
    let name = argv0.split(separator: "/").last.map(String.init) ?? argv0
    let r = Commands.run(name, Array(start.args.dropFirst()), pwd: start.value("PWD") ?? "/", in: ns)
    unsafe r.output.withUnsafeBytes { b in
      if let p = unsafe b.baseAddress, unsafe !b.isEmpty { unsafe td_stdout_write(p, b.count) }
    }
    td_stdout_flush()
    for e in r.errors {
      let line = Array((e + "\n").utf8)
      unsafe line.withUnsafeBytes { b in if let p = unsafe b.baseAddress { unsafe td_stderr_write(p, b.count) } }
    }
    exit(r.status)
  }
}
