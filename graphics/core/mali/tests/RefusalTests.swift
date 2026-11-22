// SPDX-License-Identifier: BSD-3-Clause

// What the Mali backend says it has (D174 amendment): every feature of the amendment is false, its formats are the
// ones it had, and each thing it hasn't is refused with `.unsupported` where the image, the sampler or the pipeline is made.

import GPUCore
import MaliFakeTransport
import ShaderTestKit
import Testing

@testable import GPUCoreMali

private func unsupported(_ body: () throws -> Void) -> Bool {
  do { try body() } catch let e as GPUError {
    if case .unsupported = e { return true }
  } catch {}
  return false
}

@Suite struct MaliRefusals {
  @Test func itReportsOnlyWhatItHad() throws {
    let (gpu, _) = try device()
    let f = gpu.limits.features
    #expect(f.sampledImages && f.multipleDrawsPerPass)
    #expect(f.depth && f.stencil && f.cullModes && f.rasterizerDiscard && !f.generalBlend && f.dynamicState && f.extendedTopologies && f.primitiveRestart)
    #expect(!f.mipmaps && !f.arrayImages && !f.cubeImages && !f.volumeImages && !f.multisample)
    #expect(f.independentBlend && f.multipleColorAttachments && !f.dualSourceBlend && !f.logicOps && !f.fillModeNonSolid && !f.alphaToCoverage && !f.multiview)
    #expect(!f.compressedASTC && !f.compressedETC2 && !f.compressedBC && !f.imageViews)
    #expect(!f.copyImage && !f.blitImage && !f.resolveImage && !f.fillBuffer && !f.updateBuffer && !f.clearImage && !f.clearAttachments)
    #expect(!f.drawIndirectCount && !f.importHandle && !f.specializationConstants)
    #expect(gpu.limits.maxSamples == 1)
    #expect(gpu.limits.formatTable.count == 7)
    for format in PixelFormat.all {
      let caps = gpu.limits.formats(format)
      switch format {
      case .rgba8, .bgra8:
        #expect(caps.sampled && caps.renderTarget && caps.blendable && caps.storage && !caps.storageAtomic && !caps.depthTarget, "\(format)")
      case .bgra8srgb:
        #expect(caps.sampled && caps.renderTarget && caps.blendable && !caps.storage && !caps.depthTarget, "\(format)")
      case .r8:
        #expect(caps.sampled && !caps.renderTarget && caps.storage && !caps.storageAtomic, "\(format)")
      case .depth16, .depth32f, .stencil8:
        var want = FormatCapabilities()
        want.depthTarget = true
        #expect(caps == want, "\(format)")
      default:
        #expect(caps == FormatCapabilities(), "\(format)")
      }
    }
  }

  @Test func itRefusesNewImagesAtCreation() throws {
    let (gpu, _) = try device()
    func image(_ format: PixelFormat = .rgba8, mips: UInt32 = 1, layers: UInt32 = 1, samples: UInt32 = 1, depth: Int32 = 1,
               dimension: ImageDimension = .d2, usage: ImageUsage = .sampled) -> Bool {
      unsupported { _ = try gpu.makeImage(ImageDescriptor(format: format, width: 8, height: 8, depth: depth, mipLevels: mips, layers: layers,
                                                           samples: samples, dimension: dimension, usage: usage)) }
    }
    #expect(image(.depth24stencil8, usage: .depthStencilTarget))
    #expect(image(.depth32f, usage: .depthStencilTarget | .sampled))
    #expect(!image(.depth32f, usage: .depthStencilTarget))
    #expect(!image(.depth16, usage: .depthStencilTarget))
    #expect(!image(.stencil8, usage: .depthStencilTarget))
    #expect(image(.rg8))
    #expect(image(.rgba16float))
    #expect(image(.astc(.b4x4)))
    #expect(image(.etc2rgb8))
    #expect(image(.bc7))
    #expect(image(mips: 4))
    #expect(image(layers: 4))
    #expect(image(layers: 6, dimension: .cube))
    #expect(image(depth: 4, dimension: .d3))
    #expect(image(samples: 4, usage: .renderTarget))
    #expect(!image())
  }

