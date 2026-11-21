// SPDX-License-Identifier: BSD-3-Clause

// Host only: ValhallISA's instructions into ValhallInterp's (the adapter
// point of interp/lib/Adapter.swift), and a runner that dispatches what the
// backend compiled over the interpreter, with the FAU block built from the
// shader's own layout. Nothing here goes on the device (D4).

import MaliCore
import ValhallBackend
import ValhallISA
import ValhallInterp

public struct BridgeError: Error, CustomStringConvertible {
  public var description: String
}

extension ValhallISA.Instruction: InstrConvertible {
  public func interpInstr() throws -> Instr {
    let m = mnemonic
    let v = variant
    func isShift(_ s: String) -> (UInt8, UInt8)? {
      let parts = ["RSHIFT_", "LSHIFT_", "RROT_", "LROT_", "ARSHIFT_"]
      for (n, p) in parts.enumerated() where s.hasPrefix(p) {
        let c = String(s.dropFirst(p.count))
        let k: UInt8 = c == "AND" ? 0 : c == "OR" ? 1 : 2
        return (UInt8(n), k)
      }
      return nil
    }
    var op: Opcode
    var combine: UInt8 = 0
    var shiftOp: UInt8 = 0
    switch m {
    case "FADD", "F32_TO_F16": op = .fadd
    case "FADD_IMM": op = .faddImm
    case "FADD_LSCALE": op = .faddLscale
    case "FMA": op = .fma
    case "FMA_RSCALE": op = .fmaRscale
    case "FMIN": op = .fmin
    case "FMAX": op = .fmax
    case "FCMP_OR": op = .fcmp
    case "FCMP_AND":
      op = .fcmp
      combine = 1
    case "CSEL": op = .csel
    case "FLUSH": op = .flush
    case "FROUND": op = .fround
    case "LDEXP": op = .ldexp
    case "IADD": op = .iadd
    case "ISUB": op = .isub
    case "IMUL": op = .imul
    case "IADD_IMM": op = .iaddImm
    case "AND_IMM": op = .andImm
    case "OR_IMM": op = .orImm
    case "XOR_IMM": op = .xorImm
    case "ICMP_OR": op = .icmp
    case "ICMP_AND":
      op = .icmp
      combine = 1
    case "ICMP_MULTI": op = .icmpMulti
    case "MUX": op = .mux
    case "MOV": op = .mov
    case "IABS": op = .iabs
    case "CLZ": op = .clz
    case "POPCOUNT": op = .popcount
    case "BITREV": op = .bitrev
    case "SHADD": op = .shadd
    case "S8_TO_S32": op = .s8ToS32
    case "U8_TO_U32": op = .u8ToU32
    case "S16_TO_S32": op = .s16ToS32
    case "U16_TO_U32": op = .u16ToU32
    case "S32_TO_F32": op = .s32ToF32
    case "U32_TO_F32": op = .u32ToF32
    case "F32_TO_S32": op = .f32ToS32
    case "F32_TO_U32": op = .f32ToU32
    case "F16_TO_F32": op = .f16ToF32
    case "FRCP": op = .frcp
    case "FRSQ": op = .frsq
    case "FLOGD": op = .flogd
    case "FEXP": op = .fexp
    case "FREXPM": op = .frexpm
    case "FREXPE": op = .frexpe
    case "FSIN_TABLE": op = .fsinTable
    case "FCOS_TABLE": op = .fcosTable
    case "LOAD": op = .load
    case "STORE": op = .store
    case "LEA_BUF_IMM": op = .leaBufImm
    case "DISCARD": op = .discard
    case "ATOM": op = .atom
    case "ATOM1": op = .atom1
    case "ATOM1_RETURN": op = .atom1Return
    case "ATOM_RETURN": op = .atomReturn
    case "ACMPXCHG": op = .acmpxchg
    case "BRANCH": op = .branch
    case "NOP": op = .nop
    case "BARRIER": op = .barrier
    case "WMASK": op = .wmask
    case "CLPER": op = .clper
    case "TEX_FETCH": op = .texFetch
    case "LD_TEX": op = .ldTex
    case "LEA_TEX": op = .leaTex
    case "ST_CVT": op = .stCvt
    case "LD_PKA": op = .ldPka
    default:
      if let (s, c) = isShift(m) {
        op = .shift
        shiftOp = s
        combine = c
      } else {
        throw BridgeError(description: "the interpreter does not run " + m)
      }
    }
    var dt: DataType
    switch v {
    case "f32": dt = .f32
    case "" where m == "F32_TO_F16": dt = .f32
    case "v2f16": dt = .v2f16
    case "f16": dt = .f16
    case "u32", "i32": dt = .u32
    case "s32": dt = .s32
    case "u64", "i64": dt = .u64
    case "s64": dt = .s64
    case "v2u16", "v2i16": dt = .v2u16
    case "v2s16": dt = .v2s16
    default: dt = .u32
    }
    if m == "FRCP" || m == "FRSQ" { dt = v == "f16" ? .f16 : .f32 }
    if m == "FLOGD" || m == "FEXP" || m == "FREXPM" || m == "FREXPE" { dt = .f32 }
    var i = Instr(op, dt)
    i.flow = ValhallInterp.Flow(rawValue: flow.rawValue) ?? .none
    i.fauPage = UInt8(fauPage)
    func byte(_ n: Int) -> UInt8 { source(n)?.byte ?? 0xC0 }
    i.s0 = byte(0)
    i.s1 = byte(1)
    i.s2 = byte(2)
    i.s3 = byte(3)
    // Message instructions carry their staging register where the interpreter keeps `dst`.
    let d = def
    let sr = d.fieldIndex(role: .stagingRegister)
    if sr >= 0 {
      i.dst = UInt8(values[sr])
    } else if let r = destination {
      i.dst = UInt8(r)
    }
    let swr = d.fieldIndex(role: .stagingWriteRegister)
    if swr >= 0 { i.writeReg = UInt8(values[swr]) }
    i.dstWidth = UInt8(destinationWidth)
    for n in 0..<3 {
      guard let o = operand(n) else { continue }
      if d.fieldIndex(role: .lane(n)) >= 0 {
        switch n {
        case 0: i.widen0 = UInt8(o.lane)
        case 1: i.widen1 = UInt8(o.lane)
        default: i.widen2 = UInt8(o.lane)
        }
      }
      if o.negate { i.neg |= 1 << UInt8(n) }
      if o.absolute { i.abs |= 1 << UInt8(n) }
      if n == 2 && o.complement { i.notSrc2 = true }
    }
    func val(_ name: String) -> UInt8? { value(name).map { UInt8(truncatingIfNeeded: $0) } }
    if let x = val("round") { i.round = x }
    if let x = val("clamp") { i.clamp = x }
    if let x = val("saturate") { i.saturate = x != 0 }
    if let x = val("nan") { i.sem = x }
    if let x = val("cmp") { i.cmp = x }
    if let x = val("rtype") { i.resultType = x }
    if let x = val("not_result") { i.notResult = x != 0 }
    if op == .branch {
      i.not = (val("not") ?? 0) != 0
      i.combine = val("wd0") ?? 0
      i.offset = Int32(truncatingIfNeeded: Int64(bitPattern: value("offset") ?? 0))
    } else if op == .shift {
      i.shiftOp = shiftOp
      i.combine = combine
    } else {
      i.combine = combine
      if let x = val("not") { i.not = x != 0 }
    }
    if op == .fmaRscale, let x = val("special") { i.special = x }
    if op == .mux, let x = val("cond") { i.special = x }
    if (op == .frexpm || op == .frexpe), let x = val("mode") { i.special = x }
    if op == .frexpe, let x = val("neg_result") { i.negResult = x != 0 }
    if let x = value("imm") { i.imm = UInt32(truncatingIfNeeded: x) }
    if let x = val("shift") { i.shiftAmount = x }
    if op == .ldPka {
      i.slot = val("slot") ?? 0
      i.memWidth = 3
      if v != "i32" { throw BridgeError(description: "the interpreter models LD_PKA.i32 only") }
    }
    if op == .load || op == .store || op == .atom || op == .atom1 || op == .atom1Return || op == .atomReturn
      || op == .acmpxchg
    {
      switch v {
      case "i8": i.memWidth = 0
      case "i16": i.memWidth = 1
      case "i24": i.memWidth = 2
      case "i32": i.memWidth = 3
      case "i48": i.memWidth = 4
      case "i64": i.memWidth = 5
      case "i96": i.memWidth = 6
      default: i.memWidth = 7
      }
      if let x = value("offset") {
        if op == .load || op == .store {
          i.offset = Int32(truncatingIfNeeded: Int64(bitPattern: x))
        } else {
          i.offset = Int32(x)
        }
      }
      if let x = val("lane") { i.lane = x }
      if let x = val("ext") { i.zeroExtend = x != 0 }
      if let x = val("access") { i.access = x }
      if let x = val("slot") { i.slot = x }
      if let x = val("op") { i.atomOp = x }
    }
    if op == .barrier { i.slot = 7 }
    if op == .wmask || op == .clper {
      i.subgroup = val("subgroup") ?? 3
      if op == .clper {
        i.laneOp = val("lane_op") ?? 0
        i.inactive = val("inactive") ?? 0
        i.widen1 = val("wd1") ?? 4
      }
    }
    if op == .texFetch {
      i.slot = val("slot") ?? 0
      i.imm = UInt32(value("mask") ?? 15)
    }
    if op == .ldTex || op == .leaTex || op == .stCvt {
      // The channels of the staging block (the vector size plus one; the 16-bit register formats are not modelled).
      i.slot = val("slot") ?? 0
      i.access = val("access") ?? 0
      i.offset = Int32(value("offset") ?? 0)
      i.imm = UInt32((value("vsz") ?? 0) + 1)
      let fmt = value("fmt") ?? 0
      if fmt == 1 || fmt == 3 || fmt == 5 || fmt == 7 {
        throw BridgeError(description: "the interpreter models the 32-bit register formats only")
      }
    }
    if op == .leaBufImm {
      i.imm = UInt32(value("index") ?? 0)
      i.slot = val("slot") ?? 0
    }
    if op == .f32ToS32 || op == .f32ToU32 || op == .s32ToF32 || op == .u32ToF32, let x = val("round") { i.round = x }
    if op == .s16ToS32 || op == .u16ToU32 || op == .s8ToS32 || op == .u8ToU32, let x = val("wd0") { i.widen0 = x }
    return i
  }
}

