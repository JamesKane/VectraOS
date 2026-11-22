// SPDX-License-Identifier: BSD-3-Clause

// Images, views and samplers of the Mali backend (gpucore(2); valhall 03 sections 3.7 to 3.9, 05): every image is linear in
// memory the CPU maps, one plane for a colour format and one for each aspect of a depth or stencil format, all its mip levels,
// layers and slices in the layout of 05 sections 5.5 and 5.5.4; a heap slot holds a texture descriptor over an array of plane
// descriptors, one for each (layer, level) the view covers (03 section 3.8.3).

import GPUCore

#if canImport(MaliCore)
  import MaliCore
#endif

/// One plane of an image: an aspect's texels, where its layout starts in the image's region.
struct AspectPlane {
  var aspect: ImageAspects
  var layout: ImageLayout
  var offset: Int
  var texel: TexelFormat
}

extension PixelFormat {
  /// The texture unit's format for one aspect of the format, nil for one it isn't given here.
  func texelFormat(aspect: ImageAspects) -> TexelFormat? {
    switch self {
    case .r8: return .r8
    case .r8snorm: return .r8snorm
    case .r8uint: return .r8ui
    case .r8sint: return .r8i
    case .rg8: return .rg8
    case .rg8snorm: return .rg8snorm
    case .rg8uint: return .rg8ui
    case .rg8sint: return .rg8i
    case .rgba8: return .rgba8
    case .rgba8snorm: return .rgba8snorm
    case .rgba8uint: return .rgba8ui
    case .rgba8sint: return .rgba8i
    case .rgba8srgb: return .rgba8srgb
    case .bgra8: return .bgra8
    case .bgra8srgb: return .bgra8srgb
    case .r16float: return .r16f
    case .r16uint: return .r16ui
    case .r16sint: return .r16i
    case .rg16float: return .rg16f
    case .rg16uint: return .rg16ui
    case .rg16sint: return .rg16i
    case .rgba16float: return .rgba16f
    case .rgba16uint: return .rgba16ui
    case .rgba16sint: return .rgba16i
    case .r32float: return .r32f
    case .r32uint: return .r32ui
    case .r32sint: return .r32i
    case .rg32float: return .rg32f
    case .rg32uint: return .rg32ui
    case .rg32sint: return .rg32i
    case .rgba32float: return .rgba32f
    case .rgba32uint: return .rgba32ui
    case .rgba32sint: return .rgba32i
    case .rgb10a2unorm: return .rgb10a2
    case .rg11b10float: return .rg11b10f
    case .rgb9e5: return .rgb9e5
    case .depth16: return aspect == .depth ? .depth16 : nil
    case .depth32f: return aspect == .depth ? .depth32f : nil
    case .depth24stencil8: return aspect == .depth ? .depth24 : aspect == .stencil ? .stencil8 : nil
    case .depth32fstencil8: return aspect == .depth ? .depth32f : aspect == .stencil ? .stencil8 : nil
    case .stencil8: return aspect == .stencil ? .stencil8 : nil
    case .astc(let b): return .astc(blockWidth: b.width, blockHeight: b.height, srgb: false)
    case .astcSRGB(let b): return .astc(blockWidth: b.width, blockHeight: b.height, srgb: true)
    case .etc2rgb8: return .etc2rgb8
    case .etc2rgb8srgb: return .etc2rgb8srgb
    case .etc2rgb8a1: return .etc2rgb8a1
    case .etc2rgb8a1srgb: return .etc2rgb8a1srgb
    case .etc2rgba8: return .etc2rgba8
    case .etc2rgba8srgb: return .etc2rgba8srgb
    case .eacR11: return .eacR11
    case .eacR11snorm: return .eacR11snorm
    case .eacRG11: return .eacRG11
    case .eacRG11snorm: return .eacRG11snorm
    case .bc1rgb: return .bc1rgb
    case .bc1rgbsrgb: return .bc1rgbsrgb
    case .bc1rgba: return .bc1rgba
    case .bc1rgbasrgb: return .bc1rgbasrgb
    case .bc2: return .bc2
    case .bc2srgb: return .bc2srgb
    case .bc3: return .bc3
    case .bc3srgb: return .bc3srgb
    case .bc4: return .bc4
    case .bc4snorm: return .bc4snorm
    case .bc5: return .bc5
    case .bc5snorm: return .bc5snorm
    case .bc6hufloat: return .bc6hu
    case .bc6hsfloat: return .bc6hs
    case .bc7: return .bc7
    case .bc7srgb: return .bc7srgb
    }
  }

