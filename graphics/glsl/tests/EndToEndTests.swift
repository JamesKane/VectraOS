// SPDX-License-Identifier: BSD-3-Clause

// Programs through the whole path: compiled, linked, lowered, read by the compiler and compiled for Valhall, and run on
// the IR interpreter with known inputs, checked against what GL says they compute.

@testable import GLSL
import ShaderCompiler
import ShaderTestKit
import Testing

let basicVS = """
  attribute vec4 position;
  attribute vec2 uv;
  uniform mat4 mvp;
  varying vec2 v_uv;
  void main() {
    v_uv = uv;
    gl_Position = mvp * position;
  }
  """

let basicFS = """
  precision mediump float;
  uniform vec4 tint;
  varying vec2 v_uv;
  void main() {
    gl_FragColor = vec4(v_uv, 0.5, 1.0) * tint;
  }
  """

@Suite struct EndToEndTests {
  @Test func aBasicProgramLinksLowersAndCompiles() throws {
    let p = try linkProgram(basicVS, basicFS)
    #expect(p.attributes.map { $0.name }.sorted() == ["position", "uv"])
    #expect(p.uniforms.map { $0.name } == ["mvp", "tint"])
    _ = try lowerAndCompile(p, .vertex)
    _ = try lowerAndCompile(p, .fragment)
  }

  @Test func theVertexStageComputesItsPositionInVulkansClipSpace() throws {
    let p = try linkProgram(basicVS, basicFS, bindings: [(name: "position", location: 0), (name: "uv", location: 1)])
    var block = UniformBlock(p)
    // A matrix that scales by 2 and moves x by 1 (column-major).
    block.set("mvp", [2, 0, 0, 0, 0, 2, 0, 0, 0, 0, 2, 0, 1, 0, 0, 1])
    let (_, offsets, stride) = loweringLayout(p)
    var vb = [UInt8](repeating: 0, count: Int(stride) * 2)
    let pos: [Float] = [0.25, -0.5, 0.125, 1]
    for (i, x) in pos.enumerated() { put32(&vb, Int(stride) + Int(offsets[0]!) + 4 * i, x.bitPattern) }
    put32(&vb, Int(stride) + Int(offsets[1]!), Float(0.75).bitPattern)
    put32(&vb, Int(stride) + Int(offsets[1]!) + 4, Float(0.5).bitPattern)
    for (name, ir) in try lowerAndCompile(p, .vertex) {
      for flip in [false, true] {
        var b = block
        if flip { b = UniformBlock(p, flip: true) ; b.set("mvp", [2, 0, 0, 0, 0, 2, 0, 0, 0, 0, 2, 0, 1, 0, 0, 1]) }
        let m = try machineFor(ir, p, b, vb)
        let got = try #require(output(m, ir, location: -1), "\(name)")
        // GL: (1.5, -1, 0.25, 1); Vulkan's z = (z + w) / 2 = 0.625; y flipped when asked.
        #expect(close(got, [1.5, flip ? 1 : -1, 0.625, 1]), "\(name) flip \(flip): \(got)")
        let uv = try #require(output(m, ir, location: Int(p.varyings[0].location)), "\(name)")
        #expect(uv == [0.75, 0.5], "\(name): \(uv)")
      }
    }
  }

  private func machineFor(_ ir: IRModule, _ p: GLSLProgram, _ b: UniformBlock, _ vb: [UInt8]) throws -> Machine {
    let m = try run(ir, p, block: b, vertexBytes: vb, vertexIndex: 1)
    return m
  }

  @Test func theFragmentStageMultipliesByTheTint() throws {
    let p = try linkProgram(basicVS, basicFS)
    var block = UniformBlock(p)
    block.set("tint", [0.5, 2, 4, 1])
    for (name, ir) in try lowerAndCompile(p, .fragment) {
      let m = try run(ir, p, block: block, inputs: [0: [0.25, 0.75]])
      let got = try #require(output(m, ir, location: 0), "\(name)")
      #expect(close(got, [0.125, 1.5, 2, 1]), "\(name): \(got)")
    }
  }
}
