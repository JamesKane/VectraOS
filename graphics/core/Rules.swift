// SPDX-License-Identifier: BSD-3-Clause

// The core's rules (D174 section 1 and its amendment; gpucore(2)): what makes a list, an image, a view, a sampler
// or a pipeline well formed, and what a device without a feature refuses.
//
// Two kinds of refusal, always apart:
//
//  - `.invalid`: the shape is wrong, whatever the device (a region outside its image, formats that
//    can't be copied between, a draw outside a pass). The same list is invalid everywhere.
//  - `.unsupported`: the shape is right and this device lacks a feature (`DeviceFeatures`), a limit
//    (`DeviceLimits`) or a format's capability (`DeviceLimits.formats(_:)`).
//
// Shape is judged first. A backend that doesn't have something calls the descriptor's `check` at creation, so what it
// refuses is the same words in every backend; `GPUCommandList.validate` is where the commands' rules are written.

extension GPUCommandList {
  /// Whether the device can run the list, and if not, why not: the rules every backend holds a list to, so a
  /// list that one runs and another refuses is the other's refusal of a feature (`.unsupported`), never of
  /// the list's shape (`.invalid`). This judges by the features alone; `validate(limits:)` also judges the
  /// formats' capabilities and the limits.
  public func validate(features: DeviceFeatures) -> GPUError? {
    ListRules(features: features, limits: nil).run(commands)
  }

  /// `validate(features:)`, and the device's limits and its formats' capabilities.
  public func validate(limits: DeviceLimits) -> GPUError? {
    ListRules(features: limits.features, limits: limits).run(commands)
  }
}

// MARK: Shared shape rules

func isPowerOfTwoSamples(_ n: UInt32) -> Bool { n >= 1 && n <= 64 && n & (n - 1) == 0 }

extension PixelFormat {
  /// The format with its sRGB or signed variant folded to the unorm one, for the formats that share a compatibility
  /// class (the Vulkan format classes); nil for an uncompressed format.
  var compressedClass: PixelFormat? {
    switch self {
    case .astc(let b), .astcSRGB(let b): .astc(b)
    case .etc2rgb8, .etc2rgb8srgb: .etc2rgb8
    case .etc2rgb8a1, .etc2rgb8a1srgb: .etc2rgb8a1
    case .etc2rgba8, .etc2rgba8srgb: .etc2rgba8
    case .eacR11, .eacR11snorm: .eacR11
    case .eacRG11, .eacRG11snorm: .eacRG11
    case .bc1rgb, .bc1rgbsrgb: .bc1rgb
    case .bc1rgba, .bc1rgbasrgb: .bc1rgba
    case .bc2, .bc2srgb: .bc2
    case .bc3, .bc3srgb: .bc3
    case .bc4, .bc4snorm: .bc4
    case .bc5, .bc5snorm: .bc5
    case .bc6hufloat, .bc6hsfloat: .bc6hufloat
    case .bc7, .bc7srgb: .bc7
    default: nil
    }
  }

  /// Whether a copy or a resolve may go between the two: the same format, or (colour) formats of one size of texel, or
  /// compressed formats of one class.
  func isCopyCompatible(with other: PixelFormat) -> Bool {
    if self == other { return true }
    if isDepthStencil || other.isDepthStencil { return false }
    if isCompressed || other.isCompressed {
      guard let a = compressedClass, let b = other.compressedClass else { return false }
      return a == b
    }
    return texelBlock.bytes == other.texelBlock.bytes
  }

  /// Whether a view of an image of format `image` may have this format.
  func isViewCompatible(with image: PixelFormat) -> Bool { isCopyCompatible(with: image) }
}

/// The checks of subresources, extents and regions that every command that names them shares.
enum RegionRules {
  static func layers(_ s: ImageSubresourceLayers, _ image: GPUImage, single: Bool) -> GPUError? {
    if s.layerCount == 0 { return .invalid("a region of no layers") }
    if s.mip >= image.mipLevels { return .invalid("a region of a mip level the image doesn't have") }
    if Int(s.baseLayer) + Int(s.layerCount) > Int(image.layers) { return .invalid("a region past the image's layers") }
    if s.aspects.isEmpty || !image.format.aspects.contains(s.aspects) { return .invalid("a region of an aspect the format doesn't have") }
    if image.format.aspects.contains(.color) && s.aspects != .color { return .invalid("a region of an aspect the format doesn't have") }
    if single && s.aspects != .color && s.aspects != .depth && s.aspects != .stencil {
      return .invalid("a region of more than one aspect")
    }
    return nil
  }

  static func range(_ r: ImageSubresourceRange, _ image: GPUImage) -> GPUError? {
    if r.layerCount == 0 || r.mipCount == 0 { return .invalid("a range of no mip levels or layers") }
    if Int(r.baseMip) + Int(r.mipCount) > Int(image.mipLevels) { return .invalid("a range past the image's mip levels") }
    if Int(r.baseLayer) + Int(r.layerCount) > Int(image.layers) { return .invalid("a range past the image's layers") }
    if r.aspects.isEmpty || !image.format.aspects.contains(r.aspects) { return .invalid("a range of an aspect the format doesn't have") }
    return nil
  }

  /// The offset and extent lie inside the mip level (a 2D image's depth is one), and a compressed format's land on blocks.
  static func extent(_ offset: Offset3D, _ extent: Extent3D, _ image: GPUImage, mip: UInt32) -> GPUError? {
    if extent.width == 0 || extent.height == 0 || extent.depth == 0 { return .invalid("a region of no texels") }
    if offset.x < 0 || offset.y < 0 || offset.z < 0 { return .invalid("a region before the image") }
    let m = image.descriptor.mipExtent(mip)
    if Int(offset.x) + Int(extent.width) > Int(m.width) || Int(offset.y) + Int(extent.height) > Int(m.height)
      || Int(offset.z) + Int(extent.depth) > Int(m.depth) {
      return .invalid("a region past the image")
    }
    let b = image.format.texelBlock
    if b.width > 1 || b.height > 1 {
      if Int(offset.x) % b.width != 0 || Int(offset.y) % b.height != 0 { return .invalid("a region that doesn't start on a block") }
      if Int(extent.width) % b.width != 0 && Int(offset.x) + Int(extent.width) != Int(m.width) {
        return .invalid("a region that doesn't end on a block")
      }
      if Int(extent.height) % b.height != 0 && Int(offset.y) + Int(extent.height) != Int(m.height) {
        return .invalid("a region that doesn't end on a block")
      }
    }
    return nil
  }

  static func overlaps(_ a: ImageSubresourceLayers, _ ao: Offset3D, _ b: ImageSubresourceLayers, _ bo: Offset3D, _ e: Extent3D) -> Bool {
    if a.mip != b.mip { return false }
    if a.aspects.rawValue & b.aspects.rawValue == 0 { return false }
    if Int(a.baseLayer) >= Int(b.baseLayer) + Int(b.layerCount) || Int(b.baseLayer) >= Int(a.baseLayer) + Int(a.layerCount) { return false }
    if Int(ao.x) >= Int(bo.x) + Int(e.width) || Int(bo.x) >= Int(ao.x) + Int(e.width) { return false }
    if Int(ao.y) >= Int(bo.y) + Int(e.height) || Int(bo.y) >= Int(ao.y) + Int(e.height) { return false }
    if Int(ao.z) >= Int(bo.z) + Int(e.depth) || Int(bo.z) >= Int(ao.z) + Int(e.depth) { return false }
    return true
  }

