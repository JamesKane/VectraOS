// SPDX-License-Identifier: BSD-3-Clause

// The lowering of the things the layer once left out: 1D images (sampled, on the IR interpreter; storage, on the Valhall
// interpreter), texel buffers (the heap's fourth and fifth arrays, on the Valhall interpreter) and input attachments (a fetch of the attachment's texture at the
// fragment's own position, on the IR interpreter). Each result is checked against what the GLSL means, worked out by hand.

import MaliCore
import ShaderCompiler
import ShaderTestKit
import Testing
import ValhallBackend
import ValhallBridge
import ValhallISA
import VulkanLowering

private func expectLowered(_ words: [UInt32], sourceLocation: SourceLocation = #_sourceLocation) {
  var pushVariables = 0
  for v in instructions(words, op: 59) {
    #expect(v[2] != 2 && v[2] != 12, "a variable in Uniform or StorageBuffer", sourceLocation: sourceLocation)
    if v[2] == 9 { pushVariables += 1 }
  }
  #expect(pushVariables == 1, "the core's one push-constant variable", sourceLocation: sourceLocation)
  let model = instructions(words, op: 14)
  #expect(model.count == 1 && model[0][0] == 5348, "the addressing model", sourceLocation: sourceLocation)
}

/// The image types the program declares (`OpTypeImage`: id, sampled type, dimension, depth, arrayed, multisampled, sampled, format).
private func imageTypes(_ words: [UInt32]) -> [[UInt32]] { instructions(words, op: 25) }

@Suite struct OneDimensionalLoweringTests {
  @Test func aSampledOneDimensionalImageIsTheHeapsTexture() throws {
    let layout = LoweringLayout(sets: [SetLayout(bindings: [DescriptorBinding(binding: 0, kind: .combinedImageSampler)])])
    let words = try lowered("sampled1d.frag", stage: .fragment, layout: layout)
    expectLowered(words)
    // The heap's array at binding 0 is of the program's own image type: 1D (dimension 0).
    #expect(imageTypes(words).contains { $0[2] == 0 && $0[6] == 1 })
    let bindings = instructions(words, op: 71).filter { $0[1] == 33 }.map { $0[2] }.sorted()
    #expect(bindings == [0, 1])
    for (name, ir) in try compile(words) {
      let machine = Machine(ir)
      var mem = FakeMemory(machine)
      let set0 = mem.place(slotDescriptor(6, 2))
      machine.push = le(mem.root(sets: [set0]), bytes: 8)
      machine.stageInputs[0] = [UInt64(Float(0.25).bitPattern)]
      // The texel at u of heap texture t with sampler s, component k: (k + 1) * t + 10 * s + 100 u.
      machine.texelModel = { image, sampler, operands, k in
        let u = Float(bitPattern: UInt32(truncatingIfNeeded: operands[0]))
        return UInt64((Float(k + 1) * Float(image) + 10 * Float(sampler) + 100 * u).bitPattern)
      }
      try machine.dispatch(groups: (1, 1, 1))
      let out = try #require(machine.stageOutputs[0], "\(name)")
      let got = out.map { Float(bitPattern: UInt32(truncatingIfNeeded: $0)) }
      let want = (0..<4).map { Float($0 + 1) * 6 + 20 + 25 }
      #expect(got == want, "\(name): got \(got), wanted \(want)")
    }
  }

  @Test func aStorageImageOfOneDimensionIsReadAndWrittenExactly() throws {
    let layout = LoweringLayout(sets: [
      SetLayout(bindings: [DescriptorBinding(binding: 0, kind: .storageImage), DescriptorBinding(binding: 1, kind: .storageBuffer)])
    ])
    let words = try lowered("storage1d.comp", stage: .compute, layout: layout)
    expectLowered(words)
    #expect(imageTypes(words).contains { $0[2] == 0 && $0[6] == 2 })
    let ir = try IRModule.lower(try SPIRVModule.parse(words: words))
    let cs = try ValhallBackend.compile(ir)
    let n = 16
    // HostRun maps buffer k at 0x1000_0000 plus the sizes of the ones before, each rounded up past a page.
    let sizes = [RootBlock.size, 32, 4 * n]
    var addresses: [UInt64] = []
    var next: UInt64 = 0x1000_0000
    for s in sizes {
      addresses.append(next)
      next += UInt64((s + 4096 + 4095) / 4096 * 4096)
    }
    var record = slotDescriptor(0)
    record += bufferDescriptor(addresses[2], range: 4 * n)
    var root = [UInt8](repeating: 0, count: RootBlock.size)
    put64(&root, RootBlock.setsOffset, addresses[1])
    let texels = (0..<n).map { UInt32($0 * 7 + 1) }
    let image = HostImage(set: 0, binding: 2, HostImage.Element(bytes: texels.flatMap { le(UInt64($0), bytes: 4) }, width: n, format: .r32Uint))
    let buffers = [
      Buffer(set: 9, binding: 0, bytes: root), Buffer(set: 9, binding: 1, bytes: record),
      Buffer(set: 9, binding: 2, bytes: [UInt8](repeating: 0xEE, count: 4 * n)),
    ]
    let result = try HostRun.dispatch(
      cs, buffers: buffers, images: [image], push: [UInt32(truncatingIfNeeded: addresses[0]), UInt32(truncatingIfNeeded: addresses[0] >> 32)],
      grid: (1, 1, 1))
    let out = result.buffers[2].bytes
    let after = result.images[0].elements[0].bytes
    for i in 0..<n {
      func word(_ b: [UInt8]) -> UInt32 { (0..<4).reduce(UInt32(0)) { $0 | UInt32(b[4 * i + $1]) << UInt32(8 * $1) } }
      #expect(word(out) == texels[i] * 3 + UInt32(i), "out[\(i)]")
      #expect(word(after) == texels[i] + 100, "texel \(i)")
    }
  }

}

