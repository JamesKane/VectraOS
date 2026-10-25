// SPDX-License-Identifier: BSD-3-Clause

// A Kit app in a window of its own, over the SDK (kit(2)): the SDK's
// events become UICore's frame input (the pointer and its buttons, the
// wheel, keys, and typed text from kbdfs's keymap), a frame is built when
// something happened and drawn on the CPU into the window's buffer, and
// presented only if it changed. The theme is the one Radharc has in force,
// followed as it changes (the SDK's `followTheme`), unless the program
// names one; the fonts are the faces its typefaces name, from /lib/fonts.
//
// An idle app waits in the SDK's loop: no wakeups. While an action's
// async handler runs (on the main actor, as the app's model is), the loop
// waits at most 4 ms at a time and yields, so the handler's tasks run;
// a handler that ends asks for a frame.

import GlyphAtlas
import Kbdfs
import Kit
import Node
import OpenType
import enum Radharc.RadharcIPC
import Sys
import TextLayout
import VX

public struct RunOptions {
  public var width: Int32 = 900
  public var height: Int32 = 560
  /// nil: the theme in force, followed.
  public var theme: Theme? = nil
  /// Called after each frame is drawn (tests: when to stop, what to check).
  public var afterFrame: (@MainActor (Runner) -> Bool)? = nil
  /// After each of the window's frames, with the window (its timings;
  /// M6m): true stops.
  public var afterWindowFrame: (@MainActor (KitWindow) -> Bool)? = nil
  /// Each event and frame, as a line (a program's own logging).
  public var trace: (@MainActor (String) -> Void)? = nil
  /// The app its window belongs to, for the window list ("Terminal").
  public var appName = ""
  /// The session, before its window opens.
  public var onSession: ((Session) -> Void)? = nil
  /// At the start: what wakes the loop from any thread (output from a pty
  /// read on a thread of the app's own asks for a frame through it).
  public var onStart: ((@escaping @Sendable () -> Void) -> Void)? = nil
  public init(width: Int32 = 900, height: Int32 = 560, theme: Theme? = nil,
              afterFrame: (@MainActor (Runner) -> Bool)? = nil, trace: (@MainActor (String) -> Void)? = nil)
  {
    self.trace = trace
    self.width = width
    self.height = height
    self.theme = theme
    self.afterFrame = afterFrame
  }
}

/// UICore's key for an SDK key (nil for one it doesn't act on).
func kitKey(_ k: VX.Key) -> UICore.KeyPress? {
  let usage = k.usage, modifiers = k.modifiers
  let shift = modifiers.contains(.shift), control = modifiers.contains(.control), alt = modifiers.contains(.alt)
  let key: UICore.Key
  switch usage {
  case .left: key = .left
  case .right: key = .right
  case .up: key = .up
  case .down: key = .down
  case .home: key = .home
  case .end: key = .end
  case .pageUp: key = .pageUp
  case .pageDown: key = .pageDown
  case .backspace: key = .backspace
  case .delete: key = .delete
  case .enter, .keypadEnter: key = .enter
  case .tab: key = .tab
  case .escape: key = .escape
  case .space: key = .space
  default:
    if usage.rawValue >= KeyUsage.f1.rawValue && usage.rawValue <= KeyUsage.f12.rawValue {
      key = .function(Int(usage.rawValue - KeyUsage.f1.rawValue) + 1)
    } else if k.character >= 0x20 && !isKeyRune(k.character) {
      key = .character(k.character)
    } else {
      return nil
    }
  }
  return KeyPress(key, shift: shift, control: control, alt: alt)
}

/// Plan 9's runes for keys that aren't characters (kbdfs's KeyRune).
func isKeyRune(_ c: UInt32) -> Bool { c >= KeyRune.kf && c < KeyRune.spec + 0x100 }

/// What a key types (nil for none: an editing key, or one with Control or
/// Alt held): its character, shifted by kbdfs's map when Shift is held,
/// and a letter's by Caps Lock, which Shift undoes.
func typed(_ k: VX.Key) -> String? {
  let modifiers = k.modifiers
  guard !modifiers.contains(.control), !modifiers.contains(.alt), k.usage.rawValue < 256 else { return nil }
  let isLetter = k.usage.rawValue >= KeyUsage.a.rawValue && k.usage.rawValue <= KeyUsage.z.rawValue
  let shift = isLetter ? modifiers.contains(.shift) != modifiers.contains(.capsLock) : modifiers.contains(.shift)
  let c = shift ? Keymap.us[.shift, UInt8(k.usage.rawValue)] : k.character
  guard c >= 0x20, c != 0x7F, !isKeyRune(c), let scalar = Unicode.Scalar(c) else { return nil }
  return String(Character(scalar))
}

