// SPDX-License-Identifier: BSD-3-Clause

// Private variables of a module with one function become that function's own variables: an alloca each in the
// entry block, which promotion (Mem2Reg.swift) then turns into values. A private variable is the invocation's, as a
// function variable is, so with nothing else to see it the two are the same; without this a private variable stays in
// the thread's stack memory (a vertex shader's inputs, as the Vulkan lowering makes them, and a GLSL global).

extension IRModule {
  /// Make every private global an alloca of the one function. Returns whether anything changed; a module of more
  /// than one function is left as it is.
  @discardableResult
  public mutating func localizePrivateGlobals() -> Bool {
    guard functions.count == 1 else { return false }
    var f = functions[0]
    var replace = [ValueID](repeating: -1, count: f.values.count)
    var any = false
    var allocas: [Int] = []
    for v in 0..<f.values.count {
      guard case .global(let g) = f.values[v].kind, g < globals.count, globals[g].space == .private_ else { continue }
      let al = f.makeInst(Inst(.alloca, .ptr(.function), [], imm: max(globals[g].size, 1), imm2: max(globals[g].align, 1)))
      allocas.append(al)
      replace[v] = f.insts[al].result
      any = true
    }
    guard any else { return false }
    f.blocks[0].insts.insert(contentsOf: allocas, at: 0)
    for id in 0..<f.insts.count {
      for (k, a) in f.insts[id].args.enumerated() where a < replace.count && replace[a] >= 0 {
        f.insts[id].args[k] = replace[a]
      }
      // A pointer made from one of them (a ptradd, a phi or a select of them) is now a function pointer.
      if f.insts[id].type == .ptr(.private_) {
        f.insts[id].type = .ptr(.function)
        if f.insts[id].result >= 0 { f.values[f.insts[id].result].type = .ptr(.function) }
      }
    }
    functions[0] = f
    return true
  }
}
