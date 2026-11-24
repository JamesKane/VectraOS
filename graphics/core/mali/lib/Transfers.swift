// SPDX-License-Identifier: BSD-3-Clause

// Copies, blits, clears, fills and resolves (gpucore(2), D174's amendment) run on the GPU, as compute jobs in order with the
// list's passes and dispatches: the CPU neither waits for the GPU before one nor touches a pixel. The hardware has no copy
// engine; the reference's copies are "a compute job or a draw" (valhall 05 section 5.11.10.1, R1.4), copies are compute or
// fragment work for ordering (02 section 2.4), and every image here is linear in GPU memory (no AFBC) but a sparse image used partly
// bound, which is in the 64 KiB layout (05 section 5.7: the kernels address its elements through its tiles, `tileWord`), so:
//
// - copies of buffers and images, fills, updates, clears and colour resolves are MaliShaders' `copy` kernel, which moves rows of
//   1 to 16-byte units through memory accesses (as R1.4 has the reference read a buffer of any row length into an image's
//   64-byte rows). It moves bytes unchanged, which is what the raw views of 05 section 5.3.2 and 03 section 3.8.5 give the
//   reference's copy paths (a depth plane as 4-byte, a stencil plane as 1-byte unsigned colour, a compressed block as one
//   64 or 128-bit texel); a clear writes its texel's bytes, made once from the value by the CPU (the value is not a pixel), and
//   a resolve each byte the mean of its samples, rounded, as the tile writeback's Average does an 8-bit normalized target
//   (08 section 8.3.2);
// - blits of one format with the nearest filter, depth and stencil included (Vulkan allows nothing else for them), are the
//   `blitRaw` kernel: each texel's bytes from the source texel nearest its centre;
// - blits that filter or convert are the `blit` kernel: the texture unit reads the source (its filter, its format and sRGB
//   decoding; the samplers' clamp-integer bits clear, as 03 section 3.7 has them for the reference's blit shaders) and the
//   kernel stores each texel in the destination's format. A draw would need the destination to be a render target, and
//   most blit destinations here are not (only rgba8, bgra8 and bgra8srgb are).
//
// Each transfer command is one dispatch, of every region and aspect it names (a job each; workgroup z names a slice of a job
// through a table). Its parameters, and any bytes it writes (a fill's pattern, an update's data), are in memory of its own,
// handed back with the submission's.

import GPUCore

#if canImport(MaliCore)
  import MaliCore
#endif
#if canImport(ValhallBackend)
  import ValhallBackend
#endif

enum Transfer {
  case copyBuffer(Region, Int, Region, Int, Int)
  case copyImage(ImageRecord, ImageRecord, [ImageCopyRegion])
  case blit(ImageRecord, ImageRecord, [ImageBlitRegion], SamplerFilter)
  case bufferToImage(Region, ImageRecord, [BufferImageRegion])
  case imageToBuffer(ImageRecord, Region, [BufferImageRegion])
  case fill(Region, Int, Int, UInt32)
  case update(Region, Int, [UInt8])
  case clearColor(ImageRecord, ClearColor, [ImageSubresourceRange])
  case clearDepthStencil(ImageRecord, Float, UInt32, [ImageSubresourceRange])
  /// A multisampled colour image resolved into a single-sample one: each texel the mean of its samples.
  case resolve(ImageRecord, ImageRecord, [ImageCopyRegion])
}

/// The transfers' compute kernels (MaliShaders, from graphics/core/mali/shaders).
enum TransferKernel: Int {
  case copy = 0
  case blitRaw = 1
  case blit = 2

  var spirv: [UInt8] {
    switch self {
    case .copy: MaliShaders.copyComp
    case .blitRaw: MaliShaders.blitRawComp
    case .blit: MaliShaders.blitComp
    }
  }
}

/// One job of the `copy` kernel: `rows` rows of `rowUnits` units of `unit` bytes, in `slices` slices of `layers` layers; the
/// source unit stride 0 repeats one unit. With `samples` above 1, each destination byte is the mean of that many source bytes,
/// `sampleStride` apart (`unit` is then 1).
struct CopyJob: Equatable {
  var src: UInt64
  var dst: UInt64
  var unit: Int
  var srcUnitStride: Int
  var rowUnits: Int
  var rows: Int
  var srcRowStride = 0
  var dstRowStride = 0
  var slices = 1
  var srcSliceStride = 0
  var dstSliceStride = 0
  var layers = 1
  var srcLayerStride = 0
  var dstLayerStride = 0
  var samples = 1
  var sampleStride = 0
  /// A side in the 64 KiB layout (`MaliDevice.tileWord`, 0 for a linear one), and the element its address's rows start at (x in bits
  /// 15:0, y in 31:16): its address is then its slice's start.
  var srcTile: UInt32 = 0
  var dstTile: UInt32 = 0
  var srcOrigin: UInt32 = 0
  var dstOrigin: UInt32 = 0

