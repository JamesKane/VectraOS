// SPDX-License-Identifier: BSD-3-Clause

// A service that serves each client a tree of its own (`export
// per-client`, manifest(6)): the launcher alone reaches its own tree,
// and for each service that uses it opens one through its `clients`
// node, naming the client and giving the client manifest's `grant` lines
// for it, so the service knows who is asking, which a forwarding node
// can't tell it (factotum, D75).

import IPC

@IPCLibrary(id: "todhchai.launch", version: 1)
public enum LaunchIPC {
  public enum ClientsError: Int32, IPCErrorCode, Sendable {
    /// The service won't serve what the grants ask (a malformed grant).
    case refused = 1
  }

  public protocol Clients {
    /// Serves `client`'s tree on `node` (the server's end of a Node
    /// channel), as its manifest's `grant` lines for this service ask.
    func open(client: String, grants: [String], node: consuming Handle) throws(ClientsError)
  }
}
