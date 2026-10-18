// SPDX-License-Identifier: BSD-3-Clause

// /proc (D79), after Plan 9's proc(3): a directory for each process the
// service can see, named by its koid, with
//   status   Plan 9's line: name, user, state, times, memory, priorities
//   args     its name, the one argument the kernel keeps
//   ctl      `kill`
//   note     a note to post to it (D87)
//   notepg   a note to post to its note group: every process of its job
//            and of the jobs under that
// and, given the tracing resource, trace/ (Trace.swift).
// The directory is brought up to date as it is walked or listed. What it
// needs of the kernel is a ProcHost's, so it runs hosted against fakes.

import Node
import Sys

/// What /proc says of a process.
public struct ProcStatus: Equatable, Sendable {
  public var name: String
  /// Plan 9's state names: `New` before it starts, `Running`, then
  /// `Moribund` once it has ended.
  public var state: String
  public var userMilliseconds: UInt64
  public var realMilliseconds: UInt64
  public var memoryKiB: UInt64

  public init(name: String, state: String, userMilliseconds: UInt64, realMilliseconds: UInt64, memoryKiB: UInt64) {
    self.name = name
    self.state = state
    self.userMilliseconds = userMilliseconds
    self.realMilliseconds = realMilliseconds
    self.memoryKiB = memoryKiB
  }
}

/// A process the service sees: its koid, and the koids of the jobs from
/// the service's own down to the one it runs in.
public struct ProcEntry: Equatable, Sendable {
  public var koid: UInt64
  public var jobs: [UInt64]
  public init(koid: UInt64, jobs: [UInt64]) {
    self.koid = koid
    self.jobs = jobs
  }
}

/// What the service needs of the kernel.
public struct ProcHost: @unchecked Sendable {
  public var processes: () -> [ProcEntry]
  public var status: (UInt64) -> ProcStatus?
  /// Whether it was killed (false: it's gone).
  public var kill: (UInt64) -> Bool
  public var post: (UInt64, String) throws(Status) -> Void
  /// The kernel's trace, for /proc/trace; nil without the tracing resource.
  public var trace: TraceHost?

  public init(processes: @escaping () -> [ProcEntry], status: @escaping (UInt64) -> ProcStatus?,
              kill: @escaping (UInt64) -> Bool, post: @escaping (UInt64, String) throws(Status) -> Void,
              trace: TraceHost? = nil) {
    self.processes = processes
    self.status = status
    self.kill = kill
    self.post = post
    self.trace = trace
  }
}

public enum Proc {
  /// Plan 9's status line (devproc.c's): name, user and state padded to
  /// 27, 27 and 11, then nine numbers of 11 each: user, system and real
  /// milliseconds, the same for its children, its memory in KiB, its base
  /// and current priority. Users and priorities aren't kept: `none`, 0.
  public static func statusLine(_ s: ProcStatus) -> String {
    func left(_ text: String, _ width: Int) -> String {
      let b = Array(text.utf8)
      return String(decoding: b + Array(repeating: 0x20, count: Swift.max(0, width - b.count)), as: UTF8.self)
    }
    func right(_ n: UInt64) -> String {
      let b = Array(String(n).utf8)
      return String(decoding: Array(repeating: 0x20, count: Swift.max(0, 11 - b.count)) + b, as: UTF8.self)
    }
    let numbers: [UInt64] = [s.userMilliseconds, 0, s.realMilliseconds, 0, 0, 0, s.memoryKiB, 0, 0]
    return left(s.name, 27) + " " + left("none", 27) + " " + left(s.state, 11)
      + numbers.map { " " + right($0) }.joined() + "\n"
  }

  /// A note as written to `note`: one trailing newline dropped (echo's).
  public static func note(_ text: String) -> String {
    var b = Array(text.utf8)
    if b.last == 0x0A { b.removeLast() }
    return String(decoding: b, as: UTF8.self)
  }

  /// The note group of `koid` among `all`: every process whose jobs start
  /// with its own.
  public static func noteGroup(of koid: UInt64, in all: [ProcEntry]) -> [UInt64] {
    guard let me = all.first(where: { $0.koid == koid }) else { return [] }
    return all.filter { $0.jobs.count >= me.jobs.count && Array($0.jobs.prefix(me.jobs.count)) == me.jobs }
      .map { $0.koid }
  }

  static func nodeError(_ s: Status) -> NodeError {
    switch s {
    case .shouldWait: .io
    case .badState: .notFound
    case .accessDenied: .denied
    default: .invalid
    }
  }
}

/// /proc's tree: kept current by its root's refresh.
public final class ProcFiles: @unchecked Sendable {
  let tree: NodeTree
  let host: ProcHost
  let lock = Lock()
  var shown: [(koid: UInt64, node: TreeNode)] = []
  let trace: TraceFiles?

  public init(tree: NodeTree, host: ProcHost) {
    self.tree = tree
    self.host = host
    trace = host.trace.map { TraceFiles(tree: tree, host: $0, processes: host.processes) }
    tree.refresh("") { [self] in refresh() }
  }

  /// A directory for each process there now, none for those gone.
  public func refresh() {
    let now = host.processes().map { $0.koid }
    let (added, gone) = lock.withLock { () -> ([UInt64], [TreeNode]) in
      let gone = shown.filter { s in !now.contains(s.koid) }
      shown.removeAll { s in !now.contains(s.koid) }
      let added = now.filter { k in !shown.contains { $0.koid == k } }
      return (added, gone.map { $0.node })
    }
    for node in gone { tree.remove(node) }
    for koid in added {
      let node = add(koid)
      lock.withLock { shown.append((koid, node)) }
    }
  }

  func add(_ koid: UInt64) -> TreeNode {
    let host = self.host
    let name = String(koid)
    let node = tree.directory(name)
    tree.text(name + "/status", read: { host.status(koid).map(Proc.statusLine) ?? "" })
    tree.text(name + "/args", read: { host.status(koid)?.name ?? "" })
    tree.text(name + "/ctl", read: { "" }, write: { (text: String) throws(NodeError) in
      let words = Array(Proc.note(text).utf8).split(separator: 0x20).map { Array($0) }
      guard words.count == 1, words[0] == Array("kill".utf8) else { throw .invalid }
      guard host.kill(koid) else { throw .notFound }
    })
    tree.text(name + "/note", read: { "" }, write: { (text: String) throws(NodeError) in
      do throws(Status) { try host.post(koid, Proc.note(text)) } catch { throw Proc.nodeError(error) }
    })
    tree.text(name + "/notepg", read: { "" }, write: { (text: String) throws(NodeError) in
      let note = Proc.note(text)
      var posted = 0
      for k in Proc.noteGroup(of: koid, in: host.processes()) where (try? host.post(k, note)) != nil { posted += 1 }
      guard posted > 0 else { throw .notFound }
    })
    return node
  }
}
