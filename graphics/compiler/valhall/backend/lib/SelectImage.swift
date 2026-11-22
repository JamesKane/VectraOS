// SPDX-License-Identifier: BSD-3-Clause

// Selection of storage image accesses (valhall 12b.10, 12b.11): the IR's `imgload`, `imgstore` and `imgaddr`.
//
//  - An access names its image by the handle `I`, a 32-bit resource handle (12b.10.2): the binding's FAU word (the heap
//    handle of element 0, the same word a texture binding has, graphics/mali/lib/GraphicsShader.swift and
//    FauLayout.imageBindings) plus the element index, computed at run time. The handle is one value per warp
//    (12b.2.1), which Prep.uniformTextureHandles makes it.
//  - The coordinates are two words of 16-bit halves (12b.10.1): X holds x (low) and y (high), Z holds z (low) and the
//    array layer (high). Coordinates are 32 bits in the IR: the high halves of x and y are ORed into the first free
//    coordinate (z for a 2D image, y for a 1D one), where any bit set is out of bounds (12b.10.1, the policy), so an
//    out-of-range or negative coordinate is out of bounds. A layer past 16 bits wraps.
//  - `imgload`: one `LD_TEX` of all the format's channels, in the explicit register format of the shader's result type
//    (`f32`, `u32` or `s32`, 12b.10.5: never `auto32` for a load). The channels are 32-bit registers of one block, read
//    by position like the channels of a texture access.
//  - `imgstore`: `LEA_TEX` (three registers: the address's two words and the conversion word) then `ST_CVT` with that
//    address and conversion word and the channels in a staging block, register format `auto32` (12b.10.4).
//  - `descword`: `LD_PKA` of a word of the image's descriptor (12b.13.5), for the image queries.
//  - `imgaddr`: the same `LEA_TEX`, and the address is the pointer (12b.11): an atomic on it is a global atomic.

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
  /// The coordinate sources X and Z of an access from its IR arguments (the index first).
  mutating func imageCoordinates(_ i: Inst) -> (x: Opd, z: Opd) {
    let dims = ImgFlags.dims(i.imm)
    let arrayed = ImgFlags.isArrayed(i.imm)
    let cx = opd(i.args[1])
    let layer: Opd? = arrayed ? opd(i.args[1 + dims]) : nil
    let x = newReg()
    let z = newReg()
    if dims == 1 {
      // The whole of x is the S half and the T half: the high half is the overflow.
      alu("MOV", "i32", dst: .reg(x, 0), cx)
      if let l = layer, let (amt, lane) = shiftAmount(16) {
        alu("LSHIFT_OR", "i32", dst: .reg(z, 0), l, amt, .const(0), set: [("wd1", lane)])
      } else {
        alu("MOV", "i32", dst: .reg(z, 0), .const(0))
      }
      return (.reg(x, 0), .reg(z, 0))
    }
    let cy = opd(i.args[2])
    let lowX = newReg()
    alu("AND_IMM", "i32", dst: .reg(lowX, 0), cx, set: [("imm", 0xFFFF)])
    if let (amt, lane) = shiftAmount(16) {
      alu("LSHIFT_OR", "i32", dst: .reg(x, 0), cy, amt, .reg(lowX, 0), set: [("wd1", lane)])
      let both = newReg()
      logic32("LSHIFT_OR", .reg(both, 0), cx, cy)
      if let l = layer {
        let hi = newReg()
        alu("RSHIFT_OR", "i32", dst: .reg(hi, 0), .reg(both, 0), amt, .const(0), set: [("wd1", lane)])
        alu("LSHIFT_OR", "i32", dst: .reg(z, 0), l, amt, .reg(hi, 0), set: [("wd1", lane)])
      } else {
        alu("RSHIFT_OR", "i32", dst: .reg(z, 0), .reg(both, 0), amt, .const(0), set: [("wd1", lane)])
      }
    }
    return (.reg(x, 0), .reg(z, 0))
  }

  /// The handle register of an access.
  mutating func imageHandle(_ i: Inst) -> Opd {
    let h = newReg()
    heapHandle(into: .reg(h, 0), key: i.payload[0], index: i.args[0])
    return .reg(h, 0)
  }

  func vectorSizeName(_ channels: Int) -> String { ["scalar", "v2", "v3", "v4"][channels - 1] }

  mutating func checkImageStage(_ what: String) throws(BackendError) {
    guard !isVertex else { throw BackendError.unsupported(what + " in a vertex shader") }
  }

  mutating func selectImageLoad(_ i: Inst) throws(BackendError) {
    try checkImageStage("a storage image access")
    if ImgFlags.isBuffer(i.imm) { return try selectTexelBufferLoad(i) }
    for g in texGroups where g.block == cur && g.imm == i.imm && g.args == i.args && g.payload == i.payload {
      loc[i.result] = .part(g.reg, i.imm2)
      return
    }
    let channels = ImgFlags.channels(i.imm)
    let h = imageHandle(i)
    let (x, z) = imageCoordinates(i)
    let sw = newReg(channels)
    var inst = op("LD_TEX")
    // The register format is the shader's result type (12b.10.5): f32 for float and normalised images, s32 signed, u32 unsigned.
    inst.put("fmt", ["f32", "u32", "s32"][ImgFlags.kind(i.imm)])
    inst.put("vsz", vectorSizeName(channels))
    var mi = MInst(inst, .message)
    mi.src[0] = x
    mi.src[1] = z
    mi.src[2] = h
    mi.stageWrite = .reg(sw, 0)
    mi.memory = 1
    add(mi)
    texGroups.append(TexGroup(block: cur, args: i.args, imm: i.imm, payload: i.payload, reg: sw, mask: (1 << channels) - 1))
    loc[i.result] = .part(sw, i.imm2)
  }

  /// `LEA_TEX`: the block of the address's two words and the conversion word.
  mutating func imageAddress(_ i: Inst) -> Int {
    let h = imageHandle(i)
    let (x, z) = imageCoordinates(i)
    let a = newReg(3)
    var mi = MInst(op("LEA_TEX"), .message)
    mi.src[0] = x
    mi.src[1] = z
    mi.src[2] = h
    mi.stageWrite = .reg(a, 0)
    mi.memory = 1
    add(mi)
    return a
  }

  mutating func selectImageStore(_ i: Inst) throws(BackendError) {
    try checkImageStage("a storage image access")
    if ImgFlags.isBuffer(i.imm) { return try selectTexelBufferStore(i) }
    let channels = ImgFlags.channels(i.imm)
    let first = ImgFlags.addressCount(i.imm)
    let a = imageAddress(i)
    let sr = newReg(channels)
    for k in 0..<channels { stage(i.args[first + k], into: .reg(sr, k)) }
    var inst = op("ST_CVT")
    inst.put("fmt", "auto32")
    inst.put("vsz", vectorSizeName(channels))
    inst.put("offset", 0)
    var mi = MInst(inst, .message)
    mi.src[0] = .reg(a, 0)
    mi.src[2] = .reg(a, 2)
    mi.stageRead = .reg(sr, 0)
    mi.memory = 2
    add(mi)
  }

  /// `descword`: a word of the image's descriptor through `LD_PKA` (12b.13.5): the pseudo-table handle is the image
  /// handle's table with 62 in the high bits, the offset is 32 times the index plus 4 times the word.
  mutating func selectDescWord(_ i: Inst) throws(BackendError) {
    try checkImageStage("an image query")
    let h = imageHandle(i)
    loc[i.result] = .reg(descriptorWord(handle: h, word: i.imm))
  }

  /// Word `word` of the descriptor the handle names, read by `LD_PKA` through the pseudo-table (3.2.3, 12b.13.5).
  mutating func descriptorWord(handle h: Opd, word: Int) -> Int {
    let k = materialize(0x3E00_0000)
    let p = newReg()
    guard let (amt24, lane24) = shiftAmount(24), let (amt5, lane5) = shiftAmount(5) else { return 0 }
    alu("RSHIFT_OR", "i32", dst: .reg(p, 0), h, amt24, k, set: [("wd1", lane24)])
    let index = newReg()
    alu("AND_IMM", "i32", dst: .reg(index, 0), h, set: [("imm", 0xFF_FFFF)])
    var offset = newReg()
    alu("LSHIFT_OR", "i32", dst: .reg(offset, 0), .reg(index, 0), amt5, .const(0), set: [("wd1", lane5)])
    if word != 0 {
      let moved = newReg()
      alu("IADD_IMM", "i32", dst: .reg(moved, 0), .reg(offset, 0), set: [("imm", 4 * word)])
      offset = moved
    }
    let d = newReg()
    var mi = MInst(op("LD_PKA", "i32"), .message)
    mi.src[0] = .reg(offset, 0)
    mi.src[1] = .reg(p, 0)
    mi.stageWrite = .reg(d, 0)
    mi.memory = 1
    add(mi)
    return d
  }

  mutating func selectImageAddress(_ i: Inst) throws(BackendError) {
    try checkImageStage("a storage image access")
    guard Prep.isUniform(f, i.args[0]) else {
      throw BackendError.unsupported("an atomic on a storage image chosen by a value that differs between lanes")
    }
    if ImgFlags.isBuffer(i.imm) { forgetTexelFetches() }
    let a = ImgFlags.isBuffer(i.imm) ? bufferAddress(i).address : imageAddress(i)
    let p = newReg(2)
    alu("MOV", "i32", dst: .reg(p, 0), .reg(a, 0))
    alu("MOV", "i32", dst: .reg(p, 1), .reg(a, 1))
    loc[i.result] = .reg(p)
  }
}
