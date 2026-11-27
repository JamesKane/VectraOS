// SPDX-License-Identifier: BSD-3-Clause

// Textures (gles(3), "Textures"): their names and units, their parameters, their storage and uploads, copies from the
// framebuffer and mipmap generation. An upload is converted into the upload ring and copied into the texture's image in
// the open list, in GL's order: a pass that reads or draws into the image ends first.

import GPUCore

extension GLContext {
  func boundTexture(_ target: GLenum) -> GLTexture? {
    switch target {
    case GL_TEXTURE_2D: textures2D[activeTexture] ?? default2D
    case GL_TEXTURE_CUBE_MAP: texturesCube[activeTexture] ?? defaultCube
    default: nil
    }
  }

  func setActiveTexture(_ unit: GLenum) {
    guard unit >= GL_TEXTURE0, unit < GL_TEXTURE0 + GLenum(GLContext.textureUnits) else { return fail(.invalidEnum) }
    activeTexture = Int(unit - GL_TEXTURE0)
  }

  func bindTexture(_ target: GLenum, _ name: GLuint) {
    guard target == GL_TEXTURE_2D || target == GL_TEXTURE_CUBE_MAP else { return fail(.invalidEnum) }
    var t: GLTexture? = nil
    if name != 0 {
      if let existing = share.textures[name] {
        if existing.target == 0 {
          existing.target = target
          existing.levels = [[TextureLevel?]](repeating: [], count: existing.faces)
        }
        guard existing.target == target else { return fail(.invalidOperation) }
        t = existing
      } else {
        let made = GLTexture(name: name)
        made.target = target
        made.levels = [[TextureLevel?]](repeating: [], count: made.faces)
        share.textures.insert(name, made)
        t = made
      }
    }
    if target == GL_TEXTURE_2D { textures2D[activeTexture] = t } else { texturesCube[activeTexture] = t }
  }

  func deleteTextures(_ n: GLsizei, _ names: UnsafePointer<GLuint>?) {
    guard n >= 0 else { return fail(.invalidValue) }
    guard let names = unsafe names else { return }
    for i in 0..<Int(n) {
      let name = unsafe names[i]
      guard name != 0, let t = share.textures.remove(name) else { continue }
      for u in 0..<GLContext.textureUnits {
        if textures2D[u] === t { textures2D[u] = nil }
        if texturesCube[u] === t { texturesCube[u] = nil }
      }
      if let f = framebuffer { detach(t, from: f) }
      t.deleted = true
      dropImage(t)
    }
  }

  /// Gives back a texture's image and slot, once the open list that may read them is submitted.
  func dropImage(_ t: GLTexture) {
    if let image = t.image { releaseImage(image) }
    if let s = t.slot { frame.heap.releaseTextureSlot(s) }
    t.image = nil
    t.slot = nil
    t.completeCache = nil
    attachmentSerial &+= 1
  }

  // MARK: Parameters

  func texParameter(_ target: GLenum, _ pname: GLenum, int value: GLint?, float fvalue: Float?) {
    guard let t = boundTexture(target) else { return fail(.invalidEnum) }
    let v = GLenum(bitPattern: value ?? Int32(fvalue ?? 0))
    switch pname {
    case GL_TEXTURE_MIN_FILTER:
      guard [GL_NEAREST, GL_LINEAR, GL_NEAREST_MIPMAP_NEAREST, GL_LINEAR_MIPMAP_NEAREST, GL_NEAREST_MIPMAP_LINEAR,
             GL_LINEAR_MIPMAP_LINEAR].contains(v)
      else { return fail(.invalidEnum) }
      t.minFilter = v
    case GL_TEXTURE_MAG_FILTER:
      guard v == GL_NEAREST || v == GL_LINEAR else { return fail(.invalidEnum) }
      t.magFilter = v
    case GL_TEXTURE_WRAP_S, GL_TEXTURE_WRAP_T:
      guard v == GL_REPEAT || v == GL_CLAMP_TO_EDGE || v == GL_MIRRORED_REPEAT else { return fail(.invalidEnum) }
      if pname == GL_TEXTURE_WRAP_S { t.wrapS = v } else { t.wrapT = v }
    case GL_TEXTURE_MAX_ANISOTROPY_EXT:
      let a = fvalue ?? Float(value ?? 1)
      guard a >= 1 else { return fail(.invalidValue) }
      t.maxAnisotropy = frame.limits.features.samplerAnisotropy ? min(a, frame.limits.maxAnisotropy) : 1
    default: return fail(.invalidEnum)
    }
    t.samplerSlot = nil
    t.completeCache = nil
  }

