// SPDX-License-Identifier: BSD-3-Clause

// Radharc's scene (desktop.md §1, §2; M4c): the windows, their stacking,
// focus and decorations, the pointer's effects on them, and composing a
// damaged region into a 32-bit buffer. Pure: the service gives it images
// (each a client's pixels in shared memory) and a target (the shadow of
// the framebuffer); tests give it arrays.
//
// Window management, decided: a press selects (focus at once) and the
// window rises on release without a drag, so an item can be dragged out
// of a window behind another; the neon tab moves a window; the corner
// grip resizes it, the client asked with a new configure and its old
// buffer shown, never stretched, until it draws for the new size; a moved
// window snaps to the screen's edges within 12 pixels.
//
// Spatial windows (M6j): a window may place itself, and then hears where
// the user moves it; a desktop window (Tracker's) is undecorated, the
// screen's size, and stays beneath every other window.
//
// Views (M6j, view tokens): a view is a window shown only inside another
// window's content, at an area its host gives, clipped to the host;
// drawn just after the host's own layers, it moves with its host and the
// pointer over it is the view's. Keys stay with the focused window.
//
// Colour (D110): pixels are sRGB. An image with alpha, premultiplied or
// straight, is blended over what's beneath it in linear light (Light); an
// opaque one is copied, as fills and the decorations are.
//
// The trusted prompt (D111, Prompt.swift): while a question is up it is
// drawn over every window, the rest of the screen dimmed, and the
// pointer only moves the cursor and works the prompt.

import Light

/// A rectangle in screen (or window) pixels.
public struct Rect: Equatable, Sendable {
  public var x: Int
  public var y: Int
  public var width: Int
  public var height: Int
  public init(x: Int, y: Int, width: Int, height: Int) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }
  public var isEmpty: Bool { width <= 0 || height <= 0 }
  public var maxX: Int { x + width }
  public var maxY: Int { y + height }
  public func contains(_ px: Int, _ py: Int) -> Bool { px >= x && px < maxX && py >= y && py < maxY }
  public func intersection(_ o: Rect) -> Rect {
    let x0 = max(x, o.x), y0 = max(y, o.y), x1 = min(maxX, o.maxX), y1 = min(maxY, o.maxY)
    return Rect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
  }
  public func union(_ o: Rect) -> Rect {
    if isEmpty { return o }
    if o.isEmpty { return self }
    let x0 = min(x, o.x), y0 = min(y, o.y)
    return Rect(x: x0, y: y0, width: max(maxX, o.maxX) - x0, height: max(maxY, o.maxY) - y0)
  }
}

/// Pixels a client shares: 32-bit 0x00RRGGBB words, `stride` a row, or
/// 0xAARRGGBB with alpha.
@safe public struct Pixels: @unchecked Sendable {
  let base: UInt
  public let width: Int
  public let height: Int
  public let stride: Int
  /// What the top byte is: nothing, or alpha (premultiplied or straight).
  public var alpha = RadharcIPC.PixelAlpha.opaque
  public init(unsafe base: UnsafeRawPointer, width: Int, height: Int, stride: Int) {
    self.base = UInt(bitPattern: base)
    self.width = width
    self.height = height
    self.stride = stride
  }
  /// Row `y`, `width` pixels, into `target` (packed).
  public func copyRow(_ y: Int, into target: UnsafeMutableRawPointer) {
    unsafe target.copyMemory(from: UnsafeRawPointer(bitPattern: base)! + y * stride * 4, byteCount: width * 4)
  }
  func pixel(_ x: Int, _ y: Int) -> UInt32 {
    unsafe UnsafeRawPointer(bitPattern: base)!.load(fromByteOffset: (y * stride + x) * 4, as: UInt32.self)
  }
}

/// One of a window's layers: an image's pixels, or a solid color, at a
/// place in the window's content.
public struct Layer: Equatable, Sendable {
  public var image: UInt32  // 0: solid
  public var color: UInt32
  public var rect: Rect
  public init(image: UInt32, color: UInt32 = 0, rect: Rect) {
    self.image = image
    self.color = color
    self.rect = rect
  }
}

public final class SceneWindow {
  public let id: UInt32
  public var title: String
  /// The content's place on screen (decorations around it).
  public var content: Rect
  /// The size the client last drew for, and the configure it answered.
  public var drawn: (width: Int, height: Int) = (0, 0)
  public var configSeq: UInt64 = 0
  /// The size it has been asked to draw (a pending configure if it differs).
  public var asked: (width: Int, height: Int)
  public var layers: [Layer] = []
  public var images: [(id: UInt32, pixels: Pixels)] = []
  /// Its frame as the theme draws it (UICore's Chrome, Frames.swift): its
  /// geometry and pixels; nil, the scene's own plain one.
  public internal(set) var chrome: WindowChrome?
  /// Presents latched: a renderer that copies images (the GPU's) copies
  /// again when this moves.
  public var presents: UInt64 = 0
  /// Fullscreen (M5c): the content is the screen, with no decorations;
  /// where it was before.
  public var fullscreen = false
  var windowed: Rect?
  /// The desktop (M6j): beneath every other window, undecorated.
  public internal(set) var desktop = false
  /// It placed itself (M6j): it hears where it's moved.
  public internal(set) var placed = false
  /// A panel (M6j: Deskbar's): above every other window, undecorated.
  public internal(set) var panel = false
  /// The app it says it belongs to (Deskbar groups windows by it).
  public var app = ""
  /// Hidden (M6l: Be's minimized, Deskbar's Hide): not drawn, not hit,
  /// not focused, until shown or raised.
  public internal(set) var hidden = false
  /// Zoomed (M6l: the tab's zoom box): where it was before.
  var zoomedFrom: Rect?
  public var zoomed: Bool { zoomedFrom != nil }
  /// The service whose connection opened it, as the launcher named it
  /// (M6k k6a: Radharc serves each client its own tree): not the app's
  /// word.
  public var owner = ""
  /// A secure surface (M6k k6a: the keyring's prompt): left out of what
  /// assistive clients and captures get, its pixels black to them.
  public var secure = false
  /// A popup (M6m: a menu's own surface): its owner, and its place in the
  /// owner's content. Above every window, panels too; it follows its owner,
  /// shows when it shows, and goes with it; a press in it focuses the owner.
  public internal(set) var popupOf: UInt32?
  var popupAt = (x: 0, y: 0)
  /// No border or tab: fullscreen, the desktop, a panel, or a popup.
  public var undecorated: Bool { fullscreen || desktop || panel || popupOf != nil }
  /// A view (M6j): shown only where a window embeds it.
  public internal(set) var isView = false
  /// Where it's embedded: its host, the host's id for it, and its area in
  /// the host's content.
  public internal(set) var embedding: (host: UInt32, id: UInt32, area: Rect)?
  /// Its clock (D114, `showClock`): where in its content, and whether in
  /// 24 hours; the face drawn for the time shown (nil: the scene's glyphs).
  public internal(set) var clock: (area: Rect, hours24: Bool)?
  public internal(set) var clockFace: ClockFace?

  init(id: UInt32, title: String, content: Rect) {
    self.id = id
    self.title = title
    self.content = content
    asked = (content.width, content.height)
  }