  /// A region of an image copied to or from a buffer: its subresource, extent, row length and image height, and the
  /// bytes it takes in the buffer.
  static func bufferImage(_ r: BufferImageRegion, _ image: GPUImage, _ buffer: GPUMemory) -> GPUError? {
    if let e = layers(r.subresource, image, single: true) { return e }
    if let e = extent(r.imageOffset, r.imageExtent, image, mip: r.subresource.mip) { return e }
    let f = image.format
    let b = f.texelBlock
    if r.bufferRowLength != 0 && r.bufferRowLength < r.imageExtent.width { return .invalid("a buffer row shorter than the region's") }
    if r.bufferImageHeight != 0 && r.bufferImageHeight < r.imageExtent.height { return .invalid("a buffer image shorter than the region's") }
    if f.isCompressed && (Int(r.bufferRowLength) % b.width != 0 || Int(r.bufferImageHeight) % b.height != 0) {
      return .invalid("a buffer row or image height that isn't whole blocks")
    }
    let texel = f.isCompressed ? b.bytes : f.bytesPerTexel(aspect: r.subresource.aspects)
    if texel == 0 { return .invalid("a copy of an aspect the format has no texels of") }
    if r.bufferOffset < 0 || r.bufferOffset % texel != 0 { return .invalid("a buffer offset that isn't a multiple of the texel") }
    let rowLength = Int(r.bufferRowLength == 0 ? r.imageExtent.width : r.bufferRowLength)
    let imageHeight = Int(r.bufferImageHeight == 0 ? r.imageExtent.height : r.bufferImageHeight)
    let rowBytes = ((rowLength + b.width - 1) / b.width) * texel
    let sliceBytes = ((imageHeight + b.height - 1) / b.height) * rowBytes
    let slices = Int(r.subresource.layerCount) * Int(r.imageExtent.depth)
    let lastRows = (Int(r.imageExtent.height) + b.height - 1) / b.height
    let lastRowBytes = ((Int(r.imageExtent.width) + b.width - 1) / b.width) * texel
    let end = r.bufferOffset + (slices - 1) * sliceBytes + (lastRows - 1) * rowBytes + lastRowBytes
    if end > buffer.size { return .invalid("a copy past its memory") }
    return nil
  }
}

// MARK: Views

/// What a heap slot holds the view as.
public enum HeapUse: Sendable, Equatable { case texture, storage }

extension ImageView {
  /// The view's shape, whatever it is for: its mip levels and layers inside the image, a format that may view the image's,
  /// and a dimension its image allows.
  func shapeError() -> GPUError? {
    let d = image.descriptor
    if mipCount == 0 || Int(baseMip) + Int(mipCount) > Int(d.mipLevels) { return .invalid("a view past the image's mip levels") }
    if layerCount == 0 || Int(baseLayer) + Int(layerCount) > Int(d.layers) { return .invalid("a view past the image's layers") }
    if !format.isViewCompatible(with: d.format) { return .invalid("a view of a format that isn't compatible with its image's") }
    if aspects.isEmpty || !format.aspects.contains(aspects) { return .invalid("a view of an aspect its format doesn't have") }
    if format.aspects.contains(.color) && aspects != .color { return .invalid("a view of an aspect its format doesn't have") }
    switch dimension {
    case .d2:
      if d.dimension == .d3 { return .invalid("a 2D view of a 3D image") }
      if d.dimension == .d1 { return .invalid("a 2D view of a 1D image") }
      if layerCount != 1 { return .invalid("a 2D view of more than one layer") }
    case .d2Array:
      if d.dimension == .d3 { return .invalid("a 2D array view of a 3D image") }
      if d.dimension == .d1 { return .invalid("a 2D array view of a 1D image") }
    case .cube:
      if d.dimension != .cube { return .invalid("a cube view of an image that isn't a cube") }
      if layerCount != 6 { return .invalid("a cube view that isn't six layers") }
    case .cubeArray:
      if d.dimension != .cube { return .invalid("a cube view of an image that isn't a cube") }
      if layerCount % 6 != 0 { return .invalid("a cube array view that isn't a multiple of six layers") }
    case .d3:
      if d.dimension != .d3 { return .invalid("a 3D view of an image that isn't 3D") }
    case .d1:
      if d.dimension != .d1 { return .invalid("a 1D view of an image that isn't 1D") }
      if layerCount != 1 { return .invalid("a 1D view of more than one layer") }
    case .d1Array:
      if d.dimension != .d1 { return .invalid("a 1D array view of an image that isn't 1D") }
    }
    return nil
  }

  /// The view's shape as an attachment of a pass (or its resolve target): the shape of any view, and that the view maps no
  /// components and is not 1D, which no pass draws into.
  func attachmentError() -> GPUError? {
    if let e = shapeError() { return e }
    if !swizzle.isIdentity { return .invalid("an attachment whose view maps components") }
    if dimension == .d1 || dimension == .d1Array { return .invalid("an attachment that is a 1D view") }
    return nil
  }

  /// What a feature-less device refuses of the view: a part of an image, another format, arrays, cubes and volumes.
  func featureError(_ f: DeviceFeatures) -> GPUError? {
    if !swizzle.isIdentity && !f.imageSwizzle { return .unsupported("a view that maps components") }
    if !isWholeImage && !f.imageViews { return .unsupported("a view that isn't the whole image") }
    switch dimension {
    case .d2: break
    case .d2Array: if !f.arrayImages { return .unsupported("array views") }
    case .cube: if !f.cubeImages { return .unsupported("cube views") }
    case .cubeArray: if !f.cubeImages || !f.arrayImages { return .unsupported("cube array views") }
    case .d3: if !f.volumeImages { return .unsupported("3D views") }
    case .d1: if !f.images1D { return .unsupported("1D views") }
    case .d1Array: if !f.images1D || !f.arrayImages { return .unsupported("1D array views") }
    }
    return nil
  }

  /// Whether the device may hold the view in a heap slot as a texture or a storage image: the usage, a single aspect,
  /// the features of its dimension, and the format's capability.
  public func check(for use: HeapUse, limits: DeviceLimits) -> GPUError? {
    switch use {
    case .texture: if !image.usage.contains(.sampled) { return .invalid("a texture that isn't sampled") }
    case .storage: if !image.usage.contains(.storage) { return .invalid("a storage image that isn't") }
    }
    if let e = shapeError() { return e }
    if format.isDepthStencil {
      if use == .storage { return .invalid("a storage view of a depth or stencil format") }
      if aspects != .depth && aspects != .stencil { return .invalid("a texture view of both depth and stencil") }
    }
    if use == .storage && mipCount != 1 { return .invalid("a storage view of more than one mip level") }
    if use == .storage && !swizzle.isIdentity { return .invalid("a storage view that maps components") }
    if let e = featureError(limits.features) { return e }
    let c = limits.formats(format)
    switch use {
    case .texture:
      if !c.sampled || !c.sampledSamples.contains(image.samples) { return .unsupported("a texture of \(format)") }
    case .storage:
      if !c.storage || !c.storageSamples.contains(image.samples) { return .unsupported("a storage image of \(format)") }
    }
    return nil
  }
}

