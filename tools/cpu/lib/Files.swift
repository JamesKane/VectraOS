// SPDX-License-Identifier: BSD-3-Clause

// The tree the terminal serves its node, as drawterm lays out a
// non-Plan 9 host's (/mnt/term on the node):
//
//     dev/cons      the terminal: a read waits for a line typed (the
//                   dev machine's terminal edits it, in cooked mode),
//                   empty at ^D; a write shows its bytes
//     dev/cpunote   a read waits for a note, `interrupt` at ^C
//     net/          the dev machine's network, as ip(3)'s files (Net.swift)
//     root/         the dev machine's files from a directory, / by default
//
// Each file is what a fid stands for. Errors are the strings 9gate's
// export and import use (gate(2)), so the node's Node sees the same
// failures as from another node.

import FoundationEssentials
import Glibc
import NineP

/// What dev/cons and dev/cpunote are: the terminal's ends.
public struct Console: Sendable {
  /// A line typed, at most `max` bytes; empty at the end of input (^D).
  public let read: @Sendable (Int) -> [UInt8]
  public let write: @Sendable ([UInt8]) -> Void
  /// Waits for the next note: nil when there will be none.
  public let note: @Sendable () -> String?

  public init(read: @escaping @Sendable (Int) -> [UInt8], write: @escaping @Sendable ([UInt8]) -> Void,
              note: @escaping @Sendable () -> String?) {
    self.read = read
    self.write = write
    self.note = note
  }
}

/// A 9P failure, as its Rerror's text.
struct Refusal: Error {
  let text: String
  init(_ text: String) { self.text = text }

  static let notFound = Refusal("file does not exist")
  static let notDirectory = Refusal("not a directory")
  static let isDirectory = Refusal("is a directory")
  static let exists = Refusal("file already exists")
  static let denied = Refusal("permission denied")
  static let badName = Refusal("bad character in file name")
  static let notEmpty = Refusal("directory not empty")
  static let unsupported = Refusal("operation not supported")
  static let invalid = Refusal("bad arg in system call")
  static let io = Refusal("i/o error")

  /// The text for the C library's last error.
  static func errno(_ e: Int32 = Glibc.errno) -> Refusal {
    switch e {
    case ENOENT: .notFound
    case ENOTDIR: .notDirectory
    case EISDIR: .isDirectory
    case EEXIST: .exists
    case EACCES, EPERM, EROFS: .denied
    case ENOTEMPTY: .notEmpty
    case EINVAL, ENAMETOOLONG: .invalid
    default: .io
    }
  }
}

/// Where a fid is.
enum Place: Equatable {
  case top, dev, cons, cpunote
  /// net/, net/tcp, its clone, net/cs, a conversation's directory and
  /// one of its files.
  case net, tcp, clone, cs
  case conversation(Int)
  case netFile(Int, NetFile)
  /// Under root: the names below the exported directory.
  case host([String])
}

public final class TerminalTree: @unchecked Sendable {
  let root: String
  let console: Console
  let net = TerminalNet()
  let user: String
  /// Called with a host file's names below `root` when a read of it gets
  /// nothing, at its end: vx remote boot's sign the copies are done.
  let readToEnd: (@Sendable ([String]) -> Void)?

  /// The tree with the dev machine's files from `root`, and `console`.
  public init(root: String, console: Console, readToEnd: (@Sendable ([String]) -> Void)? = nil) {
    self.root = root.count > 1 && root.hasSuffix("/") ? String(root.dropLast()) : root
    self.console = console
    self.readToEnd = readToEnd
    user = ProcessInfo.processInfo.environment["USER"] ?? "none"
  }

  // The synthetic files' qids: paths below any a host file has (whose top
  // bit is set).
  static let topQid = Qid(type: QidType.dir, path: 1)
  static let devQid = Qid(type: QidType.dir, path: 2)
  static let consQid = Qid(path: 3)
  static let noteQid = Qid(path: 4)
  static let netQid = Qid(type: QidType.dir, path: 5)
  static let tcpQid = Qid(type: QidType.dir, path: 6)
  static let cloneQid = Qid(path: 7)
  static let csQid = Qid(path: 8)
  /// A conversation's directory, and its files after it.
  static func conversationQid(_ n: Int) -> Qid { Qid(type: QidType.dir, path: 0x1000 + UInt64(n) * 16) }
  static func netFileQid(_ n: Int, _ f: NetFile) -> Qid {
    Qid(path: 0x1000 + UInt64(n) * 16 + 1 + UInt64(NetFile.allCases.firstIndex(of: f)!))
  }

  func path(_ names: [String]) -> String {
    names.isEmpty ? root : (root == "/" ? "" : root) + "/" + names.joined(separator: "/")
  }

  func hostStat(_ names: [String]) throws(Refusal) -> stat {
    var s = stat()
    guard fstatat(AT_FDCWD, path(names), &s, 0) == 0 else { throw Refusal.errno() }
    return s
  }

  static func qid(_ s: stat) -> Qid {
    let dir = s.st_mode & S_IFMT == S_IFDIR
    let path = (UInt64(s.st_ino) ^ UInt64(s.st_dev) << 40) | 1 << 63
    return Qid(type: dir ? QidType.dir : QidType.file, version: UInt32(truncatingIfNeeded: s.st_mtim.tv_sec), path: path)
  }