  /// Content, border and the tab above (just the content, fullscreen).
  /// The frame's border and tab's height: the theme's, or the scene's.
  var border: Int { chrome?.border ?? Scene.border }
  var tabHeight: Int { chrome?.tabHeight ?? Scene.tabHeight }
  public var frame: Rect {
    if undecorated { return content }
    return Rect(x: content.x - border, y: content.y - tabHeight - border,
         width: content.width + 2 * border, height: content.height + tabHeight + 2 * border)
  }
  public var tab: Rect {
    if undecorated { return Rect(x: 0, y: 0, width: 0, height: 0) }
    let w = min(chrome?.tabWidth ?? Scene.tabWidth(title), content.width + 2 * border)
    return Rect(x: content.x - border, y: content.y - tabHeight - border, width: w, height: tabHeight)
  }
  /// What the window covers: its frame less the space right of the tab.
  public var bounds: Rect { frame }
  /// What drawing it touches: its frame, and the theme's glow past it.
  public var painted: Rect {
    guard !undecorated, let m = chrome?.margin, m > 0 else { return frame }
    let f = frame
    return Rect(x: f.x - m, y: f.y - m, width: f.width + 2 * m, height: f.height + 2 * m)
  }
  /// Be's close box, at the tab's left, and zoom box, at its right.
  public var closeBox: Rect {
    let t = tab
    if !undecorated, let c = chrome { return Rect(x: t.x + c.closeBox.x, y: t.y + c.closeBox.y, width: c.closeBox.width, height: c.closeBox.height) }
    guard !undecorated, t.width >= 2 * Scene.box + 12 else { return Rect(x: 0, y: 0, width: 0, height: 0) }
    return Rect(x: t.x + 5, y: t.y + (Scene.tabHeight - Scene.box) / 2, width: Scene.box, height: Scene.box)
  }
  public var zoomBox: Rect {
    let t = tab
    if !undecorated, let c = chrome { return Rect(x: t.x + c.zoomBox.x, y: t.y + c.zoomBox.y, width: c.zoomBox.width, height: c.zoomBox.height) }
    guard !undecorated, t.width >= 2 * Scene.box + 12 else { return Rect(x: 0, y: 0, width: 0, height: 0) }
    return Rect(x: t.maxX - 5 - Scene.box, y: t.y + (Scene.tabHeight - Scene.box) / 2, width: Scene.box, height: Scene.box)
  }
  public var grip: Rect {
    if undecorated { return Rect(x: 0, y: 0, width: 0, height: 0) }
    return Rect(x: content.maxX - 12, y: content.maxY - 12, width: 12 + Scene.border, height: 12 + Scene.border)
  }
}

/// One step of composing (M5j's display list), in the layout the GPU's
/// renderer reads (shaders/compose.vert's `Quad`: vec4, ivec4, uvec4, 48
/// bytes), so that a list is one contiguous batch both renderers walk.
/// `rect` is already clipped. By kind: a fill of `color`; a rectangle of
/// an image (`texture` indexes the list's `images`, `sx`, `sy` the source
/// origin in it, `color` its alpha as `PixelAlpha`'s value); a glyph of a
/// title (`texture` its code point, `sx`, `sy` where the clipped rectangle
/// starts in its 8x16 cell); the cursor (`sx`, `sy` likewise in its
/// shape); the screen dimmed beneath the trusted prompt; the prompt's
/// seal (`sx`, `sy` where the rectangle starts from the seal's centre).
public struct Quad: Equatable, Sendable {
  public var x: Float, y: Float, width: Float, height: Float
  public var sx: Int32, sy: Int32
  public var texture: UInt32
  public var kind: UInt32
  public var color: UInt32
  var pad0: UInt32 = 0, pad1: UInt32 = 0, pad2: UInt32 = 0

  public static let fill: UInt32 = 0, image: UInt32 = 1, glyph: UInt32 = 2, cursor: UInt32 = 3, dim: UInt32 = 4
  public static let seal: UInt32 = 5

  public init(_ r: Rect, sx: Int = 0, sy: Int = 0, texture: UInt32 = 0, kind: UInt32, color: UInt32 = 0) {
    x = Float(r.x)
    y = Float(r.y)
    width = Float(r.width)
    height = Float(r.height)
    self.sx = Int32(sx)
    self.sy = Int32(sy)
    self.texture = texture
    self.kind = kind
    self.color = color
  }

  public var rect: Rect { Rect(x: Int(x), y: Int(y), width: Int(width), height: Int(height)) }
}

/// A frame's display list: its quads in draw order, and the window images
/// they draw (an image quad's `texture` is an index here). Kept and filled
/// again each frame (`displayList(_:into:)` empties it, keeping capacity).
public struct DrawList {
  public var quads: [Quad] = []
  public var images: [(window: UInt32, image: UInt32)] = []
  public init() {}
}

/// What the scene asks of the service after an event.
public enum SceneEffect: Equatable, Sendable {
  /// Tell window `id` its new size, under a new configure sequence.
  case configure(window: UInt32, width: Int, height: Int, seq: UInt64, focused: Bool)
  /// Focus moved to `id` (0: none): its keys go there, and both windows'
  /// focus is told.
  case focus(window: UInt32)
  /// Window `id`, which placed itself, moved: its content's top left.
  case moved(window: UInt32, x: Int, y: Int)
  /// The view window `host` embedded as `id` is gone.
  case viewGone(window: UInt32, id: UInt32)
  /// Ask window `id` to close (M6l: its close box, Deskbar's Close all):
  /// its client decides.
  case closeRequested(window: UInt32)
  /// A drag of `types` over window `id`'s content at (x, y), in it.
  case dragOver(window: UInt32, types: [String], x: Int, y: Int)
  /// The drag left window `id`, or ended over it without a drop.
  case dragLeft(window: UInt32)
  /// Dropped on window `id`: the types it accepted, at (x, y).
  case drop(window: UInt32, types: [String], x: Int, y: Int)
  /// The drag window `id` started ended, dropped or not.
  case dragEnded(window: UInt32, dropped: Bool)
}

public final class Scene {
  public static let tabHeight = 20, border = 1, snap = 12
  /// The image id a window's frame is drawn from (clients' are nonzero).
  public static let chromeImage: UInt32 = 0
  /// The image id its clock's face is drawn from (clients' are below it).
  public static let clockImage: UInt32 = .max
  /// The close and zoom boxes' size (M6l).
  public static let box = 10
  /// The title, and room for the close box before it and the zoom box
  /// after.
  public static func tabWidth(_ title: String) -> Int { title.utf8.count * 8 + 24 + 2 * (box + 6) }
  /// Where a tab's title starts: past its close box.
  public static let titleInset = 5 + box + 7

  public let width: Int
  public let height: Int
  /// Bottom to top.
  public private(set) var windows: [SceneWindow] = []
  public private(set) var focused: UInt32 = 0
  public private(set) var pointer = (x: 0, y: 0)
  var nextID: UInt32 = 1
  var nextSeq: UInt64 = 1
  /// A press: on what, where, and whether it became a drag.
  var press: (window: UInt32, part: Part, x: Int, y: Int, origin: Rect, dragged: Bool)?
  /// The region that needs composing again.
  public private(set) var damage = Rect(x: 0, y: 0, width: 0, height: 0)

