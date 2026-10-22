// SPDX-License-Identifier: BSD-3-Clause

// Loop (sdk(2)): one port. Everything the loop waits for queues a packet
// there: a user packet for a wake, a post or a routed message, and each
// window's channel and input doorbell (WindowSystem), bound persistently.
// Its timers, and the frames it owes, are the port wait's deadline (D25,
// D27: there are no timer objects). An idle loop with nothing due waits in
// port_wait with no deadline and wakes zero times. A blocking wait is a
// `loop.wait` zone: the idle-wakeup budget counts them.

import Sys
import Trace

public enum LoopError: Error, Equatable, CustomStringConvertible {
  /// The kernel refused a resource the loop needs (its status).
  case system(Int32)

  public var description: String {
    switch self {
    case .system(let e): "the kernel refused the loop a resource (status \(e))"
    }
  }
}

/// What other threads use to reach a loop: `wake` and `post`.
public struct LoopRemote: Sendable {
  let shared: LoopShared

  /// Wakes the loop. Wakes are coalesced: many before the loop runs make
  /// one `.wake` event.
  public func wake() { shared.signal(wake: true) }

  /// Posts a message; it arrives as a `.message` event, in order.
  public func post(_ message: Message) {
    shared.lock.withLock { shared.messages.append(message) }
    shared.signal(wake: false)
  }
}

/// State shared between a loop and its remotes, and the threads reading
/// its plumber ports (Route.swift).
final class LoopShared: @unchecked Sendable {
  let lock = Lock()
  let portRaw: UInt32  // the loop's port, which outlives this
  var messages: [Message] = []
  var routed: [(ListenID, RouteMessage)] = []
  var wakeRequested = false
  var themeChanged = false
  /// The theme's generation, from its last change line (D119).
  var themeGeneration: UInt64 = 0
  var signaled = false  // a packet is queued that the loop hasn't taken

  init(portRaw: UInt32) { self.portRaw = portRaw }

  func signal(wake: Bool) {
    let queue = lock.withLock { () -> Bool in
      if wake { wakeRequested = true }
      defer { signaled = true }
      return !signaled
    }
    if queue {
      let port = Handle(raw: portRaw)
      try? Port.queue(port, Packet(key: Loop.sharedKey))
      _ = port.release()
    }
  }

  func route(_ id: ListenID, _ message: RouteMessage) {
    lock.withLock { routed.append((id, message)) }
    signal(wake: false)
  }

  func themeChange(generation: UInt64) {
    lock.withLock {
      themeChanged = true
      if generation != 0 { themeGeneration = generation }
    }
    signal(wake: false)
  }
}

public struct Loop: ~Copyable {
  struct Timer {
    var id: TimerID
    var deadline: Deadline
    var leeway: Duration
    var interval: Duration?
  }

  let port: Handle
  let shared: LoopShared
  var timers: [Timer] = []
  var nextID: UInt64 = 1
  var seq: UInt64 = 0
  var buffer: [Event] = []
  var windows: WindowSystem?
  /// The plumber's ports it listens on (Route.swift).
  var routing: Routing?
  /// Whether a thread reads the theme's changes (Theme.swift).
  var followingTheme = false
  var deadlineFired = false

  /// How many times `wait` has returned from the kernel: the number the
  /// idle-wakeup budget counts.
  public private(set) var wakeups: UInt64 = 0

  static let waitName = TraceName("loop.wait")
  static let sharedKey: UInt64 = 1
  /// Window keys: 0x100 + slot for its channel, 0x200 + slot for its
  /// input's doorbell.
  static let channelKeys: UInt64 = 0x100
  static let inputKeys: UInt64 = 0x200

  public init() throws(LoopError) {
    let port: Handle
    do { port = try Port.create() } catch { throw .system(error.rawValue) }
    shared = LoopShared(portRaw: port.raw)
    self.port = port
  }

  /// A handle for other threads to wake this loop or post to it.
  public var remote: LoopRemote { LoopRemote(shared: shared) }

  /// Wakes the loop from its own thread (other threads use `remote`).
  public func wake() { remote.wake() }

  /// Posts a message from the loop's own thread.
  public func post(_ message: Message) { remote.post(message) }

  // MARK: Timers

  /// A timer at `deadline`, which may fire up to `leeway` late so that
  /// nearby timers share one wakeup; `repeating` re-arms it that much later
  /// each time, from the deadline, so it doesn't drift.
  public mutating func timer(at deadline: Deadline, leeway: Duration = .zero, repeating: Duration? = nil)
    -> TimerID
  {
    let id = TimerID(raw: nextID)
    nextID += 1
    timers.append(Timer(id: id, deadline: deadline, leeway: leeway, interval: repeating))
    return id
  }

  public mutating func cancel(_ id: TimerID) {
    timers.removeAll { $0.id == id }
  }

  /// When the wait must end: the earliest any timer's window closes, or a
  /// window's frame comes due, or the compositor is tried again; nil for
  /// none.
  func due() -> Deadline? {
    var fire = timers.map { Deadline(ns: $0.deadline.ns &+ $0.leeway.nanoseconds) }.min()
    if let d = windows?.nextFrameDue() { fire = fire.map { min($0, d) } ?? d }
    return fire
  }

