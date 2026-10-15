// SPDX-License-Identifier: BSD-3-Clause

// The trace format (docs/trace-format.md): its constants, shared by the
// writer and the reader.

public enum TraceFormat {
  public static let version: UInt32 = 1
  public static let regionMagic: UInt32 = 0x7274_6474  // "tdtr"
  public static let ringMagic: UInt32 = 0x676e_6972  // "ring"
  public static let headerSize = 4096
  public static let ringHeaderSize = 128
  public static let recordSize = 32

  // Region header offsets.
  public static let counterHz = 8
  public static let start = 16
  public static let processID = 24
  public static let ringCount = 28
  public static let ringSize = 32
  public static let stringsOffset = 40
  public static let stringsSize = 48
  public static let stringsUsed = 56
  public static let ringsOffset = 64
  public static let ringsClaimed = 72
  public static let flags = 76
  public static let categories = 80

  // Ring header offsets: the first 64 bytes are croi's croi_trace_ring_t.
  public static let ringHead = 0
  public static let ringCapacity = 8
  public static let ringDropped = 16
  public static let ringFirstDrop = 24
  public static let ringLastDrop = 32
  public static let ringFrequency = 40
  public static let ringSession = 48
  public static let ringMode = 56
  public static let ringCPU = 60
  public static let ringMagicOffset = 64
  public static let ringTid = 68

  public static let flagCircular: UInt32 = 1
}

/// What a record is (docs/trace-format.md, "Records").
public enum TraceKind: UInt16, Sendable {
  case mark = 0x4001
  case zone = 0x4002
  case flow = 0x4003
  case counter = 0x4004
}

/// The categories a trace point belongs to; the enabled set is a mask.
public struct TraceCategory: OptionSet, Sendable {
  public let rawValue: UInt64
  public init(rawValue: UInt64) { self.rawValue = rawValue }

  public static let app = TraceCategory(rawValue: 1 << 0)
  public static let frame = TraceCategory(rawValue: 1 << 1)
  public static let audio = TraceCategory(rawValue: 1 << 2)
  public static let input = TraceCategory(rawValue: 1 << 3)
  public static let ipc = TraceCategory(rawValue: 1 << 4)
  public static let io = TraceCategory(rawValue: 1 << 5)
  public static let mark = TraceCategory(rawValue: 1 << 6)
  public static let all = TraceCategory(rawValue: 0x7f)

  public static let names: [(String, TraceCategory)] = [
    ("app", .app), ("frame", .frame), ("audio", .audio), ("input", .input), ("ipc", .ipc), ("io", .io),
    ("mark", .mark),
  ]

  /// "frame,audio" → the set; nil if a name is unknown.
  public init?(names list: String) {
    var set: TraceCategory = []
    for name in list.split(separator: ",") {
      guard let c = Self.names.first(where: { $0.0 == name })?.1 else { return nil }
      set.insert(c)
    }
    self = set
  }
}