  /// The aspect a single-aspect view reads, and the one a colour format's only plane is.
  var firstAspect: ImageAspects { aspects.contains(.color) ? .color : aspects.contains(.depth) ? .depth : .stencil }
}

extension MaliDevice {
  // MARK: Capabilities

  /// The formats, features and limits of images and samplers.
  func installResourceCapabilities(_ l: inout DeviceLimits) {
    // Judged on the board: loinnir-test's ResourceCases (the formats, views, samplers' addressing, level of detail, anisotropy,
    // unnormalized coordinates and comparison, depth and stencil images, copies, blits, clears, compressed formats) and
    // vulkan-test (views, swizzles, 1D images).
    l.features.images1D = true
    l.features.imageViews = true
    l.features.imageSwizzle = true
    installAllResourceCapabilities(&l)
  }

  /// Turns on what the board has not yet judged, for a probe of the hardware (loinnir-test's ResourceCases): separate minification
  /// and magnification filters, and `importHandle`.
  public func probeEnableResources() {
    baseLimits.features.samplerMinMagFilters = true
    baseLimits.features.importHandle = true
  }

  func installAllResourceCapabilities(_ l: inout DeviceLimits) {
    l.maxImageDimension3D = 512
    l.maxImageArrayLayers = 256
    l.maxAnisotropy = 16
    l.features.mipmaps = true
    l.features.arrayImages = true
    l.features.cubeImages = true
    l.features.volumeImages = true
    l.features.depth = true
    l.features.stencil = true
    l.features.samplerAnisotropy = true
    l.features.samplerCompare = true
    l.features.samplerBorder = true
    l.features.customBorderColor = true
    l.features.unnormalizedCoordinates = true
    l.features.samplerAxisAddressModes = true
    l.features.samplerMirrorClampToEdge = true
    l.features.copyImage = true
    l.features.blitImage = true
    l.features.imageRegionCopies = true
    l.features.fillBuffer = true
    l.features.updateBuffer = true
    l.features.clearImage = true
    // The sampled formats: the texture unit's reads of 05 section 5.3.7's table. Integer formats filter by nearest only.
    var sampled = FormatCapabilities()
    sampled.sampled = true
    sampled.filterable = true
    sampled.blitSource = true
    sampled.blitDestination = true
    var integer = sampled
    integer.filterable = false
    let floats: [PixelFormat] = [
      .r8snorm, .rg8, .rg8snorm, .rgba8snorm, .rgba8srgb, .r16float, .rg16float, .rgba16float, .r32float, .rg32float, .rgba32float,
      .rgb10a2unorm, .rg11b10float, .rgb9e5,
    ]
    let integers: [PixelFormat] = [
      .rg8uint, .rg8sint, .rgba8uint, .rgba8sint, .rg16uint, .rg16sint, .rgba16uint, .rgba16sint, .r32uint, .r32sint,
      .rg32uint, .rg32sint, .rgba32uint, .rgba32sint,
    ]
    for f in floats { l.setFormat(f, sampled) }
    for f in integers { l.setFormat(f, integer) }
    // The four formats a pass draws into stay as they were; the one-channel integers add their sampling.
    for f in [PixelFormat.r8uint, .r8sint, .r16uint, .r16sint] {
      var c = l.formats(f)
      c.sampled = true
      c.filterable = false
      c.blitSource = true
      c.blitDestination = true
      l.setFormat(f, c)
    }
    // Depth and stencil: sampled, and (depth) compared; the attachment capability is the pipeline's (`depthTarget`).
    var depth = FormatCapabilities()
    depth.sampled = true
    depth.filterable = true
    depth.blitSource = true
    var stencil = depth
    stencil.filterable = false
    // (what the pipeline made of a format's attachment capability stays)
    for f in [PixelFormat.depth16, .depth32f, .depth24stencil8, .depth32fstencil8] {
      var c = depth
      c.depthTarget = l.formats(f).depthTarget
      l.setFormat(f, c)
    }
    var s = stencil
    s.depthTarget = l.formats(.stencil8).depthTarget
    l.setFormat(.stencil8, s)
    // Compressed formats are sampled and copied, never drawn into; the families a GPU has are TEXTURE_FEATURES'.
    var block = FormatCapabilities()
    block.sampled = true
    block.filterable = true
    if let f = transport.info.textureFeatures {
      let features = CompressedFeatures(word: f)
      if features.astcLDR {
        l.features.compressedASTC = true
        for b in ASTCBlock.all {
          l.setFormat(.astc(b), block)
          l.setFormat(.astcSRGB(b), block)
        }
      }
      if features.etc2 {
        l.features.compressedETC2 = true
        for f in [PixelFormat.etc2rgb8, .etc2rgb8srgb, .etc2rgb8a1, .etc2rgb8a1srgb, .etc2rgba8, .etc2rgba8srgb, .eacR11, .eacR11snorm,
                  .eacRG11, .eacRG11snorm] { l.setFormat(f, block) }
      }
      if features.bc {
        l.features.compressedBC = true
        for f in [PixelFormat.bc1rgb, .bc1rgbsrgb, .bc1rgba, .bc1rgbasrgb, .bc2, .bc2srgb, .bc3, .bc3srgb, .bc4, .bc4snorm, .bc5, .bc5snorm,
                  .bc6hufloat, .bc6hsfloat, .bc7, .bc7srgb] { l.setFormat(f, block) }
      }
    }
  }

