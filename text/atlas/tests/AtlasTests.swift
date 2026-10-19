// SPDX-License-Identifier: BSD-3-Clause

// The atlas and the glyph cache (M6h): random images packed until the
// atlas fills, each found again by its key, none overlapping another or
// the edge, each one's bytes as written; the atlas cleared when full (its
// generation moving on); the dirty rectangle covering every change; and
// the cache's entries the rasterizer's and generator's own output.

import FoundationEssentials
import GlyphAtlas
import MSDF
import OpenType
import Raster
import Testing

let repository: String = {
  var dir = #filePath
  for _ in 0..<4 { dir = String(dir[..<dir.lastIndex(of: "/")!]) }  // text/atlas/tests/AtlasTests.swift
  return dir
}()

func readFile(_ path: String) -> [UInt8]? {
  guard let d = try? Data(contentsOf: URL(filePath: path)) else { return nil }
  return [UInt8](d)
}

@Test func packingKeepsEveryImage() {
  var rng = SystemRandomNumberGenerator()
  var atlas = Atlas(width: 256, height: 256, bytesPerPixel: 2)
  var placed: [(GlyphKey, AtlasRegion, UInt8)] = []
  var dirty: (x: Int, y: Int, width: Int, height: Int)?
  for n in 0..<5000 {
    let w = Int.random(in: 0...24, using: &rng), h = Int.random(in: 0...24, using: &rng)
    let key = GlyphKey(font: 1, glyph: UInt32(n), size: 640)
    let fill = UInt8(truncatingIfNeeded: n * 7 + 1)
    let generation = atlas.generation
    guard let r = atlas.add(key, width: w, height: h, left: n % 5 - 2, top: n % 7, rows: { _, pixels, at in
      for i in 0..<w * 2 { pixels[at + i] = fill }
    }) else {
      Issue.record("\(w)x\(h) didn't fit")
      continue
    }
    if atlas.generation != generation {
      // Cleared to make room: what was there is gone.
      #expect(placed.allSatisfy { atlas.find($0.0) == nil })
      #expect(atlas.count == 1)
      placed.removeAll()
    }
    #expect(Int(r.width) == w && Int(r.height) == h && Int(r.x) + w <= 256 && Int(r.y) + h <= 256)
    placed.append((key, r, fill))
    if n % 97 == 0 { dirty = atlas.takeDirty() }
    // Every entry still there, found, and untouched.
    if n % 50 == 0 {
      for (k, region, f) in placed {
        #expect(atlas.find(k) == region)
        for y in 0..<Int(region.height) {
          for x in 0..<Int(region.width) * 2 {
            if atlas.pixels[(Int(region.y) + y) * 512 + Int(region.x) * 2 + x] != f {
              Issue.record("\(k.glyph)'s pixels changed")
              return
            }
          }
        }
      }
      // No two overlap, gaps included.
      let rects = placed.map { (Int($0.1.x), Int($0.1.y), Int($0.1.width) + 1, Int($0.1.height) + 1) }
      for a in 0..<rects.count {
        for b in a + 1..<rects.count {
          let (ax, ay, aw, ah) = rects[a], (bx, by, bw, bh) = rects[b]
          if ax < bx + bw && bx < ax + aw && ay < by + bh && by < ay + ah && aw > 1 && bw > 1 && ah > 1 && bh > 1 {
            Issue.record("\(a) and \(b) overlap")
            return
          }
        }
      }
    }
  }
  #expect(atlas.generation > 3)  // it filled, several times
  _ = dirty
}

@Test func theDirtyRectangleCoversWhatChanged() {
  var atlas = Atlas(width: 64, height: 64, bytesPerPixel: 1)
  let first = atlas.takeDirty()
  #expect(first == nil)
  let a = atlas.add(GlyphKey(font: 0, glyph: 1, size: 1), width: 10, height: 5, left: 0, top: 0) { _, p, at in p[at] = 1 }!
  let b = atlas.add(GlyphKey(font: 0, glyph: 2, size: 1), width: 4, height: 20, left: 0, top: 0) { _, p, at in p[at] = 1 }!
  let d = atlas.takeDirty()!
  let none = atlas.takeDirty()
  #expect(d.x <= Int(min(a.x, b.x)) && d.y <= Int(min(a.y, b.y)))
  #expect(d.x + d.width >= Int(max(a.x + a.width, b.x + b.width)) && d.y + d.height >= Int(max(a.y + a.height, b.y + b.height)))
  #expect(none == nil)
  let tooWide = atlas.add(GlyphKey(font: 0, glyph: 3, size: 1), width: 64, height: 1, left: 0, top: 0) { _, _, _ in }
  #expect(tooWide == nil)
}

@Test func theCacheHoldsWhatTheRenderersMake() throws {
  let font = try Font(try #require(readFile("\(repository)/data/fonts/noto-sans/NotoSans-Regular.ttf")))
  var cache = GlyphCache(coverageSize: 512, fieldSize: 512)
  var rasterizer = Rasterizer()
  var generator = DistanceFieldGenerator()
  var bitmap = Bitmap()
  var field = DistanceField()
  for scalar in UInt32(0x21)...0x7E {
    let g = font.glyph(for: scalar)
    for quarter in UInt8(0)...3 {
      let made = cache.coverage(font, fontID: 7, glyph: g, pixelsPerEm: 15, quarter: quarter)
      let r = try #require(made)
      let found = cache.coverage(font, fontID: 7, glyph: g, pixelsPerEm: 15, quarter: quarter)
      #expect(found == r)
      rasterizer.render(try font.outline(g), scale: 15 / Double(font.metrics.unitsPerEm), x: Double(quarter) / 4, into: &bitmap)
      #expect(Int(r.width) == bitmap.width && Int(r.height) == bitmap.height && Int(r.left) == bitmap.left
              && Int(r.top) == bitmap.top)
      for y in 0..<bitmap.height {
        for x in 0..<bitmap.width {
          #expect(cache.coverage.pixels[(Int(r.y) + y) * 512 + Int(r.x) + x] == bitmap[x, y])
        }
      }
    }
    let madeField = cache.field(font, fontID: 7, glyph: g)
    let f = try #require(madeField)
    generator.generate(try font.outline(g), scale: 32 / Double(font.metrics.unitsPerEm), into: &field)
    #expect(Int(f.width) == field.width && Int(f.top) == field.top)
    for y in 0..<field.height {
      let row = Array(cache.fields.pixels[((Int(f.y) + y) * 512 + Int(f.x)) * 4..<((Int(f.y) + y) * 512 + Int(f.x) + field.width) * 4])
      #expect(row == Array(field.pixels[y * field.width * 4..<(y + 1) * field.width * 4]))
    }
  }
  #expect(GlyphCache.quarter(10.0) == 0 && GlyphCache.quarter(10.26) == 1 && GlyphCache.quarter(10.5) == 2
          && GlyphCache.quarter(-0.25) == 3 && GlyphCache.quarter(10.9) == 0)
}
