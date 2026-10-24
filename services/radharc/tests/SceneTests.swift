// SPDX-License-Identifier: BSD-3-Clause

// Radharc's scene (M4c): window management as decided (press selects,
// release raises, the tab moves, the grip resizes, edges snap) and
// composing into a buffer.

import Light
import Radharc
import Testing

@Test func openingCascadesFocusesAndConfigures() {
  let s = Scene(width: 800, height: 600)
  let (a, ea) = s.open(title: "a", width: 200, height: 100)
  #expect(ea == [.configure(window: a.id, width: 200, height: 100, seq: 1, focused: true), .focus(window: a.id)])
  let (b, _) = s.open(title: "b", width: 200, height: 100)
  #expect(s.focused == b.id && s.windows.map { $0.id } == [a.id, b.id])
  #expect(b.content.x == a.content.x + 32 && b.content.y == a.content.y + 32)
}

@Test func pressSelectsAndReleaseRaises() {
  let s = Scene(width: 800, height: 600)
  let (a, _) = s.open(title: "a", width: 200, height: 100)
  let (b, _) = s.open(title: "b", width: 200, height: 100)
  // Press in a's visible part: a is focused at once, but not raised...
  _ = s.moveTo(a.content.x + 5, a.content.y + 5)
  #expect(s.button(down: true) == [.focus(window: a.id)])
  #expect(s.windows.last?.id == b.id)
  // ...until the release, with no drag.
  _ = s.button(down: false)
  #expect(s.windows.last?.id == a.id)
  // A drag that starts in a window behind doesn't raise it.
  _ = s.moveTo(b.content.maxX - 5, b.content.maxY - 20)  // b's part not under a
  _ = s.button(down: true)
  _ = s.moveBy(30, 30)
  _ = s.button(down: false)
  #expect(s.focused == b.id && s.windows.last?.id == a.id)
}

@Test func theTabMovesAndEdgesSnap() {
  let s = Scene(width: 800, height: 600)
  let (w, _) = s.open(title: "editor", width: 200, height: 100)
  let tab = w.tab
  _ = s.moveTo(tab.x + 4, tab.y + 4)
  _ = s.button(down: true)
  _ = s.moveBy(100, 50)
  #expect(w.content.x == 140 && w.content.y == 110)
  // Within 12 pixels of the left edge: snapped to it.
  _ = s.moveBy(-130, 0)
  #expect(w.content.x == Scene.border)
  _ = s.button(down: false)
  #expect(s.takeDamage().width > 0)
}

@Test func theGripAsksForANewSize() {
  let s = Scene(width: 800, height: 600)
  let (w, _) = s.open(title: "w", width: 200, height: 100)
  _ = s.moveTo(w.content.maxX - 4, w.content.maxY - 4)
  _ = s.button(down: true)
  let e = s.moveBy(50, 20)
  #expect(e == [.configure(window: w.id, width: 250, height: 120, seq: 2, focused: true)])
  // Until the client draws for it, its old buffer shows at its old size.
  #expect(w.content.width == 200)
  _ = s.button(down: false)
  #expect(w.content.width == 250 && w.content.height == 120)
}

@Test func composingDrawsBackgroundDecorationsLayersAndCursor() {
  let s = Scene(width: 320, height: 240)
  let (w, _) = s.open(title: "t", width: 100, height: 50)
  var pixels = [UInt32](repeating: 0x00FF_0000, count: 20 * 10)
  pixels[0] = 0x0012_3456
  pixels.withUnsafeBytes { p in
    w.images.append((7, Pixels(unsafe: p.baseAddress!, width: 20, height: 10, stride: 20)))
    s.present(w.id, seq: 1, size: (100, 50), layers: [Layer(image: 0, color: 0x0000_FF00, rect: Rect(x: 0, y: 0, width: 100, height: 50)),
                                                     Layer(image: 7, rect: Rect(x: 10, y: 5, width: 20, height: 10))], damage: nil)
    var target = [UInt32](repeating: 0xDEAD, count: 320 * 240)
    _ = s.moveTo(300, 200)
    target.withUnsafeMutableBufferPointer { t in
      s.compose(s.takeDamage(), into: t.baseAddress!, stride: 320) { _ in InlineArray(repeating: 0xFF) }
    }
    #expect(target[0] == s.decorations.desk)
    let c = w.content
    #expect(target[(c.y - 1) * 320 + c.x + 50] == s.decorations.edgeFocused)  // the focused border
    #expect(target[(c.y + 20) * 320 + c.x + 50] == 0x0000_FF00)  // the solid layer
    #expect(target[(c.y + 5) * 320 + c.x + 10] == 0x0012_3456)  // the image's first pixel
    #expect(target[(c.y + 6) * 320 + c.x + 11] == 0x00FF_0000)
    #expect(target[(w.tab.y + 3) * 320 + w.tab.x + Scene.titleInset + 1] == s.decorations.tabInkFocused)  // the title's text, in the focused tab's ink
    #expect(target[201 * 320 + 300] == s.decorations.cursorOutline)  // the cursor's outline
  }
}

