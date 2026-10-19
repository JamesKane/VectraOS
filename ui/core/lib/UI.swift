// SPDX-License-Identifier: BSD-3-Clause

// The UI Kit's immediate-mode core (M6i part 2, sdk.md §10): widgets are
// calls made every frame, keyed by id, with state retained underneath,
// in the manner of Ryan Fleury's UI series and the RAD Debugger.
//
// - Each frame builds a tree of boxes in flat arrays (reused frame to
//   frame: the per-frame arena). A box has a key (its id hashed with its
//   parent's), a style class, text, flags, and a size on each axis.
// - What must outlive a frame lives in a slot table by key: the rectangle
//   the box had last frame (what the pointer is tested against), and
//   whether it is hot (under the pointer, on top) or active (pressed). A
//   box not built in a frame loses its slot.
// - Layout is two passes over the tree (Layout.swift): sizes, then
//   positions.
// - The frame's display list is compared with the last frame's: if
//   nothing changed, `changed` is false and the caller presents nothing
//   (no idle wakeups).

import AccessTree
import TextLayout

/// A box's size on one axis, and how strictly it holds when its parent
/// has too little room (1: never shrinks; 0: gives all it has).
public enum Size: Equatable, Sendable {
  case pixels(Float, strictness: Float = 1)
  /// Its text's size, plus its style's padding.
  case text(strictness: Float = 1)
  /// A fraction of its parent's size.
  case percent(Float, strictness: Float = 0)
  /// Its children's: their sum along its layout axis, the largest across.
  case children(strictness: Float = 1)
  /// What its siblings leave, shared by weight.
  case grow(Float = 1)
}

public enum Axis: Int, Sendable {
  case horizontal = 0, vertical = 1
}

public struct BoxFlags: OptionSet, Sendable {
  public let rawValue: UInt32
  public init(rawValue: UInt32) { self.rawValue = rawValue }
  /// The pointer can press it.
  public static let clickable = BoxFlags(rawValue: 1)
  /// Its style's background (fill, border, corners, glow) is drawn.
  public static let background = BoxFlags(rawValue: 2)
  /// Its text is drawn.
  public static let text = BoxFlags(rawValue: 4)
  /// Its text is centred (else at its start).
  public static let centred = BoxFlags(rawValue: 8)
  /// Keyboard focus can rest on it.
  public static let focusable = BoxFlags(rawValue: 16)
  /// Its children are clipped to it.
  public static let clip = BoxFlags(rawValue: 32)
  /// Its text at its end (right-aligned).
  public static let end = BoxFlags(rawValue: 64)
  /// It edits text: focused, it keeps the keys a text field uses from
  /// key bindings.
  public static let editable = BoxFlags(rawValue: 128)
  /// It and its subtree are drawn over everything else in the frame, and
  /// take the pointer first (an open menu).
  public static let overlay = BoxFlags(rawValue: 256)
  /// Focused, it takes every key as it comes (a terminal): no Tab
  /// focus moves, no key bindings.
  public static let rawKeys = BoxFlags(rawValue: 512)
}

/// A key the kit acts on (the keyboard's usage, normalized by the input
/// service, mapped to these by the SDK): the editing and moving keys, and
/// a character key by its unshifted character (lower case).
public enum Key: Equatable, Sendable {
  case left, right, up, down, home, end, pageUp, pageDown, backspace, delete, enter, tab, escape, space
  case function(Int)
  case character(UInt32)
}

public struct KeyPress: Equatable, Sendable {
  public var key: Key
  public var shift: Bool
  public var control: Bool
  public var alt: Bool
  public init(_ key: Key, shift: Bool = false, control: Bool = false, alt: Bool = false) {
    self.key = key
    self.shift = shift
    self.control = control
    self.alt = alt
  }
}

/// A key or typed text, in the order they came.
public enum InputItem: Equatable, Sendable {
  case key(KeyPress)
  case text(String)
}

/// What the pointer did to a box this frame.
public struct Signal: Sendable {
  /// Under the pointer, and on top.
  public var hovered = false
  /// The pointer went down on it this frame.
  public var pressed = false
  /// Held: pressed on it and not yet released.
  public var held = false
  /// Released over it after being pressed on it: a click.
  public var clicked = false
  /// A click that followed a click on it within `UI.doubleClickTime` and
  /// 4 pixels (needs the input's `time`): the second, not a third.
  public var doubleClicked = false
  /// The secondary button went down on it (a right-click: its context
  /// menu opens on the press).
  public var secondaryPressed = false
  public init() {}
}