/// Runs `app` in a window until it's closed (or `afterFrame` says stop).
@MainActor public func run(_ app: any App, fonts: Fonts? = nil, options: RunOptions = RunOptions()) async throws {
  let session = try Session(fonts: fonts, theme: options.theme)
  session.trace = options.trace
  session.appName = options.appName
  options.onSession?(session)
  _ = try session.open(app, width: options.width, height: options.height)
  options.onStart?(session.waker)
  if let after = options.afterFrame { session.afterFrame = { w in after(w.runner) } }
  if let after = options.afterWindowFrame {
    let before = session.afterFrame
    session.afterFrame = { w in
      let stop = before?(w) ?? false
      return after(w) || stop
    }
  }
  await session.run()
}

/// One window of a session: its app, the runner building its frames, and
/// what its next frame takes.
@MainActor public final class KitWindow {
  public let id: WindowID
  public let app: any App
  public let runner: Runner
  var config: Configure?
  /// Its last configure: its size and whether it has focus.
  public var configuration: Configure? { config }
  /// Its size in pixels. Frames are drawn straight into the buffer being
  /// presented, with no canvas of their own (D124: one was a third frame
  /// a window, 4 MB at 1280×820).
  var size = (width: 1, height: 1)
  /// Damage (M6m): what changed in frames built but not yet presented
  /// (input's), and what each of the last presents changed (nil: all of
  /// it), newest last; a buffer presented `age` frames ago is behind by
  /// those, which are drawn again into it. The window must be drawn whole
  /// next (new, or retheme).
  var pendingDamage: Rect?
  var history: [Rect?] = [nil, nil, nil, nil]
  var wholeNext = true
  /// A present changed much (M6m): the next frame presents again at once,
  /// unchanged, so the other buffer is drawn then.
  var catchUp = false
  /// Its open menus' popup (M6m: shown over other windows, the window's
  /// pixels under its area drawn into it; its pointer is the window's, moved by
  /// its place): the popup, its area in points, its configure, and whether
  /// it shows what's drawn. `noPopups`: the platform has none (hosted).
  var popup: (id: WindowID, area: (x: Int, y: Int, width: Int, height: Int), config: Configure?, stale: Bool)?
  var noPopups = false
  var input = FrameInput()
  /// A frame to build.
  var due = true
  /// A frame built and not yet presented (input forced it between two).
  var unpresented = false
  /// The title Radharc was last told (an action may change it after a
  /// frame: M6m, Edit's mark).
  var sentTitle = ""
  /// The frame event's target this frame is drawn for, and the one the
  /// last present was: its next event's `presentedAt` says if it was late.
  var target: Deadline?
  var presentedFor: Deadline?
  /// Frames presented and measured, those late by half a refresh or more
  /// (dropped: a vblank passed without them), and the last frame's
  /// allocations in layout and paint, the pixels' render included (M6m:
  /// the text editor's criteria; 0 while `allocationCount` is nil).
  public internal(set) var measuredFrames = 0
  public internal(set) var droppedFrames = 0
  public internal(set) var frameAllocations: UInt64 = 0
  /// The render's share of them, and the last frame's time (built,
  /// rendered and presented), in nanoseconds.
  public internal(set) var renderAllocations: UInt64 = 0
  public internal(set) var frameTime: UInt64 = 0
  /// The frame's build (the app's views, layout and paint) and its render
  /// (pixels, and the copy to the surface), in nanoseconds.
  public internal(set) var buildTime: UInt64 = 0
  /// The last key's time (its event's), the last frame's finish (built,
  /// rendered, presented), and the last measured present: the target it
  /// was drawn for and when it reached the glass (M6m: key to glyph).
  public internal(set) var keyAt: Deadline?
  public internal(set) var renderedAt: Deadline?
  public internal(set) var lastPresent: (target: Deadline, at: Deadline)?
  public internal(set) var renderTime: UInt64 = 0
  /// Two damages as one (nil, all, wins).
  static func union(_ a: Rect?, _ b: Rect?) -> Rect? {
    guard let a else { return b }
    guard let b else { return a }
    if a.width <= 0 || a.height <= 0 { return b }
    if b.width <= 0 || b.height <= 0 { return a }
    let x0 = min(a.x, b.x), y0 = min(a.y, b.y)
    return Rect(x: x0, y: y0, width: max(a.x + a.width, b.x + b.width) - x0, height: max(a.y + a.height, b.y + b.height) - y0)
  }

