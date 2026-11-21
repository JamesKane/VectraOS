// SPDX-License-Identifier: BSD-3-Clause

// A texture handle is one value per warp (valhall 12b.2.1, 15 Q16): a fragment warp mixes primitives and instances, so
// a handle that comes from a flat varying differs between its lanes, and the compiler makes it uniform with a loop over
// the distinct values. Radharc's compose.frag indexes its textures by a flat varying (`source.z`). The shader's
// instructions are run here, 16 lanes of one warp, over the interpreter's model of a texel fetch, which refuses a fetch
// whose lanes name different textures; each lane's colour must be the one its own texture gives.

import Foundation
import MaliCore
import ShaderCompiler
import ShaderTestKit
import Testing
import ValhallBackend
import ValhallBridge
import ValhallISA
import ValhallInterp

private func sRGBLight(_ c: Float) -> Float {
  c < 0.04045 ? c / 12.92 : Float(pow(Double((c + 0.055) / 1.055), 2.4))
}

/// compose.frag over one warp: lane `n` draws a pixel of an image quad whose texture is `3 + n % 3` (three distinct
/// handles in a warp, as a warp that mixes instances has), and the colour it ends with, or the fault.
private func composeWarp(_ options: BackendOptions) throws -> (lanes: [[Float]], expected: [[Float]], blends: Int) {
  let words = try #require(treeWords("services/radharc/shaders/compose.frag.spv"))
  let c = try ValhallBackend.compileGraphics(spirv: words, options: options)
  let fs = try #require(c.fragment)
  // What the hardware does before the first instruction (the flat varyings, the position) is the test's: the three
  // `LD_VAR` loads go, and the registers they would fill are given. The tail from the coverage's `ATEST` on is the
  // blender's: the run ends where it starts.
  var instructions = c.instructions
  var first = 0
  while instructions[first].mnemonic.hasPrefix("LD_VAR") { first += 1 }
  let atest = try #require(instructions.firstIndex { $0.mnemonic == "ATEST" })
  let blend = try #require(instructions.firstIndex { $0.mnemonic == "BLEND" })
  let colour = try #require(instructions[blend].stagingRead).first
  var code: [Instr] = []
  for i in instructions[first..<(atest - 1)] { code.append(try i.interpInstr()) }
  var stop = Instr(.nop, .u32)
  stop.flow = .end
  code.append(stop)
  // The FAU: the texture binding's heap handle (table 1, element 0 at 16) and the dummy sampler's.
  let heap = DescriptorHeap.handle(index: 16)
  let sampler = DescriptorHeap.handle(index: 0)
  let block = fs.layout.block(push: [], images: [(set: 0, binding: 0, handle: heap)], dummySampler: sampler)
  var fau: [UInt32] = []
  for w in block {
    fau.append(UInt32(truncatingIfNeeded: w))
    fau.append(UInt32(truncatingIfNeeded: w >> 32))
  }
  var cfg = DispatchConfig(workgroupSize: ValhallInterp.Dim3(16), grid: ValhallInterp.Dim3(1), fau: fau)
  cfg.captureFirstWarp = true
  cfg.strictLastUse = false
  @Sendable func texel(_ handle: UInt32, _ x: UInt32, _ y: UInt32) -> [Float] {
    [Float(handle & 0xFF) / 255, Float(x & 0xFF) / 255, Float(y & 0xFF) / 255, 1]
  }
  cfg.textureFetch = { handle, x, y in texel(handle, x, y).map { $0.bitPattern } }
  cfg.registerInit = { lane, regs in
    // The flat varyings: source = (0, 0, texture index, kind 1), the colour word 0, origin (0, 0).
    regs[0] = 0
    regs[1] = 0
    regs[2] = UInt32(3 + lane % 3)
    regs[3] = 1
    regs[4] = 0
    regs[6] = 0
    regs[7] = 0
    regs[59] = UInt32(10 + lane % 4) | UInt32(20 + lane / 4) << 16
  }
  let report = try runDispatch(Shader(code), cfg, memory: GpuMemory())
  var lanes: [[Float]] = []
  var expected: [[Float]] = []
  for lane in 0..<16 {
    lanes.append((0..<3).map { Float(bitPattern: report.firstWarpRegisters[lane * 64 + colour + $0]) })
    // The fetch at the pixel's own position (the position plus a half, less the origin, floored), then light.
    let t = texel(UInt32(heap) &+ UInt32(3 + lane % 3), UInt32(10 + lane % 4), UInt32(20 + lane / 4))
    expected.append((0..<3).map { sRGBLight(t[$0]) })
  }
  return (lanes, expected, instructions.filter { $0.mnemonic == "BLEND" }.count)
}