@Test func aWindowInsideOneAboveIsHidden() {
  let s = Scene(width: 800, height: 600)
  let (big, _) = s.open(title: "big", width: 600, height: 400)
  let (small, _) = s.open(title: "s", width: 100, height: 50)
  #expect(!s.isHidden(small.id) && !s.isHidden(big.id))
  // Clicked, the big one rises over the small one, which it contains.
  _ = s.moveTo(big.content.x + 400, big.content.y + 300)
  _ = s.button(down: true)
  _ = s.button(down: false)
  #expect(s.isHidden(small.id) && !s.isHidden(big.id))
}

@Test func aFullscreenWindowIsTheScreenUndecorated() {
  let s = Scene(width: 320, height: 240)
  let (other, _) = s.open(title: "other", width: 100, height: 60)
  let (w, _) = s.open(title: "game", width: 100, height: 60)
  let before = w.content
  _ = s.top(other.id)
  let effects = s.setFullscreen(w.id, true) ?? []
  #expect(effects.contains { if case .configure(let id, 320, 240, _, true) = $0 { id == w.id } else { false } })
  #expect(effects.contains(.focus(window: w.id)))
  #expect(w.content == Rect(x: 0, y: 0, width: 320, height: 240) && w.frame == w.content && w.tab.isEmpty && w.grip.isEmpty)
  #expect(s.fullscreenOnTop === w && s.windows.last === w)
  w.layers = [Layer(image: 0, color: 0x00AB_CDEF, rect: Rect(x: 0, y: 0, width: 320, height: 240))]
  var target = [UInt32](repeating: 0xDEAD, count: 320 * 240)
  target.withUnsafeMutableBufferPointer { t in s.compose(s.takeDamage(), into: t.baseAddress!, stride: 320) { _ in InlineArray(repeating: 0xFF) } }
  #expect(target[0] == 0x00AB_CDEF && target[319] == 0x00AB_CDEF)  // no tab, no border: the layer to the corners
  // Covered by another window raised over it, it isn't on top any more.
  _ = s.top(other.id)
  #expect(s.fullscreenOnTop == nil)
  _ = s.top(w.id)
  // Back where it was.
  let back = s.setFullscreen(w.id, false) ?? []
  #expect(w.content == before && !w.fullscreen && !w.tab.isEmpty)
  #expect(back.contains { if case .configure(let id, 100, 60, _, _) = $0 { id == w.id } else { false } })
  #expect(s.setFullscreen(999, true) == nil)
}

