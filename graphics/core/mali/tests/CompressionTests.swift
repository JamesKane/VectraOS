// SPDX-License-Identifier: BSD-3-Clause

// Which images the Mali backend makes AFBC, and the CRC tables of its colour targets (gpucore(2), "The Mali backend").

import GPUCore
import MaliCore
import MaliFakeTransport
import Testing

@testable import GPUCoreMali

@Suite struct CompressionTests {
  @Test func aTargetNothingCopiesIsAFBCAndAnyOtherIsLinear() throws {
    let (gpu, _) = try device()
    func kind(_ f: PixelFormat, _ u: ImageUsage, _ w: Int32 = 64, layers: UInt32 = 1) throws -> ImageLayoutKind {
      let i = try gpu.makeImage(ImageDescriptor(format: f, width: w, height: w, layers: layers, usage: u))
      return gpu.images[i.handle]!.layout.kind
    }
    #expect(try kind(.rgba8, .renderTarget | .sampled) == .afbc)
    #expect(try kind(.bgra8, .renderTarget) == .afbc)
    #expect(try kind(.depth32f, .depthStencilTarget) == .afbc)
    #expect(try kind(.depth16, .depthStencilTarget | .sampled) == .afbc)
    // A copy, a storage image, another process's window, a small or layered image, a combined depth and stencil: linear.
    #expect(try kind(.rgba8, .renderTarget | .copySource) == .linear)
    #expect(try kind(.rgba8, .renderTarget | .storage) == .linear)
    #expect(try kind(.rgba8, .renderTarget, 8) == .linear)
    #expect(try kind(.rgba8, .renderTarget, layers: 2) == .linear)
    #expect(try kind(.depth24stencil8, .depthStencilTarget) == .linear)
    gpu.afbc = false
    #expect(try kind(.rgba8, .renderTarget) == .linear)
  }

  @Test func aColourTargetHasACRCTableAndAKernelsWriteInvalidatesIt() throws {
    let (gpu, _) = try device()
    let target = try gpu.makeImage(ImageDescriptor(format: .rgba8, width: 64, height: 64, usage: .renderTarget | .copyDestination))
    let record = gpu.images[target.handle]!
    let table = try #require(record.crc)
    #expect(table.rowStride == 64 && table.region.size >= 64 * 4)
    let before = record.crcCounter
    var list = GPUCommandList()
    list.clear(target, color: .float(1, 0, 0, 1))
    try gpu.run(list, signal: 1)
    #expect(record.crcCounter == before &+ 1, "a clear kernel wrote it")
    let storage = try gpu.makeImage(ImageDescriptor(format: .rgba8, width: 64, height: 64, usage: .renderTarget | .storage))
    #expect(gpu.images[storage.handle]!.crc == nil, "a storage image's bytes change behind any table")
  }
}
