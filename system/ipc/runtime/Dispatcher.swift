// SPDX-License-Identifier: BSD-3-Clause

/// A generated server: what a dispatcher drives.
public protocol IPCServing: ~Copyable {
  var connection: IPCServerConnection { get }
  /// Serves one request, waiting until `deadline` for it; false once the
  /// client has closed its end.
  mutating func handleNext(deadline: Int64) throws(IPCError<Never>) -> Bool
}


/// Serves many channels from one thread. A port wakes it when a channel
/// has a request (a ONCE binding, object_bind) or when another thread asks
/// it to do something for a server (`wake`, such as sending queued
/// events), so each server is only ever touched by the dispatcher's
/// thread. It can watch other objects too (`watch`: a ring's counter), on
/// the same thread.
///
/// `add`, `watch`, `unwatch`, `wake` and `stop` may be called from any thread.
public final class IPCDispatcher: @unchecked Sendable {
  final class Entry: @unchecked Sendable {
    /// The channel or watched object, which the entry's closures own.
    let object: UInt32
    let signals: UInt32
    /// Given the signals observed; false when the entry is done.
    let serve: (UInt32) throws(IPCError<Never>) -> Bool
    let wake: () throws(IPCError<Never>) -> Void

    init(object: UInt32, signals: UInt32 = Signals.readable | Signals.peerClosed,
         serve: @escaping (UInt32) throws(IPCError<Never>) -> Bool,
         wake: @escaping () throws(IPCError<Never>) -> Void = {}) {
      self.object = object
      self.signals = signals
      self.serve = serve
      self.wake = wake
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

  public init() throws(Status) { port = try Port.create() }

  /// How many channels it serves.
  public var count: Int { entries.withLock { $0.count } }

  /// Serves `server`'s channel until its client closes it. `wake` runs on
  /// the dispatcher's thread for each `wake(id)`, with the server. Returns
  /// the server's id.
  @discardableResult
  public func add<S: IPCServing & ~Copyable>(
    _ server: consuming S, wake: @escaping (inout S) throws(IPCError<Never>) -> Void = { _ in }
  ) throws(Status) -> UInt64 {
    let box = Box(server)
    let entry = Entry(
      object: box.server.connection.channel.raw,
      serve: { (_: UInt32) throws(IPCError<Never>) -> Bool in try box.server.handleNext(deadline: 0) },
      wake: { () throws(IPCError<Never>) in try wake(&box.server) })
    return try insert(entry)
  }

  /// Calls `handler` on the dispatcher's thread with the signals observed
  /// whenever `object` asserts one of `signals`, until it returns false or
  /// `unwatch`. The dispatcher owns `object` meanwhile. Returns the watch's id.
  @discardableResult
  public func watch(_ object: consuming Handle, signals: UInt32, _ handler: @escaping (UInt32) -> Bool) throws(Status)
    -> UInt64
  {
    let owned = Owned(object)
    let entry = Entry(object: owned.handle.raw, signals: signals) { (observed: UInt32) -> Bool in
      withExtendedLifetime(owned) { handler(observed) }
    }
    return try insert(entry)
  }

  /// Stops a watch (dropping its object) or a server (closing its channel).
  public func unwatch(_ id: UInt64) {
    let entry = entries.withLock { $0.remove(id) }
    if let entry {
      // Cancel the wait while the object is still open: its number may be reused.
      let object = Handle(raw: entry.object)
      try? Port.cancel(port, source: object, key: id)
      _ = object.release()
    }
  }

  func insert(_ entry: Entry) throws(Status) -> UInt64 {
    let id = entries.withLock { e in
      e.lastID += 1
      e.append(e.lastID, entry)
      return e.lastID
    }
    try arm(id, entry)
    return id
  }

  /// Asks the dispatcher to run server `id`'s wake.
  public func wake(_ id: UInt64) {
    try? Port.queue(port, Packet(key: id))
  }

  /// Makes `run` return.
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
      let packet = try Port.wait(port)
      if packet.key == 0 && packet.type == 0 { return }
      guard let entry = entries.withLock({ $0[packet.key] }) else { continue }
      var alive = true
      do throws(IPCError<Never>) {
        if packet.type == 0 {
          try entry.wake()
        } else {
          alive = try entry.serve(packet.observed)
        }
      } catch .transport(.timedOut) {
        // Nothing to read after all (a cancel, now answered).
      } catch {
        alive = false
      }
      if alive && packet.type != 0 {
        // Unless it was unwatched meanwhile.
        if entries.withLock({ $0[packet.key] === entry }) { try arm(packet.key, entry) }
      } else if !alive {
        // Dropping the server closes its channel (outside the lock: its
        // deinit may unwatch).
        let removed = entries.withLock { $0.remove(packet.key) }
        _ = removed
      }
    }
  }

  /// A packet when the entry's object asserts its signals (a channel:
  /// readable or its peer closed).
  func arm(_ id: UInt64, _ entry: Entry) throws(Status) {
    // The entry owns the object: borrow its number, then give it back.
    let object = Handle(raw: entry.object)
    var failure: Status?
    do throws(Status) {
      try object.bind(port: port, key: id, signals: entry.signals)
    } catch {
      failure = error
    }
    _ = object.release()
    if let failure { throw failure }
  }
}