// The display list (M5j): what composing draws, in order, as one packed
// batch of quads in the GPU's layout, and the images they draw.
@Test func theDisplayListIsWhatComposingDraws() {
  let s = Scene(width: 320, height: 240)
  let (w, _) = s.open(title: "ab", width: 100, height: 60)
  var pixels = [UInt32](repeating: 0x0011_2233, count: 50 * 20)
  pixels.withUnsafeMutableBufferPointer { p in
    w.images = [(7, Pixels(unsafe: p.baseAddress!, width: 50, height: 20, stride: 50))]
    // A layer bigger than its image: drawn at the image's size, cropped.
    w.layers = [Layer(image: 7, rect: Rect(x: 10, y: 5, width: 80, height: 40))]
    var list = DrawList()
    s.displayList(Rect(x: 0, y: 0, width: 320, height: 240), into: &list)
    // The desk first, where no window's content hides it.
    let desk = list.quads.prefix { $0.kind == Quad.fill && $0.color == s.decorations.desk }.map(\.rect)
    #expect(desk.allSatisfy { $0.intersection(w.content).isEmpty })
    #expect(desk.reduce(0) { $0 + $1.width * $1.height } == 320 * 240 - w.content.width * w.content.height)
    #expect(list.quads.last.map { $0.kind == Quad.cursor && $0.x == 160 && $0.y == 120 } == true)
    #expect(list.quads.filter { $0.kind == Quad.glyph }.map { $0.texture } == [0x61, 0x62])
    #expect(list.images.count == 1 && list.images[0] == (w.id, 7))
    let images = list.quads.filter { $0.kind == Quad.image }
    #expect(images.count == 1 && images[0].texture == 0)
    #expect(images.first?.rect == Rect(x: w.content.x + 10, y: w.content.y + 5, width: 50, height: 20))
    #expect(images.first.map { $0.sx == 0 && $0.sy == 0 } == true)
    // A region over part of the image: its source origin moves with it; and
    // the list is filled again, not added to.
    s.displayList(Rect(x: w.content.x + 20, y: w.content.y + 10, width: 5, height: 5), into: &list)
    let cut = list.quads.filter { $0.kind == Quad.image }
    #expect(cut.count == 1 && cut[0].width == 5 && cut[0].sx == 10 && cut[0].sy == 5)
    // The CPU's renderer of the list is what compose draws.
    s.displayList(Rect(x: 0, y: 0, width: 320, height: 240), into: &list)
    var a = [UInt32](repeating: 0, count: 320 * 240), b = a
    a.withUnsafeMutableBufferPointer { t in s.compose(Rect(x: 0, y: 0, width: 320, height: 240), into: t.baseAddress!, stride: 320) { _ in InlineArray(repeating: 0x81) } }
    b.withUnsafeMutableBufferPointer { t in s.render(list, into: t.baseAddress!, stride: 320) { _ in InlineArray(repeating: 0x81) } }
    #expect(a == b)
  }
}

// What a window's content hides isn't drawn: the ground under an opaque
// layer, a window under another's content, the desk under them all; what
// shows is drawn as before.
// A glyph's quad draws its cell's set bits from where it starts in the
// cell, to its own edge, and nothing else.
@Test func aCutGlyphDrawsItsPartOfTheCell() {
  let s = Scene(width: 32, height: 32)
  var rows = InlineArray<16, UInt8>(repeating: 0)
  for y in 0..<16 { rows[y] = UInt8(truncatingIfNeeded: 0xA5 &* (y + 1)) }
  for (sx, sy, width, height) in [(0, 0, 8, 16), (3, 2, 4, 9), (7, 15, 1, 1), (1, 0, 7, 16)] {
    var list = DrawList()
    list.quads = [Quad(Rect(x: 5, y: 6, width: width, height: height), sx: sx, sy: sy, texture: 0x41, kind: Quad.glyph,
                       color: 0x12_3456)]
    var a = [UInt32](repeating: 0, count: 32 * 32)
    a.withUnsafeMutableBufferPointer { t in s.render(list, into: t.baseAddress!, stride: 32) { _ in rows } }
    for y in 0..<32 {
      for x in 0..<32 {
        let inside = x >= 5 && x < 5 + width && y >= 6 && y < 6 + height
        let set = inside && rows[sy + y - 6] & (0x80 >> UInt8(sx + x - 5)) != 0
        #expect(a[y * 32 + x] == (set ? 0x12_3456 : 0), "\(sx),\(sy): (\(x), \(y))")
      }
    }
  }
}

