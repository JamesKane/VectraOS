// SPDX-License-Identifier: BSD-3-Clause

// Derivatives, helper invocations and the built-ins of each stage (valhall 13.6, 13.10, 14.2 to 14.4): GLSL shaders run on
// the interpreter's quads, the lanes' results checked against the same arithmetic done in Swift.

import Foundation
import MaliCore
import ShaderCompiler
import ShaderTestKit
import Testing
import ValhallBackend
import ValhallBridge
import ValhallISA
import ValhallInterp

private func at(_ inp: FragmentInput, _ lane: Int, _ loc: Int = 0) -> [Float] {
  let p = inp.pixel(lane)
  return inp.varying(loc, Float(p.x) + 0.5, Float(p.y) + 0.5)
}

@Suite struct DerivativeTests {
  /// Non-linear in x and y, so the coarse and the fine derivatives differ lane by lane.
  func input(helpers: [Int] = []) -> FragmentInput {
    var inp = FragmentInput()
    inp.origin = (8, 8)
    inp.varying = { _, x, y in [0.013 * x * x + 0.07 * y, 0.5 * y * y - 0.02 * x, 1.0 / (x + 3 * y), 0.3 * x * y - 2 * x] }
    for h in helpers { inp.coverage[h] = 0 }
    return inp
  }

  func coarse(_ inp: FragmentInput, _ lane: Int, y: Bool, _ c: Int) -> Float {
    let q = lane & ~3
    return at(inp, q + (y ? 2 : 1))[c] - at(inp, q)[c]
  }

  func fine(_ inp: FragmentInput, _ lane: Int, y: Bool, _ c: Int) -> Float {
    let n = lane ^ (y ? 2 : 1)
    let odd = y ? lane & 2 != 0 : lane & 1 != 0
    return odd ? at(inp, lane)[c] - at(inp, n)[c] : at(inp, n)[c] - at(inp, lane)[c]
  }

  @Test func coarseAndFineDerivativesAreTheQuadsDifferences() throws {
    // Lanes 1, 6 and 11 are helpers: they are in the quads, give their values, and write nothing.
    let inp = input(helpers: [1, 6, 11])
    let r = try runFragment("deriv", inp, bindings: [])
    let names = r.shader.instructions.map { $0.mnemonic }
    #expect(names.contains("CLPER"))
    let tol: Float = 1e-6
    for lane in 0..<16 {
      if inp.coverage[lane] == 0 {
        #expect(r.result.colours[lane].isEmpty, "a helper lane writes nothing")
        continue
      }
      expectTexel(r.result.colours[lane][0], [coarse(inp, lane, y: false, 0), coarse(inp, lane, y: true, 1), coarse(inp, lane, y: false, 2), coarse(inp, lane, y: true, 3)].map { $0.bitPattern }, "coarse, lane \(lane)", tolerance: tol)
      expectTexel(r.result.colours[lane][1], [fine(inp, lane, y: false, 0), fine(inp, lane, y: true, 1), fine(inp, lane, y: false, 2), fine(inp, lane, y: true, 3)].map { $0.bitPattern }, "fine, lane \(lane)", tolerance: tol)
      let w = (0..<4).map { abs(coarse(inp, lane, y: false, $0)) + abs(coarse(inp, lane, y: true, $0)) }
      expectTexel(r.result.colours[lane][2], w.map { $0.bitPattern }, "fwidth, lane \(lane)", tolerance: tol)
      let fw = (0..<2).map { abs(fine(inp, lane, y: false, $0)) + abs(fine(inp, lane, y: true, $0)) }
      let cw = (2..<4).map { abs(coarse(inp, lane, y: false, $0)) + abs(coarse(inp, lane, y: true, $0)) }
      expectTexel(r.result.colours[lane][3], (fw + cw).map { $0.bitPattern }, "fwidth variants, lane \(lane)", tolerance: tol)
    }
  }

  @Test func theFineSignFlipIsInTheLaneIdsBit() throws {
    let c = try compileShader("deriv")
    let text = c.instructions.map { $0.mnemonic }
    #expect(text.contains("LSHIFT_XOR"), "the sign flip is a shift and exclusive-or of the lane id (13.10.2)")
  }

