// SPDX-License-Identifier: BSD-3-Clause

// Colour images (M6i part 5): pictures (a decoded PNG or JPEG's pixels,
// which the program gives: hosted through C0's decoders, natively through
// the image translator) and icons, each drawn into a colour atlas at the
// size it's shown in pixels, so a quad puts it on screen texel for pixel
// (a picture resampled once: area averaging down, bilinear up, in
// premultiplied alpha; an icon rendered at that size). The atlas is the
// glyph cache's kind, four bytes a texel (straight RGBA); when it fills it
// is cleared, and what's drawn next is rendered again.

import GlyphAtlas
import Raster

public struct ImageCache: Sendable {
  public var atlas: Atlas
  /// The pictures given, by id.
  var sources: [(id: UInt32, image: RGBAImage)] = []
  var rasterizer = Rasterizer()
  var bitmap = Bitmap()

  public init(size: Int = 1024) {
    atlas = Atlas(width: size, height: size, bytesPerPixel: 4)
  }

  /// Gives a picture its id (again: replaces it; its renderings go when
  /// the atlas is next cleared, so give a new picture a new id).
  public mutating func add(id: UInt32, _ image: RGBAImage) {
    if let i = sources.firstIndex(where: { $0.id == id }) { sources[i].image = image } else { sources.append((id, image)) }
  }

  /// The integer at or below (tier 0 has no libm's floor).
  static func floor(_ v: Float) -> Float {
    let t = Float(Int(v))
    return t > v ? t - 1 : t
  }

  /// A key for what's drawn: a hash of its description, in the atlas's
  /// key (its font word marks it as a colour image).
  static func key(_ words: [UInt32]) -> GlyphKey {
    var h: UInt64 = 0xCBF2_9CE4_8422_2325
    for w in words {
      for k in 0..<4 { h = (h ^ UInt64(w >> UInt32(8 * k) & 0xFF)) &* 0x100_0000_01B3 }
    }
    return GlyphKey(font: UInt32(truncatingIfNeeded: h >> 32) | 0x8000_0000, glyph: UInt32(truncatingIfNeeded: h),
                    size: words.count > 2 ? words[2] : 0)
  }

  mutating func place(_ key: GlyphKey, _ image: RGBAImage) -> AtlasRegion? {
    atlas.add(key, width: image.width, height: image.height, left: 0, top: 0) { y, pixels, at in
      for i in 0..<(image.width * 4) { pixels[at + i] = image.pixels[y * image.width * 4 + i] }
    }
  }

  /// An icon at `size` pixels, in the atlas.
  public mutating func icon(_ index: Int, size: Int, colors: IconColors, stroke: Float, glow: Float,
                            glowColor: UInt32) -> AtlasRegion?
  {
    let key = ImageCache.key([1, UInt32(index), UInt32(size), colors.edge, colors.emblem, colors.background,
                              stroke.bitPattern, glow.bitPattern, glowColor])
    if let r = atlas.find(key) { return r }
    let image = IconData.all[index].render(size: size, colors: colors, stroke: stroke, glow: glow,
                                           glowColor: glowColor, rasterizer: &rasterizer, bitmap: &bitmap)
    return place(key, image)
  }

  /// Picture `id` at `width` by `height` pixels, in the atlas.
  public mutating func picture(_ id: UInt32, width: Int, height: Int) -> AtlasRegion? {
    let key = ImageCache.key([2, id, UInt32(width), UInt32(height)])
    if let r = atlas.find(key) { return r }
    guard width > 0, height > 0, let source = sources.first(where: { $0.id == id })?.image else { return nil }
    return place(key, ImageCache.resample(source, width: width, height: height))
  }