@Test func whatAContentHidesIsNotDrawn() {
  let s = Scene(width: 320, height: 240)
  var pixels = [UInt32](repeating: 0x0011_2233, count: 100 * 60)
  pixels.withUnsafeMutableBufferPointer { p in
    let (low, _) = s.open(title: "low", width: 100, height: 60)
    let (high, _) = s.open(title: "high", width: 100, height: 60)
    for w in [low, high] {
      w.images = [(1, Pixels(unsafe: p.baseAddress!, width: 100, height: 60, stride: 100))]
      w.layers = [Layer(image: 1, rect: Rect(x: 0, y: 0, width: 100, height: 60))]
    }
    var list = DrawList()
    s.displayList(Rect(x: 0, y: 0, width: 320, height: 240), into: &list)
    // Nothing is filled under either content, and of the low window's
    // image only what the high one leaves is drawn.
    let fills = list.quads.filter { $0.kind == Quad.fill }.map(\.rect)
    #expect(fills.allSatisfy { $0.intersection(low.content).intersection(high.content).isEmpty })
    #expect(fills.allSatisfy { $0.intersection(high.content).isEmpty })
    let images = list.quads.filter { $0.kind == Quad.image }.map(\.rect)
    #expect(images.allSatisfy { $0 == high.content || $0.intersection(high.content).isEmpty })
    #expect(images.reduce(0) { $0 + $1.width * $1.height }
      == 2 * 100 * 60 - low.content.intersection(high.content).width * low.content.intersection(high.content).height)
    // Each pixel is what its topmost window draws there.
    var a = [UInt32](repeating: 0xDEAD_BEEF, count: 320 * 240)
    a.withUnsafeMutableBufferPointer { t in s.render(list, into: t.baseAddress!, stride: 320) { _ in InlineArray(repeating: 0) } }
    let c = low.content
    #expect(a[(c.y + 1) * 320 + c.x + 1] == 0x0011_2233)
    #expect(!a.contains(0xDEAD_BEEF))
  }
}

// A quad is the shader's Quad, byte for byte (shaders/compose.vert: vec4
// rect, ivec4 source, uvec4 color), so a list is copied to the GPU as is.
@Test func aQuadHasTheShadersLayout() {
  #expect(MemoryLayout<Quad>.size == 48 && MemoryLayout<Quad>.stride == 48)
  #expect(MemoryLayout<Quad>.offset(of: \.x) == 0 && MemoryLayout<Quad>.offset(of: \.height) == 12)
  #expect(MemoryLayout<Quad>.offset(of: \.sx) == 16 && MemoryLayout<Quad>.offset(of: \.sy) == 20)
  #expect(MemoryLayout<Quad>.offset(of: \.texture) == 24 && MemoryLayout<Quad>.offset(of: \.kind) == 28)
  #expect(MemoryLayout<Quad>.offset(of: \.color) == 32)
}

// Spatial windows (M6j): a window placed where it was hears where the
// user moves it; the desktop is undecorated, the screen's size, beneath.

@Test func aPlacedWindowHearsWhereItMoves() {
  let s = Scene(width: 800, height: 600)
  let (w, _) = s.open(title: "home", width: 200, height: 100)
  let (other, _) = s.open(title: "other", width: 200, height: 100)
  // Not placed: moving it says nothing.
  #expect(s.move(other.id, x: 300, y: 300) == [])
  #expect(s.place(w.id, x: 420, y: 260) == [.moved(window: w.id, x: 420, y: 260)])
  #expect(w.content.x == 420 && w.content.y == 260 && w.placed)
  // Kept where its tab can be grabbed.
  #expect(s.place(w.id, x: 5000, y: -50) == [.moved(window: w.id, x: 800 - 21, y: 21)])
  _ = s.place(w.id, x: 100, y: 100)
  // The tab dragged: one `moved`, on release.
  _ = s.top(w.id)
  _ = s.moveTo(w.tab.x + 4, w.tab.y + 4)
  _ = s.button(down: true)
  #expect(s.moveBy(40, 30) == [])
  #expect(s.button(down: false) == [.moved(window: w.id, x: 140, y: 130)])
  // The window list's move.
  #expect(s.move(w.id, x: 50, y: 60) == [.moved(window: w.id, x: 50, y: 60)])
  #expect(s.place(999, x: 0, y: 0) == nil && s.move(999, x: 0, y: 0) == nil)
}

