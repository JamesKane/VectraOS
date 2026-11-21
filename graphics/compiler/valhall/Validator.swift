// SPDX-License-Identifier: BSD-3-Clause

// The validator (D174 section 7): the rules a shader must keep, checked over
// a sequence of instructions. Each rule has a name (`ValidationRule`), so a
// test can say which rule a bad sequence breaks and a compiler's tests can
// run every compiled shader through all of them.
//
// The rules are valhall 10.12 (the encoding checklist), 10.5.6 (FAU), 10.7
// (staging registers), 10.9 (the flow field and the wait table), 13 (control
// flow, discard, barrier) and 15 (registers, hazards, last use, quirks).
// Where the spec leaves a question open the check takes the safe reading
// and the rule's note says which.

/// The stage a shader runs in; some rules depend on it.
public enum ShaderStage: Sendable {
  case vertex, fragment, compute
  /// A blend shader, called from a fragment shader that already waited.
  case blend
}

/// The register class of the shader program descriptor (valhall 15.2.2).
public enum ValidatorRegisterClass: Sendable {
  /// r0 to r63.
  case class64
  /// r0 to r15 and r48 to r63.
  case class32
}

public struct ValidatorOptions: Sendable {
  public var arch: Int
  public var stage: ShaderStage
  public var registerClass: ValidatorRegisterClass
  /// Require every memory access that may alias an earlier outstanding one
  /// to wait for it (valhall 15.4.1 W3). Without alias information this
  /// treats every pair of accesses as aliasing, as the reference compilers
  /// do (W4); a compiler that proves independence turns it off.
  public var orderMemory: Bool

  public init(
    arch: Int = 12, stage: ShaderStage = .compute, registerClass: ValidatorRegisterClass = .class64, orderMemory: Bool = true
  ) {
    self.arch = arch
    self.stage = stage
    self.registerClass = registerClass
    self.orderMemory = orderMemory
  }
}

/// One broken rule.
public struct Violation: Equatable, Sendable {
  /// The rule's name, one of `ValidationRule.all`.
  public var rule: String
  /// The index of the instruction in the shader.
  public var instruction: Int
  public var message: String
}

/// The rules, by name.
public enum ValidationRule {
  /// The instruction encodes: fields fit, enumerations name a value, the flow value is defined.
  public static let encodable = "encodable"
  /// The instruction exists on the arch (valhall 10.15).
  public static let archAvailable = "arch-available"
  /// Registers outside the class's range are not named (15.2.2).
  public static let registerClass = "register-class"
  /// 64-bit operands start at an even register or name a whole FAU slot (10.4, 10.5.4).
  public static let pairAlignment = "pair-alignment"
  /// A staging block of two or more registers starts at an even register (10.7).
  public static let stagingAlignment = "staging-alignment"
  /// A staging block ends at or below r63 (10.7; the spec leaves open whether the hardware checks).
  public static let stagingRange = "staging-range"
  /// A derived staging count has the value its rule gives (10.13.1).
  public static let stagingCount = "staging-count"
  /// A special FAU entry read is one the hardware defines (10.5.3).
  public static let specialEntry = "special-entry"
  /// The FAU page is zero when no FAU word is read (10.5.3, the safe reading).
  public static let fauPage = "fau-page"
  /// At most two distinct FAU and small-constant words, and the FAU location rules (10.5.6).
  public static let fauBudget = "fau-budget"
  /// A message instruction reads neither `warp_id` nor a page 3 special entry (10.5.6).
  public static let messageSpecial = "message-special"
  /// `MMUL` keeps the FAU page at 0 (10.5.6).
  public static let mmulPage = "mmul-page"
  /// A message instruction names slot 0, 1 or 2 (7 for `BARRIER`) (10.9.1).
  public static let slotField = "slot-field"
  /// The coverage register of `ATEST`, `ZS_EMIT` and `BLEND` is r60 (15.2.4).
  public static let fixedRegister = "fixed-register"
  /// `ATEST` and `ZS_EMIT` wait for slot 6 (10.9.2).
  public static let waitFragmentOutput = "wait-fragment-output"
  /// `BLEND`, `ST_TILE` and a colour `LD_TILE` wait for slots 6 and 7, depth and stencil `LD_TILE` for slot 6 (10.9.2).
  public static let waitTile = "wait-tile"
  /// `BARRIER` carries `wait` and every busy general slot was waited on earlier, apart from it (10.9.2, 13.8).
  public static let waitBarrier = "wait-barrier"
  /// A register is not read before the slot of the message that writes it is waited on (15.4.1 W1).
  public static let waitRAW = "wait-raw"
  /// A register is not written before the slot of the message that writes it is waited on (15.4.1 W2).
  public static let waitWAW = "wait-waw"
  /// A memory access that may alias an outstanding one waits for it (15.4.1 W3).
  public static let memoryOrder = "memory-order"
  /// An interpolating varying load that stores or clobbers the hidden position waits for earlier users (15.4.1 W9).
  public static let varyingHiddenState = "varying-hidden-state"
  /// A register marked last use is not read again before it is written (10.5.5, 15.8.1).
  public static let lastUseLive = "last-use-live"
  /// A register still read by an in-flight message is not marked last use (10.5.5, 15.8.1).
  public static let lastUseStaging = "last-use-staging"
  /// A branch lands inside the shader (13.4.4).
  public static let branchTarget = "branch-target"
  /// The last instruction of a block that falls or branches into a join carries `reconverge` (10.9.2, 13.5.2).
  public static let reconverge = "reconverge"
  /// Every path ends with an instruction carrying `end` (13.6.6).
  public static let endOfShader = "end-of-shader"
  /// `discard` is used in fragment shaders only (10.9.2).
  public static let discardStage = "discard-stage"
  /// `BARRIER` is for compute shaders; `CLPER` and `WMASK` for fragment and compute shaders (13.8, 13.9).
  public static let stageInstruction = "stage-instruction"
  /// Every `ZS_EMIT` follows an `ATEST` (10.9.2, the generated order).
  public static let atestBeforeZS = "atest-before-zs"
  /// The restrictions a definition's fields carry that the encoding alone does not enforce (compare types,
  /// `LD_PKA` lanes, the 64-bit saturate bit, texture and varying forms, `JUMP` mode).
  public static let formRestriction = "form-restriction"