/// A buffer of a dispatch.
public struct Buffer {
  public var set: Int
  public var binding: Int
  public var bytes: [UInt8]
  public init(set: Int = 0, binding: Int, bytes: [UInt8]) {
    self.set = set
    self.binding = binding
    self.bytes = bytes
  }
}

/// The storage images of a binding (set and binding), one an element of the binding's array: each element's texels, and
/// what the model needs to address them. The heap handle of element `j` of the binding is `handle(of:)` plus `j`.
public struct HostImage {
  public struct Element {
    public var bytes: [UInt8]
    public var width: Int
    public var height: Int
    public var layers: Int
    public var format: StorageFormat
    public init(bytes: [UInt8], width: Int, height: Int = 1, layers: Int = 1, format: StorageFormat) {
      self.bytes = bytes
      self.width = width
      self.height = height
      self.layers = layers
      self.format = format
    }
  }
  public var set: Int
  public var binding: Int
  public var elements: [Element]
  public init(set: Int = 0, binding: Int, elements: [Element]) {
    self.set = set
    self.binding = binding
    self.elements = elements
  }
  public init(set: Int = 0, binding: Int, _ element: Element) { self.init(set: set, binding: binding, elements: [element]) }

  /// The handle of element 0 of the binding the run gives its `n`th image binding (any value will do: the model maps it).
  public static func handle(ofBinding n: Int) -> UInt32 { 0x0100_0000 + UInt32(n) * 0x100 }
}