  @Test func aDemotedLaneKeepsGivingItsQuadItsValues() throws {
    var inp = FragmentInput()
    inp.origin = (8, 8)
    inp.varying = { _, x, y in [(x - 8) * 0.17 + (y - 8) * 0.09 - 0.35, x * x * 0.01 + y * 0.3, 0, 0] }
    inp.coverage[2] = 0
    inp.coverage[5] = 0
    let r = try runFragment("demote", inp, bindings: [])
    #expect(r.shader.fragment?.discards == true || r.shader.instructions.contains { $0.mnemonic == "DISCARD" })
    func helper(_ l: Int) -> Float { inp.coverage[l] == 0 ? 1 : 0 }
    func after(_ l: Int) -> Float { helper(l) == 1 || at(inp, l)[0] > 0.5 ? 1 : 0 }
    func cdx(_ q: Int, _ f: (Int) -> Float) -> Float { f(q + 1) - f(q) }
    func cdy(_ q: Int, _ f: (Int) -> Float) -> Float { f(q + 2) - f(q) }
    var written = 0
    for lane in 0..<16 {
      let q = lane & ~3
      let demoted = at(inp, lane)[0] > 0.5
      if inp.coverage[lane] == 0 || demoted {
        #expect(r.result.colours[lane].isEmpty, "lane \(lane) is a helper or demoted: it writes nothing")
        continue
      }
      written += 1
      expectTexel(
        r.result.colours[lane][0], [0, 0, cdx(q) { at(inp, $0)[1] }, cdy(q) { at(inp, $0)[1] }].map { $0.bitPattern }, "lane \(lane)",
        tolerance: 1e-6)
      // The helper flag, before and after the demotion, differs between the quad's lanes: a demoted lane is a helper from
      // then on (IsHelperInvocation), and it still takes part in the derivative.
      expectTexel(
        r.result.colours[lane][1], [cdx(q, helper), cdy(q, helper), cdx(q, after), cdy(q, after)].map { $0.bitPattern }, "flags, lane \(lane)",
        tolerance: 1e-6)
    }
    #expect(written > 4 && written < 14)
  }
}

@Suite struct FragmentBuiltinTests {
  func input() -> FragmentInput {
    var inp = FragmentInput()
    inp.origin = (8, 8)
    for l in 0..<16 { inp.coverage[l] = UInt16(1 | (l * 0x111)) & 0xFFFF }
    inp.coverage[3] = 0
    inp.coverage[9] = 0
    for l in 0..<16 { inp.backFacing[l] = l % 3 == 0 }
    inp.primitiveId = 77
    inp.layer = 3
    inp.sampleId = 2
    inp.fragZ = { x, y in 0.3 + x * 0.01 + y * 0.001 }
    inp.fragW = { x, _ in 2 + x * 0.5 }
    inp.pointCoord = { x, y in [(x * 0.1).truncatingRemainder(dividingBy: 1), (y * 0.1).truncatingRemainder(dividingBy: 1)] }
    return inp
  }

  @Test func everyFragmentBuiltinHasTheValueTheABIGives() throws {
    let inp = input()
    let r = try runFragment("fragbuiltins", inp, bindings: [])
    let fs = try #require(r.shader.fragment)
    #expect(fs.writesDepth && fs.writesSampleMask && fs.perSampleShading && fs.readsSamplePositions)
    let table = inp.samplePositions[Int(inp.sampleId)]
    for lane in 0..<16 {
      let p = inp.pixel(lane)
      let x = Float(p.x) + 0.5, y = Float(p.y) + 0.5
      if inp.coverage[lane] == 0 {
        #expect(r.result.colours[lane].isEmpty, "a helper lane writes nothing")
        continue
      }
      expectTexel(r.result.colours[lane][0], [x, y, inp.fragZ(x, y), inp.fragW(x, y)].map { $0.bitPattern }, "FragCoord, lane \(lane)")
      let pc = inp.pointCoord(x, y)
      expectTexel(r.result.colours[lane][1], [pc[0], pc[1], inp.backFacing[lane] ? 0 : 1, 2].map { $0.bitPattern }, "PointCoord, FrontFacing, SampleId, lane \(lane)")
      #expect(
        r.result.colours[lane][2] == [77, 3, UInt32(inp.coverage[lane]), 0], "PrimitiveId, Layer, SampleMaskIn, HelperInvocation, lane \(lane): \(String(describing: r.result.colours[lane][2]))")
      expectTexel(r.result.colours[lane][3], [Float(table.x) / 256, Float(table.y) / 256, 0, 1].map { $0.bitPattern }, "SamplePosition, lane \(lane)")
      #expect(r.result.depth[lane] == (inp.fragZ(x, y) * 0.5).bitPattern, "FragDepth, lane \(lane)")
      #expect(r.result.coverage[lane] == UInt32(inp.coverage[lane]) & 5, "SampleMask out, lane \(lane)")
    }
  }

  @Test func baryCentricsAndClipDistancesAreRefusedByName() throws {
    for name in ["baryrefused", "clipdistance"] {
      do {
        _ = try compileShader(name)
        Issue.record("\(name) was accepted")
      } catch let e as CompileError {
        #expect(e.message.contains("14.3.7"), "\(name): \(e.message)")
      } catch let e as BackendError {
        #expect("\(e)".contains("14.3.7"), "\(name): \(e)")
      }
    }
  }
}

