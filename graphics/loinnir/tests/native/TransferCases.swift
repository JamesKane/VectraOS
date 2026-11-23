// SPDX-License-Identifier: BSD-3-Clause

// loinnir-test's cases for the core's transfers (gpucore(2)): copies, blits, clears, fills, updates and resolves, each judged
// exactly against a CPU reference written here (within a stated tolerance where the hardware filters or converts), with regions,
// odd row lengths, mip levels and layers, depth and stencil aspects, a compressed format, and transfers between draws in one
// submission. A feature or format the device doesn't report is skipped with the reason.

import GPUCore
import Sys

extension CoreCases {
  /// A texel's bytes for the cases' patterns: distinct for every place.
  func texelByte(_ x: Int, _ y: Int, _ layer: Int, _ c: Int) -> UInt8 { UInt8(truncatingIfNeeded: x * 17 + y * 5 + layer * 61 + c * 29 + 3) }

  /// The sRGB byte nearest a linear byte's value: the byte whose decoding (IEC 61966-2-1) is nearest, found by search, so the
  /// reference needs only the decoding's power of 2.4, which is a square and a fifth root's square.
  func srgbByte(_ linear: UInt8) -> Int {
    let v = Float(linear) / 255
    func decode(_ b: Int) -> Float {
      let c = Float(b) / 255
      if c <= 0.04045 { return c / 12.92 }
      let t = (c + 0.055) / 1.055
      // t^2.4 = t^2 * (t^2)^(1/5): the fifth root by Newton's method.
      let t2 = t * t
      var r: Float = 1
      for _ in 0..<30 { r -= (r * r * r * r * r - t2) / (5 * r * r * r * r) }
      return t2 * r
    }
    var best = 0
    var bestError: Float = 2
    for b in 0..<256 where abs(decode(b) - v) < bestError {
      best = b
      bestError = abs(decode(b) - v)
    }
    return best
  }

  /// A binary16's value (the cases' CPU reference of a half float).
  func halfValue(_ h: UInt16) -> Float {
    let e = Int((h >> 10) & 0x1F), m = Float(h & 0x3FF)
    var v: Float
    if e == 0 {
      v = m / 1024 / 16384
    } else {
      v = 1 + m / 1024
      var k = e - 15
      while k > 0 {
        v *= 2
        k -= 1
      }
      while k < 0 {
        v /= 2
        k += 1
      }
    }
    return h & 0x8000 != 0 ? -v : v
  }

  /// Draws, copies, a blit, a second pass and buffer transfers in one submission, each reading what the one before it wrote.
  func transfersInterleaved() throws(GPUError) {
    guard rgbaTarget, f.copyImage, f.blitImage, f.clearImage, f.fillBuffer, f.updateBuffer else {
      return skip("transfers: between draws", "no copies, blits, clears, fills or updates")
    }
    let w = 16, h = 16
    let pso = try meshPipeline()
    let red = try meshBuffer([Rect(x0: 0, y0: 0, x1: 8, y1: 6, color: [1, 0, 0, 1])], width: Float(w), height: Float(h))
    let green = try meshBuffer([Rect(x0: 12, y0: 0, x1: 16, y1: 16, color: [0, 1, 0, 1])], width: Float(w), height: Float(h))
    let a = try colorTarget(Int32(w), Int32(h))
    let b = try colorTarget(Int32(w), Int32(h))
    let c = try colorTarget(Int32(w), Int32(h))
    let source = try d.allocate(.device, bytes: 64)
    let moved = try d.allocate(.device, bytes: 96)
    let back = try d.allocate(.readback, bytes: 96)
    var list = GPUCommandList()
    list.render(RenderingInfo(colors: [Attachment(image: a, load: .clear(0, 0, 1, 1))])) { r in r.draw(pso, root: red.address, vertices: 6) }
    list.barrier(from: .fragment, to: .transfer)
    list.clear(b, color: .float(0, 0, 0, 1))
    list.barrier(from: .transfer, to: .transfer)
    // b's 8x8 corner is a's from (4, 4); c is that corner twice the size, upside down.
    list.copyImage(a, to: b, regions: [ImageCopyRegion(srcOffset: Offset3D(x: 4, y: 4), extent: Extent3D(width: 8, height: 8))])
    list.barrier(from: .transfer, to: .transfer)
    list.blitImage(b, to: c, regions: [ImageBlitRegion(srcMax: Offset3D(x: 8, y: 8, z: 1), dstMin: Offset3D(x: 0, y: 16, z: 0),
                                                       dstMax: Offset3D(x: 16, y: 0, z: 1))], filter: .nearest)
    list.barrier(from: .transfer, to: .fragment)
    list.render(RenderingInfo(colors: [Attachment(image: c, load: .load)])) { r in r.draw(pso, root: green.address, vertices: 6) }
    // Buffers: an update, a copy of it at an odd offset, a fill after it, and the lot copied out.
    var data: [UInt8] = []
    for i in 0..<40 { data.append(UInt8(i * 3 + 1)) }
    list.update(source, offset: 0, data: data)
    list.barrier(from: .transfer, to: .transfer)
    list.fill(moved, bytes: 96, value: 0x1122_3344)
    list.barrier(from: .transfer, to: .transfer)
    list.copy(source, fromOffset: 1, to: moved, toOffset: 7, bytes: 37)
    list.barrier(from: .transfer, to: .transfer)
    list.copy(moved, to: back, bytes: 96)
    let px = try readBack(list, c)
    let n = judge("transfers between draws", px, w, h) { x, y in
      if x >= 12 { return [0, 255, 0, 255] }
      // c(x, y) is b(x / 2, (15 - y) / 2), which is a(x / 2 + 4, (15 - y) / 2 + 4): red inside the rectangle drawn first.
      let ax = x / 2 + 4, ay = (15 - y) / 2 + 4
      return ax < 8 && ay < 6 ? [255, 0, 0, 255] : [0, 0, 255, 255]
    }
    let got = read(back, 96)
    for i in 0..<96 {
      let want: UInt8 = i >= 7 && i < 44 ? data[i - 7 + 1] : [0x44, 0x33, 0x22, 0x11][i % 4]
      if got[i] != want { fail("transfers between draws: byte \(i) of the buffer is \(got[i]), expected \(want)") }
    }
    ok("transfers: a pass, a copy, a flipped blit and a second pass that keeps it in one submission, \(n) pixels exact; an update, a fill and a copy at odd offsets, 96 bytes exact")
  }