@Test func theDesktopIsBeneathEveryWindow() {
  let s = Scene(width: 320, height: 240)
  let (a, _) = s.open(title: "a", width: 100, height: 60)
  let (d, _) = s.open(title: "desktop", width: 100, height: 60)
  let effects = s.setDesktop(d.id, true) ?? []
  #expect(effects.contains { if case .configure(let id, 320, 240, _, _) = $0 { id == d.id } else { false } })
  #expect(d.content == Rect(x: 0, y: 0, width: 320, height: 240) && d.frame == d.content && d.tab.isEmpty)
  #expect(s.windows.first === d && s.windows.last === a && s.focused == a.id)
  // A click on it focuses it but doesn't raise it; a new window opens above.
  _ = s.moveTo(300, 230)
  #expect(s.button(down: true) == [.focus(window: d.id)])
  _ = s.button(down: false)
  #expect(s.windows.first === d && s.focused == d.id)
  _ = s.top(d.id)
  #expect(s.windows.first === d)
  let (b, _) = s.open(title: "b", width: 100, height: 60)
  #expect(s.windows.map { $0.id } == [d.id, a.id, b.id])
  // It doesn't move; its content is drawn to the corners.
  #expect(s.move(d.id, x: 50, y: 50) == [] && d.content.x == 0)
  // Back to a window, on top, where it was.
  let back = s.setDesktop(d.id, false) ?? []
  #expect(back.contains { if case .configure(let id, 100, 60, _, _) = $0 { id == d.id } else { false } })
  #expect(s.windows.last === d && !d.tab.isEmpty)
}

// Views (M6j, view tokens): shown only inside their host, at its area,
// clipped to it; the pointer over one is its own; its host hears it go.

@Test func aViewIsShownInsideItsHost() {
  let s = Scene(width: 320, height: 240)
  let (host, _) = s.open(title: "deskbar", width: 120, height: 60)
  let (v, first) = s.openView(title: "clock", width: 10, height: 10)
  #expect(first.count == 1 && v.isView && s.focused == host.id)
  // Shown nowhere yet: no damage, hidden, not under the pointer.
  _ = s.takeDamage()
  s.present(v.id, seq: 1, size: (10, 10), layers: [Layer(image: 0, color: 0xFF00FF, rect: Rect(x: 0, y: 0, width: 10, height: 10))],
            damage: nil)
  #expect(s.takeDamage().isEmpty && s.isHidden(v.id))
  // Embedded at (100, 10), 40 by 30: configured for that, drawn there.
  let e = s.embed(host: host.id, view: v.id, id: 7, area: Rect(x: 100, y: 10, width: 40, height: 30)) ?? []
  #expect(e.contains { if case .configure(let id, 40, 30, _, _) = $0 { id == v.id } else { false } })
  s.present(v.id, seq: 2, size: (40, 30),
            layers: [Layer(image: 0, color: 0xFF00FF, rect: Rect(x: 0, y: 0, width: 40, height: 30))], damage: nil)
  var list = DrawList()
  s.displayList(Rect(x: 0, y: 0, width: 320, height: 240), into: &list)
  // Clipped to the host's content: 20 of its 40 columns show.
  let at = Rect(x: host.content.x + 100, y: host.content.y + 10, width: 20, height: 30)
  #expect(list.quads.contains { $0.kind == Quad.fill && $0.color == 0xFF00FF && $0.rect == at })
  // The pointer over it is the view's, in its coordinates; keys stay.
  _ = s.moveTo(at.x + 5, at.y + 6)
  let t = s.pointerTarget()
  #expect(t?.window == v.id && t?.x == 5 && t?.y == 6 && s.focused == host.id)
  // It moves with its host.
  _ = s.move(host.id, x: 150, y: 120)
  #expect(s.screenRect(v) == Rect(x: 250, y: 130, width: 20, height: 30))
  // Placed by its embedding's id, without its token: configured again.
  let p = s.placeEmbedding(host: host.id, id: 7, area: Rect(x: 0, y: 0, width: 16, height: 12)) ?? []
  #expect(p.contains { if case .configure(let id, 16, 12, _, _) = $0 { id == v.id } else { false } })
  #expect(s.screenRect(v) == Rect(x: 150, y: 120, width: 16, height: 12))
  #expect(s.placeEmbedding(host: host.id, id: 9, area: Rect(x: 0, y: 0, width: 5, height: 5)) == nil)
  // Gone: its host hears; the host gone, it's shown nowhere.
  let (w, _) = s.openView(title: "other", width: 10, height: 10)
  _ = s.embed(host: host.id, view: w.id, id: 8, area: Rect(x: 0, y: 0, width: 10, height: 10))
  #expect(s.close(v.id).contains(.viewGone(window: host.id, id: 7)))
  _ = s.close(host.id)
  #expect(w.embedding == nil && s.screenRect(w) == nil)
  #expect(s.embed(host: w.id, view: w.id, id: 1, area: Rect(x: 0, y: 0, width: 5, height: 5)) == nil)
}

