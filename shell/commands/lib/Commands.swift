// SPDX-License-Identifier: BSD-3-Clause

// The shell's file commands (M6m part m5): ls, cat, mkdir, rm, mv, cp and
// touch, the manual's man, lookman and sig (ManPages.swift), and sleep, each a small program (shell/commands/Main.swift, by its name)
// over this library, each as 9front's (sys/src/cmd/NAME.c): its flags
// (ARGBEGIN's; any other a usage message), its messages (an error's
// words Plan 9's, `%r`), and its exit string (Plan 9's exits, D72: "" if
// it succeeded). Paths are rc's: absolute, or from its directory (`PWD`,
// which rc gives each program it starts). Each command works through the
// program's namespace and streams its output as it goes, so its tests
// run hosted over a NodeTree. Tier 1, as rc is.
//
// What Node doesn't have is left out: no modes, owners or devices (ls -l
// shows a directory as d-rwxr-xr-x and a file as --rw-r--r--, its owner
// and group `none`), and no access times (-u is the modified time).

import Fs
import IPC
import Node
import Sys

public enum Commands {
  /// Where a command's bytes go and come from: `out` its output, as it
  /// goes; `err` each line it complains with (no newline); `stdin` the
  /// next bytes of its input (nil at its end); `descriptor` the next of
  /// descriptor N's, for a path /dev/fd/N (rc's <{}).
  public struct IO {
    public var out: ([UInt8]) -> Void
    public var err: (String) -> Void
    public var stdin: (() -> [UInt8]?)?
    public var descriptor: ((Int32) -> [UInt8]?)?

    public init(out: @escaping ([UInt8]) -> Void, err: @escaping (String) -> Void, stdin: (() -> [UInt8]?)? = nil,
                descriptor: ((Int32) -> [UInt8]?)? = nil)
    {
      self.out = out
      self.err = err
      self.stdin = stdin
      self.descriptor = descriptor
    }
  }

  /// What a command said, collected, and its exit string.
  public struct Result: Equatable, Sendable {
    public var output: [UInt8] = []
    public var errors: [String] = []
    public var status = ""
  }

  public static let names = ["ls", "cat", "mkdir", "rm", "mv", "cp", "touch", "man", "lookman", "sig", "ps", "kill",
                              "sleep"]

  /// Runs command `name` with `args` from directory `pwd`: its exit string.
  public static func run(_ name: String, _ args: [String], pwd: String, in ns: Namespace, _ io: IO) -> String {
    let c = Command(name: name, pwd: pwd, ns: ns, io: io)
    switch name {
    case "ls": return c.ls(args)
    case "cat": return c.cat(args)
    case "mkdir": return c.mkdir(args)
    case "rm": return c.rm(args)
    case "mv": return c.mv(args)
    case "cp": return c.cp(args)
    case "touch": return c.touch(args)
    case "man": return c.man(args)
    case "lookman": return c.lookman(args)
    case "sig": return c.sig(args)
    case "ps": return c.ps(args)
    case "kill": return c.kill(args)
    case "sleep": return c.sleep(args)
    default:
      io.err(name + ": not a command")
      return "not a command"
    }
  }

