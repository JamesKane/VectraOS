// SPDX-License-Identifier: BSD-3-Clause

// The shell's file commands (M6m part m5: a usable session; N1's devsh
// had them, and "the shell is M6's"): ls, cat, mkdir, rm, mv, cp and
// touch, each a small program (shell/commands/Main.swift, by its name)
// over this library. Paths are rc's: absolute, or from its directory
// (`PWD`, which rc gives each program it starts). Each command works
// through the program's namespace and returns its output and complaints,
// so its tests run hosted over an fs service. Tier 0.

import Fs
import IPC
import Node
import Sys

public enum Commands {
  /// What a command said, and its exit status (0, or 1 if anything
  /// failed: the rest still ran, as Unix's do).
  public struct Result: Equatable, Sendable {
    public var output: [UInt8] = []
    public var errors: [String] = []
    public var status: Int32 { errors.isEmpty ? 0 : 1 }
  }

  public static let names = ["ls", "cat", "mkdir", "rm", "mv", "cp", "touch"]

  /// Runs command `name` with `args`, from directory `pwd`; `stdin`, if
  /// given, reads the next bytes of its input (nil at its end), and
  /// `descriptor` the next of descriptor N's, for a path /dev/fd/N (rc's
  /// <{}).
  public static func run(_ name: String, _ args: [String], pwd: String, in ns: Namespace,
                         stdin: (() -> [UInt8]?)? = nil, descriptor: ((Int32) -> [UInt8]?)? = nil) -> Result {
    var r = Result()
    let (flags, paths) = options(args)
    let at = paths.map { resolve($0, from: pwd) }
    func say(_ s: String) { r.output += Array(s.utf8) }
    func complain(_ s: String) { r.errors.append(name + ": " + s) }
    switch name {
    case "ls":
      let long = flags.contains("l")
      let targets = at.isEmpty ? [resolve(".", from: pwd)] : at
      for (i, path) in targets.enumerated() {
        guard let s = stat(path, ns) else {
          complain("\(paths.isEmpty ? "." : paths[i]): not found")
          continue
        }
        if s.qid.kind != .directory {
          say(line(s, long: long, name: paths[i]))
          continue
        }
        guard let entries = try? ns.list(path) else {
          complain("\(path): can't list")
          continue
        }
        if targets.count > 1 { say((i > 0 ? "\n" : "") + (paths[i]) + ":\n") }
        for e in entries.sorted(by: { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }) {
          say(line(e, long: long, name: e.name))
        }
      }
    case "cat":
      // No files: stdin, to its end (9front's cat).
      if at.isEmpty, let stdin {
        while let bytes = stdin() { r.output += bytes }
      }
      for (i, path) in at.enumerated() {
        if paths[i].hasPrefix("/dev/fd/"), let fd = Int32(paths[i].dropFirst(8)), let descriptor {
          while let bytes = descriptor(fd) { r.output += bytes }
          continue
        }
        guard var n = try? ns.open(path), let bytes = try? n.readAll() else {
          complain("\(paths[i]): can't read")
          continue
        }
        r.output += bytes
      }
    case "mkdir":
      if at.isEmpty { complain("usage: mkdir [-p] DIR...") }
      for (i, path) in at.enumerated() {
        if flags.contains("p") {
          var walked = ""
          for part in path.split(separator: "/") {
            walked += "/" + part
            if stat(walked, ns) == nil, (try? ns.create(walked, kind: .directory)) == nil {
              complain("\(paths[i]): can't make \(walked)")
              break
            }
          }
        } else if stat(path, ns) != nil {
          complain("\(paths[i]): exists")
        } else if (try? ns.create(path, kind: .directory)) == nil {
          complain("\(paths[i]): can't make it")
        }
      }
    case "rm":
      if at.isEmpty { complain("usage: rm [-r] PATH...") }
      for (i, path) in at.enumerated() {
        guard let s = stat(path, ns) else {
          complain("\(paths[i]): not found")
          continue
        }
        if s.qid.kind == .directory && flags.contains("r") {
          if !removeTree(path, ns) { complain("\(paths[i]): can't remove all of it") }
        } else if !remove(path, ns) {
          complain("\(paths[i]): " + (s.qid.kind == .directory ? "a directory with something in it (rm -r)" : "can't remove it"))
        }
      }
    case "mv":
      guard at.count >= 2 else {
        complain("usage: mv FROM... TO")
        break
      }
      let to = at[at.count - 1]
      let into = at.count > 2 || stat(to, ns)?.qid.kind == .directory
      for (i, from) in at.dropLast().enumerated() {
        let target = into ? to + "/" + last(from) : to
        if let why = move(from, to: target, ns) { complain("\(paths[i]): \(why)") }
      }
    case "cp":
      guard at.count >= 2 else {
        complain("usage: cp FROM... TO")
        break
      }
      let to = at[at.count - 1]
      let into = at.count > 2 || stat(to, ns)?.qid.kind == .directory
      for (i, from) in at.dropLast().enumerated() {
        guard var src = try? ns.open(from), stat(from, ns)?.qid.kind == .file, let bytes = try? src.readAll() else {
          complain("\(paths[i]): can't read (a file, not a directory)")
          continue
        }
        let target = into ? to + "/" + last(from) : to
        if !write(bytes, to: target, ns) { complain("\(paths[i]): can't write \(target)") }
      }
    case "touch":
      if at.isEmpty { complain("usage: touch FILE...") }
      for (i, path) in at.enumerated() where stat(path, ns) == nil {
        if (try? ns.create(path, kind: .file)) == nil { complain("\(paths[i]): can't make it") }
      }
    default:
      complain("not a command")
    }
    return r
  }