  /// Buffer and image copies with row lengths and image heights that aren't the extent's, into a level and layers of an array, in
  /// formats of 1, 4 and 8 bytes a texel.
  func transferRows() throws(GPUError) {
    guard f.imageRegionCopies, f.mipmaps, f.arrayImages else { return skip("transfers: rows", "no region copies, mips or arrays") }
    var done = ""
    for (format, bytes) in [(PixelFormat.r8, 1), (.rgba8, 4), (.rgba16float, 8)] {
      guard d.limits.formats(format).sampled else { continue }
      // A 5x3 region at (1, 2) of level 1 (8x8) of layers 1 and 2 of a 16x16 array of 3 layers; the buffer's rows are 13 texels,
      // its slices 5 rows.
      let image = try self.image(format, 16, 16, mips: 2, layers: 3, usage: copyUsage())
      let rowLength = 13, imageHeight = 5
      var data = [UInt8](repeating: 0xEE, count: rowLength * imageHeight * 2 * bytes)
      for l in 0..<2 {
        for y in 0..<3 {
          for x in 0..<5 {
            for c in 0..<bytes { data[((l * imageHeight + y) * rowLength + x) * bytes + c] = texelByte(x, y, l, c) }
          }
        }
      }
      let upload = try d.allocate(.upload, bytes: data.count)
      store(upload, bytes: data)
      let readback = try d.allocate(.readback, bytes: 8 * 8 * 2 * bytes)
      let level = ImageSubresourceLayers(aspects: .color, mip: 1, baseLayer: 1, layerCount: 2)
      var list = GPUCommandList()
      list.clear(image, color: .float(0, 0, 0, 0))
      list.barrier(from: .transfer, to: .transfer)
      list.copy(upload, to: image, regions: [BufferImageRegion(bufferRowLength: UInt32(rowLength), bufferImageHeight: UInt32(imageHeight),
                                                               subresource: level, imageOffset: Offset3D(x: 1, y: 2),
                                                               imageExtent: Extent3D(width: 5, height: 3))])
      list.barrier(from: .transfer, to: .transfer)
      list.copy(image, to: readback, regions: [BufferImageRegion(subresource: level, imageExtent: Extent3D(width: 8, height: 8))])
      try run(list)
      let got = read(readback, 8 * 8 * 2 * bytes)
      for l in 0..<2 {
        for y in 0..<8 {
          for x in 0..<8 {
            let inside = x >= 1 && x < 6 && y >= 2 && y < 5
            for c in 0..<bytes {
              let want = inside ? texelByte(x - 1, y - 2, l, c) : 0
              let at = ((l * 8 + y) * 8 + x) * bytes + c
              if got[at] != want { fail("transfers: rows of \(bytes)-byte texels: layer \(l + 1) (\(x), \(y)) byte \(c) is \(got[at]), expected \(want)") }
            }
          }
        }
      }
      done += " \(bytes)B"
    }
    ok("transfers: 5x3 regions with rows of 13 texels and slices of 5 rows into level 1 of layers 1 and 2, read back whole, exact (texels of\(done))")
  }

