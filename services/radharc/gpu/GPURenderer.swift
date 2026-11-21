// SPDX-License-Identifier: BSD-3-Clause

// Radharc's GPU renderer (D121, after todhchai's): the scene's display list
// drawn by Loinnir, the CPU renderer's twin (services/radharc/lib's
// `render`). One instanced quad a step (shaders/compose.*): fills; windows'
// images, each a texture uploaded when its window presents; titles' glyphs
// from a font atlas; the cursor and the prompt's seal from their own
// textures; the dimming beneath the prompt. The target is sRGB, so the
// hardware blends in linear light, as Light does (D110); on Mali's it is the
// fixed-function blender's sRGB mode. The frame is drawn whole, copied into a
// host-visible buffer, and its damage copied from there into Radharc's
// shadow, which the outputs are copied from as before (the one way a frame
// reaches the display, on the CPU's path too), so `pixel` reads what is
// shown. v0 waits for the GPU each frame.

import Console
import GPUClient
import Loinnir
import Node
import Radharc
import Sys

public final class GPURenderer {
  let gpu: Loinnir
  let pipeline: Pipeline
  public let width: Int, height: Int
  /// The frame's targets: one, copied out of for the CPU; or, for a display that shows them as they are (`direct`), two,
  /// drawn into in turn and shown, which nothing on the CPU reads or copies.
  let targets: [Texture]
  public let direct: Bool
  var front = 0
  /// The memory the CPU reads a frame from, where it does (the CPU renderer's shadow, `pixel`, the tests).
  let readback: GPUAllocation
  let atlas: Texture
  var cursor: Texture
  var cursorColors: (UInt32, UInt32) = (0, 0)
  let seal: Texture
  var quads: GPUAllocation
  var capacity: Int
  /// Windows' images on the GPU: the texture, its upload buffer, and the
  /// window's presents when it was uploaded.
  var images: [(window: UInt32, image: UInt32, texture: Texture, staging: GPUAllocation, presents: UInt64)] = []
  public private(set) var frames = 0
  /// The last frame's GPU time, submit to done (ns), the copy into host-visible memory included; and where it went:
  /// the uploads and the draw, the copy of the frame into the buffer the CPU reads, and (not in `lastFrame`) the CPU's
  /// copy of the damage from that buffer into the shadow.
  public private(set) var lastFrame: Int64 = 0
  public private(set) var lastDraw: Int64 = 0
  public private(set) var lastReadback: Int64 = 0
  public private(set) var lastShadowCopy: Int64 = 0
  /// Why the last frame the GPU couldn't draw failed.
  public private(set) var failure: String?
  /// The driver under it: "vulkan" (Venus, or a host's) or "mali".
  public var backend: String { gpu.gpu.backend }

  static let quadBytes = 48, headerBytes = 16
  /// The font atlas: printable ASCII, 8x16 each, in a row.
  static let first: UInt32 = 0x20, glyphs = 95

  /// A renderer for a screen of `width` by `height` on the first GPU in
  /// /dev, whichever driver it has (Venus's Vulkan, or a native one's), or nil (then the CPU renders).
  public static func open(_ ns: Namespace, width: Int, height: Int, direct: Bool = false) -> GPURenderer? {
    if GPUClient.GPUContext.namespace == nil { GPUClient.GPUContext.namespace = ns }
    return try? GPURenderer(width: width, height: height, direct: direct)
  }

  /// With `direct`, two targets a display shows as they are (see `exportTarget`), if the driver makes them; else one.
  public init(width: Int, height: Int, direct: Bool = false) throws(LoinnirError) {
    gpu = try Loinnir.headless()
    self.width = width
    self.height = height
    pipeline = try gpu.pipeline(vertex: RadharcShaders.composeVert, fragment: RadharcShaders.composeFrag,
                                target: .bgra8srgb)
    // The target is drawn into and copied out of: no shader reads it, so it takes no heap slot.
    var made: [Texture] = []
    for _ in 0..<(direct ? 2 : 1) {
      made.append(try gpu.texture(.bgra8srgb, width: Int32(width), height: Int32(height), renderTarget: true,
                                  sampled: false, scanout: direct))
    }
    targets = made
    self.direct = direct
    readback = try gpu.alloc(.readback, bytes: width * height * 4)
    capacity = 1024
    quads = try gpu.alloc(.upload, bytes: Self.headerBytes + capacity * Self.quadBytes)

    // The font atlas, from the console's font (an r8 coverage texture).
    let font = Font.spleen8x16
    let atlasWidth = Self.glyphs * 8
    atlas = try gpu.texture(.r8, width: Int32(atlasWidth), height: 16)
    let atlasPixels = try gpu.alloc(.upload, bytes: atlasWidth * 16)
    let ap = unsafe atlasPixels.pointer!.assumingMemoryBound(to: UInt8.self)
    for i in 0..<Self.glyphs {
      guard let g = font.glyph(Self.first + UInt32(i)) else { continue }
      for row in 0..<16 {
        let bits = UInt8(truncatingIfNeeded: font.row(g, row) >> 24)
        for x in 0..<8 { unsafe ap[row * atlasWidth + i * 8 + x] = bits & (0x80 >> UInt8(x)) != 0 ? 255 : 0 }
      }
    }
    // The prompt's seal: its own colours, clear where it has none.
    let r = Scene.sealRadius, side = 2 * r + 1
    seal = try gpu.texture(.bgra8, width: Int32(side), height: Int32(side))
    let sealPixels = try gpu.alloc(.upload, bytes: side * side * 4)
    let sp = unsafe sealPixels.pointer!.assumingMemoryBound(to: UInt32.self)
    for y in 0..<side {
      for x in 0..<side { unsafe sp[y * side + x] = Scene.sealPixel(x - r, y - r).map { 0xFF00_0000 | $0 } ?? 0 }
    }
    let shape = Scene.cursor
    cursor = try gpu.texture(.bgra8, width: Int32(shape.width), height: Int32(shape.height))
    var cmd = try gpu.commands()
    cmd.copy(atlasPixels, to: atlas)
    cmd.copy(sealPixels, to: seal)
    try gpu.wait(try gpu.submit(cmd))
    gpu.free(atlasPixels)
    gpu.free(sealPixels)
  }

