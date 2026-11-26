// SPDX-License-Identifier: BSD-3-Clause

// A device's stream (D180): its cyclic buffer, counted by a Cycle, and the
// device it runs on. The client side (a write or read of `data`) runs on
// the unit's data dispatcher; the device side (`finished`) on the
// driver's interrupt thread. One lock covers the counts and the state;
// the device's own lock is taken under it, never the other way.
//
// A playback stream starts at its first write and stops once it has
// drained (Cycle.drained). A capture stream starts at its first read and
// winds down when its reader stops reading: two overruns with no read
// between them. Winding down hands no more periods, and the device is
// stopped once it holds none, so the interrupt thread never waits for it.
// An explicit stop (ctl, or a change of format) waits, off the lock,
// for the device to give back what it holds.
//
// A lent stream (D181) is the lessee's: it runs from the lease to its
// end without draining, the class writes nothing into its buffer, and
// each period finished adds 1 to the lease's counter.

import IPC
import Node
import Sys
import Synchronization

/// A stream's buffer, in memory the device reaches: valid while the
/// stream is prepared, and written only as the stream's Cycle allows.
@safe public struct AudioBuffer: @unchecked Sendable {
  public let bytes: UnsafeMutableRawBufferPointer
  @unsafe public init(_ bytes: UnsafeMutableRawBufferPointer) { unsafe self.bytes = bytes }
  public var count: Int { unsafe bytes.count }
  /// Bytes `range` set to `byte` (silence).
  public func fill(_ range: Range<Int>, with byte: UInt8) {
    precondition(range.lowerBound >= 0 && range.upperBound <= count)
    for i in range { unsafe bytes[i] = byte }
  }
}

/// An audio device, as its driver gives it to the class.
public protocol AudioHardware: AnyObject, Sendable {
  /// What stat's first class line says.
  var name: String { get }
  /// What a direction's stream takes; nil if the device has none.
  func capabilities(_ d: AudioDirection) -> PCMCapabilities?
  /// The largest buffer a stream may have, in bytes.
  var maxBufferBytes: Int { get }
  /// Frames between the buffer and the converter (FIFOs, the codec).
  var externalDelay: Int { get }
  /// Sets up `d` for `format`, with a buffer of `periods` periods of
  /// `periodBytes`: the buffer. Called with the stream stopped.
  func prepare(_ d: AudioDirection, _ format: PCMFormat, periodBytes: Int, periods: Int)
    throws(NodeIPC.NodeError) -> AudioBuffer
  func start(_ d: AudioDirection) throws(NodeIPC.NodeError)
  /// Hands period `slot` of `d`'s buffer to the device. The device says
  /// each is done (AudioUnit.finished) in the order handed.
  func hand(_ d: AudioDirection, slot: Int)
  /// Stops `d`. Returns once each period the device held is given back,
  /// through AudioUnit.finished.
  func stop(_ d: AudioDirection)
  /// The VMO under `d`'s buffer, a handle of its own, to lend (D181);
  /// `unsupported` if the device can't lend it.
  func lend(_ d: AudioDirection) throws(NodeIPC.NodeError) -> Handle
}

final class AudioStream: @unchecked Sendable {
  enum State: Equatable { case stopped, running, winding, stopping }

  let direction: AudioDirection
  let hardware: AudioHardware
  let lock = Lock()
  var format: PCMFormat
  var periodFrames: Int
  var periods: Int
  var lead: Int
  var cycle: Cycle?
  var buffer: AudioBuffer?
  var state = State.stopped
  /// Read since the last overrun (capture).
  var readSinceOverrun = true
  /// When the device last finished a period, and how many of the
  /// stream's runs and failures there were.
  var finishedAt: Int64 = 0
  var runs = 0
  /// Periods the device played or recorded while the stream ran, and
  /// their bytes: not those it gave back at a stop.
  var played: UInt64 = 0
  var playedBytes: UInt64 = 0
  var failure: NodeIPC.NodeError?
  /// Lent (D181): the lessee writes the buffer, and the counter the class
  /// adds 1 to at each period finished (its raw handle, the stream's).
  var leased = false
  var clockRaw: UInt32 = 0
  /// Bumped (and woken) at each period finished and each stop: a blocked
  /// writer or reader waits on it.
  let progress = Atomic<UInt32>(0)

  /// How long a writer or reader waits for the device before it fails.
  static let patience: Int64 = 2_000_000_000