  /// `copyImage` between levels, layers and slices of a volume, at offsets.
  func transferImages() throws(GPUError) {
    guard f.copyImage, f.mipmaps, f.arrayImages else { return skip("transfers: images", "no image copies, mips or arrays") }
    let usage = copyUsage()
    let a = try image(.rgba8, 16, 16, mips: 2, layers: 3, usage: usage)
    let b = try image(.rgba8, 8, 8, layers: 2, usage: usage)
    var data: [UInt8] = []
    for l in 0..<3 { for y in 0..<8 { for x in 0..<8 { for c in 0..<4 { data.append(texelByte(x, y, l, c)) } } } }
    let upload = try d.allocate(.upload, bytes: data.count)
    store(upload, bytes: data)
    let readback = try d.allocate(.readback, bytes: 8 * 8 * 2 * 4)
    var list = GPUCommandList()
    list.copy(upload, to: a, regions: [BufferImageRegion(subresource: ImageSubresourceLayers(aspects: .color, mip: 1, baseLayer: 0, layerCount: 3),
                                                         imageExtent: Extent3D(width: 8, height: 8))])
    list.clear(b, color: .float(0, 0, 0, 0))
    list.barrier(from: .transfer, to: .transfer)
    // Level 1 of layers 1 and 2 of a, from (2, 1), to layers 0 and 1 of b at (3, 4).
    list.copyImage(a, to: b, regions: [ImageCopyRegion(srcSubresource: ImageSubresourceLayers(aspects: .color, mip: 1, baseLayer: 1, layerCount: 2),
                                                       srcOffset: Offset3D(x: 2, y: 1),
                                                       dstSubresource: ImageSubresourceLayers(aspects: .color, mip: 0, baseLayer: 0, layerCount: 2),
                                                       dstOffset: Offset3D(x: 3, y: 4), extent: Extent3D(width: 5, height: 4))])
    list.barrier(from: .transfer, to: .transfer)
    list.copy(b, to: readback, regions: [BufferImageRegion(subresource: ImageSubresourceLayers(aspects: .color, mip: 0, baseLayer: 0, layerCount: 2),
                                                          imageExtent: Extent3D(width: 8, height: 8))])
    try run(list)
    let got = read(readback, 8 * 8 * 2 * 4)
    var n = 0
    for l in 0..<2 {
      for y in 0..<8 {
        for x in 0..<8 {
          let inside = x >= 3 && y >= 4
          for c in 0..<4 {
            let want = inside ? texelByte(x - 3 + 2, y - 4 + 1, l + 1, c) : 0
            let at = ((l * 8 + y) * 8 + x) * 4 + c
            if got[at] != want { fail("transfers: images: layer \(l) (\(x), \(y)) byte \(c) is \(got[at]), expected \(want)") }
          }
          n += 1
        }
      }
    }
    var volumes = ""
    if f.volumeImages {
      // Slices 1 and 2 of a volume, from (1, 1, 1), to (4, 0, 2) of another.
      let v = try image(.rgba8, 8, 8, depth: 4, dimension: .d3, usage: usage)
      let u = try image(.rgba8, 8, 8, depth: 4, dimension: .d3, usage: usage)
      var slices: [UInt8] = []
      for z in 0..<4 { for y in 0..<8 { for x in 0..<8 { for c in 0..<4 { slices.append(texelByte(x, y, z, c)) } } } }
      let up = try d.allocate(.upload, bytes: slices.count)
      store(up, bytes: slices)
      let out = try d.allocate(.readback, bytes: slices.count)
      var list = GPUCommandList()
      list.copy(up, to: v, regions: [BufferImageRegion(imageExtent: Extent3D(width: 8, height: 8, depth: 4))])
      list.clear(u, color: .float(0, 0, 0, 0))
      list.barrier(from: .transfer, to: .transfer)
      list.copyImage(v, to: u, regions: [ImageCopyRegion(srcOffset: Offset3D(x: 1, y: 1, z: 1), dstOffset: Offset3D(x: 4, y: 0, z: 2),
                                                         extent: Extent3D(width: 4, height: 5, depth: 2))])
      list.barrier(from: .transfer, to: .transfer)
      list.copy(u, to: out, regions: [BufferImageRegion(imageExtent: Extent3D(width: 8, height: 8, depth: 4))])
      try run(list)
      let got = read(out, slices.count)
      for z in 0..<4 {
        for y in 0..<8 {
          for x in 0..<8 {
            let inside = x >= 4 && y < 5 && z >= 2
            for c in 0..<4 {
              let want = inside ? texelByte(x - 4 + 1, y + 1, z - 2 + 1, c) : 0
              let at = ((z * 8 + y) * 8 + x) * 4 + c
              if got[at] != want { fail("transfers: volumes: (\(x), \(y), \(z)) byte \(c) is \(got[at]), expected \(want)") }
            }
            n += 1
          }
        }
      }
      volumes = " and a 4x5x2 block of a volume"
    }
    ok("transfers: a 5x4 region of level 1 of two layers onto level 0 of two others\(volumes), at offsets, \(n) texels exact")
  }

