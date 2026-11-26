// SPDX-License-Identifier: BSD-3-Clause

// The audio service's graph (D179), its first part: push streams mixed
// into one device. A push stream is one client's frames, 9front's format
// (16-bit stereo, little-endian) at the device's rate, queued as the
// client writes them; each quantum the graph takes a quantum's frames
// from every stream, sums them as 32-bit floats, and writes the sum into
// the device's lent buffer (D180, D181) in the device's format, clipped.
// A stream with fewer frames than a quantum gives what it has, the rest
// silence: an underrun of its own (its client was late), never the
// device's. A stream whose channel has closed plays out what it holds and
// then goes.

import Sys

/// One client's push stream: a queue of its bytes, written on the
/// service's dispatcher and taken on the mixing thread.
public final class PushStream: @unchecked Sendable {
  public let id: Int
  /// Bytes it may hold: about 370 ms at 44.1 kHz, more than a Node write.
  public static let capacity = 65536
  static let frameBytes = 4
  let lock = Lock()
  var bytes: [UInt8] = []
  var start = 0
  public private(set) var closed = false
  public private(set) var frames: UInt64 = 0
  public private(set) var underruns: UInt64 = 0
  /// Whether it has given frames since it last ran dry: a stream that
  /// hasn't started isn't late.
  var flowing = false

  public init(id: Int) { self.id = id }

  /// Bytes queued and not yet mixed.
  public var buffered: Int { lock.withLock { bytes.count - start } }

  /// Takes `data` whole, or nothing (nil) if it doesn't fit yet: the
  /// client's write waits.
  public func write(_ data: [UInt8]) -> UInt32? {
    lock.withLock { () -> UInt32? in
      let held = bytes.count - start
      guard held + data.count <= Self.capacity || held == 0 else { return nil }
      // What was mixed goes before the queue grows past its capacity.
      if start > 0, start == bytes.count || start >= Self.capacity {
        bytes.removeSubrange(0..<start)
        start = 0
      }
      bytes += data
      return UInt32(data.count)
    }
  }

  public func close() { lock.withLock { closed = true } }

  /// Drops what it holds, unplayed: there is no device.
  public func drop() {
    lock.withLock {
      bytes.removeAll(keepingCapacity: true)
      start = 0
      flowing = false
    }
  }

  /// Closed and played out: the graph drops it.
  public var finished: Bool { lock.withLock { closed && bytes.count - start < Self.frameBytes } }

  /// Adds up to `count` of its frames into `mix` (interleaved stereo
  /// floats, two a frame): the frames it gave.
  public func take(_ count: Int, into mix: inout [Float]) -> Int {
    lock.withLock { () -> Int in
      let have = (bytes.count - start) / Self.frameBytes
      let n = min(have, count)
      var at = start
      for f in 0..<n {
        let l = Int16(bitPattern: UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8)
        let r = Int16(bitPattern: UInt16(bytes[at + 2]) | UInt16(bytes[at + 3]) << 8)
        mix[2 * f] += Float(l) * (1 / 32768)
        mix[2 * f + 1] += Float(r) * (1 / 32768)
        at += Self.frameBytes
      }
      start = at
      frames += UInt64(n)
      if n < count {
        // Dry: late if it had been giving and isn't closing.
        if flowing && !closed { underruns += 1 }
        flowing = false
      } else {
        flowing = true
      }
      return n
    }
  }
}

/// The device side's format, as the lease's layout gives it: sample
/// format (s16, s32 or f32) and channels.
public struct DeviceFormat: Equatable, Sendable {
  public enum Sample: Equatable, Sendable { case s16, s32, f32 }
  public var sample: Sample
  public var channels: Int

  public init(sample: Sample, channels: Int) {
    self.sample = sample
    self.channels = channels
  }

  /// From the lease's layout's sample index (s8, u8, s16, s24, s32, f32),
  /// nil for one the graph doesn't write.
  public init?(sampleIndex: UInt32, channels: UInt32) {
    switch sampleIndex {
    case 2: sample = .s16
    case 4: sample = .s32
    case 5: sample = .f32
    default: return nil
    }
    guard channels >= 1 else { return nil }
    self.channels = Int(channels)
  }

  public var sampleBytes: Int { sample == .s16 ? 2 : 4 }
  public var frameBytes: Int { sampleBytes * channels }
}

/// Every stream, and the quantum's mix written out.
public final class Graph: @unchecked Sendable {
  let lock = Lock()
  var streams: [PushStream] = []
  var nextID = 0
  public private(set) var quanta: UInt64 = 0
  /// Quanta in which some stream gave frames.
  public private(set) var audible: UInt64 = 0
  var mix: [Float] = []

  public init() {}

  public func open() -> PushStream {
    lock.withLock {
      nextID += 1
      let s = PushStream(id: nextID)
      streams.append(s)
      return s
    }
  }

  public var all: [PushStream] { lock.withLock { streams } }

  /// Whether any stream holds frames to play.
  public var pending: Bool { lock.withLock { streams.contains { $0.buffered >= PushStream.frameBytes } } }

  /// One quantum of `frames` mixed into `out` (`frames` frames of
  /// `format`), the streams played out dropped: whether any gave frames.
  @discardableResult
  public func render(frames: Int, format: DeviceFormat, into out: UnsafeMutableRawBufferPointer) -> Bool {
    let current = lock.withLock { () -> [PushStream] in
      streams.removeAll { $0.finished }
      return streams
    }
    if mix.count != 2 * frames { mix = [Float](repeating: 0, count: 2 * frames) }
    for i in 0..<mix.count { mix[i] = 0 }
    var gave = false
    for s in current where s.take(frames, into: &mix) > 0 { gave = true }
    unsafe Self.write(mix, frames: frames, format: format, into: out)
    lock.withLock {
      quanta += 1
      if gave { audible += 1 }
    }
    return gave
  }

  /// Stereo floats into the device's frames: clipped to [-1, 1]; one
  /// channel takes the average, more than two take left and right and
  /// silence on the rest.
  public static func write(_ mix: [Float], frames: Int, format: DeviceFormat, into out: UnsafeMutableRawBufferPointer) {
    precondition(unsafe out.count >= frames * format.frameBytes)
    var at = 0
    for f in 0..<frames {
      for c in 0..<format.channels {
        var v: Float = format.channels == 1 ? (mix[2 * f] + mix[2 * f + 1]) / 2 : c < 2 ? mix[2 * f + c] : 0
        v = min(max(v, -1), 1)
        switch format.sample {
        case .s16:
          let x = v * 32767
          let s = UInt16(bitPattern: Int16(x >= 0 ? x + 0.5 : x - 0.5))  // to nearest (no libm)
          unsafe out[at] = UInt8(truncatingIfNeeded: s)
          unsafe out[at + 1] = UInt8(truncatingIfNeeded: s >> 8)
        case .s32:
          let x = Double(v) * 2147483647
          let s = UInt32(bitPattern: Int32(x >= 0 ? x + 0.5 : x - 0.5))
          for b in 0..<4 { unsafe out[at + b] = UInt8(truncatingIfNeeded: s >> (8 * UInt32(b))) }
        case .f32:
          let s = v.bitPattern
          for b in 0..<4 { unsafe out[at + b] = UInt8(truncatingIfNeeded: s >> (8 * UInt32(b))) }
        }
        at += format.sampleBytes
      }
    }
  }
}
