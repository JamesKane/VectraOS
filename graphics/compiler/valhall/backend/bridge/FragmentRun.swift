// SPDX-License-Identifier: BSD-3-Clause

// Host only: a compiled fragment shader over one warp of the interpreter, with what the hardware gives it (14.4):
// four quads of fragments on a 2 by 2 pixel grid each, their coverage and facing, the varyings, the special varyings, the
// textures and the samplers, and what comes out of BLEND and ZS_EMIT. The tests' reference for a fragment shader is
// a CPU function of the same inputs.
//
// Lane `l` of quad `q` is the pixel (x0 + 2 (q % 2) + l % 2, y0 + 2 (q / 2) + l / 2): bit 0 of the lane within the quad
// selects the column, bit 1 the row (13.10.1). A lane with no coverage is a helper lane (14.4.2): discarded from its
// first instruction (13.6.4), it supplies its quad's derivatives.

import MaliCore
import ValhallBackend
import ValhallISA
import ValhallInterp

public struct FragmentInput: Sendable {
  public var origin: (x: Int, y: Int) = (0, 0)
  /// By lane: the rasteriser's coverage (16 bits). Zero makes the lane a helper.
  public var coverage = [UInt16](repeating: 0xFFFF, count: 16)
  /// By lane: the primitive's facing (back facing is flag bit 0 of r58, 14.4.1).
  public var backFacing = [Bool](repeating: false, count: 16)
  public var primitiveId: UInt32 = 0
  public var sampleId: UInt32 = 0
  public var layer: UInt32 = 0
  /// The interpolated value of the varying at a location, at the window position (x, y) (a fragment's centre is the
  /// pixel plus a half), as floats; flat varyings come from `flat`.
  public var varying: @Sendable (_ location: Int, _ x: Float, _ y: Float) -> [Float] = { _, _, _ in [0, 0, 0, 0] }
  public var flat: @Sendable (_ location: Int, _ lane: Int) -> [UInt32] = { _, _ in [0, 0, 0, 0] }
  /// The special varyings at (x, y): `frag_z`, `frag_w` and the point coordinate.
  public var fragZ: @Sendable (_ x: Float, _ y: Float) -> Float = { _, _ in 0.5 }
  public var fragW: @Sendable (_ x: Float, _ y: Float) -> Float = { _, _ in 1 }
  public var pointCoord: @Sendable (_ x: Float, _ y: Float) -> [Float] = { _, _ in [0, 0] }
  /// The sample position table (14.7.2): 8.8 fixed-point x and y, by sample id, within the pixel.
  public var samplePositions: [(x: UInt16, y: UInt16)] = [(128, 128), (64, 192), (192, 64), (64, 64), (192, 192)]
  /// The centroid position within the pixel, for a centroid-interpolated varying.
  public var centroid: (x: Float, y: Float) = (0.5, 0.5)
  public init() {}

  /// The pixel of a lane.
  public func pixel(_ lane: Int) -> (x: Int, y: Int) {
    let q = lane / 4
    return (origin.x + 2 * (q % 2) + lane % 2, origin.y + 2 * (q / 2) + (lane / 2) % 2)
  }
}

public struct FragmentResult {
  /// By lane and render target, the colour words BLEND received (absent when the lane wrote nothing).
  public var colours: [[Int: [UInt32]]]
  public var depth: [UInt32?]
  public var stencil: [UInt32?]
  public var coverage: [UInt32]
  public var instructions: Int
}

