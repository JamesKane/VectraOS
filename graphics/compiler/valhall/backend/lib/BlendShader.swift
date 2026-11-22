// SPDX-License-Identifier: BSD-3-Clause

// Blend shaders (valhall 09 sections 9.9 and 9.10, with the worked shader of 9.10.1): the code a fragment shader jumps to
// for a render target whose blend the blender can't do (min and max, the saturated source alpha, constants that differ between
// channels, dual-source factors, logic operations, alpha-to-one). `BlendShaderSpec` (MaliCore) says what to compute for an
// 8-bit unorm or sRGB target; the result is straight-line code in registers r0 to r15 and r48, written by hand here, not selected.
//
// Registers (09 section 9.9.2 fixes the first, the rest are this file's):
//   r0..r3   the source colour, f32 (R, G, B, A); the result is made here
//   r4..r7   the second source colour (dual source), f32; r4 is scratch otherwise
//   r8, r9   the destination as the tile load gives it (f16, two registers: (R, G) and (B, A)); then scratch; then the colour
//            handed to BLEND
//   r10..r13 the destination as f32
//   r12:r13  (the opaque operand, a 64-bit register pair, loaded just before BLEND)
//   r14, r15 the factors of the source and destination terms, and constants
//   r48      the return address; r60 the coverage
//
// The arithmetic is in f32 and the tile is read and written as f16 (the working type of 9.10 step 1 for an 8-bit target): an
// 8-bit value read as f16 and written back through f16 round trips exactly (the f16 error is below an eighth of a step), so a
// logic operation, which works on the 8-bit codes, is exact. The sequence follows the reference's structure (9.10.1); what the
// section marks as this driver's (the instruction names, the scratch registers, the f32 arithmetic) is checked on the board.

#if canImport(MaliCore)
  import MaliCore
#endif
#if canImport(ValhallISA)
  import ValhallISA
#endif

/// A compiled blend shader.
public struct BlendShader: Sendable {
  /// The code, one word per instruction; the descriptor's address is of the first.
  public var code: [UInt64]
  public var instructions: [Instruction]
  /// The shader loads the destination (the descriptor's Load Destination must be set).
  public var loadsDestination: Bool
  /// The shader reads the blend constants from the fragment FAU's first four words.
  public var usesConstants: Bool

  /// The listing, one instruction a line (valhall 10.14).
  public var listing: String {
    var s = ""
    for i in instructions { s += ISATable.shared.disassemble(i) + "\n" }
    return s
  }
}

/// The instructions of one blend shader, by physical register.
struct BlendCode {
  var out: [Instruction] = []
  var cache = OpCache()
  let arch: Int

  /// A source operand.
  enum S {
    case r(Int)
    /// A small constant, index 0 to 31 (10.5.2).
    case k(Int)
    /// A user FAU word.
    case u(Int)
  }
  static let zero = S.k(0)
  static let one = S.k(16)

  init(arch: Int) { self.arch = arch }

  @discardableResult
  mutating func emit(
    _ mn: String, _ variant: String = "", dst: Int? = nil, _ srcs: [S] = [], set: [(String, Int)] = [],
    named: [(String, String)] = [], flow: Flow = .none
  ) -> Int {
    var i = Instruction(op: cache.id(mn, variant, arch: arch))
    for (k, v) in set { i.put(k, v) }
    for (k, v) in named { i.put(k, v) }
    var page = -1
    for (n, s) in srcs.enumerated() {
      switch s {
      case .r(let r): i.setSource(n, Source.register(r))
      case .k(let c): i.setSource(n, Source.constant(c))
      case .u(let w):
        i.setSource(n, Source.user(slot: (w / 2) % 32, word: w % 2))
        page = w / 2 / 32
      }
    }
    if page >= 0 { i.fauPage = page }
    if let d = dst { i.put("dst", d) }
    i.flow = flow
    ISATable.shared.normalize(&i)
    out.append(i)
    return out.count - 1
  }

  /// A wait, carried by the last instruction when it can, else by a NOP (a wait takes effect after its carrier, 10.9).
  mutating func wait(_ w: Flow) {
    if let last = out.last, last.flow == .none, !last.def.isMessage {
      out[out.count - 1].flow = w
    } else {
      emit("NOP", flow: w)
    }
  }