  // MARK: Images

  public func makeImage(_ d: ImageDescriptor) throws(GPUError) -> GPUImage {
    guard d.width > 0, d.height > 0, d.width <= baseLimits.maxImageDimension, d.height <= baseLimits.maxImageDimension else {
      throw .unsupported("an image of \(d.width) x \(d.height)")
    }
    if let e = d.check(limits: baseLimits) { throw e }
    guard d.samples == 1 else { throw .unsupported("a multisampled image") }
    if d.usage.contains(.renderTarget) && d.format == .r8 { throw .unsupported("a one-channel render target") }
    if d.usage.contains(.renderTarget) && !(d.format == .rgba8 || d.format == .bgra8 || d.format == .bgra8srgb) {
      throw .unsupported("a render target of \(d.format)")
    }
    reclaim()
    var planes: [AspectPlane] = []
    var offset = 0
    for aspect in singleAspects(d.format.aspects) {
      guard let texel = d.format.texelFormat(aspect: aspect) else { throw .unsupported("an image of \(d.format)") }
      let layout = ImageLayout(format: texel, kind: .linear, width: Int(d.width), height: Int(d.height),
                               depth: d.dimension == .d3 ? Int(d.depth) : 1, levels: Int(d.mipLevels), layers: Int(d.layers))
      planes.append(AspectPlane(aspect: aspect, layout: layout, offset: offset, texel: texel))
      offset += layout.arrayStride * layout.layers
    }
    let layout = planes[0].layout
    // A storage image has its plane descriptors as a sampled one does (03 section 3.8.6: the same texture descriptor).
    let sampled = d.usage.contains(.sampled) || d.usage.contains(.storage)
    // The plane descriptors of the whole of the first plane follow its texels (32 bytes each, from a 4096-byte boundary).
    // An image the GPU draws into and the CPU only reads (a target copied out of) is mapped cached by the CPU, and maintained
    // (syncCached).
    let arrayBytes = sampled ? layout.levels.count * layout.layers * PlaneDescriptor.size : 0
    let readOnlyByCPU = !sampled && !d.usage.contains(.copyDestination) && !d.usage.contains(.storage)
      && !d.usage.contains(.scanout)
    let region = try makeRegion(offset + arrayBytes, cpuCached: readOnlyByCPU)
    var planeAt: Int?
    if sampled {
      do throws(DescriptorError) {
        var at = offset
        for p in layout.planes(base: region.address) {
          store(try p.words(), in: region, at: at)
          at += PlaneDescriptor.size
        }
      } catch {
        release([region])
        throw .invalid("an image the texture unit can't describe")
      }
      planeAt = offset
    }
    let record = ImageRecord(region: region, descriptor: d, rowStride: layout.levels[0].rowStride, layout: layout, planeAt: planeAt)
    record.planes = planes
    return GPUImage(handle: images.insert(record), descriptor: d)
  }

  // MARK: Views in the heap

  /// A texture descriptor's dimension for a view.
  func descriptorDimension(_ v: ImageViewDimension) -> TextureDescriptor.Dimension {
    switch v {
    case .d2, .d2Array: return .d2
    case .cube, .cubeArray: return .cube
    case .d3: return .d3
    case .d1, .d1Array: return .d1
    }
  }