  enum Part { case tab, grip, content, close, zoom }

  public init(width: Int, height: Int) {
    self.width = width
    self.height = height
    pointer = (width / 2, height / 2)
    damageAll()
  }

  public func damageAll() { damage = Rect(x: 0, y: 0, width: width, height: height) }
  public func add(damage r: Rect) { damage = damage.union(r.intersection(Rect(x: 0, y: 0, width: width, height: height))) }
  public func takeDamage() -> Rect {
    followOwners()
    defer { damage = Rect(x: 0, y: 0, width: 0, height: 0) }
    return damage
  }

  public func window(_ id: UInt32) -> SceneWindow? { windows.first { $0.id == id } }

  /// A new window, cascaded, on top and focused; its first configure.
  public func open(title: String, width w: Int, height h: Int) -> (SceneWindow, [SceneEffect]) {
    let n = windows.filter { !$0.isView }.count
    let x = min(max(40 + 32 * n, Scene.border), max(Scene.border, width - w - Scene.border))
    let y = min(max(60 + 32 * n, Scene.tabHeight + Scene.border), max(Scene.tabHeight + Scene.border, height - h - Scene.border))
    let win = SceneWindow(id: nextID, title: title, content: Rect(x: x, y: y, width: w, height: h))
    nextID += 1
    insertOnTop(win)
    add(damage: win.painted)
    var effects = focus(win.id)
    effects.insert(configure(win), at: 0)
    return (win, effects)
  }

  public func close(_ id: UInt32) -> [SceneEffect] {
    // A drag it started ends; one over it is over nothing.
    var ended: [SceneEffect] = []
    if let d = drag, d.source == id {
      ended = cancelDrag().filter { if case .dragEnded = $0 { false } else { true } }
    }
    if var d = drag, d.over == id {
      d.over = nil
      d.accepted = []
      drag = d
    }
    return ended + closeWindow(id)
  }

  func closeWindow(_ id: UInt32) -> [SceneEffect] {
    // Its popups go with it.
    for p in windows where p.popupOf == id { add(damage: p.painted) }
    windows.removeAll { $0.popupOf == id }
    guard let i = windows.firstIndex(where: { $0.id == id }) else { return [] }
    let w = windows[i]
    var effects: [SceneEffect] = []
    if let e = w.embedding {
      if let r = screenRect(w) { add(damage: r) }
      effects.append(.viewGone(window: e.host, id: e.id))
    } else if !w.isView {
      add(damage: w.painted)
    }
    windows.remove(at: i)
    // Its views are shown nowhere now.
    for v in windows where v.embedding?.host == id { v.embedding = nil }
    return effects + (focused == id ? focus(topVisible?.id ?? 0) : [])
  }

  /// The topmost window that shows (not a view, not hidden).
  var topVisible: SceneWindow? { windows.last { !$0.isView && !$0.hidden } }

  // MARK: Hiding and zooming (M6l)

  /// Hides window `id` (Be's minimize: Deskbar's Hide all): focus goes to
  /// the top window that shows. nil if there's no such window; the
  /// desktop, panels and views don't hide.
  public func hide(_ id: UInt32) -> [SceneEffect]? {
    guard let w = window(id) else { return nil }
    guard !w.hidden, !w.desktop, !w.panel, !w.isView, w.popupOf == nil else { return [] }
    add(damage: w.painted)
    w.hidden = true
    return focused == id ? focus(topVisible?.id ?? 0) : []
  }

  /// Shows window `id` again, raised and focused (`top` does too).
  public func show(_ id: UInt32) -> [SceneEffect]? {
    guard let w = window(id) else { return nil }
    guard !w.isView else { return [] }
    w.hidden = false
    raise(id)
    add(damage: w.painted)
    return focus(id)
  }

  /// Asks window `id`'s client to close it; nil if there's no such window.
  public func requestClose(_ id: UInt32) -> [SceneEffect]? {
    guard let w = window(id), !w.isView else { return nil }
    return [.closeRequested(window: id)]
  }

  /// Zooms window `id` (its zoom box): to the screen less its decorations,
  /// or back to where it was; raised and focused, with a configure. nil
  /// if there's no such window.
  public func zoom(_ id: UInt32) -> [SceneEffect]? {
    guard let w = window(id) else { return nil }
    guard !w.undecorated, !w.isView else { return [] }
    add(damage: w.painted)
    if let back = w.zoomedFrom {
      w.content = back
      w.zoomedFrom = nil
    } else {
      w.zoomedFrom = w.content
      let top = Scene.tabHeight + Scene.border
      w.content = Rect(x: Scene.border, y: top, width: width - 2 * Scene.border, height: height - top - Scene.border)
    }
    w.asked = (w.content.width, w.content.height)
    w.hidden = false
    raise(id)
    add(damage: w.painted)
    return [configure(w)] + focus(id)
  }

  // MARK: Views

  /// A new view, `w` by `h` until embedded; its first configure. It isn't
  /// shown, focused or raised.
  public func openView(title: String, width w: Int, height h: Int) -> (SceneWindow, [SceneEffect]) {
    let view = SceneWindow(id: nextID, title: title, content: Rect(x: 0, y: 0, width: w, height: h))
    view.isView = true
    nextID += 1
    windows.append(view)
    return (view, [configure(view)])
  }

  /// Window `host` shows view `view` as its embedding `id` at `area` (in
  /// its content); a configure for the area's size if it changed. nil if
  /// either isn't there, or `view` isn't a view.
  public func embed(host: UInt32, view: UInt32, id: UInt32, area: Rect) -> [SceneEffect]? {
    guard let h = window(host), !h.isView, let v = window(view), v.isView else { return nil }
    if let r = screenRect(v) { add(damage: r) }
    // Another view embedded as `id` is replaced.
    for other in windows where other !== v && other.embedding?.host == host && other.embedding?.id == id {
      other.embedding = nil
    }
    v.embedding = (host, id, area)
    v.content.width = area.width
    v.content.height = area.height
    if let r = screenRect(v) { add(damage: r) }
    guard v.asked != (area.width, area.height) else { return [] }
    v.asked = (area.width, area.height)
    return [configure(v)]
  }

  /// Window `host`'s embedding `id` to `area`; nil if it has none.
  public func placeEmbedding(host: UInt32, id: UInt32, area: Rect) -> [SceneEffect]? {
    guard let v = windows.first(where: { $0.embedding?.host == host && $0.embedding?.id == id }) else { return nil }
    return embed(host: host, view: v.id, id: id, area: area)
  }

  /// Window `host` stops showing its embedding `id`.
  public func unembed(host: UInt32, id: UInt32) {
    for v in windows where v.embedding?.host == host && v.embedding?.id == id {
      if let r = screenRect(v) { add(damage: r) }
      v.embedding = nil
    }
  }

  // MARK: Popups (M6m)

  /// A popup of window `owner`, `w` by `h` at (x, y) in its content: on top
  /// of everything; its first configure, and the owner focused (a menu's
  /// keys go to it: a right-click focuses nothing). nil if there's no such
  /// window, or it's a view or a popup itself.
  public func openPopup(owner: UInt32, title: String, x: Int, y: Int, width w: Int, height h: Int)
    -> (SceneWindow, [SceneEffect])?
  {
    guard let o = window(owner), !o.isView, o.popupOf == nil else { return nil }
    let p = SceneWindow(id: nextID, title: title, content: Rect(x: o.content.x + x, y: o.content.y + y, width: w, height: h))
    nextID += 1
    p.popupOf = owner
    p.popupAt = (x, y)
    p.hidden = o.hidden
    p.app = o.app
    p.owner = o.owner
    windows.append(p)
    add(damage: p.painted)
    return (p, [configure(p)] + focus(owner))
  }