@Suite struct TexelBufferLoweringTests {
  private static let layout = LoweringLayout(sets: [
    SetLayout(bindings: [
      DescriptorBinding(binding: 0, kind: .uniformTexelBuffer), DescriptorBinding(binding: 1, kind: .storageTexelBuffer),
      DescriptorBinding(binding: 2, kind: .storageBuffer),
    ])
  ])

  @Test func theHeapHoldsThemInItsFourthAndFifthArrays() throws {
    let words = try lowered("texelbuffer.comp", stage: .compute, layout: Self.layout)
    expectLowered(words)
    // The two texel-buffer variables are set 0, bindings 3 and 4; the storage buffer is a pointer, not a variable.
    let bindings = instructions(words, op: 71).filter { $0[1] == 33 }.map { $0[2] }.sorted()
    #expect(bindings == [3, 4])
    // Their types are the program's own: a buffer image, sampled (uniform) and storage.
    #expect(imageTypes(words).contains { $0[2] == 5 && $0[6] == 1 })
    #expect(imageTypes(words).contains { $0[2] == 5 && $0[6] == 2 })
    // The atomic is on the storage texel buffer's element in the heap: a texel pointer into binding 4.
    #expect(instructions(words, op: 60).count == 1)
  }

  @Test func theCompilerTakesThemAndTheValhallBackendCompilesThemAndTheValidatorPassesThem() throws {
    let words = try lowered("texelbuffer.comp", stage: .compute, layout: Self.layout)
    for (name, ir) in try compile(words) {
      let cs = try ValhallBackend.compile(ir)
      let o = ValidatorOptions(arch: 12, stage: .compute, registerClass: cs.shader.registerClass == .r32 ? .class32 : .class64)
      #expect(ISATable.shared.validate(cs.instructions, options: o).isEmpty, "\(name)")
      let listing = cs.listing
      #expect(listing.contains("LEA_BUF") && listing.contains("LD_CVT") && listing.contains("ST_CVT"), "\(name)")
    }
  }

  /// The lowered program on the Valhall interpreter over its model of the heap's two arrays and the root block and set record the lowering
  /// reads: element i of the uniform r32float buffer is fetched as a vec4 into the output (R, 0, 0, 1: the channels the format lacks), and
  /// the storage r32uint buffer gets 2i and an atomic add of one.
  @Test func theLoweredProgramRunsOnTheValhallInterpreter() throws {
    let words = try lowered("texelbuffer.comp", stage: .compute, layout: Self.layout)
    let ir = try IRModule.lower(try SPIRVModule.parse(words: words))
    let cs = try ValhallBackend.compile(ir)
    let r32float: UInt32 = 167 << 12 | 16  // the pixel format words of R32 FLOAT and R32 UINT, order RGB1 (valhall 05 5.3.1); the program's two arrays are the heap's bindings 3 and 4
    let r32uint: UInt32 = 133 << 12 | 16
    let source: [Float] = (0..<16).map { Float($0) * 0.5 + 0.25 }
    var sourceBytes: [UInt8] = []
    for f in source { for k in 0..<4 { sourceBytes.append(UInt8(truncatingIfNeeded: f.bitPattern >> UInt32(8 * k))) } }
    // HostRun maps the buffers at 0x1000_0000 plus the sizes of the ones before, each rounded up past a page: the root block, the set
    // record (binding 2's buffer descriptor is at its byte 32, after the texel buffers' two slots, 0 and 0), then the output.
    let sizes = [RootBlock.size, 64, 4 * 4 * 16]
    var addresses: [UInt64] = []
    var next: UInt64 = 0x1000_0000
    for s in sizes {
      addresses.append(next)
      next += UInt64((s + 4096 + 4095) / 4096 * 4096)
    }
    var root = [UInt8](repeating: 0, count: RootBlock.size)
    put64(&root, RootBlock.setsOffset, addresses[1])
    var record = bufferDescriptor(0, range: 0) + bufferDescriptor(0, range: 0)
    record += bufferDescriptor(addresses[2], range: 4 * 4 * 16)
    let result = try HostRun.dispatch(
      cs,
      buffers: [
        Buffer(set: 9, binding: 0, bytes: root), Buffer(set: 9, binding: 1, bytes: record),
        Buffer(set: 9, binding: 2, bytes: [UInt8](repeating: 0xEE, count: 4 * 4 * 16)),
      ], images: [], push: [UInt32(truncatingIfNeeded: addresses[0]), UInt32(truncatingIfNeeded: addresses[0] >> 32)], grid: (1, 1, 1),
      texelBuffers: [
        HostTexelBuffer(set: 0, binding: 3, .init(bytes: sourceBytes, stride: 4, conversion: r32float)),
        HostTexelBuffer(set: 0, binding: 4, .init(bytes: [UInt8](repeating: 0xEE, count: 64), stride: 4, conversion: r32uint)),
      ])
    var got: [UInt32] = []
    var want: [UInt32] = []
    for i in 0..<16 {
      for k in 0..<4 {
        var v: UInt32 = 0
        for b in 0..<4 { v |= UInt32(result.buffers[2].bytes[16 * i + 4 * k + b]) << UInt32(8 * b) }
        got.append(v)
      }
      want += [source[i].bitPattern, 0, 0, Float(1).bitPattern]
    }
    #expect(got == want)
    var stored: [UInt32] = []
    for i in 0..<16 {
      var v: UInt32 = 0
      for b in 0..<4 { v |= UInt32(result.texelBuffers[1].elements[0].bytes[4 * i + b]) << UInt32(8 * b) }
      stored.append(v)
    }
    #expect(stored == (0..<16).map { UInt32($0 * 2 + 1) })
    #expect(result.texelBuffers[0].elements[0].bytes == sourceBytes)
  }