  func texParameterValue(_ target: GLenum, _ pname: GLenum) -> Float? {
    guard let t = boundTexture(target) else {
      fail(.invalidEnum)
      return nil
    }
    switch pname {
    case GL_TEXTURE_MIN_FILTER: return Float(t.minFilter)
    case GL_TEXTURE_MAG_FILTER: return Float(t.magFilter)
    case GL_TEXTURE_WRAP_S: return Float(t.wrapS)
    case GL_TEXTURE_WRAP_T: return Float(t.wrapT)
    case GL_TEXTURE_MAX_ANISOTROPY_EXT: return t.maxAnisotropy
    default:
      fail(.invalidEnum)
      return nil
    }
  }

  // MARK: Storage

  /// The texture and face an image target names (TEXTURE_2D, or a cube's face), or nil for one that isn't.
  func imageTarget(_ target: GLenum) -> (GLTexture, face: Int)? {
    if target == GL_TEXTURE_2D { return boundTexture(GL_TEXTURE_2D).map { ($0, 0) } }
    if target >= GL_TEXTURE_CUBE_MAP_POSITIVE_X && target <= GL_TEXTURE_CUBE_MAP_NEGATIVE_Z {
      return boundTexture(GL_TEXTURE_CUBE_MAP).map { ($0, Int(target - GL_TEXTURE_CUBE_MAP_POSITIVE_X)) }
    }
    return nil
  }

  var maxTextureSize: Int32 { min(frame.limits.maxImageDimension, 4096) }

  /// The device storage of a texture of GL format `format` and `type`.
  func textureStorage(_ format: GLenum, _ type: GLenum) -> StorageKind {
    switch format {
    case GL_DEPTH_COMPONENT:
      return .depth(type == GL_UNSIGNED_SHORT ? .depth16 : .depth32f)
    case GL_DEPTH_STENCIL_OES:
      return frame.limits.formats(.depth24stencil8).sampled ? .depthStencil(.depth24stencil8) : .depth(.depth32f)
    default: return .color(alpha: formatHasAlpha(format))
    }
  }

  /// Makes the texture's image for its level 0 of `width` by `height`, of `kind`, if it hasn't one of that already.
  func ensureImage(_ t: GLTexture, width: Int32, height: Int32, kind: StorageKind) throws(GPUError) {
    let format = kind.pixelFormat
    let cube = t.target == GL_TEXTURE_CUBE_MAP
    let mips: UInt32
    let usage: ImageUsage
    switch kind {
    case .color:
      mips = fullMipCount(width, height)
      usage = .sampled | .renderTarget | .copySource | .copyDestination
      // Storage too where the format has it: the Mali backend maps a storage image's memory cacheable for the GPU, and only
      // a storage image's, so a texture is read through the GPU's caches.
      if frame.limits.formats(format).storage { usage = usage | .storage }
    default:
      mips = 1
      usage = .sampled | .depthStencilTarget | .copyDestination
    }
    if let i = t.image, i.width == width, i.height == height, i.format == format, i.mipLevels == mips { return }
    dropImage(t)
    let image = try device.makeImage(ImageDescriptor(format: format, width: width, height: height, mipLevels: mips,
                                                     layers: cube ? 6 : 1, dimension: cube ? .cube : .d2, usage: usage))
    t.image = image
    t.kind = kind
    let slot = try frame.heap.takeTextureSlot()
    try device.writeTexture(slot, image)
    t.slot = slot
    frame.stats.textureWrites += 1
    frame.stats.images += 1
  }

  /// Ends the open pass if it reads `image` or draws into it: what follows in the list changes it. (A copy is never inside
  /// a pass, so every upload and copy ends the open pass whatever it reads.)
  func endPassUsing(_ image: GPUImage) {
    guard let p = frame.pass else { return }
    if p.reads.contains(image.handle) || p.target.color?.image == image || p.target.depthStencil?.image == image {
      frame.endPass()
    }
  }