/// The input a frame sees: where the pointer is, and what its primary
/// button did since the last frame.
public struct FrameInput: Sendable {
  public var pointerX: Float
  public var pointerY: Float
  public var down: Bool
  public var pressed: Bool
  public var released: Bool
  /// The wheel since the last frame, in logical pixels (positive down).
  public var scroll: Float
  /// The wheel's horizontal motion, in logical pixels (positive right; M6l:
  /// a touchpad's, a tilting wheel's; Shift and the wheel give it too).
  public var scrollX: Float = 0
  /// Keys pressed since the last frame, in order.
  public var keys: [KeyPress]
  /// Text committed since the last frame (typed, or an IME's commit).
  public var text: String
  /// An IME's composition in progress (shown, not yet in the text).
  public var preedit: String
  /// The secondary button went down since the last frame.
  public var secondaryPressed: Bool
  /// Keys and typed text in the order they came, for a box that takes
  /// them raw (a terminal: Enter after the text before it). `keys` and
  /// `text` hold the same, apart.
  public var sequence: [InputItem] = []
  /// When the frame's input was taken, in monotonic nanoseconds (0: not
  /// known; no double-clicks then).
  public var time: Int64 = 0
  /// Shift and Control, as held at the pointer's last event (a click's
  /// way of selecting: Shift a range, Control one more).
  public var shift = false
  public var control = false

  public init(pointerX: Float = -1, pointerY: Float = -1, down: Bool = false, pressed: Bool = false,
              released: Bool = false, scroll: Float = 0, keys: [KeyPress] = [], text: String = "",
              preedit: String = "", secondaryPressed: Bool = false, scrollX: Float = 0)
  {
    self.secondaryPressed = secondaryPressed
    self.scrollX = scrollX
    self.pointerX = pointerX
    self.pointerY = pointerY
    self.down = down
    self.pressed = pressed
    self.released = released
    self.scroll = scroll
    self.keys = keys
    self.text = text
    self.preedit = preedit
  }
}

/// A rectangle, in logical pixels.
public struct Rect: Equatable, Sendable {
  public var x: Float, y: Float, width: Float, height: Float
  public init(x: Float, y: Float, width: Float, height: Float) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }
  public func contains(_ px: Float, _ py: Float) -> Bool { px >= x && py >= y && px < x + width && py < y + height }
}

/// A box of this frame's tree.
struct Box {
  var key: UInt64
  var parent: Int32 = -1
  var first: Int32 = -1
  var last: Int32 = -1
  var next: Int32 = -1
  var flags: BoxFlags
  var size: (Size, Size)
  var axis: Axis
  var style: Style
  var text: String
  /// Where a floating box is (logical pixels): placed there, outside its
  /// parent's flow.
  var position: (Float, Float)? = nil
  /// How far its children are scrolled up, in logical pixels.
  var scrollY: Float = 0
  var scrollX: Float = 0
  /// A scroll box's room kept for its scrollbars, right and bottom: its
  /// content is clipped short of it (M6l).
  var barInset: (right: Float, bottom: Float) = (0, 0)
  /// Whether it's a scroll box (`openScroll`), which the wheel may move.
  var scroller = false
  /// One past its subtree's last box (after `end`'s layout).
  var subtreeEnd: Int32 = 0
  /// Its text's size, measured once.
  var textSize: (Float, Float) = (0, 0)
  /// Layout's results: its size, and its rectangle.
  var computed: (Float, Float) = (0, 0)
  var rect = Rect(x: 0, y: 0, width: 0, height: 0)
  /// What the accessibility tree says of it.
  var role: Role = .none
  var label = ""
  var value = ""
  var states: AccessStates = []
  /// The declared action it performs (-1: none).
  var action: Int32 = -1
}