  /// Popup `id` to (x, y) in its owner's content, `w` by `h`: a configure
  /// if its size changed. nil if it isn't a popup.
  public func setPopupArea(_ id: UInt32, x: Int, y: Int, width w: Int, height h: Int) -> [SceneEffect]? {
    guard let p = window(id), let owner = p.popupOf, let o = window(owner) else { return nil }
    add(damage: p.painted)
    p.popupAt = (x, y)
    p.content = Rect(x: o.content.x + x, y: o.content.y + y, width: w, height: h)
    add(damage: p.painted)
    guard p.asked != (w, h) else { return [] }
    p.asked = (w, h)
    return [configure(p)]
  }

  /// Each popup where its owner is now, shown as it is.
  func followOwners() {
    for p in windows {
      guard let owner = p.popupOf, let o = window(owner) else { continue }
      let x = o.content.x + p.popupAt.x, y = o.content.y + p.popupAt.y
      guard x != p.content.x || y != p.content.y || p.hidden != o.hidden else { continue }
      add(damage: p.painted)
      p.content.x = x
      p.content.y = y
      p.hidden = o.hidden
      add(damage: p.painted)
    }
  }

  /// Window `id` a panel or not (M6j): undecorated and above every other
  /// window (where it places itself), or back among them. nil if there's
  /// no such window.
  public func setPanel(_ id: UInt32, _ on: Bool) -> [SceneEffect]? {
    guard let i = windows.firstIndex(where: { $0.id == id }) else { return nil }
    let w = windows[i]
    guard w.panel != on, !w.desktop, !w.isView else { return [] }
    add(damage: w.painted)
    windows.remove(at: i)
    w.panel = on
    insertOnTop(w)
    add(damage: w.painted)
    return []
  }

  /// Where a window's content is on the screen: a view's, its area in its
  /// host's content, clipped to it (nil if it's shown nowhere).
  public func screenRect(_ w: SceneWindow) -> Rect? {
    guard w.isView else { return w.content }
    if prompts.showing?.view == w.id { return promptLayout?.chooser }
    guard let e = w.embedding, let h = window(e.host), !h.isView else { return nil }
    let r = Rect(x: h.content.x + e.area.x, y: h.content.y + e.area.y, width: e.area.width, height: e.area.height)
    return r.intersection(h.content)
  }

  /// The views a window shows.
  func views(of host: UInt32) -> [SceneWindow] { windows.filter { $0.embedding?.host == host } }

  func configure(_ w: SceneWindow) -> SceneEffect {
    let seq = nextSeq
    nextSeq += 1
    return .configure(window: w.id, width: w.asked.width, height: w.asked.height, seq: seq, focused: w.id == focused)
  }

  func focus(_ id: UInt32) -> [SceneEffect] {
    guard id != focused else { return [] }
    if let old = window(focused) { add(damage: old.painted) }
    focused = id
    given = 0
    if let new = window(id) { add(damage: new.painted) }
    return [.focus(window: id)]
  }

  func raise(_ id: UInt32) {
    // The desktop stays beneath; panels stay above.
    guard let i = windows.firstIndex(where: { $0.id == id }), !windows[i].desktop else { return }
    let w = windows.remove(at: i)
    insertOnTop(w)
    add(damage: w.painted)
  }

  /// `w` on top of its kind: a popup above everything, then panels, then
  /// anything else.
  func insertOnTop(_ w: SceneWindow) {
    if w.popupOf != nil {
      windows.append(w)
    } else if w.panel {
      windows.insert(w, at: windows.firstIndex { $0.popupOf != nil } ?? windows.count)
    } else {
      windows.insert(w, at: windows.firstIndex { $0.panel || $0.popupOf != nil } ?? windows.count)
    }
  }

  // MARK: Window control (the `windows` service's verbs)

  /// Moves window `id`'s content to (x, y); nil if there's no such window
  /// (a desktop doesn't move). A window that placed itself hears of it.
  public func move(_ id: UInt32, x: Int, y: Int) -> [SceneEffect]? {
    guard let w = window(id) else { return nil }
    guard !w.desktop else { return [] }
    add(damage: w.painted)
    w.content.x = x
    w.content.y = y
    add(damage: w.painted)
    return w.placed ? [.moved(window: id, x: x, y: y)] : []
  }

  /// Window `id` places itself (M6j): its content's top left to (x, y),
  /// kept where its tab can be grabbed (a tab's height of it on screen);
  /// from now on it hears where it's moved. nil if there's no such window.
  public func place(_ id: UInt32, x: Int, y: Int) -> [SceneEffect]? {
    guard let w = window(id) else { return nil }
    w.placed = true
    guard !w.desktop, !w.fullscreen else { return [] }
    let grab = Scene.tabHeight + Scene.border
    let nx = min(max(x, grab - w.content.width), width - grab)
    let ny = min(max(y, grab), height - Scene.border)
    add(damage: w.painted)
    w.content.x = nx
    w.content.y = ny
    add(damage: w.painted)
    return [.moved(window: id, x: nx, y: ny)]
  }

  /// Window `id` the desktop or not (M6j): the screen as its content,
  /// undecorated, beneath every other window, with a configure for the
  /// screen's size; or back where it was, on top. nil if there's no such
  /// window.
  public func setDesktop(_ id: UInt32, _ on: Bool) -> [SceneEffect]? {
    guard let i = windows.firstIndex(where: { $0.id == id }) else { return nil }
    let w = windows[i]
    guard w.desktop != on else { return [] }
    windows.remove(at: i)
    if on {
      w.windowed = w.content
      w.content = Rect(x: 0, y: 0, width: width, height: height)
      // Beneath every window, above other desktops.
      let firstNormal = windows.firstIndex { !$0.desktop } ?? windows.count
      windows.insert(w, at: firstNormal)
    } else {
      w.content = w.windowed ?? Rect(x: 40, y: 60, width: min(w.content.width, width / 2), height: min(w.content.height, height / 2))
      insertOnTop(w)
    }
    w.desktop = on
    w.asked = (w.content.width, w.content.height)
    damageAll()
    // Gone beneath: the top window has focus, if there is one.
    let top = windows.last { !$0.desktop && !$0.isView }
    let focusing = on && focused == id && top != nil ? focus(top!.id) : !on ? focus(id) : []
    return [configure(w)] + focusing
  }

  /// Gives window `id` a new size at once, and its client a configure for
  /// it (its old buffer shows at its own size meanwhile); nil if there's
  /// no such window.
  public func resize(_ id: UInt32, width w: Int, height h: Int) -> [SceneEffect]? {
    guard let win = window(id) else { return nil }
    add(damage: win.painted)
    win.asked = (w, h)
    win.content.width = w
    win.content.height = h
    add(damage: win.painted)
    return [configure(win)]
  }