@Suite struct UniformHandleTests {
  @Test func theHandleLoopServesEveryLanesTexture() throws {
    let r = try composeWarp(BackendOptions())
    #expect(r.blends == 1)
    for lane in 0..<16 {
      for ch in 0..<3 {
        let a = r.lanes[lane][ch], b = r.expected[lane][ch]
        #expect(abs(a - b) <= 0.002 + 0.002 * b, "lane \(lane) channel \(ch): \(a) against \(b)")
      }
    }
  }

  @Test func withoutTheLoopTheLanesNameDifferentTexturesInOneFetch() throws {
    var o = BackendOptions()
    o.uniformTextureHandles = false
    // The interpreter refuses the fetch the hardware would serve with one lane's handle.
    #expect(throws: ValhallInterp.InterpError.self) { _ = try composeWarp(o) }
  }

  @Test func theLoopIsAroundTheFetchAndTheDiscardsComeAfterIt() throws {
    let words = try #require(treeWords("services/radharc/shaders/compose.frag.spv"))
    let c = try ValhallBackend.compileGraphics(spirv: words)
    let names = c.instructions.map { $0.mnemonic }
    let tex = try #require(names.firstIndex(of: "TEX_FETCH"))
    let wmask = names.indices.filter { names[$0] == "WMASK" }
    let clper = names.indices.filter { names[$0] == "CLPER" }
    #expect(wmask.count == 2 && clper.count == 1, "a ballot at the loop's head and its tail, one broadcast of the handle")
    #expect(wmask[0] < clper[0] && clper[0] < tex && tex < wmask[1])
    // No discard runs before the loop is over: the helper lanes the ballot and the broadcast need stay alive (13.10.3).
    let firstDiscard = try #require(names.firstIndex(of: "DISCARD"))
    #expect(firstDiscard > wmask[1])
    // The loop's back edge goes to its head.
    let back = names.indices.filter { names[$0] == "BRANCH" && c.instructions[$0].value("offset").map { Int64(bitPattern: $0) < 0 } ?? false }
    #expect(!back.isEmpty)
  }

  @Test func aUniformHandleNeedsNoLoop() throws {
    // A fetch of a single image (not an array indexed by a varying): its handle is the binding's, the same in every lane.
    let c = try ValhallBackend.compileGraphics(spirv: try assemble(Corpus.plainFetch))
    #expect(c.instructions.contains { $0.mnemonic == "TEX_FETCH" })
    #expect(!c.instructions.contains { $0.mnemonic == "WMASK" || $0.mnemonic == "CLPER" })
  }

  @Test func anIndexFromAFlatVaryingGetsTheLoopWhereverTheShaderIs() throws {
    // Loinnir's textured.frag takes its texture index from a flat varying too: the same loop.
    let words = try #require(treeWords("graphics/loinnir/tests/shaders/textured.frag.spv"))
    let c = try ValhallBackend.compileGraphics(spirv: words)
    #expect(c.instructions.contains { $0.mnemonic == "WMASK" } && c.instructions.contains { $0.mnemonic == "CLPER" })
  }
}