/// What a key keeps between frames.
struct Slot {
  var key: UInt64
  var rect: Rect
  var frame: UInt64
  var flags: BoxFlags = []
  /// A scroll box's offset, and how tall its content was; across, the
  /// same (M6l). A scrollbar's thumb keeps where a drag began here
  /// (`scroll` the pointer, `content` the offset).
  var scroll: Float = 0
  var content: Float = 0
  var scrollX: Float = 0
  var contentWidth: Float = 0
  /// A text field's caret and the selection's other end (scalar indices).
  var caret: Int = 0
  var anchor: Int = 0
}

public struct UI: Sendable {
  public var painter: Painter
  var boxes: [Box] = []
  var stack: [Int32] = []
  // The slot table: keys and their slots, open addressing over `table`.
  var slots: [Slot] = []
  var table: [Int32] = [Int32](repeating: -1, count: 256)
  var frame: UInt64 = 0
  var input = FrameInput()
  /// The key under the pointer (topmost clickable) as of the last frame,
  /// and the one pressed and still held.
  public private(set) var hot: UInt64 = 0
  /// The scroll boxes the wheel moves this frame, down and across: the
  /// innermost under the pointer that can move that way (M6l), so a list
  /// in a scrolling window takes the wheel, and one that fits passes it on.
  var wheelTarget: (y: UInt64, x: UInt64) = (0, 0)
  /// Whether a scroll box's bars come or go next frame (its content was
  /// measured after it was built): a frame more is asked for (`pending`),
  /// at most two in a row, so a window shows its bars without waiting
  /// for input.
  var settling = false
  var settled = 0
  public internal(set) var active: UInt64 = 0
  var lastList = DisplayList()
  /// Where keyboard focus is (0: nowhere).
  public internal(set) var focus: UInt64 = 0
  /// What the release this frame ends: the key the press was on.
  var releasedFrom: UInt64 = 0
  /// Whether the last frame drew anything different from the one before.
  public private(set) var changed = true
  /// Focus shown with the focus ring: it came from the keyboard.
  public internal(set) var focusVisible = false
  /// The last frame's focusable boxes, in the order built (Tab's order).
  var focusOrder: [UInt64] = []
  /// The focused control Enter or Space pressed this frame, and one an
  /// assistive client asked to press.
  var activate: UInt64 = 0
  var pressRequest: UInt64 = 0
  // Actions (Actions.swift): the declared, their bindings now, whether a
  // control or menu item has reached each; invocations for this frame,
  // and requests for the next.
  var actions: [Action] = []
  var bindings: [KeyPress?] = []
  var reached: [Bool] = []
  var invocations: [Invocation] = []
  var requests: [Invocation] = []
  /// The accessibility tree (Accessibility.swift), as of the last frame,
  /// and each box's node (or its nearest ancestor's).
  public internal(set) var access: [AccessNode] = []
  var nodeOf: [Int32] = []
  /// The window's title, the tree's root's label.
  public var title = ""
  /// The open menu bar menu's title, and its bar (Menus.swift); the open
  /// context menu: its key, where, and what it's about.
  var openMenu: UInt64 = 0
  var openMenuBar: UInt64 = 0
  var context: (key: UInt64, x: Float, y: Float, subject: String)? = nil
  /// The submenus open (M6l): in which menu, and the item opened at each
  /// level.
  var submenus: (menu: UInt64, path: [Int]) = (0, [])
  /// The last click: on what, when and where (a double-click's first).
  var lastClick: (key: UInt64, time: Int64, x: Float, y: Float)? = nil
  /// Where the pointer went down on what's being dragged (an icon field's
  /// icon).
  var dragFrom: (x: Float, y: Float)? = nil
  /// How soon a second click makes a double-click.
  public static let doubleClickTime: Int64 = 500_000_000
  /// Text fields' undo histories (Undo.swift), by key, and the last run.
  var fieldHistories: [FieldHistory] = []
  /// The platform's allocation counter, and the last frame's count in
  /// layout and paint (M6m: the editor's criterion is none).
  public var allocationCount: (@Sendable () -> UInt64)? = nil
  /// Arrays layout and paint fill each frame, kept (M6m: none allocated
  /// in a steady frame).
  var scratch = Scratch()
  struct Scratch: Sendable {
    var kids: [Int] = []
    var flags: [Bool] = []
    var overlays: [Int] = []
    var clips: [(end: Int32, rect: Rect)] = []
    var order: [Int] = []
    var damageTable: [Int32] = []
    var damageTaken: [Bool] = []
  }
  /// The last frame's damage, in pixels (nil: nothing changed): what the
  /// platform renders, copies and presents (M6m).
  public internal(set) var damage: Rect? = nil
  /// The last frame's open overlays (menus) and their outlines, in
  /// points; nil if none (M6m).
  public internal(set) var overlayArea: Rect? = nil
  public internal(set) var layoutPaintAllocations: UInt64 = 0
  /// Lines the last frame shaped (0: its text is all as before; M6m's
  /// steady state).
  public internal(set) var linesShaped: UInt64 = 0
  var shapedBefore: UInt64 = 0
  public internal(set) var layoutAllocations: UInt64 = 0
  public internal(set) var paintAllocations: UInt64 = 0
  /// Text areas' histories (M6m), as fields' are.
  var areaHistories: [AreaHistory] = []
  var nextGroup: UInt64 = 0
  /// The screen (the root box), in logical pixels.
  public var width: Float
  public var height: Float

