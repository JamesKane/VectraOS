// SPDX-License-Identifier: BSD-3-Clause

// Memory scopes and semantics, and the 64-bit atomic load and store (valhall 12a.8.8.1, 12a.9).
//
// An atomic is the same instruction at every scope (all atomics are done at the shared L2, 12a.8.8.1), so the scope and the
// semantics become only what the dependency slots give: a release (release, acquire-release, sequentially consistent) waits for
// the slots of every earlier store and atomic before the atomic issues, an acquire waits for the atomic's own slot before anything
// that follows; a relaxed atomic is the atomic alone. The invocation scope orders nothing between invocations, so it needs none.
// A workgroup barrier is the sequence of 12a.9; an execution barrier at subgroup or invocation scope is no instruction (the lanes
// of a warp run in step; only the memory semantics' waits remain).

#if canImport(ShaderCompiler)
  import ShaderCompiler
#endif
#if canImport(ValhallISA)
  import ValhallISA
#endif

extension Selector {
  /// SPIR-V's MemorySemantics: Acquire 0x2, Release 0x4, AcquireRelease 0x8, SequentiallyConsistent 0x10.
  static func orderingOf(_ imm2: Int) -> (release: Bool, acquire: Bool) {
    let scope = imm2 >> 32
    let sem = imm2 & 0xFFFF_FFFF
    if scope == 4 { return (false, false) }
    return (sem & 0x1C != 0, sem & 0x1A != 0)
  }

  mutating func selectAtomicOrdered(_ i: Inst) throws(BackendError) {
    let (release, acquire) = Selector.orderingOf(i.imm2)
    if release { add(MInst(op("NOP"), .fence)) }
    if i.imm == AtomicKind.load || i.imm == AtomicKind.store {
      let t = i.imm == AtomicKind.load ? i.type : f.values[i.args[1]].type
      if t == .i64 {
        try selectAtomicLoadStore64(i)
        if acquire { add(MInst(op("NOP"), .fence)) }
        return
      }
    }
    try selectAtomic(i)
    if acquire { add(MInst(op("NOP"), .fence)) }
  }

  /// A naturally aligned 64-bit access is one `LOAD.i64` or `STORE.i64`, single-copy atomic like the 32-bit ones.
  mutating func selectAtomicLoadStore64(_ i: Inst) throws(BackendError) {
    let p = ptr(i.args[0])
    let (a, imm) = address(p, wide: true)
    if i.imm == AtomicKind.load {
      let d = def64(i)
      message("LOAD", "i64", address: a, offset: imm, write: d, memory: 1, named: [("access", accessFor(p))])
    } else {
      var d = opd64(i.args[1])
      if case .reg = d {} else { d = pairConstantRegs(i.args[1]) }
      message("STORE", "i64", address: a, offset: imm, read: d, memory: 2, named: [("access", accessFor(p))])
    }
  }
}