public enum HostRun {
  /// Run a compiled shader over the interpreter; returns each buffer's bytes after the dispatch.
  public static func dispatch(
    _ cs: CompiledShader, buffers: [Buffer], push: [UInt32] = [], grid: (UInt32, UInt32, UInt32), strictLastUse: Bool = true,
    wmaskLaunched: Bool = false
  ) throws -> [Buffer] {
    try dispatch(cs, buffers: buffers, images: [], push: push, grid: grid, strictLastUse: strictLastUse, wmaskLaunched: wmaskLaunched).buffers
  }

  /// Run a compiled shader over buffers and storage images (as the Mali heap's binding 2 holds them): the images'
  /// element `j` of the `n`th binding the shader names has the handle `HostImage.handle(ofBinding: n) + j`, which is what
  /// the FAU word of the binding holds (`FauLayout.imageBindings`). Returns the buffers and images after the run.
  public static func dispatch(
    _ cs: CompiledShader, buffers: [Buffer], images: [HostImage], push: [UInt32] = [], grid: (UInt32, UInt32, UInt32),
    strictLastUse: Bool = true,
    wmaskLaunched: Bool = false
  ) throws -> (buffers: [Buffer], images: [HostImage]) {
    let mem = GpuMemory()
    var models: [UInt32: StorageImageModel] = [:]
    var imageBase: [(Int, Int, Int, UInt64)] = []
    var imageAt: UInt64 = 0x6000_0000
    for (n, img) in images.enumerated() {
      for (j, e) in img.elements.enumerated() {
        mem.map(imageAt, size: max(e.bytes.count, 16) + 64)
        mem.write(imageAt, bytes: e.bytes)
        models[HostImage.handle(ofBinding: n) + UInt32(j)] = StorageImageModel(
          base: imageAt, width: e.width, height: e.height, layers: e.layers, format: e.format)
        imageBase.append((n, j, e.bytes.count, imageAt))
        imageAt += UInt64((e.bytes.count + 4096 + 4095) / 4096 * 4096)
      }
    }
    var addr: [(Int, UInt64)] = []
    var next: UInt64 = 0x1000_0000
    for b in buffers {
      mem.map(next, size: max(b.bytes.count, 16) + 64)
      mem.write(next, bytes: b.bytes)
      addr.append((b.set << 16 | b.binding, next))
      next += UInt64((b.bytes.count + 4096 + 4095) / 4096 * 4096)
    }
    func lookup(_ s: Int, _ b: Int) -> UInt64 {
      for (k, a) in addr where k == s << 16 | b { return a }
      return 0
    }
    func size(_ s: Int, _ b: Int) -> UInt32 {
      for x in buffers where x.set == s && x.binding == b { return UInt32(x.bytes.count) }
      return 0
    }
    let block = cs.layout.block(
      address: lookup, size: size, push: push, workgroups: grid,
      imageHandle: { s, b in
        for (n, img) in images.enumerated() where img.set == s && img.binding == b { return HostImage.handle(ofBinding: n) }
        return 0
      })
    var fau: [UInt32] = []
    for w in block {
      fau.append(UInt32(truncatingIfNeeded: w))
      fau.append(UInt32(truncatingIfNeeded: w >> 32))
    }
    var code: [Instr] = []
    for i in cs.instructions { code.append(try i.interpInstr()) }
    let ws = cs.shader.workgroupSize
    var cfg = DispatchConfig(
      workgroupSize: ValhallInterp.Dim3(ws.x, ws.y, ws.z), grid: ValhallInterp.Dim3(grid.0, grid.1, grid.2), fau: fau,
      sharedBytes: Int(cs.shader.workgroupMemoryBytes), threadLocalBytes: Int(cs.shader.stackBytes))
    cfg.strictLastUse = strictLastUse
    cfg.wmaskLaunched = wmaskLaunched
    cfg.flushDenormals = cs.shader.flushToZeroMode != 0
    let imageModels = models
    cfg.storageImage = { imageModels[$0] }
    // The descriptors the images' handles name, as 12b.13 reads them: word 0's low half non-zero (not null), the size
    // minus one in words 1, 6 and 7, levels minus one in bits 20:16 of word 2, log2 of the samples in bits 15:13 of word 3.
    cfg.descriptorWord = { table, offset in
      let index = offset / 32
      guard let m = imageModels[table << 24 | index] else { return 0 }
      switch (offset % 32) / 4 {
      case 0: return 1
      case 1: return UInt32(m.width - 1) | UInt32(m.height - 1) << 16
      case 6: return UInt32(m.layers - 1)
      default: return 0
      }
    }
    _ = try runDispatch(Shader(code), cfg, memory: mem)
    var out: [Buffer] = []
    for b in buffers {
      var r = b
      r.bytes = mem.read(lookup(b.set, b.binding), count: b.bytes.count)
      out.append(r)
    }
    var outImages = images
    for (n, j, count, at) in imageBase { outImages[n].elements[j].bytes = mem.read(at, count: count) }
    return (out, outImages)
  }
}