  // MARK: Waiting

  /// Blocks until there is something to report, or until `deadline` (with
  /// `leeway`) if given, and returns what happened.
  public mutating func wait(until deadline: Deadline? = nil, leeway: Duration = .zero) -> Events {
    var oneShot: TimerID?
    if let deadline { oneShot = timer(at: deadline, leeway: leeway) }
    collect(blocking: buffer.isEmpty, deadlineTimer: oneShot)
    if let oneShot { cancel(oneShot) }
    framesLast()
    defer { buffer = [] }
    return Events(items: buffer)
  }

  /// Returns what has already happened, without blocking.
  public mutating func poll() -> Events {
    collect(blocking: false, deadlineTimer: nil)
    framesLast()
    defer { buffer = [] }
    return Events(items: buffer)
  }

  /// Moves `.frame` events to the end of the batch, renumbering `seq`, so
  /// a frame is drawn for the newest configuration.
  mutating func framesLast() {
    guard buffer.count > 1, let first = buffer.first?.seq else { return }
    var others: [Event] = [], frames: [Event] = []
    for e in buffer {
      if case .frame = e.payload { frames.append(e) } else { others.append(e) }
    }
    guard !frames.isEmpty, !others.isEmpty else { return }
    buffer = others + frames
    for i in buffer.indices { buffer[i].seq = first + UInt64(i) }
  }

  mutating func collect(blocking: Bool, deadlineTimer: TimerID?) {
    var block = blocking
    while true {
      // Frames and timers whose time has come, without a wait.
      dueNow(deadlineTimer: deadlineTimer)
      if !buffer.isEmpty || deadlineFired { block = false }
      let start = Trace.now()
      let limit: Int64 = block ? due().map { Int64(min($0.ns, UInt64(Int64.max))) } ?? infiniteDeadline : 0
      let packets = (try? Port.wait(port, deadline: limit, max: 16)) ?? []
      if block {
        wakeups += 1
        Trace.zone(Self.waitName, .app, since: start)
      }
      for p in packets { take(p) }
      // And whatever else is queued.
      while !packets.isEmpty, let more = try? Port.wait(port, deadline: 0, max: 16), !more.isEmpty {
        for p in more { take(p) }
      }
      dueNow(deadlineTimer: deadlineTimer)
      if !buffer.isEmpty || !block || deadlineFired { break }
    }
    deadlineFired = false
  }

  mutating func dueNow(deadlineTimer: TimerID?) {
    fireTimers(deadlineTimer: deadlineTimer)
    guard let system = windows else { return }
    system.reconnectIfDue(loop: &self)
    system.emitDueFrames(loop: &self)
  }

  mutating func take(_ p: Packet) {
    switch p.key {
    case Self.sharedKey: drainShared()
    case Self.channelKeys..<Self.inputKeys:
      windows?.channelReady(slot: Int(p.key - Self.channelKeys), loop: &self)
    case Self.inputKeys..<(Self.inputKeys + 0x100):
      windows?.inputReady(slot: Int(p.key - Self.inputKeys), loop: &self)
    default: break
    }
  }

  mutating func append(_ payload: Event.Payload, window: WindowID = .none) {
    seq += 1
    buffer.append(Event(payload: payload, window: window, time: .now, seq: seq))
  }

  mutating func drainShared() {
    let (messages, routed, wake, theme, generation) = shared.lock.withLock {
      () -> ([Message], [(ListenID, RouteMessage)], Bool, Bool, UInt64) in
      defer {
        shared.messages.removeAll(keepingCapacity: true)
        shared.routed.removeAll(keepingCapacity: true)
        shared.wakeRequested = false
        shared.themeChanged = false
        shared.signaled = false
      }
      return (shared.messages, shared.routed, shared.wakeRequested, shared.themeChanged, shared.themeGeneration)
    }
    for m in messages { append(.message(m)) }
    for (id, m) in routed where routing?.listening(id) ?? false { append(.routed(id, m)) }
    if theme {
      // Each window's next present is drawn in it (D119): Radharc times
      // the switch by it.
      if generation != 0, let system = windows {
        for case let w? in system.slots where w.connected { try? w.client.drawnIn(generation: generation) }
      }
      append(.themeChanged)
    }
    if wake { append(.wake) }
  }

  mutating func fireTimers(deadlineTimer: TimerID?) {
    let now = Deadline.now
    var fired: [(TimerID, UInt64)] = []
    for i in timers.indices.reversed() where timers[i].deadline <= now {
      if let interval = timers[i].interval, interval.nanoseconds > 0 {
        let step = interval.nanoseconds
        let behind = (now.ns - timers[i].deadline.ns) / step
        timers[i].deadline.ns += (behind + 1) * step
        fired.append((timers[i].id, behind))
      } else {
        fired.append((timers[i].id, 0))
        timers.remove(at: i)
      }
    }
    for (id, missed) in fired.reversed() {
      if id == deadlineTimer { deadlineFired = true } else { append(.timer(id, missed: missed)) }
    }
  }
}
