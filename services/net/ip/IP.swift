// SPDX-License-Identifier: BSD-3-Clause

// /net's protocols over the stack (D79), as Plan 9's ip(3): `tcp` and
// `udp`, each a `clone` and conversations `N/{ctl,data,err,listen,local,
// remote,status}`, and the interface's files (Files.swift). Its owner
// gives it frames (`receive`), runs its timers (`poll`) and sends what it
// is given (`IPLink.transmit`).
//
// One lock covers the stack and the conversations: the tree's dispatcher
// takes it for clients' reads, writes and ctl lines, the owner's threads
// for frames and timers. After each, the frames the stack queued are
// sent, the deadline is passed to the owner, and every stream in use is
// told it may be ready (a session not waiting on it costs nothing), all
// once the lock has dropped.
//
// A conversation is the stack's TCP connection or listener, or its UDP
// endpoint. Its ctl's `connect` waits until the handshake ends (a write
// held, D94), as Plan 9's does; `listen` is a stream each channel reads
// on its own: once a call comes, the new conversation's number, the
// channel holding that conversation as Plan 9's listen fd, its ctl, does.

import Net
import Node
import Sys

/// What the stack's owner gives the tree.
public struct IPLink: Sendable {
  /// The device's path, as ipifc's status says it.
  public var device: String
  /// Sends one frame, its header included.
  public var transmit: @Sendable ([UInt8]) -> Void
  /// The stack's next deadline, after anything that may have moved it.
  public var wake: @Sendable (Int64?) -> Void

  public init(device: String, transmit: @escaping @Sendable ([UInt8]) -> Void,
              wake: @escaping @Sendable (Int64?) -> Void) {
    self.device = device
    self.transmit = transmit
    self.wake = wake
  }
}

public final class IP: @unchecked Sendable {
  /// Conversations a protocol.
  public static let conversations = 32
  /// The bytes of UDP's `headers` record: remote, local and interface
  /// addresses, remote and local ports.
  public static let udpHeaderSize = 52

  enum Proto: Int {
    case tcp = 0, udp = 1
    var name: String { self == .tcp ? "tcp" : "udp" }
  }

  enum State { case idle, connecting, connected, announced, closed }

  /// A channel open on `listen`, and the call it was given.
  final class Waiter {
    var accepted: Int?
    var read = false
  }

  final class Conversation {
    let proto: Proto
    let id: Int
    /// Its open ctl, data and listen channels (and calls given to listen
    /// channels); and whether clone has made it and is serving its ctl.
    var refs = 0
    var reserved = false
    var state = State.idle
    /// The stack's connection, listener or endpoint; -1 for none.
    var handle = -1
    var remote = IPv6Address.any
    var remotePort: UInt16 = 0
    var localPort: UInt16 = 0
    /// UDP: datagrams read and written with their addresses (`headers`).
    var headers = false
    /// Why it last failed, as `err` reads.
    var error = ""
    var waiters: [Waiter] = []
    var data: TreeNode?, ctl: TreeNode?, listen: TreeNode?
    init(_ proto: Proto, _ id: Int) {
      self.proto = proto
      self.id = id
    }
    var inUse: Bool { refs > 0 || reserved }
  }

  /// What a pass under the lock leaves to do once it drops.
  struct Settled {
    var frames: [[UInt8]] = []
    var publish: [(Proto, Int)] = []
    var ready: [TreeNode] = []
    var deadline: Int64?
  }

  let tree: NodeTree
  let path: String
  let link: IPLink
  let lock = Lock()
  var stack: NetStack
  var conversations: [[Conversation]] = [[], []]
  /// Frames given to the link.
  var framesOut = 0

  /// Serves /net's protocols at `path` in `tree` ("" for its root), over
  /// `stack`.
  public init(tree: NodeTree, at path: String, stack: consuming NetStack, link: IPLink) {
    self.tree = tree
    self.path = path
    self.link = link
    self.stack = stack
    if !path.isEmpty { tree.directory(path) }
    for proto in [Proto.tcp, .udp] {
      tree.directory(file(proto.name))
      tree.service(file(proto.name + "/clone")) { [self] (channel: consuming Handle) throws(Status) in
        guard let ctl = clone(proto) else { throw .noResources }
        try tree.serve(channel, at: ctl)
      }
      tree.text(file(proto.name + "/stats"), read: { [self] in stats(proto) })
    }
    files()
  }

