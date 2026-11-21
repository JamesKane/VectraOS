// SPDX-License-Identifier: BSD-3-Clause

// The lowering on GLSL-made Vulkan programs (shaders/, built by `vx shaders`): each lowers, the compiler takes the
// result (the IR as lowered, and optimised with and without vectors), and the IR interpreter runs it over memory laid
// out as the ABI says, against what the program's GLSL means worked out by hand.

import ShaderCompiler
import ShaderTestKit
import Testing
import ValhallBackend
import VulkanLowering

private let buffers01 = SetLayout(bindings: [
  DescriptorBinding(binding: 0, kind: .storageBuffer), DescriptorBinding(binding: 1, kind: .storageBuffer),
])

/// The program's words checked for what no lowered program has: a variable in Uniform or StorageBuffer, a push
/// constant that isn't the core's one reference, an addressing model but PhysicalStorageBuffer64.
private func expectCoreShaped(_ words: [UInt32], pushBlocks: Int = 1, sourceLocation: SourceLocation = #_sourceLocation) {
  var pushVariables = 0
  var typeStorage: [UInt32: UInt32] = [:]
  for t in instructions(words, op: 32) { typeStorage[t[0]] = t[1] }
  for v in instructions(words, op: 59) {
    let storage = v[2]
    #expect(storage != 2 && storage != 12, "a variable in Uniform or StorageBuffer", sourceLocation: sourceLocation)
    if storage == 9 { pushVariables += 1 }
  }
  #expect(pushVariables == pushBlocks, "push-constant variables", sourceLocation: sourceLocation)
  let model = instructions(words, op: 14)
  #expect(model.count == 1 && model[0][0] == 5348, "the addressing model", sourceLocation: sourceLocation)
  let caps = instructions(words, op: 17).map { $0[0] }
  #expect(caps.contains(5347) && caps.contains(11), "PhysicalStorageBufferAddresses and Int64", sourceLocation: sourceLocation)
}

@Suite struct ComputeLoweringTests {
  /// out[i] = in[i] * scale + i for i < min(count, in length, out length).
  private func runSaxpy(count: UInt32, inLength: Int, outLength: Int) throws {
    let layout = LoweringLayout(sets: [buffers01], pushConstantBytes: 8)
    let words = try lowered("saxpy.comp", stage: .compute, layout: layout)
    expectCoreShaped(words)
    let input = (0..<inLength).map { Float($0) * 0.5 - 3 }
    let sentinel: Float = -7777
    for (name, ir) in try compile(words) {
      let machine = Machine(ir)
      var mem = FakeMemory(machine)
      let inAddress = mem.place(bytes(input))
      // The output buffer holds more than its descriptor's range says: nothing past the range may change.
      let outAddress = mem.place(bytes([Float](repeating: sentinel, count: outLength + 32)))
      var record: [UInt8] = []
      record += bufferDescriptor(inAddress, range: 4 * inLength)
      record += bufferDescriptor(outAddress, range: 4 * outLength)
      #expect(record.count == layout.sets[0]!.size)
      let set = mem.place(record)
      var push: [UInt8] = []
      push += f32(2.5)
      push += le(UInt64(count), bytes: 4)
      let rootAddress = mem.root(sets: [set], push: push)
      machine.push = le(rootAddress, bytes: 8)
      try machine.dispatch(groups: (2, 1, 1))
      let got = floats(mem.read(outAddress))
      let live = Int(min(UInt32(inLength), min(UInt32(outLength), count)))
      var want = [Float](repeating: sentinel, count: outLength + 32)
      for i in 0..<live { want[i] = input[i] * 2.5 + Float(i) }
      #expect(got == want, "\(name)")
    }
  }

  @Test func twoStorageBuffersAndAPushConstant() throws {
    try runSaxpy(count: 98, inLength: 100, outLength: 96)
  }

  @Test func theBuffersRangesBoundTheWork() throws {
    // OpArrayLength is the descriptor's range over the stride: the input's 40 elements and the push constant's 17.
    try runSaxpy(count: 128, inLength: 40, outLength: 100)
    try runSaxpy(count: 17, inLength: 100, outLength: 100)
  }

