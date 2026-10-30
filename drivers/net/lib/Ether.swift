// SPDX-License-Identifier: BSD-3-Clause

// The net class (D82): a NIC as Plan 9's ether(3) directory, which a net
// driver serves in its tree and devmgr binds at /net/etherN. As 9front's
// netif.c and devether.c: `clone` opens a conversation's ctl, eight
// conversations (Ntypes), each `N/{ctl,data,type,stats,ifstats}`, and the
// device's `addr`, `stats` and `ifstats`; and `link`, ours, whose read
// waits for the link to change, so ip(4) hears it come up. A conversation takes the frames
// of the type it connects to (ethermux), each whole, one a read, and
// writes whole frames, its address put in as their source. The driver
// gives frames to `receive` and sends what `transmit` is given.

import Node
import Sys

/// What a driver gives the class.
public struct EtherNIC: Sendable {
  /// Its address, 6 bytes.
  public var mac: [UInt8]
  public var mbps: Int
  /// Sends one frame, its header included; false if it couldn't.
  public var transmit: @Sendable ([UInt8]) -> Bool
  /// The driver's own statistics, as text (ifstats).
  public var ifstats: @Sendable () -> String

  public init(mac: [UInt8], mbps: Int, transmit: @escaping @Sendable ([UInt8]) -> Bool,
              ifstats: @escaping @Sendable () -> String = { "" }) {
    self.mac = mac
    self.mbps = mbps
    self.transmit = transmit
    self.ifstats = ifstats
  }
}

/// The device's counters, as netif's.
public struct EtherCounts: Equatable, Sendable {
  public var inPackets: UInt64 = 0
  public var outPackets: UInt64 = 0
  public var crcs = 0
  public var overflows = 0
  public var softOverflows = 0
  public var frames = 0
  public var buffers = 0
  public var outputErrors = 0
  public init() {}
}

public final class Ether: @unchecked Sendable {
  /// Conversations, as Plan 9's Ntypes.
  public static let conversations = 8
  /// Frames a conversation holds before more are dropped (soft overflows):
  /// a TCP connection's whole window (net's 256 KiB, about 180 frames)
  /// arriving at once, while its reader is busy, fits, so a burst isn't
  /// cut into a loss and a halved window.
  public static let queueLimit = 256
  public static let minFrame = 60
  public static let maxFrame = 1514
  static let headerSize = 14

  final class Conversation {
    let id: Int
    var data: TreeNode?
    /// Its open ctl and data channels, and whether clone has made it and
    /// its ctl is about to be served.
    var refs = 0
    var reserved = false
    var type = 0
    var promiscuous = false
    var headersOnly = false
    var multicast: [[UInt8]] = []
    var queue: [[UInt8]] = []
    init(_ id: Int) { self.id = id }
    var inUse: Bool { refs > 0 || reserved }
  }

  let tree: NodeTree
  let path: String
  let nic: EtherNIC
  let lock = Lock()
  var conversations: [Conversation] = []
  var counts = EtherCounts()
  var link = false
  /// `link`, whose readers wait for a change.
  var linkNode: TreeNode?

  /// A reader of `link`: the state it last read (none yet).
  final class LinkReader: @unchecked Sendable {
    var seen: Bool?
  }

  /// Serves the directory at `path` in `tree` ("" for its root).
  public init(tree: NodeTree, at path: String, nic: EtherNIC) {
    self.tree = tree
    self.path = path
    self.nic = nic
    tree.directory(path)
    tree.service(file("clone")) { [self] (channel: consuming Handle) throws(Status) in
      guard let ctl = clone() else { throw .noResources }
      try tree.serve(channel, at: ctl)
    }
    tree.text(file("addr"), read: { [self] in Ether.hex(nic.mac) })
    tree.text(file("stats"), read: { [self] in stats() })
    tree.text(file("ifstats"), read: { nic.ifstats() })
    // `up` or `down`: the state now on a channel's first read, then each
    // read waits until it differs from what that channel last read.
    linkNode = tree.stream(file("link"), NodeStream(perChannel: { [self] in
      let reader = LinkReader()
      return NodeStreamChannel(take: { [self] _ in
        let up = lock.withLock { link }
        guard reader.seen != up else { return nil }
        reader.seen = up
        return Array((up ? "up\n" : "down\n").utf8)
      })
    }))
  }

