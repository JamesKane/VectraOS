// SPDX-License-Identifier: BSD-3-Clause

// loinnir-test's cases for the core's resources (D174's amendment, step 3; gpucore(2)): the formats a texture unit reads, views
// of an image's mip levels, layers and formats, depth and stencil images, the sampler's whole state, and the copies and clears
// of every format. Each draws or copies on the device Loinnir opened and judges what it reads back against a CPU reference
// written here, apart from the backend's own codec: exactly where the work is exact, within a stated tolerance where the
// hardware rounds (sRGB, a linear filter). A feature the device doesn't report is skipped with the reason.

import GPUCore
import GPUCoreMali
import Sys

extension CoreCases {
  // MARK: Bytes

  /// `drawTiles`, with a target of its own for each tile (the Mali backend draws only into the whole of its target): the tiles' pixels
  /// as one row of `count * 8` by 8.
  func drawTilesApart(_ pso: GPUPipeline, _ table: GPUMemory, count: Int, before: GPUCommandList) throws(GPUError) -> [UInt8] {
    var list = before
    var targets: [GPUImage] = []
    for i in 0..<count {
      let t = try colorTarget(8, 8)
      targets.append(t)
      list.render(RenderingInfo(colors: [Attachment(image: t, load: .clear(0, 0, 0, 1))])) { r in
        r.draw(pso, root: table.address + UInt64(32 * i), vertices: 6)
      }
    }
    let readback = try d.allocate(.readback, bytes: count * 256)
    for i in 0..<count { list.copy(targets[i], to: readback, offset: i * 256) }
    try run(list)
    let tiles = read(readback, count * 256)
    var out = [UInt8](repeating: 0, count: count * 256)
    for i in 0..<count {
      for y in 0..<8 {
        for x in 0..<8 {
          for c in 0..<4 { out[(y * count * 8 + i * 8 + x) * 4 + c] = tiles[i * 256 + (y * 8 + x) * 4 + c] }
        }
      }
    }
    return out
  }

  func word(_ m: GPUMemory, _ i: Int) -> UInt32 { unsafe m.pointer!.load(fromByteOffset: i * 4, as: UInt32.self) }
  func bad(_ what: String) {
    if probing {
      print("loinnir-test: probe failed: core: \(what)")
      return
    }
    softFailures += 1
    // The first three of each kind of failure (the first 24 bytes of its words), so a failing case doesn't bury the others.
    let key = Array(what.utf8.prefix(24))
    var n = 0
    for i in 0..<softKeys.count where softKeys[i] == key {
      softCounts[i] += 1
      n = softCounts[i]
    }
    if n == 0 {
      softKeys.append(key)
      softCounts.append(1)
      n = 1
    }
    if n <= 3 { print("loinnir-test: FAILED: core: \(what)") }
  }