  public init(painter: Painter, width: Float, height: Float) {
    self.painter = painter
    self.width = width
    self.height = height
  }

  public var theme: Theme { painter.theme }

  // MARK: Keys and slots

  static func hash(_ seed: UInt64, _ id: String) -> UInt64 {
    var h = seed ^ 0xCBF2_9CE4_8422_2325
    for b in id.utf8 {
      h = (h ^ UInt64(b)) &* 0x100_0000_01B3
    }
    return h == 0 ? 1 : h
  }

  func slot(_ key: UInt64) -> Int? {
    let mask = table.count - 1
    var i = Int(truncatingIfNeeded: key) & mask
    while true {
      let s = Int(table[i])
      if s < 0 { return nil }
      if slots[s].key == key { return s }
      i = (i + 1) & mask
    }
  }

  mutating func rebuildTable() {
    var size = 256
    while size < slots.count * 2 { size *= 2 }
    table = [Int32](repeating: -1, count: size)
    let mask = size - 1
    for (n, s) in slots.enumerated() {
      var i = Int(truncatingIfNeeded: s.key) & mask
      while table[i] >= 0 { i = (i + 1) & mask }
      table[i] = Int32(n)
    }
  }

  /// The rectangle a key's box had last frame.
  public func lastRect(_ id: String, in parent: UInt64 = 0) -> Rect? {
    slot(UI.hash(parent, id)).map { slots[$0].rect }
  }

  /// The rectangle box `key` had last frame (a custom view's, from its
  /// signal: where the pointer is in it).
  public func lastRect(key: UInt64) -> Rect? { slot(key).map { slots[$0].rect } }

  // MARK: Frames

  /// Starts a frame with its input: the root box is the screen, its
  /// children laid out along `axis`.
  public mutating func begin(_ input: FrameInput, axis: Axis = .vertical) {
    frame += 1
    self.input = input
    shapedBefore = painter.texts.inserted
    painter.texts.frame &+= 1
    settling = false
    // Where the wheel goes: the innermost scroll box (the last built) under
    // the pointer with more to show that way, from last frame's boxes.
    wheelTarget = (0, 0)
    if input.scroll != 0 || input.scrollX != 0 {
      for (i, b) in boxes.enumerated().reversed() where b.scroller && shown(i, input.pointerX, input.pointerY) {
        guard let s = slot(b.key) else { continue }
        let viewH = b.rect.height - b.barInset.bottom, viewW = b.rect.width - b.barInset.right
        if wheelTarget.y == 0 && slots[s].content > viewH + 0.5 { wheelTarget.y = b.key }
        if wheelTarget.x == 0 && slots[s].contentWidth > viewW + 0.5 { wheelTarget.x = b.key }
      }
    }
    boxes.removeAll(keepingCapacity: true)
    stack.removeAll(keepingCapacity: true)
    // Last frame's list kept to compare with, and the one before it reused
    // for this frame: swapped, never copied (M6m: a copy shares storage,
    // and emptying a shared list makes new storage).
    swap(&painter.list, &lastList)
    painter.list.reset()
    boxes.append(Box(key: UI.hash(0, "#root"), flags: [], size: (.pixels(width), .pixels(height)), axis: axis,
                     style: theme.style("default"), text: ""))
    stack.append(0)
    // A release ends what was held, wherever it lands; a click is a
    // release over what the press was on.
    releasedFrom = input.released ? active : 0
    if input.released { active = 0 }
    // A press shows focus no longer; scripts' and assistive clients'
    // requests become this frame's; then the keys are routed.
    if input.pressed { focusVisible = false }
    for var r in requests {
      r.frame = frame
      invocations.append(r)
    }
    requests.removeAll(keepingCapacity: true)
    activate = pressRequest
    pressRequest = 0
    routeKeys()
  }