  func qid(_ p: Place) throws(Refusal) -> Qid {
    switch p {
    case .top: Self.topQid
    case .dev: Self.devQid
    case .cons: Self.consQid
    case .cpunote: Self.noteQid
    case .net: Self.netQid
    case .tcp: Self.tcpQid
    case .clone: Self.cloneQid
    case .cs: Self.csQid
    case .conversation(let n): Self.conversationQid(n)
    case .netFile(let n, let f): Self.netFileQid(n, f)
    case .host(let names): Self.qid(try hostStat(names))
    }
  }

  /// One step of a walk from `p`.
  func walk(_ p: Place, _ name: String) throws(Refusal) -> Place {
    guard !name.isEmpty, !name.contains("/") else { throw .badName }
    if name == "." { return p }
    switch p {
    case .top:
      if name == ".." { return .top }
      if name == "dev" { return .dev }
      if name == "net" { return .net }
      if name == "root" { return .host([]) }
    case .dev:
      if name == ".." { return .top }
      if name == "cons" { return .cons }
      if name == "cpunote" { return .cpunote }
    case .net:
      if name == ".." { return .top }
      if name == "tcp" { return .tcp }
      if name == "cs" { return .cs }
      if ["udp", "ipifc", "iproute"].contains(name) { throw .unsupported }
    case .tcp:
      if name == ".." { return .net }
      if name == "clone" { return .clone }
      if let n = Int(name), String(n) == name, net.conversation(n) != nil { return .conversation(n) }
    case .conversation(let n):
      if name == ".." { return .tcp }
      if let f = NetFile(rawValue: name) { return .netFile(n, f) }
    case .cons, .cpunote, .clone, .cs, .netFile:
      throw .notDirectory
    case .host(let names):
      if name == ".." { return names.isEmpty ? .top : .host(Array(names.dropLast())) }
      let s = try hostStat(names)
      guard s.st_mode & S_IFMT == S_IFDIR else { throw .notDirectory }
      let next = names + [name]
      _ = try hostStat(next)
      return .host(next)
    }
    throw .notFound
  }

  func dir(_ p: Place) throws(Refusal) -> Dir {
    switch p {
    case .top: return Dir(qid: Self.topQid, mode: DirMode.dir | 0o555, name: "/", uid: user)
    case .dev: return Dir(qid: Self.devQid, mode: DirMode.dir | 0o555, name: "dev", uid: user)
    case .cons: return Dir(qid: Self.consQid, mode: 0o660, name: "cons", uid: user)
    case .cpunote: return Dir(qid: Self.noteQid, mode: 0o444, name: "cpunote", uid: user)
    case .net: return Dir(qid: Self.netQid, mode: DirMode.dir | 0o555, name: "net", uid: user)
    case .tcp: return Dir(qid: Self.tcpQid, mode: DirMode.dir | 0o555, name: "tcp", uid: user)
    case .clone: return Dir(qid: Self.cloneQid, mode: 0o666, name: "clone", uid: user)
    case .cs: return Dir(qid: Self.csQid, mode: 0o666, name: "cs", uid: user)
    case .conversation(let n):
      return Dir(qid: Self.conversationQid(n), mode: DirMode.dir | 0o555, name: "\(n)", uid: user)
    case .netFile(let n, let f):
      let mode: UInt32 = f == .ctl || f == .data ? 0o660 : 0o444
      return Dir(qid: Self.netFileQid(n, f), mode: mode, name: f.rawValue, uid: user)
    case .host(let names):
      let s = try hostStat(names)
      let dir = s.st_mode & S_IFMT == S_IFDIR
      let name = names.last ?? "root"
      return Dir(qid: Self.qid(s), mode: (dir ? DirMode.dir : 0) | UInt32(s.st_mode & 0o777),
                 length: dir ? 0 : UInt64(s.st_size), name: name, uid: Self.owner(s.st_uid) ?? user,
                 gid: Self.group(s.st_gid) ?? user, atime: UInt32(truncatingIfNeeded: s.st_atim.tv_sec),
                 mtime: UInt32(truncatingIfNeeded: s.st_mtim.tv_sec))
    }
  }

  static func owner(_ uid: uid_t) -> String? {
    guard let pw = getpwuid(uid), let name = pw.pointee.pw_name else { return nil }
    return String(cString: name)
  }

  static func group(_ gid: gid_t) -> String? {
    guard let gr = getgrgid(gid), let name = gr.pointee.gr_name else { return nil }
    return String(cString: name)
  }

  /// A directory's entries, each a stat, in one run of bytes.
  func listing(_ p: Place) throws(Refusal) -> [UInt8] {
    let children: [Place]
    switch p {
    case .top: children = [.dev, .net, .host([])]
    case .dev: children = [.cons, .cpunote]
    case .net: children = [.cs, .tcp]
    case .tcp: children = [.clone] + net.inUse().map { .conversation($0) }
    case .conversation(let n): children = NetFile.allCases.map { .netFile(n, $0) }
    case .cons, .cpunote, .clone, .cs, .netFile: throw .notDirectory
    case .host(let names):
      guard let d = opendir(path(names)) else { throw Refusal.errno() }
      defer { closedir(d) }
      var found: [Place] = []
      while let e = readdir(d) {
        let name = withUnsafeBytes(of: e.pointee.d_name) { b in
          String(decoding: b.prefix { $0 != 0 }, as: UTF8.self)
        }
        if name != "." && name != ".." { found.append(.host(names + [name])) }
      }
      children = found
    }
    var out: [UInt8] = []
    for c in children {
      // An entry gone, or one stat can't follow (a dangling link), is left out.
      guard let d = try? dir(c), let bytes = d.encode() else { continue }
      out += bytes
    }
    return out
  }
}
