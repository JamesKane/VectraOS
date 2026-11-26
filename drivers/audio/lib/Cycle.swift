// SPDX-License-Identifier: BSD-3-Clause

// A stream's cyclic buffer, counted (D180): `periods` periods of
// `periodBytes` each, in the hardware's layout. The device takes periods
// in turn, `lead` of them handed to it at a time; the client writes
// (playback) or reads (capture) the bytes around them. Everything is a
// count from the stream's start, never an index into the buffer: a
// period's slot is its number modulo `periods`, a byte's offset its count
// modulo the buffer's size. This is arithmetic only; AudioStream holds
// its lock, its memory and its device.
//
// Playback: the client may write from `cursor` (never behind what was
// handed) up to `periods` periods past what the device finished. A period
// handed before it is full is played with silence where unwritten. That
// is an underrun if the stream goes on afterwards; the silence a stream
// ends with is its drain, not an underrun. After its last written period
// the stream hands `lead` periods of silence; once those are done and
// nothing more is written, it has drained.
//
// Capture: the device fills each period handed to it. The client reads
// from `cursor` up to what the device finished. A period about to be
// handed whose slot still holds unread bytes drops them: an overrun, and
// the cursor moves to the oldest period kept.

public struct Cycle: Sendable, Equatable {
  public let direction: AudioDirection
  public let periods: Int
  public let periodBytes: Int
  public let lead: Int
  /// Periods handed to the device, and periods it finished.
  public private(set) var handed: UInt64 = 0
  public private(set) var done: UInt64 = 0
  /// Playback: bytes written. Capture: bytes read.
  public private(set) var cursor: UInt64 = 0
  public private(set) var underruns: UInt64 = 0
  public private(set) var overruns: UInt64 = 0
  /// Playback: the last handed period holding written bytes, plus one
  /// (0: none); periods handed short since the last full one.
  var lastData: UInt64 = 0
  var short: UInt64 = 0

  public init(_ direction: AudioDirection, periods: Int, periodBytes: Int, lead: Int) {
    precondition(periods >= 2 && periodBytes > 0 && lead >= 1 && lead < periods)
    self.direction = direction
    self.periods = periods
    self.periodBytes = periodBytes
    self.lead = lead
  }

  public var bufferBytes: Int { periods * periodBytes }
  var size: UInt64 { UInt64(periodBytes) }

  /// Where count `n` falls in the buffer.
  public func offset(_ n: UInt64) -> Int { Int(n % UInt64(bufferBytes)) }

  /// Periods with the device now.
  public var inFlight: Int { Int(handed - done) }

  /// Whether the device should be handed another period now.
  public var wantsPeriod: Bool { inFlight < lead }

  // MARK: Playback

  /// The bytes the client may write now, as one piece of the buffer: its
  /// offset and length (cut at the buffer's end).
  public func writable() -> (offset: Int, count: Int) {
    precondition(direction == .output)
    let from = max(cursor, handed * size)
    let end = (done + UInt64(periods)) * size
    guard from < end else { return (offset(from), 0) }
    let at = offset(from)
    return (at, min(Int(end - from), bufferBytes - at))
  }

  /// The client wrote `count` bytes where `writable` said.
  public mutating func wrote(_ count: Int) {
    cursor = max(cursor, handed * size) + UInt64(count)
  }

  /// Playback: bytes written and not yet played, 9front's `buffered`.
  /// Capture: bytes captured and not yet read.
  public var buffered: UInt64 {
    switch direction {
    case .output: cursor > done * size ? cursor - done * size : 0
    case .input: done * size > cursor ? done * size - cursor : 0
    }
  }

  /// Playback: whether the stream has handed its last written period and
  /// `lead` periods of silence after it, with nothing more written: it
  /// should hand no more. A writer late by less than that is heard as an
  /// underrun, not a stop.
  public var draining: Bool {
    direction == .output && handed >= lastData + UInt64(lead) && cursor <= handed * size
  }

  /// Playback: drained, and nothing with the device: the stream stops.
  public var drained: Bool { draining && inFlight == 0 }

  // MARK: Capture

  /// The bytes the client may read now, as one piece of the buffer.
  public func readable() -> (offset: Int, count: Int) {
    precondition(direction == .input)
    let end = done * size
    guard cursor < end else { return (offset(cursor), 0) }
    let at = offset(cursor)
    return (at, min(Int(end - cursor), bufferBytes - at))
  }

  /// The client read `count` bytes where `readable` said.
  public mutating func read(_ count: Int) { cursor += UInt64(count) }

  // MARK: The device

  /// Hands the next period to the device: its slot, and for playback how
  /// many of its bytes were written (the rest is to be made silence).
  public mutating func hand() -> (slot: Int, filled: Int) {
    let k = handed
    let slot = Int(k % UInt64(periods))
    var filled = periodBytes
    switch direction {
    case .output:
      let start = k * size
      filled = cursor <= start ? 0 : Int(min(cursor - start, size))
      if filled > 0 { lastData = k + 1 }
      if filled == periodBytes {
        underruns += short
        short = 0
      } else {
        short += 1
      }
      // A write that comes later starts at the next period.
    case .input:
      // The slot holds period k - periods: it must have been read.
      if k >= UInt64(periods), cursor < (k - UInt64(periods) + 1) * size {
        cursor = (k - UInt64(periods) + 1) * size
        overruns += 1
      }
    }
    handed += 1
    return (slot, filled)
  }

  /// The device finished the oldest period it holds.
  public mutating func finish() {
    precondition(done < handed)
    done += 1
  }

  /// The stream stopped: whatever the device held is given up, and the
  /// next start begins after it. A drain's silence isn't counted.
  public mutating func stopped() {
    done = handed
    short = 0
    if direction == .output {
      cursor = max(cursor, handed * size)
      // What was written and not handed plays when it starts again.
    } else {
      cursor = handed * size
    }
  }

  /// Capture starting: only what is captured from now on is read.
  public mutating func restart() {
    precondition(inFlight == 0)
    if direction == .input { cursor = handed * size }
  }
}