  public static let all: [String] = [
    encodable, archAvailable, registerClass, pairAlignment, stagingAlignment, stagingRange, stagingCount,
    specialEntry, fauPage, fauBudget, messageSpecial, mmulPage, slotField, fixedRegister, waitFragmentOutput,
    waitTile, waitBarrier, waitRAW, waitWAW, memoryOrder, varyingHiddenState, lastUseLive, lastUseStaging,
    branchTarget, reconverge, endOfShader, discardStage, stageInstruction, atestBeforeZS, formRestriction,
  ]
}

// MARK: register and FAU use

/// What an instruction reads and writes.
struct RegisterUse {
  /// Registers read by sources and the staging read block.
  var reads: UInt64 = 0
  /// Registers marked last use in sources.
  var marked: UInt64 = 0
  /// Registers written whole by the destination.
  var fullWrites: UInt64 = 0
  /// Registers written in one half only.
  var partialWrites: UInt64 = 0
  /// The staging block written (a message's result).
  var stagingWrites: UInt64 = 0
  /// The staging block read.
  var stagingReads: UInt64 = 0
}

struct EffectiveSource {
  var index: Int
  var byte: UInt8
  var wide: Bool
}

func registerMask(_ first: Int, _ count: Int) -> UInt64 {
  var m: UInt64 = 0
  var i = 0
  while i < count {
    if first + i < 64 { m |= 1 << UInt64(first + i) }
    i += 1
  }
  return m
}

extension ISATable {
  /// The sources an instruction reads, including those an alias fixes in its base word.
  func effectiveSources(_ inst: Instruction) -> [EffectiveSource] {
    let d = defs[inst.op]
    var out: [EffectiveSource] = []
    var n = 0
    while n < 4 {
      let i = d.fieldIndex(role: .source(n))
      if i >= 0 {
        out.append(EffectiveSource(index: n, byte: UInt8(truncatingIfNeeded: inst.values[i]), wide: d.fields[i].kind != .src32))
      } else if d.isAlias {
        let u = defs[d.aliasOf]
        let ui = u.fieldIndex(role: .source(n))
        if ui >= 0 {
          out.append(
            EffectiveSource(index: n, byte: UInt8(truncatingIfNeeded: d.base >> UInt64(8 * n)), wide: u.fields[ui].kind != .src32))
        }
      }
      n += 1
    }
    return out
  }

