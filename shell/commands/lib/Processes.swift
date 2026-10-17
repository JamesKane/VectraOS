// SPDX-License-Identifier: BSD-3-Clause

// ps and kill over /proc (D79), as 9front's: ps(1) (sys/src/cmd/ps.c), a
// line a process from its /proc/N/status, by pid; kill(1) (rc/bin/kill),
// the rc commands that would kill each process named, to pipe into rc.
// 9front's kill is an rc script over sed, which this system doesn't have
// yet, so it is a command here, printing what the script prints.

import Node

extension Command {
  // MARK: ps

  func ps(_ args: [String]) -> String {
    let a = Flags(args)  // ps.c's ARGBEGIN ignores flags it doesn't know
    let entries: [NodeIPC.Stat]
    do throws(NamespaceError) {
      entries = try ns.list("/proc")
    } catch {
      return fatal("/proc: " + Commands.why(error, "/proc"))
    }
    guard !entries.isEmpty else {
      complain("ps: empty directory /proc")
      return "empty"
    }
    let pids = entries.map { $0.name }.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }
    for pid in pids { if let line = Self.psLine(pid, ns: ns, flags: a) { io.out(Array(line.utf8)) } }
    return ""
  }

  /// One process's line, as ps.c prints it; nil if its status can't be read.
  static func psLine(_ pid: String, ns: Namespace, flags: Flags) -> String? {
    guard var f = try? ns.open("/proc/\(pid)/status"), let bytes = try? f.readAll() else { return nil }
    let argv = bytes.split(whereSeparator: { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A }).map {
      String(decoding: $0, as: UTF8.self)
    }
    guard argv.count >= 12 else { return nil }
    func number(_ s: String) -> UInt64 { UInt64(s) ?? 0 }
    let utime = number(argv[3]) / 1000, stime = number(argv[4]) / 1000, rtime = number(argv[5]) / 1000
    let size = number(argv[9])
    func two(_ n: UInt64) -> String { n < 10 ? "0\(n)" : "\(n)" }
    let nbuf = flags.has("n") ? " " + Commands.padLeft("?", 8) : ""
    var rbuf1 = ""
    if flags.has("r") {
      let r = rtime >= 86400 ? " \(rtime / 86400):\(two(rtime / 3600 % 24)):\(two(rtime / 60 % 60)):\(two(rtime % 60))"
        : rtime >= 3600 ? " \(rtime / 3600):\(two(rtime / 60 % 60)):\(two(rtime % 60))"
        : " \(rtime / 60):\(two(rtime % 60))"
      rbuf1 = Commands.padLeft(r, 12)
    }
    let pbuf = flags.has("p")
      ? " " + Commands.padLeft(String(number(argv[10])), 2) + " " + Commands.padLeft(String(number(argv[11])), 2) : ""
    let state = String(decoding: Array(argv[2].utf8.prefix(8)), as: UTF8.self)
    var line = Commands.padRight(argv[1], 10) + " " + Commands.padLeft(pid, 8) + nbuf + rbuf1 + " "
      + Commands.padLeft(String(utime / 60), 4) + ":" + two(utime % 60) + " "
      + Commands.padLeft(String(stime / 60), 3) + ":" + two(stime % 60) + " " + pbuf + " "
      + Commands.padLeft(String(size), 7) + "K " + Commands.padRight(state, 8) + " "
    if flags.has("a"), var g = try? ns.open("/proc/\(pid)/args"), let args = try? g.readAll(), !args.isEmpty {
      line += String(decoding: args.map { $0 == 0x0A ? 0x20 : $0 }, as: UTF8.self)
    } else {
      line += argv[0]
    }
    return line + "\n"
  }

  // MARK: kill

  /// For each name, each process of it: `@{echo kill>/proc/PID/note} #
  /// NAME`, as rc/bin/kill's sed makes of ps's lines.
  func kill(_ args: [String]) -> String {
    let none = Flags([])
    let pids = ((try? ns.list("/proc")) ?? []).map { $0.name }.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }
    let lines = pids.compactMap { Self.psLine($0, ns: ns, flags: none) }
    for name in args {
      for line in lines {
        let words = line.split(separator: " ")
        guard words.count >= 2, words.last.map({ $0.utf8.elementsEqual("\(name)\n".utf8) }) == true else { continue }
        io.out(Array("@{echo kill>/proc/\(words[1])/note} # \(name)\n".utf8))
      }
    }
    return ""
  }
}

extension Commands {
  /// `s` right-aligned in `width` columns (printf's %Ns).
  static func padLeft(_ s: String, _ width: Int) -> String {
    String(repeating: " ", count: max(0, width - s.utf8.count)) + s
  }

  /// `s` left-aligned in `width` columns (%-Ns).
  static func padRight(_ s: String, _ width: Int) -> String {
    s + String(repeating: " ", count: max(0, width - s.utf8.count))
  }
}