// MARK: Texel buffers

/// What the heap holds a buffer view as.
public enum TexelBufferUse: Sendable, Equatable { case uniform, storage }

extension BufferView {
  /// Whether the device may hold the view in a texel-buffer slot: `.invalid` for a shape no device takes (a range that isn't
  /// whole texels or goes past its memory, a depth or compressed format), `.unsupported` for what this device lacks (the
  /// feature, the format's capability, the most texels).
  public func check(for use: TexelBufferUse, limits: DeviceLimits) -> GPUError? {
    if format.isDepthStencil || format.isCompressed || texelBytes == 0 { return .invalid("a texel buffer of \(format)") }
    if offset < 0 || range <= 0 { return .invalid("a texel buffer view of no texels, or before its memory") }
    if range % texelBytes != 0 { return .invalid("a texel buffer view whose range isn't whole texels") }
    if offset % texelBytes != 0 { return .invalid("a texel buffer view that doesn't start on a texel") }
    if offset + range > memory.size { return .invalid("a texel buffer view past its memory") }
    let f = limits.features
    switch use {
    case .uniform: if !f.uniformTexelBuffers { return .unsupported("uniform texel buffers") }
    case .storage: if !f.storageTexelBuffers { return .unsupported("storage texel buffers") }
    }
    if elementCount > Int(limits.maxTexelBufferElements) {
      return .unsupported("a texel buffer of \(elementCount) texels")
    }
    let c = limits.formats(format)
    switch use {
    case .uniform: if !c.texelBuffer { return .unsupported("a uniform texel buffer of \(format)") }
    case .storage: if !c.storageTexelBuffer { return .unsupported("a storage texel buffer of \(format)") }
    }
    return nil
  }
}

// MARK: Images, samplers and pipelines

extension ImageDescriptor {
  /// Whether the device may make the image: `.invalid` for a shape no device makes, `.unsupported` for what this
  /// device lacks (a feature, a limit, a format's capability).
  public func check(limits: DeviceLimits) -> GPUError? {
    let f = limits.features
    if width <= 0 || height <= 0 || depth <= 0 { return .invalid("an image of \(width) x \(height) x \(depth)") }
    if layers == 0 { return .invalid("an image of no layers") }
    if mipLevels == 0 || mipLevels > maxMipLevels { return .invalid("an image of \(mipLevels) mip levels") }
    if !isPowerOfTwoSamples(samples) { return .invalid("an image of \(samples) samples") }
    switch dimension {
    case .d2:
      if depth != 1 { return .invalid("a 2D image with depth") }
    case .d1:
      if height != 1 || depth != 1 { return .invalid("a 1D image with height or depth") }
      if samples != 1 { return .invalid("a multisampled 1D image") }
      if format.isDepthStencil || format.isCompressed { return .invalid("a 1D image of \(format)") }
      if usage.contains(.renderTarget) || usage.contains(.scanout) { return .invalid("a 1D image that is drawn into or shown") }
    case .d3:
      if layers != 1 { return .invalid("a 3D image with layers") }
      if samples != 1 { return .invalid("a multisampled 3D image") }
    case .cube:
      if width != height { return .invalid("a cube image that isn't square") }
      if layers % 6 != 0 { return .invalid("a cube image whose layers aren't a multiple of six") }
      if depth != 1 { return .invalid("a cube image with depth") }
      if samples != 1 { return .invalid("a multisampled cube image") }
    }
    if samples > 1 && (mipLevels != 1 || format.isCompressed) { return .invalid("a multisampled image with mip levels or a compressed format") }
    if usage.contains(.renderTarget) && (format.isDepthStencil || format.isCompressed) {
      return .invalid("a colour render target of \(format)")
    }
    if usage.contains(.depthStencilTarget) && !format.isDepthStencil { return .invalid("a depth target of \(format)") }
    if usage.contains(.storage) && (format.isDepthStencil || format.isCompressed) { return .invalid("a storage image of \(format)") }
    if usage.contains(.scanout) {
      if format.isDepthStencil || format.isCompressed || format.bytesPerPixel != 4 || dimension != .d2 || mipLevels != 1
        || layers != 1 || samples != 1 {
        return .invalid("a scanout image that isn't one four-byte colour layer")
      }
    }
    // What the device lacks.
    if width > limits.maxImageDimension || height > limits.maxImageDimension {
      return .unsupported("an image of \(width) x \(height)")
    }
    if dimension == .d3 {
      let most = limits.maxImageDimension3D > 0 ? limits.maxImageDimension3D : limits.maxImageDimension
      if !f.volumeImages { return .unsupported("3D images") }
      if width > most || height > most || depth > most { return .unsupported("a 3D image of \(width) x \(height) x \(depth)") }
    }
    if dimension == .cube && !f.cubeImages { return .unsupported("cube images") }
    if dimension == .d1 && !f.images1D { return .unsupported("1D images") }
    if layers > 1 && !f.arrayImages && !(dimension == .cube && layers == 6) { return .unsupported("array images") }
    if f.arrayImages && layers > limits.maxImageArrayLayers { return .unsupported("an image of \(layers) layers") }
    if mipLevels > 1 && !f.mipmaps { return .unsupported("images with mip levels") }
    if samples > 1 && (!f.multisample || samples > limits.maxSamples) { return .unsupported("an image of \(samples) samples") }
    switch format.family {
    case .astc?: if !f.compressedASTC { return .unsupported("ASTC formats") }
    case .etc2?: if !f.compressedETC2 { return .unsupported("ETC2 and EAC formats") }
    case .bc?: if !f.compressedBC { return .unsupported("BC formats") }
    case nil: break
    }
    if format.hasDepth && !f.depth { return .unsupported("depth formats") }
    if format.hasStencil && !f.stencil { return .unsupported("stencil formats") }
    var listed = false
    for e in limits.formatTable where e.format == format { listed = true }
    if !listed { return .unsupported("an image of \(format)") }
    let c = limits.formats(format)
    if usage.contains(.sampled) && !(c.sampled && c.sampledSamples.contains(samples)) { return .unsupported("a sampled image of \(format)") }
    if usage.contains(.renderTarget) && !(c.renderTarget && c.renderSamples.contains(samples)) {
      return .unsupported("a render target of \(format)")
    }
    if usage.contains(.storage) && !(c.storage && c.storageSamples.contains(samples)) { return .unsupported("a storage image of \(format)") }
    if usage.contains(.depthStencilTarget) && !(c.depthTarget && c.depthSamples.contains(samples)) {
      return .unsupported("a depth target of \(format)")
    }
    return nil
  }
}

