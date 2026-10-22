// SPDX-License-Identifier: BSD-3-Clause

// A window's frame (D107), drawn by UICore's Chrome in the theme's parts
// and faces: the tab with its title and Be's boxes, and the body, with
// the glow's room past it. Drawing costs, so a frame is drawn once for its
// title and focus, small (`FrameTemplate`: around a content no bigger
// than its corners and tab need), and a window of any size has it made
// from that in nine slices: the corners and the tab as drawn, the edges
// their middle row or column repeated. Only the edges are made, the tab's
// strip and bands as deep as a corner reaches; inside is the body's fill,
// under the content, which the scene paints itself.
//
// The template is drawn once over black and once over white, so what the
// frame doesn't cover (beside the tab, rounded or cut corners, a glyph's
// edge, the glow) has its alpha: the one over black is the premultiplied
// light, and the difference in light from the one over white is how much
// shows through.

import Light
import TextLayout
import UICore

/// How far into the body the edges are drawn: past a corner's radius or
/// cut, and a bevel.
let cornerDepth = 16

/// A frame drawn for a title and a focus, at its smallest, premultiplied.
@safe public final class FrameTemplate: @unchecked Sendable {
  public let title: String
  public let focused: Bool
  let width: Int
  let height: Int
  let tabWidth: Int
  let tabHeight: Int
  let border: Int
  let margin: Int
  let closeBox: Rect
  let zoomBox: Rect
  /// The depth of the edges, from the image's side.
  let band: Int
  let pixels: [UInt32]

  public init(_ painter: inout Painter, title: String, focused: Bool) {
    let m = Chrome.windowMetrics(painter, title: title, focused: focused)
    let th = Int(m.tabHeight.rounded(.up)), b = Int(m.border.rounded(.up))
    let t = painter.theme
    let glow = ["window.tab", "window.tab.focused", "window.body", "window.body.focused"].map { t.style($0).glow }.max() ?? 0
    let margin = Int(glow.rounded(.up))
    let tw = Int(m.tabWidth.rounded(.up))
    let band = margin + b + cornerDepth
    // Room for the tab, then edge to repeat, then a corner; below the tab,
    // a row to repeat, then a corner.
    let iw = margin + tw + 2 * band + 1, ih = margin + th + 2 * band + 1
    (self.title, self.focused, width, height, tabWidth, tabHeight, border, self.margin, self.band) =
      (title, focused, iw, ih, tw, th, b, margin, band)
    let box = Int(m.box.rounded())
    closeBox = Rect(x: Int(m.closeBox.x), y: Int(m.closeBox.y), width: box, height: box)
    zoomBox = Rect(x: Int(m.zoomBox.x), y: Int(m.zoomBox.y), width: box, height: box)
    painter.list = DisplayList()
    Chrome.window(&painter, Float(margin), Float(margin), Float(iw - 2 * margin), Float(ih - 2 * margin), title: title,
                  focused: focused)
    pixels = matte(&painter, width: iw, height: ih)
  }
}

/// What `painter` holds, drawn over black and over white, as premultiplied
/// pixels with alpha; the painter is left empty.
func matte(_ painter: inout Painter, width: Int, height: Int) -> [UInt32] {
  var black = Canvas(width: width, height: height, color: 0)
  var white = Canvas(width: width, height: height, color: 0xFF_FFFF)
  painter.render(into: &black)
  painter.render(into: &white)
  painter.list = DisplayList()
  var out = [UInt32](repeating: 0, count: width * height)
  for i in 0..<(width * height) {
    let k = black.pixels[i], l = white.pixels[i]
    // How much of the white shows, in light, the most of any channel:
    // what was drawn covers what's left.
    var through: UInt32 = 0
    for shift: UInt32 in [16, 8, 0] {
      let lk = Light.decode(k >> shift), ll = Light.decode(l >> shift)
      through = max(through, ll > lk ? ll - lk : 0)
    }
    let alpha = 255 - min(255, (through * 255 + 32767) / 65535)
    out[i] = alpha << 24 | (alpha == 0 ? 0 : k & 0xFF_FFFF)
  }
  return out
}