  func file(_ name: String) -> String { path.isEmpty ? name : path + "/" + name }

  // MARK: The owner's side

  /// A frame the device received. Any thread.
  public func receive(_ frame: [UInt8], now: Int64) {
    settled(now) { stack.receive(frame, length: frame.count, now: now) }
  }

  /// Frames come together, given to the stack in one settle: their
  /// readers woken and their replies sent once for them all.
  public func receive(_ frames: [[UInt8]], now: Int64) {
    guard !frames.isEmpty else { return }
    settled(now) { for f in frames { stack.receive(f, length: f.count, now: now) } }
  }

  /// Runs the stack's timers due by `now`. Any thread.
  public func poll(now: Int64) { settled(now) { stack.poll(now: now) } }

  /// `body` on the stack (to configure it), then what it sent sent.
  public func withStack<R>(_ body: (inout NetStack, Int64) -> R) -> R {
    let now = Clock.monotonic()
    return settled(now) { body(&stack, now) }
  }

  /// `body` on the stack as it is, to read it.
  public func read<R>(_ body: (borrowing NetStack) -> R) -> R { lock.withLock { body(stack) } }

  /// When the stack next needs `poll`.
  public var nextDeadline: Int64? { lock.withLock { stack.nextDeadline } }

  /// `body` under the lock, then the frames sent, new conversations'
  /// directories made, streams told, and the owner given the deadline.
  func settled<R, E: Error>(_ now: Int64, _ body: () throws(E) -> R) throws(E) -> R {
    lock.lock()
    let result: R
    do {
      result = try body()
    } catch {
      let s = settleLocked(now)
      lock.unlock()
      finish(s)
      throw error
    }
    let s = settleLocked(now)
    lock.unlock()
    finish(s)
    return result
  }

  func settleLocked(_ now: Int64) -> Settled {
    var s = Settled()
    // Calls for each announced TCP conversation's waiting listen channels.
    for a in conversations[Proto.tcp.rawValue] where a.state == .announced && a.handle >= 0 {
      for w in a.waiters where w.accepted == nil {
        guard let c = conversations[Proto.tcp.rawValue].first(where: { !$0.inUse }) ?? newConversation(.tcp, &s)
        else { break }
        guard let handle = stack.acceptTCP(a.handle) else { break }
        c.refs = 1  // the listen channel's
        c.state = .connected
        c.handle = handle
        w.accepted = c.id
      }
    }
    for i in 0..<stack.transmit.count { s.frames.append(stack.transmit.frame(i)) }
    framesOut += s.frames.count
    stack.transmit.removeAll()
    for list in conversations {
      for c in list where c.inUse {
        if let n = c.data { s.ready.append(n) }
        if let n = c.ctl { s.ready.append(n) }
        if let n = c.listen { s.ready.append(n) }
      }
    }
    s.deadline = stack.nextDeadline
    return s
  }

  func finish(_ s: Settled) {
    for (proto, id) in s.publish { publish(proto, id) }
    for f in s.frames { link.transmit(f) }
    for n in s.ready { tree.ready(n) }
    link.wake(s.deadline)
  }

  // MARK: Conversations

  /// A conversation made, its directory to publish once the lock drops;
  /// nil if there are as many as there may be.
  func newConversation(_ proto: Proto, _ s: inout Settled) -> Conversation? {
    guard conversations[proto.rawValue].count < IP.conversations else { return nil }
    let c = Conversation(proto, conversations[proto.rawValue].count)
    conversations[proto.rawValue].append(c)
    s.publish.append((proto, c.id))
    return c
  }