  /// Converts `width` by `height` client pixels at `pixels` and copies them into mip `level` of layer `face` of the
  /// texture's image, at (`x`, `y`).
  func upload(_ t: GLTexture, face: Int, level: Int, x: Int32, y: Int32, width: Int32, height: Int32, format: GLenum,
              type: GLenum, pixels: UnsafeRawPointer, pixelBytes: Int) throws(GPUError) {
    guard let image = t.image, width > 0, height > 0, level < Int(image.mipLevels) else { return }
    let deviceBytes = image.format.texelBlock.bytes
    let staging = try frame.ring.allocate(Int(width) * Int(height) * deviceBytes)
    let rowBytes = clientRowBytes(width: Int(width), pixelBytes: pixelBytes, alignment: unpackAlignment)
    unsafe convertToDevice(pixels, width: Int(width), height: Int(height), rowBytes: rowBytes, format: format, type: type,
                           into: staging.pointer, deviceFormat: image.format)
    frame.endPass()
    frame.barrier(before: [image.handle])
    let aspects: ImageAspects = image.format.isDepthStencil ? (image.format.hasDepth ? .depth : .stencil) : .color
    frame.list.copy(staging.memory, to: image, regions: [
      BufferImageRegion(bufferOffset: staging.offset,
                        subresource: ImageSubresourceLayers(aspects: aspects, mip: UInt32(level), baseLayer: UInt32(face)),
                        imageOffset: Offset3D(x: x, y: y), imageExtent: Extent3D(width: UInt32(width), height: UInt32(height))),
    ])
    frame.noteWrite(image)
  }

  func texImage2D(_ target: GLenum, _ level: GLint, _ internalFormat: GLint, _ width: GLsizei, _ height: GLsizei,
                  _ border: GLint, _ format: GLenum, _ type: GLenum, _ pixels: UnsafeRawPointer?) {
    guard let (t, face) = imageTarget(target) else { return fail(.invalidEnum) }
    let pixelBytes: Int
    switch clientPixelBytes(format: format, type: type) {
    case .success(let b): pixelBytes = b
    case .failure(let e): return fail(e)
    }
    guard level >= 0, level < Int32(fullMipCount(maxTextureSize, maxTextureSize)), width >= 0, height >= 0,
      width <= maxTextureSize >> level, height <= maxTextureSize >> level, border == 0
    else { return fail(.invalidValue) }
    guard GLenum(bitPattern: internalFormat) == format else {
      return fail(isKnownFormat(GLenum(bitPattern: internalFormat)) ? .invalidOperation : .invalidValue)
    }
    if target != GL_TEXTURE_2D && width != height { return fail(.invalidValue) }
    let isDepth = format == GL_DEPTH_COMPONENT || format == GL_DEPTH_STENCIL_OES
    if isDepth && (target != GL_TEXTURE_2D || level != 0) { return fail(.invalidOperation) }
    // The level as GL has it now.
    while t.levels[face].count <= Int(level) { t.levels[face].append(nil) }
    t.levels[face][Int(level)] = TextureLevel(width: width, height: height, internalFormat: format)
    t.completeCache = nil
    let kind = textureStorage(format, type)
    do throws(GPUError) {
      if level == 0 && width > 0 && height > 0 {
        try ensureImage(t, width: width, height: height, kind: kind)
        attachmentSerial &+= 1
      } else if t.image == nil, let base = t.level(face: 0, 0), base.width > 0 {
        try ensureImage(t, width: base.width, height: base.height, kind: textureStorage(base.internalFormat, GL_UNSIGNED_BYTE))
      }
      if level == 0, case .color(let alpha) = kind, case .color = t.kind { t.kind = .color(alpha: alpha) }
      if let pixels = unsafe pixels {
        try unsafe upload(t, face: face, level: Int(level), x: 0, y: 0, width: width, height: height, format: format, type: type,
                          pixels: pixels, pixelBytes: pixelBytes)
      }
    } catch { fail(error) }
  }

  func texSubImage2D(_ target: GLenum, _ level: GLint, _ x: GLint, _ y: GLint, _ width: GLsizei, _ height: GLsizei,
                     _ format: GLenum, _ type: GLenum, _ pixels: UnsafeRawPointer?) {
    guard let (t, face) = imageTarget(target) else { return fail(.invalidEnum) }
    let pixelBytes: Int
    switch clientPixelBytes(format: format, type: type) {
    case .success(let b): pixelBytes = b
    case .failure(let e): return fail(e)
    }
    guard level >= 0, width >= 0, height >= 0, x >= 0, y >= 0 else { return fail(.invalidValue) }
    guard let lv = t.level(face: face, Int(level)) else { return fail(.invalidOperation) }
    guard x + width <= lv.width, y + height <= lv.height else { return fail(.invalidValue) }
    guard lv.internalFormat == format else { return fail(.invalidOperation) }
    guard let pixels = unsafe pixels, width > 0, height > 0 else { return }
    do throws(GPUError) {
      try unsafe upload(t, face: face, level: Int(level), x: x, y: y, width: width, height: height, format: format, type: type,
                        pixels: pixels, pixelBytes: pixelBytes)
    } catch { fail(error) }
  }

