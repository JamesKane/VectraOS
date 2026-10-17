// SPDX-License-Identifier: BSD-3-Clause

// Streams (D84): a file whose bytes come and go, as Plan 9's /dev/cons,
// /dev/kbd and /net's listen do. A read takes what is there; if nothing
// is, it waits until there is, the server holding the call (IPCDeferral)
// and answering it when the stream says it is ready. Only a read that
// begins a batch on a channel opened at the stream waits, which is how an
// opened file reads: one later in a batch, after walks, may have come
// through a mount whose service forwards batches in its own thread, so it
// answers with what is there, maybe nothing. The stream's service learns
// when a channel opened at it comes and goes (`opened`, `closed`), as
// Plan 9's device files do (`rawon` lasts while consctl is open).

import IPC

/// One channel's own stream, for a stream whose readers each get their own
/// copy (a plumber's port): what `NodeStream(perChannel:)` makes for each
/// channel opened at it. Its closures run on the tree's dispatcher.
public final class NodeStreamChannel: @unchecked Sendable {
  let take: (Int) -> [UInt8]?
  let closed: () -> Void

  public init(take: @escaping (Int) -> [UInt8]?, closed: @escaping () -> Void = {}) {
    self.take = take
    self.closed = closed
  }
}

/// What a stream node does. Its closures run on the tree's dispatcher.
public final class NodeStream: @unchecked Sendable {
  /// Up to `max` bytes, taking them; nil if there are none yet (a read
  /// waits), empty at the stream's end.
  let take: (Int) -> [UInt8]?
  /// A write's bytes, and how many were taken; nil: not writable.
  let write: (([UInt8]) throws(NodeError) -> UInt32)?
  let opened: () -> Void
  let closed: () -> Void
  /// Each channel's own stream, if its readers don't share one.
  let perChannel: (() -> NodeStreamChannel)?

  public init(take: @escaping (Int) -> [UInt8]?, write: (([UInt8]) throws(NodeError) -> UInt32)? = nil,
              opened: @escaping () -> Void = {}, closed: @escaping () -> Void = {}) {
    self.take = take
    self.write = write
    self.opened = opened
    self.closed = closed
    perChannel = nil
  }

  /// A stream each channel opened at it reads on its own: `open` makes the
  /// channel's (it is told when the channel goes).
  public init(perChannel open: @escaping () -> NodeStreamChannel,
              write: (([UInt8]) throws(NodeError) -> UInt32)? = nil) {
    take = { _ in [] }
    self.write = write
    opened = {}
    closed = {}
    perChannel = open
  }
}

extension NodeTree {
  /// A stream at `path`.
  @discardableResult
  public func stream(_ path: String, _ stream: NodeStream) -> TreeNode {
    place(path, .stream(stream))
  }

  /// The stream at `node` may have bytes for its waiting readers: each
  /// session with a read held on it tries again, on the dispatcher's
  /// thread. Any thread may call it.
  public func ready(_ node: TreeNode) {
    let sessions = locked { node.waiting.map { $0.id } }
    for id in sessions { dispatcher.wake(id) }
  }

  /// Answers the reads `state` holds that its stream can now (on the
  /// dispatcher's thread, from the session's wake).
  func answerHeldReads(_ state: SessionState, _ s: inout NodeIPC.NodeServer<Session>) throws(IPCError<Never>) {
    guard let node = state.stream, case .stream(let stream) = node.content else { return }
    var i = 0
    while i < state.reads.count {
      let r = state.reads[i]
      let take = state.channel?.take ?? stream.take
      guard let bytes = node.detached ? [] : take(Int(r.max)) else {
        i += 1
        continue
      }
      state.reads.remove(at: i)
      let reply = NodeIPC.Reply(results: [.data(bytes)], failure: nil, node: nil)
      try s.connection.send(try NodeIPC._reply_Node_batch(reply, to: r.header))
    }
    settle(state)
  }

  /// A read beginning a batch at a stream: its bytes, or nil once the call
  /// is held for later (nothing there yet).
  func readOrHold(_ node: TreeNode, _ stream: NodeStream, max: UInt32, _ state: SessionState) -> [UInt8]? {
    let limit = Swift.min(Int(max), NodeIPC.maxIO)
    // A waiter first, then a look: a `ready` between the two wakes the
    // session, whose wake runs after this call on the same thread.
    locked { if !node.waiting.contains(where: { $0 === state }) { node.waiting.append(state) } }
    if let bytes = (state.channel?.take ?? stream.take)(limit) {
      settle(state)
      return bytes
    }
    guard let header = state.deferral.hold() else { return [] }
    state.reads.append((header, UInt32(limit)))
    return nil
  }
}

extension NodeTree {
  /// A ring's read of `node` (D93): a stream's bytes, or nil to hold the
  /// read until it is ready, the session a waiter first (as `readOrHold`);
  /// any other node's contents at once. Empty: the stream ended.
  func ringRead(_ node: TreeNode, _ state: SessionState, offset: UInt64, max: Int) throws(NodeError) -> [UInt8]? {
    let content = try locked { () throws(NodeError) in try live(node).content }
    guard case .stream(let stream) = content else {
      return try read(node, offset: offset, max: UInt32(Swift.min(max, Int(UInt32.max))), limit: max)
    }
    locked { if !node.waiting.contains(where: { $0 === state }) { node.waiting.append(state) } }
    if node.detached { return [] }
    return (state.channel?.take ?? stream.take)(max)
  }

  /// Drops the session from its stream's waiters once it holds no read,
  /// plain or through its ring.
  func settle(_ state: SessionState) {
    guard let node = state.stream, state.reads.isEmpty, state.bulk?.held.isEmpty ?? true else { return }
    locked { node.waiting.removeAll { $0 === state } }
  }
}