  func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 255), UInt8(v >> 8)] }
  func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 255), UInt8((v >> 8) & 255), UInt8((v >> 16) & 255), UInt8(v >> 24)] }
  func f32(_ f: Float) -> [UInt8] { le32(f.bitPattern) }

  /// An 8-pixel-wide tile of the row `px`, checked to be of one colour within `tolerance`.
  func judgeTiles(_ name: String, _ px: [UInt8], _ wants: [[UInt8]], tolerance: Int) {
    for (i, want) in wants.enumerated() {
      for y in 0..<8 {
        for x in 0..<8 {
          let p = pixel(px, wants.count * 8, i * 8 + x, y)
          if !near(p, want, tolerance) { bad("\(name): tile \(i) (\(x), \(y)) reads \(hex(p)), expected \(hex(want)) within \(tolerance)") }
        }
      }
    }
  }

  /// A 4 by 4 image of one texel (`texel`'s bytes in every position), sampled in a tile by the pipeline of its class.
  struct FormatCase {
    var name: String
    var format: PixelFormat
    var texel: [UInt8]
    var want: [UInt8]
    var tolerance: Int
  }

  func formatTiles(_ title: String, _ cases: [FormatCase], fragment: [UInt8]) throws(GPUError) {
    var usable: [FormatCase] = []
    for c in cases {
      let caps = d.limits.formats(c.format)
      if caps.sampled { usable.append(c) } else { skip("format \(c.name)", "the device doesn't offer it sampled") }
    }
    guard !usable.isEmpty else { return }
    var list = GPUCommandList()
    let table = try d.allocate(.upload, bytes: 32 * usable.count)
    for (i, c) in usable.enumerated() {
      let texture = try image(c.format, 4, 4, usage: .sampled | .copyDestination)
      var data: [UInt8] = []
      for _ in 0..<16 { data.append(contentsOf: c.texel) }
      let upload = try d.allocate(.upload, bytes: data.count)
      store(upload, bytes: data)
      list.copy(upload, to: texture)
      let slot = textureBase + 20 + UInt32(i)
      try d.writeTexture(slot, ImageView(texture))
      params(table, i, texture: slot, sampler: 1)
    }
    try d.writeSampler(1, SamplerDescriptor(filter: .nearest, addressMode: .clampToEdge, mipmapMode: .nearest))
    let pso = try quadPipeline(fragment)
    let px = try drawTilesApart(pso, table, count: usable.count, before: list)
    judgeTiles(title, px, usable.map { $0.want }, tolerance: usable.map { $0.tolerance }.max() ?? 0)
    var names = ""
    for c in usable { names += " " + c.name }
    ok("\(title): sampled, exact or within the stated rounding:\(names)")
  }

  /// Each case is one block of a compressed image (4 by 4 texels of one colour), copied in as blocks and sampled in a tile.
  func compressedTiles(_ title: String, _ cases: [FormatCase]) throws(GPUError) {
    var usable: [FormatCase] = []
    for c in cases {
      if d.limits.formats(c.format).sampled { usable.append(c) } else { skip("format \(c.name)", "the device doesn't offer it sampled") }
    }
    guard !usable.isEmpty else { return }
    var list = GPUCommandList()
    let table = try d.allocate(.upload, bytes: 32 * usable.count)
    for (i, c) in usable.enumerated() {
      let texture = try image(c.format, 4, 4, usage: .sampled | .copyDestination)
      let upload = try d.allocate(.upload, bytes: c.texel.count)
      store(upload, bytes: c.texel)
      list.copy(upload, to: texture, regions: [BufferImageRegion(imageExtent: Extent3D(width: 4, height: 4))])
      let slot = textureBase + 60 + UInt32(i)
      try d.writeTexture(slot, ImageView(texture))
      params(table, i, texture: slot, sampler: 1)
    }
    try d.writeSampler(1, SamplerDescriptor(filter: .nearest, addressMode: .clampToEdge, mipmapMode: .nearest))
    let pso = try quadPipeline(LoinnirShaders.sampleFrag)
    let px = try drawTilesApart(pso, table, count: usable.count, before: list)
    judgeTiles(title, px, usable.map { $0.want }, tolerance: usable.map { $0.tolerance }.max() ?? 0)
    var names = ""
    for c in usable { names += " " + c.name }
    ok("\(title): a block copied in and sampled, decoded to the colour it holds within 1:\(names)")
  }

  func formats() throws(GPUError) {
    guard f.sampledImages, rgbaTarget else { return skip("formats", "no sampling") }
    // The float class: unorm, snorm, sRGB, float and the packed formats, read as floats and written as rgba8.
    try formatTiles("formats (float class)", [
      FormatCase(name: "r8snorm", format: .r8snorm, texel: [64], want: [128, 0, 0, 255], tolerance: 1),
      FormatCase(name: "rg8", format: .rg8, texel: [51, 204], want: [51, 204, 0, 255], tolerance: 0),
      FormatCase(name: "rgba8snorm", format: .rgba8snorm, texel: [64, 192, 127, 0], want: [128, 0, 255, 0], tolerance: 1),
      FormatCase(name: "rgba8srgb", format: .rgba8srgb, texel: [128, 128, 128, 128], want: [55, 55, 55, 128], tolerance: 2),
      FormatCase(name: "r16float", format: .r16float, texel: le16(0x3800), want: [128, 0, 0, 255], tolerance: 1),
      FormatCase(name: "rg16float", format: .rg16float, texel: le16(0x3400) + le16(0x3A00), want: [64, 191, 0, 255], tolerance: 1),
      FormatCase(name: "rgba16float", format: .rgba16float, texel: le16(0x3400) + le16(0x3800) + le16(0x3A00) + le16(0x3C00),
                 want: [64, 128, 191, 255], tolerance: 1),
      FormatCase(name: "r32float", format: .r32float, texel: f32(0.5), want: [128, 0, 0, 255], tolerance: 1),
      FormatCase(name: "rg32float", format: .rg32float, texel: f32(0.25) + f32(0.75), want: [64, 191, 0, 255], tolerance: 1),
      FormatCase(name: "rgba32float", format: .rgba32float, texel: f32(0.25) + f32(0.5) + f32(0.75) + f32(1),
                 want: [64, 128, 191, 255], tolerance: 1),
      FormatCase(name: "rgb10a2unorm", format: .rgb10a2unorm, texel: le32(512 | 256 << 10 | 768 << 20 | 3 << 30),
                 want: [128, 64, 191, 255], tolerance: 1),
      FormatCase(name: "rg11b10float", format: .rg11b10float, texel: le32(0x380 | 0x380 << 11 | 0x1C0 << 22),
                 want: [128, 128, 128, 255], tolerance: 1),
      FormatCase(name: "rgb9e5", format: .rgb9e5, texel: le32(128 | 64 << 9 | 256 << 18 | 16 << 27), want: [128, 64, 255, 255],
                 tolerance: 1),
    ], fragment: LoinnirShaders.sampleFrag)
    // The unsigned integers: each channel is written as value / 255.
    func integers(_ name: String, _ format: PixelFormat, bits: Int, _ values: [UInt32], signed: Bool) -> FormatCase {
      var texel: [UInt8] = []
      for v in values {
        switch bits {
        case 8: texel.append(UInt8(truncatingIfNeeded: v))
        case 16: texel.append(contentsOf: le16(UInt16(truncatingIfNeeded: v)))
        default: texel.append(contentsOf: le32(v))
        }
      }
      var want: [UInt8] = []
      for c in 0..<4 {
        let raw: Int = c < values.count ? Int(signed ? Int32(bitPattern: values[c]) : Int32(truncatingIfNeeded: values[c])) : (c == 3 ? 1 : 0)
        want.append(UInt8(signed ? raw + 128 : raw))
      }
      return FormatCase(name: name, format: format, texel: texel, want: want, tolerance: 0)
    }
    try formatTiles("formats (unsigned integers)", [
      integers("r8uint", .r8uint, bits: 8, [200], signed: false),
      integers("rg8uint", .rg8uint, bits: 8, [10, 20], signed: false),
      integers("rgba8uint", .rgba8uint, bits: 8, [1, 2, 3, 4], signed: false),
      integers("r16uint", .r16uint, bits: 16, [250], signed: false),
      integers("rg16uint", .rg16uint, bits: 16, [100, 200], signed: false),
      integers("rgba16uint", .rgba16uint, bits: 16, [1, 2, 3, 4], signed: false),
      integers("r32uint", .r32uint, bits: 32, [77], signed: false),
      integers("rg32uint", .rg32uint, bits: 32, [77, 78], signed: false),
      integers("rgba32uint", .rgba32uint, bits: 32, [1, 2, 3, 4], signed: false),
    ], fragment: LoinnirShaders.sampleuintFrag)
    func negative(_ v: Int32) -> UInt32 { UInt32(bitPattern: v) }
    try formatTiles("formats (signed integers)", [
      integers("r8sint", .r8sint, bits: 8, [negative(-5)], signed: true),
      integers("rg8sint", .rg8sint, bits: 8, [negative(-5), 7], signed: true),
      integers("rgba8sint", .rgba8sint, bits: 8, [negative(-5), 7, negative(-100), 100], signed: true),
      integers("r16sint", .r16sint, bits: 16, [negative(-5)], signed: true),
      integers("rg16sint", .rg16sint, bits: 16, [negative(-5), 7], signed: true),
      integers("rgba16sint", .rgba16sint, bits: 16, [negative(-5), 7, negative(-100), 100], signed: true),
      integers("r32sint", .r32sint, bits: 32, [negative(-5)], signed: true),
      integers("rg32sint", .rg32sint, bits: 32, [negative(-5), 7], signed: true),
      integers("rgba32sint", .rgba32sint, bits: 32, [negative(-5), 7, negative(-100), 100], signed: true),
    ], fragment: LoinnirShaders.samplesintFrag)
  }

  // MARK: Views

  func views() throws(GPUError) {
    guard f.imageViews, f.mipmaps, f.arrayImages, f.sampledImages, rgbaTarget, d.limits.formats(.rgba8).sampled else {
      return skip("views", "no views")
    }
    let sampler: UInt32 = 1
    try d.writeSampler(sampler, SamplerDescriptor(filter: .nearest, addressMode: .clampToEdge, mipmapMode: .nearest))
    let table = try d.allocate(.upload, bytes: 32 * 8)
    var list = GPUCommandList()
    var wants: [[UInt8]] = []
    var n = 0
    func add(_ view: ImageView, lod: Float, want: [UInt8]) throws(GPUError) {
      let slot = textureBase + 40 + UInt32(n)
      try d.writeTexture(slot, view)
      params(table, n, texture: slot, sampler: sampler, lod: lod)
      wants.append(want)
      n += 1
    }
    let levels: [[Float]] = [[1, 0, 0, 1], [0, 1, 0, 1], [0, 0, 1, 1], [1, 1, 1, 1]]
    let mips = try image(.rgba8, 8, 8, mips: 4, usage: .sampled | .copyDestination)
    for m in 0..<4 {
      let c = levels[m]
      list.clear(mips, color: .float(c[0], c[1], c[2], c[3]), ranges: [ImageSubresourceRange(aspects: .color, baseMip: UInt32(m), mipCount: 1)])
    }
    try add(ImageView(mips, baseMip: 2, mipCount: 1), lod: 0, want: bytes(levels[2]))
    try add(ImageView(mips, baseMip: 1, mipCount: 2), lod: 1, want: bytes(levels[2]))
    try add(ImageView(mips, baseMip: 3, mipCount: 1), lod: 0, want: bytes(levels[3]))
    let layered = try image(.rgba8, 4, 4, layers: 3, usage: .sampled | .copyDestination)
    let layerColors: [[Float]] = [[0.2, 0.4, 0.6, 1], [0.6, 0.4, 0.2, 1], [0, 1, 1, 1]]
    for l in 0..<3 {
      let c = layerColors[l]
      list.clear(layered, color: .float(c[0], c[1], c[2], c[3]), ranges: [ImageSubresourceRange(aspects: .color, baseLayer: UInt32(l), layerCount: 1)])
    }
    try add(ImageView(layered, dimension: .d2, baseLayer: 2, layerCount: 1), lod: 0, want: bytes(layerColors[2]))
    try add(ImageView(layered, dimension: .d2, baseLayer: 1, layerCount: 1), lod: 0, want: bytes(layerColors[1]))
    if d.limits.formats(.rgba8srgb).sampled {
      let plain = try image(.rgba8, 4, 4, usage: .sampled | .copyDestination)
      list.clear(plain, color: .float(128.0 / 255, 128.0 / 255, 128.0 / 255, 128.0 / 255))
      // The same bytes read as sRGB: decoded to light (0.2158 of 255 is 55); alpha never is.
      try add(ImageView(plain, format: .rgba8srgb), lod: 0, want: [55, 55, 55, 128])
    }
    if f.imageSwizzle {
      let texture = try image(.rgba8, 4, 4, usage: .sampled | .copyDestination)
      list.clear(texture, color: .float(30.0 / 255, 60.0 / 255, 90.0 / 255, 120.0 / 255))
      try add(ImageView(texture, swizzle: ComponentMapping(r: .zero, g: .one, b: .r, a: .one)), lod: 0, want: [0, 255, 30, 255])
      try add(ImageView(texture, swizzle: ComponentMapping(r: .a, g: .b, b: .g, a: .r)), lod: 0, want: [120, 90, 60, 30])
    }
    let pso = try quadPipeline(LoinnirShaders.lodFrag)
    let px = try drawTilesApart(pso, table, count: n, before: list)
    judgeTiles("views", px, wants, tolerance: 1)
    ok("views: a mip level, a mip range, a layer, a format (sRGB) and component swizzles, \(n) views, exact within 1")
  }

  // MARK: Samplers

  /// The pattern texel at (x, y) of a 4 by 4 image, as a texture the sampler cases read.
  func patternTexture(_ slot: UInt32, size: Int = 4, mips: UInt32 = 1) throws(GPUError) -> (GPUImage, GPUCommandList) {
    var data: [UInt8] = []
    for y in 0..<size { for x in 0..<size { data.append(contentsOf: pattern(x * 8 / size, y * 8 / size)) } }
    let upload = try d.allocate(.upload, bytes: data.count)
    store(upload, bytes: data)
    let texture = try image(.rgba8, Int32(size), Int32(size), mips: mips, usage: .sampled | .copyDestination)
    var list = GPUCommandList()
    list.copy(upload, to: texture)
    try d.writeTexture(slot, ImageView(texture))
    return (texture, list)
  }

  func samplers() throws(GPUError) {
    guard f.sampledImages, rgbaTarget, d.limits.formats(.rgba8).sampled else { return skip("samplers", "no sampling") }
    let slot = textureBase + 70
    let (_, setup) = try patternTexture(slot)
    let border: CustomBorderColor = .float(0.25, 0.5, 0.75, 1)
    let borderBytes: [UInt8] = [64, 128, 191, 255]
    // Addressing, an axis at a time: eight columns over three times the image's width from one before it.
    func texel(_ t: Int, _ mode: SamplerAddressMode) -> Int? {
      switch mode {
      case .clampToEdge: return min(max(t, 0), 3)
      case .repeat: return ((t % 4) + 4) % 4
      case .mirroredRepeat:
        let m = ((t % 8) + 8) % 8
        return m < 4 ? m : 7 - m
      case .mirrorClampToEdge: return t < 0 ? min(-t - 1, 3) : min(t, 3)
      case .clampToBorder: return t < 0 || t > 3 ? nil : t
      }
    }
    var modes: [SamplerAddressMode] = [.clampToEdge, .repeat, .mirroredRepeat]
    if f.samplerMirrorClampToEdge { modes.append(.mirrorClampToEdge) }
    if f.samplerBorder && f.customBorderColor { modes.append(.clampToBorder) }
    var checked = 0
    for mode in modes {
      for horizontal in [true, false] {
        let other: SamplerAddressMode = .clampToEdge
        if !f.samplerAxisAddressModes && mode != other { continue }
        var s = SamplerDescriptor(filter: .nearest, addressMode: other, mipmapMode: .nearest)
        if horizontal { s.addressModeU = mode } else { s.addressModeV = mode }
        if mode == .clampToBorder { s.customBorderColor = border }
        try d.writeSampler(2, s)
        let table = try d.allocate(.upload, bytes: 32)
        // u = x * 3 / 8 - 1 across the tile on the axis under test, the other axis as the image.
        params(table, 0, texture: slot, sampler: 2, direction: horizontal ? [3, 1, -1, 0] : [1, 3, 0, -1])
        let pso = try quadPipeline(LoinnirShaders.sampleFrag)
        let px = try drawTilesApart(pso, table, count: 1, before: setup)
        for y in 0..<8 {
          for x in 0..<8 {
            // The pixel centre's coordinate in texels of the axis under test, floored.
            let along = horizontal ? x : y
            let t = Int((Float(along) * 1.5 - 3.25).rounded(.down))
            let u = horizontal ? t : x / 2
            let v = horizontal ? y / 2 : t
            // The other axis is the image's own, magnified two to one.
            let tx = horizontal ? texel(u, mode) : texel(u, .clampToEdge)
            let ty = horizontal ? texel(v, .clampToEdge) : texel(v, mode)
            let want: [UInt8] = tx != nil && ty != nil ? pattern(tx! * 2, ty! * 2) : borderBytes
            let got = pixel(px, 8, x, y)
            if !near(got, want, mode == .clampToBorder ? 1 : 0) {
              bad("sampler addressing \(horizontal ? "u" : "v") mode \(mode == .repeat ? "repeat" : mode == .mirroredRepeat ? "mirrored" : mode == .clampToEdge ? "clamp" : mode == .clampToBorder ? "border" : "mirror-clamp"): (\(x), \(y)) reads \(hex(got)), expected \(hex(want))")
            }
            checked += 1
          }
        }
      }
    }
    ok("samplers: \(modes.count) address modes on each axis (repeat, mirrored, clamp, mirror-clamp, border), \(checked) pixels exact")

    // Separate filters: a checker of 16 by 16 shown at 8 by 8 minifies two to one and a 4 by 4 pattern at 8 by 8 magnifies. The level
    // of detail is the quad's (derivatives), so whether a minifying quad takes the minification filter on a one-level texture is the
    // hardware's: the descriptor's maximum level of detail (the last level, or one more) and the sampler's mipmap mode (nearest, or
    // none: the base level always) are tried in each combination, and the case needs one that is right.
    probing = true
    defer { probing = false }
    if f.samplerMinMagFilters {
      var checker: [UInt8] = []
      for y in 0..<16 { for x in 0..<16 { let v: UInt8 = (x + y) % 2 == 0 ? 0 : 255; checker.append(contentsOf: [v, v, v, 255]) } }
      let upload = try d.allocate(.upload, bytes: checker.count)
      store(upload, bytes: checker)
      let big = try image(.rgba8, 16, 16, usage: .sampled | .copyDestination)
      var list = setup
      list.copy(upload, to: big)
      let bigSlot = textureBase + 71
      let derivative = try quadPipeline(LoinnirShaders.samplederivFrag)
      try d.writeTexture(bigSlot, ImageView(big))
      // Texel (2x + 1, 2y + 1) is the one a quarter texel past the pixel's centre line lands in: even sum, so black.
      try d.writeSampler(3, SamplerDescriptor(minFilter: .nearest, magFilter: .linear, mipmapMode: .nearest))
      try d.writeSampler(4, SamplerDescriptor(minFilter: .linear, magFilter: .nearest, mipmapMode: .nearest))
      let table = try d.allocate(.upload, bytes: 32 * 4)
      params(table, 0, texture: bigSlot, sampler: 3, direction: [1, 1, 1.0 / 64, 1.0 / 64])
      params(table, 1, texture: bigSlot, sampler: 4, direction: [1, 1, 1.0 / 64, 1.0 / 64])
      params(table, 2, texture: slot, sampler: 3, direction: [1, 1, 0, 0])
      params(table, 3, texture: slot, sampler: 4, direction: [1, 1, 0, 0])
      let px = try drawTilesApart(derivative, table, count: 4, before: list)
      // Tile 0, minify nearest: black. Tile 1, minify linear: the four texels about the point weigh .0625 black, .1875 white,
      // .1875 white and .5625 black: 96. Tile 3, magnify nearest: the pattern exactly. Tile 2, magnify linear: smooth. The pixels
      // of the quads the diagonal crosses are not judged: their derivatives come from helper lanes of the other triangle.
      var judged = 0, blended = 0
      for y in 0..<8 {
        for x in 0..<8 {
          let onDiagonal = x + y >= 5 && x + y <= 9
          if !onDiagonal {
            judged += 1
            let a = pixel(px, 32, x, y)
            if a != [0, 0, 0, 255] { bad("filters: minify nearest reads \(hex(a)) at (\(x), \(y)), expected black") }
            let b = pixel(px, 32, 8 + x, y)
            if !near(b, [96, 96, 96, 255], 3) { bad("filters: minify linear reads \(hex(b)) at (\(x), \(y)), expected 96 within 3") }
            let g = pixel(px, 32, 24 + x, y)
            let want = pattern(x / 2 * 2, y / 2 * 2)
            if !near(g, want, 0) { bad("filters: magnify nearest reads \(hex(g)) at (\(x), \(y)), expected \(hex(want))") }
          }
          if x >= 1 && x < 7 && pixel(px, 32, 16 + x, y) != pixel(px, 32, 24 + x, y) { blended += 1 }
        }
      }
      if blended == 0 { bad("filters: magnify linear is the same as nearest") }
      ok("samplers: the minify and magnify filters chosen apart (a checker minified: nearest exact, linear 96 within 3; a pattern magnified: nearest exact, linear blended \(blended) pixels), \(judged) pixels each")
    } else {
      skip("samplers: separate filters", "no separate minify and magnify filters")
    }

    probing = false
    // Level of detail: bias, minimum and maximum, on the four coloured levels.
    if f.mipmaps {
      let levelColors: [[Float]] = [[1, 0, 0, 1], [0, 1, 0, 1], [0, 0, 1, 1], [1, 1, 1, 1]]
      let texture = try image(.rgba8, 8, 8, mips: 4, usage: .sampled | .copyDestination)
      var list = GPUCommandList()
      for m in 0..<4 {
        let c = levelColors[m]
        list.clear(texture, color: .float(c[0], c[1], c[2], c[3]), ranges: [ImageSubresourceRange(aspects: .color, baseMip: UInt32(m))])
      }
      let lodSlot = textureBase + 72
      try d.writeTexture(lodSlot, ImageView(texture))
      try d.writeSampler(5, SamplerDescriptor(filter: .nearest, mipmapMode: .nearest, mipLodBias: 2))
      try d.writeSampler(6, SamplerDescriptor(filter: .nearest, mipmapMode: .nearest, minLod: 3))
      try d.writeSampler(7, SamplerDescriptor(filter: .nearest, mipmapMode: .nearest, maxLod: 1))
      try d.writeSampler(8, SamplerDescriptor(filter: .nearest, mipmapMode: .nearest, mipLodBias: -1))
      let table = try d.allocate(.upload, bytes: 32 * 4)
      params(table, 0, texture: lodSlot, sampler: 5, lod: 0)  // bias 2: level 2
      params(table, 1, texture: lodSlot, sampler: 6, lod: 0)  // minimum 3: level 3
      params(table, 2, texture: lodSlot, sampler: 7, lod: 3)  // maximum 1: level 1
      params(table, 3, texture: lodSlot, sampler: 8, lod: 2)  // bias -1: level 1
      let pso = try quadPipeline(LoinnirShaders.lodFrag)
      let px = try drawTilesApart(pso, table, count: 4, before: list)
      judgeTiles("lod", px, [bytes(levelColors[2]), bytes(levelColors[3]), bytes(levelColors[1]), bytes(levelColors[1])], tolerance: 0)
      ok("samplers: level-of-detail bias (+2, -1), minimum (3) and maximum (1), exact")
    }

    // Anisotropy: an axis-aligned quad filters the same, so the pattern is exact with nearest filters and the limit set.
    if f.samplerAnisotropy {
      try d.writeSampler(9, SamplerDescriptor(filter: .nearest, mipmapMode: .nearest, maxAnisotropy: min(d.limits.maxAnisotropy, 4)))
      let table = try d.allocate(.upload, bytes: 32)
      params(table, 0, texture: slot, sampler: 9, direction: [1, 1, 0, 0])
      let pso = try quadPipeline(LoinnirShaders.sampleFrag)
      let px = try drawTilesApart(pso, table, count: 1, before: setup)
      let n = judge("anisotropy", px, 8, 8) { x, y in pattern(x / 2 * 2, y / 2 * 2) }
      ok("samplers: an anisotropy limit of 4 on a nearest sampler, \(n) pixels exact")
    }

    // Unnormalized coordinates: texels, not 0 to 1.
    if f.unnormalizedCoordinates {
      try d.writeSampler(10, SamplerDescriptor(filter: .nearest, mipmapMode: .nearest, minLod: 0, maxLod: 0, unnormalizedCoordinates: true))
      let table = try d.allocate(.upload, bytes: 32)
      params(table, 0, texture: slot, sampler: 10, direction: [4, 4, 0, 0])
      let pso = try quadPipeline(LoinnirShaders.sampleFrag)
      let px = try drawTilesApart(pso, table, count: 1, before: setup)
      let n = judge("unnormalized", px, 8, 8) { x, y in pattern(x / 2 * 2, y / 2 * 2) }
      ok("samplers: unnormalized coordinates (texels 0 to 4 across the tile), \(n) pixels exact")
    }
  }

  // MARK: Depth and stencil

  func depthImages() throws(GPUError) {
    guard f.depth, f.sampledImages, rgbaTarget else { return skip("depth images", "no depth images") }
    let cases: [(PixelFormat, String, Float, [UInt8])] = [
      (.depth16, "depth16", 0.25, le16(16384)),
      (.depth32f, "depth32f", 0.5, f32(0.5)),
      (.depth24stencil8, "depth24stencil8", 0.75, le32(12_582_911 + 1)),
      (.depth32fstencil8, "depth32fstencil8", 0.125, f32(0.125)),
    ]
    var names = ""
    for (format, name, depth, raw) in cases {
      guard d.limits.formats(format).sampled else { skip("depth image \(name)", "not offered sampled"); continue }
      let usage: ImageUsage = .sampled | .copySource | .copyDestination
      let image = try self.image(format, 4, 4, usage: usage)
      var list = GPUCommandList()
      list.clear(image, depth: depth, stencil: 77)
      // Sampled: depth reads in the first channel and (0, 0, 1) in the others.
      let slot = textureBase + 90
      try d.writeTexture(slot, ImageView(image, aspects: .depth))
      try d.writeSampler(1, SamplerDescriptor(filter: .nearest, addressMode: .clampToEdge, mipmapMode: .nearest))
      let table = try d.allocate(.upload, bytes: 32)
      params(table, 0, texture: slot, sampler: 1, direction: [1, 1, 0, 0])
      let pso = try quadPipeline(LoinnirShaders.sampleFrag)
      var px = try drawTilesApart(pso, table, count: 1, before: list)
      let want = UInt8(depth * 255 + 0.5)
      let n = judge("depth \(name)", px, 8, 8, tolerance: 1) { _, _ in [want, 0, 0, 255] }
      // Copied out: the aspect's bytes as the buffer holds them.
      let readback = try d.allocate(.readback, bytes: 4 * 4 * 4)
      var out = list
      out.copy(image, to: readback, regions: [BufferImageRegion(subresource: ImageSubresourceLayers(aspects: .depth), imageExtent: Extent3D(width: 4, height: 4))])
      try run(out)
      let got = read(readback, 16 * raw.count)
      for t in 0..<16 where Array(got[(t * raw.count)..<((t + 1) * raw.count)]) != raw {
        bad("depth copy \(name): texel \(t) reads \(hex(Array(got[(t * raw.count)..<((t + 1) * raw.count)]))), expected \(hex(raw))")
      }
      px = []
      ok("depth image \(name): cleared to \(Int(depth * 1000)) thousandths, sampled (\(n) pixels within 1) and copied out as \(raw.count)-byte texels, exact")
      names += " " + name
    }
    // Stencil aspects, read as unsigned integers.
    for (format, name) in [(PixelFormat.depth24stencil8, "depth24stencil8"), (.depth32fstencil8, "depth32fstencil8"), (.stencil8, "stencil8")] {
      guard d.limits.formats(format).sampled else { continue }
      let image = try self.image(format, 4, 4, usage: .sampled | .copySource | .copyDestination)
      var list = GPUCommandList()
      list.clear(image, depth: 0.5, stencil: 77)
      let slot = textureBase + 91
      try d.writeTexture(slot, ImageView(image, aspects: .stencil))
      try d.writeSampler(1, SamplerDescriptor(filter: .nearest, addressMode: .clampToEdge, mipmapMode: .nearest))
      let table = try d.allocate(.upload, bytes: 32)
      params(table, 0, texture: slot, sampler: 1)
      let pso = try quadPipeline(LoinnirShaders.sampleuintFrag)
      let px = try drawTilesApart(pso, table, count: 1, before: list)
      let n = judge("stencil \(name)", px, 8, 8) { _, _ in [77, 0, 0, 1] }
      let readback = try d.allocate(.readback, bytes: 16)
      var out = list
      out.copy(image, to: readback, regions: [BufferImageRegion(subresource: ImageSubresourceLayers(aspects: .stencil), imageExtent: Extent3D(width: 4, height: 4))])
      try run(out)
      for t in 0..<16 where read(readback, 16)[t] != 77 { bad("stencil copy \(name): texel \(t) is not 77") }
      ok("stencil aspect of \(name): cleared to 77, sampled as an unsigned integer (\(n) pixels) and copied out, exact")
    }
    // Comparison: reference op depth, every operation against three references.
    if f.samplerCompare, d.limits.formats(.depth32f).sampled {
      let image = try self.image(.depth32f, 4, 4, usage: .sampled | .copyDestination)
      var list = GPUCommandList()
      list.clear(image, depth: 0.5)
      let slot = textureBase + 92
      try d.writeTexture(slot, ImageView(image))
      let ops: [(CompareOp, (Float, Float) -> Bool)] = [
        (.never, { _, _ in false }), (.less, { r, z in r < z }), (.equal, { r, z in r == z }), (.lessOrEqual, { r, z in r <= z }),
        (.greater, { r, z in r > z }), (.notEqual, { r, z in r != z }), (.greaterOrEqual, { r, z in r >= z }), (.always, { _, _ in true }),
      ]
      let refs: [Float] = [0.25, 0.5, 0.75]
      var checked = 0
      for (i, (op, rule)) in ops.enumerated() {
        try d.writeSampler(UInt32(i), SamplerDescriptor(filter: .nearest, addressMode: .clampToEdge, mipmapMode: .nearest, compare: op))
        let table = try d.allocate(.upload, bytes: 32 * 3)
        for (r, ref) in refs.enumerated() { params(table, r, texture: slot, sampler: UInt32(i), lod: ref) }
        let pso = try quadPipeline(LoinnirShaders.shadowFrag)
        let px = try drawTilesApart(pso, table, count: 3, before: i == 0 ? list : GPUCommandList())
        judgeTiles("compare \(i)", px, refs.map { rule($0, 0.5) ? [255, 255, 255, 255] : [0, 0, 0, 255] }, tolerance: 0)
        checked += 3
      }
      ok("depth compare: all eight functions against three references on a depth of 0.5 (reference op depth), \(checked) results exact")
    } else {
      skip("depth compare", "no comparison samplers or no sampled depth32f")
    }
    if !names.isEmpty { print("loinnir-test: depth images ok:" + names) }
  }

  // MARK: Copies and clears of every format

  func transfers() throws(GPUError) {
    guard f.imageRegionCopies, f.copyImage, f.clearImage else { return skip("transfers", "no region copies or clears") }
    let usage: ImageUsage = .copySource | .copyDestination
    // Clears of formats, read back as the buffer holds them: the raw bytes of one texel.
    struct ClearCase {
      var format: PixelFormat
      var value: ClearColor
      var texel: [UInt8]
    }
    let clears: [ClearCase] = [
      ClearCase(format: .r8, value: .float(0.2, 0, 0, 0), texel: [51]),
      ClearCase(format: .rg8, value: .float(0.2, 0.8, 0, 0), texel: [51, 204]),
      ClearCase(format: .rgba8snorm, value: .float(0.5, -0.5, 1, -1), texel: [64, 192, 127, 129]),
      ClearCase(format: .bgra8, value: .float(1, 0.5, 0, 1), texel: [0, 128, 255, 255]),
      ClearCase(format: .rgba16float, value: .float(0.25, 0.5, 0.75, 1), texel: le16(0x3400) + le16(0x3800) + le16(0x3A00) + le16(0x3C00)),
      ClearCase(format: .r32float, value: .float(0.5, 0, 0, 0), texel: f32(0.5)),
      ClearCase(format: .r32uint, value: .uint(0xDEAD_BEEF, 0, 0, 0), texel: le32(0xDEAD_BEEF)),
      ClearCase(format: .rg16sint, value: .sint(-2, 3, 0, 0), texel: le16(0xFFFE) + le16(3)),
      ClearCase(format: .rgba8uint, value: .uint(1, 2, 3, 4), texel: [1, 2, 3, 4]),
      ClearCase(format: .rgb10a2unorm, value: .float(0.5, 0.25, 0.75, 1), texel: le32(512 | 256 << 10 | 767 << 20 | 3 << 30)),
      ClearCase(format: .rg11b10float, value: .float(0.5, 0.5, 0.5, 1), texel: le32(0x380 | 0x380 << 11 | 0x1C0 << 22)),
    ]
    var done = ""
    for c in clears {
      guard d.limits.formats(c.format).sampled || d.limits.formats(c.format).storage || d.limits.formats(c.format).renderTarget else { continue }
      let image = try self.image(c.format, 4, 4, usage: usage)
      let readback = try d.allocate(.readback, bytes: 16 * c.texel.count)
      var list = GPUCommandList()
      list.clear(image, color: c.value)
      list.copy(image, to: readback, regions: [BufferImageRegion(imageExtent: Extent3D(width: 4, height: 4))])
      try run(list)
      let got = read(readback, 16 * c.texel.count)
      for t in 0..<16 where Array(got[(t * c.texel.count)..<((t + 1) * c.texel.count)]) != c.texel {
        bad("clear \(c.texel.count)-byte format: texel \(t) reads \(hex(Array(got[(t * c.texel.count)..<((t + 1) * c.texel.count)]))), expected \(hex(c.texel))")
      }
      done += " \(c.texel.count)B"
    }
    ok("clears: colour images of \(clears.count) formats cleared and copied out, each texel exactly its format's bytes (sizes in bytes:\(done))")

    // Regions: a block of a 3D image placed with a buffer row length and image height, and read back tightly packed.
    if f.volumeImages {
      let volume = try image(.rgba8, 8, 8, depth: 4, dimension: .d3, usage: usage)
      // A 4 x 2 x 2 block, rows of 6 texels and slices of 3 rows in the buffer.
      var data = [UInt8](repeating: 0xEE, count: 6 * 3 * 2 * 4)
      for z in 0..<2 {
        for y in 0..<2 {
          for x in 0..<4 {
            let o = ((z * 3 + y) * 6 + x) * 4
            data[o] = UInt8(x + 1)
            data[o + 1] = UInt8(y + 1)
            data[o + 2] = UInt8(z + 1)
            data[o + 3] = 255
          }
        }
      }
      let upload = try d.allocate(.upload, bytes: data.count)
      store(upload, bytes: data)
      let readback = try d.allocate(.readback, bytes: 8 * 8 * 4 * 4)
      var list = GPUCommandList()
      list.clear(volume, color: .float(0, 0, 0, 0))
      list.copy(upload, to: volume, regions: [BufferImageRegion(bufferRowLength: 6, bufferImageHeight: 3, imageOffset: Offset3D(x: 1, y: 2, z: 1), imageExtent: Extent3D(width: 4, height: 2, depth: 2))])
      list.copy(volume, to: readback, regions: [BufferImageRegion(imageExtent: Extent3D(width: 8, height: 8, depth: 4))])
      try run(list)
      let got = read(readback, 8 * 8 * 4 * 4)
      var wrong = 0
      for z in 0..<4 {
        for y in 0..<8 {
          for x in 0..<8 {
            let inside = x >= 1 && x < 5 && y >= 2 && y < 4 && z >= 1 && z < 3
            let want: [UInt8] = inside ? [UInt8(x), UInt8(y - 1), UInt8(z), 255] : [0, 0, 0, 0]
            let o = ((z * 8 + y) * 8 + x) * 4
            if Array(got[o..<(o + 4)]) != want { wrong += 1 }
          }
        }
      }
      if wrong != 0 { bad("3D region: \(wrong) of 256 texels are not where the offset, row length and image height put them") }
      ok("transfers: a 4x2x2 block placed at (1, 2, 1) of a 3D image with a row length of 6 and an image height of 3, and the 8x8x4 image read back, 256 texels exact")
    }
    // Array layers and a mip level: copy a 4 x 4 block of mip 1 layer 2 of an array out and in again.
    if f.mipmaps, f.arrayImages {
      let layered = try image(.rgba8, 8, 8, mips: 2, layers: 3, usage: usage)
      var data: [UInt8] = []
      for y in 0..<4 { for x in 0..<4 { data.append(contentsOf: [UInt8(x * 40), UInt8(y * 40), 9, 255]) } }
      let upload = try d.allocate(.upload, bytes: 64)
      store(upload, bytes: data)
      let readback = try d.allocate(.readback, bytes: 64)
      let level = ImageSubresourceLayers(aspects: .color, mip: 1, baseLayer: 2, layerCount: 1)
      var list = GPUCommandList()
      list.clear(layered, color: .float(0, 0, 0, 1))
      list.copy(upload, to: layered, regions: [BufferImageRegion(subresource: level, imageExtent: Extent3D(width: 4, height: 4))])
      let other = try image(.rgba8, 8, 8, mips: 2, layers: 3, usage: usage)
      list.copyImage(layered, to: other, regions: [ImageCopyRegion(srcSubresource: level, dstSubresource: ImageSubresourceLayers(aspects: .color, mip: 1, baseLayer: 0, layerCount: 1), extent: Extent3D(width: 4, height: 4))])
      list.copy(other, to: readback, regions: [BufferImageRegion(subresource: ImageSubresourceLayers(aspects: .color, mip: 1, baseLayer: 0, layerCount: 1), imageExtent: Extent3D(width: 4, height: 4))])
      try run(list)
      let got = read(readback, 64)
      if got != data { bad("array and mip copies: the block read back differs") }
      ok("transfers: a 4x4 block copied into mip 1 of layer 2, onto mip 1 of layer 0 of another image and out again, exact")
    }
    // Block-compressed formats are plain block copies, and are sampled: a block of each family that decodes to one colour.
    if f.compressedASTC || f.compressedETC2 {
      var cases: [FormatCase] = []
      if f.compressedASTC {
        // A void-extent block (LDR): one colour, 16-bit channels (0xFFFF, 0, 0x8000, 0xFFFF).
        cases.append(FormatCase(name: "astc4x4", format: .astc(.b4x4), texel: [0xFC, 0xFD, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0, 0, 0, 0x80, 0xFF, 0xFF],
                                want: [255, 0, 128, 255], tolerance: 1))
      }
      if f.compressedETC2 {
        // A differential block of base (16, 16, 16) in five bits (132 in eight), table 0, every texel index 0: +2.
        cases.append(FormatCase(name: "etc2rgb8", format: .etc2rgb8, texel: [0x80, 0x80, 0x80, 0x02, 0, 0, 0, 0], want: [134, 134, 134, 255], tolerance: 1))
      }
      if f.compressedBC {
        // BC1: color0 pure red (0xF800), color1 black, every index 0.
        cases.append(FormatCase(name: "bc1rgba", format: .bc1rgba, texel: [0x00, 0xF8, 0, 0, 0, 0, 0, 0], want: [255, 0, 0, 255], tolerance: 1))
      }
      try compressedTiles("compressed formats", cases)
    }

    if f.compressedASTC || f.compressedETC2 {
      let format: PixelFormat = f.compressedASTC ? .astc(.b4x4) : .etc2rgba8
      let image = try self.image(format, 8, 8, usage: usage | .sampled)
      var blocks: [UInt8] = []
      for i in 0..<64 { blocks.append(UInt8((i * 5 + 1) & 255)) }
      let upload = try d.allocate(.upload, bytes: 64)
      store(upload, bytes: blocks)
      let readback = try d.allocate(.readback, bytes: 64)
      var list = GPUCommandList()
      list.copy(upload, to: image, regions: [BufferImageRegion(imageExtent: Extent3D(width: 8, height: 8))])
      list.copy(image, to: readback, regions: [BufferImageRegion(imageExtent: Extent3D(width: 8, height: 8))])
      try run(list)
      if read(readback, 64) != blocks { bad("compressed copy: the four blocks read back differ") }
      ok("transfers: four 16-byte blocks of a compressed image copied in and out, exact")
    } else {
      skip("transfers: compressed blocks", "no compressed formats")
    }
    // A linear blit: 8 by 8 to 16 by 16 and back, and rgba8 into bgra8.
    if f.blitImage, d.limits.formats(.rgba8).blitSource, d.limits.formats(.bgra8).blitDestination {
      let small = try image(.rgba8, 8, 8, usage: usage)
      let big = try image(.rgba8, 16, 16, usage: usage)
      let swapped = try image(.bgra8, 8, 8, usage: usage)
      let upload = try d.allocate(.upload, bytes: 256)
      store(upload, bytes: patternData())
      var list = GPUCommandList()
      list.copy(upload, to: small)
      list.blitImage(small, to: big, regions: [ImageBlitRegion(srcMax: Offset3D(x: 8, y: 8, z: 1), dstMax: Offset3D(x: 16, y: 16, z: 1))], filter: .linear)
      list.blitImage(small, to: swapped, regions: [ImageBlitRegion(srcMax: Offset3D(x: 8, y: 8, z: 1), dstMax: Offset3D(x: 8, y: 8, z: 1))], filter: .nearest)
      let bigPixels = try readBack(list, big)
      let swappedBytes = try readBack(GPUCommandList(), swapped)
      // Linear: a pixel at (2x + 1, 2y + 1) is the mean of 2x2 texels around... judged against the bilinear of the pattern.
      var n = 0
      for y in 2..<14 {
        for x in 2..<14 {
          func texelValue(_ tx: Int, _ ty: Int, _ c: Int) -> Float { Float(pattern(min(max(tx, 0), 7), min(max(ty, 0), 7))[c]) }
          let sx = (Float(x) + 0.5) / 2 - 0.5, sy = (Float(y) + 0.5) / 2 - 0.5
          let x0 = Int(sx.rounded(.down)), y0 = Int(sy.rounded(.down))
          let fx = sx - Float(x0), fy = sy - Float(y0)
          var want: [UInt8] = []
          for c in 0..<3 {
            let top = texelValue(x0, y0, c) * (1 - fx) + texelValue(x0 + 1, y0, c) * fx
            let bottom = texelValue(x0, y0 + 1, c) * (1 - fx) + texelValue(x0 + 1, y0 + 1, c) * fx
            want.append(UInt8(min(max(top * (1 - fy) + bottom * fy + 0.5, 0), 255)))
          }
          let got = pixel(bigPixels, 16, x, y)
          if !near(Array(got[0..<3]), want, 2) { bad("blit linear: (\(x), \(y)) reads \(hex(got)), expected \(hex(want)) within 2") }
          n += 1
        }
      }
      // rgba8 into bgra8: the bytes' red and blue exchange.
      for y in 0..<8 {
        for x in 0..<8 {
          let c = pattern(x, y)
          let got = pixel(swappedBytes, 8, x, y)
          if got != [c[2], c[1], c[0], c[3]] { bad("blit rgba8 into bgra8: (\(x), \(y)) reads \(hex(got))") }
        }
      }
      ok("transfers: a linear 2x blit within 2 of the bilinear reference (\(n) pixels) and rgba8 into bgra8 exact")
    }
  }

  // MARK: Import

  /// Memory and an image exported and imported again in the one process: the pages are the same, so what the GPU does through the
  /// import is what the owner's mapping reads, and what the GPU drew into an image is what a second image over its pages samples.
  func imports() throws(GPUError) {
    guard f.importHandle else { return skip("import", "the device can't import handles") }
    // Memory: plain stores through the imported address, read through the exporter's pointer.
    let source = try d.allocate(.upload, bytes: 4096)
    guard let raw = d.exportHandle(source) else { throw .invalid("the device exported no handle for memory") }
    let handle = Handle(raw: raw)
    let imported = try d.importHandle(handle.raw, intent: .upload, bytes: 4096)
    if imported.address == source.address { bad("import: the imported memory has the exporter's address") }
    unsafe source.pointer!.initializeMemory(as: UInt8.self, repeating: 0, count: 4096)
    // A plain store through the imported address: invocation i stores i + 1 in word i; the exporter's pointer reads them.
    let shader = try d.makeComputePipeline(spirv: LoinnirShaders.plainstoreComp)
    let root = try d.allocate(.upload, bytes: 16)
    store(root, bytes: le32(UInt32(truncatingIfNeeded: imported.address)) + le32(UInt32(truncatingIfNeeded: imported.address >> 32)))
    var list = GPUCommandList()
    list.dispatch(shader, root: root.address, x: 1)
    try run(list)
    let n: UInt32 = 64
    var wrongWords = 0
    for i in 0..<64 where word(source, i) != UInt32(i + 1) { wrongWords += 1 }
    // A probe: a plain store through a root pointer reads 0 on the Mali backend whatever the memory (gpucore(2)'s BUGS), so
    // this says what it read and is not judged.
    probing = true
    if wrongWords != 0 { bad("import: \(wrongWords) of 64 words the GPU stored through the imported address are not in the exporter's pages") }
    probing = false
    // And the other way: the CPU's write through the import is the exporter's read, and the GPU sees the owner's later write.
    unsafe imported.pointer!.storeBytes(of: 7, toByteOffset: 64, as: UInt32.self)
    if word(source, 16) != 7 { bad("import: a write through the import isn't in the exporter's pages") }
    ok("import: memory exported and imported again, a write through the import in the exporter's pages (\(n) GPU stores probed)")
    // An image: drawn into by the GPU, imported as another image, sampled.
    guard rgbaTarget else { return }
    let pattern8 = try image(.rgba8, 8, 8, usage: .sampled | .copyDestination)
    let upload = try d.allocate(.upload, bytes: 256)
    store(upload, bytes: patternData())
    let scan = try image(.rgba8, 16, 16, usage: .renderTarget | .copySource | .scanout)
    guard let rawImage = d.exportWindowHandle(scan) else { throw .invalid("the device exported no window handle for a scanout image") }
    let imageHandle = Handle(raw: rawImage)
    let imageDescriptor = ImageDescriptor(format: .rgba8, width: 16, height: 16, usage: .sampled | .copySource)
    let twin = try d.importHandle(imageHandle.raw, as: imageDescriptor)
    try d.writeTexture(textureBase + 95, ImageView(pattern8))
    try d.writeSampler(1, SamplerDescriptor(filter: .nearest, addressMode: .clampToEdge, mipmapMode: .nearest))
    let table = try d.allocate(.upload, bytes: 64)
    params(table, 0, texture: textureBase + 95, sampler: 1)
    let pso = try quadPipeline(LoinnirShaders.lodFrag)
    var draw = GPUCommandList()
    draw.copy(upload, to: pattern8)
    draw.render(RenderingInfo(colors: [Attachment(image: scan, load: .clear(0, 0, 0, 1))])) { r in
      r.draw(pso, root: table.address, vertices: 6)
    }
    try run(draw)
    try d.writeTexture(textureBase + 96, ImageView(twin))
    params(table, 1, texture: textureBase + 96, sampler: 1)
    let copy = try colorTarget(16, 16)
    var second = GPUCommandList()
    second.render(RenderingInfo(colors: [Attachment(image: copy, load: .clear(0, 0, 0, 1))])) { r in
      r.draw(pso, root: table.address + 32, vertices: 6)
    }
    let px = try readBack(second, copy)
    let n2 = judge("import (sampled)", px, 16, 16) { x, y in pattern(x / 2, y / 2) }
    // Read straight through the import too.
    let direct = try d.allocate(.readback, bytes: 16 * 16 * 4)
    var out = GPUCommandList()
    out.copy(twin, to: direct)
    try run(out)
    let bytes = read(direct, 16 * 16 * 4)
    var wrong = 0
    for y in 0..<16 { for x in 0..<16 where Array(bytes[((y * 16 + x) * 4)..<((y * 16 + x) * 4 + 4)]) != pattern(x / 2, y / 2) { wrong += 1 } }
    if wrong != 0 { bad("import: \(wrong) of 256 texels read through the imported image differ from what the GPU drew") }
    ok("import: an image the GPU drew into, imported as another image over its pages, sampled (\(n2) pixels) and copied out, exact")
    _ = handle
    _ = imageHandle
  }

  // MARK: Present images

  /// A window's frames where the device presents direct (`makePresentImage`): drawn by the GPU into the image's own pages in rows
  /// of the width (widths whose rows are and aren't a multiple of 64 bytes), read through the window's handle as a window's
  /// reader maps it, and imported again as another image and sampled, as Radharc's GPU renderer does; and the timeline's
  /// counter, which a window may read and not add to.
  func presentImages() throws(GPUError) {
    guard f.presentDirect else { return skip("present", "the device stages a window's frames") }
    let pattern8 = try image(.rgba8, 8, 8, usage: .sampled | .copyDestination)
    let upload = try d.allocate(.upload, bytes: 256)
    store(upload, bytes: patternData())
    try d.writeTexture(textureBase + 97, ImageView(pattern8))
    try d.writeSampler(1, SamplerDescriptor(filter: .nearest, addressMode: .clampToEdge, mipmapMode: .nearest))
    let table = try d.allocate(.upload, bytes: 64)
    params(table, 0, texture: textureBase + 97, sampler: 1)
    let pso = try quadPipeline(LoinnirShaders.lodFrag)
    var first = GPUCommandList()
    first.copy(upload, to: pattern8)
    try run(first)
    // Each pixel's centre falls inside one texel of the pattern for these sizes ((x + 0.5) * 8 / width is never whole).
    for (width, height) in [(64, 24), (40, 24), (104, 40)] {
      let w = Int32(width), h = Int32(height)
      func want(_ x: Int, _ y: Int) -> [UInt8] { pattern((2 * x + 1) * 4 / width, (2 * y + 1) * 4 / height) }
      let frame = try d.makePresentImage(format: .rgba8, width: w, height: h, usage: .renderTarget)
      guard frame.isDirect, frame.bytes == width * height * 4 else {
        bad("present \(width)x\(height): a direct frame of \(width * height * 4) bytes, not staged (\(frame.bytes))")
        d.destroy(frame)
        continue
      }
      var draw = GPUCommandList()
      draw.render(RenderingInfo(colors: [Attachment(image: frame.image, load: .clear(0, 0, 0, 1))])) { r in
        r.draw(pso, root: table.address, vertices: 6)
      }
      var list = GPUCommandList()
      frame.recordPresent(into: &list)
      if !list.isEmpty { bad("present \(width)x\(height): presenting a direct frame adds work") }
      try run(draw)
      // The window's reader: the pages through the handle the window is given, mapped as Radharc maps them.
      guard let raw = frame.exportHandle(d) else { throw .invalid("present: no handle for the window") }
      let vmo = Handle(raw: raw)
      let size = (width * height * 4 + 4095) & ~4095
      guard let mapping = try? VMO.map(vmo, length: size, writable: false) else { throw .invalid("present: the window's handle can't be mapped") }
      var wrong = 0
      var firstWrong = ""
      for y in 0..<height {
        for x in 0..<width {
          var got: [UInt8] = []
          for c in 0..<4 { got.append(unsafe mapping.address.load(fromByteOffset: (y * width + x) * 4 + c, as: UInt8.self)) }
          if got != want(x, y) {
            if wrong == 0 { firstWrong = " (the first at (\(x), \(y)): \(hex(got)), expected \(hex(want(x, y))))" }
            wrong += 1
          }
        }
      }
      if wrong != 0 { bad("present \(width)x\(height): \(wrong) of \(width * height) pixels the window reads are wrong\(firstWrong)") }
      // Radharc's GPU renderer: the window's pages imported and sampled where they lie, where the rows are a multiple of 64
      // bytes; the others the device refuses (the texture unit reads zeros from them), and the renderer uploads them.
      if f.importHandle && width * 4 % 64 != 0 {
        var refused = false
        do throws(GPUError) { d.destroy(try d.importHandle(vmo.raw, as: ImageDescriptor(format: .rgba8, width: w, height: h, usage: .sampled))) }
        catch { if case .unsupported = error { refused = true } }
        if !refused { bad("present \(width)x\(height): an import of rows of \(width * 4) bytes is not refused") }
        if wrong == 0 && refused {
          ok("present: a \(width)x\(height) frame drawn into its own pages in rows of \(width * 4) bytes, read by the window (\(width * height) pixels), exact; its import refused")
        }
      } else if f.importHandle {
        let twin = try d.importHandle(vmo.raw, as: ImageDescriptor(format: .rgba8, width: w, height: h, usage: .sampled))
        try d.writeTexture(textureBase + 98, ImageView(twin))
        params(table, 1, texture: textureBase + 98, sampler: 1)
        let copy = try colorTarget(w, h)
        var second = GPUCommandList()
        second.render(RenderingInfo(colors: [Attachment(image: copy, load: .clear(0, 0, 0, 1))])) { r in
          r.draw(pso, root: table.address + 32, vertices: 6)
        }
        let px = try readBack(second, copy)
        let n = judge("present \(width)x\(height) imported", px, width, height) { x, y in want(x, y) }
        d.destroy(twin)
        if wrong == 0 {
          ok("present: a \(width)x\(height) frame drawn into its own pages in rows of \(width * 4) bytes, read by the window (\(width * height) pixels) and imported and sampled (\(n)), exact")
        }
      } else if wrong == 0 {
        ok("present: a \(width)x\(height) frame drawn into its own pages in rows of \(width * 4) bytes, read by the window (\(width * height) pixels), exact")
      }
      _ = consume mapping
      _ = consume vmo
      d.destroy(frame)
    }
    // The timeline's counter: past what was signalled, and the window can't raise it.
    guard let rawCounter = d.timelineHandle() else { return skip("present timeline", "the device's timeline is no counter it gives") }
    let counter = Handle(raw: rawCounter)
    let reached = (try? Counter.read(counter)) ?? -1
    if reached < Int64(timeline) { bad("present: the timeline's counter reads \(reached), past which the device signalled \(timeline)") }
    if (try? Counter.add(counter, 1)) != nil { bad("present: the timeline's counter given to a window can be raised") }
    ok("present: the timeline's counter reads \(reached) after \(timeline) was signalled, and refuses an add")
  }

  /// Runs the resource cases, and gives the count of checks that failed (they go on past a failure, to show every one).
  @discardableResult
  func resourceCases() -> Int {
    var t = Clock.monotonic()
    do throws(GPUError) { try formats() } catch { caught("formats", error) }
    lap("formats", t)
    t = Clock.monotonic()
    do throws(GPUError) { try views() } catch { caught("views", error) }
    lap("views", t)
    t = Clock.monotonic()
    do throws(GPUError) { try samplers() } catch { caught("samplers", error) }
    lap("samplers", t)
    t = Clock.monotonic()
    do throws(GPUError) { try depthImages() } catch { caught("depth images", error) }
    lap("depth images", t)
    t = Clock.monotonic()
    do throws(GPUError) { try transfers() } catch { caught("transfers", error) }
    lap("transfers", t)
    t = Clock.monotonic()
    do throws(GPUError) { try imports() } catch { caught("import", error) }
    lap("import", t)
    t = Clock.monotonic()
    do throws(GPUError) { try presentImages() } catch { caught("present", error) }
    lap("present", t)
    for n in notes { print(n) }
    return softFailures
  }
}