  @Test func itRefusesNewSamplersAndViewsAndImports() throws {
    let (gpu, _) = try device()
    #expect(unsupported { try gpu.writeSampler(0, SamplerDescriptor(addressMode: .clampToBorder)) })
    #expect(unsupported { try gpu.writeSampler(0, SamplerDescriptor(addressMode: .mirrorClampToEdge)) })
    #expect(unsupported { try gpu.writeSampler(0, SamplerDescriptor(mipmapMode: .linear)) })
    #expect(unsupported { try gpu.writeSampler(0, SamplerDescriptor(minFilter: .nearest, magFilter: .linear)) })
    #expect(unsupported { try gpu.writeSampler(0, SamplerDescriptor(addressModeU: .repeat)) })
    #expect(unsupported { try gpu.writeSampler(0, SamplerDescriptor(maxAnisotropy: 4)) })
    #expect(unsupported { try gpu.writeSampler(0, SamplerDescriptor(compare: .less)) })
    try gpu.writeSampler(0, SamplerDescriptor(filter: .nearest, addressMode: .repeat))
    let image = try gpu.makeImage(ImageDescriptor(format: .rgba8, width: 8, height: 8, usage: .sampled))
    try gpu.writeTexture(0, ImageView(image))
    #expect(unsupported { try gpu.writeTexture(1, ImageView(image, format: .rgba8uint)) })
    #expect(unsupported { _ = try gpu.importHandle(5, intent: .upload, bytes: 4096) })
    #expect(unsupported { _ = try gpu.importHandle(5, as: ImageDescriptor(format: .bgra8, width: 8, height: 8, usage: .scanout)) })
    #expect(unsupported { _ = try gpu.makeComputePipeline(spirv: [3, 2, 35, 7] + [UInt8](repeating: 0, count: 16), specialization: [SpecializationConstant(id: 0, bool: true)]) })
  }

  @Test func itRefusesOneDimensionalImagesMappedViewsCustomBordersAndTexelBuffers() throws {
    let (gpu, _) = try device()
    let f = gpu.limits.features
    #expect(!f.images1D && !f.imageSwizzle && !f.customBorderColor && !f.uniformTexelBuffers && !f.storageTexelBuffers)
    #expect(gpu.limits.heapTexelBuffers == 0 && gpu.limits.heapStorageTexelBuffers == 0 && gpu.limits.maxTexelBufferElements == 0)
    #expect(unsupported { _ = try gpu.makeImage(ImageDescriptor(format: .rgba8, width: 8, height: 1, dimension: .d1, usage: .sampled)) })
    // A mapped view is not the whole image, which the device takes only whole.
    let image = try gpu.makeImage(ImageDescriptor(format: .rgba8, width: 8, height: 8, usage: .sampled))
    #expect(unsupported { try gpu.writeTexture(1, ImageView(image, swizzle: ComponentMapping(r: .b, b: .r))) })
    #expect(unsupported { try gpu.writeSampler(0, SamplerDescriptor(addressMode: .clampToBorder, customBorderColor: .float(1, 0, 0, 1))) })
    let memory = try gpu.allocate(.upload, bytes: 256)
    #expect(unsupported { try gpu.writeTexelBuffer(0, BufferView(memory, format: .rgba8)) })
    #expect(unsupported { try gpu.writeStorageTexelBuffer(0, BufferView(memory, format: .rgba8)) })
  }