  /// The same, what it said collected.
  public static func run(_ name: String, _ args: [String], pwd: String, in ns: Namespace,
                         stdin: (() -> [UInt8]?)? = nil, descriptor: ((Int32) -> [UInt8]?)? = nil) -> Result {
    final class Box { var r = Result() }
    let box = Box()
    let io = IO(out: { box.r.output += $0 }, err: { box.r.errors.append($0) }, stdin: stdin, descriptor: descriptor)
    let status = run(name, args, pwd: pwd, in: ns, io)
    box.r.status = status
    return box.r
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

  /// Plan 9's %q (quotefmtinstall's, rc's rules): `s` as it is, or in
  /// single quotes (a quote doubled) if it is empty or holds a space, a
  /// control character or one of rc's; `always` quotes it anyway (%#q).
  public static func quote(_ s: String, always: Bool = false) -> String {
    let special = Array("`^#*[]=|\\?${}()'<>&;".utf8)
    let needs = always || s.isEmpty || s.utf8.contains { $0 <= 0x20 || special.contains($0) }
    guard needs else { return s }
    return "'" + s.split(separator: "'", omittingEmptySubsequences: false).joined(separator: "''") + "'"
  }

  /// A Node error's words, as Plan 9's kernel and file servers say them; a
  /// walk's (nothing there, or not a directory) names `path`, as 9front's
  /// namec does.
  public static func why(_ e: NamespaceError, _ path: String) -> String {
    switch e {
    case .notFound, .node(.notFound): "file does not exist: " + quote(path, always: true)
    case .node(.notDirectory): "not a directory: " + quote(path, always: true)
    case .badPath, .node(.badName): "bad character in file name"
    case .node(.tooManyNames): "file name too long"
    case .node(.isDirectory): "file is a directory"
    case .node(.exists): "file already exists"
    case .node(.denied), .node(.unsupported), .cantCreate: "permission denied"
    case .node(.notEmpty): "directory not empty"
    case .node(.invalid): "bad arg in system call"
    case .sealed: "mount/attach disallowed"
    case .unionFull: "too many mounts"
    case .transport: "i/o on hungup channel"
    case .node(.io), .node(.tooManyOps), .wire: "i/o error"
    }
  }

  /// Plan 9's ls time (asciitime): "Oct 16 15:17", or "Oct 16  2026" for
  /// one more than six months before `now` or a day after it (UTC).
  public static func asciitime(_ ns: Int64, now: Int64) -> String {
    let t = seconds(ns)
    let n = seconds(now)
    let (year, month, day, rest) = civil(t)
    let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    func two(_ v: Int64, _ pad: String) -> String { v < 10 ? pad + "\(v)" : "\(v)" }
    let date = months[Int(month - 1)] + " " + two(day, " ")
    if t < n - 180 * 24 * 60 * 60 || n + 24 * 60 * 60 < t {
      var y = String(year)
      while y.utf8.count < 5 { y = " " + y }
      return date + " " + y
    }
    return date + " " + two(rest / 3600, "0") + ":" + two(rest % 3600 / 60, "0")
  }

  static func seconds(_ ns: Int64) -> Int64 { ns >= 0 ? ns / 1_000_000_000 : (ns - 999_999_999) / 1_000_000_000 }

  /// Seconds since the epoch as year, month, day and the seconds into it
  /// (Howard Hinnant's civil_from_days).
  static func civil(_ seconds: Int64) -> (Int64, Int64, Int64, Int64) {
    var days = seconds >= 0 ? seconds / 86400 : (seconds - 86399) / 86400
    let rest = seconds - days * 86400
    days += 719_468
    let era = (days >= 0 ? days : days - 146_096) / 146_097
    let doe = days - era * 146_097
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    let mp = (5 * doy + 2) / 153
    let day = doy - (153 * mp + 2) / 5 + 1
    let month = mp < 10 ? mp + 3 : mp - 9
    return (yoe + era * 400 + (month <= 2 ? 1 : 0), month, day, rest)
  }
}

/// Plan 9's ARGBEGIN over a command's arguments: each word that starts
/// with `-` (not `-` alone) is flags, until `--` (taken) or a word that
/// isn't; a flag in `valued` takes the rest of its word, or the next word.
struct Flags {
  var flags: [(flag: Character, value: String?)] = []
  var rest: [String] = []