// Panels (M6j, Deskbar): above every window, raised or new.

@Test func aPanelStaysAboveEveryWindow() {
  let s = Scene(width: 320, height: 240)
  let (a, _) = s.open(title: "a", width: 100, height: 60)
  let (p, _) = s.open(title: "deskbar", width: 80, height: 40)
  #expect(s.setPanel(p.id, true) == [] && p.panel && p.frame == p.content && p.tab.isEmpty)
  let (b, _) = s.open(title: "b", width: 100, height: 60)
  #expect(s.windows.map { $0.id } == [a.id, b.id, p.id])
  _ = s.top(a.id)
  #expect(s.windows.last === p && s.windows[1] === a)
  _ = s.setPanel(p.id, false)
  _ = s.top(b.id)
  #expect(s.windows.last === b && !p.panel)
}

/// Be's close box asks the client; the zoom box zooms and back (M6l).
@Test func theTabsBoxesCloseAndZoom() {
  let s = Scene(width: 800, height: 600)
  let (w, _) = s.open(title: "notes", width: 300, height: 200)
  let before = w.content
  #expect(w.closeBox.x > w.tab.x && w.zoomBox.maxX < w.tab.maxX && w.closeBox.maxX < w.zoomBox.x)
  func click(_ r: Rect) -> [SceneEffect] {
    _ = s.moveTo(r.x + r.width / 2, r.y + r.height / 2)
    _ = s.button(down: true)
    return s.button(down: false)
  }
  #expect(click(w.closeBox) == [.closeRequested(window: w.id)])
  #expect(s.window(w.id) != nil)  // the client decides
  // Pressed and dragged off: nothing.
  _ = s.moveTo(w.closeBox.x + 2, w.closeBox.y + 2)
  _ = s.button(down: true)
  _ = s.moveBy(40, 40)
  #expect(s.button(down: false).isEmpty)
  _ = s.moveTo(w.zoomBox.x + 2, w.zoomBox.y + 2)
  _ = s.button(down: true)
  let zoomed = s.button(down: false)
  #expect(w.zoomed && w.content.width == 798 && w.content.y == Scene.tabHeight + Scene.border)
  #expect(zoomed.contains { if case .configure(_, 798, 600 - Scene.tabHeight - 2 * Scene.border, _, _) = $0 { true } else { false } })
  _ = s.zoom(w.id)
  #expect(!w.zoomed && w.content == before)
}

/// A hidden window isn't drawn, hit or focused; `show` and `top` bring it
/// back (M6l: Deskbar's Hide all, Show all).
@Test func aHiddenWindowIsGoneUntilShown() {
  let s = Scene(width: 800, height: 600)
  let (a, _) = s.open(title: "a", width: 200, height: 100)
  let (b, _) = s.open(title: "b", width: 200, height: 100)
  #expect(s.hide(b.id) == [.focus(window: a.id)])
  #expect(b.hidden && s.isHidden(b.id))
  _ = s.moveTo(b.content.maxX - 3, b.content.maxY - 20)  // b's part not over a
  #expect(s.pointerTarget() == nil)
  var list = DrawList()
  s.displayList(Rect(x: 0, y: 0, width: 800, height: 600), into: &list)
  #expect(!list.quads.contains { $0.kind == Quad.fill && $0.color == s.decorations.tabFocused && Int($0.x) == b.tab.x && Int($0.y) == b.tab.y })
  #expect(s.top(b.id) == [.focus(window: b.id)])
  #expect(!b.hidden && s.windows.last?.id == b.id)
  _ = s.hide(b.id)
  #expect(s.show(b.id) == [.focus(window: b.id)] && !b.hidden)
  // The desktop and panels don't hide.
  #expect(s.hide(999) == nil)
}