  /// The first conversation not in use, reserved for the ctl that clone
  /// serves; nil if all are.
  func clone(_ proto: Proto) -> TreeNode? {
    var s = Settled()
    let id = lock.withLock { () -> Int? in
      guard let c = conversations[proto.rawValue].first(where: { !$0.inUse }) ?? newConversation(proto, &s) else {
        return nil
      }
      c.reserved = true
      return c.id
    }
    for (p, i) in s.publish { publish(p, i) }  // its ctl is served next
    guard let id else { return nil }
    return tree.node(file("\(proto.name)/\(id)/ctl"))
  }

  func conversation(_ proto: Proto, _ id: Int) -> Conversation { conversations[proto.rawValue][id] }

  /// Conversation `id`'s directory, made once.
  func publish(_ proto: Proto, _ id: Int) {
    let dir = file("\(proto.name)/\(id)")
    guard tree.node(dir) == nil else { return }
    tree.directory(dir)
    let ctl = tree.stream(dir + "/ctl", NodeStream(perChannel: { [self] in
      lock.withLock {
        let c = conversation(proto, id)
        c.refs += 1
        c.reserved = false
      }
      var read = false
      return NodeStreamChannel(take: { _ in
        // Its number, once, then the end.
        guard !read else { return [] }
        read = true
        return Array("\(id)".utf8)
      }, closed: { [self] in release(proto, id) })
    }, write: { [self] (bytes: [UInt8]) throws(NodeError) -> UInt32? in
      try control(proto, id, bytes)
    }))
    let data = tree.stream(dir + "/data", NodeStream(take: { [self] max in take(proto, id, max) },
      write: { [self] (bytes: [UInt8]) throws(NodeError) -> UInt32? in try send(proto, id, bytes) },
      opened: { [self] in lock.withLock { conversation(proto, id).refs += 1 } },
      closed: { [self] in release(proto, id) }))
    let listen = tree.stream(dir + "/listen", NodeStream(perChannel: { [self] in listener(proto, id) }))
    lock.withLock {
      let c = conversation(proto, id)
      c.ctl = ctl
      c.data = data
      c.listen = listen
    }
    tree.text(dir + "/err", read: { [self] in lock.withLock { conversation(proto, id).error } })
    tree.text(dir + "/local", read: { [self] in lock.withLock { local(conversation(proto, id)) } })
    tree.text(dir + "/remote", read: { [self] in lock.withLock { remote(conversation(proto, id)) } })
    tree.text(dir + "/status", read: { [self] in lock.withLock { status(conversation(proto, id)) } })
  }

  /// One of the conversation's channels closed; the last ends it, as
  /// closeconv does: TCP's connection closed gracefully (reset if data
  /// was left unread), its listener and calls not yet taken reset, UDP's
  /// endpoint closed.
  func release(_ proto: Proto, _ id: Int) {
    settled(Clock.monotonic()) {
      let c = conversation(proto, id)
      c.refs -= 1
      guard !c.inUse else { return }
      if c.handle >= 0 {
        if proto == .tcp { stack.closeTCP(c.handle, now: Clock.monotonic()) } else { stack.closeUDP(c.handle) }
      }
      c.handle = -1
      c.state = .idle
      c.remote = .any
      c.remotePort = 0
      c.localPort = 0
      c.headers = false
      c.waiters = []
    }
  }

  /// A channel on `listen`: it waits for a call on the announced
  /// conversation, then reads as the call's number, and holds the call
  /// while it is open. UDP's conversations take no calls.
  func listener(_ proto: Proto, _ id: Int) -> NodeStreamChannel {
    let w = Waiter()
    let announced = settled(Clock.monotonic()) { () -> Bool in
      let c = conversation(proto, id)
      guard proto == .tcp, c.state == .announced else { return false }
      c.refs += 1
      c.waiters.append(w)
      return true
    }
    guard announced else { return NodeStreamChannel(take: { _ in [] }) }
    return NodeStreamChannel(take: { [self] _ in
      lock.withLock { () -> [UInt8]? in
        if let n = w.accepted {
          guard !w.read else { return [] }
          w.read = true
          return Array("\(n)".utf8)
        }
        return conversation(proto, id).state == .announced ? nil : []
      }
    }, closed: { [self] in
      let call = lock.withLock { () -> Int? in
        conversation(proto, id).waiters.removeAll { $0 === w }
        return w.accepted
      }
      if let call { release(proto, call) }
      release(proto, id)
    })
  }