  static let words = 22
}

/// One job of the `blitRaw` and `blit` kernels: a destination rectangle of a level (`dx`, `dy`, `dz` its lesser corner, `w`,
/// `h`, `d` its size) in `layers` layers, and the source rectangle it scales from (the first corner and the signed size, in the
/// source level's texels); `flips` bit n: the destination's corners on axis n are reversed.
struct BlitJob: Equatable {
  var src: UInt64 = 0
  var dst: UInt64
  var bytes: Int
  var srcRowStride = 0
  var srcSliceStride = 0
  var srcLayerStride = 0
  var dstRowStride: Int
  var dstSliceStride: Int
  var dstLayerStride: Int
  var dx: Int
  var dy: Int
  var dz: Int
  var w: Int
  var h: Int
  var d: Int
  var layers: Int
  var sx: Float
  var sy: Float
  var sz: Float
  var sw: Float
  var sh: Float
  var sd: Float
  var flips: UInt32
  var srcWidth: Int
  var srcHeight: Int
  var srcDepth: Int
  var texture = 0
  var sampler = 0
  var format: UInt32 = 0
  var kind: UInt32 = 0
  /// A side in the 64 KiB layout (`MaliDevice.tileWord`, 0 for a linear one).
  var srcTile: UInt32 = 0
  var dstTile: UInt32 = 0

  static let words = 34
}

extension MaliDevice {
  func plane(_ r: ImageRecord, _ aspect: ImageAspects) -> AspectPlane? {
    for p in r.planes where p.aspect == aspect { return p }
    return nil
  }

  /// The aspects of `a` the image has, one at a time.
  func singleAspects(_ a: ImageAspects) -> [ImageAspects] {
    var out: [ImageAspects] = []
    for x in [ImageAspects.color, .depth, .stencil] where a.contains(x) { out.append(x) }
    return out
  }

  /// The GPU address of a texel of a plane: its block's first byte (`z` a slice of a volume, or a sample plane).
  func texelAddress(_ r: ImageRecord, _ p: AspectPlane, mip: Int, layer: Int, x: Int = 0, y: Int = 0, z: Int = 0) -> UInt64 {
    r.region.address + UInt64(p.offset + p.layout.texelOffset(x: x, y: y, level: mip, layer: layer, z: z))
  }

  /// A plane's addressing for the kernels (copy.comp's `tiled`): 0 for a linear plane; for one in the 64 KiB layout (a sparse image's,
  /// valhall 05 section 5.7.2), bit 31, the tile's width and height in elements as log2 (bits 4:0 and 12:8) and the element's bytes
  /// as log2 (bits 20:16).
  static func tileWord(_ p: AspectPlane) -> UInt32 {
    guard p.layout.kind == .interleaved64K, let t = ImageLayout.tile64K(bytes: p.texel.bytesPerTexel) else { return 0 }
    return 1 << 31 | UInt32(t.width.trailingZeroBitCount) | UInt32(t.height.trailingZeroBitCount) << 8
      | UInt32(p.texel.bytesPerTexel.trailingZeroBitCount) << 16
  }

  /// Where a copy's rows of a plane start: the texel's address (a linear plane), or, for one in the 64 KiB layout, its slice's start,
  /// with the plane's tile word and the element the rows start at (x in bits 15:0, y in 31:16).
  func side(_ r: ImageRecord, _ p: AspectPlane, mip: Int, layer: Int, x: Int = 0, y: Int = 0, z: Int = 0)
    -> (address: UInt64, tile: UInt32, origin: UInt32)
  {
    let tile = Self.tileWord(p)
    if tile == 0 { return (texelAddress(r, p, mip: mip, layer: layer, x: x, y: y, z: z), 0, 0) }
    return (texelAddress(r, p, mip: mip, layer: layer, z: z), tile, UInt32(x / p.texel.blockWidth) | UInt32(y / p.texel.blockHeight) << 16)
  }

  /// The largest of 16, 8, 4, 2 and 1 bytes that divides every value: the unit a copy moves at once.
  static func unit(_ values: [Int], atMost most: Int = 16) -> Int {
    var u = most
    while u > 1 {
      var all = true
      for v in values where v % u != 0 { all = false }
      if all { return u }
      u /= 2
    }
    return 1
  }

  /// A kernel's program, compiled at first use.
  func transferProgram(_ k: TransferKernel) throws(GPUError) -> (shader: ComputeShader, layout: FauLayout) {
    if let p = transferPrograms[k.rawValue] { return p }
    let words = try spirvWords(k.spirv)
    let compiled: CompiledShader
    do { compiled = try ValhallBackend.compile(spirv: words, options: BackendOptions(arch: transport.info.arch)) } catch {
      throw .unsupported("the compiler refused a transfer kernel: " + describe(error))
    }
    let p = (compiled.shader, compiled.layout)
    transferPrograms[k.rawValue] = p
    return p
  }