  func registerUse(_ inst: Instruction) -> RegisterUse {
    var u = RegisterUse()
    for s in effectiveSources(inst) {
      let src = Source(byte: s.byte)
      if src.kind == .register {
        let m = registerMask(src.register, s.wide ? 2 : 1)
        u.reads |= m
        if src.lastUse { u.marked |= m }
      }
    }
    let d = defs[inst.op]
    if let r = inst.destination {
      let m = registerMask(r, inst.destinationIs64Bit ? 2 : 1)
      let dw = inst.destinationWidth
      if d.fieldIndex(role: .destinationWidth) >= 0 && (dw == 1 || dw == 2) {
        u.partialWrites |= m
      } else {
        u.fullWrites |= m
      }
    }
    if let b = inst.stagingRead { u.stagingReads = registerMask(b.first, b.count) }
    if let b = inst.stagingWrite { u.stagingWrites = registerMask(b.first, b.count) }
    u.reads |= u.stagingReads
    // fused varying-and-texture forms with a sample position read the identifier register r61
    if d.cls == .s3a {
      let sel = inst.value("sel") ?? 0
      if sel != 0 && sel != 4 && sel != 7 { u.reads |= 1 << 61 }
    }
    return u
  }

  /// The FAU and small-constant words an instruction reads.
  struct FAUWords {
    var user: [Int] = []  // 64-bit slot indices
    var special: [Int] = []  // entries
    var words: [Int] = []  // distinct FAU words and constants, as keys
    var reads: Bool { !user.isEmpty || !special.isEmpty }
  }

  func fauWords(_ inst: Instruction, arch: Int) -> FAUWords {
    var f = FAUWords()
    func add(_ key: Int) { if !f.words.contains(key) { f.words.append(key) } }
    for s in effectiveSources(inst) {
      let src = Source(byte: s.byte)
      switch src.kind {
      case .register: break
      case .userFAU:
        let slot = src.fauSlot
        if !f.user.contains(slot) { f.user.append(slot) }
        if s.wide {
          add(slot * 2)
          add(slot * 2 + 1)
        } else {
          add(slot * 2 + src.word)
        }
      case .special:
        let e = src.specialEntry
        if !f.special.contains(e) { f.special.append(e) }
        if s.wide {
          add(1000 + e * 2)
          add(1000 + e * 2 + 1)
        } else {
          add(1000 + e * 2 + src.word)
        }
      case .constant:
        // the zero constant is free from arch 12
        if src.constantIndex != 0 || arch < 12 { add(2000 + src.constantIndex) }
      }
    }
    return f
  }
}

// MARK: the validator

extension ISATable {
  /// Check a shader against the rules. An empty result means no rule is broken.
  public func validate(_ program: [Instruction], options: ValidatorOptions = ValidatorOptions()) -> [Violation] {
    var v = ShaderValidation(isa: self, program: program, options: options)
    v.run()
    return v.violations
  }
}

struct ShaderValidation {
  let isa: ISATable
  let program: [Instruction]
  let options: ValidatorOptions
  var violations: [Violation] = []

  init(isa: ISATable, program: [Instruction], options: ValidatorOptions) {
    self.isa = isa
    self.program = program
    self.options = options
  }

  mutating func fail(_ rule: String, _ i: Int, _ message: String) {
    violations.append(Violation(rule: rule, instruction: i, message: message))
  }

  mutating func run() {
    for i in 0..<program.count { checkInstruction(i) }
    checkControlFlow()
    checkHazards()
    checkLastUse()
    checkFragmentOutputOrder()
  }

  // MARK: per instruction

  func registerAllowed(_ r: Int) -> Bool {
    if options.registerClass == .class32 && r >= 16 && r < 48 { return false }
    return r < 64
  }

