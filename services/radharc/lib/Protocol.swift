// SPDX-License-Identifier: BSD-3-Clause

// Radharc's protocol (desktop.md §1, M4c): a client opens windows from the
// compositor, each window its own channel. A window holds images (pixels
// in a VMO the client shares, each with an acquire counter the client
// raises once it has drawn, and a release counter the compositor raises
// once it no longer reads them) and presents a list of layers over them,
// drawn for a configure: a buffer drawn for an older size is shown at its
// own size, never stretched. The window's input comes on a ring of its own
// (the one ring, D43: WindowInput.swift), keys while it has focus and the
// pointer in its content's coordinates, with a counter for its doorbell.
//
// Frames (M4d): the compositor latches presents at its vblanks (synthetic
// on the boot framebuffer, D27: its own deadline, not a timeline), composes
// once and copies the damage out, then sends each window whose present it
// showed a `frame`: when it was shown, the next vblank to aim for, and its
// credit back.
//
// `Windows` (M4f, desktop.md §1's `windows`) is the window list with
// rio's wctl verbs, typed, for any number of subscribers: each connection
// hears `changed` with the list as it is after a change.
//
// Spatial windows (M6j): a window may place itself (Tracker opens a folder
// where it was) and then hears `moved` when the user moves it; a window
// whose role is `desktop` is the desktop (Tracker's): undecorated, the
// screen's size, beneath every other window.
//
// View tokens (M6j; desktop.md §1): a client opens a view, a surface that
// presents and takes input as a window does but is shown only inside
// another's window, and holds its token: a channel end, whose peer
// Radharc keeps and knows the view by (D107: event pairs are cut, D23). A
// window embeds a view by its token at an area of its content; the view is
// configured for that area's size, and the pointer over it is the view's.
// Deskbar's replicants are views, each its own process: a crash takes down
// only the replicant, and its embedder hears `viewGone`.
//
// Panels and apps (M6j): a panel (`setPanel`: Deskbar) is undecorated and
// above every other window; a window says which app it belongs to
// (`setApp`), and the window list's `entries` carry it, for Deskbar's
// running apps.
//
// Colour (D110): an image's pixels are 8-bit sRGB, opaque, unless a tag
// says otherwise. A tag names their transfer, primaries and alpha; Radharc
// composes only sRGB with BT.709's primaries, refusing a tag naming
// another with the error that names it, and blends an image with alpha in
// linear light (Light).
//
// The console serves `Handoff`: the compositor gives it a channel to
// itself, and the console moves from the framebuffer into a window
// (decided: Radharc owns the framebuffer; the console is its first client).
//
// Not here yet: the privileged services (capture, inject, observe,
// shortcuts) and secure surfaces, which come with the trusted prompt
// (D111); buffer collections and direct scanout, with the display class.

import IPC
import Node

@IPCLibrary(id: "todhchai.radharc", version: 5)
public enum RadharcIPC {
  public enum WindowError: Int32, IPCErrorCode, Sendable {
    case invalid = 1
    case noImage
    case unavailable
    /// A present beyond the window's latency: wait for a `frame`.
    case noCredit
    /// An image tagged with a transfer other than sRGB's.
    case transfer
    /// An image tagged with primaries other than BT.709's.
    case primaries
  }

  /// An image's pixels' transfer: how a value encodes light.
  public enum Transfer: UInt8, Sendable {
    case srgb = 0
    case linear = 1
    /// SMPTE ST 2084's perceptual quantizer.
    case pq = 2
    /// Hybrid log-gamma.
    case hlg = 3
  }

  /// The colours an image's red, green and blue are.
  public enum Primaries: UInt8, Sendable {
    /// sRGB's.
    case bt709 = 0
    case p3 = 1
    case bt2020 = 2
  }

  /// What an image's top byte is.
  public enum PixelAlpha: UInt8, Sendable {
    /// Nothing: every pixel is opaque.
    case opaque = 0
    /// Alpha, the channels already times it in light.
    case premultiplied = 1
    /// Alpha, the channels as they are.
    case straight = 2
  }

  /// What an image's pixels mean. An image not tagged is sRGB, BT.709,
  /// opaque.
  public struct PixelTag: Equatable, Sendable {
    public var transfer: Transfer
    public var primaries: Primaries
    public var alpha: PixelAlpha
    public init(transfer: Transfer = .srgb, primaries: Primaries = .bt709, alpha: PixelAlpha = .opaque) {
      self.transfer = transfer
      self.primaries = primaries
      self.alpha = alpha
    }
  }

