// SPDX-License-Identifier: BSD-3-Clause

// Radharc's GPU renderer (D121, after todhchai's): the scene's display list
// drawn by Loinnir, the CPU renderer's twin (services/radharc/lib's
// `render`). One instanced quad a step (shaders/compose.*): fills; windows'
// images, each a texture uploaded when its window presents; titles' glyphs
// from a font atlas; the cursor and the prompt's seal from their own
// textures; the dimming beneath the prompt. The target is sRGB, so the
// hardware blends in linear light, as Light does (D110). The frame is drawn
// whole, copied into a host-visible buffer, and its damage copied from there
// into Radharc's shadow, which the outputs are copied from as before, so
// `pixel` reads what is shown. v0 waits for the GPU each frame.

import Console
import GPUClient
import Loinnir
import Node
import Radharc
import Sys

public final class GPURenderer {
  let gpu: Loinnir
  let pipeline: Pipeline
  let width: Int, height: Int
  let target: Texture
  let scanout: GPUAllocation
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
  /// The last frame's GPU time, submit to done (ns).
  public private(set) var lastFrame: Int64 = 0
  /// Why the last frame the GPU couldn't draw failed.
  public private(set) var failure: String?

  static let quadBytes = 48, headerBytes = 16
  /// The font atlas: printable ASCII, 8x16 each, in a row.
  static let first: UInt32 = 0x20, glyphs = 95

  /// A renderer for a screen of `width` by `height` on the first GPU in
  /// /dev with Venus, or nil (then the CPU renders).
  public static func open(_ ns: Namespace, width: Int, height: Int) -> GPURenderer? {
    if GPUClient.GPUContext.namespace == nil { GPUClient.GPUContext.namespace = ns }
    return try? GPURenderer(width: width, height: height)
  }

  public init(width: Int, height: Int) throws(LoinnirError) {
    gpu = try Loinnir.headless()
    self.width = width
    self.height = height
    pipeline = try gpu.pipeline(vertex: RadharcShaders.composeVert, fragment: RadharcShaders.composeFrag,
                                target: .bgra8srgb)
    target = try gpu.texture(.bgra8srgb, width: Int32(width), height: Int32(height), renderTarget: true)
    scanout = try gpu.alloc(.readback, bytes: width * height * 4)
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

  /// Draws the scene whole and copies `damage` of it into `shadow`
  /// (0x00RRGGBB, `width` a row); false if the GPU failed (then the CPU
  /// draws).
  public func render(_ scene: Scene, damage: Rect, into shadow: UnsafeMutablePointer<UInt32>) -> Bool {
    do throws(LoinnirError) {
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
      // The quads, into the instance buffer.
      if list.quads.count > capacity {
        while capacity < list.quads.count { capacity *= 2 }
        gpu.free(quads)
        quads = try gpu.alloc(.upload, bytes: Self.headerBytes + capacity * Self.quadBytes)
      }
      let base = unsafe quads.pointer!
      unsafe base.storeBytes(of: Float(width), toByteOffset: 0, as: Float.self)
      unsafe base.storeBytes(of: Float(height), toByteOffset: 4, as: Float.self)
      let out = unsafe (base + Self.headerBytes).bindMemory(to: Quad.self, capacity: list.quads.count)
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
        unsafe out[k] = q
      }
      let count = UInt32(list.quads.count)
      cmd.render(to: .texture(target)) { r in r.draw(pipeline, root: quads.address, vertices: 6, instances: count) }
      cmd.copy(target, to: scanout)
      let submitted = Clock.monotonic()
      try gpu.wait(try gpu.submit(cmd))
      lastFrame = Clock.monotonic() - submitted
      for a in spent { gpu.free(a) }
      spent = []
      // The damage, from the GPU's frame (B, G, R, A bytes: the
      // 0xAARRGGBB word) into the shadow, alpha dropped.
      let from = unsafe UnsafePointer<UInt32>(scanout.pointer!.assumingMemoryBound(to: UInt32.self))
      for y in damage.y..<damage.maxY {
        for x in damage.x..<damage.maxX { unsafe shadow[y * width + x] = from[y * width + x] & 0xFF_FFFF }
      }
      frames += 1
      return true
    } catch {
      failure = describe(error)
      return false
    }
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