  mutating func checkInstruction(_ i: Int) {
    let inst = program[i]
    let d = inst.def
    let name = d.fullName
    // encodability
    do {
      _ = try isa.encode(inst)
    } catch {
      fail(ValidationRule.encodable, i, name + " does not encode: " + error.description)
    }
    if !d.available(on: options.arch) { fail(ValidationRule.archAvailable, i, name + " does not exist on arch " + String(options.arch)) }
    if options.arch <= 13 && inst.flow == .reserved14 { fail(ValidationRule.encodable, i, "flow value 14 is reserved") }
    let use = isa.registerUse(inst)
    let all = use.reads | use.fullWrites | use.partialWrites | use.stagingWrites
    var r = 0
    while r < 64 {
      if all & (1 << UInt64(r)) != 0 && !registerAllowed(r) {
        fail(ValidationRule.registerClass, i, name + " names r" + String(r) + ", which class 32 does not have")
        break
      }
      r += 1
    }
    // pairs and blocks
    for s in isa.effectiveSources(inst) where s.wide {
      let src = Source(byte: s.byte)
      switch src.kind {
      case .register:
        if src.register & 1 != 0 { fail(ValidationRule.pairAlignment, i, name + ": a 64-bit source starts at odd r" + String(src.register)) }
      case .userFAU, .special:
        if src.word != 0 { fail(ValidationRule.pairAlignment, i, name + ": a 64-bit FAU source names word 1") }
      case .constant: break
      }
    }
    if inst.destinationIs64Bit, let dst = inst.destination, dst & 1 != 0 {
      fail(ValidationRule.pairAlignment, i, name + ": a 64-bit destination starts at odd r" + String(dst))
    }
    for b in [inst.stagingRead, inst.stagingWrite] {
      guard let b else { continue }
      if b.count >= 2 && b.first & 1 != 0 { fail(ValidationRule.stagingAlignment, i, name + ": a block of \(b.count) starts at r\(b.first)") }
      if b.first + b.count > 64 { fail(ValidationRule.stagingRange, i, name + ": the block r\(b.first) x \(b.count) runs past r63") }
    }
    for (k, f) in d.fields.enumerated() where f.rule != .none && (f.role == .stagingCount || f.role == .stagingWriteCount) {
      if let x = isa.derive(f.rule, d, inst.values, k), x != inst.values[k] {
        fail(ValidationRule.stagingCount, i, name + ": the block has \(inst.values[k]) registers, the fields give \(x)")
      }
    }
    // FAU
    let fau = isa.fauWords(inst, arch: options.arch)
    for e in fau.special where SpecialFAU.name(page: inst.fauPage, entry: e) == nil {
      fail(ValidationRule.specialEntry, i, name + ": special entry \(e) of page \(inst.fauPage) is not defined")
    }
    for e in fau.special where inst.fauPage == 3 && ((e == 4 && options.arch < 12) || (e == 5 && options.arch < 13)) {
      fail(ValidationRule.specialEntry, i, name + ": special entry \(e) of page 3 does not exist on arch \(options.arch)")
    }
    // a special entry read needs the page that names it; with no FAU read the page is zero
    // (ADR reads `pc` through its alias, whose base word carries page 3)
    let expectedPage = fau.reads ? inst.fauPage : Int((d.base >> 57) & 3)
    if !fau.reads && inst.fauPage != expectedPage { fail(ValidationRule.fauPage, i, name + " reads no FAU but names page \(inst.fauPage)") }
    if d.cls == .m3 && inst.fauPage != 0 { fail(ValidationRule.mmulPage, i, "MMUL names FAU page \(inst.fauPage)") }
    let aluRules = d.unit != .msg || d.mnemonic.sym == "ATEST" || d.mnemonic.sym == "BLEND"
    let msgRules = d.unit == .msg
    if fau.words.count > 2 { fail(ValidationRule.fauBudget, i, name + " reads \(fau.words.count) FAU or constant words, at most 2 are allowed") }
    if aluRules && options.arch <= 13 && fau.user.count + fau.special.count > 1 {
      fail(ValidationRule.fauBudget, i, name + " reads more than one FAU location")
    }
    if msgRules && (fau.user.count > 1 || fau.special.count > 1) {
      fail(ValidationRule.fauBudget, i, name + " reads more than one user slot or special entry")
    }
    if msgRules {
      for e in fau.special {
        let page = inst.fauPage
        if (page == 0 && e == 2) || page == 3 { fail(ValidationRule.messageSpecial, i, name + " reads a special entry a message may not") }
      }
    }
    // slots
    if d.cls.isMessage, let si = Optional(d.fieldIndex(role: .slot)), si >= 0 {
      let s = inst.values[si]
      if d.mnemonic.sym == "BARRIER" ? s != 7 : s > 2 { fail(ValidationRule.slotField, i, name + " names slot \(s)") }
    }
    checkForm(i, inst)
    checkStage(i, inst)
    checkFlowWaits(i, inst)
  }