  /// Ends the frame: lays it out, draws it, keeps what its keys must
  /// remember, and finds what's hot for the next.
  public mutating func end() {
    // The editor's criterion (M6m): no allocations in layout and paint,
    // counted where the platform can (natively, the floor's heap).
    let layoutStart = allocationCount?() ?? 0
    var kids = scratch.kids
    scratch.kids = []
    Layout.solve(&boxes, scratch: &kids)
    scratch.kids = kids
    // Slots: this frame's rectangles; those not built this frame go.
    for b in boxes {
      if let s = slot(b.key) {
        slots[s].rect = b.rect
        slots[s].frame = frame
        slots[s].flags = b.flags
      } else {
        slots.append(Slot(key: b.key, rect: b.rect, frame: frame, flags: b.flags))
        if slots.count * 2 > table.count { rebuildTable() } else { insertLast() }
      }
    }
    if slots.contains(where: { $0.frame != frame }) {
      slots.removeAll { $0.frame != frame }
      rebuildTable()
      // A field not built any more takes its history with it.
      var kept = fieldHistories
      kept.removeAll { h in slot(h.key) == nil }
      fieldHistories = kept
    }
    // Hot: the topmost clickable box under the pointer: an overlay's
    // first, then the last built.
    hot = 0
    // (Moved out, not copied: a copy shares the storage, and emptying it
    // would make new storage.)
    var inOverlay = scratch.flags
    scratch.flags = []
    inOverlay.removeAll(keepingCapacity: true)
    inOverlay.append(contentsOf: repeatElement(false, count: boxes.count))
    defer { scratch.flags = inOverlay }
    for i in boxes.indices where i > 0 {
      inOverlay[i] = boxes[i].flags.contains(.overlay) || inOverlay[Int(boxes[i].parent)]
    }
    for pass in 0..<2 where hot == 0 {
      let overlay = pass == 0
      for i in boxes.indices.reversed() where inOverlay[i] == overlay {
        let b = boxes[i]
        if b.flags.contains(.clickable) && b.rect.contains(input.pointerX, input.pointerY)
          && shown(i, input.pointerX, input.pointerY)
        {
          hot = b.key
          break
        }
      }
    }
    if active != 0 && !input.down { active = 0 }
    // Scroll boxes remember how tall and wide their content was: every box
    // within them (floating ones too: an icon field's icons), overlays
    // (menus) aside.
    for (i, b) in boxes.enumerated() where b.flags.contains(.clip) {
      if let s = slot(b.key) {
        var bottom = b.rect.y, right = b.rect.x
        for j in (i + 1)..<boxes.count where within(j, i) {
          bottom = max(bottom, boxes[j].rect.y + boxes[j].rect.height)
          right = max(right, boxes[j].rect.x + boxes[j].rect.width)
        }
        slots[s].content = bottom + b.scrollY - b.rect.y
        slots[s].contentWidth = right + b.scrollX - b.rect.x
      }
    }
    for b in boxes where b.scroller {
      guard let s = slot(b.key) else { continue }
      let bars = UI.bars(rect: b.rect, content: (slots[s].content, slots[s].contentWidth))
      if bars.vertical != (b.barInset.right > 0) || bars.horizontal != (b.barInset.bottom > 0) { settling = true }
    }
    settled = settling ? settled + 1 : 0
    if settled > 2 { settling = false }

    // A press on nothing focusable takes focus away.
    if input.pressed && !boxes.contains(where: { $0.flags.contains(.focusable) && $0.rect.contains(input.pointerX, input.pointerY) }) {
      focus = 0
    }
    focusOrder.removeAll(keepingCapacity: true)
    for b in boxes where b.flags.contains(.focusable) { focusOrder.append(b.key) }
    // A focused box no longer built (a field that closed) has it no more
    // (M6m: Edit's text takes it back).
    if focus != 0 && !boxes.contains(where: { $0.key == focus }) { focus = 0 }
    // Invocations not taken in a whole frame go.
    invocations.removeAll { $0.frame <= frame }
    let layoutEnd = allocationCount?() ?? 0
    buildAccessibility()
    let paintStart = allocationCount?() ?? 0
    draw()
    changed = !painter.list.same(as: lastList)
    damage = changed ? findDamage() : nil
    let paintEnd = allocationCount?() ?? 0
    linesShaped = painter.texts.inserted &- shapedBefore
    layoutAllocations = layoutEnd &- layoutStart
    paintAllocations = paintEnd &- paintStart
    layoutPaintAllocations = layoutAllocations &+ paintAllocations
  }


