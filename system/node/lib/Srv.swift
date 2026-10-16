// SPDX-License-Identifier: BSD-3-Clause

// A session's service board, mounted at /srv (architecture §4): a user's
// own programs post Node channels by name, as 9front's /srv does, so they
// can find each other without a global registry. Posting goes through the
// Board protocol; reading is Node, where a posted name forwards walks to
// the channel posted. A post whose program has gone disappears.

import IPC

@IPCLibrary(id: "todhchai.srv", version: 1)
public enum SrvIPC {
  public enum BoardError: Int32, IPCErrorCode, Sendable {
    case exists = 1
    case notFound
    case badName
  }

  public protocol Board {
    /// Posts `node` (a Node channel) as `name`.
    func post(_ name: String, _ node: consuming Handle) throws(BoardError)
    func withdraw(_ name: String) throws(BoardError)
  }
}

/// The board service: a tree of posted names, served as Node, and the
/// Board protocol that changes it.
public final class SrvBoard: @unchecked Sendable {
  public let tree: NodeTree
  let dispatcher: IPCDispatcher

  public init(dispatcher: IPCDispatcher) {
    self.dispatcher = dispatcher
    tree = NodeTree(dispatcher: dispatcher)
  }

  /// Serves the board's Node tree (what /srv mounts).
  public func serveNode(_ channel: consuming Handle) throws(Status) { try tree.serve(channel) }

  /// Serves the Board protocol, for posting.
  public func serveBoard(_ channel: consuming Handle) throws(Status) {
    try dispatcher.add(SrvIPC.BoardServer(channel: channel, impl: Poster(board: self)))
  }

  struct Poster: SrvIPC.BoardHandler {
    let board: SrvBoard

    mutating func post(_ name: String, _ node: consuming Handle) throws(SrvIPC.BoardError) {
      guard NodeIPC.isValidName(name) else { throw .badName }
      guard board.tree.node(name) == nil else { throw .exists }
      board.tree.mount(name, node)
    }

    mutating func withdraw(_ name: String) throws(SrvIPC.BoardError) {
      guard NodeIPC.isValidName(name), let node = board.tree.node(name) else { throw .notFound }
      board.tree.remove(node)
    }
  }
}
