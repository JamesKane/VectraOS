// SPDX-License-Identifier: BSD-3-Clause

// The core's heap on Mali over a fake transport (gpucore(2)): sampled images made linear with their plane
// descriptor, `writeTexture` and `writeSampler` as MaliCore's descriptors in the heap, and a draw whose fragment
// shader samples given a copy of the heap with the resource table, the handles and the root pointer a shader reads.

import GPUCore
import MaliFakeTransport
import MaliCore
import ShaderTestKit
import Testing

@testable import GPUCoreMali

/// A fragment shader that samples texture binding 0 with sampler binding 1 at a fixed coordinate.
/// layout(set = 0, binding = 0) uniform texture2D tex; layout(set = 0, binding = 1) uniform sampler smp;
/// layout(location = 0) out vec4 col;
/// void main() { col = textureLod(sampler2D(tex, smp), vec2(0.5), 0.0); }
let samplingFragment = """
  OpCapability Shader
  OpMemoryModel Logical GLSL450
  OpEntryPoint Fragment %main "main" %col
  OpExecutionMode %main OriginUpperLeft
  OpDecorate %col Location 0
  OpDecorate %tex DescriptorSet 0
  OpDecorate %tex Binding 0
  OpDecorate %smp DescriptorSet 0
  OpDecorate %smp Binding 1
  \(Corpus.graphicsPrelude)
  %col = OpVariable %ptr_out_v4 Output
  %img = OpTypeImage %float 1 0 0 0 1 0
  %samp = OpTypeSampler
  %simg = OpTypeSampledImage %img
  %ptr_uc_img = OpTypePointer UniformConstant %img
  %ptr_uc_samp = OpTypePointer UniformConstant %samp
  %tex = OpVariable %ptr_uc_img UniformConstant
  %smp = OpVariable %ptr_uc_samp UniformConstant
  %c = OpConstantComposite %v2float %fhalf %fhalf
  %main = OpFunction %void None %fn
  %entry = OpLabel
  %image = OpLoad %img %tex
  %sampler = OpLoad %samp %smp
  %si = OpSampledImage %simg %image %sampler
  %t = OpImageSampleExplicitLod %v4float %si %c 2 %f0
  OpStore %col %t
  OpReturn
  OpFunctionEnd
  """

func samplingPipeline(_ gpu: MaliDevice) throws -> GPUPipeline {
  try gpu.makeGraphicsPipeline(GraphicsPipelineDescriptor(
    vertex: bytes(try assemble(Corpus.varyingVertex)), fragment: bytes(try assemble(samplingFragment)), colorFormats: [.rgba8]))
}

/// A pass of one draw of `pipeline` into a fresh 64 x 64 target.
func drawList(_ gpu: MaliDevice, _ pipeline: GPUPipeline) throws -> GPUCommandList {
  let target = try gpu.makeImage(ImageDescriptor(format: .rgba8, width: 64, height: 64, usage: .renderTarget))
  var list = GPUCommandList()
  list.render(RenderingInfo(colors: [Attachment(image: target, load: .dontCare)])) { r in
    r.draw(pipeline, root: 0x1000, vertices: 3)
  }
  return list
}

/// Every word, as 32 bits, of every buffer the transport saw at its submits.
func allWords(_ t: FakeTransport) -> [UInt32] { t.memory.flatMap { $0 } }

@Suite struct HeapTests {
  @Test func theDeviceSaysItSamplesAndHowManySlotsTheHeapHas() throws {
    let (gpu, _) = try device()
    #expect(gpu.limits.features.sampledImages)
    #expect(gpu.limits.heapTextures == 4096 && gpu.limits.heapSamplers == 16)
    #expect(gpu.limits.features.storageImages && gpu.limits.heapStorageImages == 1024)
  }