  init(_ args: [String], valued: String = "") {
    var i = 0
    words: while i < args.count, args[i].hasPrefix("-"), args[i].utf8.count > 1 {
      if args[i] == "--" {
        i += 1
        break
      }
      var chars = Array(args[i].dropFirst())[...]
      i += 1
      while let c = chars.popFirst() {
        guard valued.contains(c) else {
          flags.append((c, nil))
          continue
        }
        if !chars.isEmpty {
          flags.append((c, String(chars)))
        } else if i < args.count {
          flags.append((c, args[i]))
          i += 1
        } else {
          flags.append((c, nil))
        }
        continue words
      }
    }
    rest = Array(args[i...])
  }

  /// The first flag not among `known`, if any.
  func unknown(_ known: String) -> Character? { flags.first { !known.contains($0.flag) }?.flag }
  func has(_ c: Character) -> Bool { flags.contains { $0.flag == c } }
  func value(_ c: Character) -> String?? { flags.last { $0.flag == c }.map { $0.value } }
}

/// One command's run.
struct Command {
  let name: String
  let pwd: String
  let ns: Namespace
  let io: Commands.IO

  func at(_ path: String) -> String { Commands.resolve(path, from: pwd) }
  func complain(_ s: String) { io.err(s) }
  /// A usage message (Usage, from the command's page) said, and its exit string.
  func usage(_ lines: [String]) -> String {
    for l in lines { io.err(l) }
    return "usage"
  }

  func stat(_ path: String) throws(NamespaceError) -> NodeIPC.Stat {
    var n = try ns.open(at(path))
    do throws(NodeIPC.NodeClient.Failure) {
      return try n.stat(fields: NodeIPC.Fields.all)
    } catch {
      throw NamespaceError(error)
    }
  }

  func remove(_ path: String) throws(NamespaceError) {
    var n = try ns.open(at(path))
    do throws(NodeIPC.NodeClient.Failure) {
      try n.remove()
    } catch {
      throw NamespaceError(error)
    }
  }

  /// Plan 9's create(path, OWRITE): a file there already is cut to
  /// nothing and kept; else a new one.
  func create(_ path: String) throws(NamespaceError) -> NodeIPC.NodeClient {
    if let s = try? stat(path), s.qid.kind == .file {
      try ns.wstat(at(path), NodeIPC.Wstat(size: 0))
      return try ns.open(at(path))
    }
    return try ns.create(at(path), kind: .file)
  }

  /// Copies `from` to `to` a chunk at a time, through NodeFile (D103): on
  /// the files' rings once they move bulk, its writes behind waited for at
  /// the end; nil, or the message.
  func copy(_ from: consuming NodeIPC.NodeClient, _ to: consuming NodeIPC.NodeClient, _ fromName: String,
            _ toName: String) -> String? {
    var source = NodeFile(from), target = NodeFile(to)
    var offset: UInt64 = 0
    while true {
      let chunk: [UInt8]
      do throws(NodeIPC.NodeClient.Failure) {
        chunk = try source.read(offset: offset, max: NodeFile.preferredIO)
      } catch {
        return "error reading \(fromName): " + Commands.why(NamespaceError(error), fromName)
      }
      do throws(NodeIPC.NodeClient.Failure) {
        if chunk.isEmpty {
          try target.finish()
          return nil
        }
        try target.write(offset: offset, chunk)
      } catch {
        return "error writing \(toName): " + Commands.why(NamespaceError(error), toName)
      }
      offset += UInt64(chunk.count)
    }
  }

  /// The same node: the same qid in the same mount (9front's samefile,
  /// its dev and type the mount).
  func same(_ a: NodeIPC.Stat, _ aPath: String, _ bPath: String) -> Bool {
    guard let b = try? stat(bPath), let ma = try? ns.locate(at(aPath)), let mb = try? ns.locate(at(bPath)) else {
      return false
    }
    return a.qid == b.qid && NodeIPC.same(ma.mount, mb.mount)
  }

  // MARK: ls

  /// A listed entry, and the name it's shown under (9front's NDir).
  struct Entry {
    var stat: NodeIPC.Stat
    var prefix: String?
  }