  /// A depth and stencil image: cleared by ranges, its aspects copied in and out of buffers, onto another image, and blitted.
  func transferDepthStencil() throws(GPUError) {
    guard f.depth, f.stencil, f.imageRegionCopies, f.copyImage, f.clearImage else {
      return skip("transfers: depth and stencil", "no depth, stencil, copies or clears")
    }
    var format: PixelFormat?
    for c in [PixelFormat.depth32fstencil8, .depth24stencil8] where d.limits.formats(c).sampled { format = c }
    guard let ds = format else { return skip("transfers: depth and stencil", "no depth and stencil format to copy") }
    let float = ds == .depth32fstencil8
    func depthWord(_ v: Float) -> UInt32 { float ? v.bitPattern : UInt32(v * 16_777_215 + 0.5) }
    let usage = copyUsage()
    let a = try image(ds, 8, 8, layers: 2, usage: usage)
    let b = try image(ds, 8, 8, usage: usage)
    // Depth for the 4x4 block at (2, 2) of layer 1: k / 64 for texel k.
    var depthIn: [UInt8] = []
    var stencilIn: [UInt8] = []
    for k in 0..<16 {
      let word = depthWord(Float(k) / 64)
      depthIn += [UInt8(word & 255), UInt8((word >> 8) & 255), UInt8((word >> 16) & 255), UInt8(word >> 24)]
      stencilIn.append(UInt8(k * 9 + 1))
    }
    let depthUp = try d.allocate(.upload, bytes: 64)
    store(depthUp, bytes: depthIn)
    let stencilUp = try d.allocate(.upload, bytes: 16)
    store(stencilUp, bytes: stencilIn)
    let depthOut = try d.allocate(.readback, bytes: 256)
    let stencilOut = try d.allocate(.readback, bytes: 64)
    let layer1 = ImageSubresourceLayers(aspects: .depth, mip: 0, baseLayer: 1, layerCount: 1)
    let stencil1 = ImageSubresourceLayers(aspects: .stencil, mip: 0, baseLayer: 1, layerCount: 1)
    var list = GPUCommandList()
    // Layer 0 to (0.75, 3), layer 1 to (0.25, 200); then only layer 1's stencil to 77.
    list.clear(a, depth: 0.75, stencil: 3, ranges: [ImageSubresourceRange(aspects: .depth | .stencil, layerCount: 2)])
    list.barrier(from: .transfer, to: .transfer)
    list.clear(a, depth: 0.25, stencil: 200, ranges: [ImageSubresourceRange(aspects: .depth | .stencil, baseLayer: 1, layerCount: 1)])
    list.barrier(from: .transfer, to: .transfer)
    list.clear(a, depth: 0, stencil: 77, ranges: [ImageSubresourceRange(aspects: .stencil, baseLayer: 1, layerCount: 1)])
    list.barrier(from: .transfer, to: .transfer)
    list.copy(depthUp, to: a, regions: [BufferImageRegion(subresource: layer1, imageOffset: Offset3D(x: 2, y: 2), imageExtent: Extent3D(width: 4, height: 4))])
    list.copy(stencilUp, to: a, regions: [BufferImageRegion(subresource: stencil1, imageOffset: Offset3D(x: 2, y: 2), imageExtent: Extent3D(width: 4, height: 4))])
    list.barrier(from: .transfer, to: .transfer)
    // Layer 1 of a, both aspects, onto b.
    list.copyImage(a, to: b, regions: [ImageCopyRegion(srcSubresource: ImageSubresourceLayers(aspects: .depth | .stencil, mip: 0, baseLayer: 1, layerCount: 1),
                                                       dstSubresource: ImageSubresourceLayers(aspects: .depth | .stencil), extent: Extent3D(width: 8, height: 8))])
    list.barrier(from: .transfer, to: .transfer)
    list.copy(b, to: depthOut, regions: [BufferImageRegion(subresource: ImageSubresourceLayers(aspects: .depth), imageExtent: Extent3D(width: 8, height: 8))])
    list.copy(b, to: stencilOut, regions: [BufferImageRegion(subresource: ImageSubresourceLayers(aspects: .stencil), imageExtent: Extent3D(width: 8, height: 8))])
    try run(list)
    let depths = read(depthOut, 256), stencils = read(stencilOut, 64)
    let mask: UInt32 = float ? 0xFFFF_FFFF : 0xFF_FFFF
    for y in 0..<8 {
      for x in 0..<8 {
        let inside = x >= 2 && x < 6 && y >= 2 && y < 6
        let k = (y - 2) * 4 + (x - 2)
        let wantDepth = depthWord(inside ? Float(k) / 64 : 0.25) & mask
        let wantStencil: UInt8 = inside ? UInt8(k * 9 + 1) : 77
        let o = (y * 8 + x) * 4
        let gotDepth = (UInt32(depths[o]) | UInt32(depths[o + 1]) << 8 | UInt32(depths[o + 2]) << 16 | UInt32(depths[o + 3]) << 24) & mask
        if gotDepth != wantDepth { fail("transfers: depth at (\(x), \(y)) is 0x\(String(gotDepth, radix: 16)), expected 0x\(String(wantDepth, radix: 16))") }
        if stencils[y * 8 + x] != wantStencil { fail("transfers: stencil at (\(x), \(y)) is \(stencils[y * 8 + x]), expected \(wantStencil)") }
      }
    }
    var blitted = ""
    if f.blitImage, d.limits.formats(ds).blitSource, d.limits.formats(ds).blitDestination {
      // b's 4x4 block at (2, 2) blitted to the whole of c (twice the size, flipped across), both aspects, nearest.
      let c = try image(ds, 8, 8, usage: usage)
      var list = GPUCommandList()
      list.blitImage(b, to: c, regions: [ImageBlitRegion(srcSubresource: ImageSubresourceLayers(aspects: .depth | .stencil), srcMin: Offset3D(x: 2, y: 2, z: 0),
                                                         srcMax: Offset3D(x: 6, y: 6, z: 1), dstSubresource: ImageSubresourceLayers(aspects: .depth | .stencil),
                                                         dstMin: Offset3D(x: 8, y: 0, z: 0), dstMax: Offset3D(x: 0, y: 8, z: 1))], filter: .nearest)
      list.barrier(from: .transfer, to: .transfer)
      list.copy(c, to: depthOut, regions: [BufferImageRegion(subresource: ImageSubresourceLayers(aspects: .depth), imageExtent: Extent3D(width: 8, height: 8))])
      list.copy(c, to: stencilOut, regions: [BufferImageRegion(subresource: ImageSubresourceLayers(aspects: .stencil), imageExtent: Extent3D(width: 8, height: 8))])
      try run(list)
      let depths = read(depthOut, 256), stencils = read(stencilOut, 64)
      for y in 0..<8 {
        for x in 0..<8 {
          let k = (y / 2) * 4 + (7 - x) / 2
          let o = (y * 8 + x) * 4
          let gotDepth = (UInt32(depths[o]) | UInt32(depths[o + 1]) << 8 | UInt32(depths[o + 2]) << 16 | UInt32(depths[o + 3]) << 24) & mask
          if gotDepth != depthWord(Float(k) / 64) & mask { fail("transfers: blitted depth at (\(x), \(y)) is 0x\(String(gotDepth, radix: 16))") }
          if stencils[y * 8 + x] != UInt8(k * 9 + 1) { fail("transfers: blitted stencil at (\(x), \(y)) is \(stencils[y * 8 + x])") }
        }
      }
      blitted = "; a 4x4 block blitted to 8x8 flipped across, both aspects, exact"
    }
    ok("transfers: \(float ? "depth32f" : "depth24")-stencil8 cleared by ranges and aspects, both aspects copied in at (2, 2) of layer 1, onto another image and out, 64 texels exact\(blitted)")
  }