  func file(_ name: String) -> String { path.isEmpty ? name : path + "/" + name }

  // MARK: The driver's side

  /// A frame the device received: to each conversation that wants it.
  /// Any thread.
  public func receive(_ frame: [UInt8]) { receive([frame]) }

  /// Frames the device received together (an interrupt's): muxed under
  /// one lock, and each conversation told once. Told a frame at a time,
  /// the reader's server woke for the first while the rest came, a wake
  /// or two a frame along the receive path.
  public func receive(_ frames: [[UInt8]]) {
    guard !frames.isEmpty else { return }
    let ready = lock.withLock { () -> [TreeNode] in
      var ready: [TreeNode] = []
      for frame in frames {
        counts.inPackets += 1
        for node in mux(frame, from: nil) where !ready.contains(where: { $0 === node }) { ready.append(node) }
      }
      return ready
    }
    for node in ready { tree.ready(node) }
  }

  public func setLink(_ up: Bool) {
    let changed = lock.withLock { () -> Bool in
      defer { link = up }
      return link != up
    }
    if changed, let n = linkNode { tree.ready(n) }
  }

  /// A frame the device lost for want of a buffer.
  public func overflow() { lock.withLock { counts.overflows += 1 } }

  public var current: EtherCounts { lock.withLock { counts } }

  // MARK: Conversations

  /// The first conversation not in use, made if need be, reserved for the
  /// ctl that clone serves; nil if all are.
  func clone() -> TreeNode? {
    let (made, id) = lock.withLock { () -> (Bool, Int?) in
      if let c = conversations.first(where: { !$0.inUse }) {
        c.reserved = true
        return (false, c.id)
      }
      guard conversations.count < Ether.conversations else { return (false, nil) }
      let c = Conversation(conversations.count)
      c.reserved = true
      conversations.append(c)
      return (true, c.id)
    }
    guard let id else { return nil }
    if made { publish(id) }
    return tree.node(file("\(id)/ctl"))
  }

  func conversation(_ id: Int) -> Conversation { conversations[id] }

  /// Conversation `id`'s directory.
  func publish(_ id: Int) {
    let dir = file("\(id)")
    tree.directory(dir)
    tree.stream(dir + "/ctl", NodeStream(perChannel: { [self] in
      lock.withLock {
        let c = conversation(id)
        c.refs += 1
        c.reserved = false
      }
      var read = false
      return NodeStreamChannel(take: { _ in
        // Its number, once (netif's readnum), then the end.
        guard !read else { return [] }
        read = true
        return Array(Ether.number(id).utf8)
      }, closed: { [self] in release(id) })
    }, write: { [self] (bytes: [UInt8]) throws(NodeError) in
      try control(id, String(decoding: bytes, as: UTF8.self))
      return UInt32(bytes.count)
    }))
    let data = tree.stream(dir + "/data", NodeStream(take: { [self] max in take(id, max) },
      write: { [self] (bytes: [UInt8]) throws(NodeError) in try send(id, bytes) },
      opened: { [self] in lock.withLock { conversation(id).refs += 1 } },
      closed: { [self] in release(id) }))
    lock.withLock { conversation(id).data = data }
    tree.text(dir + "/type", read: { [self] in Ether.number(lock.withLock { conversation(id).type }) })
    tree.text(dir + "/stats", read: { [self] in stats() })
    tree.text(dir + "/ifstats", read: { [self] in nic.ifstats() })
  }

  /// One of the conversation's channels closed; the last ends it, as
  /// netifclose does.
  func release(_ id: Int) {
    lock.withLock {
      let c = conversation(id)
      c.refs -= 1
      guard !c.inUse else { return }
      c.type = 0
      c.promiscuous = false
      c.headersOnly = false
      c.multicast = []
      c.queue = []
    }
  }