  /// The restrictions the field tables state in their text.
  mutating func checkForm(_ i: Int, _ inst: Instruction) {
    let d = inst.def
    let m = d.mnemonic.sym
    let name = d.fullName
    func nameOf(_ field: String) -> ByteName { (inst.valueName(field) ?? "").sym }
    switch m {
    case "ICMP_OR", "ICMP_AND", "ICMP", "ICMP_MULTI":
      let c = inst.value("cmp") ?? 0
      if c > 5 { fail(ValidationRule.formRestriction, i, name + ": gtlt and total are float comparisons") }
      if nameOf("rtype") == "c" && (m != "ICMP_MULTI" || d.variant.sym != "u32") {
        fail(ValidationRule.formRestriction, i, name + ": the c result type is ICMP_MULTI.u32 only")
      }
    case "CSEL":
      if d.variant.startsWithBytes("f") || d.variant.sym == "v2f16" { break }
      if (inst.value("cmp") ?? 0) > 5 { fail(ValidationRule.formRestriction, i, name + ": gtlt and total are float comparisons") }
    case "IADD", "ISUB":
      if d.variant.endsWithBytes("64") && options.arch >= 11 && (inst.value("saturate") ?? 0) != 0 {
        fail(ValidationRule.formRestriction, i, name + ": the 64-bit saturate bit must be 0 on arch 11 and later")
      }
    case "LD_PKA":
      if d.variant.sym == "i8" && (nameOf("lane") == "b1" || nameOf("lane") == "b3") {
        fail(ValidationRule.formRestriction, i, "LD_PKA.i8 into lane b1 or b3 hits the lane erratum")
      }
    case "JUMP":
      if options.arch >= 11 && nameOf("mode") != "absolute" { fail(ValidationRule.formRestriction, i, "JUMP is absolute from arch 11") }
    case "LD_TILE":
      if options.arch < 11 && (inst.value("last_read") ?? 0) != 0 {
        fail(ValidationRule.formRestriction, i, "LD_TILE has no last_read bit on arch 10")
      }
    case "FRCP", "FRSQ":
      if options.arch == 10 && d.variant.sym == "f16" && inst.destinationWidth == 2 {
        fail(ValidationRule.formRestriction, i, name + ": the arch 10 half result is never written to h1")
      }
    case "F32_TO_S32", "F32_TO_U32":
      if options.arch == 10 && (inst.value("wd0") ?? 0) != 0 {
        fail(ValidationRule.formRestriction, i, name + " has no widen on arch 10")
      }
    case "TEX_FETCH":
      if nameOf("dim") == "cube" { fail(ValidationRule.formRestriction, i, "TEX_FETCH has no cube form") }
    case "TEX_GATHER", "VAR_TEX_GATHER", "VAR_TEX_BUF_GATHER":
      let dim = nameOf("dim")
      if dim != "tex2d" && !(dim == "cube" && m == "TEX_GATHER") { fail(ValidationRule.formRestriction, i, name + ": gather is 2D or cube") }
    case "TEX_DUAL":
      if (inst.value("wide") ?? 0) != 0 { fail(ValidationRule.formRestriction, i, "TEX_DUAL takes packed handles") }
    case "LD_VAR", "LD_VAR_IMM", "LD_VAR_BUF", "LD_VAR_BUF_IMM":
      let f = nameOf("fmt")
      if !f.text.isEmpty && f != "auto32" && f != "f32" && f != "f16" { fail(ValidationRule.formRestriction, i, name + ": the format is f32 or f16") }
    case "LD_VAR_FLAT", "LD_VAR_FLAT_IMM":
      let f = nameOf("fmt")
      if f == "s16" || f == "u16" { fail(ValidationRule.formRestriction, i, name + ": no 16-bit integer formats") }
    case "LD_VAR_SPECIAL":
      if (inst.value("vsz") ?? 0) > 1 { fail(ValidationRule.formRestriction, i, "LD_VAR_SPECIAL is scalar or v2") }
      if nameOf("fmt") != "f32" { fail(ValidationRule.formRestriction, i, "LD_VAR_SPECIAL is f32") }
    default: break
    }
    if d.cls == .s3a {
      let lod = nameOf("lod")
      if !lod.text.isEmpty && lod != "none" && lod != "computed" { fail(ValidationRule.formRestriction, i, name + ": LOD mode none or computed only") }
    }
    if options.arch < 11 && (inst.value("project") ?? 0) != 0 && d.cls == .s2rw {
      fail(ValidationRule.formRestriction, i, name + ": no projection on arch 10")
    }
    // plain destination widths have no value 0
    let wi = d.fieldIndex(role: .destinationWidth)
    if wi >= 0 && d.fields[wi].family >= 0 && isa.families[d.fields[wi].family].name(of: 0) == nil && inst.values[wi] == 0 {
      fail(ValidationRule.formRestriction, i, name + ": destination width 0 is invalid")
    }
  }

