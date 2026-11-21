// SPDX-License-Identifier: BSD-3-Clause

// Copies, blits, clears and fills (gpucore(2), D174's amendment): done by the CPU in order with the GPU's passes, as the
// other copies of this backend are. Every image is linear in CPU-visible memory (no AFBC, which only the tile-write path can
// produce), so the transfer is a walk over rows; nothing here is a copy engine, the hardware has none (valhall 05 section
// 5.11.10.1 says what the reference's draws and kernels do for the layouts this backend doesn't use). Compressed formats are
// plain block copies. A step of the CPU reads what the GPU wrote before it (`submit` brings the CPU's caches up to date first).

import GPUCore

#if canImport(MaliCore)
  import MaliCore
#endif

enum Transfer {
  case copyImage(ImageRecord, ImageRecord, [ImageCopyRegion])
  case blit(ImageRecord, ImageRecord, [ImageBlitRegion], SamplerFilter)
  case bufferToImage(Region, ImageRecord, [BufferImageRegion])
  case imageToBuffer(ImageRecord, Region, [BufferImageRegion])
  case fill(Region, Int, Int, UInt32)
  case update(Region, Int, [UInt8])
  case clearColor(ImageRecord, ClearColor, [ImageSubresourceRange])
  case clearDepthStencil(ImageRecord, Float, UInt32, [ImageSubresourceRange])
}

extension MaliDevice {
  func plane(_ r: ImageRecord, _ aspect: ImageAspects) -> AspectPlane? {
    for p in r.planes where p.aspect == aspect { return p }
    return nil
  }

  func spot(_ r: ImageRecord, _ p: AspectPlane, mip: Int, layer: Int, x: Int, y: Int, z: Int) -> UnsafeMutableRawPointer {
    unsafe r.region.buffer.pointer + p.offset + p.layout.texelOffset(x: x, y: y, level: mip, layer: layer, z: z)
  }

  /// The aspects of `a` the image has, one at a time.
  func singleAspects(_ a: ImageAspects) -> [ImageAspects] {
    var out: [ImageAspects] = []
    for x in [ImageAspects.color, .depth, .stencil] where a.contains(x) { out.append(x) }
    return out
  }

  func runTransfer(_ t: Transfer) {
    switch t {
    case .copyImage(let a, let b, let regions): copyImages(a, b, regions)
    case .blit(let a, let b, let regions, let filter): blitImages(a, b, regions, filter)
    case .bufferToImage(let m, let i, let regions): bufferImage(m, i, regions, toImage: true)
    case .imageToBuffer(let i, let m, let regions): bufferImage(m, i, regions, toImage: false)
    case .fill(let m, let offset, let bytes, let value):
      m.touched = true
      var i = 0
      while i < bytes {
        let shift = UInt32((i & 3) * 8)
        unsafe m.buffer.pointer.storeBytes(of: UInt8(truncatingIfNeeded: value >> shift), toByteOffset: offset + i, as: UInt8.self)
        i += 1
      }
    case .update(let m, let offset, let data):
      m.touched = true
      for (i, b) in data.enumerated() { unsafe m.buffer.pointer.storeBytes(of: b, toByteOffset: offset + i, as: UInt8.self) }
    case .clearColor(let i, let color, let ranges): clearColorImage(i, color, ranges)
    case .clearDepthStencil(let i, let depth, let stencil, let ranges): clearDepthStencil(i, depth, stencil, ranges)
    }
  }

  // MARK: Image to image