  /// Uploads freed once the frame that copies them is done.
  var spent: [GPUAllocation] = []

  /// The cursor in the theme's colours, drawn again when they change.
  func cursorTexture(_ scene: Scene, _ cmd: inout CommandList) throws(LoinnirError) {
    let colors = (scene.decorations.cursorOutline, scene.decorations.cursorFill)
    guard colors != cursorColors else { return }
    cursorColors = colors
    let shape = Scene.cursor
    let pixels = try gpu.alloc(.upload, bytes: shape.width * shape.height * 4)
    let cp = unsafe pixels.pointer!.assumingMemoryBound(to: UInt32.self)
    for i in 0..<shape.width * shape.height {
      unsafe cp[i] = shape.shape[i] == 0 ? 0 : 0xFF00_0000 | (shape.shape[i] == 1 ? colors.0 : colors.1)
    }
    cmd.copy(pixels, to: cursor)
    spent.append(pixels)
  }

  /// A window image's texture, uploaded if its window has presented since.
  func texture(_ scene: Scene, window: UInt32, image: UInt32, _ cmd: inout CommandList) throws(LoinnirError) -> Texture? {
    guard let w = scene.window(window), let pixels = scene.pixels(window: window, image: image) else { return nil }
    var i = images.firstIndex { $0.window == window && $0.image == image }
    if let k = i, images[k].texture.width != Int32(pixels.width) || images[k].texture.height != Int32(pixels.height) {
      gpu.free(images[k].texture)
      gpu.free(images[k].staging)
      images.remove(at: k)
      i = nil
    }
    if i == nil {
      let t = try gpu.texture(.bgra8, width: Int32(pixels.width), height: Int32(pixels.height))
      let s = try gpu.alloc(.upload, bytes: pixels.width * pixels.height * 4)
      images.append((window, image, t, s, UInt64.max))
      i = images.count - 1
    }
    guard let k = i else { return nil }
    // A frame's chrome changes without a present: uploaded each frame.
    if images[k].presents != w.presents || image == Scene.chromeImage {
      let into = unsafe images[k].staging.pointer!
      for y in 0..<pixels.height { unsafe pixels.copyRow(y, into: into + y * pixels.width * 4) }
      cmd.copy(images[k].staging, to: images[k].texture)
      images[k].presents = w.presents
    }
    return images[k].texture
  }

  /// The frame's display list, kept between frames for its capacity, and
  /// its images' heap indices.
  var list = DrawList()
  var heap: [UInt32] = []