  init(_ direction: AudioDirection, _ hardware: AudioHardware, format: PCMFormat, periodFrames: Int, periods: Int,
       lead: Int) {
    self.direction = direction
    self.hardware = hardware
    self.format = format
    self.periodFrames = periodFrames
    self.periods = periods
    self.lead = lead
  }

  var periodBytes: Int { periodFrames * format.frameBytes }

  // MARK: Under the lock

  func preparedLocked() throws(NodeIPC.NodeError) -> Cycle {
    if let cycle { return cycle }
    let b = try hardware.prepare(direction, format, periodBytes: periodBytes, periods: periods)
    guard b.count >= periodBytes * periods else { throw .io }
    buffer = b
    let c = Cycle(direction, periods: periods, periodBytes: periodBytes, lead: lead)
    cycle = c
    return c
  }

  func startLocked() throws(NodeIPC.NodeError) {
    _ = try preparedLocked()
    cycle!.restart()
    try hardware.start(direction)
    state = .running
    runs += 1
    readSinceOverrun = true
    handLocked()
  }

  /// Hands the device periods until it holds `lead`, unless the stream is
  /// winding down or playback has drained what was written.
  func handLocked() {
    guard state == .running, var c = cycle, let b = buffer else { return }
    while c.wantsPeriod, !(direction == .output && !leased && c.draining) {
      let overruns = c.overruns
      let (slot, filled) = c.hand()
      if direction == .output, !leased, filled < c.periodBytes {
        let silence = format.sample.silence
        let from = slot * c.periodBytes + filled
        b.fill(from..<((slot + 1) * c.periodBytes), with: silence)
      }
      hardware.hand(direction, slot: slot)
      if c.overruns != overruns {
        if !readSinceOverrun {
          state = .winding
          break
        }
        readSinceOverrun = false
      }
    }
    cycle = c
  }

  func bump() {
    progress.wrappingAdd(1, ordering: .releasing)
    unsafe Futex.wake(progressAddress, count: 64)
  }

  var progressAddress: UnsafeMutablePointer<UInt32> {
    withUnsafePointer(to: progress) {
      unsafe UnsafeMutablePointer(mutating: UnsafeRawPointer($0).assumingMemoryBound(to: UInt32.self))
    }
  }

  /// Waits, off the lock, for progress past `seen`: false if none came.
  func wait(past seen: UInt32) -> Bool {
    let deadline = Clock.monotonic() + Self.patience
    while progress.load(ordering: .acquiring) == seen {
      guard Clock.monotonic() < deadline else { return false }
      try? unsafe Futex.wait(progressAddress, current: seen, deadline: deadline)
    }
    return true
  }

  // MARK: The device's side

  /// The device finished the oldest period it holds.
  func finished() {
    var stopNow = false
    lock.withLock {
      guard var c = cycle, c.inFlight > 0, state != .stopped else { return }
      c.finish()
      cycle = c
      finishedAt = Clock.monotonic()
      if state == .running || state == .winding {
        played += 1
        playedBytes += UInt64(c.periodBytes)
        if leased, clockRaw != 0 {
          let clock = Handle(raw: clockRaw)
          try? Counter.add(clock, 1)
          _ = clock.release()
        }
      }
      switch state {
      case .running:
        if direction == .output && !leased && c.drained {
          stopNow = true
        } else {
          handLocked()
          if state == .winding && cycle!.inFlight == 0 { stopNow = true }
        }
      case .winding:
        if c.inFlight == 0 { stopNow = true }
      case .stopping, .stopped:
        break
      }
      if stopNow {
        // Nothing is with the device: stopping it waits for nothing.
        hardware.stop(direction)
        cycle!.stopped()
        state = .stopped
      }
    }
    bump()
  }

  // MARK: The client's side

  /// Copies `data` into the buffer as room comes, starting the stream:
  /// the bytes taken (all of them, unless the device stops taking any).
  func write(_ data: [UInt8]) throws(NodeIPC.NodeError) -> UInt32 {
    guard direction == .output else { throw .unsupported }
    var done = 0
    while done < data.count {
      let seen = progress.load(ordering: .acquiring)
      let took = try lock.withLock { () throws(NodeIPC.NodeError) -> Int in
        guard !leased else { throw .denied }
        var c = try preparedLocked()
        let (at, room) = c.writable()
        let n = min(room, data.count - done)
        if n > 0 {
          data.withUnsafeBytes { src in
            unsafe buffer!.bytes.baseAddress!.advanced(by: at)
              .copyMemory(from: src.baseAddress!.advanced(by: done), byteCount: n)
          }
          c.wrote(n)
        }
        cycle = c
        switch state {
        case .stopped: try startLocked()
        case .running: handLocked()
        case .winding:
          state = .running
          handLocked()
        case .stopping: break
        }
        return n
      }
      done += took
      if took == 0, !wait(past: seen) { break }
    }
    guard done > 0 || data.isEmpty else { throw .io }
    return UInt32(done)
  }

