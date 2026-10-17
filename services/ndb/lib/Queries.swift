// SPDX-License-Identifier: BSD-3-Clause

// A file each channel asks on and reads the answers to, as /net/cs and
// /net/dns are: a write is a query, its write held (D94) while a thread
// of its own answers it, as Plan 9's cs and dns answer each in a process
// of its own, since an answer may wait on the network. The write then
// succeeds, or fails with why; each read after takes one answer, and the
// end comes after the last. A channel's queries are its own.

import IPC
import Node
import Synchronization
import Sys

final class QueryFile: @unchecked Sendable {
  /// One channel's query and its answers.
  final class Channel: @unchecked Sendable {
    let lock = Lock()
    /// The query being answered, and its answer once there is one.
    var asked: [UInt8]?
    var outcome: Result<[[UInt8]], NodeError>?
    var answers: [[UInt8]] = []

    func take(_ max: Int) -> [UInt8]? {
      lock.withLock {
        guard !answers.isEmpty else { return [] }
        if answers[0].count <= max { return answers.removeFirst() }
        defer { answers[0].removeFirst(max) }
        return Array(answers[0][..<max])
      }
    }
  }

  /// What a write does.
  enum Step {
    case wait
    case answered(UInt32)
    case failed(NodeError)
    case ask(String)
  }

  let tree: NodeTree
  let node = Locked<TreeNode?>(nil)
  let active = Atomic<Int>(0)
  let maxRequest: Int
  /// A ctl line, done at once, if the text is one.
  let command: @Sendable (String) -> Bool
  let answer: @Sendable (String) -> Result<[[UInt8]], NodeError>

  /// Queries answered at once, at most; one more fails (`io`).
  static let maxActive = 32

  init(tree: NodeTree, at path: String, maxRequest: Int, command: @escaping @Sendable (String) -> Bool,
       answer: @escaping @Sendable (String) -> Result<[[UInt8]], NodeError>) {
    self.tree = tree
    self.maxRequest = maxRequest
    self.command = command
    self.answer = answer
    let n = tree.stream(path, NodeStream(perChannel: { [self] in
      let c = Channel()
      return NodeStreamChannel(take: { c.take($0) },
                               write: { [self] (data: [UInt8]) throws(NodeError) -> UInt32? in try write(c, data) })
    }))
    node.withLock { $0 = n }
  }

  /// A write: held while it is answered; a held write tried again is the
  /// same query (writes behind it wait), so its answer.
  func write(_ c: Channel, _ data: [UInt8]) throws(NodeError) -> UInt32? {
    guard data.count < maxRequest else { throw .invalid }
    let step = c.lock.withLock { () -> Step in
      if let asked = c.asked, asked == data {
        guard let outcome = c.outcome else { return .wait }
        c.asked = nil
        c.outcome = nil
        switch outcome {
        case .success(let a):
          c.answers = a
          return .answered(UInt32(data.count))
        case .failure(let e):
          c.answers = []
          return .failed(e)
        }
      }
      var text = String(decoding: data, as: UTF8.self)
      if text.utf8.last == 0x0A { text = String(decoding: data.dropLast(), as: UTF8.self) }
      c.answers = []
      return .ask(text)
    }
    switch step {
    case .wait: return nil
    case .answered(let n): return n
    case .failed(let e): throw e
    case .ask(let text):
      if command(text) { return UInt32(data.count) }
      guard active.add(1, ordering: .relaxed).newValue <= QueryFile.maxActive else {
        active.subtract(1, ordering: .relaxed)
        throw .io
      }
      c.lock.withLock {
        c.asked = data
        c.outcome = nil
      }
      let answer = self.answer
      do throws(Status) {
        _ = try Thread.spawn { [self] in
          let outcome = answer(text)
          c.lock.withLock { c.outcome = outcome }
          active.subtract(1, ordering: .relaxed)
          if let n = node.withLock({ $0 }) { tree.ready(n) }
        }.release()
      } catch {
        c.lock.withLock { c.asked = nil }
        active.subtract(1, ordering: .relaxed)
        throw .io
      }
      return nil
    }
  }
}
