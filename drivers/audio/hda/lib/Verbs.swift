// SPDX-License-Identifier: BSD-3-Clause

// An HD Audio codec's verbs and parameters (Intel High Definition Audio
// Specification rev. 1.0a, §7.3): a command is the codec's address, a
// node and a verb, with a 12-bit verb and an 8-bit payload or a 4-bit
// verb and a 16-bit one; the parameters a node is asked for; the fields
// of widget capabilities, pin defaults and amplifiers; and a stream's
// format word.

import AudioDevice

public enum Verb {
  /// A command word.
  public static func command(codec: Int, node: Int, verb: UInt32, payload: UInt32) -> UInt32 {
    let body = verb >= 0x100 ? verb << 8 | (payload & 0xFF) : verb << 16 | (payload & 0xFFFF)
    return UInt32(codec & 0xF) << 28 | UInt32(node & 0x7F) << 20 | (body & 0xF_FFFF)
  }

  public static let getParameter: UInt32 = 0xF00
  public static let getConnectionSelect: UInt32 = 0xF01
  public static let setConnectionSelect: UInt32 = 0x701
  public static let getConnectionList: UInt32 = 0xF02
  public static let setPowerState: UInt32 = 0x705
  public static let setStream: UInt32 = 0x706
  public static let setPinControl: UInt32 = 0x707
  public static let setEAPD: UInt32 = 0x70C
  public static let getConfigDefault: UInt32 = 0xF1C
  /// 4-bit verbs.
  public static let setFormat: UInt32 = 0x2
  public static let setAmp: UInt32 = 0x3
}

public enum Parameter {
  public static let vendor: UInt32 = 0x00
  public static let nodeCount: UInt32 = 0x04
  public static let functionType: UInt32 = 0x05
  public static let widgetCaps: UInt32 = 0x09
  public static let pcm: UInt32 = 0x0A
  public static let streamFormats: UInt32 = 0x0B
  public static let pinCaps: UInt32 = 0x0C
  public static let inAmpCaps: UInt32 = 0x0D
  public static let connectionLength: UInt32 = 0x0E
  public static let outAmpCaps: UInt32 = 0x12
}

/// A widget's type: Audio Widget Capabilities bits 23:20.
public enum WidgetType: UInt32, Sendable {
  case output = 0, input, mixer, selector, pin, power, volumeKnob, beep
  case vendor = 0xF
}

public struct WidgetCaps: Equatable, Sendable {
  public var raw: UInt32
  public init(_ raw: UInt32) { self.raw = raw }
  public var type: WidgetType? { WidgetType(rawValue: (raw >> 20) & 0xF) }
  public var stereo: Bool { raw & 1 != 0 }
  public var inAmp: Bool { raw & (1 << 1) != 0 }
  public var outAmp: Bool { raw & (1 << 2) != 0 }
  /// The widget's own amplifier capabilities, not the function group's.
  public var ampOverride: Bool { raw & (1 << 3) != 0 }
  /// Its own PCM capabilities, not the function group's.
  public var formatOverride: Bool { raw & (1 << 4) != 0 }
  public var connectionList: Bool { raw & (1 << 8) != 0 }
  public var digital: Bool { raw & (1 << 9) != 0 }
  public var powerControl: Bool { raw & (1 << 10) != 0 }
}

/// A pin's Configuration Default: what is wired to it.
public struct PinConfig: Equatable, Sendable {
  public var raw: UInt32
  public init(_ raw: UInt32) { self.raw = raw }
  /// 0 a jack, 1 nothing, 2 a fixed device, 3 both.
  public var connectivity: UInt32 { raw >> 30 }
  /// 0 line out, 1 speaker, 2 headphones, 8 line in, 0xA microphone...
  public var device: UInt32 { (raw >> 20) & 0xF }
  public var association: UInt32 { (raw >> 4) & 0xF }
  public var sequence: UInt32 { raw & 0xF }
  public var connected: Bool { connectivity != 1 }

  public var isOutput: Bool { [0, 1, 2].contains(device) }
  public var isInput: Bool { [8, 0xA].contains(device) }

  /// Which output is played first: line out, then speaker, then
  /// headphones; and for input, line in, then microphone.
  public var rank: Int {
    switch device {
    case 0: 0
    case 1: 1
    case 2: 2
    case 8: 0
    case 0xA: 1
    default: 9
    }
  }
}

/// Amplifier Capabilities: the step that is 0 dB, the steps, mute.
public struct AmpCaps: Equatable, Sendable {
  public var raw: UInt32
  public init(_ raw: UInt32) { self.raw = raw }
  public var offset: UInt32 { raw & 0x7F }
  public var steps: UInt32 { (raw >> 8) & 0x7F }
  public var mute: Bool { raw & (1 << 31) != 0 }
}

/// Supported PCM Size, Rates: rates by bit, and sample sizes.
public enum PCMBits {
  public static let rates: [UInt32] = [8000, 11025, 16000, 22050, 32000, 44100, 48000, 88200, 96000, 176400, 192000,
                                       384000]

  /// The class's capabilities of a converter: its rates, and the sample
  /// formats its sizes give (16 bits s16; 24 s24; 32 s32).
  public static func capabilities(_ pcm: UInt32, channels: ClosedRange<Int>) -> PCMCapabilities {
    var samples: [SampleFormat] = []
    if pcm & (1 << 17) != 0 { samples.append(.s16) }
    if pcm & (1 << 19) != 0 { samples.append(.s24) }
    if pcm & (1 << 20) != 0 { samples.append(.s32) }
    var r: [UInt32] = []
    for (i, rate) in rates.enumerated() where pcm & (1 << UInt32(i)) != 0 { r.append(rate) }
    return PCMCapabilities(samples: samples, rates: r, channels: channels)
  }
}

/// A stream's format word (§3.7.1), the same in SDnFMT and the
/// converter's format.
public enum StreamFormat {
  public static func word(_ f: PCMFormat) -> UInt16? {
    let base: UInt32, mult: UInt32, div: UInt32
    switch f.rate {
    case 8000: (base, mult, div) = (48000, 1, 6)
    case 11025: (base, mult, div) = (44100, 1, 4)
    case 16000: (base, mult, div) = (48000, 1, 3)
    case 22050: (base, mult, div) = (44100, 1, 2)
    case 32000: (base, mult, div) = (48000, 2, 3)
    case 44100: (base, mult, div) = (44100, 1, 1)
    case 48000: (base, mult, div) = (48000, 1, 1)
    case 88200: (base, mult, div) = (44100, 2, 1)
    case 96000: (base, mult, div) = (48000, 2, 1)
    case 176400: (base, mult, div) = (44100, 4, 1)
    case 192000: (base, mult, div) = (48000, 4, 1)
    default: return nil
    }
    let bits: UInt32
    switch f.sample {
    case .s16: bits = 1
    case .s24: bits = 3
    case .s32: bits = 4
    default: return nil
    }
    guard f.channels >= 1, f.channels <= 16 else { return nil }
    let w = (base == 44100 ? 1 << 14 : 0) | (mult - 1) << 11 | (div - 1) << 8 | bits << 4 | UInt32(f.channels - 1)
    return UInt16(w)
  }
}