/// A window's frame at its size, from its template, and its geometry, in
/// whole pixels.
@safe public final class WindowChrome: @unchecked Sendable {
  /// The image: the frame and its glow's margin on each side.
  public let width: Int
  public let height: Int
  public let tabWidth: Int
  public let tabHeight: Int
  public let border: Int
  /// The room its glow takes past the frame, on each side.
  public let margin: Int
  /// Be's close and zoom boxes in the tab.
  public let closeBox: Rect
  public let zoomBox: Rect
  /// The parts of the image made: the rest is the body's fill.
  public let strips: [Rect]
  public let template: FrameTemplate
  public let contentWidth: Int
  public let contentHeight: Int
  let storage: UnsafeMutablePointer<UInt32>

  public var title: String { template.title }
  public var focused: Bool { template.focused }

  /// The frame around content `cw` by `ch`, from `t`; a window narrower
  /// than its tab, or shorter than its corners, has its tab cut.
  public init(_ t: FrameTemplate, contentWidth cw: Int, contentHeight ch: Int) {
    let w = cw + 2 * t.border, h = ch + t.tabHeight + 2 * t.border
    let iw = w + 2 * t.margin, ih = h + 2 * t.margin
    (width, height, border, margin, template) = (iw, ih, t.border, t.margin, t)
    (tabWidth, tabHeight, closeBox, zoomBox) = (min(t.tabWidth, w), t.tabHeight, t.closeBox, t.zoomBox)
    (contentWidth, contentHeight) = (cw, ch)
    let band = t.band
    let top = Rect(x: 0, y: 0, width: iw, height: min(ih, t.margin + t.tabHeight + band))
    var strips = [top]
    if ih - band > top.maxY {
      let bottom = Rect(x: 0, y: ih - band, width: iw, height: band)
      strips.append(bottom)
      if iw > 2 * band {
        strips.append(Rect(x: 0, y: top.maxY, width: band, height: bottom.y - top.maxY))
        strips.append(Rect(x: iw - band, y: top.maxY, width: band, height: bottom.y - top.maxY))
      } else {
        strips.append(Rect(x: 0, y: top.maxY, width: iw, height: bottom.y - top.maxY))
      }
    } else if ih > top.maxY {
      strips.append(Rect(x: 0, y: top.maxY, width: iw, height: ih - top.maxY))
    }
    self.strips = strips
    unsafe storage = UnsafeMutablePointer<UInt32>.allocate(capacity: max(1, iw * ih))
    unsafe storage.initialize(repeating: 0, count: max(1, iw * ih))
    // Nine slices: a column or row left of (above) the repeated one is the
    // template's own, one right of (below) it the template's as far from
    // its end; between, the repeated one. Narrower than the template, the
    // right part is cut where it meets the left.
    let midX = t.width - band - 1, midY = t.height - band - 1
    func sx(_ x: Int) -> Int { x < midX ? x : x >= iw - band ? x - (iw - t.width) : midX }
    func sy(_ y: Int) -> Int { y < midY ? y : y >= ih - band ? y - (ih - t.height) : midY }
    for s in strips {
      for y in s.y..<s.maxY {
        let ty = min(max(sy(y), 0), t.height - 1)
        for x in s.x..<s.maxX {
          let tx = min(max(sx(x), 0), t.width - 1)
          unsafe storage[y * iw + x] = t.pixels[ty * t.width + tx]
        }
      }
    }
  }

  deinit { unsafe storage.deallocate() }

  /// Its pixels, premultiplied.
  public var pixels: Pixels {
    var p = unsafe Pixels(unsafe: UnsafeRawPointer(storage), width: width, height: height, stride: width)
    p.alpha = .premultiplied
    return p
  }

  /// Pixel `i` of the image (tests).
  public func pixel(_ i: Int) -> UInt32 { unsafe storage[i] }

  /// Whether it was made for this.
  public func fits(title t: String, focused f: Bool, contentWidth cw: Int, contentHeight ch: Int) -> Bool {
    t.utf8.elementsEqual(title.utf8) && f == focused && cw == contentWidth && ch == contentHeight
  }
}