/// A popup (M6m: a menu's own surface) is above every window, panels too;
/// follows its owner; hides with it; a press in it focuses the owner; it
/// goes with it; and it's none of a view's or another popup's.
@Test func aPopupStaysAboveAndFollowsItsOwner() {
  let s = Scene(width: 800, height: 600)
  let (desk, _) = s.open(title: "desktop", width: 100, height: 100)
  _ = s.setDesktop(desk.id, true)
  let (w, _) = s.open(title: "notes", width: 300, height: 200)
  let (bar, _) = s.open(title: "deskbar", width: 80, height: 40)
  _ = s.setPanel(bar.id, true)
  guard let (p, effects) = s.openPopup(owner: desk.id, title: "menu", x: 200, y: 150, width: 120, height: 90) else {
    Issue.record("no popup")
    return
  }
  #expect(effects.count == 2 && s.focused == desk.id && p.undecorated && p.frame == p.content)
  #expect(p.content == Rect(x: 200, y: 150, width: 120, height: 90) && s.windows.last === p)
  // A window raised, or one opened, stays beneath it.
  _ = s.top(w.id)
  let (later, _) = s.open(title: "later", width: 50, height: 50)
  #expect(s.windows.last === p && s.windows[s.windows.count - 2] === bar && s.windows.contains { $0 === later })
  // A press in it focuses its owner (keys stay there).
  _ = s.moveTo(210, 160)
  _ = s.button(down: true)
  _ = s.button(down: false)
  #expect(s.focused == desk.id)
  // It follows its owner, moved or hidden.
  let (q, _) = s.openPopup(owner: w.id, title: "menu", x: 10, y: 20, width: 40, height: 30)!
  _ = s.move(w.id, x: 300, y: 300)
  _ = s.takeDamage()
  #expect(q.content.x == 310 && q.content.y == 320)
  _ = s.hide(w.id)
  _ = s.takeDamage()
  #expect(q.hidden)
  #expect(s.setPopupArea(q.id, x: 0, y: 0, width: 50, height: 30)?.count == 1 && q.content.width == 50)
  // It goes with its owner; a popup can't have one, nor can a view.
  _ = s.close(w.id)
  #expect(s.window(q.id) == nil && s.window(p.id) != nil)
  #expect(s.openPopup(owner: p.id, title: "x", x: 0, y: 0, width: 10, height: 10) == nil)
  let (v, _) = s.openView(title: "view", width: 10, height: 10)
  #expect(s.openPopup(owner: v.id, title: "x", x: 0, y: 0, width: 10, height: 10) == nil)
  #expect(s.setPopupArea(w.id, x: 0, y: 0, width: 10, height: 10) == nil)
}

// Colour (D110): an image tagged with alpha is blended over the layers
// beneath it in linear light; an opaque one is copied, its top byte
// ignored.
@Test func anImageWithAlphaIsBlendedInLight() {
  let s = Scene(width: 320, height: 240)
  let (w, _) = s.open(title: "a", width: 100, height: 60)
  // Half-transparent white, premultiplied (half its light: 0xbc) and
  // straight, over grey: both 0xcd, where blending the bytes gives 0xc0.
  var premultiplied = [UInt32](repeating: 0x80BC_BCBC, count: 10 * 10)
  var straight = [UInt32](repeating: 0x80FF_FFFF, count: 10 * 10)
  premultiplied.withUnsafeMutableBufferPointer { p in
    straight.withUnsafeMutableBufferPointer { q in
      w.images = [(1, Pixels(unsafe: p.baseAddress!, width: 10, height: 10, stride: 10)),
                  (2, Pixels(unsafe: q.baseAddress!, width: 10, height: 10, stride: 10))]
      w.layers = [Layer(image: 0, color: 0x80_8080, rect: Rect(x: 0, y: 0, width: 100, height: 60)),
                  Layer(image: 1, rect: Rect(x: 0, y: 0, width: 10, height: 10)),
                  Layer(image: 2, rect: Rect(x: 20, y: 0, width: 10, height: 10))]
      func pixel(_ x: Int) -> UInt32 {
        var target = [UInt32](repeating: 0, count: 320 * 240)
        target.withUnsafeMutableBufferPointer { t in
          s.compose(Rect(x: 0, y: 0, width: 320, height: 240), into: t.baseAddress!, stride: 320) { _ in InlineArray(repeating: 0) }
        }
        return target[(w.content.y + 5) * 320 + w.content.x + x]
      }
      // Untagged, each is opaque: its colour, the top byte dropped.
      #expect(pixel(5) == 0xBCBCBC && pixel(25) == 0xFFFFFF)
      #expect(s.tag(window: w.id, image: 1, alpha: .premultiplied) && s.tag(window: w.id, image: 2, alpha: .straight))
      #expect(pixel(5) == Light.over(premultiplied: 0x80BC_BCBC, 0x80_8080) && pixel(25) == pixel(5))
      #expect(pixel(5) == 0xCDCDCD)
      var list = DrawList()
      s.displayList(Rect(x: 0, y: 0, width: 320, height: 240), into: &list)
      #expect(list.quads.filter { $0.kind == Quad.image }.map { $0.color } == [1, 2])
      #expect(!s.tag(window: w.id, image: 9, alpha: .straight))
    }
  }
}

