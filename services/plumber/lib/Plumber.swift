// SPDX-License-Identifier: BSD-3-Clause

// The plumber (D85), after plumber(4): messages written to `send` are
// routed by the rules and given to their port. Every channel open on the
// port gets a copy; with none, a ruleset's `plumb client` starts its app
// and holds the message until the port is opened, `plumb start` starts it
// and drops the message, and with neither the send fails. Ports are made
// for each `plumb to` the rules name, and never taken away. Each channel
// open on a port reads its messages one at a time (a read takes at most one,
// the rest of a long one on the next read).
//
// What it needs from where it runs is a `PlumberHost`'s: whether a path
// is a file or a directory (the rules' isfile and isdir), and starting a
// program. Everything runs on the plumber's one thread.

public struct PlumberHost {
  public var files: (String) -> Rules.FileKind?
  /// Starts `argv` with `wdir` as its directory; nil, or why it couldn't.
  public var start: ([String], String) -> String?

  public init(files: @escaping (String) -> Rules.FileKind? = { _ in nil },
              start: @escaping ([String], String) -> String? = { _, _ in "no programs to start" })
  {
    self.files = files
    self.start = start
  }
}

public enum PlumbError: Error, Equatable, Sendable {
  /// What was written isn't a plumb(6) message.
  case badMessage
  /// No ruleset takes it.
  case noRule
  /// Its port has no reader, and its ruleset starts nothing.
  case noReader(String)
  /// Its app couldn't be started.
  case startFailed(String)

  public var text: String {
    switch self {
    case .badMessage: "not a plumb message"
    case .noRule: "no matching plumb rule"
    case .noReader(let p): "no reader for port \(p)"
    case .startFailed(let why): "can't start: \(why)"
    }
  }

  public static func == (a: Self, b: Self) -> Bool { same(a.text, b.text) }
}

/// One channel's view of a port: its messages, read one at a time.
public final class PortReader: @unchecked Sendable {
  var queue: [[UInt8]] = []
  var taken = 0

  /// Up to `max` bytes of the next message, nil if there is none yet.
  public func take(_ max: Int) -> [UInt8]? {
    guard let first = queue.first, max > 0 else { return nil }
    let n = Swift.min(max, first.count - taken)
    defer {
      taken += n
      if taken == first.count {
        queue.removeFirst()
        taken = 0
      }
    }
    return Array(first[taken..<taken + n])
  }
}

public final class Plumber: @unchecked Sendable {
  final class Port {
    let name: String
    var readers: [PortReader] = []
    /// Held for the app a `plumb client` started, until the port is opened.
    var held: [[UInt8]] = []
    var delivered = 0
    init(_ name: String) { self.name = name }
  }

  public static let maxHeld = 32

  public private(set) var rulesText: String
  var rules: Rules
  var ports: [Port] = []
  let host: PlumberHost
  /// The last sends, for the status: what was routed where, or refused.
  var log: [String] = []

  public init(rules text: String, host: PlumberHost) throws(RuleError) {
    rules = try Rules(text)
    rulesText = text
    self.host = host
    addPorts()
  }

  /// The ports, in the order the rules name them.
  public var portNames: [String] { ports.map { $0.name } }

  func addPorts() {
    for p in rules.ports where !ports.contains(where: { same($0.name, p) }) { ports.append(Port(p)) }
  }

  func port(_ name: String) -> Port? { ports.first { same($0.name, name) } }

  /// More rules (a write to `rules`), a ruleset of their own after those in
  /// force (a blank line between): the whole set parsed again, the new
  /// ports made. On an error, the rules stay as they were.
  public func append(rules text: String) throws(RuleError) {
    var all = rulesText
    if !all.isEmpty {
      if all.utf8.last != 0x0A { all += "\n" }
      if !all.utf8.reversed().starts(with: [0x0A, 0x0A]) { all += "\n" }
    }
    all += text
    rules = try Rules(all)
    rulesText = all
    addPorts()
  }

  /// A message written to `send`: routed, and given to its port's readers
  /// (or held, or its app started). The port it went to.
  @discardableResult
  public func send(_ bytes: [UInt8]) throws(PlumbError) -> String {
    do throws(PlumbError) {
      guard let message = RouteMessage(packed: bytes) else { throw .badMessage }
      guard let routed = rules.route(message, files: host.files), let name = routed.port, let port = port(name) else {
        throw .noRule
      }
      let packed = routed.message.packed
      if !port.readers.isEmpty {
        for r in port.readers { r.queue.append(packed) }
        port.delivered += 1
        note("\(name): to \(port.readers.count) reader\(port.readers.count == 1 ? "" : "s")")
      } else if let argv = routed.client {
        if let why = host.start(argv, routed.message.wdir) { throw .startFailed(why) }
        if port.held.count == Self.maxHeld { port.held.removeFirst() }
        port.held.append(packed)
        note("\(name): held for \(argv.joined(separator: " "))")
      } else if let argv = routed.start {
        if let why = host.start(argv, routed.message.wdir) { throw .startFailed(why) }
        note("\(name): started \(argv.joined(separator: " "))")
      } else {
        throw .noReader(name)
      }
      return name
    } catch {
      note("refused: \(error.text)")
      throw error
    }
  }

  /// A channel opened on port `name`: its reader, given what was held for
  /// the port; nil if there is no such port.
  public func open(port name: String) -> PortReader? {
    guard let port = port(name) else { return nil }
    let r = PortReader()
    r.queue = port.held
    if !port.held.isEmpty { port.delivered += port.held.count }
    port.held = []
    port.readers.append(r)
    return r
  }

  /// The channel went.
  public func close(_ reader: PortReader, port name: String) {
    port(name)?.readers.removeAll { $0 === reader }
  }

  func note(_ line: String) {
    log.append(line)
    if log.count > 16 { log.removeFirst() }
  }

  /// `port NAME readers N held N delivered N` a port, then the last sends.
  public var status: String {
    ports.map { "port \($0.name) readers \($0.readers.count) held \($0.held.count) delivered \($0.delivered)\n" }.joined()
      + log.map { "sent \($0)\n" }.joined()
  }
}