  func ls(_ args: [String]) -> String {
    let a = Flags(args)
    if a.unknown("FdlmnpqQrstTu") != nil { return usage(Usage.ls) }
    let now = Clock.realtime()
    var pending: [Entry] = []
    var failed = false
    func output() {
      var list = pending
      pending = []
      if !a.has("n") { list = sorted(list, a) }
      var text = ""
      let widths = Widths(list.map { $0.stat }, a)
      for e in list {
        var shown = e.stat.name
        if !a.has("p"), let p = e.prefix { shown = (p == "/" ? "" : p) + "/" + e.stat.name }
        text += format(e.stat, shown, a, widths, now: now)
      }
      if !text.isEmpty { io.out(Array(text.utf8)) }
    }
    func one(_ arg: String, multi: Bool) {
      let s = clean(arg)
      let st: NodeIPC.Stat
      do throws(NamespaceError) {
        st = try stat(s)
      } catch {
        complain("ls: \(s): " + Commands.why(error, s))
        failed = true
        return
      }
      if st.qid.kind == .directory && !a.has("d") {
        output()
        let entries: [NodeIPC.Stat]
        do throws(NamespaceError) {
          entries = try ns.list(at(s))
        } catch {
          complain("ls: \(s): " + Commands.why(error, s))
          failed = true
          return
        }
        pending += entries.map { Entry(stat: $0, prefix: multi ? s : nil) }
        output()
      } else {
        // A file under its own name, or a directory's: what's before its
        // last "/" its prefix. (Mount points stat with no name.)
        var e = Entry(stat: st, prefix: nil)
        if let slash = s.utf8.lastIndex(of: 0x2F) {
          e.prefix = String(s[..<slash])
          if e.stat.name.isEmpty { e.stat.name = String(s[s.utf8.index(after: slash)...]) }
        } else if e.stat.name.isEmpty {
          e.stat.name = s
        }
        pending.append(e)
      }
    }
    if a.rest.isEmpty { one(".", multi: false) } else { for arg in a.rest { one(arg, multi: true) } }
    output()
    return failed ? "errors" : ""
  }

  /// 9front's xcleanname: slashes compressed, a trailing one dropped.
  func clean(_ name: String) -> String {
    var out: [UInt8] = []
    for b in name.utf8 where !(b == 0x2F && out.last == 0x2F) { out.append(b) }
    while out.count > 1 && out.last == 0x2F { out.removeLast() }
    return String(decoding: out, as: UTF8.self)
  }

  /// 9front's compar: by time (newest first) with -t, else by prefix and
  /// name as bytes; -r reverses.
  func sorted(_ list: [Entry], _ a: Flags) -> [Entry] {
    func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }
    func cmp(_ x: [UInt8], _ y: [UInt8]) -> Int {
      x.lexicographicallyPrecedes(y) ? -1 : (x == y ? 0 : 1)
    }
    let indexed = Array(list.enumerated())
    let ordered = indexed.sorted { l, r in
      let x = l.element
      let y = r.element
      var i: Int
      if a.has("t") {
        i = x.stat.modified > y.stat.modified ? -1 : (x.stat.modified < y.stat.modified ? 1 : 0)
      } else if let px = x.prefix, let py = y.prefix {
        i = cmp(bytes(px), bytes(py))
        if i == 0 { i = cmp(bytes(x.stat.name), bytes(y.stat.name)) }
      } else if let px = x.prefix {
        i = cmp(bytes(px), bytes(y.stat.name))
        if i == 0 { i = 1 }
      } else if let py = y.prefix {
        i = cmp(bytes(x.stat.name), bytes(py))
        if i == 0 { i = -1 }
      } else {
        i = cmp(bytes(x.stat.name), bytes(y.stat.name))
      }
      if i == 0 { i = l.offset < r.offset ? -1 : 1 }
      if a.has("r") { i = -i }
      return i < 0
    }
    return ordered.map { $0.element }
  }