extension SamplerDescriptor {
  /// Whether the device may make the sampler: `.invalid` for contradictory fields, `.unsupported` for a feature the device lacks.
  public func check(limits: DeviceLimits) -> GPUError? {
    let f = limits.features
    if maxAnisotropy < 1 { return .invalid("an anisotropy below one") }
    if minLod > maxLod { return .invalid("a sampler whose minimum level of detail is above its maximum") }
    if unnormalizedCoordinates {
      if mipmapMode != .nearest || minLod != 0 || maxLod != 0 { return .invalid("unnormalized coordinates with mip levels") }
      if maxAnisotropy != 1 || compare != nil { return .invalid("unnormalized coordinates with anisotropy or compare") }
      if minFilter != magFilter { return .invalid("unnormalized coordinates with two filters") }
      for m in [addressModeU, addressModeV] where m != .clampToEdge && m != .clampToBorder {
        return .invalid("unnormalized coordinates with addressing other than clamping")
      }
    }
    if customBorderColor != nil && ![addressModeU, addressModeV, addressModeW].contains(.clampToBorder) {
      return .invalid("a custom border colour on a sampler that doesn't clamp to a border")
    }
    if customBorderColor != nil && !f.customBorderColor { return .unsupported("a custom border colour") }
    if minFilter != magFilter && !f.samplerMinMagFilters { return .unsupported("a sampler whose filters differ") }
    if (addressModeU != addressModeV || addressModeV != addressModeW) && !f.samplerAxisAddressModes {
      return .unsupported("a sampler addressing its axes differently")
    }
    for m in [addressModeU, addressModeV, addressModeW] {
      if m == .clampToBorder && !f.samplerBorder { return .unsupported("a sampler that clamps to a border colour") }
      if m == .mirrorClampToEdge && !f.samplerMirrorClampToEdge { return .unsupported("a sampler that mirrors once and clamps") }
    }
    if (mipmapMode == .linear || mipLodBias != 0 || minLod != 0) && !f.mipmaps { return .unsupported("a sampler of mip levels") }
    if maxAnisotropy > 1 && (!f.samplerAnisotropy || maxAnisotropy > limits.maxAnisotropy) {
      return .unsupported("an anisotropy of \(maxAnisotropy)")
    }
    if compare != nil && !f.samplerCompare { return .unsupported("a comparison sampler") }
    if unnormalizedCoordinates && !f.unnormalizedCoordinates { return .unsupported("unnormalized coordinates") }
    return nil
  }
}

extension GraphicsPipelineDescriptor {
  /// Whether the device may make the pipeline: `.invalid` for contradictory state, `.unsupported` for the features, limits and
  /// capabilities the device lacks. It doesn't look at the shaders.
  public func check(limits: DeviceLimits) -> GPUError? {
    let f = limits.features
    if colorFormats.isEmpty && depthStencilFormat == nil { return .invalid("a pipeline with no attachment") }
    if colorFormats.count > 8 { return .invalid("a pipeline with \(colorFormats.count) colour targets") }
    for c in colorFormats where c.isDepthStencil || c.isCompressed { return .invalid("a colour target of \(c)") }
    if let d = depthStencilFormat, !d.isDepthStencil { return .invalid("a depth and stencil target of \(d)") }
    if let b = attachmentBlends, b.count != 1 && b.count != colorFormats.count {
      return .invalid("blends for \(b.count) of \(colorFormats.count) colour targets")
    }
    if !isPowerOfTwoSamples(multisample.samples) { return .invalid("a pipeline of \(multisample.samples) samples") }
    if multisample.samples == 1 && multisample.sampleMask & 1 == 0 { return .invalid("a sample mask that keeps no sample") }
    if multisample.minSampleShading < 0 || multisample.minSampleShading > 1 { return .invalid("a sample shading outside 0 to 1") }
    if rasterization.lineWidth <= 0 { return .invalid("a line of no width") }
    if depthStencil.depthBoundsTest && depthStencil.minDepthBounds > depthStencil.maxDepthBounds {
      return .invalid("depth bounds whose minimum is above the maximum")
    }
    if (depthStencil.depthTest || depthStencil.depthWrite) && !(depthStencilFormat?.hasDepth ?? false) {
      return .invalid("a depth test with no depth attachment")
    }
    if depthStencil.stencilTest && !(depthStencilFormat?.hasStencil ?? false) { return .invalid("a stencil test with no stencil attachment") }
    if depthStencil.depthBoundsTest && !(depthStencilFormat?.hasDepth ?? false) { return .invalid("depth bounds with no depth attachment") }
    if topology == .patchList {
      if patchControlPoints == 0 { return .invalid("a patch list of no control points") }
      if tessellationControl == nil || tessellationEvaluation == nil { return .invalid("a patch list without both tessellation stages") }
    } else if tessellationControl != nil || tessellationEvaluation != nil {
      return .invalid("tessellation stages without a patch list")
    }
    if (tessellationControl == nil) != (tessellationEvaluation == nil) { return .invalid("one tessellation stage without the other") }
    if primitiveRestart && (topology == .triangleList || topology == .lineList || topology == .pointList || topology == .patchList) {
      return .invalid("primitive restart of a list topology")
    }
    for i in 0..<specialization.count {
      for j in (i + 1)..<max(specialization.count, i + 1) where specialization[i].id == specialization[j].id {
        return .invalid("two values for specialization constant \(specialization[i].id)")
      }
    }
    // What the device lacks.
    if colorFormats.count > 1 && (!f.multipleColorAttachments || UInt32(colorFormats.count) > limits.maxColorAttachments) {
      return .unsupported("a pipeline with \(colorFormats.count) colour targets")
    }
    for c in colorFormats {
      let caps = limits.formats(c)
      if !caps.renderTarget || !caps.renderSamples.contains(multisample.samples) { return .unsupported("a pipeline that draws into \(c)") }
    }
    if let d = depthStencilFormat {
      if d.hasDepth && !f.depth { return .unsupported("depth attachments") }
      if d.hasStencil && !f.stencil { return .unsupported("stencil attachments") }
      let caps = limits.formats(d)
      if !caps.depthTarget || !caps.depthSamples.contains(multisample.samples) { return .unsupported("a pipeline that draws into \(d)") }
    }
    if depthStencil.depthBoundsTest && !f.depthBounds { return .unsupported("a depth bounds test") }
    if rasterization.cull != .none && !f.cullModes { return .unsupported("a cull mode other than none") }
    if rasterization.polygonMode != .fill && !f.fillModeNonSolid { return .unsupported("a polygon mode other than fill") }
    if rasterization.depthBias && !f.depthBias { return .unsupported("depth bias") }
    if rasterization.depthClamp && !f.depthClamp { return .unsupported("depth clamp") }
    if rasterization.rasterizerDiscard && !f.rasterizerDiscard { return .unsupported("rasterizer discard") }
    if rasterization.lineWidth != 1 && (!f.wideLines || rasterization.lineWidth > limits.maxLineWidth) && !dynamic.contains(.lineWidth) {
      return .unsupported("a line width of \(rasterization.lineWidth)")
    }
    if multisample.samples > 1 && (!f.multisample || multisample.samples > limits.maxSamples) {
      return .unsupported("a pipeline of \(multisample.samples) samples")
    }
    if multisample.samples > 1 && multisample.sampleMask != ~0 && !f.multisample { return .unsupported("a sample mask") }
    if multisample.alphaToCoverage && !f.alphaToCoverage { return .unsupported("alpha to coverage") }
    if multisample.alphaToOne && !f.alphaToOne { return .unsupported("alpha to one") }
    if multisample.sampleShading && !f.sampleShading { return .unsupported("sample shading") }
    let blends = effectiveBlends
    for c in 0..<blends.count {
      let b = blends[c]
      let plain = b.enabled ? b == .alphaOver : b.writeMask == .all
      if !plain && !f.generalBlend {
        return .unsupported("a blend other than opaque and source alpha over, or a colour write mask")
      }
      if b.enabled && c < colorFormats.count && !limits.formats(colorFormats[c]).blendable {
        return .unsupported("a blend into \(colorFormats[c])")
      }
      if b.usesDualSource && !f.dualSourceBlend { return .unsupported("dual-source blending") }
      if c > 0 && b != blends[0] && !f.independentBlend { return .unsupported("a blend that differs between colour targets") }
    }
    if logicOp != nil && !f.logicOps { return .unsupported("logic operations") }
    if (blendConstants != BlendConstants() || dynamic.contains(.blendConstants)) && !f.generalBlend {
      return .unsupported("blend constants")
    }
    if !dynamic.isEmpty && !f.dynamicState { return .unsupported("dynamic state") }
    if (topology == .lineStrip || topology == .triangleFan) && !f.extendedTopologies { return .unsupported("line strips and triangle fans") }
    if topology == .patchList && (!f.tessellation || patchControlPoints > limits.maxPatchControlPoints) {
      return .unsupported("patch lists")
    }
    if primitiveRestart && !f.primitiveRestart { return .unsupported("primitive restart") }
    if geometry != nil && !f.geometryShader { return .unsupported("geometry shaders") }
    if (tessellationControl != nil || tessellationEvaluation != nil) && !f.tessellation { return .unsupported("tessellation") }
    if !specialization.isEmpty && !f.specializationConstants { return .unsupported("specialization constants") }
    if viewMask != 0 {
      if !f.multiview { return .unsupported("multiview") }
      if UInt32(32 - viewMask.leadingZeroBitCount) > limits.maxMultiviewViews { return .unsupported("a view mask of \(viewMask)") }
    }
    return nil
  }
}

