// SPDX-License-Identifier: BSD-3-Clause

// The lowered programs through the Valhall backend: each compiles, and its instructions pass the ISA validator (the
// wait-slot, scheduling and register rules). The lowered saxpy compute shader also runs on the Valhall interpreter,
// over memory laid out as the root block and set records say, and its output is checked exactly.

import MaliCore
import ShaderCompiler
import ShaderTestKit
import Testing
import ValhallBackend
import ValhallBridge
import ValhallISA
import VulkanLowering

private struct Case {
  var shader: String
  var stage: VulkanLowering.ShaderStage
  var layout: LoweringLayout
}

private let saxpyLayout = LoweringLayout(
  sets: [
    SetLayout(bindings: [DescriptorBinding(binding: 0, kind: .storageBuffer), DescriptorBinding(binding: 1, kind: .storageBuffer)])
  ], pushConstantBytes: 8)

private let cases: [Case] = [
  Case(shader: "saxpy.comp", stage: .compute, layout: saxpyLayout),
  Case(
    shader: "arrayed.comp", stage: .compute,
    layout: LoweringLayout(
      sets: [SetLayout(bindings: [DescriptorBinding(binding: 0, kind: .storageBuffer, count: 3)])], pushConstantBytes: 4)),
  Case(
    shader: "textured.frag", stage: .fragment,
    layout: LoweringLayout(sets: [
      nil,
      SetLayout(bindings: [
        DescriptorBinding(binding: 0, kind: .uniformBuffer), DescriptorBinding(binding: 1, kind: .combinedImageSampler),
      ]),
    ])),
  Case(
    shader: "arrayed.frag", stage: .fragment,
    layout: LoweringLayout(sets: [
      SetLayout(bindings: [DescriptorBinding(binding: 0, kind: .sampledImage, count: 4), DescriptorBinding(binding: 1, kind: .sampler)])
    ])),
  Case(
    shader: "geometry.vert", stage: .vertex,
    layout: LoweringLayout(
      vertexBindings: [VertexBinding(binding: 0, stride: 16), VertexBinding(binding: 1, stride: 8, perInstance: true)],
      vertexAttributes: [
        VertexAttribute(location: 0, binding: 0, format: .rgb32Float, offset: 0),
        VertexAttribute(location: 1, binding: 0, format: .rgba8Unorm, offset: 12),
        VertexAttribute(location: 2, binding: 1, format: .rg32Float, offset: 0),
      ])),
  Case(
    shader: "indexed.vert", stage: .vertex,
    layout: LoweringLayout(
      vertexBindings: [VertexBinding(binding: 0, stride: 20)],
      vertexAttributes: [
        VertexAttribute(location: 0, binding: 0, format: .r32Float, offset: 0),
        VertexAttribute(location: 1, binding: 0, format: .rg32Sint, offset: 4),
        VertexAttribute(location: 2, binding: 0, format: .r32Uint, offset: 12),
      ])),
]

private func broken(_ rules: [Violation], _ what: String) -> [String] {
  rules.map { what + ": " + $0.rule + " at " + String($0.instruction) + ": " + $0.message }
}

@Suite struct BackendTests {
  @Test func everyLoweredProgramCompilesAndPassesTheValidator() throws {
    for c in cases {
      let ir = try IRModule.lower(try SPIRVModule.parse(words: try lowered(c.shader, stage: c.stage, layout: c.layout)))
      if c.stage == .compute {
        let cs = try ValhallBackend.compile(ir)
        #expect(!cs.instructions.isEmpty, "\(c.shader)")
        let o = ValidatorOptions(arch: 12, stage: .compute, registerClass: cs.shader.registerClass == .r32 ? .class32 : .class64)
        #expect(broken(ISATable.shared.validate(cs.instructions, options: o), c.shader) == [])
      } else {
        let g = try ValhallBackend.compileGraphics(ir)
        #expect(!g.instructions.isEmpty, "\(c.shader)")
        let stage: ValhallISA.ShaderStage = c.stage == .vertex ? .vertex : .fragment
        let o = ValidatorOptions(arch: 12, stage: stage, registerClass: .class64)
        #expect(broken(ISATable.shared.validate(g.instructions, options: o), c.shader) == [])
      }
    }
  }

  /// The one lowered program the backend refuses: the length of a runtime array whose stride isn't a power of two is a
  /// division, and the backend selects no integer division (64-bit udiv). (A power of two is a shift, as saxpy's is.) When it does,
  /// this fails: move the program to `cases`.
  @Test func anOddStrideArrayLengthNeedsIntegerDivision() throws {
    let layout = LoweringLayout(sets: [
      SetLayout(bindings: [DescriptorBinding(binding: 0, kind: .storageBuffer), DescriptorBinding(binding: 1, kind: .storageBuffer)])
    ])
    let ir = try IRModule.lower(try SPIRVModule.parse(words: try lowered("records.comp", stage: .compute, layout: layout)))
    #expect(throws: BackendError.unsupported("64-bit integer operation udiv")) { _ = try ValhallBackend.compile(ir) }
  }

  /// The saxpy shader on the Valhall interpreter: the root block, the set record and the buffers are interpreter
  /// memory at the addresses `HostRun.dispatch` maps its buffers at, which are known before it runs.
  @Test func theLoweredSaxpyRunsOnTheValhallInterpreter() throws {
    let ir = try IRModule.lower(try SPIRVModule.parse(words: try lowered("saxpy.comp", stage: .compute, layout: saxpyLayout)))
    let cs = try ValhallBackend.compile(ir)
    let inLength = 100
    let outLength = 96
    let count: UInt32 = 98
    let input = (0..<inLength).map { Float($0) * 0.5 - 3 }
    let sentinel: Float = -7777
    // HostRun maps buffer k at 0x1000_0000 plus the sizes of the ones before, each rounded up past a page.
    let sizes = [RootBlock.size, 32, 4 * inLength, 4 * (outLength + 32)]
    var addresses: [UInt64] = []
    var next: UInt64 = 0x1000_0000
    for s in sizes {
      addresses.append(next)
      next += UInt64((s + 4096 + 4095) / 4096 * 4096)
    }
    var record = bufferDescriptor(addresses[2], range: 4 * inLength)
    record += bufferDescriptor(addresses[3], range: 4 * outLength)
    var root = [UInt8](repeating: 0, count: RootBlock.size)
    put64(&root, RootBlock.setsOffset, addresses[1])
    put32(&root, RootBlock.pushConstantsOffset, Float(2.5).bitPattern)
    put32(&root, RootBlock.pushConstantsOffset + 4, count)
    let out = [Float](repeating: sentinel, count: outLength + 32)
    let buffers = [
      Buffer(set: 9, binding: 0, bytes: root), Buffer(set: 9, binding: 1, bytes: record),
      Buffer(set: 9, binding: 2, bytes: bytes(input)), Buffer(set: 9, binding: 3, bytes: bytes(out)),
    ]
    let result = try HostRun.dispatch(
      cs, buffers: buffers, push: [UInt32(truncatingIfNeeded: addresses[0]), UInt32(truncatingIfNeeded: addresses[0] >> 32)],
      grid: (2, 1, 1))
    let got = floats(result[3].bytes)
    var want = [Float](repeating: sentinel, count: outLength + 32)
    for i in 0..<Int(min(UInt32(inLength), min(UInt32(outLength), count))) { want[i] = input[i] * 2.5 + Float(i) }
    #expect(got == want)
    #expect(result[2].bytes == bytes(input))
  }
}