  /// Window `id` fullscreen or not (M5c): the screen as its content, raised
  /// and focused, with a configure for the screen's size; back to where it
  /// was. nil if there's no such window.
  public func setFullscreen(_ id: UInt32, _ on: Bool) -> [SceneEffect]? {
    guard let w = window(id) else { return nil }
    guard w.fullscreen != on else { return [] }
    add(damage: w.painted)
    if on {
      w.windowed = w.content
      w.content = Rect(x: 0, y: 0, width: width, height: height)
    } else {
      w.content = w.windowed ?? Rect(x: 40, y: 60, width: min(w.content.width, width / 2), height: min(w.content.height, height / 2))
    }
    w.fullscreen = on
    w.asked = (w.content.width, w.content.height)
    damageAll()
    raise(id)
    let focused = focus(id)
    return [configure(w)] + focused
  }

  /// The topmost window, if it's fullscreen: what direct scanout may show.
  public var fullscreenOnTop: SceneWindow? { topVisible.flatMap { $0.fullscreen ? $0 : nil } }

  /// Raises and focuses window `id`; nil if there's no such window.
  public func top(_ id: UInt32) -> [SceneEffect]? {
    guard let w = window(id) else { return nil }
    // A hidden window shows again.
    if w.hidden {
      w.hidden = false
      add(damage: w.painted)
    }
    raise(id)
    return focus(id)
  }

  /// The topmost window under (x, y), and what part of it.
  func hit(_ x: Int, _ y: Int) -> (SceneWindow, Part)? {
    followOwners()
    for w in windows.reversed() where !w.isView && !w.hidden {
      if w.closeBox.contains(x, y) { return (w, .close) }
      if w.zoomBox.contains(x, y) { return (w, .zoom) }
      if w.tab.contains(x, y) { return (w, .tab) }
      if w.grip.contains(x, y) { return (w, .grip) }
      let body = Rect(x: w.content.x - Scene.border, y: w.content.y - Scene.border,
                      width: w.content.width + 2 * Scene.border, height: w.content.height + 2 * Scene.border)
      if body.contains(x, y) { return (w, .content) }
    }
    return nil
  }

  /// A client presented: its layers and the configure it drew for. A
  /// buffer drawn for an older configure is shown only if the size still
  /// matches (never stretched).
  public func present(_ id: UInt32, seq: UInt64, size: (width: Int, height: Int), layers: [Layer], damage: Rect?) {
    window(id)?.presents += 1
    guard let w = window(id) else { return }
    w.configSeq = seq
    w.drawn = size
    w.layers = layers
    // A view shown nowhere damages nothing.
    guard let content = screenRect(w) else { return }
    if w.isView, let e = w.embedding, let h = window(e.host) {
      let at = Rect(x: h.content.x + e.area.x, y: h.content.y + e.area.y, width: e.area.width, height: e.area.height)
      if let d = damage {
        add(damage: Rect(x: at.x + d.x, y: at.y + d.y, width: d.width, height: d.height).intersection(content))
      } else {
        add(damage: content)
      }
      return
    }
    if let d = damage {
      add(damage: Rect(x: content.x + d.x, y: content.y + d.y, width: d.width, height: d.height))
    } else {
      add(damage: content)
    }
  }

  // MARK: The pointer

  public func moveTo(_ x: Int, _ y: Int) -> [SceneEffect] {
    let nx = max(0, min(width - 1, x)), ny = max(0, min(height - 1, y))
    add(damage: cursorRect)
    if drag != nil { add(damage: badgeRect) }
    pointer = (nx, ny)
    add(damage: cursorRect)
    // A drag: the badge follows, and the window under it hears.
    if drag != nil {
      add(damage: badgeRect)
      return dragMoved()
    }
    guard prompts.showing == nil, var p = press, let w = window(p.window) else { return [] }
    let dx = nx - p.x, dy = ny - p.y
    if !p.dragged && (abs(dx) > 2 || abs(dy) > 2) { p.dragged = true }
    press = p
    guard p.dragged else { return [] }
    switch p.part {
    case .tab:
      add(damage: w.painted)
      w.content.x = snapX(p.origin.x + dx, w)
      w.content.y = snapY(p.origin.y + dy, w)
      add(damage: w.painted)
      return []
    case .grip:
      let nw = max(64, p.origin.width + dx), nh = max(32, p.origin.height + dy)
      guard (nw, nh) != w.asked else { return [] }
      w.asked = (nw, nh)
      return [configure(w)]
    case .content, .close, .zoom:
      return []
    }
  }

  public func moveBy(_ dx: Int, _ dy: Int) -> [SceneEffect] { moveTo(pointer.x + dx, pointer.y + dy) }

  func snapX(_ x: Int, _ w: SceneWindow) -> Int {
    let left = Scene.border, right = width - w.content.width - Scene.border
    if abs(x - left) <= Scene.snap { return left }
    if abs(x - right) <= Scene.snap { return right }
    return x
  }
  func snapY(_ y: Int, _ w: SceneWindow) -> Int {
    let top = Scene.tabHeight + Scene.border, bottom = height - w.content.height - Scene.border
    if abs(y - top) <= Scene.snap { return top }
    if abs(y - bottom) <= Scene.snap { return bottom }
    return y
  }

  /// A button: the left one selects, moves and resizes, and its release
  /// ends a drag.
  public func button(down: Bool) -> [SceneEffect] {
    if !down, let d = drag {
      drag = nil
      press = nil
      add(damage: badgeRect)
      if let o = d.over, !d.accepted.isEmpty, let t = pointerTarget(), t.window == o {
        return [.drop(window: o, types: d.accepted, x: t.x, y: t.y), .dragEnded(window: d.source, dropped: true)]
      }
      return (d.over.map { [SceneEffect.dragLeft(window: $0)] } ?? []) + [.dragEnded(window: d.source, dropped: false)]
    }
    if down {
      guard let (w, part) = hit(pointer.x, pointer.y) else {
        press = nil
        return []
      }
      press = (w.id, part, pointer.x, pointer.y, w.content, false)
      return focus(w.popupOf ?? w.id)  // press selects (a popup's, its owner)
    }
    guard let p = press else { return [] }
    press = nil
    // A box clicked: released over it, not dragged off.
    if p.part == .close || p.part == .zoom, let w = window(p.window) {
      guard !p.dragged, (p.part == .close ? w.closeBox : w.zoomBox).contains(pointer.x, pointer.y) else { return [] }
      return p.part == .close ? [.closeRequested(window: w.id)] : (zoom(w.id) ?? [])
    }
    // Release raises, unless the press became a drag out of the window.
    if !p.dragged || p.part != .content { raise(p.window) }
    if p.dragged && p.part == .tab, let w = window(p.window), w.placed {
      return [.moved(window: w.id, x: w.content.x, y: w.content.y)]
    }
    if p.part == .grip, let w = window(p.window) {
      add(damage: Rect(x: w.content.x - Scene.border, y: w.content.y - Scene.tabHeight - Scene.border,
                       width: max(w.content.width, w.asked.width) + 2 * Scene.border,
                       height: max(w.content.height, w.asked.height) + Scene.tabHeight + 2 * Scene.border))
      w.content.width = w.asked.width
      w.content.height = w.asked.height
    }
    return []
  }