  public struct Area: Equatable, Sendable {
    public var x: Int32
    public var y: Int32
    public var width: Int32
    public var height: Int32
    public init(x: Int32, y: Int32, width: Int32, height: Int32) {
      self.x = x
      self.y = y
      self.width = width
      self.height = height
    }
  }

  /// What a window is to the desktop.
  public enum WindowRole: UInt8, Sendable {
    case normal = 0
    /// The desktop: undecorated, the screen's size, beneath every other
    /// window and never raised over them.
    case desktop = 1
  }

  /// A window in the list, with its app and role.
  public struct WindowEntry: Equatable, Sendable {
    public var id: UInt32
    public var title: String
    /// What it said it belongs to (`setApp`; "" if it didn't).
    public var app: String
    public var area: Area
    public var focused: Bool
    /// The desktop's (`setRole(.desktop)`), or a panel (`setPanel`).
    public var desktop: Bool
    public var panel: Bool
    public init(id: UInt32, title: String, app: String, area: Area, focused: Bool, desktop: Bool, panel: Bool) {
      self.id = id
      self.title = title
      self.app = app
      self.area = area
      self.focused = focused
      self.desktop = desktop
      self.panel = panel
    }
  }

  public struct Layer: Equatable, Sendable {
    /// 0: a solid color.
    public var image: UInt32
    public var color: UInt32
    public var area: Area
    public init(image: UInt32, color: UInt32, area: Area) {
      self.image = image
      self.color = color
      self.area = area
    }
  }

  public struct Configure: Equatable, Sendable {
    /// Draw for this; present it back.
    public var seq: UInt64
    public var width: UInt32
    public var height: UInt32
    public var focused: Bool
    public init(seq: UInt64, width: UInt32, height: UInt32, focused: Bool) {
      self.seq = seq
      self.width = width
      self.height = height
      self.focused = focused
    }
  }

  /// A frame, after the compositor latched a window's present.
  public struct Frame: Equatable, Sendable {
    /// The present's `number`, and when it reached the screen: the
    /// composed frame's copy to the framebuffer done (monotonic ns).
    public var presented: Int64
    public var presentedAt: Int64
    /// The vblank it was latched at (monotonic ns), and the next one to aim
    /// for.
    public var vblank: Int64
    public var target: Int64
    /// Presents the window may queue now.
    public var credits: UInt32
    public init(presented: Int64, presentedAt: Int64, vblank: Int64, target: Int64, credits: UInt32) {
      self.presented = presented
      self.presentedAt = presentedAt
      self.vblank = vblank
      self.target = target
      self.credits = credits
    }
  }

  public struct ScreenInfo: Equatable, Sendable {
    public var width: UInt32
    public var height: UInt32
    public var windows: UInt32
    public init(width: UInt32, height: UInt32, windows: UInt32) {
      self.width = width
      self.height = height
      self.windows = windows
    }
  }

  /// A window in the list: its content's place on screen.
  public struct WindowInfo: Equatable, Sendable {
    public var id: UInt32
    public var area: Area
    public var focused: Bool
    public var title: String
    public init(id: UInt32, area: Area, focused: Bool, title: String) {
      self.id = id
      self.area = area
      self.focused = focused
      self.title = title
    }
  }

  public struct Opened: ~Copyable {
    /// The window's channel (Window).
    public var window: Handle
    /// Its input ring's VMO (WindowInput), and the counter Radharc adds to
    /// when the client sleeps on the ring: its doorbell.
    public var input: Handle
    public var doorbell: Handle
    public var first: Configure
    public init(window: consuming Handle, input: consuming Handle, doorbell: consuming Handle, first: Configure) {
      self.window = window
      self.input = input
      self.doorbell = doorbell
      self.first = first
    }
  }

  /// A view: its channel (Window), input and first configure as a
  /// window's, and its token.
  public struct OpenedView: ~Copyable {
    public var window: Handle
    public var input: Handle
    public var doorbell: Handle
    public var first: Configure
    /// What a window embeds it by (`Window.embed`): a channel end, whose
    /// peer Radharc keeps. It can't be duplicated: give it whole.
    public var token: Handle
    public init(window: consuming Handle, input: consuming Handle, doorbell: consuming Handle, first: Configure,
                token: consuming Handle)
    {
      self.window = window
      self.input = input
      self.doorbell = doorbell
      self.first = first
      self.token = token
    }
  }