  /// A damage's whole pixels in a window of `size`.
  static func pixels(_ r: Rect, _ size: (width: Int, height: Int)) -> (x0: Int, y0: Int, x1: Int, y1: Int) {
    let x0 = max(0, Int(r.x)), y0 = max(0, Int(r.y))
    let x1 = min(size.width, Int(r.x + r.width) + 1), y1 = min(size.height, Int(r.y + r.height) + 1)
    return (x0, y0, max(x0, x1), max(y0, y1))
  }

  /// What counts allocations (none yet).
  public static var allocationCount: (@Sendable () -> UInt64)?
  init(id: WindowID, app: any App, runner: Runner) {
    self.id = id
    self.app = app
    sentTitle = app.title
    self.runner = runner
  }
}

/// Kit apps in windows of one program (M6j: Tracker's folders, each its
/// own window), over one SDK loop. A window opens at a place of its own
/// (`at`: then `onMoved` says where the user moves it) or as the desktop;
/// apps open and close windows from their handlers too. `run` returns when
/// the last window closes, or `stop` is called.
@MainActor public final class Session {
  public private(set) var fonts: Fonts
  public private(set) var theme: Theme
  /// The theme is Radharc's, followed (none was named); the fonts are
  /// chosen for it, unless the program gave its own.
  let following: Bool
  let ownFonts: Bool
  var loop: Loop
  public private(set) var windows: [KitWindow] = []
  var stopped = false
  /// A window that placed itself moved (its content's top left).
  public var onMoved: ((KitWindow, Int32, Int32) -> Void)? = nil
  /// A view a window embedded (its id there) is gone.
  public var onViewGone: ((KitWindow, UInt32) -> Void)? = nil
  /// The user asked to close a window: by default, it closes.
  public var onClose: ((KitWindow) -> Void)? = nil
  /// A file chooser (`choose`) for the window finished: the confined file
  /// channel if chosen, or nil if cancelled.
  public var onChosen: ((KitWindow, consuming Handle?) -> Void)? = nil
  /// After each frame is drawn: true stops the session.
  public var afterFrame: ((KitWindow) -> Bool)? = nil
  /// Before each frame is built (what a program's threads brought).
  public var beforeFrame: ((KitWindow) -> Void)? = nil
  /// Each event and frame, as a line.
  public var trace: ((String) -> Void)? = nil
  /// The app every window it opens belongs to ("Tracker"), for the
  /// window list (Deskbar's running apps); "" says nothing. Its routes'
  /// `src`.
  public var appName = ""
  /// `run` goes on with no window open (a program that opens one when
  /// a route comes: the viewer); else it returns when the last closes.
  public var stayOpen = false
  /// The loop was woken (`waker`, from another thread): what a program
  /// with no window yet looks at (the keyring's questions).
  public var onWake: (() -> Void)? = nil
  /// A message the plumber sent to a port the session listens on
  /// (`listen`).
  public var onRouted: ((ListenID, RouteMessage) -> Void)? = nil
  /// What became of a route an app sent (a context menu's Route, or its
  /// own `route`): nil if the plumber took it, or why it didn't.
  public var onRouteResult: ((Route, RouteError?) -> Void)? = nil
  /// Each key down and up as the SDK gives it, before the app sees it:
  /// true takes it (rio's kbd, which hears the keys held).
  public var onKey: ((KitWindow, VX.Key, _ down: Bool) -> Bool)? = nil

  /// A session in `theme`, or in the theme Radharc has in force, followed
  /// as it changes; with `fonts`, or the faces the theme's typefaces name.
  public init(fonts: Fonts? = nil, theme: Theme? = nil) throws {
    loop = try Loop()
    following = theme == nil
    if following { loop.followTheme() }
    let t = theme ?? loop.theme() ?? .base
    self.theme = t
    ownFonts = fonts != nil
    self.fonts = fonts ?? Session.fonts(for: t)
  }