/// What a vertex shader stored: the position record and the generic varyings block of each of the first 16 vertices
/// (the lanes of one warp), as 32-bit words.
public struct VertexResult {
  public var positions: [[UInt32]]
  public var varyings: [[UInt32]]
}

extension HostRun {
  /// Run a vertex shader's instructions over one warp of vertices (the lanes' vertex ids are 0 to 15, the instance
  /// 0) on the interpreter, both IDVS passes: the position pass with `shader_output` 1 and the varying pass with 4.
  /// `memory` is mapped first (the root pointer's buffers: 16 vertices' worth, since the warp's lanes all run);
  /// `fau` is the vertex FAU block as 32-bit words. The interpreter models the hardware vertex-output buffers as
  /// 16-byte position records and `varyingBytes`-byte generic blocks, one a vertex (a test model: the unit of
  /// `LEA_BUF_IMM`'s element is the spec's open question, 12c.4.1).
  public static func vertex(
    instructions: [Instruction], fau: [UInt32], varyingBytes: Int, memory: [(address: UInt64, bytes: [UInt8])]
  ) throws -> VertexResult {
    var code: [Instr] = []
    for i in instructions { code.append(try i.interpInstr()) }
    let positionBase: UInt64 = 0x5000_0000
    let varyingBase: UInt64 = 0x6000_0000
    let stride = max(varyingBytes, 16)
    var positions = [[UInt32]](repeating: [], count: 16)
    var varyings = [[UInt32]](repeating: [], count: 16)
    var shaderOutputs: [UInt32] = [1, 4]
    if varyingBytes == 0 { shaderOutputs = [1] }
    let mem = GpuMemory()
    for m in memory {
      mem.map(m.address, size: max(m.bytes.count, 16) + 64)
      mem.write(m.address, bytes: m.bytes)
    }
    mem.map(positionBase, size: 16 * 16 + 64)
    mem.map(varyingBase, size: 16 * stride + 64)
    for out in shaderOutputs {
      var cfg = DispatchConfig(workgroupSize: ValhallInterp.Dim3(16), grid: ValhallInterp.Dim3(1), fau: fau)
      cfg.shaderOutput = out
      cfg.hardwareBuffers = [(positionBase, 16), (varyingBase, UInt64(stride))]
      cfg.registerInit = { inv, regs in
        regs[59] = UInt32(inv)
        regs[60] = UInt32(inv)
        regs[61] = 0
      }
      _ = try runDispatch(Shader(code), cfg, memory: mem)
    }
    func words(_ base: UInt64, _ n: Int) -> [UInt32] {
      let b = mem.read(base, count: n * 4)
      var out: [UInt32] = []
      var k = 0
      while k + 3 < b.count {
        out.append(UInt32(b[k]) | UInt32(b[k + 1]) << 8 | UInt32(b[k + 2]) << 16 | UInt32(b[k + 3]) << 24)
        k += 4
      }
      return out
    }
    for v in 0..<16 {
      positions[v] = words(positionBase + UInt64(16 * v), 4)
      if varyingBytes > 0 { varyings[v] = words(varyingBase + UInt64(stride * v), varyingBytes / 4) }
    }
    return VertexResult(positions: positions, varyings: varyings)
  }
}