// MARK: The list

struct ListRules {
  let features: DeviceFeatures
  let limits: DeviceLimits?

  func caps(_ f: PixelFormat) -> FormatCapabilities? { limits?.formats(f) }

  func run(_ commands: [Command]) -> GPUError? {
    var pass: RenderingInfo?
    var passDraws = 0
    for c in commands {
      switch c {
      case .beginRendering(let info):
        if pass != nil { return .invalid("a pass begins inside a pass") }
        if let e = begin(info) { return e }
        pass = info
        passDraws = 0
      case .endRendering:
        if pass == nil { return .invalid("a pass ends that didn't begin") }
        pass = nil
      case .setViewport, .setScissor:
        if pass == nil { return .invalid("a viewport or scissor outside a pass") }
      case .draw(let p, _, _, _, _, _):
        if let e = drawable(p, pass) { return e }
        passDraws += 1
        if passDraws > 1 && !features.multipleDrawsPerPass { return .unsupported("more than one draw in a pass") }
      case .drawIndexed(let p, _, let indices, let offset, let type, let count, _, let first, _, _):
        if let e = drawable(p, pass) { return e }
        if !features.indexedDraw { return .unsupported("indexed draws") }
        if offset < 0 || offset + (Int(first) + Int(count)) * type.bytes > indices.size { return .invalid("indices past their memory") }
        passDraws += 1
        if passDraws > 1 && !features.multipleDrawsPerPass { return .unsupported("more than one draw in a pass") }
      case .drawIndirect(let p, _, let args, let offset, let count, let stride):
        if let e = drawable(p, pass) { return e }
        if !features.indirectDraw { return .unsupported("indirect draws") }
        if offset < 0 || stride < 16 || count > 0 && offset + (Int(count) - 1) * Int(stride) + 16 > args.size {
          return .invalid("indirect arguments past their memory")
        }
        passDraws += 1
        if passDraws > 1 && !features.multipleDrawsPerPass { return .unsupported("more than one draw in a pass") }
      case .drawIndexedIndirect(let p, _, _, _, _, let args, let offset, let count, let stride):
        if let e = drawable(p, pass) { return e }
        if !features.indirectDraw || !features.indexedDraw { return .unsupported("indirect indexed draws") }
        if offset < 0 || stride < 20 || count > 0 && offset + (Int(count) - 1) * Int(stride) + 20 > args.size {
          return .invalid("indirect arguments past their memory")
        }
        passDraws += 1
        if passDraws > 1 && !features.multipleDrawsPerPass { return .unsupported("more than one draw in a pass") }
      case .drawIndirectCount(let p, _, let args, let offset, let counts, let countOffset, let maxCount, let stride):
        if let e = drawable(p, pass) { return e }
        if let e = indirectCount(args, offset, counts, countOffset, maxCount, stride, 16) { return e }
        if !features.indirectDraw || !features.drawIndirectCount { return .unsupported("indirect draws with a count") }
        passDraws += 1
        if passDraws > 1 && !features.multipleDrawsPerPass { return .unsupported("more than one draw in a pass") }
      case .drawIndexedIndirectCount(let p, _, let indices, let indexOffset, _, let args, let offset, let counts, let countOffset,
                                     let maxCount, let stride):
        if let e = drawable(p, pass) { return e }
        if indexOffset < 0 || indexOffset > indices.size { return .invalid("indices past their memory") }
        if let e = indirectCount(args, offset, counts, countOffset, maxCount, stride, 20) { return e }
        if !features.indirectDraw || !features.indexedDraw || !features.drawIndirectCount {
          return .unsupported("indirect indexed draws with a count")
        }
        passDraws += 1
        if passDraws > 1 && !features.multipleDrawsPerPass { return .unsupported("more than one draw in a pass") }
      case .dispatch(let p, _, let x, let y, let z):
        if pass != nil { return .invalid("a dispatch inside a pass") }
        if p.kind != .compute { return .invalid("a dispatch of a graphics pipeline") }
        if x == 0 || y == 0 || z == 0 { return .invalid("a dispatch of no workgroups") }
      case .dispatchIndirect(let p, _, let args, let offset):
        if pass != nil { return .invalid("a dispatch inside a pass") }
        if p.kind != .compute { return .invalid("a dispatch of a graphics pipeline") }
        if !features.indirectDispatch { return .unsupported("indirect dispatch") }
        if offset < 0 || offset + 12 > args.size { return .invalid("indirect arguments past their memory") }
      case .copyBuffer(let from, let fo, let dst, let dstOffset, let bytes):
        if pass != nil { return .invalid("a copy inside a pass") }
        if bytes < 0 || fo < 0 || dstOffset < 0 || fo + bytes > from.size || dstOffset + bytes > dst.size { return .invalid("a copy past its memory") }
      case .copyBufferToImage(let m, let offset, let image):
        if pass != nil { return .invalid("a copy inside a pass") }
        if !image.usage.contains(.copyDestination) { return .invalid("a copy into an image that isn't a copy destination") }
        if let e = wholeImageCopy(image, m, offset) { return e }
      case .copyImageToBuffer(let image, let m, let offset):
        if pass != nil { return .invalid("a copy inside a pass") }
        if !image.usage.contains(.copySource) { return .invalid("a copy out of an image that isn't a copy source") }
        if let e = wholeImageCopy(image, m, offset) { return e }
      case .barrier:
        if pass != nil { return .invalid("a barrier inside a pass") }
      case .imageBarrier(_, _, let image, let range):
        if pass != nil { return .invalid("a barrier inside a pass") }
        if let e = RegionRules.range(range, image) { return e }
      case .writeTimestamp(let set, let index, _):
        if set.kind != .timestamp { return .invalid("a timestamp into an occlusion set") }
        if !features.timestampQueries { return .unsupported("timestamp queries") }
        if index < 0 || index >= set.count { return .invalid("a query past its set") }
      case .beginQuery(let set, let index), .endQuery(let set, let index):
        if let e = query(set, index, pass) { return e }
      case .copyImage(let src, let dst, let regions):
        if let e = copyImage(src, dst, regions, pass) { return e }
      case .blitImage(let src, let dst, let regions, let filter):
        if let e = blit(src, dst, regions, filter, pass) { return e }
      case .resolveImage(let src, let dst, let regions):
        if let e = resolve(src, dst, regions, pass) { return e }
      case .copyBufferToImageRegions(let m, let image, let regions):
        if pass != nil { return .invalid("a copy inside a pass") }
        if !image.usage.contains(.copyDestination) { return .invalid("a copy into an image that isn't a copy destination") }
        if let e = bufferImage(image, m, regions) { return e }
      case .copyImageToBufferRegions(let image, let m, let regions):
        if pass != nil { return .invalid("a copy inside a pass") }
        if !image.usage.contains(.copySource) { return .invalid("a copy out of an image that isn't a copy source") }
        if let e = bufferImage(image, m, regions) { return e }
      case .fillBuffer(let m, let offset, let bytes, _):
        if pass != nil { return .invalid("a fill inside a pass") }
        if offset < 0 || offset % 4 != 0 || bytes <= 0 || bytes % 4 != 0 || offset + bytes > m.size { return .invalid("a fill past its memory") }
        if !features.fillBuffer { return .unsupported("buffer fills") }
      case .updateBuffer(let m, let offset, let data):
        if pass != nil { return .invalid("an update inside a pass") }
        if data.isEmpty || data.count % 4 != 0 || data.count > 65536 { return .invalid("an update of \(data.count) bytes") }
        if offset < 0 || offset % 4 != 0 || offset + data.count > m.size { return .invalid("an update past its memory") }
        if !features.updateBuffer { return .unsupported("buffer updates") }
      case .clearColorImage(let image, let color, let ranges):
        if let e = clearColor(image, color, ranges, pass) { return e }
      case .clearDepthStencilImage(let image, _, _, let ranges):
        if let e = clearDepthStencil(image, ranges, pass) { return e }
      case .clearAttachments(let attachments, let rects):
        if let e = clearAttachments(attachments, rects, pass) { return e }
      case .setBlendConstants:
        if pass == nil { return .invalid("a state command outside a pass") }
        if !features.dynamicState { return .unsupported("dynamic state") }
      case .setStencilReference, .setStencilCompareMask, .setStencilWriteMask:
        if pass == nil { return .invalid("a state command outside a pass") }
        if !features.dynamicState || !features.stencil { return .unsupported("dynamic stencil state") }
      case .setDepthBias:
        if pass == nil { return .invalid("a state command outside a pass") }
        if !features.dynamicState || !features.depthBias { return .unsupported("dynamic depth bias") }
      case .setDepthBounds(let lo, let hi):
        if pass == nil { return .invalid("a state command outside a pass") }
        if lo > hi { return .invalid("depth bounds whose minimum is above the maximum") }
        if !features.dynamicState || !features.depthBounds { return .unsupported("dynamic depth bounds") }
      case .setLineWidth(let w):
        if pass == nil { return .invalid("a state command outside a pass") }
        if w <= 0 { return .invalid("a line of no width") }
        if !features.dynamicState { return .unsupported("dynamic state") }
        if w != 1 && !features.wideLines { return .unsupported("wide lines") }
        if let l = limits, w > l.maxLineWidth { return .unsupported("a line width of \(w)") }
      }
    }
    if pass != nil { return .invalid("a pass that never ends") }
    return nil
  }

