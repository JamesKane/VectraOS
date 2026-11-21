// SPDX-License-Identifier: BSD-3-Clause

// The Valhall backend for compute (D174 section 3, step 1): an IR module (or
// SPIR-V) to a `ComputeShader` MaliCore dispatches, with the FAU layout it
// reads. The order of the work:
//
//   inline calls, optimise, scalarise        (Prep, ShaderCompiler's passes)
//   select instructions over virtual registers   (Select*)
//   fit the FAU rules                        (Legalize)
//   allocate registers, spilling to the stack    (Alloc)
//   slots, waits, reconverge, end, offsets   (Emit, Backend.link)
//   check the result with the ISA validator, encode

#if canImport(MaliCore)
  import MaliCore
#endif
#if canImport(ShaderCompiler)
  import ShaderCompiler
#endif
#if canImport(ValhallISA)
  import ValhallISA
#endif

public enum ValhallBackend {
  /// Compile the entry point of SPIR-V words (the first GLCompute one, or `entryPoint`).
  public static func compile(
    spirv words: [UInt32], entryPoint: String? = nil, specialization: [(id: UInt32, bits: UInt64)] = [],
    options: BackendOptions = BackendOptions()
  ) throws(BackendError) -> CompiledShader {
    var ir: IRModule
    do {
      let s = try SPIRVModule.parse(words: words)
      ir = try IRModule.lower(s, entryPoint: entryPoint, specialization: specialization)
    } catch {
      throw BackendError.frontEnd(error.message)
    }
    return try compile(ir, options: options)
  }

  /// Compile a lowered module (optimised or not).
  public static func compile(_ module: IRModule, options: BackendOptions = BackendOptions()) throws(BackendError) -> CompiledShader {
    var m = module
    try Prep.inlineCalls(&m)
    do {
      try m.optimize()
      try m.verify(scalar: true)
      // No divide instruction exists (11b.1): the divisions become float estimates and corrections.
      let expanded = m.expandIntegerDivision()
      if m.expandLongConversions() || expanded { try m.verify(scalar: true) }
    } catch {
      throw BackendError.frontEnd(error.message)
    }
    try Prep.refuseDoubles(m)
    guard m.executionModel == 5 else { throw BackendError.unsupported("a shader that is not a compute shader") }
    var f = m.functions[m.entry]
    // A storage image's handle that differs between lanes is made uniform by a loop (12b.2.1).
    if options.uniformTextureHandles { Prep.uniformTextureHandles(&f) }
    Prep.splitCriticalEdges(&f)
    var sel = Selector(m, f, options)
    var mf = try sel.run()
    mf.legalize()
    var alloc = try mf.allocate(options)
    if alloc.highest < 0 { alloc.highest = 0 }

    // Registers in, waits, `end`.
    var blocks = mf.physical(alloc)
    for b in 0..<blocks.count {
      blocks[b] = Schedule.waits(blocks[b])
      blocks[b] = mergeEnd(blocks[b])
    }
    let instructions = try link(blocks)

    if options.validate {
      let vo = ValidatorOptions(
        arch: options.arch, stage: .compute, registerClass: alloc.class32 ? .class32 : .class64)
      let v = ISATable.shared.validate(instructions, options: vo)
      if let first = v.first {
        throw BackendError.invalidOutput(first.rule + " at " + String(first.instruction) + ": " + first.message)
      }
    }
    var code: [UInt64] = []
    for i in instructions {
      do {
        code.append(try ISATable.shared.encode(i))
      } catch {
        throw BackendError.invalidOutput(error.description)
      }
    }

    var layout = sel.fau
    var words = layout.bindings.count * 2
    if layout.numWorkgroupsWord >= 0 { words = max(words, layout.numWorkgroupsWord + 3) }
    for b in layout.bindings where b.sizeWord >= 0 { words = max(words, b.sizeWord + 1) }
    for b in layout.imageBindings { words = max(words, b.word + 1) }
    layout.pushWords = sel.maxPushWord + 1
    if layout.pushWords > 0 { words = max(words, layout.pushWord + layout.pushWords) }
    layout.words = (words + 1) / 2 * 2
    if layout.words > 256 { throw BackendError.fauOverflow }

    let merging = !(mf.usesBarrier || mf.usesWorkgroupMemory || mf.usesLaneID)
    let shader = ComputeShader(
      code: code, registerClass: alloc.class32 ? .r32 : .r64, preloadMask: mf.preload,
      workgroupSize: Dim3(m.localSize.x, m.localSize.y, m.localSize.z),
      stackBytes: UInt32((mf.stackBytes + 7) / 8 * 8), workgroupMemoryBytes: UInt32(sel.workgroupBytes),
      fauWords: UInt32(layout.words), allowsWorkgroupMerging: merging, flushToZeroMode: options.flushToZeroMode)
    return CompiledShader(
      shader: shader, layout: layout, instructions: instructions, registersUsed: alloc.highest + 1,
      spillSlots: mf.spillSlots)
  }

