// SPDX-License-Identifier: BSD-3-Clause

// The trace format (docs/trace-format.md): its constants, shared by the
// writer and the reader. Version 2 (D50): each ring is a trace header,
// then a one ring (lib/ring) of slots that are the ring's sequence and a
// record.

public enum TraceFormat {
  public static let version: UInt32 = 2
  public static let regionMagic: UInt32 = 0x7274_6474  // "tdtr"
  public static let ringMagic: UInt32 = 0x676e_6972  // "ring"
  public static let headerSize = 4096
  /// A trace ring's header: the one ring follows it.
  public static let ringHeaderSize = 128
  public static let recordSize = 32
  /// A slot: the ring's u64 sequence, then a record.
  public static let slotSize = 40
  /// The one ring's format descriptor for trace slots (trace.h's
  /// CROI_TRACE_RING_FORMAT, "TRC2").
  public static let ringFormat: UInt64 = 0x3243_5254
  /// trace.h's CROI_TRACE_RECORDS_PER_PAGE: trace_configure's pages.
  public static let recordsPerPage = 128

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

  // Trace ring header offsets: croi's croi_trace_ring_t, kernel and user
  // rings alike.
  public static let ringFrequency = 0
  public static let ringSession = 8
  public static let ringDropped = 16
  public static let ringFirstDrop = 24
  public static let ringLastDrop = 32
  public static let ringMode = 40
  public static let ringCPU = 44
  public static let ringMagicOffset = 48
  public static let ringTid = 52

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