  /// The swizzle of a view: the view's own over what the aspect reads (a depth or stencil view reads (value, 0, 0, 1) in
  /// Vulkan's terms, 05 section 5.3.2.1).
  func swizzleWord(_ view: ImageView, aspect: ImageAspects) -> UInt32 {
    let base: [UInt32] = aspect == .color ? [0, 1, 2, 3] : [0, 4, 4, 5]
    func pick(_ s: ComponentSwizzle, _ own: UInt32) -> UInt32 {
      switch s {
      case .identity: return base[Int(own)]
      case .r: return base[0]
      case .g: return base[1]
      case .b: return base[2]
      case .a: return base[3]
      case .zero: return 4
      case .one: return 5
      }
    }
    return TextureSwizzle.make(
      r: pick(view.swizzle.r, 0), g: pick(view.swizzle.g, 1), b: pick(view.swizzle.b, 2), a: pick(view.swizzle.a, 3))
  }

  /// The descriptor words of a view, and the region of its own plane array where it needs one: the whole image of a colour
  /// format uses the array the image keeps.
  func viewWords(_ view: ImageView, use: HeapUse) throws(GPUError) -> (words: [UInt32], array: Region?) {
    guard let record = images[view.image.handle] else { throw .invalid("an image that isn't this device's") }
    if let e = view.check(for: use, limits: baseLimits) { throw e }
    let aspect = view.format.isDepthStencil ? view.aspects : ImageAspects.color
    guard let plane = plane(record, aspect), let texel = view.format.texelFormat(aspect: aspect) else {
      throw .unsupported("a view of \(view.format)")
    }
    guard texel.bytesPerTexel == plane.texel.bytesPerTexel, texel.blockWidth == plane.texel.blockWidth,
      texel.blockHeight == plane.texel.blockHeight
    else { throw .unsupported("a view that reads the texels as another size of block") }
    let d = record.descriptor
    let level = plane.layout.levels[Int(view.baseMip)]
    let planeAt = record.planeAt
    let whole = view.isWholeImage && aspect == .color && view.format == d.format && planeAt != nil
    var layerRange = Int(view.baseLayer)..<Int(view.baseLayer + view.layerCount)
    if view.dimension == .d3 { layerRange = 0..<1 }
    var viewLayout = plane.layout
    viewLayout.format = texel
    var region: Region?
    var surfaces: UInt64
    if whole, let at = planeAt {
      surfaces = record.region.address + UInt64(at)
    } else {
      let planes = viewLayout.planes(base: record.region.address + UInt64(plane.offset), levels: Int(view.baseMip)..<Int(view.baseMip + view.mipCount),
                                     layers: layerRange)
      let r = try makeRegion(planes.count * PlaneDescriptor.size)
      do throws(DescriptorError) {
        var at = 0
        for p in planes {
          store(try p.words(), in: r, at: at)
          at += PlaneDescriptor.size
        }
      } catch {
        release([r])
        throw .invalid("a view the texture unit can't describe")
      }
      region = r
      surfaces = r.address
    }
    let cubes = view.dimension == .cube || view.dimension == .cubeArray
    let td = TextureDescriptor(
      dimension: descriptorDimension(view.dimension), format: texel, width: level.width,
      height: view.dimension == .d1 || view.dimension == .d1Array ? 1 : level.height, swizzle: swizzleWord(view, aspect: aspect),
      layout: .linear, levels: Int(view.mipCount), layers: cubes ? Int(view.layerCount) / 6 : Int(view.dimension == .d3 ? 1 : view.layerCount),
      depth: view.dimension == .d3 ? level.depth : 1, surfaces: surfaces)
    do throws(DescriptorError) { return (try td.words(), region) } catch {
      if let region { release([region]) }
      throw .invalid("a view the texture unit can't describe")
    }
  }

  func putEntry(_ words: [UInt32], at index: Int, in table: inout [UInt32]) {
    let first = index * Heap.entryWords
    if table.count < first + Heap.entryWords {
      table.append(contentsOf: [UInt32](repeating: 0, count: first + Heap.entryWords - table.count))
    }
    for (i, w) in words.enumerated() { table[first + i] = w }
  }

  public func writeTexture(_ index: UInt32, _ image: GPUImage) throws(GPUError) { try writeTexture(index, ImageView(image)) }

  public func writeTexture(_ index: UInt32, _ view: ImageView) throws(GPUError) {
    guard index < UInt32(Heap.textureSlots) else { throw .invalid("texture slot \(index)") }
    let v = try viewWords(view, use: .texture)
    putEntry(v.words, at: Int(index), in: &textureWords)
    holdArray(v.array, slot: Int(index), in: &textureArrays)
  }