  /// Column widths over a batch (9front's dowidths).
  struct Widths {
    var size = 0
    var version = 0
    var length = 0

    init(_ stats: [NodeIPC.Stat], _ a: Flags) {
      for s in stats {
        size = max(size, String((s.size + 1023) / 1024).utf8.count)
        version = max(version, String(s.qid.version).utf8.count)
        length = max(length, String(s.size).utf8.count)
      }
    }
  }

  func format(_ s: NodeIPC.Stat, _ name: String, _ a: Flags, _ w: Widths, now: Int64) -> String {
    func right(_ v: String, _ width: Int) -> String {
      var v = v
      while v.utf8.count < width { v = " " + v }
      return v
    }
    func hex(_ v: UInt64, _ digits: Int) -> String {
      var s = String(v, radix: 16)
      while s.utf8.count < digits { s = "0" + s }
      return s
    }
    let directory = s.qid.kind == .directory
    var line = ""
    if a.has("s") { line += right(String((s.size + 1023) / 1024), w.size) + " " }
    if a.has("m") { line += "[none] " }
    if a.has("q") {
      line += "(" + hex(s.qid.path, 16) + " " + right(String(s.qid.version), w.version) + " "
        + (directory ? "80" : "00") + ") "
    }
    if a.has("T") { line += "- " }
    if a.has("l") {
      line += (directory ? "d-rwxr-xr-x" : "--rw-r--r--") + " M 0 none none " + right(String(s.size), w.length) + " "
        + Commands.asciitime(s.modified, now: now) + " "
    }
    line += a.has("Q") ? name : Commands.quote(name)
    if a.has("F") && directory { line += "/" }
    return line + "\n"
  }

  // MARK: cat

  func cat(_ args: [String]) -> String {
    // No files: stdin, to its end.
    if args.isEmpty {
      if let stdin = io.stdin { while let bytes = stdin() { io.out(bytes) } }
      return ""
    }
    for f in args {
      if f.hasPrefix("/dev/fd/"), let fd = Int32(f.dropFirst(8)), let descriptor = io.descriptor {
        while let bytes = descriptor(fd) { io.out(bytes) }
        continue
      }
      var n: NodeIPC.NodeClient
      do throws(NamespaceError) {
        n = try ns.open(at(f))
      } catch {
        return fatal("can't open \(f): " + Commands.why(error, f))
      }
      var offset: UInt64 = 0
      while true {
        let chunk: [UInt8]
        do throws(NodeIPC.NodeClient.Failure) {
          chunk = try n.read(offset: offset, max: UInt32(NodeIPC.maxIO))
        } catch {
          return fatal("error reading \(f): " + Commands.why(NamespaceError(error), f))
        }
        if chunk.isEmpty { break }
        io.out(chunk)
        offset += UInt64(chunk.count)
      }
    }
    return ""
  }

  /// Plan 9's sysfatal: the message said, and its exit string.
  func fatal(_ message: String) -> String {
    complain(name + ": " + message)
    return message
  }

  // MARK: mkdir

  func mkdir(_ args: [String]) -> String {
    let a = Flags(args, valued: "m")
    let usage = Usage.mkdir
    if a.unknown("mp") != nil { return self.usage(usage) }
    if let m = a.value("m") {
      // Node keeps no modes: checked, as 9front's, and not kept.
      guard let m, let mode = UInt32(m, radix: 8), mode <= 0o777 else { return self.usage(usage) }
    }
    var failed = false
    func make(_ s: String) -> Bool {
      if (try? stat(s)) != nil {
        complain("mkdir: \(s) already exists")
        failed = true
        return false
      }
      do throws(NamespaceError) {
        _ = try ns.create(at(s), kind: .directory)
        return true
      } catch {
        complain("mkdir: can't create \(s): " + Commands.why(error, s))
        failed = true
        return false
      }
    }
    for s in a.rest {
      guard a.has("p") else {
        _ = make(s)
        continue
      }
      // Each prefix ending before a "/" after the first byte, then s.
      var prefixes: [String] = []
      let bytes = Array(s.utf8)
      for i in bytes.indices where i > 0 && bytes[i] == 0x2F { prefixes.append(String(decoding: bytes[..<i], as: UTF8.self)) }
      // Only those below the deepest that is there: a path a mount is
      // under (/mnt of /mnt/term) needn't stat itself.
      if (try? stat(s)) != nil { continue }
      if let there = prefixes.lastIndex(where: { (try? stat($0)) != nil }) { prefixes.removeFirst(there + 1) }
      var ok = true
      for p in prefixes {
        if !make(p) {
          ok = false
          break
        }
      }
      if ok && (try? stat(s)) == nil { _ = make(s) }
    }
    return failed ? "error" : ""
  }