// Drag and drop (D112): only from a press held on a window's content; the
// window under the pointer hears it and answers; a release over one that
// accepted drops, anything else ends it with none.

@Test func aDragFromOneWindowDropsOnAnother() {
  let s = Scene(width: 640, height: 480)
  let (a, _) = s.open(title: "a", width: 100, height: 80)
  let (b, _) = s.open(title: "b", width: 100, height: 80)
  _ = s.move(a.id, x: 20, y: 40)
  _ = s.move(b.id, x: 300, y: 40)
  // No press: no drag.
  #expect(s.startDrag(source: a.id, types: ["text/plain"]) == nil)
  _ = s.moveTo(50, 60)
  _ = s.button(down: true)
  let over = s.startDrag(source: a.id, types: ["text/plain", "text/uri-list"]) ?? []
  #expect(over == [.dragOver(window: a.id, types: ["text/plain", "text/uri-list"], x: 30, y: 20)])
  // Over b: a hears it left, b hears it.
  let moved = s.moveTo(320, 70)
  #expect(moved == [.dragLeft(window: a.id), .dragOver(window: b.id, types: ["text/plain", "text/uri-list"], x: 20, y: 30)])
  // Only what the drag carries is taken.
  s.acceptDrag(b.id, types: ["text/uri-list", "image/png"])
  #expect(s.drag?.accepted == ["text/uri-list"])
  // What's drawn: the badge, in the focused tab's colour.
  var list = DrawList()
  s.displayList(Rect(x: 0, y: 0, width: 640, height: 480), into: &list)
  #expect(list.quads.contains { $0.kind == Quad.fill && $0.color == s.decorations.tabFocused && $0.rect.x == 335 })
  let dropped = s.button(down: false)
  #expect(dropped == [.drop(window: b.id, types: ["text/uri-list"], x: 20, y: 30), .dragEnded(window: a.id, dropped: true)])
  #expect(s.drag == nil)
}

@Test func aDragNotTakenEndsWithNoDrop() {
  let s = Scene(width: 640, height: 480)
  let (a, _) = s.open(title: "a", width: 100, height: 80)
  let (b, _) = s.open(title: "b", width: 100, height: 80)
  _ = s.move(a.id, x: 20, y: 40)
  _ = s.move(b.id, x: 300, y: 40)
  _ = s.moveTo(50, 60)
  _ = s.button(down: true)
  _ = s.startDrag(source: a.id, types: ["text/plain"])
  _ = s.moveTo(320, 70)
  #expect(s.button(down: false) == [.dragLeft(window: b.id), .dragEnded(window: a.id, dropped: false)])
  // Escape, over b: cancelled.
  _ = s.moveTo(50, 60)
  _ = s.button(down: true)
  _ = s.startDrag(source: a.id, types: ["text/plain"])
  _ = s.moveTo(320, 70)
  s.acceptDrag(b.id, types: ["text/plain"])
  #expect(s.cancelDrag() == [.dragLeft(window: b.id), .dragEnded(window: a.id, dropped: false)])
  // Its source closed: the window under it hears it left.
  _ = s.moveTo(50, 60)
  _ = s.button(down: true)
  _ = s.startDrag(source: a.id, types: ["text/plain"])
  _ = s.moveTo(320, 70)
  #expect(s.close(a.id).contains(.dragLeft(window: b.id)) && s.drag == nil)
}