extension HostRun {
  /// Run a compiled fragment shader over one warp. `bindings` give the heap handle of each image or sampler binding the
  /// shader names (`GraphicsFauLayout.imageBindings`: element 0's handle; element `j` is the handle plus `j`);
  /// `textures` and `samplers` are the models those handles name.
  public static func fragment(
    _ cs: CompiledGraphicsShader, input: FragmentInput, push: [UInt32] = [], bindings: [(set: Int, binding: Int, handle: UInt32)] = [],
    dummySampler: UInt32 = 0, textures: [UInt32: TextureModel] = [:], samplers: [UInt32: SamplerModel] = [:], strictLastUse: Bool = true
  ) throws -> FragmentResult {
    guard let fs = cs.fragment else { throw BridgeError(description: "not a fragment shader") }
    var code: [Instr] = []
    for i in cs.instructions { code.append(try i.interpInstr()) }
    let block = fs.layout.block(push: push, images: bindings, dummySampler: dummySampler)
    var fau: [UInt32] = []
    for w in block {
      fau.append(UInt32(truncatingIfNeeded: w))
      fau.append(UInt32(truncatingIfNeeded: w >> 32))
    }
    let mem = GpuMemory()
    let tableAt: UInt64 = 0x7800_0000
    mem.map(tableAt, size: 4096)
    var table: [UInt8] = []
    for p in input.samplePositions {
      table += [UInt8(p.x & 0xFF), UInt8(p.x >> 8), UInt8(p.y & 0xFF), UInt8(p.y >> 8)]
    }
    mem.write(tableAt, bytes: table)
    var cfg = DispatchConfig(workgroupSize: ValhallInterp.Dim3(16), grid: ValhallInterp.Dim3(1), fau: fau)
    cfg.strictLastUse = strictLastUse
    cfg.samplePositionTable = tableAt
    var helpers: UInt16 = 0
    for l in 0..<16 where input.coverage[l] == 0 { helpers |= 1 << UInt16(l) }
    cfg.helperMask = helpers
    let tex = textures
    let smp = samplers
    cfg.textures = { tex[$0] }
    cfg.samplers = { smp[$0] }
    cfg.descriptorWord = { table, offset in
      let handle = table << 24 | offset / 32
      let word = Int(offset % 32) / 4
      if let t = tex[handle] { return t.descriptorWord(word) }
      if let s = smp[handle] { return s.words[word] }
      return 0
    }
    let inp = input
    let model = FragmentModel(
      varying: { lane, offset, count, position in
        let p = inp.pixel(lane)
        var fx = Float(p.x) + 0.5
        var fy = Float(p.y) + 0.5
        if position == 1 {
          fx = Float(p.x) + inp.centroid.x
          fy = Float(p.y) + inp.centroid.y
        } else if position == 2, Int(inp.sampleId) < inp.samplePositions.count {
          fx = Float(p.x) + Float(inp.samplePositions[Int(inp.sampleId)].x) / 256
          fy = Float(p.y) + Float(inp.samplePositions[Int(inp.sampleId)].y) / 256
        }
        let v = inp.varying(offset / 16, fx, fy)
        return (0..<count).map { ($0 < v.count ? v[$0] : 0).bitPattern }
      },
      flat: { lane, offset, count in
        let v = inp.flat(offset / 16, lane)
        return (0..<count).map { $0 < v.count ? v[$0] : 0 }
      },
      special: { lane, name, _ in
        let p = inp.pixel(lane)
        let fx = Float(p.x) + 0.5, fy = Float(p.y) + 0.5
        switch name {
        case 0: return inp.pointCoord(fx, fy).map { $0.bitPattern }
        case 2: return [inp.fragW(fx, fy).bitPattern]
        default: return [inp.fragZ(fx, fy).bitPattern]
        }
      })
    cfg.fragment = model
    cfg.registerInit = { lane, regs in
      let p = inp.pixel(lane)
      regs[55] = 0
      regs[56] = 0
      regs[57] = inp.primitiveId
      regs[58] = inp.backFacing[lane] ? 1 : 0
      regs[59] = UInt32(p.x) | UInt32(p.y) << 16
      regs[60] = UInt32(inp.coverage[lane])
      regs[61] = UInt32(inp.coverage[lane]) | inp.sampleId << 16
      regs[62] = inp.layer
      regs[63] = 0
    }
    let report = try runDispatch(Shader(code), cfg, memory: mem)
    return FragmentResult(
      colours: model.colours, depth: model.depth, stencil: model.stencil, coverage: model.blendCoverage, instructions: report.instructions)
  }
}