  // MARK: Passes

  private func begin(_ info: RenderingInfo) -> GPUError? {
    if info.colors.isEmpty && info.depthStencil == nil { return .invalid("a pass with no attachment") }
    if info.colors.count > 8 { return .invalid("a pass with more than eight attachments") }
    if info.layerCount == 0 { return .invalid("a pass of no layers") }
    if info.viewMask != 0 && info.layerCount != 1 { return .invalid("a multiview pass with layers") }
    let area = info.area
    if area.width == 0 || area.height == 0 || area.x < 0 || area.y < 0
      || Int(area.x) + Int(area.width) > Int(info.width) || Int(area.y) + Int(area.height) > Int(info.height) {
      return .invalid("a render area outside the attachments")
    }
    let layersNeeded = info.viewMask != 0 ? UInt32(32 - info.viewMask.leadingZeroBitCount) : info.layerCount
    for a in info.colors {
      if !a.view.image.usage.contains(.renderTarget) { return .invalid("an attachment that isn't a render target") }
      if let e = a.view.attachmentError() { return e }
      if a.view.format.isDepthStencil || a.view.format.isCompressed { return .invalid("a colour attachment of \(a.view.format)") }
      if a.view.mipCount != 1 { return .invalid("an attachment of more than one mip level") }
      if a.view.dimension == .cube || a.view.dimension == .cubeArray { return .invalid("an attachment that is a cube view") }
      if a.view.width != info.width || a.view.height != info.height { return .invalid("attachments of different sizes") }
      if a.view.samples != info.samples { return .invalid("attachments of different sample counts") }
      if a.view.layerCount < layersNeeded { return .invalid("an attachment with fewer layers than the pass") }
      if a.load == .load && !features.loadAttachments { return .unsupported("a pass that loads its attachment's contents") }
      if case .clear = a.load, a.view.format.channelClass != .float { return .invalid("a float clear of an integer attachment") }
      if let r = a.resolve {
        if a.view.samples == 1 { return .invalid("a resolve of an attachment that isn't multisampled") }
        if let e = r.attachmentError() { return e }
        if !r.image.usage.contains(.renderTarget) { return .invalid("a resolve target that isn't a render target") }
        if r.samples != 1 || r.format != a.view.format || r.width != info.width || r.height != info.height || r.mipCount != 1 {
          return .invalid("a resolve target that doesn't match its attachment")
        }
        if r.layerCount < layersNeeded { return .invalid("a resolve target with fewer layers than the pass") }
      }
    }
    if let d = info.depthStencil {
      if !d.view.image.usage.contains(.depthStencilTarget) { return .invalid("an attachment that isn't a depth and stencil target") }
      if let e = d.view.attachmentError() { return e }
      if !d.view.format.isDepthStencil { return .invalid("a depth attachment of \(d.view.format)") }
      if d.view.aspects != d.view.format.aspects { return .invalid("a depth and stencil attachment that leaves out an aspect") }
      if d.view.mipCount != 1 { return .invalid("an attachment of more than one mip level") }
      if d.view.dimension == .cube || d.view.dimension == .cubeArray { return .invalid("an attachment that is a cube view") }
      if d.view.width != info.width || d.view.height != info.height { return .invalid("attachments of different sizes") }
      if d.view.samples != info.samples { return .invalid("attachments of different sample counts") }
      if d.view.layerCount < layersNeeded { return .invalid("an attachment with fewer layers than the pass") }
      if let r = d.resolve {
        if d.view.samples == 1 { return .invalid("a resolve of an attachment that isn't multisampled") }
        if let e = r.attachmentError() { return e }
        if !r.image.usage.contains(.depthStencilTarget) { return .invalid("a resolve target that isn't a depth and stencil target") }
        if r.samples != 1 || r.format != d.view.format || r.width != info.width || r.height != info.height || r.mipCount != 1 {
          return .invalid("a resolve target that doesn't match its attachment")
        }
      }
      if d.view.format.hasDepth && !features.depth { return .unsupported("depth attachments") }
      if d.view.format.hasStencil && !features.stencil { return .unsupported("stencil attachments") }
      if (d.depthLoad == .load && d.view.format.hasDepth || d.stencilLoad == .load && d.view.format.hasStencil)
        && !features.loadAttachments {
        return .unsupported("a pass that loads its attachment's contents")
      }
      if d.resolve != nil && !features.depthStencilResolve { return .unsupported("a pass that resolves its depth and stencil") }
    }
    // What the device lacks.
    if info.colors.count > 1 && !features.multipleColorAttachments { return .unsupported("a pass with \(info.colors.count) colour attachments") }
    if info.layerCount > 1 && !features.arrayImages { return .unsupported("a pass of \(info.layerCount) layers") }
    if info.viewMask != 0 && !features.multiview { return .unsupported("a multiview pass") }
    if info.samples > 1 && !features.multisample { return .unsupported("a multisampled pass") }
    for a in info.colors {
      if let v = a.view.featureError(features) { return v }
      if a.resolve != nil && !features.resolveAttachments { return .unsupported("a pass that resolves its attachments") }
      if let l = limits {
        let c = l.formats(a.view.format)
        if !c.renderTarget || !c.renderSamples.contains(a.view.samples) { return .unsupported("a render target of \(a.view.format)") }
      }
    }
    if let d = info.depthStencil {
      if let v = d.view.featureError(features) { return v }
      if let l = limits {
        let c = l.formats(d.view.format)
        if !c.depthTarget || !c.depthSamples.contains(d.view.samples) { return .unsupported("a depth target of \(d.view.format)") }
      }
    }
    if let l = limits {
      if info.samples > l.maxSamples { return .unsupported("a pass of \(info.samples) samples") }
      if UInt32(info.colors.count) > l.maxColorAttachments { return .unsupported("a pass with \(info.colors.count) colour attachments") }
      if info.layerCount > l.maxImageArrayLayers { return .unsupported("a pass of \(info.layerCount) layers") }
      if info.viewMask != 0 && layersNeeded > l.maxMultiviewViews { return .unsupported("a view mask of \(info.viewMask)") }
    }
    return nil
  }