  /// Whether nothing of window `id` shows: off the screen, or its frame
  /// inside one window's above it (one, not a union of several: cheap, and
  /// conservative). Hidden windows' frames are throttled to about 1 Hz.
  public func isHidden(_ id: UInt32) -> Bool {
    guard let i = windows.firstIndex(where: { $0.id == id }) else { return true }
    if windows[i].hidden { return true }
    // A view is hidden where its host is, or shown nowhere.
    if windows[i].isView {
      if prompts.showing?.view == id { return false }
      return windows[i].embedding.map { isHidden($0.host) } ?? true
    }
    let frame = windows[i].frame
    if frame.intersection(Rect(x: 0, y: 0, width: width, height: height)).isEmpty { return true }
    for above in windows[(i + 1)...] where !above.hidden && !above.isView && above.frame.intersection(frame) == frame {
      return true
    }
    return false
  }

  /// The window the pointer is over, and where in its content.
  public func pointerTarget() -> (window: UInt32, x: Int, y: Int)? {
    guard let (w, part) = hit(pointer.x, pointer.y), part == .content else { return nil }
    // Over one of its views: the view's, the last embedded on top.
    for v in views(of: w.id).reversed() {
      guard let e = v.embedding, let r = screenRect(v), r.contains(pointer.x, pointer.y) else { continue }
      return (v.id, pointer.x - (w.content.x + e.area.x), pointer.y - (w.content.y + e.area.y))
    }
    return (w.id, pointer.x - w.content.x, pointer.y - w.content.y)
  }

  // MARK: Drag and drop (D112)

  /// A drag under way: the window it started from and the types it
  /// carries; the window under the pointer, and what it would take.
  public struct Drag: Equatable, Sendable {
    public var source: UInt32
    public var types: [String]
    public var over: UInt32?
    public var accepted: [String] = []
  }
  public private(set) var drag: Drag?

  /// The badge drawn beside the cursor while a drag is under way.
  var badgeRect: Rect { Rect(x: pointer.x + 14, y: pointer.y + 14, width: 18, height: 14) }

  /// A drag of `types` from window `source`: only while the left button
  /// pressed on its content is held. nil if it isn't; else the window
  /// under the pointer hears of it.
  public func startDrag(source: UInt32, types: [String]) -> [SceneEffect]? {
    guard drag == nil, let p = press, p.window == source, p.part == .content, !types.isEmpty else { return nil }
    drag = Drag(source: source, types: types)
    add(damage: badgeRect)
    return dragMoved()
  }

  /// The pointer moved in a drag: a window left hears, the one under it
  /// hears where it is.
  func dragMoved() -> [SceneEffect] {
    guard var d = drag else { return [] }
    let t = pointerTarget()
    var out: [SceneEffect] = []
    if t?.window != d.over {
      if let o = d.over { out.append(.dragLeft(window: o)) }
      d.over = t?.window
      d.accepted = []
    }
    if let t { out.append(.dragOver(window: t.window, types: d.types, x: t.x, y: t.y)) }
    drag = d
    return out
  }

  /// Window `id`, under the drag, would take `types` of it.
  public func acceptDrag(_ id: UInt32, types: [String]) {
    guard var d = drag, d.over == id else { return }
    // (Bytes compared: tier 0 has no Unicode tables.)
    let taken = types.filter { t in d.types.contains { $0.utf8.elementsEqual(t.utf8) } }
    guard taken.count != d.accepted.count || !zip(taken, d.accepted).allSatisfy({ $0.utf8.elementsEqual($1.utf8) }) else {
      return
    }
    d.accepted = taken
    drag = d
    add(damage: badgeRect)
  }

  /// The drag ends with no drop (Escape, its window gone).
  public func cancelDrag() -> [SceneEffect] {
    guard let d = drag else { return [] }
    drag = nil
    press = nil
    add(damage: badgeRect)
    return (d.over.map { [SceneEffect.dragLeft(window: $0)] } ?? []) + [.dragEnded(window: d.source, dropped: false)]
  }

  // MARK: The clipboard's read rule

  /// The focused window, once it has been given a key or a press since it
  /// was focused; 0 until then.
  public private(set) var given: UInt32 = 0

  /// Window `id` was given a key or a press: it counts if it is focused.
  public func gave(_ id: UInt32) {
    if id != 0 && id == focused { given = id }
  }

  /// Whether `client` may read the clipboard (D112): its window is
  /// focused and has had input since.
  public func mayRead(client: String) -> Bool {
    guard given != 0, given == focused, let w = window(given) else { return false }
    return same(w.owner, client)
  }

  // MARK: The trusted prompt

  /// The questions asked, the oldest on screen.
  public private(set) var prompts = Prompts()

  /// Where the question on screen is drawn, if one is.
  public var promptLayout: PromptLayout? {
    prompts.showing.map { PromptLayout($0, screenWidth: width, screenHeight: height) }
  }

  public func newPromptID() -> UInt64 { prompts.newID() }

  /// Queues `q`. Shown, it dims the screen, and a press under way ends.
  public func ask(_ q: PromptQuestion, now: Int64) {
    guard prompts.ask(q, now: now) else { return }
    press = nil
    damageAll()
  }

  /// Takes question `id` away (its asker closed it, or it was answered).
  public func withdraw(_ id: UInt64, now: Int64) {
    if prompts.withdraw(id, now: now) { damageAll() }
  }

  /// The left button, over the prompt.
  public func promptButton(down: Bool, now: Int64) -> Prompts.Outcome {
    guard let l = promptLayout else { return .none }
    return settle(down ? prompts.press(pointer.x, pointer.y, now: now, l) : prompts.release(pointer.x, pointer.y, l), now)
  }

  /// A rune typed, to the prompt.
  public func promptTyped(_ rune: UInt32, now: Int64) -> Prompts.Outcome {
    settle(prompts.typed(rune, now: now), now)
  }

  func settle(_ o: Prompts.Outcome, _ now: Int64) -> Prompts.Outcome {
    switch o {
    case .none: break
    case .redraw: if let l = promptLayout { add(damage: l.panel) }
    case .answered(let id, let reply):
      if let q = prompts.showing, q.id == id, case .choose = q.kind, reply.starts(with: "once".utf8) {
        if let l = promptLayout { add(damage: l.panel) }
      } else {
        withdraw(id, now: now)
      }
    }
    return o
  }

  // MARK: Composing

  static let cursorWidth = 11, cursorHeight = 16
  /// An arrow: 1 outline, 2 fill, 0 clear.
  static let cursorShape: [UInt8] = {
    var s = [UInt8](repeating: 0, count: cursorWidth * cursorHeight)
    for y in 0..<cursorHeight {
      let span = y < 11 ? y + 1 : max(0, 11 - (y - 10) * 2)
      for x in 0..<min(span, cursorWidth) { s[y * cursorWidth + x] = (x == 0 || x == span - 1 || y == 10) ? 1 : 2 }
    }
    return s
  }()
  var cursorRect: Rect { Rect(x: pointer.x, y: pointer.y, width: Scene.cursorWidth, height: Scene.cursorHeight) }

  /// Window `id`'s frame, drawn by the theme (nil: the scene's own); its
  /// place, old and new, damaged.
  public func setChrome(_ id: UInt32, _ c: WindowChrome?) {
    guard let w = window(id) else { return }
    add(damage: w.painted)
    w.chrome = c
    add(damage: w.painted)
  }