  func copyImages(_ a: ImageRecord, _ b: ImageRecord, _ regions: [ImageCopyRegion]) {
    b.region.touched = true
    for r in regions {
      for aspect in singleAspects(r.srcSubresource.aspects) {
        guard let sp = plane(a, aspect), let dp = plane(b, aspect) else { continue }
        let bw = sp.texel.blockWidth, bh = sp.texel.blockHeight, bytes = sp.texel.bytesPerTexel
        let across = (Int(r.extent.width) + bw - 1) / bw
        let down = (Int(r.extent.height) + bh - 1) / bh
        let rowBytes = across * bytes
        let layers = Int(r.srcSubresource.layerCount)
        for l in 0..<layers {
          for z in 0..<Int(r.extent.depth) {
            for y in 0..<down {
              let from = unsafe spot(a, sp, mip: Int(r.srcSubresource.mip), layer: Int(r.srcSubresource.baseLayer) + l,
                              x: Int(r.srcOffset.x), y: Int(r.srcOffset.y) + y * bh, z: Int(r.srcOffset.z) + z)
              let to = unsafe spot(b, dp, mip: Int(r.dstSubresource.mip), layer: Int(r.dstSubresource.baseLayer) + l,
                            x: Int(r.dstOffset.x), y: Int(r.dstOffset.y) + y * bh, z: Int(r.dstOffset.z) + z)
              // An image copied onto itself may overlap.
              unsafe to.copyMemory(from: UnsafeRawPointer(from), byteCount: rowBytes)
            }
          }
        }
      }
    }
  }

  // MARK: Buffer and image

  func bufferImage(_ m: Region, _ i: ImageRecord, _ regions: [BufferImageRegion], toImage: Bool) {
    if toImage { i.region.touched = true } else { m.touched = true }
    for r in regions {
      for aspect in singleAspects(r.subresource.aspects) {
        guard let p = plane(i, aspect) else { continue }
        let bw = p.texel.blockWidth, bh = p.texel.blockHeight, bytes = p.texel.bytesPerTexel
        let across = (Int(r.imageExtent.width) + bw - 1) / bw
        let down = (Int(r.imageExtent.height) + bh - 1) / bh
        let rowLength = r.bufferRowLength != 0 ? Int(r.bufferRowLength) : Int(r.imageExtent.width)
        let imageHeight = r.bufferImageHeight != 0 ? Int(r.bufferImageHeight) : Int(r.imageExtent.height)
        let rowStride = (rowLength + bw - 1) / bw * bytes
        let sliceStride = (imageHeight + bh - 1) / bh * rowStride
        let depth = Int(r.imageExtent.depth)
        let layers = Int(r.subresource.layerCount)
        var n = 0
        for l in 0..<layers {
          for z in 0..<depth {
            for y in 0..<down {
              let image = unsafe spot(i, p, mip: Int(r.subresource.mip), layer: Int(r.subresource.baseLayer) + l,
                               x: Int(r.imageOffset.x), y: Int(r.imageOffset.y) + y * bh, z: Int(r.imageOffset.z) + z)
              let buffer = unsafe m.buffer.pointer + r.bufferOffset + n * sliceStride + y * rowStride
              if toImage {
                unsafe image.copyMemory(from: UnsafeRawPointer(buffer), byteCount: across * bytes)
              } else {
                unsafe buffer.copyMemory(from: UnsafeRawPointer(image), byteCount: across * bytes)
              }
            }
            n += 1
          }
        }
      }
    }
  }

  // MARK: Blits