  /// Draws the scene whole into `target` and waits for the GPU (`lastDraw`): the uploads of what changed, then one pass
  /// that ends with the GPU's caches cleaned, so the pixels are in memory a display reads.
  func draw(_ scene: Scene, to target: Texture) throws(LoinnirError) {
      scene.displayList(Rect(x: 0, y: 0, width: width, height: height), into: &list)
      var cmd = try gpu.commands()
      try cursorTexture(scene, &cmd)
      // Images gone from the scene go.
      images.removeAll { r in
        let gone = scene.pixels(window: r.window, image: r.image) == nil
        if gone {
          gpu.free(r.texture)
          gpu.free(r.staging)
        }
        return gone
      }
      // The list's images, as heap indices (uploaded if they've changed).
      heap.removeAll(keepingCapacity: true)
      for ref in list.images { heap.append(try texture(scene, window: ref.window, image: ref.image, &cmd)?.index ?? 0) }
      // The quads, into the instance buffer, behind one header, drawn by one draw.
      let per = max(list.quads.count, 1)
      let runs = max((list.quads.count + per - 1) / per, 1)
      let stride = Self.headerBytes + per * Self.quadBytes
      if list.quads.count > capacity || quads.size < runs * stride {
        while capacity < list.quads.count { capacity *= 2 }
        gpu.free(quads)
        quads = try gpu.alloc(.upload, bytes: max(Self.headerBytes + capacity * Self.quadBytes, runs * stride))
      }
      let base = unsafe quads.pointer!
      for run in 0..<runs {
        unsafe base.storeBytes(of: Float(width), toByteOffset: run * stride, as: Float.self)
        unsafe base.storeBytes(of: Float(height), toByteOffset: run * stride + 4, as: Float.self)
      }
      let last = Self.first + UInt32(Self.glyphs)
      for k in list.quads.indices {
        var q = list.quads[k]
        switch q.kind {
        case Quad.image: q.texture = heap[Int(q.texture)]
        case Quad.glyph:
          let index = q.texture >= Self.first && q.texture < last ? q.texture - Self.first : 0x3F - Self.first
          q.sx += Int32(index) * 8
          q.texture = atlas.index
        case Quad.cursor: q.texture = cursor.index
        case Quad.seal:
          q.sx += Int32(Scene.sealRadius)
          q.sy += Int32(Scene.sealRadius)
          q.texture = seal.index
        default: break
        }
        unsafe (base + (k / per) * stride + Self.headerBytes + (k % per) * Self.quadBytes)
          .storeBytes(of: q, as: Quad.self)
      }
      let count = UInt32(list.quads.count)
      // Cleared first (a tiler needs to know before the pass begins; the desk's fill covers it all anyway).
      cmd.render(to: .texture(target), clear: (0, 0, 0, 1)) { r in
        for run in 0..<runs {
          r.draw(pipeline, root: quads.address + UInt64(run * stride), vertices: 6,
                 instances: UInt32(min(per, Int(count) - run * per)))
        }
      }
      let submitted = Clock.monotonic()
      try gpu.wait(try gpu.submit(cmd))
      lastDraw = Clock.monotonic() - submitted
      for a in spent { gpu.free(a) }
      spent = []
  }

  /// Draws the scene whole and copies `damage` of it into `shadow`
  /// (0x00RRGGBB, `width` a row), the CPU's copy; false if the GPU failed (then the CPU
  /// draws).
  public func render(_ scene: Scene, damage: Rect, into shadow: UnsafeMutablePointer<UInt32>) -> Bool {
    do throws(LoinnirError) {
      try draw(scene, to: targets[0])
      front = 0
      lastReadback = 0
      lastShadowCopy = 0
      try unsafe readFront(damage, into: shadow)
      lastFrame = lastDraw + lastReadback
      frames += 1
      return true
    } catch {
      failure = describe(error)
      return false
    }
  }

  /// Draws the scene whole into the target not shown, for a display that shows the targets as they are, and gives its
  /// index: nothing is copied, nothing on the CPU reads a pixel. Nil if the GPU failed.
  public func renderDirect(_ scene: Scene) -> Int? {
    guard direct else { return nil }
    let into = 1 - front
    do throws(LoinnirError) {
      try draw(scene, to: targets[into])
      front = into
      lastFrame = lastDraw
      lastReadback = 0
      lastShadowCopy = 0
      frames += 1
      return into
    } catch {
      failure = describe(error)
      return nil
    }
  }

  /// A new handle to target `i`'s VMO, for the display to attach: nil where the driver can't share it as it is (the
  /// rows are not `width * 4` bytes), or this renderer is not `direct`.
  public func exportTarget(_ i: Int) -> Handle? {
    guard direct, i >= 0, i < targets.count else { return nil }
    return gpu.exportVMO(targets[i])
  }

  /// The frame last drawn, copied by the GPU into the memory the CPU reads (`lastReadback`) and from there, `damage` of
  /// it, into `shadow` (`lastShadowCopy`): on the CPU renderer's path, and when something wants a pixel of a frame that
  /// is shown as it is.
  public func readFront(_ damage: Rect, into shadow: UnsafeMutablePointer<UInt32>) throws(LoinnirError) {
    let start = Clock.monotonic()
    var back = try gpu.commands()
    back.copy(targets[front], to: readback)
    try gpu.wait(try gpu.submit(back))
    let read = Clock.monotonic()
    lastReadback = read - start
    // The damage, from the GPU's frame (B, G, R, A bytes: the 0xAARRGGBB word) into the shadow, alpha dropped.
    let from = unsafe UnsafePointer<UInt32>(readback.pointer!.assumingMemoryBound(to: UInt32.self))
    for y in damage.y..<damage.maxY {
      for x in damage.x..<damage.maxX { unsafe shadow[y * width + x] = from[y * width + x] & 0xFF_FFFF }
    }
    lastShadowCopy = Clock.monotonic() - read
  }
}

/// A Loinnir error in words (Embedded Swift prints no enums).
func describe(_ e: LoinnirError) -> String {
  switch e {
  case .vulkan(.noLoader): return "no Vulkan loader"
  case .vulkan(.missing(let name)): return "no " + name
  case .vulkan(.failed(let call, let result)): return call + " failed: \(result.rawValue)"
  case .window(let why): return "the window: " + why
  case .unsupported(let why): return why
  }
}