  @Test func aTexelBufferThatTheLayoutLacksOrNamesAsAnotherKindIsInvalid() throws {
    let wrong = LoweringLayout(sets: [
      SetLayout(bindings: [
        DescriptorBinding(binding: 0, kind: .storageImage), DescriptorBinding(binding: 1, kind: .storageTexelBuffer),
        DescriptorBinding(binding: 2, kind: .storageBuffer),
      ])
    ])
    #expect(throws: LoweringError.invalid("binding 0 of set 0 is not the kind of descriptor the program declares")) {
      _ = try lowered("texelbuffer.comp", stage: .compute, layout: wrong)
    }
  }
}

@Suite struct InputAttachmentLoweringTests {
  private static let layout = LoweringLayout(sets: [SetLayout(bindings: [DescriptorBinding(binding: 0, kind: .inputAttachment)])])

  @Test func subpassLoadIsAFetchOfTheAttachmentsTextureAtTheFragmentsPosition() throws {
    let words = try lowered("subpass.frag", stage: .fragment, layout: Self.layout)
    expectLowered(words)
    #expect(instructions(words, op: 98).isEmpty, "no OpImageRead is left")
    #expect(instructions(words, op: 95).count == 1, "one OpImageFetch")
    #expect(!instructions(words, op: 17).map { $0[0] }.contains(40), "the InputAttachment capability is gone")
    // The heap's texture array is the one variable, at set 0, binding 0; FragCoord is read.
    let bindings = instructions(words, op: 71).filter { $0[1] == 33 }.map { $0[2] }.sorted()
    #expect(bindings == [0])
    #expect(instructions(words, op: 71).contains { $0[1] == 11 && $0[2] == 15 }, "the FragCoord built-in")
    for (name, ir) in try compile(words) {
      let machine = Machine(ir)
      var mem = FakeMemory(machine)
      let set0 = mem.place(slotDescriptor(9))
      machine.push = le(mem.root(sets: [set0]), bytes: 8)
      machine.fragCoord = [UInt64(Float(5.5).bitPattern), UInt64(Float(7.5).bitPattern), UInt64(Float(0.5).bitPattern), UInt64(Float(1).bitPattern)]
      // The texel at integer (x, y) of heap texture t, component k: 1000 t + 100 x + 10 y + k.
      machine.texelModel = { image, _, operands, k in
        let x = Int32(truncatingIfNeeded: operands[0])
        let y = Int32(truncatingIfNeeded: operands[1])
        return UInt64((Float(image) * 1000 + Float(x) * 100 + Float(y) * 10 + Float(k)).bitPattern)
      }
      try machine.dispatch(groups: (1, 1, 1))
      let out = try #require(machine.stageOutputs[0], "\(name)")
      let got = out.map { Float(bitPattern: UInt32(truncatingIfNeeded: $0)) }
      let want = (0..<4).map { 2 * (Float(9000 + 500 + 70) + Float($0)) }
      #expect(got == want, "\(name): got \(got), wanted \(want)")
    }
  }

}