  public func writeStorageImage(_ index: UInt32, _ image: GPUImage) throws(GPUError) { try writeStorageImage(index, ImageView(image)) }

  public func writeStorageImage(_ index: UInt32, _ view: ImageView) throws(GPUError) {
    guard index < UInt32(Heap.storageSlots) else { throw .invalid("storage image slot \(index)") }
    let v = try viewWords(view, use: .storage)
    putEntry(v.words, at: Int(index), in: &storageWords)
    holdArray(v.array, slot: Int(index), in: &storageArrays)
  }

  /// A slot's own plane array lives until the slot is written again (work already submitted keeps the descriptor it was
  /// submitted with, and so the array it points at: the old one is retired, not freed).
  func holdArray(_ region: Region?, slot: Int, in table: inout [Region?]) {
    if table.count <= slot { table.append(contentsOf: [Region?](repeating: nil, count: slot + 1 - table.count)) }
    if let old = table[slot] { retire([old]) }
    table[slot] = region
  }

  // MARK: Samplers

  public func writeSampler(_ index: UInt32, _ sampler: SamplerDescriptor) throws(GPUError) {
    guard index < UInt32(Heap.samplerSlots) else { throw .invalid("sampler slot \(index)") }
    if let e = sampler.check(limits: baseLimits) { throw e }
    func wrap(_ m: SamplerAddressMode) -> SamplerWords.Wrap {
      switch m {
      case .clampToEdge: return .clampToEdge
      case .repeat: return .repeat
      case .mirroredRepeat: return .mirroredRepeat
      case .mirrorClampToEdge: return .mirroredClampToEdge
      case .clampToBorder: return .clampToBorder
      }
    }
    func filter(_ f: SamplerFilter) -> SamplerWords.Filter { f == .linear ? .linear : .nearest }
    var border: [UInt32]
    if let c = sampler.customBorderColor {
      switch c {
      case .float(let r, let g, let b, let a): border = [r.bitPattern, g.bitPattern, b.bitPattern, a.bitPattern]
      case .int(let r, let g, let b, let a): border = [UInt32(bitPattern: r), UInt32(bitPattern: g), UInt32(bitPattern: b), UInt32(bitPattern: a)]
      }
    } else {
      let one = Float(1).bitPattern
      switch sampler.borderColor {
      case .transparentBlackFloat, .transparentBlackInt: border = [0, 0, 0, 0]
      case .opaqueBlackFloat: border = [0, 0, 0, one]
      case .opaqueBlackInt: border = [0, 0, 0, 1]
      case .opaqueWhiteFloat: border = [one, one, one, one]
      case .opaqueWhiteInt: border = [1, 1, 1, 1]
      }
    }
    func lod(_ v: Float) -> UInt32 { UInt32(min(max(v, 0), 31.99) * 256) }
    let anisotropic = sampler.maxAnisotropy > 1
    let unnormalized = sampler.unnormalizedCoordinates
    var compare: UInt32 = 0
    if let op = sampler.compare {
      // Vulkan's "reference op texel" is the hardware's "texel op' reference": the operation mirrored (03 section 3.7.4).
      switch op {
      case .never: compare = 0
      case .less: compare = 4
      case .equal: compare = 2
      case .lessOrEqual: compare = 6
      case .greater: compare = 1
      case .notEqual: compare = 5
      case .greaterOrEqual: compare = 3
      case .always: compare = 7
      }
    }
    let words: [UInt32]
    do throws(DescriptorError) {
      var w = SamplerWords(
        wrapS: wrap(sampler.addressModeU), wrapT: wrap(sampler.addressModeV), wrapR: unnormalized ? .clampToEdge : wrap(sampler.addressModeW),
        minFilter: filter(sampler.minFilter), magFilter: filter(sampler.magFilter),
        mipmap: sampler.mipmapMode == .linear ? (anisotropic ? .performanceTrilinear : .trilinear) : .nearest,
        normalizedCoordinates: !unnormalized, minLOD: lod(sampler.minLod), maxLOD: sampler.maxLod >= 31.99 ? 0x1FFF : lod(sampler.maxLod),
        lodBias: Int16(min(max(sampler.mipLodBias * 256, -32768), 32767)), border: border)
      w.compare = compare
      w.maxAnisotropy = anisotropic ? Int(min(sampler.maxAnisotropy, 32)) : 1
      words = try w.words()
    } catch { throw .invalid("a sampler the texture unit can't describe") }
    for (i, w) in words.enumerated() { samplerWords[Int(index) * Heap.entryWords + i] = w }
  }
}