  @Test func anArrayOfBuffersIsIndexedThroughTheSetRecord() throws {
    let layout = LoweringLayout(
      sets: [SetLayout(bindings: [DescriptorBinding(binding: 0, kind: .storageBuffer, count: 3)])], pushConstantBytes: 4)
    let words = try lowered("arrayed.comp", stage: .compute, layout: layout)
    expectCoreShaped(words)
    let a: [UInt32] = (0..<8).map { UInt32($0) + 1 }
    let b: [UInt32] = (0..<8).map { UInt32($0) * 3 }
    for which in 0..<3 {
      for (name, ir) in try compile(words) {
        let machine = Machine(ir)
        var mem = FakeMemory(machine)
        let addresses = [mem.place(bytes(a)), mem.place(bytes(b)), mem.place(bytes([UInt32](repeating: 99, count: 8)))]
        var record: [UInt8] = []
        for x in addresses { record += bufferDescriptor(x, range: 32) }
        let set = mem.place(record)
        let root = mem.root(sets: [set], push: le(UInt64(which), bytes: 4))
        machine.push = le(root, bytes: 8)
        try machine.dispatch(groups: (1, 1, 1))
        // words[which][i] = words[0][i] + 10 * words[1][i], and the other two are as they were.
        var want = [a, b, [UInt32](repeating: 99, count: 8)]
        for i in 0..<8 { want[which][i] = a[i] &+ 10 &* b[i] }
        for k in 0..<3 { #expect(ShaderTestKit.words(mem.read(addresses[k])) == want[k], "buffer \(k) with which = \(which), \(name)") }
      }
    }
  }
}

@Suite struct FragmentLoweringTests {
  private static let texturedLayout = LoweringLayout(
    sets: [
      nil,
      SetLayout(bindings: [
        DescriptorBinding(binding: 0, kind: .uniformBuffer), DescriptorBinding(binding: 1, kind: .combinedImageSampler),
      ]),
    ])

  @Test func aUniformBufferAndACombinedImageSampler() throws {
    let words = try lowered("textured.frag", stage: .fragment, layout: Self.texturedLayout)
    expectCoreShaped(words)
    // A constant element: nothing is NonUniform, and no capability for it is declared.
    #expect(instructions(words, op: 71).filter { $0[1] == 5300 }.isEmpty)
    // The heap: a runtime array of texture2D at set 0, binding 0 and one of samplers at binding 1.
    let bindings = instructions(words, op: 71).filter { $0[1] == 33 }.map { $0[2] }.sorted()
    #expect(bindings == [0, 1])
    for (name, ir) in try compile(words) {
      let machine = Machine(ir)
      var mem = FakeMemory(machine)
      // std140: tint at 0, gain at 16.
      let params = mem.place(f32(0.5, 1, 2, 4, 0.25, 0, 0, 0))
      var record = bufferDescriptor(params, range: 32)
      record += slotDescriptor(7, 3)
      let set1 = mem.place(record)
      // Set 0 isn't in the layout: its slot in the root block is never read.
      let root = mem.root(sets: [0, set1])
      machine.push = le(root, bytes: 8)
      machine.stageInputs[0] = [UInt64(Float(3).bitPattern), UInt64(Float(5).bitPattern)]
      // The texel at (x, y) of the heap texture t with sampler s, component k: (k + 1) * t + 0.5 x + 0.25 y + 100 s.
      machine.texelModel = { image, sampler, operands, k in
        let x = Float(bitPattern: UInt32(truncatingIfNeeded: operands[0]))
        let y = Float(bitPattern: UInt32(truncatingIfNeeded: operands[1]))
        return UInt64((Float(k + 1) * Float(image) + 0.5 * x + 0.25 * y + 100 * Float(sampler)).bitPattern)
      }
      try machine.dispatch(groups: (1, 1, 1))
      let out = try #require(machine.stageOutputs[0], "\(name)")
      let tint: [Float] = [0.5, 1, 2, 4]
      var want: [Float] = []
      for k in 0..<4 { want.append((Float(k + 1) * 7 + 1.5 + 1.25 + 300) * tint[k] * 0.25) }
      let got = out.map { Float(bitPattern: UInt32(truncatingIfNeeded: $0)) }
      #expect(got == want, "\(name): got \(got), wanted \(want)")
    }
  }