  // MARK: rm

  func rm(_ args: [String]) -> String {
    let a = Flags(args)
    if a.unknown("rf") != nil { return usage(Usage.rm) }
    let quiet = a.has("f")
    var last = ""
    func err(_ f: String, _ e: NamespaceError) {
      guard !quiet else { return }
      last = Commands.why(e, f)
      complain("rm: \(f): " + last)
    }
    /// A directory with something in it: what's in it, then it.
    func rmdir(_ f: String) {
      let entries: [NodeIPC.Stat]
      do throws(NamespaceError) {
        entries = try ns.list(at(f))
      } catch {
        err(f, error)
        return
      }
      var directories: [String] = []
      for e in entries {
        let child = f + "/" + e.name
        do throws(NamespaceError) {
          try remove(child)
        } catch {
          if e.qid.kind == .directory { directories.append(child) } else { err(child, error) }
        }
      }
      for d in directories { rmdir(d) }
      do throws(NamespaceError) { try remove(f) } catch { err(f, error) }
    }
    for f in a.rest {
      do throws(NamespaceError) {
        try remove(f)
      } catch {
        if a.has("r"), let s = try? stat(f), s.qid.kind == .directory { rmdir(f) } else { err(f, error) }
      }
    }
    return last
  }

  // MARK: mv

  /// 9front's split: a path's directory and last name.
  func split(_ path: String) -> (dir: String, elem: String) {
    if let slash = path.utf8.lastIndex(of: 0x2F) {
      return (String(path[..<slash]), String(path[path.utf8.index(after: slash)...]))
    }
    if path == ".." { return ("..", ".") }
    return (".", path)
  }

  /// Plan 9's cleanname, as mv's prepass does.
  func cleanname(_ path: String) -> String {
    let rooted = path.hasPrefix("/")
    var parts: [Substring] = []
    for p in path.split(separator: "/") {
      if p == "." { continue }
      if p == "..", let last = parts.last, last != ".." {
        parts.removeLast()
        continue
      }
      if p == "..", rooted { continue }
      parts.append(p)
    }
    let joined = parts.joined(separator: "/")
    return rooted ? "/" + joined : (joined.isEmpty ? "." : joined)
  }

  func mv(_ args: [String]) -> String {
    guard args.count >= 2 else {
      _ = usage(Usage.mv)
      return "bad usage"
    }
    let names = args.map(cleanname)
    let last = names[names.count - 1]
    var todir: String
    var toelem: String?
    if let to = try? stat(last), to.qid.kind == .directory {
      if names.count == 2, let from = try? stat(names[0]), from.qid.kind == .directory {
        (todir, toelem) = split(last)  // mv dir1 dir2
      } else {
        todir = last  // mv file... dir
        toelem = nil
      }
    } else {
      (todir, toelem) = split(last)  // mv file1 file2
    }
    if names.count > 2 && toelem != nil {
      complain("mv: \(last) not a directory")
      return "bad usage"
    }
    var failed = false
    for from in names.dropLast() {
      switch move(from, todir: todir, toelem: toelem) {
      case .moved: break
      case .failed: failed = true
      case .fatal: return "mv"
      }
    }
    return failed ? "failure" : ""
  }