  mutating func move(_ d: Int, immediate v: UInt32) {
    emit("IADD_IMM", "i32", dst: d, [BlendCode.zero], set: [("imm", Int(v))])
  }

  /// `d = a + b`, with the sign of each and the clamp of the result.
  mutating func add(_ d: Int, _ a: S, negateA: Bool = false, _ b: S, negateB: Bool = false, clamp: Bool = false) {
    var set: [(String, Int)] = []
    if negateA { set.append(("neg0", 1)) }
    if negateB { set.append(("neg1", 1)) }
    emit("FADD", "f32", dst: d, [a, b], set: set, named: clamp ? [("clamp", "clamp_0_1")] : [])
  }

  /// `d = a * b`.
  mutating func multiply(_ d: Int, _ a: S, _ b: S) {
    emit("FMA", "f32", dst: d, [a, b, BlendCode.zero], set: [("neg2", 1)])
  }

  /// `d = 1 - x`.
  mutating func oneMinus(_ d: Int, _ x: S) { add(d, BlendCode.one, x, negateB: true) }

  /// `d = x`, clamped to the range of an 8-bit unorm (the source and the blend constant are clamped to the format, 9.10.1).
  mutating func clamped(_ d: Int, _ x: S) { add(d, x, BlendCode.zero, negateB: true, clamp: true) }

  mutating func logic(_ mn: String, _ d: Int, _ a: S, _ b: S) {
    emit(mn, "i32", dst: d, [a, BlendCode.zero, b], named: [("wd1", "b0")])
  }
}

/// A factor's value for one channel: nothing (zero), one, or a register.
private enum FactorValue {
  case zero
  case one
  case reg(Int)
}

private let destination = 10  // r10 to r13: the destination, f32
private let packed = 8  // r8, r9: the colour BLEND takes, f16

extension ValhallBackend {
  /// The blend shader for `spec` (09 sections 9.9 and 9.10). A refusal means the state isn't one this compiler's shader does.
  public static func compileBlendShader(_ spec: BlendShaderSpec, options: BackendOptions = BackendOptions()) throws(BackendError)
    -> BlendShader
  {
    var c = BlendCode(arch: options.arch)
    let mask = spec.writeMask & 0xF
    let logic = spec.effectiveLogic
    let reads = spec.readsDestination
    // Nothing is written when the result is the destination (a no-op operation, an empty mask): the shader only returns.
    let writes = mask != 0 && logic != .noop

    if writes {
      if reads {
        // 9.10 step 3 (12c.7.3): the pixel-index word, the coverage ANDed with 0x1F, and the conversion word.
        c.move(14, immediate: spec.pixelIndexWord)
        c.emit("AND_IMM", "i32", dst: 15, [.r(60)], set: [("imm", 0x1F)])
        c.move(12, immediate: spec.conversionWord)
        let ld = c.emit("LD_TILE", "", [.r(14), .r(15), .r(12)], named: [("fmt", "f16"), ("vsz", "v4"), ("slot", "slot0")])
        c.out[ld].put("sr", packed)
        ISATable.shared.normalize(&c.out[ld])
      }
      // Step 2 and the clamps of 9.10.1: alpha one, then the source (and the second source) to the format.
      if spec.alphaToOne { c.emit("MOV", "i32", dst: 3, [BlendCode.one]) }
      for k in 0..<4 { c.clamped(k, .r(k)) }
      if spec.usesSecondSource { for k in 4..<8 { c.clamped(k, .r(k)) } }
      if reads {
        c.wait(.wait0)
        for k in 0..<4 {
          c.emit("F16_TO_F32", "", dst: destination + k, [.r(packed + k / 2)], set: [("wd0", k % 2)])
        }
      }
      if let l = logic {
        try logicChannels(&c, l, mask: mask)
      } else if spec.evaluatesEquation {
        equationChannels(&c, spec, mask: mask)
      } else if mask != 0xF {
        for k in 0..<4 where mask & (1 << UInt32(k)) == 0 { c.emit("MOV", "i32", dst: k, [.r(destination + k)]) }
      }
      // Step 6: the colour as f16, in the two registers BLEND reads, and the opaque operand in a register pair.
      for k in 0..<4 {
        c.emit(
          "F32_TO_F16", "", dst: packed + k / 2, [.r(k)], named: [("dw", k % 2 == 0 ? "h0" : "h1"), ("clamp", "clamp_0_1")])
      }
      let operand = spec.opaqueOperand
      c.move(12, immediate: UInt32(truncatingIfNeeded: operand))
      c.move(13, immediate: UInt32(truncatingIfNeeded: operand >> 32))
      let b = c.emit("BLEND", "", [.r(12), BlendCode.zero, .r(60)], named: [("fmt", "f16"), ("slot", "slot1")])
      c.out[b].put("sr", packed)
      ISATable.shared.normalize(&c.out[b])
    }
    // Step 7: a conditional jump to the link register when it is not zero; else the end (9.9.4).
    c.emit("JUMP", "", [.r(48), .r(48)])
    c.emit("NOP", flow: .end)

    if options.validate {
      let vo = ValidatorOptions(arch: options.arch, stage: .blend, registerClass: .class32)
      if let first = ISATable.shared.validate(c.out, options: vo).first {
        throw BackendError.invalidOutput("a blend shader: " + first.rule + " at " + String(first.instruction) + ": " + first.message)
      }
    }
    var code: [UInt64] = []
    for i in c.out {
      do { code.append(try ISATable.shared.encode(i)) } catch { throw BackendError.invalidOutput(error.description) }
    }
    return BlendShader(code: code, instructions: c.out, loadsDestination: writes && reads, usesConstants: spec.usesConstants)
  }

