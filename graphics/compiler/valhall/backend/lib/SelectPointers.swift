// SPDX-License-Identifier: BSD-3-Clause

// Pointers and integers: a global pointer is a 64-bit value in a register pair, so converting between it and an
// integer is a move at most.

#if canImport(ShaderCompiler)
  import ShaderCompiler
#endif

extension Selector {
  /// `ptrtoint`: the integer is the pair that holds the pointer; a pointer that has been moved by constant or
  /// run-time offsets (or is a buffer's address in the FAU) is added up into a new pair.
  mutating func selectPtrToInt(_ i: Inst) throws(BackendError) {
    let p = ptr(i.args[0])
    switch p.base {
    case .reg, .binding: break
    default: throw BackendError.unsupported("ptrtoint of a local pointer")
    }
    if case .reg(let r) = p.base, p.offset == 0, p.dyn < 0, mf.vregs[r].size == 2 {
      loc[i.result] = .reg(r)
      return
    }
    let (base, imm) = address(p, wide: true)
    let d = def64(i)
    alu("IADD", "u64", dst: d, base, imm == 0 ? .const(0) : pairConstant(UInt64(bitPattern: Int64(imm))))
  }

  /// `inttoptr`: the pair that holds the integer is the pointer.
  mutating func selectIntToPtr(_ i: Inst) throws(BackendError) {
    switch loc[i.args[0]] {
    case .reg(let r): loc[i.result] = .ptr(PtrVal(base: .reg(r), offset: 0))
    case .const(let bits):
      guard case .reg(let r, _) = pairConstant(bits) else { return }
      loc[i.result] = .ptr(PtrVal(base: .reg(r), offset: 0))
    default: throw BackendError.unsupported("inttoptr of a value that isn't in registers")
    }
  }
}