  @Test func aSampledImageIsLinearWithItsPlaneDescriptorAfterTheTexels() throws {
    let (gpu, t) = try device()
    let d = ImageDescriptor(format: .bgra8, width: 5, height: 3, usage: .sampled | .copyDestination | .copySource)
    let image = try gpu.makeImage(d)
    let record = gpu.images[image.handle]!
    // Rows of 20 bytes in a stride of 64; the surface of 192 bytes; the plane after it.
    #expect(record.rowStride == 64 && record.planeAt == 192)
    let buffer = t.bound.first { $0.address == record.region.address }!.buffer
    func word(_ i: Int) -> UInt32 { buffer.pointer.load(fromByteOffset: 192 + 4 * i, as: UInt32.self) }
    #expect(word(0) & 0xF == PlaneDescriptor.typeTag)
    #expect(word(0) >> 8 & 0xF == ImageLayoutKind.linear.clumpOrdering)
    #expect(word(2) == UInt32(truncatingIfNeeded: record.region.address))
    #expect(word(4) & 0x7FF_FFFF == 64)
    #expect(word(7) == UInt32(5 - 1) | UInt32(3 - 1) << 16)
    // The CPU's copies use the same stride.
    let up = try gpu.allocate(.upload, bytes: 60)
    let back = try gpu.allocate(.readback, bytes: 60)
    let u = up.pointer!.assumingMemoryBound(to: UInt8.self)
    for i in 0..<60 { u[i] = UInt8(i + 1) }
    var list = GPUCommandList()
    list.copy(up, to: image)
    list.barrier()
    list.copy(image, to: back)
    try gpu.run(list, signal: 1)
    let b = back.pointer!.assumingMemoryBound(to: UInt8.self)
    #expect((0..<60).allSatisfy { b[$0] == UInt8($0 + 1) })
  }

  @Test func anImageWithoutTheSampledUsageHasNoPlaneAndIsNotATexture() throws {
    let (gpu, _) = try device()
    let plain = try gpu.makeImage(ImageDescriptor(format: .rgba8, width: 4, height: 4, usage: .copyDestination))
    #expect(gpu.images[plain.handle]!.planeAt == nil)
    #expect(throws: GPUError.self) { try gpu.writeTexture(0, plain) }
  }

  @Test func theFormatsTheTextureUnitIsGiven() throws {
    let (gpu, _) = try device()
    for format in [PixelFormat.rgba8, .bgra8, .bgra8srgb, .r8] {
      let image = try gpu.makeImage(ImageDescriptor(format: format, width: 8, height: 8, usage: .sampled))
      try gpu.writeTexture(0, image)
      let first = gpu.textureWords[0]
      #expect(first & 0xF == TextureDescriptor.typeTag)
      #expect(first >> 10 == format.texelFormat!.word)
    }
    // The sRGB view's bit is in the format word (05 section 5.3): the texture unit decodes on read.
    let srgb = try gpu.makeImage(ImageDescriptor(format: .bgra8srgb, width: 8, height: 8, usage: .sampled))
    try gpu.writeTexture(1, srgb)
    #expect(gpu.textureWords[8] >> 10 & 0x3F_FFFF == (TexelFormat.bgra8srgb.word) )
  }

  @Test func writeTextureStoresMaliCoresDescriptorAtItsSlot() throws {
    let (gpu, _) = try device()
    let image = try gpu.makeImage(ImageDescriptor(format: .rgba8, width: 16, height: 8, usage: .sampled))
    try gpu.writeTexture(2, image)
    let record = gpu.images[image.handle]!
    let expected = try TextureDescriptor(image: record.layout, surfaces: record.region.address + UInt64(record.planeAt!)).words()
    #expect(Array(gpu.textureWords[16..<24]) == expected)
    // The slots before it are empty, and the array grows no further.
    #expect(gpu.textureWords.count == 24 && gpu.textureWords[0..<16].allSatisfy { $0 == 0 })
    // The width and height are in the descriptor: 16 - 1 and 8 - 1.
    #expect(expected[1] == 15 | 7 << 16)
    // Another write replaces the slot.
    let other = try gpu.makeImage(ImageDescriptor(format: .rgba8, width: 4, height: 4, usage: .sampled))
    try gpu.writeTexture(2, other)
    #expect(gpu.textureWords[17] == 3 | 3 << 16)
  }

