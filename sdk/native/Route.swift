// SPDX-License-Identifier: BSD-3-Clause

// Routing (D85): a message is one write to the plumber's `send`, and a
// port is a file of the plumber's whose read waits for the next message
// (D84). The loop reads each port it listens on in a thread of its own,
// which hands each message to the loop as a packet on its port: no IPC
// call can be left waiting on the loop's own thread, and an idle port
// costs the loop no wakeups.

import IPC
import Node
import Sys

final class Routing {
  static let path = "/mnt/plumb"
  /// The ports listened on, by id.
  var ports: [ListenID] = []
  var nextID: UInt32 = 1

  func listening(_ id: ListenID) -> Bool { ports.contains(id) }
}

extension Loop {
  /// Listens on the plumber's port `name`: what is sent there comes as
  /// `.routed` events, from now until the loop ends.
  public mutating func listen(port name: String) throws(RouteError) -> ListenID {
    guard let ns = NativeProcess.namespace else { throw .noPlumber }
    let client: NodeIPC.NodeClient
    do { client = try ns.open(Routing.path + "/" + name) } catch {
      throw (try? ns.open(Routing.path)) == nil ? .noPlumber : .noPort
    }
    if routing == nil { routing = Routing() }
    let routing = routing!
    let id = ListenID(raw: routing.nextID)
    routing.nextID += 1
    routing.ports.append(id)
    let raw = client.takeConnection().takeChannel().release()
    let shared = self.shared
    do {
      _ = try Sys.Thread.spawn {
        var port = NodeIPC.NodeClient(channel: Handle(raw: raw))
        while let bytes = try? port.read(offset: 0, max: 1 << 16) {
          if let m = RouteMessage(packed: bytes) { shared.route(id, m) }
        }
      }
    } catch {
      routing.ports.removeAll { $0 == id }
      _ = Handle(raw: raw)
      throw .noPort
    }
    return id
  }

  /// Sends `message` to the plumber, whose rules choose its port.
  public func route(_ message: RouteMessage) throws(RouteError) {
    guard let ns = NativeProcess.namespace, var send = try? ns.open(Routing.path + "/send") else { throw .noPlumber }
    guard (try? send.write(offset: 0, message.packed)) != nil else { throw .refused }
  }
}