  /// The faces in /lib/fonts (a directory a family, a file a face).
  public static func installedFonts() -> [Font] {
    guard let ns = processNamespace(), let families = try? ns.list("/lib/fonts") else { return [] }
    var out: [Font] = []
    for family in families {
      let dir = "/lib/fonts/" + family.name
      for face in (try? ns.list(dir)) ?? [] where face.name.hasSuffix(".ttf") || face.name.hasSuffix(".otf") {
        if var f = try? ns.open(dir + "/" + face.name), let bytes = try? f.readAll(), let font = try? Font(bytes) {
          out.append(font)
        }
      }
    }
    return out
  }

  /// The faces `theme`'s typefaces name, from /lib/fonts (read once).
  static func fonts(for theme: Theme) -> Fonts {
    if installed == nil { installed = installedFonts() }
    return Fonts(theme: theme, from: installed ?? [])
  }
  static var installed: [Font]?

  /// The loop's waits that blocked (the SDK's `wakeups`).
  public var wakeups: UInt64 { loop.wakeups }

  /// What wakes the loop from any thread.
  public var waker: @Sendable () -> Void {
    let remote = loop.remote
    return { remote.wake() }
  }

  /// Opens `app` in a window `width` by `height`, at (x, y) on the screen
  /// if given, or as the desktop. The first window waits a few seconds for
  /// a compositor still starting.
  @discardableResult
  public func open(_ app: any App, width: Int32, height: Int32, at place: (x: Int32, y: Int32)? = nil,
                   desktop: Bool = false, panel: Bool = false) throws -> KitWindow
  {
    var id: WindowID? = nil
    let tries = windows.isEmpty ? 100 : 1
    for attempt in 0..<tries {
      do {
        id = try loop.openWindow(app.title, width: width, height: height)
        break
      } catch {
        if attempt == tries - 1 { throw error }
        _ = loop.wait(until: .now + .milliseconds(50))
      }
    }
    let wid = id!
    if desktop { loop.setDesktop(wid, true) }
    if panel { loop.setPanel(wid, true) }
    if !appName.isEmpty { loop.setApp(wid, appName) }
    if let place { loop.placeWindow(wid, x: place.x, y: place.y) }
    return adopt(app, wid, width: width, height: height, scrolls: !desktop && !panel)
  }

  /// Opens `app` in a view `width` by `height`: shown only where a window
  /// embeds its token (`viewToken`), its size the embedding's.
  @discardableResult
  public func openView(_ app: any App, width: Int32, height: Int32) throws -> KitWindow {
    let id = try loop.openView(app.title, width: width, height: height)
    return adopt(app, id, width: width, height: height, scrolls: false)
  }

  /// Adopts a view already opened in Radharc (Tracker's chooser view,
  /// opened by Radharc for the trusted prompt).
  @discardableResult
  public func adoptView(_ app: any App, opened: consuming RadharcIPC.Opened) throws -> KitWindow {
    let w = Int32(opened.first.width), h = Int32(opened.first.height)
    let id = try loop.adoptView(opened, title: app.title)
    return adopt(app, id, width: w, height: h, scrolls: false)
  }

  /// Asks the file chooser for window `w`; `onChosen` receives the chosen
  /// file's channel (or nil if cancelled).
  public func choose(_ w: KitWindow, save: Bool = false, types: [String] = [], name: String = "") throws(WindowError) {
    try loop.choose(w.id, save: save, types: types, name: name)
  }

  /// Radharc draws the time in window `w` at `x`, `y`, `width` by `height`
  /// (logical pixels; D114); an empty area takes it away.
  public func showClock(_ w: KitWindow, x: Int32, y: Int32, width: Int32, height: Int32, hours24: Bool) {
    loop.showClock(w.id, x: x, y: y, width: width, height: height, hours24: hours24)
  }

  /// View `w`'s token, for the window that shows it (once).
  public func viewToken(_ w: KitWindow) -> Handle? { loop.viewToken(w.id) }

  /// Shows a view in window `host`'s content at `x`, `y`, `width` by
  /// `height`, as its embedding `id`, its token given whole.
  public func embed(_ host: KitWindow, token: consuming Handle, id: UInt32, x: Int32, y: Int32, width: Int32,
                    height: Int32) throws(WindowError)
  {
    try loop.embed(host.id, token: token, id: id, x: x, y: y, width: width, height: height)
  }