  /// Bytes in memory of the submission's own: a fill's pattern, an update's data.
  func stage(_ bytes: [UInt8], held: inout [Region]) throws(GPUError) -> UInt64 {
    let region = try makeRegion(max(bytes.count, 16))
    held.append(region)
    var words = [UInt32](repeating: 0, count: (bytes.count + 7) / 8 * 2)
    for (i, b) in bytes.enumerated() { words[i / 4] |= UInt32(b) << UInt32(8 * (i % 4)) }
    store(words, in: region, at: 0)
    return region.address
  }

  // MARK: Steps

  /// The steps of a transfer: a dispatch of a kernel, or two for a blit that has both kinds of job; none where it moves nothing.
  func transferSteps(_ t: Transfer, held: inout [Region]) throws(GPUError) -> [Step] {
    switch t {
    case .copyBuffer(let a, let ao, let b, let bo, let bytes):
      return try copySteps(bufferCopyJobs(src: a.address + UInt64(ao), dst: b.address + UInt64(bo), bytes: bytes), held: &held)
    case .fill(let m, let offset, let bytes, let value):
      var pattern: [UInt8] = []
      for _ in 0..<4 { for k in 0..<4 { pattern.append(UInt8(truncatingIfNeeded: value >> UInt32(8 * k))) } }
      let at = try stage(pattern, held: &held)
      return try copySteps(fillJobs(pattern: at, dst: m.address + UInt64(offset), bytes: bytes), held: &held)
    case .update(let m, let offset, let data):
      guard !data.isEmpty else { return [] }
      let at = try stage(data, held: &held)
      return try copySteps(bufferCopyJobs(src: at, dst: m.address + UInt64(offset), bytes: data.count), held: &held)
    case .bufferToImage(let m, let i, let regions):
      return try copySteps(bufferImageJobs(m, i, regions, toImage: true), held: &held)
    case .imageToBuffer(let i, let m, let regions):
      return try copySteps(bufferImageJobs(m, i, regions, toImage: false), held: &held)
    case .copyImage(let a, let b, let regions):
      return try copySteps(imageCopyJobs(a, b, regions), held: &held)
    case .resolve(let a, let b, let regions):
      return try copySteps(resolveJobs(a, b, regions), held: &held)
    case .clearColor(let i, let color, let ranges):
      guard let p = plane(i, .color) else { return [] }
      let at = try stage(Self.clearTexel(i.descriptor.format, p.texel.bytesPerTexel, color), held: &held)
      return try copySteps(clearJobs(i, p, pattern: at, ranges.filter { $0.aspects.contains(.color) }), held: &held)
    case .clearDepthStencil(let i, let depth, let stencil, let ranges):
      var jobs: [CopyJob] = []
      for aspect in [ImageAspects.depth, .stencil] {
        guard let p = plane(i, aspect) else { continue }
        let texel = Self.depthStencilTexel(i.descriptor.format, aspect, depth: depth, stencil: stencil)
        let at = try stage(texel + texel + texel + texel, held: &held)
        jobs += clearJobs(i, p, pattern: at, ranges.filter { $0.aspects.contains(aspect) })
      }
      return try copySteps(jobs, held: &held)
    case .blit(let a, let b, let regions, let filter):
      let (raw, sampled) = blitJobs(a, b, regions, filter)
      var steps = try blitSteps(raw, kernel: .blitRaw, textures: [], held: &held)
      steps += try blitSteps(sampled.map { $0.job }, kernel: .blit, textures: sampled.map { ($0.texture, $0.planes) }, held: &held)
      return steps
    }
  }

  /// A dispatch of the `copy` kernel over `jobs`: their words, then the table of workgroup z to job, in memory of the step's.
  func copySteps(_ all: [CopyJob], held: inout [Region]) throws(GPUError) -> [Step] {
    let jobs = all.filter { $0.rowUnits > 0 && $0.rows > 0 && $0.slices > 0 && $0.layers > 0 }
    guard !jobs.isEmpty else { return [] }
    var z = 0
    var x = 0
    var y = 0
    var words: [UInt32] = []
    var table: [UInt32] = []
    for (n, j) in jobs.enumerated() {
      words += [
        UInt32(truncatingIfNeeded: j.src), UInt32(truncatingIfNeeded: j.src >> 32), UInt32(truncatingIfNeeded: j.dst),
        UInt32(truncatingIfNeeded: j.dst >> 32), UInt32(j.unit), UInt32(j.srcUnitStride), UInt32(j.rowUnits), UInt32(j.rows),
        UInt32(j.srcRowStride), UInt32(j.dstRowStride), UInt32(j.srcSliceStride), UInt32(j.dstSliceStride), UInt32(j.slices),
        UInt32(j.srcLayerStride), UInt32(j.dstLayerStride), UInt32(z), UInt32(j.samples), UInt32(j.sampleStride), j.srcTile, j.dstTile,
        j.srcOrigin, j.dstOrigin,
      ]
      for _ in 0..<(j.slices * j.layers) { table.append(UInt32(n)) }
      z += j.slices * j.layers
      x = max(x, (j.rowUnits + 63) / 64)
      y = max(y, j.rows)
    }
    return [try kernelStep(.copy, jobs: words, count: jobs.count, table: table, grid: Dim3(UInt32(x), UInt32(y), UInt32(z)), heap: nil,
                           held: &held)]
  }

