// SPDX-License-Identifier: BSD-3-Clause

// The CSF interface in words, for the status: why discovery refused it, and
// what a booted one holds (version, features, slots).

extension CSFError: CustomStringConvertible {
  public var description: String {
    switch self {
    case .sectionTooSmall: return "the shared section is smaller than the global control block"
    case .notBooted: return "GLB_VERSION reads 0"
    case .outsideSection(let block, let g, let s):
      return "\(blockName(block)) (CSG \(g), CS \(s)) is not inside the shared section"
    case .groupCount(let n): return "\(n) CSG slots, not 3 to 31"
    case .streamCount(let g, let n): return "CSG \(g) has \(n) CS slots, not 8 to 32"
    case .mismatch(let what, let g, let s): return "\(mismatchName(what)) differs at CSG \(g), CS \(s)"
    case .badSlot: return "no such slot"
    case .badRingSize: return "a ring size that is not a power of two"
    case .startPending: return "a CSG's start is unacknowledged"
    case .insertBeforeExtract: return "a ring's INSERT is behind its EXTRACT"
    }
  }
}

func blockName(_ b: CSF.Block) -> String {
  switch b {
  case .globalControl: return "global control"
  case .globalInput: return "global input"
  case .globalOutput: return "global output"
  case .groupControl: return "CSG control"
  case .groupInput: return "CSG input"
  case .groupOutput: return "CSG output"
  case .streamControl: return "CS control"
  case .streamInput: return "CS input"
  case .streamOutput: return "CS output"
  }
}

func mismatchName(_ m: CSF.Mismatch) -> String {
  switch m {
  case .groupFeatures: return "CSG_FEATURES"
  case .suspendSize: return "CSG_SUSPEND_SIZE"
  case .protmSuspendSize: return "CSG_PROTM_SUSPEND_SIZE"
  case .streamNum: return "CSG_STREAM_NUM"
  case .streamFeatures: return "CS_FEATURES"
  }
}

extension CSFLayout {
  /// The status's lines for a booted interface: its version and features,
  /// and the slots it has.
  public var statusLines: [String] {
    let v = version
    var first = "firmware interface \(v.major).\(v.minor).\(v.patch), GLB_FEATURES \(hex(features))"
    if v.hasInstrFeatures { first += ", GLB_INSTR_FEATURES \(hex(instrFeatures))" }
    var lines = [first]
    if let g = groups.first, let s = g.streams.first {
      var kinds = ""
      if s.features.compute { kinds += " compute" }
      if s.features.fragment { kinds += " fragment" }
      if s.features.tiler { kinds += " tiler" }
      var line = "\(groupCount) CSG slots (CSG_FEATURES \(hex(g.features)), suspend buffer \(g.suspendSize) bytes,"
      line += " protected \(g.protmSuspendSize)), \(streamCount) CS slots each"
      line += " (CS_FEATURES \(hex(s.features.raw)): \(s.features.workRegisters) work registers,"
      line += " \(s.features.scoreboards) scoreboards,\(kinds))"
      lines.append(line)
    }
    return lines
  }
}