  func blitImages(_ a: ImageRecord, _ b: ImageRecord, _ regions: [ImageBlitRegion], _ filter: SamplerFilter) {
    b.region.touched = true
    for r in regions {
      for aspect in singleAspects(r.srcSubresource.aspects) {
        guard let sp = plane(a, aspect), let dp = plane(b, aspect) else { continue }
        let sf = a.descriptor.format, df = b.descriptor.format
        let color = aspect == .color
        let smip = Int(r.srcSubresource.mip), dmip = Int(r.dstSubresource.mip)
        // Destination texels run from the lesser corner to the greater; the source is walked from its first corner toward its
        // second, so a corner past the other flips.
        let dx0 = min(r.dstMin.x, r.dstMax.x), dx1 = max(r.dstMin.x, r.dstMax.x)
        let dy0 = min(r.dstMin.y, r.dstMax.y), dy1 = max(r.dstMin.y, r.dstMax.y)
        let dz0 = min(r.dstMin.z, r.dstMax.z), dz1 = max(r.dstMin.z, r.dstMax.z)
        let flipX = r.dstMax.x < r.dstMin.x, flipY = r.dstMax.y < r.dstMin.y, flipZ = r.dstMax.z < r.dstMin.z
        let sw = Float(r.srcMax.x - r.srcMin.x), sh = Float(r.srcMax.y - r.srcMin.y), sd = Float(r.srcMax.z - r.srcMin.z)
        let w = Float(dx1 - dx0), h = Float(dy1 - dy0), d = Float(dz1 - dz0)
        let sl = sp.layout.levels[smip]
        for l in 0..<Int(r.dstSubresource.layerCount) {
          for dz in dz0..<max(dz1, dz0 + 1) {
            for dy in dy0..<dy1 {
              for dx in dx0..<dx1 {
                var u = (Float(dx - dx0) + 0.5) / w
                var v = (Float(dy - dy0) + 0.5) / h
                var t = d > 0 ? (Float(dz - dz0) + 0.5) / d : 0.5
                if flipX { u = 1 - u }
                if flipY { v = 1 - v }
                if flipZ { t = 1 - t }
                let sx = Float(r.srcMin.x) + u * sw - 0.5
                let sy = Float(r.srcMin.y) + v * sh - 0.5
                let sz = Int(Float(r.srcMin.z) + t * sd)
                var value: [Float]
                func fetch(_ x: Int, _ y: Int) -> [Float] {
                  let cx = min(max(x, 0), sl.width - 1), cy = min(max(y, 0), sl.height - 1)
                  let p = unsafe spot(a, sp, mip: smip, layer: Int(r.srcSubresource.baseLayer) + l, x: cx, y: cy, z: min(max(sz, 0), sl.depth - 1))
                  if color { return unsafe TexelCodec.decode(sf, UnsafeRawPointer(p)) }
                  return unsafe [Self.depthValue(sf, aspect, UnsafeRawPointer(p)), 0, 0, 1]
                }
                if filter == .nearest || sf.channelClass != .float || !color {
                  let nx = Int((sx + 0.5).rounded(.down)), ny = Int((sy + 0.5).rounded(.down))
                  value = fetch(nx, ny)
                } else {
                  let x0 = Int(sx.rounded(.down)), y0 = Int(sy.rounded(.down))
                  let fx = sx - Float(x0), fy = sy - Float(y0)
                  let p00 = fetch(x0, y0), p10 = fetch(x0 + 1, y0), p01 = fetch(x0, y0 + 1), p11 = fetch(x0 + 1, y0 + 1)
                  value = [0, 0, 0, 0]
                  for c in 0..<4 {
                    let top = p00[c] + (p10[c] - p00[c]) * fx
                    let bottom = p01[c] + (p11[c] - p01[c]) * fx
                    value[c] = top + (bottom - top) * fy
                  }
                }
                let to = unsafe spot(b, dp, mip: dmip, layer: Int(r.dstSubresource.baseLayer) + l, x: Int(dx), y: Int(dy), z: Int(dz))
                if color {
                  unsafe TexelCodec.encode(df, value, to: to)
                } else {
                  unsafe Self.storeDepth(df, aspect, value[0], to: to)
                }
              }
            }
          }
        }
      }
    }
  }

  // MARK: Depth and stencil texels

  /// The depth of a texel of a depth plane, or the stencil value, as a float.
  static func depthValue(_ f: PixelFormat, _ aspect: ImageAspects, _ p: UnsafeRawPointer) -> Float {
    if aspect == .stencil { return Float(unsafe p.load(as: UInt8.self)) }
    switch f {
    case .depth16: return Float(unsafe p.loadUnaligned(as: UInt16.self)) / 65535
    case .depth32f, .depth32fstencil8: return Float(bitPattern: unsafe p.loadUnaligned(as: UInt32.self))
    default: return Float(unsafe p.loadUnaligned(as: UInt32.self) & 0xFF_FFFF) / 16_777_215
    }
  }

