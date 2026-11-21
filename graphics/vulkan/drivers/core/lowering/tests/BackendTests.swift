// SPDX-License-Identifier: BSD-3-Clause

// The lowered programs through the Valhall backend. Every lowered program reads a descriptor's address and makes a
// pointer of it (OpConvertUToPtr, IR `inttoptr`), and the push-constant block's pointer is turned back into an address
// for the push constants' bytes (`ptrtoint`): the backend selects neither yet. So each program is pinned with the
// refusal it gets, by name, as the compiler's TreeShaderTests pin what the compiler lacks: when the backend takes
// them, these fail, and the programs are compiled and listed here instead.

import ShaderCompiler
import ShaderTestKit
import Testing
import ValhallBackend
import VulkanLowering

private struct Case {
  var shader: String
  var stage: ShaderStage
  var layout: LoweringLayout
  /// The refusal the backend gives; nil if it takes the program.
  var refusal: String?
}

private let cases: [Case] = [
  Case(
    shader: "saxpy.comp", stage: .compute,
    layout: LoweringLayout(
      sets: [
        SetLayout(bindings: [DescriptorBinding(binding: 0, kind: .storageBuffer), DescriptorBinding(binding: 1, kind: .storageBuffer)])
      ], pushConstantBytes: 8),
    refusal: "operation ptrtoint"),
  Case(
    shader: "arrayed.comp", stage: .compute,
    layout: LoweringLayout(
      sets: [SetLayout(bindings: [DescriptorBinding(binding: 0, kind: .storageBuffer, count: 3)])], pushConstantBytes: 4),
    refusal: "operation ptrtoint"),
  Case(
    shader: "textured.frag", stage: .fragment,
    layout: LoweringLayout(sets: [
      nil,
      SetLayout(bindings: [
        DescriptorBinding(binding: 0, kind: .uniformBuffer), DescriptorBinding(binding: 1, kind: .combinedImageSampler),
      ]),
    ]), refusal: "operation inttoptr"),
  Case(
    shader: "arrayed.frag", stage: .fragment,
    layout: LoweringLayout(sets: [
      SetLayout(bindings: [DescriptorBinding(binding: 0, kind: .sampledImage, count: 4), DescriptorBinding(binding: 1, kind: .sampler)])
    ]), refusal: "operation inttoptr"),
  Case(
    shader: "geometry.vert", stage: .vertex,
    layout: LoweringLayout(
      vertexBindings: [VertexBinding(binding: 0, stride: 16), VertexBinding(binding: 1, stride: 8, perInstance: true)],
      vertexAttributes: [
        VertexAttribute(location: 0, binding: 0, format: .rgb32Float, offset: 0),
        VertexAttribute(location: 1, binding: 0, format: .rgba8Unorm, offset: 12),
        VertexAttribute(location: 2, binding: 1, format: .rg32Float, offset: 0),
      ]),
    refusal: "operation inttoptr"),
]

@Suite struct BackendTests {
  @Test func theBackendTakesTheLoweredProgramsOrRefusesByName() throws {
    for c in cases {
      let ir = try IRModule.lower(try SPIRVModule.parse(words: try lowered(c.shader, stage: c.stage, layout: c.layout)))
      var refusal: String? = nil
      do {
        if c.stage == .compute {
          _ = try ValhallBackend.compile(ir)
        } else {
          _ = try ValhallBackend.compileGraphics(ir)
        }
      } catch let e as BackendError {
        if case .unsupported(let what) = e { refusal = what } else { refusal = "\(e)" }
      }
      #expect(refusal == c.refusal, "\(c.shader)")
    }
  }
}
