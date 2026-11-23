// SPDX-License-Identifier: BSD-3-Clause

// The heap's texel buffers on the Mali backend over the fake transport (gpucore(2), malicore(2); valhall 03 3.4.1, 3.5): the Buffer
// descriptors a view makes in table 2, the handles a shader's bindings hold, and what the device says it can take.

import GPUCore
import MaliFakeTransport
import Testing

@testable import GPUCoreMali

private func unsupported(_ body: () throws -> Void) -> Bool {
  do { try body() } catch let e as GPUError {
    if case .unsupported = e { return true }
  } catch {}
  return false
}

private func invalid(_ body: () throws -> Void) -> Bool {
  do { try body() } catch let e as GPUError {
    if case .invalid = e { return true }
  } catch {}
  return false
}

@Suite struct MaliTexelBufferTests {
  @Test func aViewIsABufferDescriptorOfTheStructureTypeAfterTheStorageImagesInTable2() throws {
    let (gpu, _) = try device()
    let memory = try gpu.allocate(.upload, bytes: 4096)
    try gpu.writeTexelBuffer(3, BufferView(memory, format: .r32float, offset: 16, range: 256))
    try gpu.writeStorageTexelBuffer(2, BufferView(memory, format: .rgba8, offset: 64, range: 1024))
    // Uniform slot 3 is table 2's slot 1024 + 3, 32 bytes each: type 9 with buffer type 3, the size, the address, the stride, the size's high
    // half, and the 22-bit pixel format word (R32F: index 167, order RGB1).
    let a = Array(gpu.storageWords[((1024 + 3) * 8)..<((1024 + 3) * 8 + 8)])
    #expect(a[0] == 9 | 3 << 4 && a[1] == 256)
    #expect(UInt64(a[2]) | UInt64(a[3]) << 32 == memory.address + 16)
    #expect(a[4] == 4 && a[5] == 0 && a[6] == 0 && a[7] == 16 | 167 << 12)
    // Storage slot 2 is slot 2048 + 2: RGBA8 (index 187, order RGBA), four bytes a texel.
    let b = Array(gpu.storageWords[((2048 + 2) * 8)..<((2048 + 2) * 8 + 8)])
    #expect(b[0] == 9 | 3 << 4 && b[1] == 1024 && b[4] == 4 && b[7] == 187 << 12)
    #expect(UInt64(b[2]) | UInt64(b[3]) << 32 == memory.address + 64)
    // The storage images' slots, and the other texel slots, are untouched.
    #expect(gpu.storageWords[0..<(1024 * 8)].allSatisfy { $0 == 0 })
    // BGRA8 is the same index with the order BGRA.
    try gpu.writeTexelBuffer(0, BufferView(memory, format: .bgra8, range: 64))
    #expect(gpu.storageWords[1024 * 8 + 7] == 4 | 187 << 12)
  }

  @Test func theDeviceTakesTheFormatsOfTheSpecificationsTable() throws {
    let (gpu, _) = try device()
    let l = gpu.limits
    #expect(l.features.uniformTexelBuffers && l.features.storageTexelBuffers)
    #expect(l.heapTexelBuffers == 1024 && l.heapStorageTexelBuffers == 1024 && l.maxTexelBufferElements > 65536)
    for f in [PixelFormat.r8, .rg8, .rgba8, .bgra8, .rgba8snorm, .r16float, .rgba16uint, .r32float, .r32sint, .rg32uint, .rgba32float, .rgb10a2unorm] {
      let c = l.formats(f)
      #expect(c.texelBuffer && c.storageTexelBuffer, "\(f)")
    }
    // Atomics on the 32-bit one-channel integers only.
    for f in [PixelFormat.r32uint, .r32sint] { #expect(l.formats(f).storageTexelBufferAtomic, "\(f)") }
    for f in [PixelFormat.r32float, .rgba8] { #expect(!l.formats(f).storageTexelBufferAtomic, "\(f)") }
    for f in [PixelFormat.depth16, .stencil8, .rgba8srgb, .bgra8srgb, .bc1rgb, .etc2rgb8] {
      let c = l.formats(f)
      #expect(!c.texelBuffer && !c.storageTexelBuffer && !c.storageTexelBufferAtomic, "\(f)")
    }
    let memory = try gpu.allocate(.upload, bytes: 256)
    #expect(unsupported { try gpu.writeTexelBuffer(0, BufferView(memory, format: .rgba8srgb)) })
    #expect(invalid { try gpu.writeTexelBuffer(0, BufferView(memory, format: .depth16)) })
    #expect(invalid { try gpu.writeTexelBuffer(0, BufferView(memory, format: .rgba8, range: 7)) })
    #expect(invalid { try gpu.writeTexelBuffer(1024, BufferView(memory, format: .rgba8)) })
    #expect(invalid { try gpu.writeStorageTexelBuffer(1024, BufferView(memory, format: .rgba8)) })
  }

  @Test func aComputeShaderNamesTheArraysByTheirHandlesInTheOneTable() throws {
    let (gpu, t) = try device()
    let source = try gpu.allocate(.upload, bytes: 64)
    let target = try gpu.allocate(.upload, bytes: 64)
    try gpu.writeTexelBuffer(0, BufferView(source, format: .r32uint))
    try gpu.writeStorageTexelBuffer(0, BufferView(target, format: .r32uint))
    let pipeline = try gpu.makeComputePipeline(spirv: try spirv("texelbuffer.comp"))
    _ = try gpu.makeComputePipeline(spirv: try spirv("texelorder.comp"))
    _ = try gpu.makeComputePipeline(spirv: try spirv("texelfill.comp"))
    var list = GPUCommandList()
    list.dispatch(pipeline, root: 0, x: 1, y: 1, z: 1)
    try gpu.graphicsQueue.submit(list, wait: 0, signal: 1)
    // The FAU holds binding 3's handle (table 2, slot 1024) and binding 4's (slot 2048): 0x02000400 and 0x02000800; and the dispatch's
    // snapshot of table 2 holds the descriptors where those handles say.
    var uniform = false, storage = false, snapshot = false
    for (_, words) in zip(t.boundAtSubmit, t.memory.suffix(t.boundAtSubmit.count)) {
      for w in words {
        if w == 0x0200_0400 { uniform = true }
        if w == 0x0200_0800 { storage = true }
      }
      for i in 0..<max(words.count - 8, 0) where words[i] == 9 | 3 << 4 && words[i + 1] == 64 && words[i + 4] == 4 { snapshot = true }
    }
    #expect(uniform && storage && snapshot)
  }
}