  static func storeDepth(_ f: PixelFormat, _ aspect: ImageAspects, _ v: Float, to p: UnsafeMutableRawPointer) {
    if aspect == .stencil {
      unsafe p.storeBytes(of: UInt8(min(max(v, 0), 255)), as: UInt8.self)
      return
    }
    switch f {
    case .depth16: unsafe p.storeBytes(of: UInt16(min(max(v, 0), 1) * 65535 + 0.5), as: UInt16.self)
    case .depth32f, .depth32fstencil8: unsafe p.storeBytes(of: v.bitPattern, as: UInt32.self)
    default: unsafe p.storeBytes(of: UInt32(min(max(v, 0), 1) * 16_777_215 + 0.5), as: UInt32.self)
    }
  }

  // MARK: Clears

  func clearColorImage(_ i: ImageRecord, _ color: ClearColor, _ ranges: [ImageSubresourceRange]) {
    i.region.touched = true
    guard let p = plane(i, .color) else { return }
    let f = i.descriptor.format
    var value: [Float]
    var raw: [UInt32] = [0, 0, 0, 0]
    var integer = false
    switch color {
    case .float(let r, let g, let b, let a): value = [r, g, b, a]
    case .uint(let r, let g, let b, let a):
      value = [Float(r), Float(g), Float(b), Float(a)]
      raw = [r, g, b, a]
      integer = true
    case .sint(let r, let g, let b, let a):
      value = [Float(r), Float(g), Float(b), Float(a)]
      raw = [UInt32(bitPattern: r), UInt32(bitPattern: g), UInt32(bitPattern: b), UInt32(bitPattern: a)]
      integer = true
    }
    // A texel, made once.
    var texel = [UInt8](repeating: 0, count: max(p.texel.bytesPerTexel, 16))
    texel.withUnsafeMutableBytes { buffer in
      let base = unsafe buffer.baseAddress!
      if integer, let c = TexelCodec.channels(f) {
        for k in 0..<c.count { unsafe TexelCodec.store(base, k * c.bits / 8, bits: c.bits, raw[k]) }
      } else if TexelCodec.handles(f) {
        unsafe TexelCodec.encode(f, value, to: base)
      }
    }
    for range in ranges where range.aspects.contains(.color) {
      for mip in Int(range.baseMip)..<Int(range.baseMip + range.mipCount) {
        let level = p.layout.levels[mip]
        let across = (level.width + p.texel.blockWidth - 1) / p.texel.blockWidth
        let down = (level.height + p.texel.blockHeight - 1) / p.texel.blockHeight
        let bytes = p.texel.bytesPerTexel
        for layer in Int(range.baseLayer)..<Int(range.baseLayer + range.layerCount) {
          for z in 0..<level.depth {
            for y in 0..<down {
              let row = unsafe spot(i, p, mip: mip, layer: layer, x: 0, y: y * p.texel.blockHeight, z: z)
              for x in 0..<across {
                texel.withUnsafeBytes { unsafe (row + x * bytes).copyMemory(from: $0.baseAddress!, byteCount: bytes) }
              }
            }
          }
        }
      }
    }
  }

  func clearDepthStencil(_ i: ImageRecord, _ depth: Float, _ stencil: UInt32, _ ranges: [ImageSubresourceRange]) {
    i.region.touched = true
    let f = i.descriptor.format
    for range in ranges {
      for aspect in singleAspects(range.aspects) where aspect != .color {
        guard let p = plane(i, aspect) else { continue }
        for mip in Int(range.baseMip)..<Int(range.baseMip + range.mipCount) {
          let level = p.layout.levels[mip]
          for layer in Int(range.baseLayer)..<Int(range.baseLayer + range.layerCount) {
            for z in 0..<level.depth {
              for y in 0..<level.height {
                for x in 0..<level.width {
                  unsafe Self.storeDepth(f, aspect, aspect == .stencil ? Float(stencil & 0xFF) : depth,
                                  to: spot(i, p, mip: mip, layer: layer, x: x, y: y, z: z))
                }
              }
            }
          }
        }
      }
    }
  }
}
