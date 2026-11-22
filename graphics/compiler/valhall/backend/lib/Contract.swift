// SPDX-License-Identifier: BSD-3-Clause

// What the Valhall backend takes and gives (D174 section 3): the options, the
// errors, the compiled shader, and the FAU layout, which is the contract
// between the compiler and the driver that dispatches the shader.
//
// The FAU block is an array of 64-bit slots the shader reads through user FAU
// sources (valhall 10.5.3, 14.7). The compiler chooses where each value sits
// (14.7.3: "a different driver can choose a different layout if its compiler
// addresses it consistently"); `FauLayout` (MaliCore's: data, so a dispatch needs no
// compiler) is the compiler's answer, and `FauLayout.block(...)` builds the block from it. The order, always:
//
//   1. one slot for each storage or uniform buffer the shader names (set and
//      binding), in ascending (set, binding) order: the buffer's 64-bit GPU
//      address. A shader of one buffer has its address in slot 0, as the
//      bring-up shader's does.
//   2. two slots for the number of workgroups (x, y, z, then a pad word),
//      when the shader reads it.
//   3. the byte size of each buffer whose run-time array length the shader
//      reads, one 32-bit word each, in the order of (1), packed from the
//      next slot.
//   3b. the heap handle of element 0 of each storage image binding the shader names (`imageBindings`), one 32-bit
//      word each, in ascending (set, binding) order.
//   4. the push constants, from the next slot: word n is the API push
//      constant at byte offset 4n, for every word up to the highest the
//      shader reads.
//
// Slots 0 to 127 are reachable (4 pages of 32; 10.5.3). A shader that needs
// more is refused (`fauOverflow`).

#if canImport(MaliCore)
  import MaliCore
#endif
#if canImport(ShaderCompiler)
  import ShaderCompiler
#endif
#if canImport(ValhallISA)
  import ValhallISA
#endif

public enum BackendError: Error, Equatable {
  /// The IR or the SPIR-V behind it holds something the backend does not select (the text says what).
  case unsupported(String)
  /// The IR is malformed, or the shader breaks a rule the backend relies on.
  case invalidIR(String)
  /// More values live at once than the registers hold, and spilling could not help.
  case outOfRegisters
  /// The FAU layout needs more than 128 slots.
  case fauOverflow
  /// Stack or spill slots past what a 16-bit offset reaches.
  case stackOverflow
  /// A bug: a rule of the ISA validator broke on the backend's own output (the first violation's text).
  case invalidOutput(String)
  /// Front-end errors, with the front end's text.
  case frontEnd(String)
}

/// What a vertex shader's generic varying stores do, for the board probes: `tested` is the compiler's own (the group's
/// stores behind a test of `shader_output` bit 2); `always` makes them in every pass; `shaderOutput` makes them in
/// every pass and stores `shader_output & 255` (as the float of that many 255ths, so a colour shows it as a byte) in
/// the first component of the first varying, to show what the hardware sets.
public enum VaryingProbe: Sendable {
  case tested, always, shaderOutput
}

public struct BackendOptions: Sendable {
  public var varyingProbe: VaryingProbe = .tested
  /// The arch major to compile for (valhall 17 for 14; 12 is the Immortalis-G720's).
  public var arch: Int
  /// Allocate in class 32 when the shader fits (valhall 15.2.3); false: always class 64.
  public var preferClass32: Bool
  /// Allocate no more than this many registers, in allocation order, to force spills in tests (nil: all).
  public var registerLimit: Int?
  /// The SPD's flush-to-zero mode the shader will run with (valhall 04.2.4).
  public var flushToZeroMode: UInt32
  /// Run the ISA validator over the output and fail with `invalidOutput` when a rule breaks.
  public var validate: Bool
  /// A vertex shader's varyings the fragment shader declares NoPerspective, bit n for location n (14.3.6), when the
  /// compile knows them (the fragment shader's `nonPerspectiveMask`); nil reads the mask from the FAU at run time.
  public var nonPerspectiveMask: UInt32?
  /// Make a texture access whose handle differs between lanes a loop over the distinct handles (valhall 12b.2.1). On:
  /// the hardware reads one handle for a warp. A test turns it off to see what that does.
  public var uniformTextureHandles = true
  /// Build every ballot from lane permutes instead of WMASK (valhall 13.9.4: whether WMASK reports the lanes executing it or every lane launched is open): the
  /// permute (CLPER) gives zero for a lane that is not executing, whatever WMASK does, so the ballot is 16 permutes of the operand. Off: WMASK is trusted.
  public var ballotWithoutWMASK = false
  /// A fragment shader that may call a blend shader (valhall 09 section 9.9): after each `BLEND`, the 16-byte call sequence of 9.9.1; the
  /// colour staged in r0 to r3 for each; the blend constants reserved in the first two FAU slots (9.9.5); and nothing the shader needs
  /// after a `BLEND` kept in r0 to r15 or r48 (9.9.2). Off, a fragment shader has none of these.
  public var blendShaders = false

  public init(
    arch: Int = 12, preferClass32: Bool = true, registerLimit: Int? = nil, flushToZeroMode: UInt32 = 0, validate: Bool = true,
    nonPerspectiveMask: UInt32? = 0
  ) {
    self.nonPerspectiveMask = nonPerspectiveMask
    self.arch = arch
    self.preferClass32 = preferClass32
    self.registerLimit = registerLimit
    self.flushToZeroMode = flushToZeroMode
    self.validate = validate
  }
}

/// A shader the backend made.
public struct CompiledShader: Sendable {
  /// What MaliCore dispatches.
  public var shader: ComputeShader
  public var layout: FauLayout
  /// The instructions the words encode, for tests and listings.
  public var instructions: [Instruction]
  /// Registers the allocation used (the highest number plus one) and the spill slots it made.
  public var registersUsed: Int
  public var spillSlots: Int

  /// The listing, one instruction a line (valhall 10.14).
  public var listing: String {
    var s = ""
    for i in instructions {
      s += ISATable.shared.disassemble(i) + "\n"
    }
    return s
  }
}