  /// A ctl line (netifwrite's and devether's).
  func control(_ id: Int, _ text: String) throws(NodeError) {
    var line = Array(text.utf8)
    while let last = line.last, last == 0x0A || last == 0x20 { line.removeLast() }
    // Bytes, not Strings: comparing Strings needs Unicode's tables.
    let words = line.split(separator: 0x20).map { Array($0) }
    guard let verb = words.first else { throw .invalid }
    func named(_ name: String) -> Bool { verb.elementsEqual(name.utf8) }
    let argument = words.count == 2 ? String(decoding: words[1], as: UTF8.self) : nil
    try lock.withLock { () throws(NodeError) in
      let c = conversation(id)
      if named("connect") {
        guard let argument, let type = Ether.parseType(argument) else { throw .invalid }
        if type > 0, conversations.contains(where: { $0.inUse && $0.type == type }) { throw .exists }
        c.type = type
      } else if named("promiscuous") {
        c.promiscuous = true
      } else if named("headersonly") {
        c.headersOnly = true
      } else if named("nonblocking") {
        // Writes never wait here.
      } else if named("addmulti") || named("delmulti") || named("remmulti") {
        guard let argument, let address = Ether.parseAddress(argument) else { throw .invalid }
        c.multicast.removeAll { $0 == address }
        if named("addmulti") { c.multicast.append(address) }
      } else {
        throw .invalid
      }
    }
  }

  /// The conversation's next frame, cut to `max` as a message queue reads.
  func take(_ id: Int, _ max: Int) -> [UInt8]? {
    lock.withLock {
      let c = conversation(id)
      guard !c.queue.isEmpty else { return nil }
      let frame = c.queue.removeFirst()
      return frame.count > max ? Array(frame.prefix(max)) : frame
    }
  }

  /// A frame written to a conversation's data: its source made the
  /// device's, a copy to each conversation that wants it, then sent.
  func send(_ id: Int, _ bytes: [UInt8]) throws(NodeError) -> UInt32 {
    guard bytes.count >= Ether.minFrame, bytes.count <= Ether.maxFrame else { throw .invalid }
    var frame = bytes
    for i in 0..<6 { frame[6 + i] = nic.mac[i] }
    let ready = lock.withLock { mux(frame, from: id) }
    for node in ready { tree.ready(node) }
    let sent = nic.transmit(frame)
    lock.withLock { if sent { counts.outPackets += 1 } else { counts.outputErrors += 1 } }
    return UInt32(bytes.count)
  }

  /// ethermux, without bridges: each conversation's copy of `frame`, from
  /// the device (nil) or written to conversation `from`; the data nodes
  /// whose readers have more. Under the lock.
  func mux(_ frame: [UInt8], from: Int?) -> [TreeNode] {
    guard frame.count >= Ether.headerSize else { return [] }
    let promiscuous = conversations.contains { $0.inUse && $0.promiscuous }
    let multi = frame[0] & 1 != 0
    let tome: Bool
    if !multi {
      // Sent to someone else: only the promiscuous see it.
      if from != nil && !promiscuous { return [] }
      tome = from == nil && Array(frame[0..<6]) == nic.mac
    } else {
      let destination = Array(frame[0..<6])
      if from == nil && !promiscuous && destination != Ether.broadcast
        && !conversations.contains(where: { $0.inUse && $0.multicast.contains(destination) }) {
        return []
      }
      tome = false
    }
    let type = Int(frame[12]) << 8 | Int(frame[13])
    var ready: [TreeNode] = []
    for c in conversations where c.refs > 0 {
      if c.type != type && c.type >= 0 { continue }
      if !tome && !multi && !c.promiscuous { continue }
      guard c.queue.count < Ether.queueLimit else {
        if !(c.headersOnly || c.type == -2) { counts.softOverflows += 1 }
        continue
      }
      c.queue.append(c.headersOnly || c.type == -2 ? Ether.header(frame, timed: c.type != -2) : frame)
      if let data = c.data { ready.append(data) }
    }
    return ready
  }

  // MARK: Text