  /// Copies a rectangle of the framebuffer's colour into mip `level` of layer `face` of `image` at (`dx`, `dy`): the
  /// framebuffer's (`x`, `y`) is GL's, from its bottom row, clamped to it.
  func copyFromFramebuffer(_ image: GPUImage, face: Int, level: Int, dx: Int32, dy: Int32, x: Int32, y: Int32, width: Int32,
                           height: Int32, from target: RenderTarget) {
    guard let src = target.color else { return }
    // The part of the rectangle inside the framebuffer.
    let x0 = max(x, 0), y0 = max(y, 0)
    let x1 = min(x + width, target.width), y1 = min(y + height, target.height)
    guard x1 > x0, y1 > y0 else { return }
    let ox = dx + (x0 - x), oy = dy + (y0 - y)
    frame.endPass()
    frame.barrier(before: [src.image.handle, image.handle])
    let srcLayers = ImageSubresourceLayers(mip: src.baseMip, baseLayer: src.baseLayer)
    let dstLayers = ImageSubresourceLayers(mip: UInt32(level), baseLayer: UInt32(face))
    if target.flipped || src.format != image.format {
      // A window's rows run from the top, and its format may be blue-first: a blit flips and converts.
      let sy0 = target.flipped ? target.height - y1 : y0, sy1 = target.flipped ? target.height - y0 : y1
      frame.list.blitImage(src.image, to: image, regions: [
        ImageBlitRegion(srcSubresource: srcLayers, srcMin: Offset3D(x: x0, y: target.flipped ? sy1 : sy0),
                        srcMax: Offset3D(x: x1, y: target.flipped ? sy0 : sy1, z: 1), dstSubresource: dstLayers,
                        dstMin: Offset3D(x: ox, y: oy), dstMax: Offset3D(x: ox + (x1 - x0), y: oy + (y1 - y0), z: 1)),
      ], filter: .nearest)
    } else {
      frame.list.copyImage(src.image, to: image, regions: [
        ImageCopyRegion(srcSubresource: srcLayers, srcOffset: Offset3D(x: x0, y: y0), dstSubresource: dstLayers,
                        dstOffset: Offset3D(x: ox, y: oy), extent: Extent3D(width: UInt32(x1 - x0), height: UInt32(y1 - y0))),
      ])
    }
    frame.noteWrite(image)
  }

  /// Whether a framebuffer of `target` can be copied into a texture of GL format `format` (GL ES 2.0's table 3.9).
  func copyCompatible(_ format: GLenum, _ target: RenderTarget) -> Bool {
    guard target.color != nil else { return false }
    switch format {
    case GL_ALPHA, GL_LUMINANCE_ALPHA, GL_RGBA: return target.alphaBits > 0
    case GL_LUMINANCE, GL_RGB: return true
    default: return false
    }
  }

  func copyTexImage2D(_ target: GLenum, _ level: GLint, _ internalFormat: GLenum, _ x: GLint, _ y: GLint, _ width: GLsizei,
                      _ height: GLsizei, _ border: GLint) {
    guard let (t, face) = imageTarget(target) else { return fail(.invalidEnum) }
    guard isKnownFormat(internalFormat), internalFormat != GL_DEPTH_COMPONENT, internalFormat != GL_DEPTH_STENCIL_OES,
      internalFormat != GL_BGRA_EXT
    else { return fail(.invalidValue) }
    guard level >= 0, width >= 0, height >= 0, width <= maxTextureSize >> level, height <= maxTextureSize >> level, border == 0
    else { return fail(.invalidValue) }
    if target != GL_TEXTURE_2D && width != height { return fail(.invalidValue) }
    guard let fb = currentTarget() else { return }
    guard copyCompatible(internalFormat, fb) else { return fail(.invalidOperation) }
    while t.levels[face].count <= Int(level) { t.levels[face].append(nil) }
    t.levels[face][Int(level)] = TextureLevel(width: width, height: height, internalFormat: internalFormat)
    t.completeCache = nil
    do throws(GPUError) {
      if level == 0 && width > 0 && height > 0 {
        try ensureImage(t, width: width, height: height, kind: .color(alpha: formatHasAlpha(internalFormat)))
        attachmentSerial &+= 1
      }
      guard let image = t.image, width > 0, height > 0 else { return }
      copyFromFramebuffer(image, face: face, level: Int(level), dx: 0, dy: 0, x: x, y: y, width: width, height: height, from: fb)
    } catch { fail(error) }
  }