@Suite struct VertexBuiltinTests {
  @Test func theIndicesAndTheDriversBaseValues() throws {
    let c = try compileShader("vertexbuiltins")
    let v = try #require(c.vertex)
    #expect(v.readsDrawIndex && v.layout.baseVertexWord >= 0 && v.layout.baseInstanceWord >= 0)
    #expect(v.preloadMask & (1 << 14) != 0, "r62, the draw id")
    let block = v.layout.block(viewport: ViewportTransform(width: 1, height: 1), baseVertex: 7, baseInstance: 3)
    var fau: [UInt32] = []
    for w in block {
      fau.append(UInt32(truncatingIfNeeded: w))
      fau.append(UInt32(truncatingIfNeeded: w >> 32))
    }
    let r = try HostRun.vertex(instructions: c.instructions, fau: fau, varyingBytes: Int(v.varyingBytes), memory: [])
    for lane in 0..<16 {
      let words = r.varyings[lane]
      #expect(Float(bitPattern: words[0]) == Float(lane), "VertexIndex, lane \(lane)")
      #expect(Float(bitPattern: words[1]) == 3, "InstanceIndex is the instance plus the base instance, lane \(lane)")
      #expect(Array(words[4..<8]) == [7, 3, 0, UInt32(lane)], "BaseVertex, BaseInstance, DrawIndex, VertexIndex, lane \(lane)")
    }
  }

  @Test func aLayerAndAViewportIndexAreTheAttributeSectionsByte() throws {
    for (name, viewport) in [("layer", false), ("viewport", true)] {
      let c = try compileShader(name)
      let v = try #require(c.vertex)
      #expect(v.extendedRecord && v.storesViewportIndex == viewport, "\(name)")
      #expect(c.instructions.contains { $0.mnemonic == "STORE" && $0.variant == "i8" }, "\(name)")
      // The attribute group is behind shader_output's bit 1.
      #expect(c.listing.contains("shader_output"), "\(name)")
    }
    #expect(throws: BackendError.self) { _ = try compileShader("bothlayerviewport") }
  }

  @Test func aShaderWithoutThemKeepsTheBasicRecord() throws {
    let v = try #require(try compileShader("vertexbuiltins").vertex)
    #expect(!v.extendedRecord && !v.storesPointSize)
  }
}

@Suite struct ComputeBuiltinTests {
  @Test func everyComputeBuiltinOfEveryInvocation() throws {
    let cs = try ValhallBackend.compile(spirv: try shaderWords("computebuiltins"))
    let grid = (2, 2, 2)
    let size = (8, 4, 2)
    let total = grid.0 * grid.1 * grid.2 * size.0 * size.1 * size.2
    let out = try HostRun.dispatch(cs, buffers: [Buffer(binding: 0, bytes: [UInt8](repeating: 0xEE, count: total * 20 * 4))], grid: (2, 2, 2))
    let bytes = out[0].bytes
    func word(_ i: Int) -> UInt32 {
      UInt32(bytes[4 * i]) | UInt32(bytes[4 * i + 1]) << 8 | UInt32(bytes[4 * i + 2]) << 16 | UInt32(bytes[4 * i + 3]) << 24
    }
    let w = grid.0 * size.0, h = grid.1 * size.1
    var seen = 0
    for gz in 0..<(grid.2 * size.2) {
      for gy in 0..<h {
        for gx in 0..<w {
          let idx = gx + w * (gy + h * gz)
          let lx = gx % size.0, ly = gy % size.1, lz = gz % size.2
          let li = lx + size.0 * (ly + size.1 * lz)
          let want: [Int] = [
            lx, ly, lz, li, gx / size.0, gy / size.1, gz / size.2, grid.0, grid.1, grid.2, size.0, size.1, size.2, gx, gy, gz, 16,
            (size.0 * size.1 * size.2 + 15) / 16, li / 16, li % 16,
          ]
          let got = (0..<20).map { Int(word(idx * 20 + $0)) }
          #expect(got == want, "invocation \(gx),\(gy),\(gz): \(got) against \(want)")
          seen += 1
        }
      }
    }
    #expect(seen == total)
  }
}