  @Test func itRefusesNewPipelineStateAtCreation() throws {
    let (gpu, _) = try device()
    let vs = bytes(try assemble(Corpus.varyingVertex))
    let fs = bytes(try assemble(Corpus.varyingFragment))
    func pipeline(_ formats: [PixelFormat] = [.rgba8], topology: PrimitiveTopology = .triangleList,
                  depth: PixelFormat? = nil, raster: RasterizationState = RasterizationState(),
                  multisample: MultisampleState = MultisampleState(), blends: [ColorBlendAttachment]? = nil,
                  dynamic: DynamicStates = DynamicStates()) -> Bool {
      unsupported {
        _ = try gpu.makeGraphicsPipeline(GraphicsPipelineDescriptor(
          vertex: vs, fragment: fs, colorFormats: formats, topology: topology, depthStencilFormat: depth, rasterization: raster,
          multisample: multisample, attachmentBlends: blends, dynamic: dynamic))
      }
    }
    #expect(pipeline(depth: .depth24stencil8))
    #expect(pipeline(raster: RasterizationState(polygonMode: .line)))
    #expect(pipeline(multisample: MultisampleState(samples: 4)))
    // The fixed-function blend stage has one multiplier: minimum and maximum, the saturated source alpha and the second
    // source need a blend shader, which this driver doesn't make.
    #expect(pipeline(blends: [ColorBlendAttachment(enabled: true, srcColor: .one, dstColor: .one, colorOp: .min, alphaOp: .min)]))
    #expect(pipeline(blends: [ColorBlendAttachment(enabled: true, srcColor: .srcAlphaSaturate, dstColor: .one)]))
    #expect(pipeline(blends: [ColorBlendAttachment(enabled: true, srcColor: .src1Color, dstColor: .one)]))
    #expect(pipeline([.rgba16float]))
    // What the fixed-function stage does, it makes.
    for t: PrimitiveTopology in [.lineList, .lineStrip, .pointList, .triangleStrip, .triangleFan] {
      #expect(!pipeline(topology: t))
    }
    #expect(!pipeline(depth: .depth32f))
    #expect(!pipeline([.rgba8, .bgra8, .bgra8srgb]))
    #expect(!pipeline(raster: RasterizationState(cull: .back, depthBias: true, depthClamp: true, rasterizerDiscard: true)))
    #expect(pipeline(blends: [ColorBlendAttachment(enabled: true, srcColor: .one, dstColor: .one)]), "general blend is off until blend shaders")
    #expect(!pipeline(blends: [.alphaOver]))
    #expect(!pipeline(dynamic: .lineWidth | .depthBias))
    // What it had, it still makes.
    _ = try gpu.makeGraphicsPipeline(GraphicsPipelineDescriptor(vertex: vs, fragment: fs, colorFormats: [.bgra8srgb], blend: .opaque))
  }

  @Test func itRefusesNewCommandsInSubmit() throws {
    let (gpu, _) = try device()
    let a = try gpu.makeImage(ImageDescriptor(format: .rgba8, width: 8, height: 8, usage: .copySource | .copyDestination))
    let m = try gpu.allocate(.upload, bytes: 256)
    func refused(_ body: (inout GPUCommandList) -> Void) -> Bool {
      var l = GPUCommandList()
      body(&l)
      return unsupported { try gpu.graphicsQueue.submit(l, wait: 0, signal: 1) } || l.validate(features: gpu.limits.features).map { e in
        if case .unsupported = e { return true } else { return false }
      } == true
    }
    #expect(refused { $0.copyImage(a, to: a, regions: [ImageCopyRegion(dstOffset: Offset3D(x: 4), extent: Extent3D(width: 4, height: 4))]) })
    #expect(refused { $0.fill(m, bytes: 16, value: 0) })
    #expect(refused { $0.update(m, data: [1, 2, 3, 4]) })
    #expect(refused { $0.clear(a, color: .float(0, 0, 0, 0)) })
    #expect(refused { $0.blitImage(a, to: a, regions: [ImageBlitRegion(srcMax: Offset3D(x: 4, y: 4, z: 1), dstMin: Offset3D(x: 4), dstMax: Offset3D(x: 8, y: 8, z: 1))]) })
    #expect(refused { $0.copy(m, to: a, regions: [BufferImageRegion(imageExtent: Extent3D(width: 2, height: 2))]) })
  }
}