  /// Window `host`'s embedding `id` moved or sized.
  public func placeEmbedding(_ host: KitWindow, id: UInt32, x: Int32, y: Int32, width: Int32, height: Int32)
    throws(WindowError)
  {
    try loop.placeEmbedding(host.id, id: id, x: x, y: y, width: width, height: height)
  }

  /// Window `host` stops showing its embedding `id`.
  public func unembed(_ host: KitWindow, id: UInt32) { loop.unembed(host.id, id: id) }

  /// A window (or view) the loop opened, run as `app`'s.
  func adopt(_ app: any App, _ wid: WindowID, width: Int32, height: Int32, scrolls: Bool = true) -> KitWindow {
    let remote = loop.remote
    let runner = Runner(app: app, painter: Painter(theme: theme, fonts: fonts,
                                                   cache: GlyphCache(coverageSize: 1024, fieldSize: 256)),
                        width: Float(width), height: Float(height))
    runner.scrolls = scrolls
    runner.ui.allocationCount = KitWindow.allocationCount
    // Cut, Copy and Paste: the clipboard's text (sdk(2)'s Snarf).
    runner.ui.clipboard = Clipboard(read: { Snarf.read() }, write: { Snarf.write($0) })
    runner.wake = { remote.wake() }
    runner.router = { [weak self] r in _ = try? self?.route(r) }
    let w = KitWindow(id: wid, app: app, runner: runner)
    windows.append(w)
    loop.requestFrame(wid)
    return w
  }

  /// Closes a window (its app's handlers settle first).
  public func close(_ w: KitWindow) {
    guard let i = windows.firstIndex(where: { $0 === w }) else { return }
    windows.remove(at: i)
    if let p = w.popup { loop.closeWindow(p.id) }
    loop.closeWindow(w.id)
  }

  // MARK: Popups (M6m)

  /// A popup's events: its pointer the owner's, moved by its place.
  func handlePopup(_ payload: Event.Payload, _ w: KitWindow) {
    guard var p = w.popup else { return }
    switch payload {
    case .configure(let c):
      p.config = c
      p.stale = true
      w.popup = p
      presentPopup(w)
    case .frame:
      presentPopup(w)
    case .pointer(var e):
      let scale = w.config.map { Double($0.pixelWidth) / Double(max($0.width, 1)) } ?? 1
      e.x += Double(p.area.x) * scale
      e.y += Double(p.area.y) * scale
      handle(.pointer(e), w)
    case .wheel:
      handle(payload, w)
    default: break
    }
  }