  /// A compressed format's blocks copied between images at block offsets, into a second level.
  func transferCompressed() throws(GPUError) {
    var format: PixelFormat?
    var compressedName = ""
    if f.compressedASTC {
      format = .astc(.b4x4)
      compressedName = "astc 4x4"
    } else if f.compressedETC2 {
      format = .etc2rgba8
      compressedName = "etc2 rgba8"
    } else if f.compressedBC {
      format = .bc3
      compressedName = "bc3"
    }
    guard f.copyImage, f.imageRegionCopies, f.mipmaps, let cf = format else { return skip("transfers: compressed", "no compressed format with copies") }
    let usage = copyUsage()
    // 16x16 (4x4 blocks) into a 16x16 of 2 levels: blocks (1, 1) to (2, 2) onto (2, 0) of level 0, and block (0, 0) onto (1, 1)
    // of level 1 (8x8, 2x2 blocks).
    let a = try image(cf, 16, 16, usage: usage)
    let b = try image(cf, 16, 16, mips: 2, usage: usage)
    var blocks: [UInt8] = []
    for i in 0..<16 * 16 { blocks.append(UInt8(truncatingIfNeeded: i * 7 + 5)) }
    let upload = try d.allocate(.upload, bytes: blocks.count)
    store(upload, bytes: blocks)
    let zeros = try d.allocate(.upload, bytes: 256 + 64)
    store(zeros, bytes: [UInt8](repeating: 0, count: 320))
    let out0 = try d.allocate(.readback, bytes: 256)
    let out1 = try d.allocate(.readback, bytes: 64)
    var list = GPUCommandList()
    list.copy(upload, to: a, regions: [BufferImageRegion(imageExtent: Extent3D(width: 16, height: 16))])
    list.copy(zeros, to: b, regions: [BufferImageRegion(imageExtent: Extent3D(width: 16, height: 16))])
    list.copy(zeros, to: b, regions: [BufferImageRegion(bufferOffset: 256, subresource: ImageSubresourceLayers(aspects: .color, mip: 1),
                                                        imageExtent: Extent3D(width: 8, height: 8))])
    list.barrier(from: .transfer, to: .transfer)
    list.copyImage(a, to: b, regions: [
      ImageCopyRegion(srcOffset: Offset3D(x: 4, y: 4), dstOffset: Offset3D(x: 8, y: 0), extent: Extent3D(width: 8, height: 8)),
      ImageCopyRegion(dstSubresource: ImageSubresourceLayers(aspects: .color, mip: 1), dstOffset: Offset3D(x: 4, y: 4), extent: Extent3D(width: 4, height: 4)),
    ])
    list.barrier(from: .transfer, to: .transfer)
    list.copy(b, to: out0, regions: [BufferImageRegion(imageExtent: Extent3D(width: 16, height: 16))])
    list.copy(b, to: out1, regions: [BufferImageRegion(subresource: ImageSubresourceLayers(aspects: .color, mip: 1), imageExtent: Extent3D(width: 8, height: 8))])
    try run(list)
    let got0 = read(out0, 256), got1 = read(out1, 64)
    for by in 0..<4 {
      for bx in 0..<4 {
        for i in 0..<16 {
          let inside = bx >= 2 && by < 2
          let want: UInt8 = inside ? blocks[((by + 1) * 4 + bx - 2 + 1) * 16 + i] : 0
          if got0[(by * 4 + bx) * 16 + i] != want { fail("transfers: compressed level 0: block (\(bx), \(by)) byte \(i) differs") }
        }
      }
    }
    for by in 0..<2 {
      for bx in 0..<2 {
        for i in 0..<16 {
          let want: UInt8 = bx == 1 && by == 1 ? blocks[i] : 0
          if got1[(by * 2 + bx) * 16 + i] != want { fail("transfers: compressed level 1: block (\(bx), \(by)) byte \(i) differs") }
        }
      }
    }
    ok("transfers: \(compressedName) blocks copied between images at block offsets and into level 1, 20 blocks exact")
  }

