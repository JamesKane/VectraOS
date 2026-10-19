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
// The console serves `Handoff`: the compositor gives it a channel to
// itself, and the console moves from the framebuffer into a window
// (decided: Radharc owns the framebuffer; the console is its first client).
//
// Not here yet: the privileged services (capture, inject, observe,
// shortcuts) and secure surfaces, which come with the trusted prompt
// (D111); buffer collections and direct scanout, with the display class.

import IPC
import Node

@IPCLibrary(id: "todhchai.radharc", version: 1)
public enum RadharcIPC {
  public enum WindowError: Int32, IPCErrorCode, Sendable {
    case invalid = 1
    case noImage
    case unavailable
    /// A present beyond the window's latency: wait for a `frame`.
    case noCredit
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
    /// `stride` pixels a row, sRGB.
    func addImage(id: UInt32, vmo: consuming Handle, width: UInt32, height: UInt32, stride: UInt32, acquire: consuming Handle,
                  release: consuming Handle) throws(WindowError)
    func removeImage(id: UInt32)
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
    /// `area` (its coordinates), as embedding `id` (the caller's: embed
    /// again to move or size it); the view is configured for the area.
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