  // MARK: the equation

  /// The factor `f` of channel `k` (the alpha channel's functions use the alpha variants of the colour factors, 9.4.2), made in
  /// register `t` when it isn't a register already; `spare` is a scratch register.
  private static func factor(_ c: inout BlendCode, _ f: BlendFactor, channel k: Int, into t: Int, spare: Int) -> FactorValue {
    let alpha = k == 3
    let own = alpha ? 3 : k
    switch f {
    case .zero: return .zero
    case .one: return .one
    case .srcColour: return .reg(own)
    case .srcAlpha: return .reg(3)
    case .oneMinusSrcColour:
      c.oneMinus(t, .r(own))
      return .reg(t)
    case .oneMinusSrcAlpha:
      c.oneMinus(t, .r(3))
      return .reg(t)
    case .dstColour: return .reg(destination + own)
    case .dstAlpha: return .reg(destination + 3)
    case .oneMinusDstColour:
      c.oneMinus(t, .r(destination + own))
      return .reg(t)
    case .oneMinusDstAlpha:
      c.oneMinus(t, .r(destination + 3))
      return .reg(t)
    case .constantColour, .constantAlpha, .oneMinusConstantColour, .oneMinusConstantAlpha:
      let word = f == .constantAlpha || f == .oneMinusConstantAlpha || alpha ? 3 : k
      c.clamped(t, .u(word))
      if f == .oneMinusConstantColour || f == .oneMinusConstantAlpha { c.oneMinus(t, .r(t)) }
      return .reg(t)
    case .srcAlphaSaturate:
      if alpha { return .one }
      // min(Sa, 1 - Da)
      c.oneMinus(spare, .r(destination + 3))
      c.emit("FMIN", "f32", dst: t, [.r(3), .r(spare)])
      return .reg(t)
    case .src1Colour: return .reg(4 + own)
    case .src1Alpha: return .reg(7)
    case .oneMinusSrc1Colour:
      c.oneMinus(t, .r(4 + own))
      return .reg(t)
    case .oneMinusSrc1Alpha:
      c.oneMinus(t, .r(7))
      return .reg(t)
    }
  }

