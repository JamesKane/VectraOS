// SPDX-License-Identifier: BSD-3-Clause

// bin/ls, cat, mkdir, rm, mv, cp, touch (M6m part m5): the shell's file
// commands, one program each from this file, its command its name (rc's
// argv[0]); the work is Commands' (lib/Commands.swift), from rc's
// directory (PWD), in the namespace its Startup gives (D65). Output goes
// to stdout as it comes, complaints to stderr, and its exit string is
// the command's (td_exits, D72). Tier 1, as rc is.

import Commands
import LibSys
import Node
import Sys
import TDFloor
import TDNative
import VectraOSLibc

@main struct Command {
  static func main() {
    let start = Startup.current
    guard let ns = try? Namespace(start), let argv0 = start.args.first else {
      print("no namespace")
      exit(1)
    }
    let name = argv0.split(separator: "/").last.map(String.init) ?? argv0
    let io = Commands.IO(out: { bytes in
      unsafe bytes.withUnsafeBytes { b in
        if let p = unsafe b.baseAddress, unsafe !b.isEmpty { unsafe td_stdout_write(p, b.count) }
      }
      td_stdout_flush()
    }, err: { line in
      let bytes = Array((line + "\n").utf8)
      unsafe bytes.withUnsafeBytes { b in if let p = unsafe b.baseAddress { unsafe td_stderr_write(p, b.count) } }
    }, stdin: {
      var buffer = [UInt8](repeating: 0, count: 4096)
      let n = unsafe buffer.withUnsafeMutableBytes { unsafe td_stdin_read($0.baseAddress!, $0.count) }
      return n > 0 ? Array(buffer[..<n]) : nil
    }, descriptor: { fd in
      // fd 0, or one it was started with that it reads (D46).
      var reads = false
      guard fd == 0 || (unsafe td_stdio_has(fd, &reads) && reads) else { return nil }
      var buffer = [UInt8](repeating: 0, count: 4096)
      let n = unsafe buffer.withUnsafeMutableBytes { unsafe td_stdio_read_fd(fd, $0.baseAddress!, UInt64($0.count)) }
      return n > 0 ? Array(buffer[..<Int(n)]) : nil
    })
    let status = Commands.run(name, Array(start.args.dropFirst()), pwd: start.value("PWD") ?? "/", in: ns, io)
    unsafe status.withCString { unsafe td_exits($0) }
  }
}
