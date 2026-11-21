// SPDX-License-Identifier: BSD-3-Clause

// Selection of texel buffer accesses (valhall 03 3.4.1, 3.5, 12a.5.2, 12a.7, 12b.14.1): the IR's `imgload`, `imgstore` and
// `imgaddr` with `ImgFlags.buffer`, and the size query's `descword`s (a buffer's size and stride are words 1 and 4 of its descriptor).
//
//  - The buffer is named by a resource handle, the binding's FAU word plus the element of the binding's array, as a storage
//    image is: the descriptor is a Buffer descriptor (type 9, buffer type 3) in the same table and index space as the textures
//    and storage images (03 3.4.1), and the FAU word is the heap handle of its element 0 (graphics/core/mali/lib/MaliDevice.swift
//    says where the heap puts them).
//  - An access starts with `LEA_BUF` (the element index, the handle): the 64-bit address of the element, two registers.
//  - The conversion word (a load or a store needs it) is word 7 of the descriptor, read by `LD_PKA.i32` through the
//    pseudo-table (62 << 24 | the handle's table) at byte offset 32 * index + 28; a word of zero is replaced by 0x5F0E7, the
//    constant format that reads every channel as zero (12b.12, 12b.14.1).
//  - A load is `LD_CVT` of the address and the conversion word, the register format of the shader's result type (`f32`, `u32` or
//    `s32`) and as many channels as the shader reads (four for a fetch of a samplerBuffer, whose format is only the descriptor's).
//    The channels a format lacks come from the pixel format word's component order (12b.14.1, inferred there and tested on the
//    board: loinnir-test's texel-buffer check), so a one-component format fetched as four reads (R, 0, 0, 1) without software.
//  - A store is `ST_CVT`, register format `auto32`, with every channel of the shader's texel (12b.14.1: not trimmed).
//  - `imgaddr` (an atomic's address) is the `LEA_BUF` result: the atomic is the global one (12b.14.1).
//  - The element index of a lane may differ from its neighbours' (only the binding's element is one value per warp).

#if canImport(MaliCore)
  import MaliCore
#endif
#if canImport(ShaderCompiler)
  import ShaderCompiler
#endif
#if canImport(ValhallISA)
  import ValhallISA
#endif

extension Selector {
  /// A store or an atomic may change what an earlier fetch of the same element read: later fetches are made again.
  mutating func forgetTexelFetches() {
    texGroups.removeAll { $0.block == cur && ImgFlags.isBuffer($0.imm) }
    // The store, or the atomic after the address, and the accesses before and after it to the same texel are in program order for one
    // invocation, which the messages do not give by themselves (the board: a store then an atomic add lost the add): everything in
    // flight completes before the next instruction.
    add(MInst(op("NOP"), .fence))
    texelWritten = true
  }

  /// `LEA_BUF`: the element's two address words, and the handle register of the access (for the conversion word).
  mutating func bufferAddress(_ i: Inst) -> (address: Int, handle: Opd) {
    if texelWritten { add(MInst(op("NOP"), .fence)) }
    let h = imageHandle(i)
    let index = copyToReg(opd(i.args[1]))
    let a = newReg(2)
    var mi = MInst(op("LEA_BUF"), .message)
    mi.src[0] = index
    mi.src[1] = h
    mi.stageWrite = .reg(a, 0)
    mi.memory = 1
    add(mi)
    return (a, h)
  }

  /// A texel buffer's conversion word: word 7 of its descriptor, 0x5F0E7 where that is zero (12b.12, 12b.14.1).
  mutating func texelConversionWord(handle h: Opd) -> Opd {
    let word = descriptorWord(handle: h, word: 7)
    let constant = materialize(0x5F0E7)
    let c = newReg()
    alu("CSEL", "u32", dst: .reg(c, 0), .reg(word, 0), .const(0), constant, .reg(word, 0), named: [("cmp", "eq")])
    return .reg(c, 0)
  }

  mutating func selectTexelBufferLoad(_ i: Inst) throws(BackendError) {
    for g in texGroups where g.block == cur && g.imm == i.imm && g.args == i.args && g.payload == i.payload {
      loc[i.result] = .part(g.reg, i.imm2)
      return
    }
    let channels = ImgFlags.channels(i.imm)
    let (a, h) = bufferAddress(i)
    let conversion = texelConversionWord(handle: h)
    let sw = newReg(channels)
    var inst = op("LD_CVT")
    inst.put("fmt", ["f32", "u32", "s32"][ImgFlags.kind(i.imm)])
    inst.put("vsz", vectorSizeName(channels))
    inst.put("offset", 0)
    var mi = MInst(inst, .message)
    mi.src[0] = .reg(a, 0)
    mi.src[2] = conversion
    mi.stageWrite = .reg(sw, 0)
    mi.memory = 1
    add(mi)
    texGroups.append(TexGroup(block: cur, args: i.args, imm: i.imm, payload: i.payload, reg: sw, mask: (1 << channels) - 1))
    loc[i.result] = .part(sw, i.imm2)
  }

  mutating func selectTexelBufferStore(_ i: Inst) throws(BackendError) {
    forgetTexelFetches()
    let channels = ImgFlags.channels(i.imm)
    let first = ImgFlags.addressCount(i.imm)
    let (a, h) = bufferAddress(i)
    let conversion = texelConversionWord(handle: h)
    let sr = newReg(channels)
    for k in 0..<channels { stage(i.args[first + k], into: .reg(sr, k)) }
    var inst = op("ST_CVT")
    inst.put("fmt", "auto32")
    inst.put("vsz", vectorSizeName(channels))
    inst.put("offset", 0)
    var mi = MInst(inst, .message)
    mi.src[0] = .reg(a, 0)
    mi.src[2] = conversion
    mi.stageRead = .reg(sr, 0)
    mi.memory = 2
    add(mi)
  }
}