  @Test func aHandleThatDiffersBetweenLanesIsNonUniform() throws {
    let layout = LoweringLayout(
      sets: [
        SetLayout(bindings: [DescriptorBinding(binding: 0, kind: .sampledImage, count: 4), DescriptorBinding(binding: 1, kind: .sampler)])
      ])
    let words = try lowered("arrayed.frag", stage: .fragment, layout: layout)
    expectCoreShaped(words)
    let caps = instructions(words, op: 17).map { $0[0] }
    #expect(caps.contains(5301) && caps.contains(5302) && caps.contains(5307), "the capabilities of a non-uniform heap index")
    #expect(!instructions(words, op: 71).filter { $0[1] == 5300 }.isEmpty)
    let slots: [UInt32] = [5, 9, 12, 20]
    for which in 0..<4 {
      for (name, ir) in try compile(words) {
        let machine = Machine(ir)
        var mem = FakeMemory(machine)
        var record: [UInt8] = []
        for s in slots { record += slotDescriptor(s) }
        record += slotDescriptor(2)
        let set0 = mem.place(record)
        machine.push = le(mem.root(sets: [set0]), bytes: 8)
        // `which` is the first input (location 0), `uv` the second.
        var which0 = -1
        var uv1 = -1
        for (n, v) in ir.inputs.enumerated() {
          if v.location == 0 { which0 = n }
          if v.location == 1 { uv1 = n }
        }
        machine.stageInputs[which0] = [UInt64(which)]
        machine.stageInputs[uv1] = [UInt64(Float(1).bitPattern), UInt64(Float(2).bitPattern)]
        machine.texelModel = { image, sampler, operands, k in
          UInt64((Float(image) * 1000 + Float(sampler) * 100 + Float(k)).bitPattern)
        }
        try machine.dispatch(groups: (1, 1, 1))
        let out = try #require(machine.stageOutputs[0], "\(name)")
        let got = out.map { Float(bitPattern: UInt32(truncatingIfNeeded: $0)) }
        let want = (0..<4).map { Float(slots[which]) * 1000 + 2 * 100 + Float($0) }
        #expect(got == want, "which = \(which), \(name): got \(got), wanted \(want)")
      }
    }
  }
}

@Suite struct VertexLoweringTests {
  private static let layout = LoweringLayout(
    vertexBindings: [VertexBinding(binding: 0, stride: 16), VertexBinding(binding: 1, stride: 8, perInstance: true)],
    vertexAttributes: [
      VertexAttribute(location: 0, binding: 0, format: .rgb32Float, offset: 0),
      VertexAttribute(location: 1, binding: 0, format: .rgba8Unorm, offset: 12),
      VertexAttribute(location: 2, binding: 1, format: .rg32Float, offset: 0),
    ])

  /// What the buffers hold: four vertices of a float3 and four colour bytes, and three instances' float2.
  private static let vertices: [(pos: [Float], color: [UInt8])] = [
    ([9, 9, 9], [1, 2, 3, 4]), ([1, 2, 3], [255, 128, 0, 64]), ([-4, 0.5, 8], [0, 0, 0, 255]), ([10, 20, 30], [51, 102, 204, 17]),
  ]
  private static let shifts: [[Float]] = [[0.25, -1], [0.5, -0.25], [100, 200]]