  func copyTexSubImage2D(_ target: GLenum, _ level: GLint, _ xoffset: GLint, _ yoffset: GLint, _ x: GLint, _ y: GLint,
                         _ width: GLsizei, _ height: GLsizei) {
    guard let (t, face) = imageTarget(target) else { return fail(.invalidEnum) }
    guard level >= 0, width >= 0, height >= 0, xoffset >= 0, yoffset >= 0 else { return fail(.invalidValue) }
    guard let lv = t.level(face: face, Int(level)) else { return fail(.invalidOperation) }
    guard xoffset + width <= lv.width, yoffset + height <= lv.height else { return fail(.invalidValue) }
    guard let fb = currentTarget() else { return }
    guard copyCompatible(lv.internalFormat, fb) else { return fail(.invalidOperation) }
    guard let image = t.image, width > 0, height > 0 else { return }
    copyFromFramebuffer(image, face: face, level: Int(level), dx: xoffset, dy: yoffset, x: x, y: y, width: width,
                        height: height, from: fb)
  }

  func generateMipmap(_ target: GLenum) {
    guard target == GL_TEXTURE_2D || target == GL_TEXTURE_CUBE_MAP, let t = boundTexture(target) else { return fail(.invalidEnum) }
    guard let base = t.level(face: 0, 0), let image = t.image, case .color = t.kind else { return fail(.invalidOperation) }
    for f in 0..<t.faces where t.level(face: f, 0) != base { return fail(.invalidOperation) }
    let count = Int(fullMipCount(base.width, base.height))
    for f in 0..<t.faces {
      while t.levels[f].count < count { t.levels[f].append(nil) }
      for l in 1..<max(count, 1) {
        t.levels[f][l] = TextureLevel(width: max(1, base.width >> Int32(l)), height: max(1, base.height >> Int32(l)),
                                      internalFormat: base.internalFormat)
      }
    }
    t.completeCache = nil
    guard count > 1 else { return }
    frame.endPass()
    frame.barrier(before: [image.handle])
    for l in 1..<count {
      let src = image.descriptor.mipExtent(UInt32(l - 1)), dst = image.descriptor.mipExtent(UInt32(l))
      frame.list.blitImage(image, to: image, regions: [
        ImageBlitRegion(srcSubresource: ImageSubresourceLayers(mip: UInt32(l - 1), baseLayer: 0, layerCount: UInt32(t.faces)),
                        srcMax: Offset3D(x: src.width, y: src.height, z: 1),
                        dstSubresource: ImageSubresourceLayers(mip: UInt32(l), baseLayer: 0, layerCount: UInt32(t.faces)),
                        dstMax: Offset3D(x: dst.width, y: dst.height, z: 1)),
      ], filter: .linear)
      frame.list.barrier(from: .transfer, to: .transfer)
    }
    frame.noteWrite(image)
  }

  /// The heap slots a draw names for the texture on `unit` that a sampler of the program reads: the texture's, or the
  /// incomplete texture's.
  func samplerSlots(unit: Int, cube: Bool) throws(GPUError) -> (texture: UInt32, sampler: UInt32, image: UInt64?) {
    let t = (cube ? texturesCube[unit] ?? defaultCube : textures2D[unit] ?? default2D)
    guard t.isComplete, let slot = t.slot, let image = t.image else {
      let s = try sampler(for: SamplerDescriptor(filter: .nearest))
      return (try frame.incompleteSlot(cube: cube), s, nil)
    }
    if let s = t.samplerSlot, frame.heap.samplerValid(s, t.samplerGeneration, epoch: frame.epoch) {
      return (slot, s, image.handle)
    }
    var d = t.samplerDescriptor
    // A device whose samplers have one filter (Mali, so far) takes the magnification filter for both.
    if d.minFilter != d.magFilter && !frame.limits.features.samplerMinMagFilters { d.minFilter = d.magFilter }
    var found = try frame.heap.samplerSlot(d, epoch: frame.epoch)
    if found == nil {
      // Every sampler slot is read by the open list: submit it, and the slots are free to be written again.
      try frame.submit()
      found = try frame.heap.samplerSlot(d, epoch: frame.epoch)
    }
    guard let (s, g) = found else { throw .outOfMemory("the heap's sampler slots") }
    t.samplerSlot = s
    t.samplerGeneration = g
    return (slot, s, image.handle)
  }

  func sampler(for d: SamplerDescriptor) throws(GPUError) -> UInt32 {
    if let (s, _) = try frame.heap.samplerSlot(d, epoch: frame.epoch) { return s }
    try frame.submit()
    guard let (s, _) = try frame.heap.samplerSlot(d, epoch: frame.epoch) else { throw .outOfMemory("the heap's sampler slots") }
    return s
  }
}