  /// After a frame of `w`: a popup over its open menus, at their place, or
  /// none.
  func syncPopup(_ w: KitWindow) {
    guard !w.noPopups else { return }
    guard let r = w.runner.ui.overlayArea else {
      if let p = w.popup {
        loop.closeWindow(p.id)
        w.popup = nil
      }
      return
    }
    // Whole points, inside the window (a menu is laid out inside it).
    let x0 = max(0, Int(r.x)), y0 = max(0, Int(r.y))
    let x1 = min(Int(w.runner.ui.width), Int(r.x + r.width) + 1), y1 = min(Int(w.runner.ui.height), Int(r.y + r.height) + 1)
    guard x1 > x0, y1 > y0 else { return }
    let area = (x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    if var p = w.popup {
      if p.area != area {
        loop.setPopupArea(p.id, x: Int32(area.x), y: Int32(area.y), width: Int32(area.width), height: Int32(area.height))
        p.area = area
      }
      p.stale = true
      w.popup = p
    } else {
      do {
        let id = try loop.openPopup(w.id, w.runner.app.title, x: Int32(area.x), y: Int32(area.y), width: Int32(area.width),
                                    height: Int32(area.height))
        w.popup = (id, area, nil, true)
      } catch {
        w.noPopups = true
        return
      }
    }
    presentPopup(w)
  }

  /// The menus' pixels in its popup: the window's last frame drawn again
  /// over the popup's area, straight into the popup's buffer.
  func presentPopup(_ w: KitWindow) {
    guard var p = w.popup, p.stale, let c = p.config, let surface = loop.cpuSurface(p.id) else { return }
    let scale = w.config.map { Float($0.pixelWidth) / Float(max($0.width, 1)) } ?? 1
    let sx = Int(Float(p.area.x) * scale), sy = Int(Float(p.area.y) * scale)
    let rows = min(Int(surface.height), w.size.height - sy), cols = min(Int(surface.width), w.size.width - sx)
    if rows > 0 && cols > 0 {
      var view = unsafe PixelView(surface.pixels.baseAddress!.assumingMemoryBound(to: UInt32.self),
                                  stride: surface.stride / 4, x0: sx, y0: sy, width: sx + cols, height: sy + rows)
      view.fill(x0: sx, y0: sy, x1: sx + cols, y1: sy + rows, theme.color("chrome") & 0xFF_FFFF)
      w.runner.ui.painter.render(into: &view, region: (sx, sy, sx + cols, sy + rows))
    }
    // (Refused, it is drawn again with the next frame.)
    p.stale = (try? loop.present(p.id, surface, configSeq: c.configSeq, damage: nil)) == nil
    w.popup = p
  }

  /// Listens on the plumber's port `port`: its messages come to `onRouted`.
  public func listen(port: String) throws(RouteError) -> ListenID { try loop.listen(port: port) }

  /// Sends `r` to the plumber, whose rules choose its port
  /// (`onRouteResult` hears what became of it).
  public func route(_ r: Route) throws(RouteError) {
    let m = RouteMessage(src: appName, wdir: r.wdir, type: r.type, data: r.data, attrs: r.attributes)
    do throws(RouteError) {
      try loop.route(m)
      trace?("routed \(r.data)")
      onRouteResult?(r, nil)
    } catch {
      trace?("route \(r.data): \(error)")
      onRouteResult?(r, error)
      throw error
    }
  }

  /// Moves a window that placed itself.
  public func place(_ w: KitWindow, x: Int32, y: Int32) { loop.placeWindow(w.id, x: x, y: y) }

  /// The window's id in Radharc's window list (`Loop.listID`).
  public func listID(_ w: KitWindow) -> UInt32? { loop.listID(w.id) }

  /// A frame of window `w`'s, built when its next frame event comes (a
  /// program's own news: M6m's bench).
  public func redraw(_ w: KitWindow) {
    w.due = true
    loop.requestFrame(w.id)
  }

  /// Its title, again (the app's changed).
  public func retitle(_ w: KitWindow) {
    w.sentTitle = w.app.title
    loop.setTitle(w.id, w.sentTitle)
  }

  /// Ends `run` after the current events.
  public func stop() { stopped = true }

  /// Every window drawn again in `theme`, in the faces it names unless
  /// the program gave its own.
  public func retheme(_ t: Theme) {
    theme = t
    if !ownFonts { fonts = Session.fonts(for: t) }
    for w in windows {
      let p = w.runner.ui.painter
      // (A new glyph cache: the faces may be new.)
      w.runner.ui.painter = Painter(theme: t, fonts: fonts, scale: p.scale,
                                    cache: ownFonts ? p.cache : GlyphCache(coverageSize: 1024, fieldSize: 256))
      w.due = true
      w.unpresented = true
      // (Its background too: drawn whole.)
      w.wholeNext = true
      loop.requestFrame(w.id)
    }
  }

  public func run() async {
    main: while !stopped && (stayOpen || !windows.isEmpty) {
      let busy = windows.contains { !$0.runner.running.isEmpty }
      // (Tracing wakes once a second, to show the loop is alive.)
      let events = busy ? loop.wait(until: .now + .milliseconds(4))
        : trace != nil ? loop.wait(until: .now + .seconds(1)) : loop.wait()
      if events.isEmpty { trace?("idle") }
      for e in events {
        trace?("event \(e.payload)")
        switch e.payload {
        case .themeChanged:
          if following, let t = loop.theme() { retheme(t) }
          continue
        case .wake, .message:
          // A wake is the program's, for no window: every window looks again.
          onWake?()
          // (Each asks for its frame: one marked due waited for the next
          // input until M6m, as Terminal's output did.)
          for w in windows {
            w.due = true
            loop.requestFrame(w.id)
          }
          continue
        case .routed(let id, let m):
          onRouted?(id, m)
          for w in windows { w.due = true }
          continue
        default: break
        }
        if let owner = windows.first(where: { $0.popup?.id == e.window }) {
          handlePopup(e.payload, owner)
          continue
        }
        guard let w = windows.first(where: { $0.id == e.window }) else { continue }
        handle(e.payload, w)
        if stopped { break main }
      }
      // Input asks for the next frame; a running handler gets its turn.
      for w in windows where w.due { loop.requestFrame(w.id) }
      if busy { await Task.yield() }
    }
    for w in windows { await w.runner.settle() }
    for w in windows { loop.closeWindow(w.id) }
    windows.removeAll()
  }

  func handle(_ payload: Event.Payload, _ w: KitWindow) {
    switch payload {
    case .configure(let c):
      // Focus alone (the same size): nothing to draw again, but a frame,
      // so what follows a frame hears it.
      if let old = w.config, old.width == c.width, old.height == c.height, old.pixelWidth == c.pixelWidth,
        old.pixelHeight == c.pixelHeight
      {
        w.config = c
        w.due = true
        return
      }
      w.config = c
      w.runner.ui.width = Float(c.width)
      w.runner.ui.height = Float(c.height)
      w.runner.ui.painter.scale = Float(c.pixelWidth) / Float(max(c.width, 1))
      w.size = (Int(c.pixelWidth), Int(c.pixelHeight))
      w.wholeNext = true
      w.due = true
      // A new size needs a buffer drawn for it, even if what's drawn is
      // the same: Radharc shows the old one at its own size meanwhile.
      w.unpresented = true
    case .pointer(let p):
      let scale = w.config.map { Float($0.pixelWidth) / Float(max($0.width, 1)) } ?? 1
      w.input.pointerX = Float(p.x) / scale
      w.input.pointerY = Float(p.y) / scale
      w.input.shift = p.modifiers.contains(.shift)
      w.input.control = p.modifiers.contains(.control)
      // A press and its release in one frame would be lost to the UI (a
      // click is a press seen, then a release): the first has its frame.
      if case .down(.left) = p.action, w.input.released { frame(w, force: true) }
      if case .up(.left) = p.action, w.input.pressed { frame(w, force: true) }
      switch p.action {
      case .down(.left):
        w.input.down = true
        w.input.pressed = true
      case .up(.left):
        w.input.down = false
        w.input.released = true
      case .down(.right): w.input.secondaryPressed = true
      default: break
      }
      w.due = true
    case .wheel(let wheel):
      w.input.scroll += Float(wheel.dy)
      w.input.scrollX += Float(wheel.dx)
      // (Shift and the wheel scroll across: the wheel's own modifiers.)
      w.input.shift = wheel.modifiers.contains(.shift)
      w.due = true
    case .keyDown(let k) where onKey?(w, k, true) == true:
      w.keyAt = k.time ?? Deadline.now
    case .keyUp(let k):
      _ = onKey?(w, k, false)
    case .keyDown(let k):
      w.keyAt = k.time ?? Deadline.now
      if let press = kitKey(k) {
        w.input.keys.append(press)
        w.input.sequence.append(.key(press))
      }
      if let t = typed(k) {
        w.input.text += t
        w.input.sequence.append(.text(t))
      }
      // Offered to the app as it comes (M6m: a terminal's pty hears it at
      // once); taken, it needs no frame of its own: what it changes (the
      // echo) asks for one.
      var keys = FrameInput()
      (keys.keys, keys.text, keys.sequence) = (w.input.keys, w.input.text, w.input.sequence)
      if w.runner.app.takeInput(keys) {
        (w.input.keys, w.input.text, w.input.sequence) = ([], "", [])
      } else {
        w.due = true
      }
    case .moved(let x, let y):
      onMoved?(w, x, y)
    case .viewGone(let id):
      onViewGone?(w, id)
    case .chosen(let ok):
      onChosen?(w, ok ? loop.takeChosen(w.id) : nil)
    case .frame(let f):
      // The last present: on time, or a vblank late (M6m).
      if let drawn = w.presentedFor, let at = f.presentedAt {
        let half = (f.refresh?.nanoseconds ?? 16_666_667) / 2
        w.measuredFrames += 1
        if at.ns > drawn.ns &+ half { w.droppedFrames += 1 }
        w.lastPresent = (drawn, at)
        w.presentedFor = nil
      }
      w.target = f.target
      frame(w)
    case .close:
      if let onClose { onClose(w) } else { close(w) }
    default: break
    }
  }

  func frame(_ w: KitWindow, force: Bool = false) {
    let r = w.runner
    guard let c = w.config else { return }
    if w.due || r.wantsFrame || force {
      beforeFrame?(w)
      w.input.time = Int64(Deadline.now.ns)
      let began = Deadline.now
      let changed = r.frame(w.input)
      w.buildTime = Deadline.now.since(began).nanoseconds
      // What happened is consumed; what's held stays.
      var kept = FrameInput(pointerX: w.input.pointerX, pointerY: w.input.pointerY, down: w.input.down)
      kept.shift = w.input.shift
      kept.control = w.input.control
      w.input = kept
      w.due = false
      // The window may have closed in its own frame.
      guard windows.contains(where: { $0 === w }) else { return }
      if w.app.title != w.sentTitle {
        w.sentTitle = w.app.title
        loop.setTitle(w.id, w.sentTitle)
      }
      // A forced frame (input's) isn't presented: the next one is, changed
      // or not.
      if force {
        if changed, let damage = r.ui.damage { w.pendingDamage = KitWindow.union(w.pendingDamage, damage) }
        w.unpresented = w.unpresented || changed
        w.due = true
        loop.requestFrame(w.id)
        return
      }
      if changed || w.unpresented, let surface = loop.cpuSurface(w.id) {
        w.unpresented = false
        // Only what changed (M6m): this frame's damage and any unpresented
        // frames', or all of it.
        let size = w.size
        let whole = Rect(x: 0, y: 0, width: Float(size.width), height: Float(size.height))
        // (A list that changed with no quad different, only their order,
        // damages nothing: nil here would mean all of it.)
        let none = Rect(x: 0, y: 0, width: 0, height: 0)
        let d: Rect? = w.wholeNext ? nil : KitWindow.union(w.pendingDamage, changed ? r.ui.damage : nil) ?? none
        w.wholeNext = false
        w.pendingDamage = nil
        let renderStart = KitWindow.allocationCount?() ?? 0
        let renderBegan = Deadline.now
        w.presentedFor = w.target
        // The buffer is behind by what its last `age` presents changed, and
        // this one's: drawn into it, the rest of it as it was.
        w.history.removeFirst()
        w.history.append(d)
        var copy: Rect? = d
        let age = Int(surface.age)
        // A large change (a quarter of the window or more, or a buffer
        // never used): presented again at once, so the window's other
        // buffer catches up now, not in a later frame's (a key's) time.
        let big = d.map { $0.width * $0.height * 4 >= whole.width * whole.height } ?? true
        if big || age == 0 { w.catchUp = true } else if w.catchUp {
          w.catchUp = false
        }
        if age == 0 || age > w.history.count { copy = nil } else {
          for h in w.history.suffix(age) {
            guard let h, let c0 = copy else {
              copy = nil
              break
            }
            copy = KitWindow.union(c0, h)
          }
        }
        let rows = min(Int(surface.height), size.height), cols = min(Int(surface.width), size.width)
        let area = KitWindow.pixels(copy ?? whole, size)
        let x1 = min(area.x1, cols), y1 = min(area.y1, rows)
        if x1 > area.x0 && y1 > area.y0 {
          var view = unsafe PixelView(surface.pixels.baseAddress!.assumingMemoryBound(to: UInt32.self),
                                      stride: surface.stride / 4, width: cols, height: rows)
          view.fill(x0: area.x0, y0: area.y0, x1: x1, y1: y1, theme.color("chrome") & 0xFF_FFFF)
          r.ui.painter.render(into: &view, region: (area.x0, area.y0, x1, y1))
        }
        w.renderAllocations = (KitWindow.allocationCount?() ?? 0) &- renderStart
        w.frameAllocations = r.ui.layoutPaintAllocations + w.renderAllocations
        let shown = d.map { r -> (x: Int32, y: Int32, width: Int32, height: Int32) in
          let a = KitWindow.pixels(r, size)
          return (Int32(a.x0), Int32(a.y0), Int32(a.x1 - a.x0), Int32(a.y1 - a.y0))
        }
        do { try loop.present(w.id, surface, configSeq: c.configSeq, damage: shown) } catch {
          // Refused (two frames drawn before Radharc showed one): what this
          // one drew isn't shown, so the next draws all of it.
          w.wholeNext = true
          w.unpresented = true
          w.due = true
        }
        w.renderTime = Deadline.now.since(renderBegan).nanoseconds
        w.renderedAt = Deadline.now
        if w.catchUp {
          w.unpresented = true
          w.due = true
        }
        w.frameTime = Deadline.now.since(began).nanoseconds
        syncPopup(w)
      }
      if let stop = afterFrame, stop(w) { stopped = true }
    }
    if w.due || r.wantsFrame || !r.running.isEmpty { loop.requestFrame(w.id) }
  }
}