  /// The blend equation on each channel the mask writes, the result in r0 to r3 (a channel the mask doesn't write is the destination).
  private static func equationChannels(_ c: inout BlendCode, _ spec: BlendShaderSpec, mask: UInt32) {
    let e = spec.equation
    for k in 0..<4 {
      if mask & (1 << UInt32(k)) == 0 {
        c.emit("MOV", "i32", dst: k, [.r(destination + k)])
        continue
      }
      let alpha = k == 3
      let op = alpha ? e.alphaOperation : e.colourOperation
      let fs = alpha ? e.alphaSource : e.colourSource
      let fd = alpha ? e.alphaDestination : e.colourDestination
      if op == .min || op == .max {
        c.emit(op == .min ? "FMIN" : "FMAX", "f32", dst: k, [.r(k), .r(destination + k)])
        continue
      }
      // The source term S * fs in r14, the destination term D * fd in r15 (or the source or destination itself for a factor of one).
      var a: FactorValue = .zero
      switch factor(&c, fs, channel: k, into: 14, spare: 8) {
      case .zero: break
      case .one: a = .reg(k)
      case .reg(let x):
        c.multiply(14, .r(k), .r(x))
        a = .reg(14)
      }
      var b: FactorValue = .zero
      switch factor(&c, fd, channel: k, into: 15, spare: 9) {
      case .zero: break
      case .one: b = .reg(destination + k)
      case .reg(let x):
        c.multiply(15, .r(destination + k), .r(x))
        b = .reg(15)
      }
      // The terms and their signs: add S + D, subtract S - D, reverse subtract D - S.
      let negateA = op == .reverseSubtract
      let negateB = op == .subtract
      switch (a, b) {
      case (.reg(let x), .reg(let y)): c.add(k, .r(x), negateA: negateA, .r(y), negateB: negateB, clamp: true)
      case (.reg(let x), _): c.add(k, .r(x), negateA: negateA, BlendCode.zero, negateB: true, clamp: true)
      case (_, .reg(let y)): c.add(k, .r(y), negateA: negateB, BlendCode.zero, negateB: true, clamp: true)
      default: c.move(k, immediate: 0)
      }
    }
  }

  // MARK: logic operations

  /// A logic operation on the 8-bit codes of each channel the mask writes (09 section 9.12.1 item 3): the source and the
  /// destination to integers (round to nearest), the operation bitwise, the result back to a float.
  private static func logicChannels(_ c: inout BlendCode, _ l: LogicOperation, mask: UInt32) throws(BackendError) {
    c.move(14, immediate: 0x437F_0000)  // 255.0
    c.move(15, immediate: 0x3B80_8081)  // 1 / 255
    for k in 0..<4 {
      if mask & (1 << UInt32(k)) == 0 {
        c.emit("MOV", "i32", dst: k, [.r(destination + k)])
        continue
      }
      // s in r8, d in r9 (as codes 0 to 255).
      c.multiply(8, .r(k), .r(14))
      c.emit("F32_TO_U32", "", dst: 8, [.r(8)])
      if l.readsDestination {
        c.multiply(9, .r(destination + k), .r(14))
        c.emit("F32_TO_U32", "", dst: 9, [.r(9)])
      }
      func invert(_ r: Int) { c.emit("XOR_IMM", "i32", dst: r, [.r(r)], set: [("imm", 0xFF)]) }
      switch l {
      case .clear: c.move(8, immediate: 0)
      case .set: c.move(8, immediate: 0xFF)
      case .copy: break
      case .noop: throw BackendError.invalidIR("a no-op logic operation has no blend shader code")
      case .and: c.logic("LSHIFT_AND", 8, .r(8), .r(9))
      case .andReverse:
        invert(9)
        c.logic("LSHIFT_AND", 8, .r(8), .r(9))
      case .andInverted:
        invert(8)
        c.logic("LSHIFT_AND", 8, .r(8), .r(9))
      case .xor: c.logic("LSHIFT_XOR", 8, .r(8), .r(9))
      case .or: c.logic("LSHIFT_OR", 8, .r(8), .r(9))
      case .nor:
        c.logic("LSHIFT_OR", 8, .r(8), .r(9))
        invert(8)
      case .equivalent:
        c.logic("LSHIFT_XOR", 8, .r(8), .r(9))
        invert(8)
      case .invert:
        invert(9)
        c.emit("MOV", "i32", dst: 8, [.r(9)])
      case .orReverse:
        invert(9)
        c.logic("LSHIFT_OR", 8, .r(8), .r(9))
      case .copyInverted: invert(8)
      case .orInverted:
        invert(8)
        c.logic("LSHIFT_OR", 8, .r(8), .r(9))
      case .nand:
        c.logic("LSHIFT_AND", 8, .r(8), .r(9))
        invert(8)
      }
      c.emit("U32_TO_F32", "", dst: 8, [.r(8)])
      c.multiply(k, .r(8), .r(15))
    }
  }
}