  /// Blits that filter and convert: linear and scaled into a half-float image, flipped across; integers into wider integers,
  /// flipped down; into sRGB.
  func transferBlits() throws(GPUError) {
    guard f.blitImage else { return skip("transfers: blits", "no image blits") }
    let caps = d.limits
    let usage = copyUsage()
    let upload = try d.allocate(.upload, bytes: 256)
    store(upload, bytes: patternData())
    var done: [String] = []
    if caps.formats(.rgba8).blitSource, caps.formats(.rgba16float).blitDestination, caps.formats(.rgba8).filterable {
      // 8x8 to a 12x10 rectangle at (2, 3) of a 16x16, its x corners reversed.
      let a = try image(.rgba8, 8, 8, usage: usage)
      let h = try image(.rgba16float, 16, 16, usage: usage)
      let out = try d.allocate(.readback, bytes: 16 * 16 * 8)
      var list = GPUCommandList()
      list.copy(upload, to: a)
      list.clear(h, color: .float(0, 0, 0, 0))
      list.barrier(from: .transfer, to: .transfer)
      list.blitImage(a, to: h, regions: [ImageBlitRegion(srcMax: Offset3D(x: 8, y: 8, z: 1), dstMin: Offset3D(x: 14, y: 3, z: 0),
                                                         dstMax: Offset3D(x: 2, y: 13, z: 1))], filter: .linear)
      list.barrier(from: .transfer, to: .transfer)
      list.copy(h, to: out, regions: [BufferImageRegion(imageExtent: Extent3D(width: 16, height: 16))])
      try run(list)
      let got = read(out, 16 * 16 * 8)
      func value(_ x: Int, _ y: Int, _ c: Int) -> Float {
        let o = (y * 16 + x) * 8 + c * 2
        return halfValue(UInt16(got[o]) | UInt16(got[o + 1]) << 8)
      }
      var n = 0
      for y in 0..<16 {
        for x in 0..<16 {
          let inside = x >= 2 && x < 14 && y >= 3 && y < 13
          for c in 0..<4 {
            var want: Float = 0
            if inside {
              // The centre's place in the source, the x axis reversed, and the bilinear of the pattern there.
              let u = 1 - (Float(x - 2) + 0.5) / 12, v = (Float(y - 3) + 0.5) / 10
              let sx = u * 8 - 0.5, sy = v * 8 - 0.5
              let x0 = Int(sx + 1) - 1, y0 = Int(sy + 1) - 1
              let fx = sx - Float(x0), fy = sy - Float(y0)
              func t(_ tx: Int, _ ty: Int) -> Float { Float(pattern(min(max(tx, 0), 7), min(max(ty, 0), 7))[c]) / 255 }
              let top = t(x0, y0) * (1 - fx) + t(x0 + 1, y0) * fx
              let bottom = t(x0, y0 + 1) * (1 - fx) + t(x0 + 1, y0 + 1) * fx
              want = top * (1 - fy) + bottom * fy
            }
            let g = value(x, y, c)
            if abs(g - want) > 0.01 { fail("transfers: linear blit to rgba16float: (\(x), \(y)) channel \(c) is \(g), expected \(want) within 0.01") }
          }
          if inside { n += 1 }
        }
      }
      done.append("linear 8x8 to 12x10 flipped across into rgba16float (\(n) texels within 0.01, the rest untouched)")
    }
    if caps.formats(.rgba8uint).blitSource, caps.formats(.rgba16uint).blitDestination {
      let a = try image(.rgba8uint, 8, 8, usage: usage)
      let wide = try image(.rgba16uint, 8, 8, usage: usage)
      let out = try d.allocate(.readback, bytes: 8 * 8 * 8)
      var list = GPUCommandList()
      list.copy(upload, to: a)
      list.barrier(from: .transfer, to: .transfer)
      list.blitImage(a, to: wide, regions: [ImageBlitRegion(srcMax: Offset3D(x: 8, y: 8, z: 1), dstMin: Offset3D(x: 0, y: 8, z: 0),
                                                            dstMax: Offset3D(x: 8, y: 0, z: 1))], filter: .nearest)
      list.barrier(from: .transfer, to: .transfer)
      list.copy(wide, to: out, regions: [BufferImageRegion(imageExtent: Extent3D(width: 8, height: 8))])
      try run(list)
      let got = read(out, 8 * 8 * 8)
      for y in 0..<8 {
        for x in 0..<8 {
          let p = pattern(x, 7 - y)
          for c in 0..<4 {
            let o = (y * 8 + x) * 8 + c * 2
            if got[o] != p[c] || got[o + 1] != 0 { fail("transfers: rgba8uint into rgba16uint: (\(x), \(y)) channel \(c) is \(got[o]) \(got[o + 1])") }
          }
        }
      }
      done.append("rgba8uint into rgba16uint flipped down, exact")
    }
    if caps.formats(.rgba8).blitSource, caps.formats(.rgba8srgb).blitDestination {
      let a = try image(.rgba8, 8, 8, usage: usage)
      let s = try image(.rgba8srgb, 8, 8, usage: usage)
      let out = try d.allocate(.readback, bytes: 256)
      var list = GPUCommandList()
      list.copy(upload, to: a)
      list.barrier(from: .transfer, to: .transfer)
      list.blitImage(a, to: s, regions: [ImageBlitRegion(srcMax: Offset3D(x: 8, y: 8, z: 1), dstMax: Offset3D(x: 8, y: 8, z: 1))], filter: .nearest)
      list.barrier(from: .transfer, to: .transfer)
      list.copy(s, to: out, regions: [BufferImageRegion(imageExtent: Extent3D(width: 8, height: 8))])
      try run(list)
      let got = read(out, 256)
      for y in 0..<8 {
        for x in 0..<8 {
          let p = pattern(x, y)
          for c in 0..<4 {
            let want = c < 3 ? srgbByte(p[c]) : Int(p[c])
            let g = Int(got[(y * 8 + x) * 4 + c])
            if abs(g - want) > 1 { fail("transfers: rgba8 into rgba8srgb: (\(x), \(y)) channel \(c) is \(g), expected \(want) within 1") }
          }
        }
      }
      done.append("rgba8 into rgba8srgb, each within 1 of the encoding")
    }
    guard !done.isEmpty else { return skip("transfers: blits", "no format pairs to blit") }
    var line = "transfers: blits:"
    for (i, s) in done.enumerated() { line += (i == 0 ? " " : "; ") + s }
    ok(line)
  }