  /// The parameters' memory (a header of the table's address and the count, the jobs, the table) and the dispatch that reads it.
  func kernelStep(_ k: TransferKernel, jobs: [UInt32], count: Int, table: [UInt32], grid: Dim3,
                  heap: (address: UInt64, bytes: Int)?, held: inout [Region]) throws(GPUError) -> Step {
    let program = try transferProgram(k)
    let tableAt = 16 + jobs.count * 4
    let region = try makeRegion(tableAt + table.count * 4 + 8)
    held.append(region)
    let tableAddress = region.address + UInt64(tableAt)
    var words: [UInt32] = [UInt32(truncatingIfNeeded: tableAddress), UInt32(truncatingIfNeeded: tableAddress >> 32), UInt32(count), 0]
    words += jobs
    words += table
    if words.count % 2 == 1 { words.append(0) }
    store(words, in: region, at: 0)
    return .dispatch(program.shader, program.layout, root: region.address, grid: grid, indirect: nil, heap: heap, kernel: k)
  }

  // MARK: Buffers

  /// A copy of `bytes` from `src` to `dst`: rows of up to 16384 units, then the rest.
  func bufferCopyJobs(src: UInt64, dst: UInt64, bytes: Int) -> [CopyJob] {
    guard bytes > 0 else { return [] }
    let unit = Self.unit([Int(truncatingIfNeeded: src & 15), Int(truncatingIfNeeded: dst & 15), bytes])
    let units = bytes / unit
    let across = min(units, 16384)
    let rows = units / across
    var jobs = [CopyJob(src: src, dst: dst, unit: unit, srcUnitStride: unit, rowUnits: across, rows: rows, srcRowStride: across * unit,
                        dstRowStride: across * unit)]
    let done = rows * across * unit
    if done < bytes {
      jobs.append(CopyJob(src: src + UInt64(done), dst: dst + UInt64(done), unit: unit, srcUnitStride: unit, rowUnits: (bytes - done) / unit,
                          rows: 1))
    }
    return jobs
  }

  /// `bytes` from `dst` filled with the 16-byte pattern at `pattern` (a 32-bit value four times): 16 bytes at a time where
  /// both ends allow, 4 otherwise; a tail of fewer than 4 bytes takes the value's first bytes.
  func fillJobs(pattern: UInt64, dst: UInt64, bytes: Int) -> [CopyJob] {
    guard bytes > 0 else { return [] }
    let unit = dst % 16 == 0 && bytes % 16 == 0 ? 16 : 4
    let units = bytes / unit
    var jobs: [CopyJob] = []
    if units > 0 {
      let across = min(units, 16384)
      let rows = units / across
      jobs.append(CopyJob(src: pattern, dst: dst, unit: unit, srcUnitStride: 0, rowUnits: across, rows: rows, dstRowStride: across * unit))
      let rest = units - rows * across
      if rest > 0 {
        jobs.append(CopyJob(src: pattern, dst: dst + UInt64(rows * across * unit), unit: unit, srcUnitStride: 0, rowUnits: rest, rows: 1))
      }
    }
    let tail = bytes - units * unit
    if tail > 0 {
      jobs.append(CopyJob(src: pattern, dst: dst + UInt64(units * unit), unit: 1, srcUnitStride: 1, rowUnits: tail, rows: 1))
    }
    return jobs
  }

  // MARK: Buffer and image