  /// The device's stats (netifread's Nstatqid).
  func stats() -> String {
    let (c, up, prom) = lock.withLock {
      (counts, link, conversations.filter { $0.inUse && $0.promiscuous }.count)
    }
    return "in: \(c.inPackets)\nlink: \(up ? 1 : 0)\nout: \(c.outPackets)\ncrc errs: \(c.crcs)\n"
      + "overflows: \(c.overflows)\nsoft overflows: \(c.softOverflows)\nframing errs: \(c.frames)\n"
      + "buffer errs: \(c.buffers)\noutput errs: \(c.outputErrors)\nprom: \(prom)\nmbps: \(nic.mbps)\n"
      + "addr: \(Ether.hex(nic.mac))\n"
  }

  static let broadcast: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]

  /// readnum's: right-justified in 11 columns and a blank, as Plan 9's
  /// 32-bit ulong (so -1 reads 4294967295).
  public static func number(_ n: Int) -> String {
    let digits = String(UInt32(truncatingIfNeeded: n))
    return String(repeating: " ", count: max(0, 11 - digits.utf8.count)) + digits + " "
  }

  /// `525400123456`: an address as addr and stats give it.
  public static func hex(_ bytes: [UInt8]) -> String {
    let digits = Array("0123456789abcdef".utf8)
    var out: [UInt8] = []
    for b in bytes { out += [digits[Int(b >> 4)], digits[Int(b & 15)]] }
    return String(decoding: out, as: UTF8.self)
  }

  /// connect's type, as strtoul reads it: 0x for hex, a leading 0 for
  /// octal, and - for the types that take every frame.
  public static func parseType(_ text: String) -> Int? {
    var s = Array(text.utf8)
    let negative = s.first == UInt8(ascii: "-")
    if negative { s.removeFirst() }
    var base = 10
    if s.count > 2, s[0] == UInt8(ascii: "0"), s[1] | 0x20 == UInt8(ascii: "x") {
      base = 16
      s.removeFirst(2)
    } else if s.count > 1, s[0] == UInt8(ascii: "0") {
      base = 8
    }
    guard !s.isEmpty else { return nil }
    var n = 0
    for b in s {
      let d: Int
      switch b {
      case UInt8(ascii: "0")...UInt8(ascii: "9"): d = Int(b) - 0x30
      case UInt8(ascii: "a")...UInt8(ascii: "f"): d = Int(b) - 0x57
      case UInt8(ascii: "A")...UInt8(ascii: "F"): d = Int(b) - 0x37
      default: return nil
      }
      guard d < base, n < 1 << 32 else { return nil }
      n = n * base + d
    }
    // A type is a 32-bit int, as Plan 9's.
    return Int(Int32(truncatingIfNeeded: negative ? -n : n))
  }

  /// An address in hex, its bytes maybe separated by colons.
  public static func parseAddress(_ text: String) -> [UInt8]? {
    let digits = Array(text.utf8).filter { $0 != UInt8(ascii: ":") }
    guard digits.count == 12 else { return nil }
    var out: [UInt8] = []
    for i in stride(from: 0, to: 12, by: 2) {
      guard let pair = UInt8(String(decoding: digits[i..<(i + 2)], as: UTF8.self), radix: 16) else { return nil }
      out.append(pair)
    }
    return out
  }

  /// headersonly's record (etherrtrace): the frame's first 64 bytes, and
  /// unless the type is -2, its length at 58 and the milliseconds at 60,
  /// big-endian.
  static func header(_ frame: [UInt8], timed: Bool) -> [UInt8] {
    var record = Array(frame.prefix(64))
    record += [UInt8](repeating: 0, count: 64 - record.count)
    if timed {
      let ms = UInt32(truncatingIfNeeded: Clock.monotonic() / 1_000_000)
      record[58] = UInt8(truncatingIfNeeded: frame.count >> 8)
      record[59] = UInt8(truncatingIfNeeded: frame.count)
      for i in 0..<4 { record[60 + i] = UInt8(truncatingIfNeeded: ms >> (24 - 8 * UInt32(i))) }
    }
    return record
  }
}