  mutating func insertLast() {
    let mask = table.count - 1
    let n = slots.count - 1
    var i = Int(truncatingIfNeeded: slots[n].key) & mask
    while table[i] >= 0 { i = (i + 1) & mask }
    table[i] = Int32(n)
  }

  /// Boxes in the order they were built (a parent under its children),
  /// a clipping box's subtree clipped to it.
  mutating func draw() {
    // Each box's subtree's end, from the leaves up.
    for i in stride(from: boxes.count - 1, through: 0, by: -1) {
      var end = Int32(i + 1)
      var c = boxes[i].first
      while c >= 0 {
        end = max(end, boxes[Int(c)].subtreeEnd)
        c = boxes[Int(c)].next
      }
      boxes[i].subtreeEnd = end
    }
    // Overlays' subtrees are drawn after the rest, unclipped by what holds
    // them. (The arrays are the UI's, reused: M6m.)
    var overlays = scratch.overlays, clips = scratch.clips, order = scratch.order
    (scratch.overlays, scratch.clips, scratch.order) = ([], [], [])
    overlays.removeAll(keepingCapacity: true)
    clips.removeAll(keepingCapacity: true)
    order.removeAll(keepingCapacity: true)
    defer { (scratch.overlays, scratch.clips, scratch.order) = (overlays, clips, order) }
    for i in boxes.indices where boxes[i].flags.contains(.overlay) { overlays.append(i) }
    // Where they are (M6m: a platform shows them in a popup of their own,
    // over other windows), with room for an outline.
    overlayArea = nil
    for o in overlays {
      let r = boxes[o].rect
      guard r.width > 0, r.height > 0 else { continue }
      let grown = Rect(x: r.x - 2, y: r.y - 2, width: r.width + 4, height: r.height + 4)
      overlayArea = overlayArea.map { a in
        let x0 = min(a.x, grown.x), y0 = min(a.y, grown.y)
        return Rect(x: x0, y: y0, width: max(a.x + a.width, grown.x + grown.width) - x0,
                    height: max(a.y + a.height, grown.y + grown.height) - y0)
      } ?? grown
    }
    painter.clip(nil)
    var i = 0
    while i < boxes.count {
      if boxes[i].flags.contains(.overlay) {
        i = Int(boxes[i].subtreeEnd)
        continue
      }
      order.append(i)
      i += 1
    }
    for o in overlays where !overlays.contains(where: { $0 < o && Int32(o) < boxes[$0].subtreeEnd }) {
      order.append(contentsOf: o..<Int(boxes[o].subtreeEnd))
    }
    var previous = -1
    for i in order {
      // A jump (into an overlay) leaves the clips of what came before.
      if i != previous + 1 {
        clips.removeAll()
        painter.clip(nil)
      }
      previous = i
      while let top = clips.last, Int32(i) >= top.end {
        clips.removeLast()
        painter.clip(clips.last?.rect)
      }
      let b = boxes[i]
      if b.flags.contains(.background) { painter.shape(b.rect.x, b.rect.y, b.rect.width, b.rect.height, b.style) }
      if b.flags.contains(.text) { drawText(b) }
      // The focus ring (the storyboard's focus-visible outline: 2 px amber,
      // 2 px out), when the keyboard put focus here; a text field's own
      // focused style shows it.
      if focusVisible && b.key == focus && !b.flags.contains(.editable) {
        var ring = theme.style("focus")
        let out = ring.padding.top + ring.border
        ring.cuts = b.style.cuts
        ring.radius = b.style.radius > 0 ? b.style.radius + out : 0
        painter.shape(b.rect.x - out, b.rect.y - out, b.rect.width + 2 * out, b.rect.height + 2 * out, ring)
      }
      // A box that clips clips its own drawing too (M6m: a text area's
      // lines), then its subtree.
      if b.flags.contains(.clip) { pushClip(b, &clips) }
      if let custom = drawers.first(where: { $0.key == b.key }) { custom.draw(&painter, b.rect) }
    }
    painter.clip(nil)
    drawers.removeAll(keepingCapacity: true)
  }