  /// Each region and aspect: the image's rows of blocks, and the buffer's rows of `bufferRowLength` texels (the extent's width
  /// when 0) in slices of `bufferImageHeight` rows, a slice for each slice of a volume and each layer.
  func bufferImageJobs(_ m: Region, _ i: ImageRecord, _ regions: [BufferImageRegion], toImage: Bool) -> [CopyJob] {
    var jobs: [CopyJob] = []
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
        let mip = Int(r.subresource.mip)
        let level = p.layout.levels[mip]
        let at = side(i, p, mip: mip, layer: Int(r.subresource.baseLayer), x: Int(r.imageOffset.x), y: Int(r.imageOffset.y),
                      z: Int(r.imageOffset.z))
        let image = at.address
        let buffer = m.address + UInt64(r.bufferOffset)
        let unit = Self.unit([Int(truncatingIfNeeded: image & 15), Int(truncatingIfNeeded: buffer & 15), across * bytes, rowStride, sliceStride,
                              level.rowStride, level.surfaceStride, p.layout.arrayStride], atMost: min(bytes, 16))
        var j = CopyJob(src: toImage ? buffer : image, dst: toImage ? image : buffer, unit: unit, srcUnitStride: unit,
                        rowUnits: across * bytes / unit, rows: down)
        j.slices = depth
        if toImage {
          j.dstTile = at.tile
          j.dstOrigin = at.origin
        } else {
          j.srcTile = at.tile
          j.srcOrigin = at.origin
        }
        j.layers = Int(r.subresource.layerCount)
        let imageStrides = (level.rowStride, level.surfaceStride, p.layout.arrayStride)
        let bufferStrides = (rowStride, sliceStride, depth * sliceStride)
        let (s, d) = toImage ? (bufferStrides, imageStrides) : (imageStrides, bufferStrides)
        (j.srcRowStride, j.srcSliceStride, j.srcLayerStride) = s
        (j.dstRowStride, j.dstSliceStride, j.dstLayerStride) = d
        jobs.append(j)
      }
    }
    return jobs
  }

  // MARK: Image to image

  /// Each region and aspect: rows of the source's blocks. A volume's slices pair with the other image's slices, or with its
  /// layers where only one of the two is a volume; a multisampled image's sample planes are copied each to its own.
  func imageCopyJobs(_ a: ImageRecord, _ b: ImageRecord, _ regions: [ImageCopyRegion]) -> [CopyJob] {
    var jobs: [CopyJob] = []
    let srcVolume = a.descriptor.dimension == .d3, dstVolume = b.descriptor.dimension == .d3
    for r in regions {
      for aspect in singleAspects(r.srcSubresource.aspects) {
        guard let sp = plane(a, aspect), let dp = plane(b, aspect) else { continue }
        let bw = sp.texel.blockWidth, bh = sp.texel.blockHeight, bytes = sp.texel.bytesPerTexel
        let across = (Int(r.extent.width) + bw - 1) / bw
        let down = (Int(r.extent.height) + bh - 1) / bh
        let smip = Int(r.srcSubresource.mip), dmip = Int(r.dstSubresource.mip)
        let sl = sp.layout.levels[smip], dl = dp.layout.levels[dmip]
        let s = side(a, sp, mip: smip, layer: Int(r.srcSubresource.baseLayer), x: Int(r.srcOffset.x), y: Int(r.srcOffset.y),
                     z: Int(r.srcOffset.z))
        let d = side(b, dp, mip: dmip, layer: Int(r.dstSubresource.baseLayer), x: Int(r.dstOffset.x), y: Int(r.dstOffset.y),
                     z: Int(r.dstOffset.z))
        let src = s.address, dst = d.address
        let unit = Self.unit([Int(truncatingIfNeeded: src & 15), Int(truncatingIfNeeded: dst & 15), across * bytes, sl.rowStride, dl.rowStride],
                             atMost: min(bytes, 16))
        var j = CopyJob(src: src, dst: dst, unit: unit, srcUnitStride: unit, rowUnits: across * bytes / unit, rows: down,
                        srcRowStride: sl.rowStride, dstRowStride: dl.rowStride)
        (j.srcTile, j.srcOrigin, j.dstTile, j.dstOrigin) = (s.tile, s.origin, d.tile, d.origin)
        if srcVolume || dstVolume {
          // The slices of the volume (or volumes), and the layers of the other image.
          j.slices = Int(srcVolume ? r.extent.depth : r.srcSubresource.layerCount)
          j.srcSliceStride = srcVolume ? sl.surfaceStride : sp.layout.arrayStride
          j.dstSliceStride = dstVolume ? dl.surfaceStride : dp.layout.arrayStride
        } else {
          j.slices = min(sl.samples, dl.samples)
          j.srcSliceStride = sl.surfaceStride
          j.dstSliceStride = dl.surfaceStride
          j.layers = Int(r.srcSubresource.layerCount)
          j.srcLayerStride = sp.layout.arrayStride
          j.dstLayerStride = dp.layout.arrayStride
        }
        jobs.append(j)
      }
    }
    return jobs
  }

  // MARK: Resolves

  /// Each region: every byte of the destination's texels the mean of the source's samples' bytes, rounded to nearest; the formats
  /// a multisampled image has here are 8-bit normalized, whose bytes the tile's writeback averages as they are stored (an sRGB
  /// format's encoded bytes, valhall 08 section 8.3.2).
  func resolveJobs(_ a: ImageRecord, _ b: ImageRecord, _ regions: [ImageCopyRegion]) -> [CopyJob] {
    guard let sp = plane(a, .color), let dp = plane(b, .color) else { return [] }
    var jobs: [CopyJob] = []
    let bytes = sp.texel.bytesPerTexel
    for r in regions {
      let smip = Int(r.srcSubresource.mip), dmip = Int(r.dstSubresource.mip)
      let sl = sp.layout.levels[smip], dl = dp.layout.levels[dmip]
      let d = side(b, dp, mip: dmip, layer: Int(r.dstSubresource.baseLayer), x: Int(r.dstOffset.x), y: Int(r.dstOffset.y))
      var j = CopyJob(
        src: texelAddress(a, sp, mip: smip, layer: Int(r.srcSubresource.baseLayer), x: Int(r.srcOffset.x), y: Int(r.srcOffset.y)),
        dst: d.address,
        unit: 1, srcUnitStride: 1, rowUnits: Int(r.extent.width) * bytes, rows: Int(r.extent.height), srcRowStride: sl.rowStride,
        dstRowStride: dl.rowStride)
      j.layers = Int(r.srcSubresource.layerCount)
      j.srcLayerStride = sp.layout.arrayStride
      j.dstLayerStride = dp.layout.arrayStride
      j.samples = sl.samples
      j.sampleStride = sl.surfaceStride
      j.dstTile = d.tile
      j.dstOrigin = d.origin
      jobs.append(j)
    }
    return jobs
  }

  // MARK: Clears

  /// Each level of each range of the plane: every block of every slice and sample plane of its layers, the texel at `pattern`.
  func clearJobs(_ i: ImageRecord, _ p: AspectPlane, pattern: UInt64, _ ranges: [ImageSubresourceRange]) -> [CopyJob] {
    var jobs: [CopyJob] = []
    let bytes = p.texel.bytesPerTexel
    for range in ranges {
      for mip in Int(range.baseMip)..<Int(range.baseMip + range.mipCount) {
        let level = p.layout.levels[mip]
        var j = CopyJob(src: pattern, dst: texelAddress(i, p, mip: mip, layer: Int(range.baseLayer)), unit: bytes, srcUnitStride: 0,
                        rowUnits: (level.width + p.texel.blockWidth - 1) / p.texel.blockWidth,
                        rows: (level.height + p.texel.blockHeight - 1) / p.texel.blockHeight, dstRowStride: level.rowStride)
        j.slices = level.depth * level.samples
        j.dstSliceStride = level.surfaceStride
        j.dstTile = Self.tileWord(p)
        j.layers = Int(range.layerCount)
        j.dstLayerStride = p.layout.arrayStride
        jobs.append(j)
      }
    }
    return jobs
  }

  /// The bytes of one texel of a colour format holding the clear value, as the format stores it (16 bytes at least).
  static func clearTexel(_ f: PixelFormat, _ bytes: Int, _ color: ClearColor) -> [UInt8] {
    var texel = [UInt8](repeating: 0, count: max(bytes, 16))
    texel.withUnsafeMutableBytes { buffer in
      let base = unsafe buffer.baseAddress!
      switch color {
      case .float(let r, let g, let b, let a):
        if TexelCodec.handles(f) { unsafe TexelCodec.encode(f, [r, g, b, a], to: base) }
      case .uint(let r, let g, let b, let a):
        if let c = TexelCodec.channels(f) {
          let raw = [r, g, b, a]
          for k in 0..<c.count { unsafe TexelCodec.store(base, k * c.bits / 8, bits: c.bits, raw[k]) }
        }
      case .sint(let r, let g, let b, let a):
        if let c = TexelCodec.channels(f) {
          let raw = [UInt32(bitPattern: r), UInt32(bitPattern: g), UInt32(bitPattern: b), UInt32(bitPattern: a)]
          for k in 0..<c.count { unsafe TexelCodec.store(base, k * c.bits / 8, bits: c.bits, raw[k]) }
        }
      }
    }
    return Array(texel[0..<bytes])
  }

  /// The bytes of one texel of a depth or stencil plane holding the value.
  static func depthStencilTexel(_ f: PixelFormat, _ aspect: ImageAspects, depth: Float, stencil: UInt32) -> [UInt8] {
    if aspect == .stencil { return [UInt8(truncatingIfNeeded: stencil)] }
    let word: UInt32
    switch f {
    case .depth16:
      let v = UInt16(min(max(depth, 0), 1) * 65535 + 0.5)
      return [UInt8(v & 255), UInt8(v >> 8)]
    case .depth32f, .depth32fstencil8: word = depth.bitPattern
    // 24 bits: in double precision, where 1.0 makes 0xFFFFFF (a float's 16777215.5 rounds to 2^24).
    default: word = UInt32(Double(min(max(depth, 0), 1)) * 16_777_215 + 0.5)
    }
    return [UInt8(word & 255), UInt8((word >> 8) & 255), UInt8((word >> 16) & 255), UInt8(word >> 24)]
  }

  // MARK: Blits

  /// The jobs of a blit: of one format with the nearest filter (depth and stencil always), a raw move of the nearest texel; any
  /// other, a read of the source by the texture unit and a store in the destination's format (with the texture it reads).
  func blitJobs(_ a: ImageRecord, _ b: ImageRecord, _ regions: [ImageBlitRegion], _ filter: SamplerFilter)
    -> (raw: [BlitJob], sampled: [(job: BlitJob, texture: [UInt32] , planes: [PlaneDescriptor])])
  {
    var raw: [BlitJob] = []
    var sampled: [(job: BlitJob, texture: [UInt32], planes: [PlaneDescriptor])] = []
    let sf = a.descriptor.format, df = b.descriptor.format
    for r in regions {
      for aspect in singleAspects(r.srcSubresource.aspects) {
        guard let sp = plane(a, aspect), let dp = plane(b, aspect) else { continue }
        let smip = Int(r.srcSubresource.mip), dmip = Int(r.dstSubresource.mip)
        let sl = sp.layout.levels[smip], dl = dp.layout.levels[dmip]
        let dx0 = min(r.dstMin.x, r.dstMax.x), dx1 = max(r.dstMin.x, r.dstMax.x)
        let dy0 = min(r.dstMin.y, r.dstMax.y), dy1 = max(r.dstMin.y, r.dstMax.y)
        let dz0 = min(r.dstMin.z, r.dstMax.z), dz1 = max(r.dstMin.z, r.dstMax.z)
        var flips: UInt32 = 0
        if r.dstMax.x < r.dstMin.x { flips |= 1 }
        if r.dstMax.y < r.dstMin.y { flips |= 2 }
        if r.dstMax.z < r.dstMin.z { flips |= 4 }
        var j = BlitJob(
          dst: texelAddress(b, dp, mip: dmip, layer: Int(r.dstSubresource.baseLayer)), bytes: dp.texel.bytesPerTexel,
          dstRowStride: dl.rowStride, dstSliceStride: dl.surfaceStride, dstLayerStride: dp.layout.arrayStride, dx: Int(dx0), dy: Int(dy0),
          dz: Int(dz0), w: Int(dx1 - dx0), h: Int(dy1 - dy0), d: max(Int(dz1 - dz0), 1), layers: Int(r.dstSubresource.layerCount),
          sx: Float(r.srcMin.x), sy: Float(r.srcMin.y), sz: Float(r.srcMin.z), sw: Float(r.srcMax.x - r.srcMin.x),
          sh: Float(r.srcMax.y - r.srcMin.y), sd: Float(r.srcMax.z - r.srcMin.z), flips: flips, srcWidth: sl.width, srcHeight: sl.height,
          srcDepth: sl.depth)
        j.dstTile = Self.tileWord(dp)
        if aspect != .color || (sf == df && filter == .nearest) || !TexelCodec.handles(df) {
          j.src = texelAddress(a, sp, mip: smip, layer: Int(r.srcSubresource.baseLayer))
          j.srcRowStride = sl.rowStride
          j.srcSliceStride = sl.surfaceStride
          j.srcTile = Self.tileWord(sp)
          j.srcLayerStride = sp.layout.arrayStride
          raw.append(j)
          continue
        }
        // The source as a texture of its level: a volume a 3D texture where floats are filtered; any other, and an integer
        // volume (fetched, never filtered), an array of its layers or slices.
        let volume = a.descriptor.dimension == .d3
        let integer = sf.channelClass != .float
        j.kind = integer ? (sf.channelClass == .uint ? 2 : 3) : (volume ? 1 : 0)
        j.sampler = filter == .linear && !integer ? 1 : 0
        j.format = Self.blitFormat(df)
        let base = a.region.address + UInt64(sp.offset)
        var planes: [PlaneDescriptor] = []
        var texture: TextureDescriptor
        if volume && !integer {
          planes = sp.layout.planes(base: base, levels: smip..<(smip + 1), layers: 0..<1)
          texture = TextureDescriptor(dimension: .d3, format: sp.layout.format, width: sl.width, height: sl.height, layout: sp.layout.kind,
                                      depth: sl.depth, surfaces: 0)
        } else if volume {
          for z in 0..<sl.depth {
            planes.append(PlaneDescriptor(address: base + UInt64(sl.offset + z * sl.surfaceStride), size: UInt64(sl.surfaceStride),
                                          rowStride: sl.rowStride, width: sl.width, height: sl.height, kind: sp.layout.kind,
                                          format: sp.layout.format))
          }
          texture = TextureDescriptor(format: sp.layout.format, width: sl.width, height: sl.height, layout: sp.layout.kind, layers: sl.depth,
                                      surfaces: 0)
        } else {
          let first = Int(r.srcSubresource.baseLayer)
          planes = sp.layout.planes(base: base, levels: smip..<(smip + 1), layers: first..<(first + Int(r.srcSubresource.layerCount)))
          texture = TextureDescriptor(format: sp.layout.format, width: sl.width, height: sl.height, layout: sp.layout.kind,
                                      layers: planes.count, surfaces: 0)
        }
        texture.surfaces = 0
        // The texture's words are made once its planes' address is known (blitSteps); here, its shape.
        let words = (try? texture.words()) ?? []
        sampled.append((j, words, planes))
      }
    }
    return (raw, sampled.map { ($0.job, $0.texture, $0.planes) })
  }

  /// The `blit` kernel's word for how the destination stores a texel (blit.comp's header).
  static func blitFormat(_ f: PixelFormat) -> UInt32 {
    switch f {
    case .rgb10a2unorm: return 8
    case .rg11b10float: return 9
    case .rgb9e5: return 10
    default: break
    }
    guard let c = TexelCodec.channels(f) else { return 0 }
    let type: UInt32
    switch c.type {
    case .unorm: type = 0
    case .snorm: type = 1
    case .uint: type = 2
    case .sint: type = 3
    case .float, .ufloat: type = 4
    case .srgb: type = 5
    }
    return type | UInt32(c.count) << 4 | UInt32(c.bits) << 8 | (c.swapRB ? 1 << 16 : 0)
  }

  /// A dispatch of a blit kernel over `jobs`; for `blit`, with a heap of its own: the nearest and the linear sampler (entries 0
  /// and 1), each job's texture (from entry 2), and the textures' planes after the table.
  func blitSteps(_ all: [BlitJob], kernel: TransferKernel, textures: [(words: [UInt32], planes: [PlaneDescriptor])],
                 held: inout [Region]) throws(GPUError) -> [Step] {
    guard !all.isEmpty else { return [] }
    var heap: (address: UInt64, bytes: Int)?
    if kernel == .blit {
      let entries = 2 + all.count
      let tableBytes = entries * 32
      var planeCount = 0
      for t in textures { planeCount += t.planes.count }
      let region = try makeRegion(tableBytes + planeCount * PlaneDescriptor.size)
      held.append(region)
      do throws(DescriptorError) {
        store(try SamplerWords(minFilter: .nearest, magFilter: .nearest).words(), in: region, at: 0)
        store(try SamplerWords(minFilter: .linear, magFilter: .linear).words(), in: region, at: 32)
        var at = tableBytes
        for (n, t) in textures.enumerated() {
          var words = t.words
          let surfaces = region.address + UInt64(at)
          words[4] = UInt32(truncatingIfNeeded: surfaces)
          words[5] = UInt32(truncatingIfNeeded: surfaces >> 32)
          store(words, in: region, at: (2 + n) * 32)
          for p in t.planes {
            store(try p.words(), in: region, at: at)
            at += PlaneDescriptor.size
          }
        }
      } catch { throw .unsupported("the texture unit can't describe a blit's source") }
      heap = (region.address, tableBytes)
    }
    var z = 0
    var x = 0
    var y = 0
    var words: [UInt32] = []
    var table: [UInt32] = []
    for (n, j) in all.enumerated() {
      let span = j.d * j.layers
      guard j.w > 0, j.h > 0, span > 0 else { continue }
      words += [
        UInt32(truncatingIfNeeded: j.src), UInt32(truncatingIfNeeded: j.src >> 32), UInt32(truncatingIfNeeded: j.dst),
        UInt32(truncatingIfNeeded: j.dst >> 32), UInt32(j.bytes), UInt32(j.srcRowStride), UInt32(j.srcSliceStride), UInt32(j.srcLayerStride),
        UInt32(j.dstRowStride), UInt32(j.dstSliceStride), UInt32(j.dstLayerStride), UInt32(j.dx), UInt32(j.dy), UInt32(j.dz), UInt32(j.w),
        UInt32(j.h), UInt32(j.d), j.sx.bitPattern, j.sy.bitPattern, j.sz.bitPattern, j.sw.bitPattern, j.sh.bitPattern, j.sd.bitPattern,
        j.flips, UInt32(j.srcWidth), UInt32(j.srcHeight), UInt32(j.srcDepth), UInt32(z), UInt32(kernel == .blit ? n : 0),
        UInt32(j.sampler), j.format, j.kind, j.srcTile, j.dstTile,
      ]
      for _ in 0..<span { table.append(UInt32(words.count / BlitJob.words - 1)) }
      z += span
      x = max(x, (j.w + 7) / 8)
      y = max(y, (j.h + 7) / 8)
    }
    guard z > 0 else { return [] }
    return [try kernelStep(kernel, jobs: words, count: words.count / BlitJob.words, table: table, grid: Dim3(UInt32(x), UInt32(y), UInt32(z)),
                           heap: heap, held: &held)]
  }
}