  @Test func attributesAreFetchedAndConverted() throws {
    let words = try lowered("geometry.vert", stage: .vertex, layout: Self.layout)
    expectCoreShaped(words)
    // The inputs are gone from the interface: what is left is the built-ins (the index) and the outputs.
    let entry = instructions(words, op: 15)[0]
    let inputsLeft = instructions(words, op: 71).filter { $0[1] == 30 }.map { $0[0] }  // Location
    for v in instructions(words, op: 59) where v[2] == 1 { #expect(!inputsLeft.contains(v[1]), "an Input variable with a Location") }
    #expect(entry.count > 3)
    var vertexBytes: [UInt8] = []
    for v in Self.vertices { vertexBytes += bytes(v.pos) + v.color }
    var instanceBytes: [UInt8] = []
    for s in Self.shifts { instanceBytes += bytes(s) }
    for (name, ir) in try compile(words) {
      var positionOutput = -1
      var colorOutput = -1
      for (n, o) in ir.outputs.enumerated() {
        if o.builtin == 0 { positionOutput = n }
        if o.location == 0 && o.builtin < 0 { colorOutput = n }
      }
      for (vertex, instance) in [(2, 1), (0, 0), (1, 2)] {
        let machine = Machine(ir)
        var mem = FakeMemory(machine)
        let vb0 = mem.place(vertexBytes)
        let vb1 = mem.place(instanceBytes)
        // Binding 0 starts at the second vertex (the buffer's address plus its offset), so VertexIndex 2 reads the
        // buffer's fourth; binding 1 at its start.
        let root = mem.root(vertexBuffers: [vb0 + 16, vb1])
        machine.push = le(root, bytes: 8)
        machine.vertexIndex = UInt64(vertex)
        machine.instanceIndex = UInt64(instance)
        try machine.dispatch(groups: (1, 1, 1))
        let v = Self.vertices[vertex + 1]
        let s = Self.shifts[instance]
        let position = try #require(machine.stageOutputs[positionOutput], "\(name)").map { Float(bitPattern: UInt32(truncatingIfNeeded: $0)) }
        #expect(position == [v.pos[0] + s[0], v.pos[1] + s[1], v.pos[2], 1], "position of vertex \(vertex), instance \(instance), \(name)")
        let color = try #require(machine.stageOutputs[colorOutput], "\(name)").map { Float(bitPattern: UInt32(truncatingIfNeeded: $0)) }
        #expect(color == v.color.map { Float($0) / 255 }, "colour of vertex \(vertex), \(name)")
      }
    }
  }

  @Test func theFormatsConvertAsVulkanSays() throws {
    // The same program over other bindings and formats: a float3 taken from a float4 at an offset, and a float2 from a
    // single float (the missing component is 0), by a binding whose stride is 0.
    let wide = LoweringLayout(
      vertexBindings: [VertexBinding(binding: 3, stride: 32, perInstance: false), VertexBinding(binding: 4, stride: 0, perInstance: true)],
      vertexAttributes: [
        VertexAttribute(location: 0, binding: 3, format: .rgba32Float, offset: 8),
        VertexAttribute(location: 1, binding: 3, format: .rgba8Unorm, offset: 4),
        VertexAttribute(location: 2, binding: 4, format: .r32Float, offset: 0),
      ])
    let words = try lowered("geometry.vert", stage: .vertex, layout: wide)
    let ir = try IRModule.lower(try SPIRVModule.parse(words: words))
    try ir.verify()
    var bytes32 = [UInt8](repeating: 0, count: 32 * 2)
    let pos: [Float] = [1.5, -2, 4, 8]
    for (i, x) in pos.enumerated() { put32(&bytes32, 32 + 8 + 4 * i, x.bitPattern) }
    put32(&bytes32, 32 + 4, 0x40FF_8000)
    let machine = Machine(ir)
    var mem = FakeMemory(machine)
    let vb3 = mem.place(bytes32)
    // Binding 4's stride is 0: every instance reads the same words; the second component is missing, so it is 0.
    let vb4 = mem.place(f32(0.5, 99))
    var roots = [UInt64](repeating: 0, count: 8)
    roots[3] = vb3
    roots[4] = vb4
    machine.push = le(mem.root(vertexBuffers: roots), bytes: 8)
    machine.vertexIndex = 1
    machine.instanceIndex = 7
    try machine.dispatch(groups: (1, 1, 1))
    var positionOutput = 0
    var colorOutput = 0
    for (n, o) in ir.outputs.enumerated() {
      if o.builtin == 0 { positionOutput = n }
      if o.location == 0 && o.builtin < 0 { colorOutput = n }
    }
    let position = machine.stageOutputs[positionOutput]!.map { Float(bitPattern: UInt32(truncatingIfNeeded: $0)) }
    // position.xy + shift, shift = (0.5, 0).
    #expect(position == [2, -2, 4, 1])
    let color = machine.stageOutputs[colorOutput]!.map { Float(bitPattern: UInt32(truncatingIfNeeded: $0)) }
    #expect(color == [0x00, 0x80, 0xFF, 0x40].map { Float($0) / 255 })
  }
}

@Suite struct IntegerVertexLoweringTests {
  @Test func integerAttributesAndTheProgramsOwnIndices() throws {
    // Every vertex is a float, an ivec2 and a uint, in a 20-byte stride; the program also reads its own (signed)
    // VertexIndex and InstanceIndex, which the fetch shares.
    let layout = LoweringLayout(
      vertexBindings: [VertexBinding(binding: 0, stride: 20)],
      vertexAttributes: [
        VertexAttribute(location: 0, binding: 0, format: .r32Float, offset: 0),
        VertexAttribute(location: 1, binding: 0, format: .rg32Sint, offset: 4),
        VertexAttribute(location: 2, binding: 0, format: .r32Uint, offset: 12),
      ])
    let words = try lowered("indexed.vert", stage: .vertex, layout: layout)
    expectCoreShaped(words)
    // The program's own VertexIndex and InstanceIndex are reused: no built-in is declared twice.
    let builtIns = instructions(words, op: 71).filter { $0[1] == 11 }.map { $0[2] }
    #expect(builtIns.filter { $0 == 42 }.count == 1 && builtIns.filter { $0 == 43 }.count == 1)
    var data: [UInt8] = []
    for v in 0..<3 {
      data += f32(0.5 * Float(v + 1))
      data += le(UInt64(UInt32(bitPattern: Int32(-3 - v))), bytes: 4) + le(UInt64(7 * v), bytes: 4)
      data += le(UInt64(100 + v), bytes: 4) + [0, 0, 0, 0]
    }
    for (name, ir) in try compile(words) {
      var position = 0
      var ids = 0
      var flag = 0
      for (n, o) in ir.outputs.enumerated() {
        if o.builtin == 0 { position = n }
        if o.location == 0 && o.builtin < 0 { ids = n }
        if o.location == 1 && o.builtin < 0 { flag = n }
      }
      let machine = Machine(ir)
      var mem = FakeMemory(machine)
      let buffer = mem.place(data)
      machine.push = le(mem.root(vertexBuffers: [buffer]), bytes: 8)
      machine.vertexIndex = 2
      machine.instanceIndex = 3
      try machine.dispatch(groups: (1, 1, 1))
      let p = try #require(machine.stageOutputs[position], "\(name)").map { Float(bitPattern: UInt32(truncatingIfNeeded: $0)) }
      #expect(p == [2, 1.5, 3, 1], "\(name)")
      let i = try #require(machine.stageOutputs[ids], "\(name)").map { Int32(bitPattern: UInt32(truncatingIfNeeded: $0)) }
      #expect(i == [-5, 14], "\(name)")
      let f = try #require(machine.stageOutputs[flag], "\(name)").map { UInt32(truncatingIfNeeded: $0) }
      #expect(f == [105], "\(name)")
    }
  }
}

@Suite struct StorageImageLoweringTests {
  @Test func aStorageImageIsTheHeapsThirdArray() throws {
    let layout = LoweringLayout(sets: [
      SetLayout(bindings: [DescriptorBinding(binding: 0, kind: .storageImage), DescriptorBinding(binding: 1, kind: .uniformBuffer)])
    ])
    let words = try lowered("storage.comp", stage: .compute, layout: layout)
    expectCoreShaped(words)
    // The compiler takes no storage images yet (OpImageWrite), so this is checked as words: the one variable at set 0,
    // binding 2, and the uniform buffer's pointer in PhysicalStorageBuffer.
    let binding = instructions(words, op: 71).filter { $0[1] == 33 }.map { $0[2] }
    #expect(binding == [2])
    let capabilities = instructions(words, op: 17).map { $0[0] }
    #expect(capabilities.contains(5302))
  }
}

@Suite struct PassThroughTests {
  @Test func aProgramWithNothingToLowerIsUnchanged() throws {
    var root = String(#filePath)
    for _ in 0..<7 { root = String(root[..<root.lastIndex(of: "/")!]) }
    for path in ["graphics/loinnir/tests/shaders/triangle.frag.spv"] {
      let bytesIn = try #require(readFile(root + "/" + path), "\(path)")
      let wordsIn = words(bytesIn)
      let layout = LoweringLayout(sets: [SetLayout(bindings: [])])
      let out = try lower(spirv: wordsIn, stage: .fragment, entryPoint: "main", layout: layout)
      #expect(out == wordsIn, "\(path)")
    }
  }
}

@Suite struct LoweringErrorTests {
  @Test func whatTheLayerLeavesOutIsNamed() throws {
    let layout = LoweringLayout(sets: [SetLayout(bindings: [DescriptorBinding(binding: 0, kind: .combinedImageSampler)])])
    #expect(throws: LoweringError.unsupported("a cube image")) {
      _ = try lowered("cube.frag", stage: .fragment, layout: layout)
    }
  }