  /// Drawing a widget adds over its box (a caret, a selection), run in
  /// its place in the tree, after layout.
  var drawers: [(key: UInt64, draw: @Sendable (inout Painter, Rect) -> Void)] = []

  mutating func drawText(_ b: Box) {
    let s = b.style
    let tx = b.flags.contains(.centred) ? b.rect.x + (b.rect.width - b.textSize.0) / 2
      : b.flags.contains(.end) ? b.rect.x + b.rect.width - s.padding.right - b.textSize.0 : b.rect.x + s.padding.left
    let ty = b.rect.y + (b.rect.height - painter.lineHeight(s)) / 2
    painter.text(b.text, tx, ty, s)
  }

  // MARK: Building

  var parentKey: UInt64 { boxes[Int(stack[stack.count - 1])].key }

  /// A clipping box's clip (short of its bars, inside the clips around
  /// it), pushed for its subtree.
  mutating func pushClip(_ b: Box, _ clips: inout [(end: Int32, rect: Rect)]) {
    var r = b.rect
    r.width = max(0, r.width - b.barInset.right)
    r.height = max(0, r.height - b.barInset.bottom)
    if let outer = clips.last?.rect {
      let x0 = max(r.x, outer.x), y0 = max(r.y, outer.y)
      r = Rect(x: x0, y: y0, width: max(0, min(r.x + r.width, outer.x + outer.width) - x0),
               height: max(0, min(r.y + r.height, outer.y + outer.height) - y0))
    }
    clips.append((b.subtreeEnd, r))
    painter.clip(r)
  }

  /// Whether box `i`'s point (x, y) is shown: inside every clipping box
  /// it's in (short of their scrollbars), up to an overlay, which nothing
  /// clips. A row scrolled out of view, or under a scrollbar, isn't hot.
  func shown(_ i: Int, _ x: Float, _ y: Float) -> Bool {
    var j = i
    while j > 0 {
      let b = boxes[j]
      if b.flags.contains(.clip) {
        let r = b.rect
        guard x >= r.x && y >= r.y && x < r.x + r.width - b.barInset.right && y < r.y + r.height - b.barInset.bottom
        else { return false }
      }
      if b.flags.contains(.overlay) { return true }
      j = Int(b.parent)
    }
    return true
  }

  /// Whether box `j` is within box `i` (a descendant) and part of its
  /// content: no overlay on the way (j's own included), nor a box that
  /// clips (a list inside a window: its rows are its own content, the
  /// list's box the window's).
  func within(_ j: Int, _ i: Int) -> Bool {
    if boxes[j].flags.contains(.overlay) { return false }
    var p = Int(boxes[j].parent)
    while p >= 0 {
      if p == i { return true }
      if boxes[p].flags.contains(.overlay) || boxes[p].flags.contains(.clip) { return false }
      p = Int(boxes[p].parent)
    }
    return false
  }

  /// A box, a child of the open one: its id (unique among its siblings),
  /// style class, text, sizes and flags; what the pointer did to it.
  @discardableResult
  public mutating func box(_ id: String, class name: String = "default", text: String = "",
                           width: Size = .text(), height: Size = .text(), axis: Axis = .horizontal,
                           flags: BoxFlags = [], at position: (Float, Float)? = nil) -> Signal
  {
    let key = UI.hash(parentKey, id)
    let style = theme.style(name)
    var b = Box(key: key, flags: flags, size: (width, height), axis: axis, style: style, text: text)
    b.position = position
    if !text.isEmpty {
      b.textSize = (painter.measure(text, style), painter.lineHeight(style))
    }
    let index = Int32(boxes.count)
    let p = Int(stack[stack.count - 1])
    b.parent = Int32(p)
    if boxes[p].last >= 0 { boxes[Int(boxes[p].last)].next = index } else { boxes[p].first = index }
    boxes[p].last = index
    boxes.append(b)
    return signal(key, flags)
  }