  public protocol Compositor {
    func screen() -> ScreenInfo
    func open(title: String, width: UInt32, height: UInt32) throws(WindowError) -> Opened
    /// A view, `width` by `height` until embedded: a window's
    /// protocol and input, shown only where a window embeds its token.
    func openView(title: String, width: UInt32, height: UInt32) throws(WindowError) -> OpenedView
  }

  public protocol Window {
    func setTitle(_ title: String)
    /// Image `id`: `width` by `height` 32-bit 0x00RRGGBB pixels in `vmo`,
    /// `stride` pixels a row, sRGB, opaque until tagged (`tagImage`).
    func addImage(id: UInt32, vmo: consuming Handle, width: UInt32, height: UInt32, stride: UInt32, acquire: consuming Handle,
                  release: consuming Handle) throws(WindowError)
    func removeImage(id: UInt32)
    /// What image `id`'s pixels mean, from its next present on: with alpha,
    /// their top byte is it. A transfer or primaries other than sRGB's is
    /// refused (`transfer`, `primaries`), and the image keeps its tag.
    @since(2) func tagImage(id: UInt32, tag: PixelTag) throws(WindowError)
    /// Fullscreen: the screen as the window's content, undecorated,
    /// raised and focused, with a configure for the screen's size; or back.
    func setFullscreen(_ on: Bool) throws(WindowError)
    /// `layers` for configure `seq` (drawn at `width` by `height`), shown
    /// at the first vblank after every image's acquire counter reaches
    /// `acquire`, one present a vblank, in order; `damage` in the window's
    /// coordinates (none: all of it). An image's release counter reaches a
    /// present's `number` once a later present stops using it (it is read
    /// until then). Each present takes a credit (`noCredit` if none):
    /// `latency` of them, one back with each `frame`.
    func present(seq: UInt64, width: UInt32, height: UInt32, layers: [Layer], damage: [Area], acquire: Int64,
                 number: Int64) throws(WindowError)
    /// Presents the window may have queued, 1 to 3 (1 at first).
    func setLatency(frames: UInt32) throws(WindowError)
    @event func configure(_ c: Configure)
    /// A present was latched and shown. A hidden window's come about once
    /// a second.
    @event func frame(_ f: Frame)
    /// Its content's top left to (x, y) on the screen, kept where its tab
    /// can still be grabbed (a spatial window opens where it was).
    /// From then on it hears `moved`.
    func place(x: Int32, y: Int32) throws(WindowError)
    /// Its role. `desktop`: undecorated, the screen's size (a
    /// configure follows), beneath every other window; `normal`: back
    /// where it was.
    func setRole(_ role: WindowRole) throws(WindowError)
    /// It moved (its tab dragged, the window list's `move`, or `place`):
    /// its content's top left now. Only to a window that placed itself.
    @event func moved(x: Int32, y: Int32)
    /// Shows the view whose token this is in this window's content at
    /// `area` (its coordinates), as embedding `id` (the caller's; another
    /// view embedded as `id` stops showing); the view is configured for
    /// the area. A token can't be duplicated: `placeEmbedding` moves or
    /// sizes it after.
    func embed(_ token: consuming Handle, id: UInt32, area: Area) throws(WindowError)
    /// Stops showing embedding `id`.
    func unembed(id: UInt32)
    /// Embedding `id`'s view is gone (its client closed it, or ended).
    @event func viewGone(_ id: UInt32)
    /// The app it belongs to, as its user knows it ("Tracker"): the
    /// window list carries it.
    func setApp(_ name: String)
    /// A panel (Deskbar's) or not: undecorated, above every other window,
    /// where it places itself.
    func setPanel(_ on: Bool) throws(WindowError)
    /// The user asked to close it (its tab's close box, or Deskbar's
    /// Close all): its client decides, and closes it or not.
    @event func closeRequested()
    /// A popup of this window (a menu's own surface, shown above every
    /// window, panels too): `width` by `height` at (x, y) in this window's
    /// content, undecorated, following it, shown when it shows and gone
    /// when it goes; a press in it focuses this window, so keys stay here.
    /// `invalid` for a view's or a popup's own.
    func openPopup(title: String, x: Int32, y: Int32, width: UInt32, height: UInt32) throws(WindowError) -> Opened
    /// A popup's place and size again (a configure follows a new size);
    /// `invalid` if this isn't a popup.
    func setPopupArea(x: Int32, y: Int32, width: UInt32, height: UInt32) throws(WindowError)
    /// Its id in the window list (Windows), which the list's verbs take:
    /// rio's wctl sizes, raises and hides its own windows by it.
    @since(3) func listID() -> UInt32
    /// Moves or sizes embedding `id` to `area`, the view configured for
    /// it; `invalid` if this window has no embedding `id`.
    @since(4) func placeEmbedding(id: UInt32, area: Area) throws(WindowError)
    /// Drag and drop: a drag over this window's content, carrying
    /// representations of `types`, the pointer at (x, y) in it; told again
    /// as it moves. The window answers with `acceptDrag`.
    @since(5) @event func dragOver(types: [String], x: Int32, y: Int32)
    /// The drag left this window, or was cancelled over it.
    @since(5) @event func dragLeft()
    /// Dropped here: what the window accepted of `types`, at (x, y). The
    /// window's client may read the entry in its `drop` files until the
    /// window's next input.
    @since(5) @event func drop(types: [String], x: Int32, y: Int32)
    /// The drag this window started ended: dropped where it was accepted,
    /// or not.
    @since(5) @event func dragEnded(dropped: Bool)
    /// What this window would take of the drag over it (none: nothing).
    @since(5) func acceptDrag(types: [String])
  }