  enum Moved { case moved, failed, fatal }

  /// 9front's mv1: a rename (wstat) within its directory, else a copy and
  /// a remove. Between directories of one volume, the fs protocol's
  /// rename first, for a volume that speaks it.
  func move(_ from: String, todir: String, toelem given: String?) -> Moved {
    let dirb: NodeIPC.Stat
    do throws(NamespaceError) {
      dirb = try stat(from)
    } catch {
      complain("mv: can't stat \(from): " + Commands.why(error, from))
      return .failed
    }
    let (fromdir, fromelem) = split(from)
    let toelem = given ?? fromelem
    guard !toelem.isEmpty else {
      complain("mv: null last name element moving \(from)")
      return .failed
    }
    let toname = todir + "/" + toelem
    let directory = dirb.qid.kind == .directory
    func sameDir(_ a: String, _ b: String) -> Bool {
      if NodeIPC.same(a, b) || NodeIPC.same(at(a), at(b)) { return true }
      guard let s = try? stat(a) else { return false }
      return same(s, a, b)
    }
    if sameDir(fromdir, todir) {
      if same(dirb, from, toname) {
        complain("mv: \(from) and \(toname) are the same")
        return .failed
      }
      // The target goes first.
      if (try? stat(toname)) != nil {
        do throws(NamespaceError) {
          try remove(toname)
        } catch {
          complain("mv: can't remove \(toname): " + Commands.why(error, toname))
          return .fatal
        }
      }
      do throws(NamespaceError) {
        try ns.wstat(at(from), NodeIPC.Wstat(name: toelem))
        return .moved
      } catch {
        if directory {
          complain("mv: can't rename directory \(from): " + Commands.why(error, from))
          return .failed
        }
      }
    } else if let a = try? ns.locate(at(from)), let b = try? ns.locate(at(toname)), NodeIPC.same(a.mount, b.mount),
      let root = try? ns.connect(a.mount)
    {
      var d = FsIPC.DirectoryClient(channel: root)
      do throws(IPCError<FsIPC.FsError>) {
        try d.rename(a.rest.joined(separator: "/"), to: b.rest.joined(separator: "/"))
        return .moved
      } catch {}
    }
    // Renaming won't do: a copy.
    if directory {
      complain("mv: \(from) is a directory, not copied to \(toname)")
      return .failed
    }
    let src: NodeIPC.NodeClient
    do throws(NamespaceError) {
      src = try ns.open(at(from))
    } catch {
      complain("mv: can't open \(from): " + Commands.why(error, from))
      return .failed
    }
    let dst: NodeIPC.NodeClient
    do throws(NamespaceError) {
      dst = try create(toname)
    } catch {
      complain("mv: can't create \(toname): " + Commands.why(error, toname))
      return .failed
    }
    if let message = copy(src, dst, from, toname) {
      complain("mv: " + message)
      return .failed
    }
    try? ns.wstat(at(toname), NodeIPC.Wstat(modified: dirb.modified))  // its time, if it may be set
    do throws(NamespaceError) {
      try remove(from)
    } catch {
      complain("mv: can't remove \(from): " + Commands.why(error, from))
      return .failed
    }
    return .moved
  }

  // MARK: cp