  /// Up to `max` captured bytes, waiting for the first, starting the
  /// stream if it was stopped.
  func read(max: Int) throws(NodeIPC.NodeError) -> [UInt8] {
    guard direction == .input else { throw .unsupported }
    while true {
      let seen = progress.load(ordering: .acquiring)
      let bytes = try lock.withLock { () throws(NodeIPC.NodeError) -> [UInt8]? in
        var c = try preparedLocked()
        switch state {
        case .stopped:
          try startLocked()
          c = cycle!
        case .winding:
          state = .running
          handLocked()
          c = cycle!
        case .running, .stopping: break
        }
        readSinceOverrun = true
        let (at, ready) = c.readable()
        guard ready > 0 else { return nil }
        let n = min(ready, max)
        var out = [UInt8](repeating: 0, count: n)
        out.withUnsafeMutableBytes { dst in
          unsafe dst.baseAddress!.copyMemory(from: buffer!.bytes.baseAddress!.advanced(by: at), byteCount: n)
        }
        c.read(n)
        cycle = c
        return out
      }
      if let bytes { return bytes }
      guard wait(past: seen) else { throw .io }
    }
  }

  /// Stops the stream, waiting for the device to give back its periods.
  func stop() {
    let running = lock.withLock { () -> Bool in
      guard state == .running || state == .winding else { return false }
      state = .stopping
      return true
    }
    guard running else { return }
    hardware.stop(direction)
    lock.withLock {
      cycle?.stopped()
      state = .stopped
    }
    bump()
  }

  // MARK: The lease (D181)

  /// Lends the stream: stopped if it ran, set up afresh so that period
  /// `k` of the lease is slot `k mod periods`, its buffer made silence, a
  /// counter made, and started. The buffer's VMO.
  func lend() throws(NodeIPC.NodeError) -> Handle {
    stop()
    let raw = try lock.withLock { () throws(NodeIPC.NodeError) -> UInt32 in
      guard !leased, state == .stopped else { throw .exists }
      cycle = nil
      buffer = nil
      let c = try preparedLocked()
      let vmo = try hardware.lend(direction)
      let silence = format.sample.silence
      buffer!.fill(0..<c.bufferBytes, with: silence)
      let clock: Handle
      do throws(Status) {
        clock = try Counter.create()
      } catch {
        throw .io
      }
      clockRaw = clock.release()
      leased = true
      do throws(NodeIPC.NodeError) {
        try startLocked()
      } catch {
        leased = false
        _ = Handle(raw: clockRaw)  // closed
        clockRaw = 0
        throw error
      }
      return vmo.release()
    }
    return Handle(raw: raw)
  }

  /// A handle of the lent stream's counter, nil if it isn't lent.
  func clock() -> Handle? {
    let raw = lock.withLock { () -> UInt32 in
      guard leased, clockRaw != 0 else { return 0 }
      let c = Handle(raw: clockRaw)
      let copy = (try? c.duplicate())?.release() ?? 0
      _ = c.release()
      return copy
    }
    return raw == 0 ? nil : Handle(raw: raw)
  }

  /// The lease ends: the stream stopped, its counter closed.
  func endLease() {
    guard lock.withLock({ leased }) else { return }
    stop()
    lock.withLock {
      leased = false
      if clockRaw != 0 { _ = Handle(raw: clockRaw) }
      clockRaw = 0
    }
  }

  /// A new format or period: the stream stopped, and prepared again at
  /// its next start.
  func reconfigure(_ f: PCMFormat, periodFrames: Int) {
    stop()
    lock.withLock {
      format = f
      self.periodFrames = periodFrames
      cycle = nil
      buffer = nil
    }
  }

  /// The counts, for stat.
  var snapshot: (state: State, cycle: Cycle?, finishedAt: Int64, runs: Int, played: UInt64, playedBytes: UInt64,
                 leased: Bool) {
    lock.withLock { (state, cycle, finishedAt, runs, played, playedBytes, leased) }
  }
}
