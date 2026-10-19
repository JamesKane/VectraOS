// SPDX-License-Identifier: BSD-3-Clause

// Routing (sdk(2), D85): a program hands the plumber "open this", and its
// rules choose the port it goes to. A message is the plumber's own
// (`RouteMessage`, plumb(6)'s fields). A program listens on a port
// (`Loop.listen`) and what is sent there comes as `.routed` events on its
// loop.

@_exported import Plumber

/// A port the loop listens on (`Loop.listen`).
public struct ListenID: Hashable, Sendable { public var raw: UInt32 }

public enum RouteError: Error, Equatable, CustomStringConvertible {
  /// The namespace has no plumber (its manifest's `mount /mnt/plumb`).
  case noPlumber
  /// The plumber refused the message: no rule takes it, or its port has
  /// no reader and nothing to start (its log says which).
  case refused
  /// The plumber has no port of that name.
  case noPort

  public var description: String {
    switch self {
    case .noPlumber: "there's no plumber at /mnt/plumb"
    case .refused: "the plumber refused the message"
    case .noPort: "the plumber has no port of that name"
    }
  }
}