  /// `clearColorImage` of a range of levels and layers, the others kept.
  func transferClearRanges() throws(GPUError) {
    guard f.clearImage, f.mipmaps, f.arrayImages, f.imageRegionCopies else { return skip("transfers: clears of ranges", "no clears, mips or arrays") }
    let image = try self.image(.rgba8, 8, 8, mips: 3, layers: 4, usage: copyUsage())
    let out = try d.allocate(.readback, bytes: 4 * (64 + 16 + 4) * 4)
    var list = GPUCommandList()
    list.clear(image, color: .float(0, 0, 1, 1))
    list.barrier(from: .transfer, to: .transfer)
    list.clear(image, color: .float(1, 0, 0, 1), ranges: [ImageSubresourceRange(aspects: .color, baseMip: 1, mipCount: 2, baseLayer: 1, layerCount: 2)])
    list.barrier(from: .transfer, to: .transfer)
    var offset = 0
    for mip in 0..<3 {
      let size = 8 >> mip
      list.copy(image, to: out, regions: [BufferImageRegion(bufferOffset: offset, subresource: ImageSubresourceLayers(aspects: .color, mip: UInt32(mip), baseLayer: 0, layerCount: 4),
                                                            imageExtent: Extent3D(width: UInt32(size), height: UInt32(size)))])
      offset += size * size * 4 * 4
    }
    try run(list)
    let got = read(out, offset)
    var at = 0
    var n = 0
    for mip in 0..<3 {
      let size = 8 >> mip
      for layer in 0..<4 {
        let cleared = mip >= 1 && layer >= 1 && layer < 3
        let want: [UInt8] = cleared ? [255, 0, 0, 255] : [0, 0, 255, 255]
        for _ in 0..<(size * size) {
          if Array(got[at..<(at + 4)]) != want { fail("transfers: clear of a range: level \(mip) layer \(layer) reads \(hex(Array(got[at..<(at + 4)])))") }
          at += 4
          n += 1
        }
      }
    }
    ok("transfers: levels 1 and 2 of layers 1 and 2 of a 3-level, 4-layer image cleared, the rest kept, \(n) texels exact")
  }

