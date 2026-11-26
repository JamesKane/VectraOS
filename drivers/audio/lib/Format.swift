// SPDX-License-Identifier: BSD-3-Clause

// The audio class's formats (D82, D179): a stream's sample format, rate
// and channels, and what a device's stream can take. Names are 9front's
// audio(3) where it has them (`s16`); the rest follow its pattern (`s8`,
// `u8`, `s24` in 32-bit containers, `s32`, `f32`). Frames are
// interleaved and little-endian, as the hardware reads them (D180).

/// Which way a stream goes.
public enum AudioDirection: Sendable, Equatable {
  case output, input

  public var name: String { self == .output ? "out" : "in" }
}

public enum SampleFormat: Sendable, Equatable {
  case s8, u8, s16, s24, s32, f32

  public static let all: [SampleFormat] = [.s8, .u8, .s16, .s24, .s32, .f32]

  public var name: String {
    switch self {
    case .s8: "s8"
    case .u8: "u8"
    case .s16: "s16"
    case .s24: "s24"
    case .s32: "s32"
    case .f32: "f32"
    }
  }

  /// Bytes a sample takes in a frame (s24's container is 32 bits).
  public var bytes: Int {
    switch self {
    case .s8, .u8: 1
    case .s16: 2
    case .s24, .s32, .f32: 4
    }
  }

  /// The byte silence is made of: 0x80 for unsigned 8-bit, else 0.
  public var silence: UInt8 { self == .u8 ? 0x80 : 0 }

  public static func named(_ name: String) -> SampleFormat? {
    for f in all where AudioText.same(f.name, name) { return f }
    return nil
  }
}

/// A stream's format: its samples, channels and rate.
public struct PCMFormat: Sendable, Equatable {
  public var sample: SampleFormat
  public var channels: Int
  public var rate: UInt32

  public init(sample: SampleFormat, channels: Int, rate: UInt32) {
    self.sample = sample
    self.channels = channels
    self.rate = rate
  }

  public var frameBytes: Int { sample.bytes * channels }

  /// 9front's default: 16-bit stereo at 44.1 kHz.
  public static let plan9 = PCMFormat(sample: .s16, channels: 2, rate: 44100)
}

/// What a device's stream can take: sample formats and rates in the
/// device's order, and a range of channels.
public struct PCMCapabilities: Sendable, Equatable {
  public var samples: [SampleFormat]
  public var rates: [UInt32]
  public var channels: ClosedRange<Int>

  public init(samples: [SampleFormat], rates: [UInt32], channels: ClosedRange<Int>) {
    self.samples = samples
    self.rates = rates
    self.channels = channels
  }

  public func allows(_ f: PCMFormat) -> Bool {
    samples.contains(f.sample) && rates.contains(f.rate) && channels.contains(f.channels)
  }

  /// The format closest to `wanted` it can take: `wanted` itself if it
  /// can, else its sample format, channels and rate each moved to the
  /// nearest the device has (s16 first, then the widest).
  public func nearest(_ wanted: PCMFormat) -> PCMFormat? {
    guard !samples.isEmpty, !rates.isEmpty else { return nil }
    var f = wanted
    if !samples.contains(f.sample) {
      f.sample = samples.contains(.s16) ? .s16 : samples.max { $0.bytes < $1.bytes }!
    }
    f.channels = min(max(f.channels, channels.lowerBound), channels.upperBound)
    if !rates.contains(f.rate) {
      var best = rates[0]
      for r in rates where distance(r, wanted.rate) < distance(best, wanted.rate) { best = r }
      f.rate = best
    }
    return f
  }

  func distance(_ a: UInt32, _ b: UInt32) -> UInt32 { a > b ? a - b : b - a }

  /// stat's line for a direction: `out formats s16 s32 rates 44100 48000 channels 1-2`.
  public func line(_ d: AudioDirection) -> String {
    var s = d.name + " formats"
    for f in samples { s += " " + f.name }
    s += " rates"
    for r in rates { s += " \(r)" }
    s += " channels \(channels.lowerBound)-\(channels.upperBound)"
    return s
  }
}

/// Text helpers for the class's files: words compared as bytes (Embedded
/// Swift's String has no contains, and names are ASCII).
public enum AudioText {
  public static func same(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }

  /// A command's lines, each split into words.
  public static func lines(_ text: String) -> [[String]] {
    var out: [[String]] = []
    for line in text.utf8.split(separator: 0x0A) {
      let words = line.split(whereSeparator: { $0 == 0x20 || $0 == 0x09 || $0 == 0x0D })
        .map { String(decoding: $0, as: UTF8.self) }
      if !words.isEmpty { out.append(words) }
    }
    return out
  }

  /// A decimal number, all digits, at most 10 of them.
  public static func number(_ word: String) -> UInt64? {
    var n: UInt64 = 0
    var digits = 0
    for c in word.utf8 {
      guard c >= 0x30, c <= 0x39, digits < 10 else { return nil }
      n = n * 10 + UInt64(c - 0x30)
      digits += 1
    }
    return digits > 0 ? n : nil
  }
}