  mutating func checkStage(_ i: Int, _ inst: Instruction) {
    let m = inst.mnemonic.sym
    if inst.flow == .discard && options.stage != .fragment && options.stage != .blend {
      fail(ValidationRule.discardStage, i, "discard is for fragment shaders")
    }
    if m == "BARRIER" && options.stage != .compute { fail(ValidationRule.stageInstruction, i, "BARRIER is for compute shaders") }
    if (m == "CLPER" || m == "WMASK") && options.stage != .fragment && options.stage != .compute {
      fail(ValidationRule.stageInstruction, i, m.text + " is for fragment and compute shaders")
    }
    // the coverage register
    func isR60(_ n: Int) -> Bool {
      guard let s = inst.source(n) else { return true }
      return s.kind == .register && s.register == 60
    }
    switch m {
    case "ATEST":
      if !isR60(0) || inst.stagingWrite?.first != 60 { fail(ValidationRule.fixedRegister, i, "ATEST uses r60 for coverage") }
    case "ZS_EMIT":
      if !isR60(2) || inst.stagingWrite?.first != 60 { fail(ValidationRule.fixedRegister, i, "ZS_EMIT uses r60 for coverage") }
    case "BLEND":
      if !isR60(2) { fail(ValidationRule.fixedRegister, i, "BLEND takes its coverage from r60") }
    default: break
    }
  }

  /// The waits of the table in valhall 10.9.2, under the rule the board showed (docs/gpu/valhall-board-findings.md):
  /// a wait in an instruction's flow field takes effect after that instruction, as reconverge, discard and end do,
  /// so the wait an instruction needs is carried by an earlier one. Here, an earlier instruction of the same block
  /// with no message between it and this one; the instruction's own flow field never counts.
  mutating func checkFlowWaits(_ i: Int, _ inst: Instruction) {
    let m = inst.mnemonic.sym
    func covers(_ test: (Flow) -> Bool) -> Bool {
      // any earlier instruction of the block, if no message lies between it and the consumer (the first instruction
      // of a block gets a NOP: the block before is not on every path)
      var j = i
      while j > 0 && !isJoinTarget(j) {
        j -= 1
        if program[j].def.isMessage || program[j].mnemonic.sym == "BRANCH" { return false }
        if test(program[j].flow) { return true }
      }
      return false
    }
    if options.stage == .blend { return }
    switch m {
    case "ATEST", "ZS_EMIT":
      if !covers({ $0.waitsSlot6 }) { fail(ValidationRule.waitFragmentOutput, i, m.text + " needs wait0126 or wait") }
    case "BLEND":
      if !covers({ $0.waitsSlot7 }) { fail(ValidationRule.waitTile, i, "BLEND needs wait") }
    case "ST_TILE":
      if !covers({ $0.waitsSlot7 }) { fail(ValidationRule.waitTile, i, "ST_TILE needs wait") }
    case "LD_TILE":
      if (inst.value("z_stencil") ?? 0) != 0 {
        if !covers({ $0.waitsSlot6 }) { fail(ValidationRule.waitTile, i, "a depth or stencil LD_TILE needs wait0126 or wait") }
      } else if !covers({ $0.waitsSlot7 }) {
        fail(ValidationRule.waitTile, i, "a colour LD_TILE needs wait")
      }
    case "BARRIER":
      if inst.flow != .wait { fail(ValidationRule.waitBarrier, i, "BARRIER carries wait") }
    default: break
    }
  }

  // MARK: control flow

  func successors(_ i: Int) -> [Int] {
    let inst = program[i]
    if inst.flow == .end { return [] }
    switch inst.mnemonic.sym {
    case "BRANCH":
      let target = i + 1 + Int(Int64(bitPattern: inst.value("offset") ?? 0))
      let unconditional = inst.source(0)?.byte == 0xC0 && (inst.value("not") ?? 0) != 0 && (inst.value("wd0") ?? 0) == 0
      return unconditional ? [target] : [target, i + 1]
    case "JUMP", "JUMP_EX":
      return []
    default:
      return [i + 1]
    }
  }

  /// The instructions some path from the entry reaches.
  func reachable() -> [Bool] {
    let n = program.count
    var reached = [Bool](repeating: false, count: n + 1)
    var work = [0]
    while let i = work.popLast() {
      if i < 0 || i > n || reached[i] { continue }
      reached[i] = true
      if i == n { continue }
      work.append(contentsOf: successors(i))
    }
    return reached
  }

  /// The edges into each instruction from reachable instructions.
  func predecessorCounts() -> [Int] {
    var n = [Int](repeating: 0, count: program.count + 1)
    let reached = reachable()
    for i in 0..<program.count where reached[i] {
      for s in successors(i) where s >= 0 && s <= program.count { n[s] += 1 }
    }
    return n
  }

  func isJoinTarget(_ i: Int) -> Bool {
    let counts = predecessorCounts()
    return counts[i] + (i == 0 ? 1 : 0) > 1
  }