  /// `resolveImage` of a region at offsets.
  func transferResolveRegion() throws(GPUError) {
    guard f.multisample, f.resolveImage, rgbaTarget, d.limits.formats(.rgba8).renderSamples.contains(4) else {
      return skip("transfers: resolve of a region", "no 4-sample images or image resolves")
    }
    let w = 16, h = 16
    let mesh = try meshBuffer([Rect(x0: 0, y0: 0, x1: 8.5, y1: 16, color: [1, 0, 0, 1])], width: Float(w), height: Float(h))
    let pso = try meshPipeline(multisample: MultisampleState(samples: 4))
    let ms = try colorTarget(Int32(w), Int32(h), samples: 4)
    let resolved = try colorTarget(8, 8)
    var list = GPUCommandList()
    list.render(RenderingInfo(colors: [Attachment(image: ms, load: .clear(0, 0, 1, 1), store: .store)])) { r in r.draw(pso, root: mesh.address, vertices: 6) }
    list.barrier(from: .fragment, to: .transfer)
    list.clear(resolved, color: .float(0, 1, 0, 1))
    list.barrier(from: .transfer, to: .transfer)
    // The 6x4 region from (5, 3), whose fourth column is the edge, to (1, 2).
    list.resolveImage(ms, to: resolved, regions: [ImageCopyRegion(srcOffset: Offset3D(x: 5, y: 3), dstOffset: Offset3D(x: 1, y: 2),
                                                                  extent: Extent3D(width: 6, height: 4))])
    let px = try readBack(list, resolved)
    let n = judge("resolve of a region", px, 8, 8, tolerance: 2) { x, y in
      guard x >= 1 && x < 7 && y >= 2 && y < 6 else { return [0, 255, 0, 255] }
      let sx = x - 1 + 5
      if sx < 8 { return [255, 0, 0, 255] }
      if sx > 8 { return [0, 0, 255, 255] }
      return [128, 0, 127, 255]
    }
    ok("transfers: a 6x4 region of a 4-sample image resolved at offsets, \(n) pixels, the edge the mean within 2, the rest untouched")
  }

  func transferCases() {
    var t = Clock.monotonic()
    do throws(GPUError) { try transfersInterleaved() } catch { caught("transfers: between draws", error) }
    do throws(GPUError) { try transferRows() } catch { caught("transfers: rows", error) }
    do throws(GPUError) { try transferImages() } catch { caught("transfers: images", error) }
    lap("transfers: between draws, rows and images", t)
    t = Clock.monotonic()
    do throws(GPUError) { try transferDepthStencil() } catch { caught("transfers: depth and stencil", error) }
    do throws(GPUError) { try transferCompressed() } catch { caught("transfers: compressed", error) }
    do throws(GPUError) { try transferBlits() } catch { caught("transfers: blits", error) }
    do throws(GPUError) { try transferClearRanges() } catch { caught("transfers: clears of ranges", error) }
    do throws(GPUError) { try transferResolveRegion() } catch { caught("transfers: resolve of a region", error) }
    lap("transfers: depth and stencil, compressed, blits, clears and resolves", t)
  }
}