  /// The window list and its verbs (rio's wctl, typed).
  public protocol Windows {
    /// Bottom to top.
    func list() -> [WindowInfo]
    /// Its content's top left to (x, y).
    func move(id: UInt32, x: Int32, y: Int32) throws(WindowError)
    /// Asks its client for a new size (a configure).
    func resize(id: UInt32, width: UInt32, height: UInt32) throws(WindowError)
    /// Raised and focused.
    func top(id: UInt32) throws(WindowError)
    /// The list, bottom to top, with each window's app and role (views
    /// aren't windows here).
    func entries() -> [WindowEntry]
    /// Hides a window (Be's minimize; Deskbar's Hide all): not shown,
    /// hit or focused until `show` or `top`.
    func hide(id: UInt32) throws(WindowError)
    /// Shows a hidden window, raised and focused.
    func show(id: UInt32) throws(WindowError)
    /// Asks a window's client to close it (`closeRequested`).
    func close(id: UInt32) throws(WindowError)
    /// Zooms a window (its zoom box): to the screen, or back.
    func zoom(id: UInt32) throws(WindowError)
    /// The hidden windows' ids.
    func hidden() -> [UInt32]
    /// The list changed (a window opened, closed, moved, resized, retitled,
    /// or focus moved): the list now. Changes close together come as one.
    @event func changed(_ windows: [WindowInfo])
  }

  public protocol Handoff {
    /// The console moves into a window of `compositor`.
    func take(compositor: consuming Handle)
  }

  /// A role's colour, 0xAARRGGBB.
  public struct ThemeRole: Sendable {
    public var name: String
    public var color: UInt32
    public init(name: String, color: UInt32) {
      self.name = name
      self.color = color
    }
  }

  /// A material over a part's fill. Lengths and angles are IEEE 754
  /// single-precision bits.
  public struct ThemeMaterial: Sendable {
    /// 1 a gradient (`a` to `b` at angle `x`), 2 a bevel (`style` raised 0,
    /// inset 1 or groove 2, `x` wide), 3 a pattern (`style` stripes 0,
    /// checks 1 or dots 2, of `a` and `b`, `x` apart), 4 a shadow (`a`,
    /// offset by `x` and `y`, blurred over `z`).
    public var kind: UInt8
    public var style: UInt8
    public var a: UInt32
    public var b: UInt32
    public var x: UInt32
    public var y: UInt32
    public var z: UInt32
    public init(kind: UInt8, style: UInt8, a: UInt32, b: UInt32, x: UInt32, y: UInt32, z: UInt32) {
      self.kind = kind
      self.style = style
      self.a = a
      self.b = b
      self.x = x
      self.y = y
      self.z = z
    }
  }

  /// A class's style, resolved. Lengths are logical pixels and, like the
  /// size, line height and tracking, IEEE 754 single-precision bits.
  public struct ThemeStyle: Sendable {
    public var name: String
    public var fill: UInt32
    public var stroke: UInt32
    public var ink: UInt32
    public var border: UInt32
    public var radius: UInt32
    /// Corner cuts, a byte each from the top left, clockwise.
    public var cuts: UInt32
    public var glow: UInt32
    public var glowColor: UInt32
    /// display 0, body 1, mono 2, ui 3.
    public var font: UInt8
    public var weight: UInt16
    public var size: UInt32
    public var lineHeight: UInt32
    public var tracking: UInt32
    public var uppercase: Bool
    /// Top, right, bottom, left.
    public var padding: [UInt32]
    public var materials: [ThemeMaterial]
    public init(name: String, fill: UInt32, stroke: UInt32, ink: UInt32, border: UInt32, radius: UInt32,
                cuts: UInt32, glow: UInt32, glowColor: UInt32, font: UInt8, weight: UInt16, size: UInt32,
                lineHeight: UInt32, tracking: UInt32, uppercase: Bool, padding: [UInt32], materials: [ThemeMaterial])
    {
      self.name = name
      self.fill = fill
      self.stroke = stroke
      self.ink = ink
      self.border = border
      self.radius = radius
      self.cuts = cuts
      self.glow = glow
      self.glowColor = glowColor
      self.font = font
      self.weight = weight
      self.size = size
      self.lineHeight = lineHeight
      self.tracking = tracking
      self.uppercase = uppercase
      self.padding = padding
      self.materials = materials
    }
  }