  mutating func checkControlFlow() {
    let n = program.count
    if n == 0 { return }
    // branch targets
    for i in 0..<n where program[i].mnemonic.sym == "BRANCH" {
      let target = i + 1 + Int(Int64(bitPattern: program[i].value("offset") ?? 0))
      if target < 0 || target >= n { fail(ValidationRule.branchTarget, i, "the branch lands at \(target), outside 0..<\(n)") }
    }
    // reachability: no path falls off the end
    let reached = reachable()
    if reached[n] {
      // report the instructions that fall into the end
      for i in 0..<n where reached[i] && successors(i).contains(n) {
        fail(ValidationRule.endOfShader, i, "a path runs past the last instruction without end")
      }
    }
    // reconverge on the last instruction of a block feeding a join
    var counts = predecessorCounts()
    counts[0] += 1
    for p in 0..<n where reached[p] {
      for s in successors(p) where s >= 0 && s < n && counts[s] > 1 && program[p].flow != .reconverge {
        fail(ValidationRule.reconverge, p, "this instruction leads to a join at \(s) and does not carry reconverge")
        break
      }
    }
  }

  // MARK: dataflow: hazards

  struct HazardState: Equatable {
    var pendingWrite: [UInt64] = [0, 0, 0]
    var pendingRead: [UInt64] = [0, 0, 0]
    var busy: UInt8 = 0
    var storesOut: UInt8 = 0
    var loadsOut: UInt8 = 0
    var varyingOut: UInt8 = 0

    mutating func merge(_ o: HazardState) {
      for s in 0..<3 {
        pendingWrite[s] |= o.pendingWrite[s]
        pendingRead[s] |= o.pendingRead[s]
      }
      busy |= o.busy
      storesOut |= o.storesOut
      loadsOut |= o.loadsOut
      varyingOut |= o.varyingOut
    }

    mutating func wait(_ slots: UInt8) {
      for s in 0..<3 where slots & (1 << UInt8(s)) != 0 {
        pendingWrite[s] = 0
        pendingRead[s] = 0
      }
      busy &= ~slots
      storesOut &= ~slots
      loadsOut &= ~slots
      varyingOut &= ~slots
    }

    var anyWrite: UInt64 { pendingWrite[0] | pendingWrite[1] | pendingWrite[2] }
    var anyRead: UInt64 { pendingRead[0] | pendingRead[1] | pendingRead[2] }
  }

  /// Memory access kind: 1 read, 2 write (stores and atomics), 0 none.
  func memoryKind(_ inst: Instruction) -> Int {
    switch inst.mnemonic.sym {
    case "LOAD", "LD_CHECKED", "LD_CHECKED_IMM", "LD_CVT": return 1
    case "STORE", "ST_CHECKED", "ST_CHECKED_IMM", "ST_CVT", "ATOM", "ATOM1", "ATOM1_RETURN", "ATOM_RETURN", "AXCHG",
      "ACMPXCHG":
      return 2
    default: return 0
    }
  }

  func isInterpolating(_ inst: Instruction) -> Bool {
    switch inst.mnemonic.sym {
    case "LD_VAR", "LD_VAR_IMM", "LD_VAR_BUF", "LD_VAR_BUF_IMM":
      return (inst.value("upd") ?? 0) != 1
    case "VAR_TEX_SINGLE", "VAR_TEX_GATHER", "VAR_TEX_GRADIENT", "VAR_TEX_DUAL", "VAR_TEX_BUF_SINGLE", "VAR_TEX_BUF_GATHER",
      "VAR_TEX_BUF_GRADIENT", "VAR_TEX_BUF_DUAL":
      return (inst.value("sel") ?? 0) != 7
    default: return false
    }
  }

  func isVaryingUser(_ inst: Instruction) -> Bool {
    inst.mnemonic.startsWithBytes("LD_VAR") && inst.mnemonic.sym != "LD_VAR_SPECIAL" || inst.mnemonic.startsWithBytes("VAR_TEX")
  }

  /// The state after instruction `i` from the state before it, and the state its checks see. The board showed that
  /// a wait in the flow field takes effect after the instruction (docs/gpu/valhall-board-findings.md): the checks
  /// see the entry state unchanged, and the wait clears its slots after the instruction, the message the
  /// instruction itself issues on one of them included.
  func step(_ i: Int, _ before: HazardState) -> (after: HazardState, waited: HazardState) {
    let inst = program[i]
    var s = before
    let waited = before
    let d = inst.def
    if d.cls.isMessage, let slot = inst.effectiveSlot, slot < 3 {
      let bit: UInt8 = 1 << UInt8(slot)
      s.busy |= bit
      let u = isa.registerUse(inst)
      s.pendingWrite[slot] |= u.stagingWrites
      s.pendingRead[slot] |= u.stagingReads
      switch memoryKind(inst) {
      case 1: s.loadsOut |= bit
      case 2: s.storesOut |= bit
      default: break
      }
      // A load that retrieves (a flat load always does, 12c.2.4) leaves the hidden register alone: nothing waits for it (12c.5.5).
      if isVaryingUser(inst) && isInterpolating(inst) { s.varyingOut |= bit }
    }
    s.wait(inst.flow.generalSlots)
    return (s, waited)
  }