  func cp(_ args: [String]) -> String {
    let a = Flags(args)
    guard a.unknown("gux") == nil, a.rest.count >= 2 else { return usage(Usage.cp) }
    let to = a.rest[a.rest.count - 1]
    let todir = (try? stat(to))?.qid.kind == .directory
    if a.rest.count > 2 && !todir {
      complain("cp: \(to) not a directory")
      return "bad usage"
    }
    var failed = false
    for from in a.rest.dropLast() {
      var target = to
      if todir { target = to + "/" + (from.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? from) }
      let dirb: NodeIPC.Stat
      do throws(NamespaceError) {
        dirb = try stat(from)
      } catch {
        complain("cp: can't stat \(from): " + Commands.why(error, from))
        failed = true
        continue
      }
      if dirb.qid.kind == .directory {
        complain("cp: \(from) is a directory")
        failed = true
        continue
      }
      if same(dirb, from, target) {
        complain("cp: \(from) and \(target) are the same file")
        failed = true
        continue
      }
      let src: NodeIPC.NodeClient
      do throws(NamespaceError) {
        src = try ns.open(at(from))
      } catch {
        complain("cp: can't open \(from): " + Commands.why(error, from))
        failed = true
        continue
      }
      let dst: NodeIPC.NodeClient
      do throws(NamespaceError) {
        dst = try create(target)
      } catch {
        complain("cp: can't create \(target): " + Commands.why(error, target))
        failed = true
        continue
      }
      if let message = copy(src, dst, from, target) {
        complain("cp: " + message)
        failed = true
        continue
      }
      // -x keeps its time (Node keeps no mode); -g and -u, its group and
      // owner, which Node doesn't have.
      if a.has("x") {
        do throws(NamespaceError) {
          try ns.wstat(at(target), NodeIPC.Wstat(modified: dirb.modified))
        } catch {
          complain("cp: warning: can't wstat \(target): " + Commands.why(error, target))
        }
      }
    }
    return failed ? "errors" : ""
  }

  // MARK: touch

  func touch(_ args: [String]) -> String {
    let a = Flags(args, valued: "t")
    let usage = Usage.touch
    if a.unknown("ct") != nil || a.rest.isEmpty { return self.usage(usage) }
    var now = Clock.realtime() / 1_000_000_000
    if let t = a.value("t") {
      guard let t, let v = Self.strtoul(t) else { return self.usage(usage) }
      now = v
    }
    let change = NodeIPC.Wstat(modified: now * 1_000_000_000)
    var failed = 0
    for f in a.rest {
      do throws(NamespaceError) {
        try ns.wstat(at(f), change)
        continue
      } catch {
        if a.has("c") {
          complain("touch: \(f): cannot wstat: " + Commands.why(error, f))
          failed += 1
          continue
        }
      }
      do throws(NamespaceError) {
        _ = try ns.create(at(f), kind: .file)
      } catch {
        complain("touch: \(f): cannot create: " + Commands.why(error, f))
        failed += 1
        continue
      }
      try? ns.wstat(at(f), change)
    }
    return failed > 0 ? "touch" : ""
  }

  /// sleep(1): waits `time` seconds, a decimal fraction allowed; as
  /// atof, it reads what it can of the number and waits that. Nothing to
  /// wait without one.
  func sleep(_ args: [String]) -> String {
    guard let time = args.first else { return "" }
    var whole: Int64 = 0, fraction: Int64 = 0, scale: Int64 = 1_000_000_000
    var bytes = Array(time.utf8)[...]
    while let c = bytes.first, c >= 0x30, c <= 0x39, whole < 1 << 32 {
      whole = whole * 10 + Int64(c - 0x30)
      bytes = bytes.dropFirst()
    }
    if bytes.first == 0x2E {
      for c in bytes.dropFirst() {
        guard c >= 0x30, c <= 0x39 else { break }
        scale /= 10
        fraction += Int64(c - 0x30) * scale
      }
    }
    Sys.sleep(until: Clock.monotonic() + whole * 1_000_000_000 + fraction)
    return ""
  }

  /// strtoul(s, &end, 0), all of `s`: decimal, 0x hex or 0 octal.
  static func strtoul(_ s: String) -> Int64? {
    if s.hasPrefix("0x") || s.hasPrefix("0X") { return Int64(s.dropFirst(2), radix: 16) }
    if s.hasPrefix("0") && s.utf8.count > 1 { return Int64(s.dropFirst(), radix: 8) }
    return Int64(s, radix: 10)
  }
}