  // MARK: The clock (D114)

  /// The time the clocks show (`ClockText`'s); a change damages each.
  public var clockText: (minuteOfDay: Int64, set: Bool) = (0, false) {
    didSet { if clockText != oldValue { damageClocks() } }
  }

  /// Window `id` shows the clock in `area` of its content (nil: none).
  public func setClock(_ id: UInt32, area: Rect?, hours24: Bool) {
    guard let w = window(id) else { return }
    damageClocks(of: w)
    w.clock = area.map { ($0, hours24) }
    if w.clock == nil { w.clockFace = nil }
    damageClocks(of: w)
  }

  /// Window `id`'s clock's face, drawn for the time it shows now.
  public func setClockFace(_ id: UInt32, _ face: ClockFace?) {
    guard let w = window(id) else { return }
    w.clockFace = face
    damageClocks(of: w)
  }

  /// What window `w`'s clock shows.
  public func clockString(_ w: SceneWindow) -> String {
    ClockText.text(minuteOfDay: clockText.minuteOfDay, hours24: w.clock?.hours24 ?? true)
  }

  /// Where window `w`'s clock is on screen, clipped to its content.
  func clockRect(_ w: SceneWindow) -> Rect? {
    guard let c = w.clock, clockText.set else { return nil }
    let r = Rect(x: w.content.x + c.area.x, y: w.content.y + c.area.y, width: c.area.width, height: c.area.height)
      .intersection(w.content)
    return r.isEmpty ? nil : r
  }

  func damageClocks(of w: SceneWindow? = nil) {
    for v in windows where w == nil || v === w {
      if let r = clockRect(v), !v.hidden { add(damage: r) }
    }
  }

  /// What the decorations are drawn in, from the theme; changing it
  /// damages the screen.
  public var decorations = Decorations.base {
    didSet { if decorations != oldValue { damageAll() } }
  }

  /// What composing `region` draws, in order (M5j), into `list`:
  /// background, windows bottom to top with their decorations and layers,
  /// the cursor; each clipped to the region (and an image to its own
  /// size). A renderer, the CPU's (`render`) or the GPU's (Radharc's,
  /// natively), draws it.
  public func displayList(_ region: Rect, into list: inout DrawList) {
    list.quads.removeAll(keepingCapacity: true)
    list.images.removeAll(keepingCapacity: true)
    let r = region.intersection(Rect(x: 0, y: 0, width: width, height: height))
    guard !r.isEmpty else { return }
    func fill(_ rect: Rect, _ color: UInt32) {
      let c = rect.intersection(r)
      if !c.isEmpty { list.quads.append(Quad(c, kind: Quad.fill, color: color)) }
    }
    fill(r, decorations.desk)
    // A window's layers at `at` (its content's top left), clipped to `clip`:
    // a buffer drawn for another size is shown at its own size, cropped.
    func layers(_ w: SceneWindow, at: (x: Int, y: Int), clip: Rect) {
      for layer in w.layers {
        let origin = (x: at.x + layer.rect.x, y: at.y + layer.rect.y)
        var lr = Rect(x: origin.x, y: origin.y, width: layer.rect.width, height: layer.rect.height).intersection(clip)
        guard !lr.isEmpty else { continue }
        if layer.image == 0 {
          list.quads.append(Quad(lr, kind: Quad.fill, color: layer.color))
          continue
        }
        guard let image = w.images.first(where: { $0.id == layer.image })?.pixels else { continue }
        lr = lr.intersection(Rect(x: origin.x, y: origin.y, width: image.width, height: image.height))
        guard !lr.isEmpty else { continue }
        var index = list.images.firstIndex { $0.window == w.id && $0.image == layer.image }
        if index == nil {
          list.images.append((w.id, layer.image))
          index = list.images.count - 1
        }
        list.quads.append(Quad(lr, sx: lr.x - origin.x, sy: lr.y - origin.y, texture: UInt32(index!), kind: Quad.image,
                               color: UInt32(image.alpha.rawValue)))
      }
    }
    for w in windows where !w.isView && !w.hidden {
      let focused = w.id == self.focused
      guard !w.painted.intersection(r).isEmpty else { continue }
      // Its frame, the theme's: an image under its layers.
      // The theme's frame: the body's ground under its content, then the
      // frame's edges over it.
      if !w.undecorated, let c = w.chrome {
        fill(w.content.intersection(r), decorations.body)
        // (Only its edges: the inside is the body's fill, above.)
        let f = w.painted
        for s in c.strips {
          let cr = Rect(x: f.x + s.x, y: f.y + s.y, width: s.width, height: s.height).intersection(r)
          guard !cr.isEmpty else { continue }
          var index = list.images.firstIndex { $0.window == w.id && $0.image == Scene.chromeImage }
          if index == nil {
            list.images.append((w.id, Scene.chromeImage))
            index = list.images.count - 1
          }
          list.quads.append(Quad(cr, sx: cr.x - f.x, sy: cr.y - f.y, texture: UInt32(index!), kind: Quad.image,
                                 color: UInt32(RadharcIPC.PixelAlpha.premultiplied.rawValue)))
        }
      } else if !w.undecorated {
        // Border, tab, title, the scene's own (none: fullscreen, the desktop).
        let body = Rect(x: w.content.x - Scene.border, y: w.content.y - Scene.border,
                        width: w.content.width + 2 * Scene.border, height: w.content.height + 2 * Scene.border)
        fill(body, focused ? decorations.edgeFocused : decorations.edge)
        let tab = w.tab
        fill(tab, focused ? decorations.tabFocused : decorations.tab)
        let text = focused ? decorations.tabInkFocused : decorations.tabInk
        // Be's boxes: the close box a square, the zoom box a small square
        // over a large one's corner; 1-pixel strokes in the title's colour.
        func stroke(_ b: Rect) {
          fill(Rect(x: b.x, y: b.y, width: b.width, height: 1), text)
          fill(Rect(x: b.x, y: b.maxY - 1, width: b.width, height: 1), text)
          fill(Rect(x: b.x, y: b.y, width: 1, height: b.height), text)
          fill(Rect(x: b.maxX - 1, y: b.y, width: 1, height: b.height), text)
        }
        let cb = w.closeBox, zb = w.zoomBox
        if cb.width > 0 {
          stroke(cb)
          stroke(Rect(x: zb.x + 3, y: zb.y + 3, width: zb.width - 3, height: zb.height - 3))
          stroke(Rect(x: zb.x, y: zb.y, width: 6, height: 6))
        }
        var tx = tab.x + (cb.width > 0 ? Scene.titleInset : 12)
        let titleEnd = zb.width > 0 ? zb.x - 4 : tab.maxX - 4
        for scalar in w.title.unicodeScalars where tx + 8 <= titleEnd {
          let cell = Rect(x: tx, y: tab.y + 2, width: 8, height: 16)
          let c = cell.intersection(r)
          if !c.isEmpty {
            list.quads.append(Quad(c, sx: c.x - cell.x, sy: c.y - cell.y, texture: scalar.value, kind: Quad.glyph,
                                   color: text))
          }
          tx += 8
        }
      }
      // Content: the body's ground, then the layers, clipped to it; then its
      // views over them, each at its area.
      let content = w.content.intersection(r)
      if w.chrome == nil || w.undecorated { fill(content, decorations.body) }
      layers(w, at: (w.content.x, w.content.y), clip: content)
      for v in views(of: w.id) {
        guard let e = v.embedding, let vr = screenRect(v) else { continue }
        layers(v, at: (w.content.x + e.area.x, w.content.y + e.area.y), clip: vr.intersection(r))
      }
      // Its clock over them: its face if drawn for the time shown, else
      // the time in the scene's glyphs, right-aligned and centred.
      if let cr = clockRect(w) {
        let text = clockString(w)
        if let f = w.clockFace, f.fits(text: text, width: cr.width, height: cr.height) {
          let c = cr.intersection(r)
          if !c.isEmpty {
            var index = list.images.firstIndex { $0.window == w.id && $0.image == Scene.clockImage }
            if index == nil {
              list.images.append((w.id, Scene.clockImage))
              index = list.images.count - 1
            }
            list.quads.append(Quad(c, sx: c.x - cr.x, sy: c.y - cr.y, texture: UInt32(index!), kind: Quad.image,
                                   color: UInt32(RadharcIPC.PixelAlpha.premultiplied.rawValue)))
          }
        } else {
          var tx = cr.maxX - text.utf8.count * 8
          let ty = cr.y + (cr.height - 16) / 2
          for scalar in text.unicodeScalars {
            let cell = Rect(x: tx, y: ty, width: 8, height: 16)
            let c = cell.intersection(cr).intersection(r)
            if !c.isEmpty {
              list.quads.append(Quad(c, sx: c.x - cell.x, sy: c.y - cell.y, texture: scalar.value, kind: Quad.glyph,
                                     color: decorations.tabInk))
            }
            tx += 8
          }
        }
      }
    }
    // The prompt over them all, the screen dimmed; then the cursor, last.
    if let q = prompts.showing, let l = promptLayout {
      l.draw(q, pressed: prompts.pressed, field: prompts.field, screen: Rect(x: 0, y: 0, width: width, height: height),
             clip: r, into: &list)
      if q.view != 0, let v = window(q.view), let c = l.chooser {
        layers(v, at: (c.x, c.y), clip: c.intersection(r))
      }
    }
    // A drag's badge: filled in the focused tab's colour where it would be
    // taken, the body's where not.
    if let d = drag {
      let b = badgeRect
      for (rect, color) in [(b, decorations.edgeFocused),
                            (Rect(x: b.x + 1, y: b.y + 1, width: b.width - 2, height: b.height - 2),
                             d.accepted.isEmpty ? decorations.body : decorations.tabFocused)] {
        let c = rect.intersection(r)
        if !c.isEmpty { list.quads.append(Quad(c, kind: Quad.fill, color: color)) }
      }
    }
    let cr = cursorRect.intersection(r)
    if !cr.isEmpty { list.quads.append(Quad(cr, sx: cr.x - pointer.x, sy: cr.y - pointer.y, kind: Quad.cursor)) }
  }