  @Test func theSlotsAndTheImagesAreChecked() throws {
    let (gpu, _) = try device()
    let image = try gpu.makeImage(ImageDescriptor(format: .rgba8, width: 4, height: 4, usage: .sampled))
    try gpu.writeTexture(4095, image)
    #expect(throws: GPUError.self) { try gpu.writeTexture(4096, image) }
    #expect(throws: GPUError.self) { try gpu.writeTexture(0, GPUImage(handle: 99, descriptor: ImageDescriptor(format: .rgba8, width: 4, height: 4, usage: .sampled))) }
    try gpu.writeSampler(15, SamplerDescriptor())
    #expect(throws: GPUError.self) { try gpu.writeSampler(16, SamplerDescriptor()) }
    #expect(throws: GPUError.self) { try gpu.writeStorageImage(0, image) }
  }

  @Test func writeSamplerStoresMaliCoresWordsForTheFilterAndTheWrap() throws {
    let (gpu, _) = try device()
    try gpu.writeSampler(1, SamplerDescriptor(filter: .nearest, addressMode: .repeat))
    #expect(Array(gpu.samplerWords[8..<16]) == (try SamplerWords(wrapS: .repeat, wrapT: .repeat, wrapR: .repeat, minFilter: .nearest, magFilter: .nearest).words()))
    try gpu.writeSampler(1, SamplerDescriptor(filter: .linear, addressMode: .mirroredRepeat))
    #expect(Array(gpu.samplerWords[8..<16]) == (try SamplerWords(wrapS: .mirroredRepeat, wrapT: .mirroredRepeat, wrapR: .mirroredRepeat, minFilter: .linear, magFilter: .linear).words()))
    // Slot 0 is untouched.
    #expect(gpu.samplerWords[0..<8].allSatisfy { $0 == 0 })
  }

  @Test func aSamplingDrawGetsACopyOfTheHeapAsATableOfTheResourceTable() throws {
    let (gpu, t) = try device()
    let image = try gpu.makeImage(ImageDescriptor(format: .rgba8, width: 16, height: 16, usage: .sampled))
    try gpu.writeTexture(2, image)
    try gpu.writeSampler(0, SamplerDescriptor(filter: .nearest))
    let pipeline = try samplingPipeline(gpu)
    try gpu.graphicsQueue.submit(try drawList(gpu, pipeline), wait: 0, signal: 1)
    let words = allWords(t)
    // The heap's copy: the 16 samplers, then 3 textures.
    let heapBytes = UInt32((16 + 3) * 32)
    var tables: [(address: UInt64, flag: UInt32)] = []
    for i in 0..<words.count - 3 where words[i + 2] == heapBytes && words[i + 3] == 0 && words[i + 1] >> 24 == 1 {
      tables.append((UInt64(words[i]) | UInt64(words[i + 1] & 0xFF_FFFF) << 32, words[i + 1] >> 24))
    }
    #expect(tables.count == 1)
    // The heap is in memory the VM maps (it has been let go since; the transport kept what it held at the submit).
    let heapAt = tables[0].address
    #expect(heapAt & 63 == 0)
    // The fragment shader's FAU block names the textures' first entry (16) and the samplers' (0) in table 1.
    let textureHandle = DescriptorHeap.handle(index: 16)
    let samplerHandle = DescriptorHeap.handle(index: 0)
    #expect(textureHandle == 0x0100_0010 && samplerHandle == 0x0100_0000)
    #expect(words.contains(textureHandle) && words.contains(samplerHandle))
  }