  mutating func checkHazards() {
    let n = program.count
    if n == 0 { return }
    var entry = [HazardState?](repeating: nil, count: n + 1)
    entry[0] = HazardState()
    var work = [0]
    var guardCount = 0
    while let i = work.popLast(), guardCount < 100_000 {
      guardCount += 1
      guard i < n, let before = entry[i] else { continue }
      let after = step(i, before).after
      for s in successors(i) where s >= 0 && s < n {
        var merged = entry[s] ?? HazardState()
        let old = merged
        merged.merge(after)
        if entry[s] == nil || merged != old {
          entry[s] = merged
          work.append(s)
        }
      }
    }
    for i in 0..<n {
      guard let before = entry[i] else { continue }
      let (_, waited) = step(i, before)
      let inst = program[i]
      let name = inst.def.fullName
      let u = isa.registerUse(inst)
      let pendingW = waited.anyWrite
      if u.reads & pendingW != 0 { fail(ValidationRule.waitRAW, i, name + " reads a register a message still writes") }
      let writes = u.fullWrites | u.partialWrites | u.stagingWrites
      if writes & pendingW != 0 { fail(ValidationRule.waitWAW, i, name + " writes a register a message still writes") }
      if options.orderMemory {
        let kind = memoryKind(inst)
        if (kind == 1 && waited.storesOut != 0) || (kind == 2 && (waited.storesOut | waited.loadsOut) != 0) {
          fail(ValidationRule.memoryOrder, i, name + " may alias an outstanding access and does not wait for it")
        }
      }
      if isInterpolating(inst) && isVaryingUser(inst) && waited.varyingOut != 0 {
        fail(ValidationRule.varyingHiddenState, i, name + " changes the interpolation state while an earlier varying load is outstanding")
      }
      if inst.mnemonic.sym == "BARRIER" && before.busy & 7 != 0 {
        // the busy general slots, before the barrier's own wait: the instruction before it must have waited
        fail(ValidationRule.waitBarrier, i, "a general slot is busy at the barrier; it needs its own earlier wait")
      }
      // last use of a staging source of an in-flight message (valhall 10.5.5)
      let inFlight = waited.anyRead | u.stagingReads
      if u.marked & inFlight != 0 { fail(ValidationRule.lastUseStaging, i, name + " marks a register an in-flight message still reads") }
    }
  }

  // MARK: liveness: last use

  mutating func checkLastUse() {
    let n = program.count
    if n == 0 { return }
    var gen = [UInt64](repeating: 0, count: n)
    var kill = [UInt64](repeating: 0, count: n)
    var marked = [UInt64](repeating: 0, count: n)
    for i in 0..<n {
      let u = isa.registerUse(program[i])
      gen[i] = u.reads | u.partialWrites
      kill[i] = u.fullWrites | u.stagingWrites
      marked[i] = u.marked
    }
    var liveIn = [UInt64](repeating: 0, count: n + 1)
    var liveOut = [UInt64](repeating: 0, count: n)
    var changed = true
    var rounds = 0
    while changed && rounds < 1000 {
      changed = false
      rounds += 1
      var i = n - 1
      while i >= 0 {
        var out: UInt64 = 0
        for s in successors(i) where s >= 0 && s < n { out |= liveIn[s] }
        let inn = gen[i] | (out & ~kill[i])
        if out != liveOut[i] || inn != liveIn[i] {
          liveOut[i] = out
          liveIn[i] = inn
          changed = true
        }
        i -= 1
      }
    }
    for i in 0..<n where marked[i] != 0 {
      // a register the instruction overwrites whole may be marked on its own source
      let still = marked[i] & liveOut[i] & ~kill[i]
      if still != 0 {
        fail(ValidationRule.lastUseLive, i, program[i].def.fullName + " marks a register that is read again before it is written")
      }
    }
  }

  // MARK: fragment output order

  mutating func checkFragmentOutputOrder() {
    var sawATest = false
    for i in 0..<program.count {
      let m = program[i].mnemonic.sym
      if m == "ATEST" { sawATest = true }
      if m == "ZS_EMIT" && !sawATest { fail(ValidationRule.atestBeforeZS, i, "ZS_EMIT without an ATEST before it") }
    }
  }
}