  /// A window's image's pixels, for a renderer.
  public func pixels(window: UInt32, image: UInt32) -> Pixels? {
    if image == Scene.chromeImage { return self.window(window)?.chrome?.pixels }
    if image == Scene.clockImage { return self.window(window)?.clockFace?.pixels }
    return self.window(window)?.images.first { $0.id == image }?.pixels
  }

  /// What a window's image's top byte is, from its next present on; false
  /// if there is no such image.
  public func tag(window: UInt32, image: UInt32, alpha: RadharcIPC.PixelAlpha) -> Bool {
    guard let w = self.window(window), let i = w.images.firstIndex(where: { $0.id == image }) else { return false }
    w.images[i].pixels.alpha = alpha
    return true
  }

  /// Draws `list` into `target` (32-bit 0x00RRGGBB, `stride` pixels a row):
  /// the CPU's renderer. `glyph` draws a title's text (the font's bits for
  /// a code point's row, 8 wide, 16 high).
  public func render(_ list: DrawList, into target: UnsafeMutablePointer<UInt32>, stride: Int,
                     glyph: (UInt32, Int) -> UInt8)
  {
    for q in list.quads {
      let c = q.rect
      switch q.kind {
      case Quad.fill:
        for y in c.y..<c.maxY {
          let row = unsafe target + y * stride
          for x in c.x..<c.maxX { unsafe row[x] = q.color }
        }
      case Quad.glyph:
        for y in c.y..<c.maxY {
          let bits = glyph(q.texture, Int(q.sy) + y - c.y)
          for x in c.x..<c.maxX where bits & (0x80 >> UInt8(Int(q.sx) + x - c.x)) != 0 {
            unsafe target[y * stride + x] = q.color
          }
        }
      case Quad.image:
        let ref = list.images[Int(q.texture)]
        guard let pixels = pixels(window: ref.window, image: ref.image) else { continue }
        for y in c.y..<c.maxY {
          for x in c.x..<c.maxX {
            let p = pixels.pixel(Int(q.sx) + x - c.x, Int(q.sy) + y - c.y)
            switch q.color {
            case UInt32(RadharcIPC.PixelAlpha.premultiplied.rawValue):
              unsafe target[y * stride + x] = Light.over(premultiplied: p, target[y * stride + x])
            case UInt32(RadharcIPC.PixelAlpha.straight.rawValue):
              unsafe target[y * stride + x] = Light.over(straight: p, target[y * stride + x])
            default: unsafe target[y * stride + x] = p & 0xFF_FFFF
            }
          }
        }
      case Quad.dim:
        let t = Trusted.dimming
        for y in c.y..<c.maxY {
          for x in c.x..<c.maxX {
            let p = unsafe target[y * stride + x]
            unsafe target[y * stride + x] = UInt32(t[Int(p >> 16 & 0xFF)]) << 16 | UInt32(t[Int(p >> 8 & 0xFF)]) << 8
              | UInt32(t[Int(p & 0xFF)])
          }
        }
      case Quad.seal:
        for y in c.y..<c.maxY {
          for x in c.x..<c.maxX {
            if let s = Trusted.seal(Int(q.sx) + x - c.x, Int(q.sy) + y - c.y) { unsafe target[y * stride + x] = s }
          }
        }
      default:  // the cursor
        for y in c.y..<c.maxY {
          for x in c.x..<c.maxX {
            let s = Scene.cursorShape[(Int(q.sy) + y - c.y) * Scene.cursorWidth + Int(q.sx) + x - c.x]
            if s != 0 { unsafe target[y * stride + x] = s == 1 ? decorations.cursorOutline : decorations.cursorFill }
          }
        }
      }
    }
  }

  /// Composes `region` into `target` with the CPU's renderer.
  public func compose(_ region: Rect, into target: UnsafeMutablePointer<UInt32>, stride: Int,
                      glyph: (UInt32, Int) -> UInt8)
  {
    var list = DrawList()
    displayList(region, into: &list)
    unsafe render(list, into: target, stride: stride, glyph: glyph)
  }

  /// The cursor's pixels: 0 clear, 1 its outline, 2 its body.
  public static var cursor: (width: Int, height: Int, shape: [UInt8]) { (cursorWidth, cursorHeight, cursorShape) }
}
