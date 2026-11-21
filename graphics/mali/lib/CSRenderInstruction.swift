// SPDX-License-Identifier: BSD-3-Clause

// The command-stream instructions of a render pass (chinese-wall's valhall 01,
// sections 1.9.3 to 1.9.7 and 1.10): the vertex/tiler run, the fragment run,
// the two finishing instructions and the tiler heap's. One 64-bit word each,
// the opcode in bits [63:56], the other bits zero unless a table names them.
// Arch 12 and 13 (the G720's): arch 14 has RUN_FRAGMENT2 and no framebuffer
// parameters block, and arch 10 and 11 have RUN_IDVS; neither is here.

/// HEAP_OPERATION's operation (01 section 1.10). Value 2 is undefined.
public enum CSHeapOperation: UInt64, Sendable {
  case vertexTilerStarted = 0
  case vertexTilerCompleted = 1
  case fragmentCompleted = 3
}

/// RUN_FRAGMENT's tile order (01 section 1.9.6).
public enum CSTileOrder: UInt64, Sendable {
  case zOrder = 0
  case horizontal = 1
  case vertical = 2
  case reverseHorizontal = 5
  case reverseVertical = 6
}

extension CSInstruction {
  public static let opRUN_FRAGMENT: UInt64 = 7
  public static let opRUN_FULLSCREEN: UInt64 = 8
  public static let opFINISH_TILING: UInt64 = 9
  public static let opFINISH_FRAGMENT: UInt64 = 11
  public static let opRUN_IDVS2: UInt64 = 12
  public static let opHEAP_SET: UInt64 = 48
  public static let opHEAP_OPERATION: UInt64 = 49

  /// RUN_IDVS2 (01 section 1.9.3, arch 12 and later): one draw through the vertex/tiler pipeline. Flags override
  /// `[31:0]` (ORed into TILER_FLAGS), progress increment `[32]` zero, malloc enable `[33]`, draw id enable `[34]`,
  /// vertex shading mode `[36:35]` (0 early, 1 deferred), draw id register `[47:40]`, stage tag `[51:48]` (0).
  /// A driver always sets malloc and early shading (the spec's policy).
  public static func runIDVS2(
    flagsOverride: UInt32 = 0, malloc: Bool = true, deferredShading: Bool = false, drawIDRegister: Int? = nil,
    stage: UInt8 = 0
  ) -> UInt64 {
    opRUN_IDVS2 << 56 | UInt64(stage & 0xF) << 48 | UInt64(drawIDRegister ?? 0) << 40 | (deferredShading ? 1 : 0) << 35
      | (drawIDRegister != nil ? 1 : 0) << 34 | (malloc ? 1 : 0) << 33 | UInt64(flagsOverride)
  }

  /// RUN_FRAGMENT (01 section 1.9.6, arch 10 to 13): one fragment pass over a framebuffer descriptor. Enable TEM
  /// `[0]`, tile order `[7:4]`, progress increment `[32]` zero.
  public static func runFragment(tileOrder: CSTileOrder = .zOrder, enableTileEnableMap: Bool = false) -> UInt64 {
    opRUN_FRAGMENT << 56 | tileOrder.rawValue << 4 | (enableTileEnableMap ? 1 : 0)
  }

  /// FINISH_TILING (01 section 1.9.7): flush the tiler and end the vertex/tiler phase. Endpoint-asynchronous: it
  /// is counted on the endpoint slot, as the pass's RUN_IDVS2 are.
  public static let finishTiling: UInt64 = opFINISH_TILING << 56

  /// FINISH_FRAGMENT (01 section 1.9.7): hand the heap chunks a finished fragment pass used back to the heap.
  /// Increment fragment completed `[0]`, wait mask `[31:16]`, the register pair of the last chunk `[39:32]` and of
  /// the first `[47:40]` (the tiler context's completed bottom and completed top), signal slot `[51:48]`, defer
  /// mode `[52]`. With a zero wait mask it runs in order and the signal slot is ignored.
  public static func finishFragment(
    firstChunkPair: Int, lastChunkPair: Int, incrementFragmentCompleted: Bool, waitMask: UInt16 = 0,
    signalSlot: Int = 0, deferred: Bool = false
  ) -> UInt64 {
    opFINISH_FRAGMENT << 56 | (deferred ? 1 : 0) << 52 | UInt64(signalSlot & 0xF) << 48
      | (UInt64(truncatingIfNeeded: firstChunkPair) & 0xFF) << 40 | (UInt64(truncatingIfNeeded: lastChunkPair) & 0xFF) << 32
      | UInt64(waitMask) << 16 | (incrementFragmentCompleted ? 1 : 0)
  }

  /// HEAP_SET (01 section 1.10): select the heap context (the kernel's, 32 bytes) the stream's tiler and fragment
  /// work uses, from the address pair in `register` `[47:40]`.
  public static func heapSet(addressPair register: Int) -> UInt64 {
    opHEAP_SET << 56 | (UInt64(truncatingIfNeeded: register) & 0xFF) << 40
  }

  /// HEAP_OPERATION (01 section 1.10): update the heap's progress counters. Wait mask `[31:16]`, operation
  /// `[34:32]`, signal slot `[51:48]`, defer mode `[52]`. With a zero wait mask it runs in order.
  public static func heapOperation(
    _ operation: CSHeapOperation, waitMask: UInt16 = 0, signalSlot: Int = 0, deferred: Bool = false
  ) -> UInt64 {
    opHEAP_OPERATION << 56 | (deferred ? 1 : 0) << 52 | UInt64(signalSlot & 0xF) << 48 | operation.rawValue << 32
      | UInt64(waitMask) << 16
  }
}