  /// `end` goes on the instruction before it when that one has no flow and cannot be left; else a NOP carries it.
  static func mergeEnd(_ list: [PInst]) -> [PInst] {
    var out: [PInst] = []
    for p in list {
      if p.kind == .end {
        if let last = out.last, last.inst.flow == .none, last.kind == .alu || last.kind == .message {
          out[out.count - 1].inst.flow = .end
        } else {
          var q = p
          q.inst.flow = .end
          out.append(q)
        }
      } else {
        out.append(p)
      }
    }
    return out
  }

  /// Mark the last read of registers (10.5.5), by the same dataflow the validator checks over the registers, and
  /// not on a register any message reads as staging (it may be in flight, 13.7.2).
  static func markLastUses(_ prog: inout [PInst], _ label: [Int]) {
    let n = prog.count
    var succ = [[Int]](repeating: [], count: n)
    for i in 0..<n {
      let p = prog[i]
      if p.inst.flow == .end { continue }
      if p.kind == .branch {
        let un = p.inst.source(0)?.byte == 0xC0 && (p.inst.value("not") ?? 0) != 0
        succ[i] = un ? [label[p.target]] : [label[p.target], i + 1]
      } else {
        succ[i] = [i + 1]
      }
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
        for s in succ[i] where s < n { out |= liveIn[s] }
        let inn = prog[i].reads | (out & ~prog[i].writes)
        if out != liveOut[i] || inn != liveIn[i] {
          liveOut[i] = out
          liveIn[i] = inn
          changed = true
        }
        i -= 1
      }
    }
    for i in 0..<n {
      for k in 0..<4 {
        guard let op = prog[i].inst.operand(k), op.source.kind == .register else { continue }
        // The coverage register is the hardware's: the fragment output instructions read and write it (14.4.3), and
        // the hand-written shader the board ran leaves it unmarked.
        let name = prog[i].inst.mnemonic.sym
        if op.source.register == 60 && (name == "ATEST" || name == "BLEND" || name == "ZS_EMIT") { continue }
        let r = regMask(op.source.register, op.is64Bit ? 2 : 1)
        var own: UInt64 = 0
        if let b = prog[i].inst.stagingRead { own = regMask(b.first, b.count) }
        if r & (prog[i].inflight | own) == 0 && r & liveOut[i] & ~prog[i].writes == 0 {
          prog[i].inst.setSource(k, Source(byte: op.source.byte | 0x40))
        }
      }
    }
  }

  /// Lay the blocks out, flag the instructions before joins `reconverge` (13.5.2) and resolve the branches.
  static func link(_ blocks: [[PInst]]) throws(BackendError) -> [Instruction] {
    var prog: [PInst] = []
    var label = [Int](repeating: 0, count: blocks.count)
    for b in 0..<blocks.count {
      label[b] = prog.count
      prog.append(contentsOf: blocks[b])
    }
    func isUncond(_ p: PInst) -> Bool {
      p.inst.source(0)?.byte == 0xC0 && (p.inst.value("not") ?? 0) != 0
    }
    var guardCount = 0
    while guardCount < 100_000 {
      guardCount += 1
      let n = prog.count
      // Successors and predecessor counts.
      var succ = [[Int]](repeating: [], count: n)
      for i in 0..<n {
        let p = prog[i]
        if p.inst.flow == .end { continue }
        if p.kind == .branch {
          succ[i] = isUncond(p) ? [label[p.target]] : [label[p.target], i + 1]
        } else {
          succ[i] = [i + 1]
        }
      }
      var reached = [Bool](repeating: false, count: n + 1)
      var work = [0]
      while let i = work.popLast() {
        if i < 0 || i > n || reached[i] { continue }
        reached[i] = true
        if i < n { work.append(contentsOf: succ[i]) }
      }
      var counts = [Int](repeating: 0, count: n + 1)
      counts[0] = 1
      for i in 0..<n where reached[i] { for s in succ[i] { counts[s] += 1 } }
      var fixed = false
      for i in 0..<n where reached[i] {
        var join = false
        for s in succ[i] where s < n && counts[s] > 1 { join = true }
        if !join || prog[i].inst.flow == .reconverge { continue }
        if prog[i].inst.flow == .none {
          prog[i].inst.flow = .reconverge
        } else if prog[i].kind == .branch {
          throw BackendError.invalidOutput("a branch that needs reconverge carries a wait")
        } else {
          var nop = Instruction("NOP")!
          nop.flow = .reconverge
          prog.insert(PInst(inst: nop, kind: .alu), at: i + 1)
          for b in 0..<label.count where label[b] >= i + 1 { label[b] += 1 }
          fixed = true
          break
        }
      }
      if !fixed { break }
    }
    markLastUses(&prog, label)
    var out: [Instruction] = []
    for i in 0..<prog.count {
      var inst = prog[i].inst
      if prog[i].kind == .branch { inst.put("offset", label[prog[i].target] - (i + 1)) }
      out.append(inst)
    }
    return out
  }
}
