// SPDX-License-Identifier: BSD-3-Clause

// A devicetree device's links as its driver reads them (D154): devmgr's
// /dev/dt/links, a line a link, `KIND NAME PROVIDER [NODE] CELLS...`
// (DeviceLink.summary, with the provider named by its host's service,
// whose tree is the driver's /dev/provider/SERVICE, or `-` where none
// runs), and the command that turns one on through its provider's `ctl`:
// a clock on, a reset released, a supply or a PHY on, a pin state set.

/// One line of /dev/dt/links.
public struct ProvidedLink: Equatable, Sendable {
  /// `clock`, `reset`, `pinctrl`, `syscon` and the rest (DeviceLink).
  public var kind: String
  /// Its name for the device (`default`, `core`), empty for `-`.
  public var name: String
  /// The provider's service; empty where none runs.
  public var provider: String
  /// The node named, where it isn't the provider's own (a pin state's).
  public var node: String
  public var cells: [UInt32]

  public init(kind: String, name: String = "", provider: String, node: String = "", cells: [UInt32] = []) {
    self.kind = kind
    self.name = name
    self.provider = provider
    self.node = node
    self.cells = cells
  }

  /// The links in `text`, a line each; a line it can't read is left out.
  public static func parse(_ text: String) -> [ProvidedLink] {
    var out: [ProvidedLink] = []
    for line in text.utf8.split(separator: 0x0A) {
      let words = line.split(separator: 0x20).map { String(decoding: $0, as: UTF8.self) }
      guard words.count >= 3 else { continue }
      let dash = { (w: String) in w.utf8.elementsEqual("-".utf8) ? "" : w }
      var link = ProvidedLink(kind: words[0], name: dash(words[1]), provider: dash(words[2]))
      for w in words.dropFirst(3) {
        if w.utf8.first == UInt8(ascii: "/") {
          link.node = w
        } else if let n = UInt32(w) {
          link.cells.append(n)
        }
      }
      out.append(link)
    }
    return out
  }

  public func isKind(_ k: String) -> Bool { kind.utf8.elementsEqual(k.utf8) }

  /// The command that turns it on through its provider's `ctl`, for the
  /// kinds every provider of that kind takes: `clock ID on`, `reset ID
  /// deassert`, a supply `on`, a PHY `on` and its specifier's cells (`on
  /// 4`, a combo PHY's USB 3 mode), and for the `default` pin state,
  /// `state NAME`, the state node's name; nil for any other.
  public var enabling: String? {
    if isKind("clock"), let id = cells.first { return "clock \(id) on" }
    if isKind("reset"), let id = cells.first { return "reset \(id) deassert" }
    if isKind("supply") { return "on" }
    if isKind("phy") { return (["on"] + cells.map { String($0) }).joined(separator: " ") }
    if isKind("pinctrl"), name.utf8.elementsEqual("default".utf8), !node.isEmpty {
      let state = node.utf8.split(separator: UInt8(ascii: "/")).last.map { String(decoding: $0, as: UTF8.self) } ?? ""
      return state.isEmpty ? nil : "state \(state)"
    }
    return nil
  }
}

/// A GPIO line its provider watches, as the provider's `events` reads
/// (k1-gpio(3)): after `gpio CELLS watch` to its `ctl`, a line `gpio
/// CELLS active|inactive edges N`, CELLS the consumer's specifier, and a
/// read of `events` waits until one of its lines changes.
public struct WatchedGpio: Equatable, Sendable {
  public var active: Bool
  /// The interrupts that found an edge on it so far.
  public var edges: Int

  public init(active: Bool, edges: Int) {
    self.active = active
    self.edges = edges
  }

  /// The line for the specifier `cells` in `text`; nil if it isn't there.
  public static func find(_ text: String, cells: [UInt32]) -> WatchedGpio? {
    for line in text.utf8.split(separator: 0x0A) {
      let w = line.split(separator: 0x20).map { String(decoding: $0, as: UTF8.self) }
      guard !cells.isEmpty, w.count == cells.count + 4, w[0].utf8.elementsEqual("gpio".utf8),
        w[1...cells.count].map({ UInt32($0) }) == cells.map({ Optional($0) }),
        w[cells.count + 2].utf8.elementsEqual("edges".utf8), let edges = Int(w[cells.count + 3])
      else { continue }
      let state = w[cells.count + 1].utf8
      guard state.elementsEqual("active".utf8) || state.elementsEqual("inactive".utf8) else { continue }
      return WatchedGpio(active: state.elementsEqual("active".utf8), edges: edges)
    }
    return nil
  }
}