  // MARK: ctl

  /// A ctl line, as Plan 9's: `connect`, `announce`, and for TCP
  /// `hangup` and `close`, for UDP `headers`. A TCP `connect` is
  /// answered once the handshake ends (nil until then).
  func control(_ proto: Proto, _ id: Int, _ bytes: [UInt8]) throws(NodeError) -> UInt32? {
    var line = bytes
    while let last = line.last, last == 0x0A || last == 0x20 { line.removeLast() }
    // Bytes, not Strings: comparing Strings needs Unicode's tables.
    let words = line.split(separator: 0x20).map { Array($0) }
    let count = UInt32(bytes.count)
    return try settled(Clock.monotonic()) { () throws(NodeError) -> UInt32? in
      let c = conversation(proto, id)
      let now = Clock.monotonic()
      if proto == .tcp, c.state == .connecting {
        // The connect held: answered once the handshake has ended.
        switch stack.tcpState(c.handle) {
        case .synSent, .synReceived: return nil
        case .closed:
          c.error = IP.reason(stack.tcpError(c.handle))
          stack.closeTCP(c.handle, now: now)
          c.handle = -1
          c.state = .closed
          throw .io
        default:
          c.state = .connected
          return count
        }
      }
      guard let verb = words.first else { throw .invalid }
      func named(_ name: String) -> Bool { verb.elementsEqual(name.utf8) }
      if named("connect") {
        guard words.count >= 2, c.state == .idle || c.state == .closed,
          let (address, port) = IP.parseAddress(words[1]), port != 0
        else { throw .invalid }
        if proto == .tcp {
          guard let handle = stack.connectTCP(to: address, port: port, now: now) else {
            c.error = "no route or no free connection"
            throw .io
          }
          c.handle = handle
          c.state = .connecting
          return nil
        }
        var local: UInt16 = 0
        if words.count >= 3 {
          guard let p = UInt16(String(decoding: words[2], as: UTF8.self)) else { throw .invalid }
          local = p
        }
        guard let e = stack.openUDP(port: local) else {
          c.error = "port in use or no free endpoint"
          throw .io
        }
        c.handle = e
        c.localPort = stack.udpPort(e)
        c.remote = address
        c.remotePort = port
        c.state = .connected
        return count
      }
      if named("announce") {
        guard words.count == 2, c.state == .idle || c.state == .closed, let port = IP.parsePort(words[1]) else {
          throw .invalid
        }
        if proto == .tcp {
          guard let handle = announceTCP(port) else {
            c.error = "port in use or no free connection"
            throw .io
          }
          c.handle = handle
          c.localPort = stack.tcpLocal(handle).port
        } else {
          guard let e = stack.openUDP(port: port) else {
            c.error = "port in use or no free endpoint"
            throw .io
          }
          c.handle = e
          c.localPort = stack.udpPort(e)
        }
        c.state = .announced
        return count
      }
      if proto == .tcp, named("hangup") {
        if c.handle >= 0 { stack.abortTCP(c.handle, now: now) }
        c.handle = -1
        c.state = .closed
        return count
      }
      if proto == .tcp, named("close") {
        guard c.state == .connected else { throw .invalid }
        stack.shutdownTCP(c.handle, now: now)
        return count
      }
      if proto == .udp, named("headers") {
        c.headers = true
        return count
      }
      // Accepted, and nothing to do: there are no keepalives, and the
      // stack's TTL and type of service are its own.
      for name in ["keepalive", "ttl", "tos", "ignoreadvice", "bind"] where named(name) { return count }
      throw .invalid
    }
  }

  /// A listener on `port`, or on the first free port from 49152 if it is 0.
  func announceTCP(_ port: UInt16) -> Int? {
    if port != 0 { return stack.listenTCP(port: port) }
    for p in UInt16(49152)...UInt16.max {
      if let l = stack.listenTCP(port: p) { return l }
    }
    return nil
  }