  @Test func aProgramThatDisagreesWithTheLayoutIsInvalid() throws {
    let noBinding = LoweringLayout(sets: [SetLayout(bindings: [DescriptorBinding(binding: 1, kind: .storageBuffer)])], pushConstantBytes: 8)
    #expect(throws: LoweringError.invalid("binding 0 of set 0 (variable inBuf) is not in the pipeline layout")) {
      _ = try lowered("saxpy.comp", stage: .compute, layout: noBinding)
    }
    let noSet = LoweringLayout(sets: [], pushConstantBytes: 8)
    #expect(throws: LoweringError.invalid("set 0 (variable inBuf) is not in the pipeline layout")) {
      _ = try lowered("saxpy.comp", stage: .compute, layout: noSet)
    }
    let wrongKind = LoweringLayout(
      sets: [SetLayout(bindings: [DescriptorBinding(binding: 0, kind: .uniformBuffer), DescriptorBinding(binding: 1, kind: .storageBuffer)])],
      pushConstantBytes: 8)
    #expect(throws: LoweringError.invalid("binding 0 of set 0 is not the kind of descriptor the program declares")) {
      _ = try lowered("saxpy.comp", stage: .compute, layout: wrongKind)
    }
    let tooMuch = LoweringLayout(sets: [buffers01], pushConstantBytes: 132)
    #expect(throws: LoweringError.invalid("the pipeline layout's push constants (132 bytes) are over 128")) {
      _ = try lowered("saxpy.comp", stage: .compute, layout: tooMuch)
    }
    let noAttribute = LoweringLayout(
      vertexBindings: [VertexBinding(binding: 0, stride: 16)],
      vertexAttributes: [VertexAttribute(location: 0, binding: 0, format: .rgb32Float, offset: 0)])
    #expect(throws: LoweringError.invalid("the vertex input at location 1 has no attribute")) {
      _ = try lowered("geometry.vert", stage: .vertex, layout: noAttribute)
    }
    let mismatch = LoweringLayout(
      vertexBindings: [VertexBinding(binding: 0, stride: 16), VertexBinding(binding: 1, stride: 8, perInstance: true)],
      vertexAttributes: [
        VertexAttribute(location: 0, binding: 0, format: .rgb32Uint, offset: 0),
        VertexAttribute(location: 1, binding: 0, format: .rgba8Unorm, offset: 12),
        VertexAttribute(location: 2, binding: 1, format: .rg32Float, offset: 0),
      ])
    #expect(throws: LoweringError.invalid("the vertex input at location 0 is a float and its attribute is not")) {
      _ = try lowered("geometry.vert", stage: .vertex, layout: mismatch)
    }
    let unaligned = LoweringLayout(
      vertexBindings: [VertexBinding(binding: 0, stride: 16), VertexBinding(binding: 1, stride: 8, perInstance: true)],
      vertexAttributes: [
        VertexAttribute(location: 0, binding: 0, format: .rgb32Float, offset: 2),
        VertexAttribute(location: 1, binding: 0, format: .rgba8Unorm, offset: 12),
        VertexAttribute(location: 2, binding: 1, format: .rg32Float, offset: 0),
      ])
    #expect(throws: LoweringError.invalid("the attribute at location 0: an offset or a stride that isn't a multiple of 4")) {
      _ = try lowered("geometry.vert", stage: .vertex, layout: unaligned)
    }
  }

  @Test func theStageAndTheEntryPointAreChecked() throws {
    let layout = LoweringLayout(sets: [buffers01], pushConstantBytes: 8)
    #expect(throws: LoweringError.invalid("the entry point main is not a vertex shader")) {
      _ = try lowered("saxpy.comp", stage: .vertex, layout: layout)
    }
    #expect(throws: LoweringError.invalid("no entry point named other")) {
      _ = try lowered("saxpy.comp", stage: .compute, layout: layout, entry: "other")
    }
  }

  @Test func wordsThatAreNotSPIRVAreMalformed() throws {
    let layout = LoweringLayout()
    #expect(throws: LoweringError.malformed("shorter than SPIR-V's five-word header")) {
      _ = try lower(spirv: [0x0723_0203], stage: .compute, entryPoint: "main", layout: layout)
    }
    #expect(throws: LoweringError.malformed("bad magic number")) {
      _ = try lower(spirv: [1, 2, 3, 4, 5, 6], stage: .compute, entryPoint: "main", layout: layout)
    }
    var truncated = try shader("saxpy.comp")
    truncated.removeLast(3)
    #expect(throws: LoweringError.self) {
      _ = try lower(spirv: truncated, stage: .compute, entryPoint: "main", layout: LoweringLayout(sets: [buffers01], pushConstantBytes: 8))
    }
  }
}
