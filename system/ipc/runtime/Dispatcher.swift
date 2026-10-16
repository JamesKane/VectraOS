// SPDX-License-Identifier: BSD-3-Clause

/// A generated server: what a dispatcher drives.
public protocol IPCServing: ~Copyable {
  var connection: IPCServerConnection { get set }
  /// Serves one message already read from its channel.
  mutating func handle(_ message: IPCMessage) throws(IPCError<Never>)
}

/// The replies and events the servers send while the dispatcher serves
/// them, written together in one array (channel_write, D41). Only the
/// dispatcher's thread touches it.
final class IPCOutbox {
  /// The entry being served, whose messages these are.
  var key: UInt64 = 0
  var keys: [UInt64] = []
  var items: [Channel.Outgoing] = []

  func append(_ message: IPCMessage, to channel: UInt32) {
    keys.append(key)
    items.append(Channel.Outgoing(channel: channel, bytes: message.bytes, handles: message.handles))
  }

  /// Drops entry `key`'s messages, closing their handles: before its
  /// channel closes, whose number may be reused.
  func discard(_ key: UInt64) {
    var i = 0
    while i < keys.count {
      if keys[i] == key {
        for h in items[i].handles { Sys.close(raw: h) }
        keys.remove(at: i)
        items.remove(at: i)
      } else {
        i += 1
      }
    }
  }

  /// Writes them all; the keys of the entries whose writes failed.
  func flush() -> [UInt64] {
    guard !items.isEmpty else { return [] }
    var failed: [UInt64] = []
    if (try? Channel.write(&items)) == nil {
      failed = keys  // nothing went (the call refused the array)
    } else {
      for i in items.indices where items[i].status != .ok { failed.append(keys[i]) }
    }
    keys.removeAll(keepingCapacity: true)
    items.removeAll(keepingCapacity: true)
    return failed
  }
}

/// Serves many channels from one thread. Each channel is bound to the
/// dispatcher's port once, PERSISTENT (object_bind): a packet comes when it
/// becomes readable or its peer closes, so the dispatcher reads it until it
/// would block. A wakeup takes up to CROI_PORT_MAX_PACKETS packets, reads
/// one message from every ready channel in one channel_read array, has
/// their servers handle them, and writes every reply and event in one
/// channel_write array, round after round until no channel has more. Another
/// thread may ask it to do something for a server (`wake`, such as sending
/// queued events), so each server is only ever touched by the dispatcher's
/// thread. It can watch other objects too (`watch`: a ring's counter), on
/// the same thread.
///
/// `add`, `watch`, `unwatch`, `wake` and `stop` may be called from any thread.
public final class IPCDispatcher: @unchecked Sendable {
  final class Entry: @unchecked Sendable {
    /// The channel or watched object, which the entry's closures own.
    let object: UInt32
    let signals: UInt32
    /// A server's: serves one message read from its channel.
    let handle: ((IPCMessage) throws(IPCError<Never>) -> Void)?
    /// A watch's: given the signals observed; false when it is done.
    let observe: ((UInt32) -> Bool)?
    let wake: () throws(IPCError<Never>) -> Void

    init(server object: UInt32, handle: @escaping (IPCMessage) throws(IPCError<Never>) -> Void,
         wake: @escaping () throws(IPCError<Never>) -> Void) {
      self.object = object
      signals = Signals.readable | Signals.peerClosed
      self.handle = handle
      observe = nil
      self.wake = wake
    }

    init(watch object: UInt32, signals: UInt32, observe: @escaping (UInt32) -> Bool) {
      self.object = object
      self.signals = signals
      handle = nil
      self.observe = observe
      wake = {}
    }
  }

  /// A watched object, owned by its entry.
  final class Owned {
    let handle: Handle
    init(_ handle: consuming Handle) { self.handle = handle }
  }

  /// A server, kept where the entry's closures can reach it.
  final class Box<S: IPCServing & ~Copyable> {
    var server: S
    init(_ server: consuming S) { self.server = server }
  }

  /// Entries by id, in an array sorted by id: ids only grow, so a new one
  /// goes at the end. (No hashed collections in tier 0: Embedded Swift's
  /// need libm and a random seed.)
  struct Entries {
    var ids: [UInt64] = []
    var all: [Entry] = []
    var lastID: UInt64 = 0

    var count: Int { ids.count }

    func index(_ id: UInt64) -> Int? {
      var low = 0, high = ids.count
      while low < high {
        let mid = (low + high) / 2
        if ids[mid] < id { low = mid + 1 } else { high = mid }
      }
      return low < ids.count && ids[low] == id ? low : nil
    }

    subscript(id: UInt64) -> Entry? { index(id).map { all[$0] } }

    mutating func append(_ id: UInt64, _ entry: Entry) {
      ids.append(id)
      all.append(entry)
    }

    mutating func remove(_ id: UInt64) -> Entry? {
      guard let i = index(id) else { return nil }
      ids.remove(at: i)
      return all.remove(at: i)
    }
  }

  let port: Handle
  let entries = Locked(Entries())
  let outbox = IPCOutbox()

  public init() throws(Status) { port = try Port.create() }

  /// How many channels it serves and objects it watches.
  public var count: Int { entries.withLock { $0.count } }