  @Test func theHeapCopyHoldsTheTexturesDescriptor() throws {
    let (gpu, t) = try device()
    let image = try gpu.makeImage(ImageDescriptor(format: .rgba8, width: 16, height: 16, usage: .sampled))
    try gpu.writeTexture(0, image)
    let record = gpu.images[image.handle]!
    let descriptor = try TextureDescriptor(image: record.layout, surfaces: record.region.address + UInt64(record.planeAt!)).words()
    let pipeline = try samplingPipeline(gpu)
    try gpu.graphicsQueue.submit(try drawList(gpu, pipeline), wait: 0, signal: 1)
    // The descriptor, then the 16 samplers' 512 bytes before it, are in a copy the pass was given.
    let words = allWords(t)
    var found = false
    for i in 0..<words.count - 8 where Array(words[i..<i + 8]) == descriptor { found = true }
    #expect(found)
  }

  @Test func aDrawThatSamplesNothingIsGivenNoHeap() throws {
    let (gpu, t) = try device()
    try gpu.writeSampler(0, SamplerDescriptor())
    let before = t.created
    try gpu.graphicsQueue.submit(try drawList(gpu, try trianglePipeline(gpu)), wait: 0, signal: 1)
    let plainBuffers = t.created - before
    let (gpu2, t2) = try device()
    let pipeline = try samplingPipeline(gpu2)
    let before2 = t2.created
    try gpu2.graphicsQueue.submit(try drawList(gpu2, pipeline), wait: 0, signal: 1)
    // The same pass, and the sampling draw's one more: the heap's copy.
    #expect(t2.created - before2 == plainBuffers + 1)
  }

  /// Every address the pass reads through (the resource table's heap, a texture's plane array, the plane's texels) is
  /// inside memory the VM maps: an address nothing maps is a GPU MMU fault.
  @Test func everyAddressTheSamplingPassNamesIsInABoundRegion() throws {
    let (gpu, t) = try device()
    let image = try gpu.makeImage(ImageDescriptor(format: .rgba8, width: 8, height: 8, usage: .sampled | .copyDestination))
    try gpu.writeTexture(2, image)
    try gpu.writeSampler(0, SamplerDescriptor())
    try gpu.graphicsQueue.submit(try drawList(gpu, try samplingPipeline(gpu)), wait: 0, signal: 1)
    let regions = t.boundAtSubmit
    #expect(regions.count == t.memory.count)
    func inside(_ address: UInt64, _ bytes: UInt64) -> Bool {
      regions.contains { address >= $0.address && address + bytes <= $0.address + UInt64($0.size) }
    }
    func word(_ address: UInt64) -> UInt32? {
      for (i, r) in regions.enumerated() where address >= r.address && address + 4 <= r.address + UInt64(r.size) {
        return t.memory[i][Int(address - r.address) / 4]
      }
      return nil
    }
    let heapBytes = UInt32((16 + 3) * 32)
    var tables: [(address: UInt64, size: UInt64)] = []
    for m in t.memory {
      for i in 0..<m.count - 3 where m[i + 2] == heapBytes && m[i + 3] == 0 && m[i + 1] >> 24 == 1 {
        tables.append((UInt64(m[i]) | UInt64(m[i + 1] & 0xFF_FFFF) << 32, UInt64(heapBytes)))
      }
    }
    try #require(tables.count == 1)
    // The heap, whole.
    #expect(inside(tables[0].address, tables[0].size))
    // The texture's descriptor at its slot: its plane array, and the plane's texels.
    let entry = tables[0].address + UInt64(16 + 2) * 32
    let surfaces = UInt64(try #require(word(entry + 16))) | UInt64(try #require(word(entry + 20))) << 32
    #expect(inside(surfaces, 32))
    let record = gpu.images[image.handle]!
    #expect(surfaces == record.region.address + UInt64(record.planeAt!))
    let size = UInt64(try #require(word(surfaces + 4))) | UInt64(try #require(word(surfaces + 12)) >> 16) << 32
    let texels = UInt64(try #require(word(surfaces + 8))) | UInt64(try #require(word(surfaces + 12)) & 0xFFFF) << 32
    #expect(texels == record.region.address && size == UInt64(record.layout.levels[0].surfaceStride))
    #expect(inside(texels, size))
  }
}
