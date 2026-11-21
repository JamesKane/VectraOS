// SPDX-License-Identifier: BSD-3-Clause

// What a dispatch is given, what it reports and how it fails.

public struct Dim3: Sendable, Equatable {
  public var x: UInt32
  public var y: UInt32
  public var z: UInt32
  public init(_ x: UInt32, _ y: UInt32 = 1, _ z: UInt32 = 1) {
    self.x = x
    self.y = y
    self.z = z
  }
  public var count: Int { Int(x) * Int(y) * Int(z) }
}

/// An instruction list. Instruction `i` is at byte address `codeBase + 8 * i`.
public struct Shader: Sendable {
  public var code: [Instr]
  public init(_ code: [Instr]) { self.code = code }
}

public struct DispatchConfig: Sendable {
  /// Invocations per workgroup (14 §14.2.1: each axis up to 1024).
  public var workgroupSize: Dim3
  /// Workgroups in the grid.
  public var grid: Dim3
  /// The user FAU: 32-bit words, two per 64-bit slot (10 §10.5.3). A source naming a slot at or past
  /// the end is a `Fault.fauOutOfRange` (the spec leaves what such a read returns open, 10 §10.5.3).
  public var fau: [UInt32]
  /// Bytes of workgroup (shared) memory, and of thread-local storage per invocation.
  public var sharedBytes: Int
  public var threadLocalBytes: Int
  /// Where those live in the GPU address space: workgroup `n`'s shared memory is at
  /// `sharedBase + n * sharedBytes`, invocation `i`'s thread-local storage at `tlsBase + i * threadLocalBytes`
  /// (`i` the invocation's index over the whole dispatch).
  public var sharedBase: UInt64
  public var tlsBase: UInt64
  /// The shader program descriptor's flush-to-zero mode (04 §4.2.4): subnormal inputs and results of the
  /// float instructions of 11a become zero.
  public var flushDenormals: Bool
  /// The address of instruction 0 (what `pc` is relative to).
  public var codeBase: UInt64
  /// `resource_table_pointer` (10 §10.5.3).
  public var resourceTable: UInt64
  /// Shared and thread-local memory start filled with this byte, so reading what the shader never wrote
  /// gives a recognisable value (14 §14.9: stack memory is not cleared). `nil` is zero.
  public var poison: UInt8?
  /// Instructions one warp may execute before the run is judged not to finish.
  public var maxStepsPerWarp: Int
  /// Report a read of a register after the instruction that marked it last use (10 §10.5.5).
  public var strictLastUse: Bool
  /// Lanes of every warp that start as helper lanes: discarded from the first instruction (13 §13.6.4).
  public var helperMask: UInt16 = 0
  /// The value of the special entry `shader_output` (14.7.2): the output groups the vertex pass writes.
  public var shaderOutput: UInt32 = 0
  /// A vertex shader's hardware vertex-output buffers (table 61, 14.3.4), by buffer index: `LEA_BUF_IMM` gives
  /// `base + element * stride`. The spec leaves the unit of the element open (12c.4.1); a test says what it models.
  public var hardwareBuffers: [(base: UInt64, stride: UInt64)] = []
  /// Called for each invocation (its index over its workgroup) after the ABI preloads, to set registers
  /// the way a test wants (tests only: the hardware has no such thing).
  public var registerInit: (@Sendable (_ invocation: Int, _ regs: inout [UInt32]) -> Void)?
  /// `TEX_FETCH`'s texture, a test model: the texel (four words) of texture handle `texture` at (`x`, `y`). The hardware
  /// reads one handle for a whole warp (12b.2.1), so a fetch whose lanes name different textures is a `Fault`.
  public var textureFetch: (@Sendable (_ texture: UInt32, _ x: UInt32, _ y: UInt32) -> [UInt32])?
  /// The storage images of a run, a test model (ImageOps.swift): the image a handle names, nil for none.
  /// The resource table's descriptors, a test model: the 32-bit word at byte `offset` of table `table` (an `LD_PKA` through
  /// the pseudo-table handle `(62 << 24) | table`, 12b.13.5).
  public var descriptorWord: (@Sendable (_ table: UInt32, _ offset: UInt32) -> UInt32)?
  public var storageImage: (@Sendable (_ handle: UInt32) -> StorageImageModel?)?
  /// Keep the registers of the first warp of the first workgroup in `RunReport.firstWarpRegisters`.
  public var captureFirstWarp = false
  /// What WMASK reports (13 section 13.9.4, open): false, the lanes active in the current context (the reference compiler's
  /// reading); true, every lane launched in the warp that still runs (not ended or retired), whichever path it is on, with
  /// its register as the tested value.
  public var wmaskLaunched = false

  public init(
    workgroupSize: Dim3 = Dim3(16), grid: Dim3 = Dim3(1), fau: [UInt32] = [], sharedBytes: Int = 0,
    threadLocalBytes: Int = 0
  ) {
    self.workgroupSize = workgroupSize
    self.grid = grid
    self.fau = fau
    self.sharedBytes = sharedBytes
    self.threadLocalBytes = threadLocalBytes
    sharedBase = 0x0000_7000_0000_0000
    tlsBase = 0x0000_7100_0000_0000
    flushDenormals = false
    codeBase = 0x0000_0000_4000_0000
    resourceTable = 0
    poison = 0xA5
    maxStepsPerWarp = 1_000_000
    strictLastUse = true
  }
}

public struct RunReport: Sendable {
  public var workgroups = 0
  public var warps = 0
  /// Instructions issued, counting each warp-instruction once per active-lane group that ran it.
  public var instructions = 0
  public var barriers = 0
  /// `[lane * 64 + register]` of workgroup 0's warp 0, when `captureFirstWarp` is set.
  public var firstWarpRegisters: [UInt32] = []
}

/// What the interpreter objects to. The first four are the interpreter acting as the second line
/// behind the validator (D174 §7, 15's rules): a shader that hits one is wrong, whatever the hardware
/// would have done.
public enum Fault: Error, Sendable, Equatable {
  /// A register read while a message's result for it was still in flight (10 §10.9.1).
  case readBeforeWait(register: Int, slot: Int)
  /// A register written while a message's result for it was still in flight.
  case writeBeforeWait(register: Int, slot: Int)
  /// A register read after an instruction marked it last use (10 §10.5.5).
  case readAfterLastUse(register: Int)
  /// A `BARRIER` while a general slot (0 to 2) was busy (12a §12a.9, 13 §13.8).
  case barrierWithBusySlots(slots: UInt8)
  /// A `BARRIER` reached by some lanes of a warp only (divergent code), or by only some warps.
  case barrierNotUniform
  case unmapped(address: UInt64)
  case misaligned(address: UInt64)
  case fauOutOfRange(slot: Int)
  case reservedSpecial(page: Int, entry: Int)
  /// An encoding the spec calls invalid, or a variant this interpreter does not model.
  case invalid(String)
  case pcOutOfRange(Int)
  case stepLimit
}

public struct InterpError: Error, Sendable, Equatable {
  public var fault: Fault
  public var workgroup: Dim3
  public var warp: Int
  public var pc: Int
}