  /// A typeface, for each font role in its order.
  public struct ThemeFace: Sendable {
    public var family: String
    public var weight: UInt16
    /// The width axis, a percentage of normal.
    public var width: UInt16
    public init(family: String, weight: UInt16, width: UInt16) {
      self.family = family
      self.weight = weight
      self.width = width
    }
  }

  /// A knob of the theme's (D108), as it is set.
  public struct ThemeKnob: Sendable {
    public var name: String
    /// role 0, choice 1, length 2, scale 3.
    public var kind: UInt8
    public var label: String
    public var defaultValue: String
    public var value: String
    public var options: [String]
    /// IEEE 754 double-precision bits.
    public var min: UInt64
    public var max: UInt64
    public init(name: String, kind: UInt8, label: String, defaultValue: String, value: String, options: [String],
                min: UInt64, max: UInt64)
    {
      self.name = name
      self.kind = kind
      self.label = label
      self.defaultValue = defaultValue
      self.value = value
      self.options = options
      self.min = min
      self.max = max
    }
  }

  /// The theme in force, resolved: what radharc(4)'s `theme/resolved`
  /// holds.
  public struct ResolvedTheme: Sendable {
    /// Raised by one at each change.
    public var generation: UInt64
    public var name: String
    public var title: String
    /// "" for none.
    public var variant: String
    /// The type's scale (IEEE 754 single-precision bits).
    public var textScale: UInt32
    public var roles: [ThemeRole]
    public var styles: [ThemeStyle]
    public var faces: [ThemeFace]
    public var knobs: [ThemeKnob]
    public init(generation: UInt64, name: String, title: String, variant: String, textScale: UInt32,
                roles: [ThemeRole], styles: [ThemeStyle], faces: [ThemeFace], knobs: [ThemeKnob])
    {
      self.generation = generation
      self.name = name
      self.title = title
      self.variant = variant
      self.textScale = textScale
      self.roles = roles
      self.styles = styles
      self.faces = faces
      self.knobs = knobs
    }
  }

  /// The resolved theme as it is kept: `theme/resolved` is one message,
  /// this event, read in place by whoever maps the file.
  public protocol ThemeFile {
    @event func resolved(_ theme: ResolvedTheme)
  }
}

// The list's entries compare their names as bytes: String's == needs the
// Unicode tables tier 0 doesn't link.
extension RadharcIPC.WindowInfo {
  public static func == (a: Self, b: Self) -> Bool {
    a.id == b.id && a.area == b.area && a.focused == b.focused && a.title.utf8.elementsEqual(b.title.utf8)
  }
}

extension RadharcIPC.WindowEntry {
  public static func == (a: Self, b: Self) -> Bool {
    a.id == b.id && a.area == b.area && a.focused == b.focused && a.desktop == b.desktop && a.panel == b.panel
      && a.title.utf8.elementsEqual(b.title.utf8) && a.app.utf8.elementsEqual(b.app.utf8)
  }
}

extension RadharcIPC.Opened {
  /// The window's channel, taken out (channels can't be duplicated, and a
  /// field of another module's ~Copyable struct can't be consumed alone).
  /// Duplicate the input ring and doorbell first if you need them.
  public consuming func takeWindow() -> Handle { window }
}

extension RadharcIPC.OpenedView {
  /// A window's opening as a view's, with its token.
  public init(opened: consuming RadharcIPC.Opened, token: consuming Handle) {
    self.init(window: opened.window, input: opened.input, doorbell: opened.doorbell, first: opened.first, token: token)
  }

  /// The view's channel taken out, and its token into `token` (duplicate
  /// the input and doorbell first). Neither can be duplicated, and a
  /// noncopyable tuple can't carry both.
  public consuming func takeWindow(token: inout Handle?) -> Handle {
    token = .some(self.token)
    return window
  }
}