  static func reason(_ error: TCPError) -> String {
    switch error {
    case .none: "connection closed"
    case .refused: "connection refused"
    case .reset: "connection reset"
    case .timedOut: "connection timed out"
    }
  }

  // MARK: data

  /// What a read of data takes: TCP's next bytes (empty at the stream's
  /// end), UDP's next datagram; nil until there are some.
  func take(_ proto: Proto, _ id: Int, _ max: Int) -> [UInt8]? {
    settled(Clock.monotonic()) { () -> [UInt8]? in
      let c = conversation(proto, id)
      if c.state == .closed { return [] }
      guard c.handle >= 0, c.state == .connected || (proto == .udp && c.state == .announced) else { return nil }
      if proto == .tcp {
        // As much as waits, and no buffer when none does: a read is tried
        // for each waiting reader at every settle, and a buffer of the
        // read's size zeroed each time was a tenth of a copy's CPU.
        let count = Swift.min(max, stack.tcpReadable(c.handle))
        guard count > 0 else { return stack.tcpAtEnd(c.handle) ? [] : nil }
        var buffer = [UInt8](repeating: 0, count: count)
        let n = stack.readTCP(c.handle, into: &buffer, max: count, now: Clock.monotonic())
        if n < count { buffer.removeSubrange(n...) }
        return buffer
      }
      var buffer = [UInt8](repeating: 0, count: FrameQueue.slotSize)
      while let d = stack.receiveUDP(c.handle, into: &buffer) {
        if c.headers {
          var record = [UInt8](repeating: 0, count: IP.udpHeaderSize)
          d.source.write(&record, at: 0)
          d.destination.write(&record, at: 16)
          interfaceAddress(for: d.source).write(&record, at: 32)
          record[48] = UInt8(d.sourcePort >> 8)
          record[49] = UInt8(d.sourcePort & 0xFF)
          record[50] = UInt8(c.localPort >> 8)
          record[51] = UInt8(c.localPort & 0xFF)
          return Array((record + buffer[..<d.length]).prefix(max))
        }
        // A connected conversation takes only its peer's.
        if c.state == .connected, d.source != c.remote || d.sourcePort != c.remotePort { continue }
        return Array(buffer[..<Swift.min(d.length, max)])
      }
      return nil
    }
  }

  /// A write of data: TCP takes what its send buffer has room for (nil
  /// while it has none), UDP sends one datagram.
  func send(_ proto: Proto, _ id: Int, _ bytes: [UInt8]) throws(NodeError) -> UInt32? {
    try settled(Clock.monotonic()) { () throws(NodeError) -> UInt32? in
      let c = conversation(proto, id)
      let now = Clock.monotonic()
      guard c.handle >= 0, c.state == .connected || (proto == .udp && c.state == .announced) else { throw .io }
      if bytes.isEmpty { return 0 }
      if proto == .tcp {
        let n = stack.writeTCP(c.handle, bytes, now: now)
        if n > 0 { return UInt32(n) }
        switch stack.tcpState(c.handle) {
        case .established, .closeWait: return nil  // full: wait for room
        default:
          c.error = IP.reason(stack.tcpError(c.handle))
          throw .io
        }
      }
      var to = c.remote, port = c.remotePort, offset = 0
      if c.headers {
        guard bytes.count >= IP.udpHeaderSize else { throw .invalid }
        to = IPv6Address(bytes, at: 0)
        port = UInt16(bytes[48]) << 8 | UInt16(bytes[49])
        offset = IP.udpHeaderSize
      } else if c.state != .connected {
        throw .invalid  // announced without headers: there is no one to send to
      }
      guard stack.sendUDP(c.handle, to: to, port: port, bytes, offset: offset, now: now) else {
        c.error = "no route, or too big for one packet"
        throw .io
      }
      return UInt32(bytes.count)
    }
  }

  /// Our address that `peer` is reached from.
  func interfaceAddress(for peer: IPv6Address) -> IPv6Address {
    if peer.mappedIPv4 != nil { return IPv6Address(mapping: stack.ipv4) }
    return stack.ipv6Addresses.first(where: { $0.isLinkLocal == peer.isLinkLocal }) ?? stack.linkLocalAddress
  }