  private func drawable(_ p: GPUPipeline, _ pass: RenderingInfo?) -> GPUError? {
    guard let pass else { return .invalid("a draw outside a pass") }
    if p.kind != .graphics { return .invalid("a draw with a compute pipeline") }
    if let t = p.targets {
      var formats: [PixelFormat] = []
      for a in pass.colors { formats.append(a.view.format) }
      if t.colorFormats != formats || t.depthStencilFormat != pass.depthStencil?.view.format || t.samples != pass.samples
        || t.viewMask != pass.viewMask {
        return .invalid("a draw with a pipeline made for other attachments")
      }
    }
    return nil
  }

  private func indirectCount(_ args: GPUMemory, _ offset: Int, _ counts: GPUMemory, _ countOffset: Int, _ maxCount: UInt32,
                             _ stride: UInt32, _ record: Int) -> GPUError? {
    if offset < 0 || offset % 4 != 0 || stride < UInt32(record) || stride % 4 != 0
      || maxCount > 0 && offset + (Int(maxCount) - 1) * Int(stride) + record > args.size {
      return .invalid("indirect arguments past their memory")
    }
    if countOffset < 0 || countOffset % 4 != 0 || countOffset + 4 > counts.size { return .invalid("an indirect count past its memory") }
    return nil
  }

  // MARK: Queries

  private func query(_ set: GPUQuerySet, _ index: Int, _ pass: RenderingInfo?) -> GPUError? {
    switch set.kind {
    case .timestamp: return .invalid("an occlusion query in a timestamp set")
    case .occlusion:
      if !features.occlusionQueries { return .unsupported("occlusion queries") }
      if pass == nil { return .invalid("an occlusion query outside a pass") }
    case .pipelineStatistics(let s):
      if s.rawValue == 0 { return .invalid("a statistics query of no counters") }
      if !features.pipelineStatisticsQueries { return .unsupported("pipeline statistics queries") }
    }
    if index < 0 || index >= set.count { return .invalid("a query past its set") }
    return nil
  }

  // MARK: Copies

  /// The command that copies an image whole: mip 0 of layer 0, tightly packed rows.
  private func wholeImageCopy(_ image: GPUImage, _ m: GPUMemory, _ offset: Int) -> GPUError? {
    if image.format.isDepthStencil { return .invalid("a whole-image copy of a depth or stencil image: name the aspect with regions") }
    if image.samples != 1 { return .invalid("a copy of a multisampled image") }
    if offset < 0 || offset + image.descriptor.byteSize(mip: 0) > m.size { return .invalid("a copy past its memory") }
    return nil
  }

  private func bufferImage(_ image: GPUImage, _ m: GPUMemory, _ regions: [BufferImageRegion]) -> GPUError? {
    if regions.isEmpty { return .invalid("a copy of no regions") }
    if image.samples != 1 { return .invalid("a copy of a multisampled image") }
    for r in regions { if let e = RegionRules.bufferImage(r, image, m) { return e } }
    if !features.imageRegionCopies { return .unsupported("image copies with regions") }
    return nil
  }

  private func copyImage(_ src: GPUImage, _ dst: GPUImage, _ regions: [ImageCopyRegion], _ pass: RenderingInfo?) -> GPUError? {
    if pass != nil { return .invalid("a copy inside a pass") }
    if regions.isEmpty { return .invalid("a copy of no regions") }
    if !src.usage.contains(.copySource) { return .invalid("a copy out of an image that isn't a copy source") }
    if !dst.usage.contains(.copyDestination) { return .invalid("a copy into an image that isn't a copy destination") }
    if src.samples != dst.samples { return .invalid("a copy between images of different sample counts") }
    if !src.format.isCopyCompatible(with: dst.format) { return .invalid("a copy between formats that aren't compatible") }
    for r in regions {
      if let e = RegionRules.layers(r.srcSubresource, src, single: false) { return e }
      if let e = RegionRules.layers(r.dstSubresource, dst, single: false) { return e }
      if r.srcSubresource.aspects != r.dstSubresource.aspects { return .invalid("a copy between different aspects") }
      if r.srcSubresource.layerCount != r.dstSubresource.layerCount { return .invalid("a copy between different numbers of layers") }
      if let e = RegionRules.extent(r.srcOffset, r.extent, src, mip: r.srcSubresource.mip) { return e }
      if let e = RegionRules.extent(r.dstOffset, r.extent, dst, mip: r.dstSubresource.mip) { return e }
      if src.handle == dst.handle && RegionRules.overlaps(r.srcSubresource, r.srcOffset, r.dstSubresource, r.dstOffset, r.extent) {
        return .invalid("a copy onto itself")
      }
    }
    if !features.copyImage { return .unsupported("image copies") }
    return nil
  }