  /// A picture at another size: each pixel the average of the source's
  /// area under it (smaller), or bilinear between the source's pixels
  /// (larger), in premultiplied alpha.
  public static func resample(_ s: RGBAImage, width: Int, height: Int) -> RGBAImage {
    if s.width == width && s.height == height { return s }
    var out = RGBAImage(width: width, height: height)
    func texel(_ x: Int, _ y: Int) -> (Float, Float, Float, Float) {
      let cx = min(max(x, 0), s.width - 1), cy = min(max(y, 0), s.height - 1)
      let i = (cy * s.width + cx) * 4
      let a = Float(s.pixels[i + 3]) / 255
      return (Float(s.pixels[i]) * a, Float(s.pixels[i + 1]) * a, Float(s.pixels[i + 2]) * a, a)
    }
    let sx = Float(s.width) / Float(width), sy = Float(s.height) / Float(height)
    for y in 0..<height {
      for x in 0..<width {
        var acc: (Float, Float, Float, Float) = (0, 0, 0, 0)
        if sx >= 1 && sy >= 1 {
          // The source's area under this pixel, partial pixels weighted.
          let x0 = Float(x) * sx, x1 = x0 + sx, y0 = Float(y) * sy, y1 = y0 + sy
          var total: Float = 0
          var ty = Int(y0)
          while Float(ty) < y1 && ty < s.height {
            let wy = min(Float(ty + 1), y1) - max(Float(ty), y0)
            var tx = Int(x0)
            while Float(tx) < x1 && tx < s.width {
              let wx = min(Float(tx + 1), x1) - max(Float(tx), x0)
              let t = texel(tx, ty), w = wx * wy
              acc = (acc.0 + t.0 * w, acc.1 + t.1 * w, acc.2 + t.2 * w, acc.3 + t.3 * w)
              total += w
              tx += 1
            }
            ty += 1
          }
          if total > 0 { acc = (acc.0 / total, acc.1 / total, acc.2 / total, acc.3 / total) }
        } else {
          let u = (Float(x) + 0.5) * sx - 0.5, v = (Float(y) + 0.5) * sy - 0.5
          let iu = Int(u + 1) - 1, iv = Int(v + 1) - 1
          let fu = u - Float(iu), fv = v - Float(iv)
          let a = texel(iu, iv), b = texel(iu + 1, iv), c = texel(iu, iv + 1), d = texel(iu + 1, iv + 1)
          func mix(_ p: Float, _ q: Float, _ r: Float, _ t: Float) -> Float {
            (p * (1 - fu) + q * fu) * (1 - fv) + (r * (1 - fu) + t * fu) * fv
          }
          acc = (mix(a.0, b.0, c.0, d.0), mix(a.1, b.1, c.1, d.1), mix(a.2, b.2, c.2, d.2), mix(a.3, b.3, c.3, d.3))
        }
        let i = (y * width + x) * 4
        if acc.3 > 0 {
          out.pixels[i] = UInt8(min(255, acc.0 / acc.3 + 0.5))
          out.pixels[i + 1] = UInt8(min(255, acc.1 / acc.3 + 0.5))
          out.pixels[i + 2] = UInt8(min(255, acc.2 / acc.3 + 0.5))
        }
        out.pixels[i + 3] = UInt8(min(255, acc.3 * 255 + 0.5))
      }
    }
    return out
  }
}

extension Painter {
  /// An icon of the sheet, `size` logical pixels square, its top left at
  /// (x, y): in its kind's colour (and its emblem's), over the desk;
  /// glowing if selected (the storyboard's .35cqw, in
  /// `desktop.icon.selected`'s glow colour; not in the accessible theme). Its strokes are 1 px (the accessible theme's 1.6),
  /// at any size.
  public mutating func icon(_ name: String, _ x: Float, _ y: Float, size: Float, color: UInt32, emblem: UInt32 = 0,
                            selected: Bool = false)
  {
    guard let index = IconData.index(name) else { return }
    let px = Int(size * scale + 0.5)
    guard px > 0 else { return }
    let accessible = theme.textScale > 1
    let glow = selected && !accessible ? Theme.cqw(0.35) * scale : 0
    let colors = IconColors(edge: color & 0xFF_FFFF, emblem: emblem & 0xFF_FFFF, background: theme.color("desk") & 0xFF_FFFF)
    guard let r = images.icon(index, size: px, colors: colors, stroke: (accessible ? 1.6 : 1) * scale, glow: glow,
                              glowColor: theme.style("desktop.icon.selected").glowColor)
    else { return }
    let pad = Float(Int(r.width) - px) / 2
    list.append(UIQuad(x: ImageCache.floor(x * scale) - pad, y: ImageCache.floor(y * scale) - pad,
                       width: Float(r.width), height: Float(r.height), kind: UIQuad.image, fill: 0xFFFF_FFFF,
                       atlasX: r.x, atlasY: r.y, atlasWidth: r.width, atlasHeight: r.height))
  }

  /// Picture `id` (given to `images`) in the rectangle (logical pixels),
  /// at `opacity`.
  public mutating func image(_ id: UInt32, _ x: Float, _ y: Float, _ width: Float, _ height: Float,
                             opacity: Float = 1)
  {
    let w = Int(width * scale + 0.5), h = Int(height * scale + 0.5)
    guard let r = images.picture(id, width: w, height: h) else { return }
    let a = UInt32(min(max(opacity, 0), 1) * 255 + 0.5)
    list.append(UIQuad(x: ImageCache.floor(x * scale), y: ImageCache.floor(y * scale), width: Float(w),
                       height: Float(h), kind: UIQuad.image, fill: a << 24 | 0xFF_FFFF, atlasX: r.x, atlasY: r.y,
                       atlasWidth: r.width, atlasHeight: r.height))
  }
}