  /// Opens a box for children (closed by `close()`); what the pointer did.
  @discardableResult
  public mutating func open(_ id: String, class name: String = "default", width: Size = .children(),
                            height: Size = .children(), axis: Axis = .vertical, flags: BoxFlags = [],
                            at position: (Float, Float)? = nil) -> Signal
  {
    let s = box(id, class: name, width: width, height: height, axis: axis, flags: flags, at: position)
    stack.append(Int32(boxes.count - 1))
    return s
  }

  public mutating func close() {
    if stack.count > 1 { stack.removeLast() }
  }

  /// The signal for a key: hot as of the last frame's layout; pressed,
  /// held and clicked from this frame's input.
  mutating func signal(_ key: UInt64, _ flags: BoxFlags) -> Signal {
    var s = Signal()
    guard flags.contains(.clickable) else { return s }
    s.hovered = hot == key
    if s.hovered && input.pressed {
      active = key
      s.pressed = true
    }
    s.held = active == key && input.down
    s.clicked = input.released && hot == key && releasedFrom == key
    if s.clicked && input.time != 0 {
      if let c = lastClick, c.key == key, input.time - c.time <= UI.doubleClickTime,
        abs(input.pointerX - c.x) <= 4, abs(input.pointerY - c.y) <= 4
      {
        s.doubleClicked = true
        lastClick = nil
      } else {
        lastClick = (key, input.time, input.pointerX, input.pointerY)
      }
    }
    s.secondaryPressed = s.hovered && input.secondaryPressed
    if activate == key && activate != 0 {
      s.clicked = true
      activate = 0
    }
    return s
  }

  // MARK: Widgets

  /// A line of text in a class.
  public mutating func label(_ id: String, _ text: String, class name: String = "label") {
    box(id, class: name, text: text, flags: [.text])
  }

  /// A button in a class (`.held` while pressed); whether it was clicked
  /// this frame.
  @discardableResult
  public mutating func button(_ id: String, _ text: String, class name: String = "button") -> Bool {
    let key = UI.hash(parentKey, id)
    let s = box(id, class: pressing(key) ? name + ".held" : name, text: text,
                flags: [.clickable, .background, .text, .centred, .focusable])
    return s.clicked
  }

  /// This frame's input as it came (a box taking raw keys reads them here).
  public var frameInput: FrameInput { input }

  /// The key of the box open now (its children's ids hash with it).
  public var openKey: UInt64 { parentKey }

  /// Gives keyboard focus to a box (its key: `UI.key`), as a press would.
  public mutating func focus(on key: UInt64) { focus = key }

  /// Whether a control is pressed now: the pointer went down on it and is
  /// still down, over it (it undraws when the pointer rolls off).
  func pressing(_ key: UInt64) -> Bool {
    input.down && hot == key && (active == key || input.pressed)
  }

  /// A box drawn by `draw` after layout, in its rectangle (an icon, a
  /// picture, a gauge); what the pointer did to it.
  @discardableResult
  public mutating func custom(_ id: String, class name: String = "default", width: Size, height: Size,
                              flags: BoxFlags = [], at position: (Float, Float)? = nil,
                              draw: @escaping @Sendable (inout Painter, Rect) -> Void) -> Signal
  {
    let s = box(id, class: name, width: width, height: height, flags: flags, at: position)
    drawers.append((boxes[boxes.count - 1].key, draw))
    return s
  }

  /// Space that takes what its siblings leave.
  public mutating func spacer(_ id: String, weight: Float = 1) {
    let horizontal = boxes[Int(stack[stack.count - 1])].axis == .horizontal
    box(id, width: horizontal ? .grow(weight) : .pixels(0), height: horizontal ? .pixels(0) : .grow(weight))
  }

  /// The rectangle a box was given this frame (after `end`).
  public func rect(_ id: String, in parent: UInt64 = 0) -> Rect? { lastRect(id, in: parent) }

  /// The key of a box (its id hashed with its parent's key).
  public static func key(_ id: String, in parent: UInt64 = 0) -> UInt64 { hash(parent, id) }
}