  // MARK: local, remote, status, stats

  func local(_ c: Conversation) -> String {
    if c.proto == .tcp, c.handle >= 0, c.state != .announced {
      let l = stack.tcpLocal(c.handle)
      return "\(IP.text(l.address))!\(l.port)\n"
    }
    let address = c.state == .connected ? interfaceAddress(for: c.remote) : .any
    return "\(IP.text(address))!\(c.localPort)\n"
  }

  func remote(_ c: Conversation) -> String {
    if c.proto == .tcp, c.handle >= 0, c.state != .announced {
      let r = stack.tcpPeer(c.handle)
      return "\(IP.text(r.address))!\(r.port)\n"
    }
    return "\(IP.text(c.remote))!\(c.remotePort)\n"
  }

  static let tcpStates = ["Closed", "Listen", "Syn_sent", "Syn_received", "Established", "Finwait1", "Finwait2",
                          "Close_wait", "Closing", "Last_ack", "Time_wait"]

  func status(_ c: Conversation) -> String {
    if c.proto == .udp {
      let waiting = c.handle >= 0 ? stack.waitingUDP(c.handle) : 0
      return "\(c.inUse ? "Open" : "Closed") qin \(waiting) qout 0\n"
    }
    guard c.handle >= 0 else { return "Closed qin 0 qout 0\n" }
    let state = stack.tcpState(c.handle)
    let sendable = state == .established || state == .closeWait
    let out = sendable ? stack.tcpRingSize - stack.tcpWritable(c.handle) : 0
    return "\(IP.tcpStates[Int(state.rawValue)]) qin \(stack.tcpReadable(c.handle)) qout \(out)\n"
  }

  func stats(_ proto: Proto) -> String {
    let n = lock.withLock { stack.counters }
    if proto == .tcp {
      return "InSegs: \(n.tcpSegmentsIn)\nOutSegs: \(n.tcpSegmentsOut)\nRetransSegs: \(n.tcpRetransmits)\n"
        + "FastRetransSegs: \(n.tcpFastRetransmits)\nTimeouts: \(n.tcpTimeouts)\nOutRsts: \(n.tcpResetsOut)\n"
        + "Refused: \(n.tcpRefused)\n"
    }
    return "InDatagrams: \(n.udpIn)\nNoPorts: \(n.portsUnreachable)\nInErrors: \(n.udpDropped)\n"
  }

  // MARK: Addresses

  /// An address as Plan 9 prints one: IPv4's (mapped) dotted, else
  /// IPv6's, `::` for none.
  static func text(_ a: IPv6Address) -> String { a.mappedIPv4.map { $0.text } ?? a.text }

  /// `address!port`, as a ctl line gives it: IPv4 or IPv6.
  static func parseAddress(_ word: [UInt8]) -> (IPv6Address, UInt16)? {
    let parts = word.split(separator: 0x21, omittingEmptySubsequences: false)  // "!"
    guard parts.count >= 2, let address = parseIP(Array(parts[0])),
      let port = UInt16(String(decoding: parts[1], as: UTF8.self))
    else { return nil }
    return (address, port)
  }

  /// `[address!]port` of an announce: the port, `*` or 0 for any (the
  /// address is ours, whichever it is).
  static func parsePort(_ word: [UInt8]) -> UInt16? {
    let parts = word.split(separator: 0x21, omittingEmptySubsequences: false)
    guard parts.count <= 2, let last = parts.last else { return nil }
    if parts.count == 2, !parts[0].elementsEqual([0x2A]), parseIP(Array(parts[0])) == nil { return nil }
    if last.elementsEqual([0x2A]) { return 0 }
    return UInt16(String(decoding: last, as: UTF8.self))
  }

  static func parseIP(_ bytes: [UInt8]) -> IPv6Address? {
    let text = String(decoding: bytes, as: UTF8.self)
    if let v4 = IPv4Address(text) { return IPv6Address(mapping: v4) }
    return IPv6Address(text)
  }
}