  /// Serves `server`'s channel until its client closes it. `wake` runs on
  /// the dispatcher's thread for each `wake(id)`, with the server. Returns
  /// the server's id.
  @discardableResult
  public func add<S: IPCServing & ~Copyable>(
    _ server: consuming S, wake: @escaping (inout S) throws(IPCError<Never>) -> Void = { _ in }
  ) throws(Status) -> UInt64 {
    server.connection.outbox = outbox
    let box = Box(server)
    let entry = Entry(
      server: box.server.connection.channel.raw,
      handle: { (message: IPCMessage) throws(IPCError<Never>) in try box.server.handle(message) },
      wake: { () throws(IPCError<Never>) in try wake(&box.server) })
    return try insert(entry)
  }

  /// Calls `handler` on the dispatcher's thread with the signals observed
  /// each time one of `signals` rises on `object` (a PERSISTENT binding:
  /// one that stays asserted calls it no more, so the handler clears what
  /// it was told of, as a reader drains a channel), until it returns false
  /// or `unwatch`. The dispatcher owns `object` meanwhile. Returns the
  /// watch's id.
  @discardableResult
  public func watch(_ object: consuming Handle, signals: UInt32, _ handler: @escaping (UInt32) -> Bool) throws(Status)
    -> UInt64
  {
    let owned = Owned(object)
    let entry = Entry(watch: owned.handle.raw, signals: signals) { (observed: UInt32) -> Bool in
      withExtendedLifetime(owned) { handler(observed) }
    }
    return try insert(entry)
  }

  /// Stops a watch (dropping its object) or a server (closing its
  /// channel): the dispatcher does it on its thread, as it does a wake,
  /// so no server is closed while it serves one.
  public func unwatch(_ id: UInt64) {
    try? Port.queue(port, Packet(key: id, payload: (Self.removal, 0, 0, 0)))
  }

  /// A user packet's payload.0 that asks for its key's removal.
  static var removal: UInt64 { 1 }

  /// Adds an entry and binds its object, once and for good.
  func insert(_ entry: Entry) throws(Status) -> UInt64 {
    let id = entries.withLock { e in
      e.lastID += 1
      e.append(e.lastID, entry)
      return e.lastID
    }
    // The entry owns the object: borrow its number, then give it back.
    let object = Handle(raw: entry.object)
    var failure: Status?
    do throws(Status) {
      try object.bind(port: port, key: id, signals: entry.signals, persistent: true)
    } catch {
      failure = error
    }
    _ = object.release()
    if let failure {
      _ = entries.withLock { $0.remove(id) }
      throw failure
    }
    return id
  }

  /// Asks the dispatcher to run server `id`'s wake.
  public func wake(_ id: UInt64) {
    try? Port.queue(port, Packet(key: id))
  }

  /// Makes `run` return, once it has served what it was woken for.
  public func stop() {
    try? Port.queue(port, Packet(key: 0))
  }

  /// Drops every server, closing their channels: for a service that is
  /// done, once `run` has returned.
  public func removeAll() {
    // Moved out, then dropped outside the lock: a server's deinit may
    // unwatch. (A copy isn't enough: the optimizer may release the
    // original's storage last, under the lock.)
    var all = Entries()
    entries.withLock { e in
      all.lastID = e.lastID
      swap(&all, &e)
    }
    withExtendedLifetime(all.all) {}
  }

  /// Serves until `stop`.
  public func run() throws(Status) {
    while true {
      let packets = try Port.wait(port, max: Int(CROI_PORT_MAX_PACKETS))
      var stopping = false
      var ready: [UInt64] = []
      for packet in packets {
        if packet.type == CROI_PKT_TYPE_USER {
          if packet.key == 0 {
            stopping = true
          } else if packet.payload.0 == Self.removal {
            remove(packet.key)
          } else if let entry = entries.withLock({ $0[packet.key] }) {
            outbox.key = packet.key
            do throws(IPCError<Never>) { try entry.wake() } catch { remove(packet.key) }
          }
          continue
        }
        guard let entry = entries.withLock({ $0[packet.key] }) else { continue }  // removed meanwhile
        if let observe = entry.observe {
          if !observe(packet.observed) { remove(packet.key) }
        } else if !ready.contains(packet.key) {
          ready.append(packet.key)
        }
      }
      try serve(ready)
      if stopping { return }
    }
  }

  /// Reads the ready channels in arrays until each would block, its
  /// server handling each message, and writes their replies and events
  /// after each round. A channel whose client has gone, or whose server
  /// fails, is dropped with its server.
  func serve(_ ready: [UInt64]) throws(Status) {
    var ready = ready
    while true {
      for key in outbox.flush() { remove(key) }
      guard !ready.isEmpty else { return }
      let round = entries.withLock { e in ready.compactMap { key in e[key].map { (key, $0) } } }
      var reads = round.map { Channel.Incoming(channel: $0.1.object) }
      try Channel.read(&reads)
      ready.removeAll(keepingCapacity: true)
      for (i, (key, entry)) in round.enumerated() {
        switch reads[i].status {
        case .ok:
          guard let m = reads[i].message, let handle = entry.handle else { continue }
          outbox.key = key
          do throws(IPCError<Never>) {
            try handle(IPCMessage(bytes: m.bytes, handles: m.handles))
            ready.append(key)  // it may have more
          } catch {
            remove(key)
          }
        case .shouldWait:
          break  // drained: the next message brings a packet
        default:
          remove(key)  // peerClosed: the client has gone
        }
      }
    }
  }

  /// Drops an entry and its unsent messages: a server closes its channel,
  /// a watch its object, either ending its binding (outside the lock: a
  /// server's deinit may unwatch).
  func remove(_ key: UInt64) {
    outbox.discard(key)
    let removed = entries.withLock { $0.remove(key) }
    _ = removed
  }
}