  private func blit(_ src: GPUImage, _ dst: GPUImage, _ regions: [ImageBlitRegion], _ filter: SamplerFilter,
                    _ pass: RenderingInfo?) -> GPUError? {
    if pass != nil { return .invalid("a blit inside a pass") }
    if regions.isEmpty { return .invalid("a blit of no regions") }
    if !src.usage.contains(.copySource) { return .invalid("a blit out of an image that isn't a copy source") }
    if !dst.usage.contains(.copyDestination) { return .invalid("a blit into an image that isn't a copy destination") }
    if src.samples != 1 || dst.samples != 1 { return .invalid("a blit of a multisampled image") }
    if src.format.isCompressed || dst.format.isCompressed { return .invalid("a blit of a compressed image") }
    if src.format.isDepthStencil || dst.format.isDepthStencil {
      if src.format != dst.format { return .invalid("a blit between depth or stencil and another format") }
      if filter != .nearest { return .invalid("a blit of depth or stencil with a filter") }
    } else {
      if src.format.channelClass != dst.format.channelClass { return .invalid("a blit between formats read as different types") }
      if src.format.channelClass != .float && filter != .nearest { return .invalid("a blit of integers with a filter") }
    }
    for r in regions {
      if let e = RegionRules.layers(r.srcSubresource, src, single: false) { return e }
      if let e = RegionRules.layers(r.dstSubresource, dst, single: false) { return e }
      if r.srcSubresource.aspects != r.dstSubresource.aspects { return .invalid("a blit between different aspects") }
      if r.srcSubresource.layerCount != r.dstSubresource.layerCount { return .invalid("a blit between different numbers of layers") }
      if let e = blitCorners(r.srcMin, r.srcMax, src, r.srcSubresource.mip) { return e }
      if let e = blitCorners(r.dstMin, r.dstMax, dst, r.dstSubresource.mip) { return e }
    }
    if !features.blitImage { return .unsupported("image blits") }
    if limits != nil {
      guard let s = caps(src.format), let d = caps(dst.format) else { return nil }
      if !s.blitSource || !d.blitDestination { return .unsupported("a blit of \(src.format) to \(dst.format)") }
      if filter == .linear && !s.filterable { return .unsupported("a linear blit of \(src.format)") }
    }
    return nil
  }

  private func blitCorners(_ lo: Offset3D, _ hi: Offset3D, _ image: GPUImage, _ mip: UInt32) -> GPUError? {
    let m = image.descriptor.mipExtent(mip)
    for (a, b, size) in [(lo.x, hi.x, m.width), (lo.y, hi.y, m.height), (lo.z, hi.z, m.depth)] {
      if a < 0 || b < 0 || a > size || b > size { return .invalid("a blit corner outside the image") }
      if a == b { return .invalid("a blit of no texels") }
    }
    return nil
  }

  private func resolve(_ src: GPUImage, _ dst: GPUImage, _ regions: [ImageCopyRegion], _ pass: RenderingInfo?) -> GPUError? {
    if pass != nil { return .invalid("a resolve inside a pass") }
    if regions.isEmpty { return .invalid("a resolve of no regions") }
    if !src.usage.contains(.copySource) { return .invalid("a resolve out of an image that isn't a copy source") }
    if !dst.usage.contains(.copyDestination) { return .invalid("a resolve into an image that isn't a copy destination") }
    if src.samples == 1 { return .invalid("a resolve of an image that isn't multisampled") }
    if dst.samples != 1 { return .invalid("a resolve into a multisampled image") }
    if src.format != dst.format { return .invalid("a resolve between different formats") }
    if src.format.isDepthStencil || src.format.isCompressed { return .invalid("a resolve of \(src.format)") }
    for r in regions {
      if let e = RegionRules.layers(r.srcSubresource, src, single: false) { return e }
      if let e = RegionRules.layers(r.dstSubresource, dst, single: false) { return e }
      if r.srcSubresource.layerCount != r.dstSubresource.layerCount { return .invalid("a resolve between different numbers of layers") }
      if let e = RegionRules.extent(r.srcOffset, r.extent, src, mip: r.srcSubresource.mip) { return e }
      if let e = RegionRules.extent(r.dstOffset, r.extent, dst, mip: r.dstSubresource.mip) { return e }
    }
    if !features.resolveImage { return .unsupported("image resolves") }
    return nil
  }

  // MARK: Clears

  private func clearColor(_ image: GPUImage, _ color: ClearColor, _ ranges: [ImageSubresourceRange], _ pass: RenderingInfo?) -> GPUError? {
    if pass != nil { return .invalid("a clear inside a pass") }
    if !image.usage.contains(.copyDestination) { return .invalid("a clear of an image that isn't a copy destination") }
    if !image.format.aspects.contains(.color) || image.format.isCompressed { return .invalid("a colour clear of \(image.format)") }
    if image.format.channelClass != color.channelClass { return .invalid("a clear colour of another type than the format's") }
    if ranges.isEmpty { return .invalid("a clear of no ranges") }
    for r in ranges {
      if let e = RegionRules.range(r, image) { return e }
    }
    if !features.clearImage { return .unsupported("image clears") }
    return nil
  }

  private func clearDepthStencil(_ image: GPUImage, _ ranges: [ImageSubresourceRange], _ pass: RenderingInfo?) -> GPUError? {
    if pass != nil { return .invalid("a clear inside a pass") }
    if !image.usage.contains(.copyDestination) { return .invalid("a clear of an image that isn't a copy destination") }
    if !image.format.isDepthStencil { return .invalid("a depth clear of \(image.format)") }
    if ranges.isEmpty { return .invalid("a clear of no ranges") }
    for r in ranges {
      if let e = RegionRules.range(r, image) { return e }
    }
    if !features.clearImage { return .unsupported("image clears") }
    return nil
  }

  private func clearAttachments(_ attachments: [ClearAttachment], _ rects: [ClearRect], _ pass: RenderingInfo?) -> GPUError? {
    guard let pass else { return .invalid("clearing attachments outside a pass") }
    if attachments.isEmpty || rects.isEmpty { return .invalid("a clear of no attachments or rectangles") }
    let area = pass.area
    for r in rects {
      if r.width == 0 || r.height == 0 || r.layerCount == 0 { return .invalid("a clear of no texels") }
      if r.x < Int32(area.x) || r.y < Int32(area.y) || Int(r.x) + Int(r.width) > Int(area.x) + Int(area.width)
        || Int(r.y) + Int(r.height) > Int(area.y) + Int(area.height) {
        return .invalid("a clear outside the render area")
      }
      let layers = pass.viewMask != 0 ? 1 : pass.layerCount
      if Int(r.baseLayer) + Int(r.layerCount) > Int(layers) { return .invalid("a clear past the pass's layers") }
    }
    for a in attachments {
      switch a {
      case .color(let index, let color):
        if index < 0 || index >= pass.colors.count { return .invalid("a clear of a colour attachment the pass doesn't have") }
        if pass.colors[index].view.format.channelClass != color.channelClass {
          return .invalid("a clear colour of another type than the format's")
        }
      case .depthStencil(let aspects, _, _):
        guard let d = pass.depthStencil else { return .invalid("a clear of a depth attachment the pass doesn't have") }
        if aspects.isEmpty || !d.view.format.aspects.contains(aspects) || aspects.contains(.color) {
          return .invalid("a clear of an aspect the attachment doesn't have")
        }
      }
    }
    if !features.clearAttachments { return .unsupported("clearing attachments in a pass") }
    return nil
  }
}