  /// Leading `-xy` words as flags, the rest as paths (`--` ends flags).
  static func options(_ args: [String]) -> (flags: [Character], paths: [String]) {
    var flags: [Character] = []
    var i = 0
    while i < args.count, args[i].hasPrefix("-"), args[i].utf8.count > 1 {
      if args[i] == "--" {
        i += 1
        break
      }
      flags += args[i].dropFirst()
      i += 1
    }
    return (flags, Array(args[i...]))
  }

  /// `path` made absolute from `pwd`, `.` and `..` taken out.
  public static func resolve(_ path: String, from pwd: String) -> String {
    let whole = path.hasPrefix("/") ? path : pwd + "/" + path
    var parts: [Substring] = []
    for p in whole.split(separator: "/") {
      if p == "." { continue }
      if p == ".." {
        if !parts.isEmpty { parts.removeLast() }
        continue
      }
      parts.append(p)
    }
    return "/" + parts.joined(separator: "/")
  }

  static func last(_ path: String) -> String { path.split(separator: "/").last.map(String.init) ?? path }

  static func stat(_ path: String, _ ns: Namespace) -> NodeIPC.Stat? {
    guard var n = try? ns.open(path) else { return nil }
    return try? n.stat(fields: NodeIPC.Fields.all)
  }

  static func remove(_ path: String, _ ns: Namespace) -> Bool {
    guard var n = try? ns.open(path) else { return false }
    return (try? n.remove()) != nil
  }

  static func removeTree(_ path: String, _ ns: Namespace) -> Bool {
    var ok = true
    for e in (try? ns.list(path)) ?? [] {
      let child = path + "/" + e.name
      if !(e.qid.kind == .directory ? removeTree(child, ns) : remove(child, ns)) { ok = false }
    }
    return remove(path, ns) && ok
  }

  /// A file at `path` holding `bytes` (one already there is replaced).
  static func write(_ bytes: [UInt8], to path: String, _ ns: Namespace) -> Bool {
    if let s = stat(path, ns) {
      guard s.qid.kind == .file, remove(path, ns) else { return false }
    }
    guard var f = try? ns.create(path, kind: .file) else { return false }
    var at = 0
    while at < bytes.count {
      let n = min(NodeIPC.maxIO, bytes.count - at)
      guard (try? f.write(offset: UInt64(at), Array(bytes[at..<(at + n)]))) != nil else { return false }
      at += n
    }
    return true
  }

  /// Moves `from` to `to` on one volume (its fs Directory's rename);
  /// nil, or why not.
  static func move(_ from: String, to: String, _ ns: Namespace) -> String? {
    guard stat(from, ns) != nil else { return "not found" }
    guard let a = try? ns.locate(from), let b = try? ns.locate(to), a.mount == b.mount else {
      return "can't move it to another volume (cp, then rm)"
    }
    guard let root = try? ns.connect(a.mount) else { return "can't reach its volume" }
    var d = FsIPC.DirectoryClient(channel: root)
    do throws(IPCError<FsIPC.FsError>) {
      try d.rename(a.rest.joined(separator: "/"), to: b.rest.joined(separator: "/"))
      return nil
    } catch {
      return "can't move it (\(error))"
    }
  }

  /// A listing's line: the name (a directory's with "/"), or, long, its
  /// kind, size, date (UTC) and name.
  static func line(_ s: NodeIPC.Stat, long: Bool, name: String) -> String {
    let shown = name + (s.qid.kind == .directory ? "/" : "")
    guard long else { return shown + "\n" }
    let kind = s.qid.kind == .directory ? "d" : (s.qid.kind == .service ? "s" : "-")
    var size = String(s.size)
    while size.utf8.count < 10 { size = " " + size }
    return kind + " " + size + " " + date(s.modified) + " " + shown + "\n"
  }

  /// Nanoseconds since the epoch as "YYYY-MM-DD HH:MM" (UTC).
  public static func date(_ ns: Int64) -> String {
    let seconds = ns >= 0 ? ns / 1_000_000_000 : (ns - 999_999_999) / 1_000_000_000
    var days = seconds >= 0 ? seconds / 86400 : (seconds - 86399) / 86400
    let rest = seconds - days * 86400
    // Howard Hinnant's civil_from_days.
    days += 719_468
    let era = (days >= 0 ? days : days - 146_096) / 146_097
    let doe = days - era * 146_097
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    let mp = (5 * doy + 2) / 153
    let day = doy - (153 * mp + 2) / 5 + 1
    let month = mp < 10 ? mp + 3 : mp - 9
    let year = yoe + era * 400 + (month <= 2 ? 1 : 0)
    func two(_ v: Int64) -> String { v < 10 ? "0\(v)" : "\(v)" }
    return "\(year)-\(two(month))-\(two(day)) \(two(rest / 3600)):\(two(rest % 3600 / 60))"
  }
}
