// SPDX-License-Identifier: BSD-3-Clause

// bin/radharc (D107, after todhchai's M4c and desktop.md §1): the
// compositor, CPU-composited on the boot framebuffer. It owns the
// framebuffer: the console becomes its first client through the console's
// `handoff`, and draws into a window from then on. It composes into a
// shadow in memory and copies only the damage to the write-combining
// framebuffer (slow to read, fast to write in runs), and serves
// RadharcIPC: windows, each its own channel, images in clients' VMOs with
// acquire and release counters, layers presented for a configure. It reads
// kbdfs's /dev/kbd and the mouse's /dev/mouse and routes them: keys to the
// focused window's ring, the pointer to the cursor, to window management
// (lib's Scene) and to the window under it, in its own coordinates. Its
// decorations are drawn from the theme in force (D107), Platinum Indigo
// unless another is loaded: it serves the theme tree (ThemeTree, below).
//
// Frames (M4d): nothing is composed when it changes. A change (a present,
// the pointer, a move) adds to the work counter, and the latch thread,
// waiting on it, latches at the next vblank: synthetic at 60 Hz, as the
// boot framebuffer has none, and kept by the thread itself, t0 plus n
// periods slept to (D27: there is no display timeline). It latches
// `latchLead` before the vblank, so that what it composes is out by the
// vblank: it takes each window's oldest present whose images are drawn
// (their acquire counters read, never waited on), composes the damage
// once, copies it out, and sends each of those windows a `frame`: when it
// was shown, the next vblank, its credit back. A window may queue its
// latency's worth of presents (1 to 3). A hidden one's are latched about
// once a second. With nothing changing, it never wakes.
//
// Its tree, each client's own (`export per-client`: the launcher names the
// client): `status` (with the latch's timing), `list` (a line a window,
// bottom to top: id, x, y, width, height, focused, title), `windows`
// (RadharcIPC.Windows: the list and its verbs, to any number of
// subscribers), `pixel` (write "X Y", read the composed pixel there as
// RRGGBB: tests look at the screen through it), `compositor`
// (RadharcIPC.Compositor) and `theme`, the one theme tree mounted.
//
// The trusted prompt (D111): a client whose manifest says `grant windows
// prompt` has `prompt` too, a stream each open of which asks one
// question (lib's Prompt): its write, the question; its read, waiting,
// the answer; its close before then, the question withdrawn. Only
// /dev/kbd's and /dev/mouse's input reaches it, read here; while it is
// up, no window gets any. `pixel` reads it as black, as any capture will.
//
// The clipboard (D112, lib's Clipboard): every client's tree has `snarf`,
// its text, and `clip`, a file a representation and `new`, which takes a
// whole entry. Anyone writes; a read, or `clip`'s listing, is only for the
// client whose window is focused and has had a key or a press since.

import Console
import GlyphAtlas
import IPC
import Kbdfs
import Node
import OpenType
import Radharc
import RadharcGPU
import Settings
import Sys
import Themes
import UICore

/// An image a client shares: its pixels mapped, and its counters.
final class ImageState: @unchecked Sendable {
  let id: UInt32
  let mapping: Mapping
  let acquire: Handle
  let release: Handle
  init(id: UInt32, mapping: consuming Mapping, acquire: consuming Handle, release: consuming Handle) {
    self.id = id
    self.mapping = mapping
    self.acquire = acquire
    self.release = release
  }
}

/// A window's input ring, mapped, and the doorbell to its client.
final class InputOut: @unchecked Sendable {
  let mapping: Mapping
  var ring: InputProducer
  let doorbell: Handle
  init?(mapping: consuming Mapping, doorbell: consuming Handle) {
    guard unsafe WindowInput.create(mapping.address), let ring = unsafe InputProducer(attaching: mapping.address) else {
      return nil
    }
    self.ring = ring
    self.mapping = mapping
    self.doorbell = doorbell
  }
}

/// A present waiting for a vblank.
struct Queued {
  var seq: UInt64
  var size: (width: Int, height: Int)
  var layers: [Layer]
  var damage: Radharc.Rect?
  var acquire: Int64
  var number: Int64
  var used: [UInt32]
  /// The theme generation it is drawn in (D119; 0: the window never said).
  var theme: UInt64 = 0
}

/// The output on the boot framebuffer: write-combining, written in runs.
@safe final class FramebufferOut: @unchecked Sendable {
  let address: UInt
  let stride: Int
  let swap: Bool  // the framebuffer's pixels are 0x00BBGGRR
  /// A display driver's outputs (D120), in its place, if there is one.
  let display: DisplaySink?
  init(_ address: UnsafeMutableRawPointer, stride: Int, swap: Bool, display: DisplaySink? = nil) {
    self.address = UInt(bitPattern: address)
    self.stride = stride
    self.swap = swap
    self.display = display
  }

  func copy(_ d: Radharc.Rect, from shadow: UnsafeMutablePointer<UInt32>, width: Int) {
    if let display {
      unsafe display.copy(d, from: shadow, width: width)
      return
    }
    for y in d.y..<d.maxY {
      let dst = unsafe UnsafeMutablePointer<UInt32>(bitPattern: address + UInt(y * stride * 4))! + d.x
      let src = unsafe shadow + y * width + d.x
      if swap {
        for x in 0..<d.width {
          let p = unsafe src[x]
          unsafe dst[x] = (p >> 16 & 0xFF) | (p & 0xFF00) | (p & 0xFF) << 16
        }
      } else {
        unsafe dst.update(from: src, count: d.width)
      }
    }
  }
}

/// A window's server-side state.
final class WindowState: @unchecked Sendable {
  let id: UInt32
  var images: [ImageState] = []
  let io: InputOut
  var server: UInt64 = 0
  var pending: [RadharcIPC.Configure] = []
  /// Presents not yet latched, oldest first; at most `latency`.
  var queue: [Queued] = []
  var latency = 1
  /// The present on screen: its number and the images it reads.
  var shown: (number: Int64, used: [UInt32])?
  var lastLatched: Int64 = 0
  /// The theme generation its presents are drawn in, and the one shown
  /// (D119; 0: it doesn't follow the theme).
  var drawingTheme: UInt64 = 0
  var shownTheme: UInt64 = 0
  var frames: [RadharcIPC.Frame] = []
  /// A key pressed in it not yet answered on screen: the latches then and
  /// the time, and the time to its next present (terminal key → draw).
  var keyAt: (latch: Int, time: Int64)?
  var keyDrawn: Int64?
  /// Whether a frame of it has been shown (cold start → first frame).
  var everShown = false
  var last = RadharcIPC.Configure(seq: 0, width: 0, height: 0, focused: false)
  /// Where it moved, to tell it (a window that placed itself).
  var moves: [(x: Int32, y: Int32)] = []
  /// A view's token's peer (raw; 0 for a window), kept while it lives.
  var token: UInt32 = 0
  /// The user asked to close it (M6l), to tell it.
  var closeAsked = false
  /// Its embeddings whose views are gone, to tell it.
  var viewsGone: [UInt32] = []
  /// What a drag told it, to tell it, in order.
  var drags: [DragEvent] = []
  /// File chooser results (`true` chosen, `false` cancelled) to tell it,
  /// and the chosen file's channel (raw; 0: none) until `takeChosen`.
  var chosen: [Bool] = []
  var chosenFile: UInt32 = 0
  /// Its frame as drawn for its title, focused and not (Frames.swift),
  /// and those asked of the drawer and not yet drawn.
  var templates: [FrameTemplate] = []
  var asked: [(title: String, focused: Bool)] = []
  /// Its clock's faces drawn (this minute's and the next's), and the
  /// texts asked of the drawer and not yet drawn (D114).
  var clockFaces: [ClockFace] = []
  var clockAsked: [String] = []
  init(id: UInt32, io: InputOut) {
    self.id = id
    self.io = io
  }
  func deliver(_ e: InputEvent) {
    if io.ring.push(e) { try? Counter.add(io.doorbell, 1) }
  }
}

@safe final class State: @unchecked Sendable {
  let lock = Lock()
  let scene: Scene
  var windows: [WindowState] = []
  let shadowAddress: UInt
  var shadow: UnsafeMutablePointer<UInt32> { unsafe UnsafeMutablePointer(bitPattern: shadowAddress)! }
  let framebuffer: FramebufferOut
  var frames = 0
  var probe = (x: 0, y: 0)
  let dispatcher: IPCDispatcher
  /// Added to when there's something for the next vblank.
  let work: Handle
  let period: Int64 = 16_666_667
  /// When vblank 0 was: the synthetic vblanks are t0 plus n periods.
  let t0: Int64
  /// How long before its vblank a frame is latched: composing and copying
  /// out take about 3 ms on the CPU (todhchai's M5l).
  let latchLead: Int64 = 5_000_000
  /// The latch's lateness after its vblank, and its frame's copy done, of
  /// recent frames (ns).
  var lateness: [Int64] = []
  /// Latches begun after their vblank (plugin.replace's frames missed).
  var missedFrames = 0
  /// Keys pressed until their window's next present (ns) and until it was
  /// shown (latches), the last and the most, and how many were timed.
  var keyDraw: (last: Int64, most: Int64, frames: Int, mostFrames: Int, timed: Int) = (0, 0, 0, 0, 0)
  /// The last window shown for the first time: its title, and when.
  var firstShown: (title: String, at: Int64)?
  /// The desktop's window and a panel shown: once both have been, the
  /// desktop is up (boot.desktop, said once).
  var deskShown = false, panelShown = false, desktopUp = false
  var shownAfter: [Int64] = []
  var latches = 0
  /// Input read, and events the windows' rings had no room for.
  var keys = 0
  var pointer = 0
  /// The `windows` service's subscribers (a server each), the list they
  /// were last told of, and its generation.
  var subscribers: [(key: UInt64, server: UInt64, sent: UInt64)] = []
  var nextSubscriber: UInt64 = 0
  var listed: [RadharcIPC.WindowInfo] = []
  var listedHidden: [UInt32] = []
  var listedSpaces: [RadharcIPC.WorkspaceInfo] = []
  var listGeneration: UInt64 = 0
  /// The questions asked on `prompt` and not yet answered, and how many
  /// have been.
  var asks: [PromptAsk] = []
  var choosers: [ChooserAsk] = []
  let chooserLock = Lock()
  var chooser: RadharcIPC.ChooserClient?
  /// Under chooserLock: the chooser is out for a confirm, which waits on
  /// its provider's main thread and so is never made under a lock (that
  /// thread may be waiting on ours); the cancels meant for it meanwhile.
  var chooserOut = false
  var chooserCancels: [UInt64] = []
  /// One confirm at a time; taken under no other lock.
  let confirmLock = Lock()
  var asked = 0
  /// The clipboard, and the reads it refused.
  var clip = Clipboard()
  var clipRefused = 0
  /// The `clipboard` service's entries (D117), and its readers' streams,
  /// told of each.
  var clipFeed = ClipFeed()
  var clipReaders: [(NodeTree, TreeNode)] = []
  /// The lock screen (D118): the `lock` channels open (a ready one can
  /// unlock), and the files to tell of a change; locks, unlocks and
  /// Control-Alt-Deletes; no input for `lockAfter` (ns, 0 never) locks.
  var lockChannels: [LockChannel] = []
  var lockNodes: [(NodeTree, TreeNode)] = []
  var locks = 0, unlocks = 0, attentions = 0
  var lockAfter: Int64 = 600_000_000_000
  /// The space the mouse's absolute positions are in, where it isn't the
  /// desk's (D120: the boot framebuffer's, on a display's outputs).
  var pointerSpace: (width: Int, height: Int)?
  /// The GPU's renderer (D121), where Venus is there.
  var gpu: GPURenderer?
  /// theme.switch (D119): the generation in force and the latch it came
  /// at, until every window that follows the theme shows it; the frames
  /// the last switch took, and the switches timed.
  var themeGeneration: UInt64 = 0
  var themeSince: Int?
  var themeSwitchFrames = 0
  var themeSwitches = 0
  /// The entry a drag under way carries, and the one dropped: readable by
  /// the drop's window's client until that window's next key or press.
  /// The faces in /lib/fonts, and a painter in the theme in force and the
  /// faces its typefaces name: what windows' frames are drawn with (none
  /// read: the scene's own plain frames).
  var faces: [OpenType.Font] = []
  var drawer: FrameDrawer?
  /// D114: the last input, and whether the desktop is idle (no input for
  /// `idleAfter`); the next minute's start, for the clocks, and the
  /// frames that only moved them; the pacing's p99 lateness shown (us).
  /// Each client tree's `idle` and `pacing`, told when they change.
  var lastInput: Int64 = 0
  var idle = false
  let idleAfter: Int64 = 10_000_000_000
  var nextMinute: Int64?
  var clockFrames = 0
  var pacingShown: Int64 = 0
  var watchers: [(tree: NodeTree, idle: TreeNode, pacing: TreeNode)] = []
  var dragEntry: ClipEntry?
  var dropped: (window: UInt32, entry: ClipEntry)?
  var drags = 0, drops = 0
  /// D116: the workspaces' work off the lock (layouts, Settings), the
  /// chords held, and the gated services' questions (Desk.swift).
  let desk = Desk()

  init(width: Int, height: Int, framebuffer: FramebufferOut, dispatcher: IPCDispatcher, work: consuming Handle) {
    self.work = work
    scene = Scene(width: width, height: height)
    shadowAddress = UInt(bitPattern: UnsafeMutablePointer<UInt32>.allocate(capacity: width * height))
    self.framebuffer = framebuffer
    self.dispatcher = dispatcher
    t0 = Clock.monotonic()
  }

  // MARK: The lock screen (D118)

  var canUnlock: Bool { lockChannels.contains { $0.ready } }

  /// Locks, if something can unlock; whether the screen is locked.
  func lockScreen(now: Int64) -> Bool {
    guard !scene.locked else { return true }
    guard canUnlock else { return false }
    scene.setLocked(true, now: now)
    locks += 1
    desk.ask(.store(area: "Lock", name: "Lock:Locked", value: .bool(true)))
    for (t, n) in lockNodes { t.ready(n) }
    noteChanges()
    wake()
    return true
  }

  func unlockScreen(now: Int64) {
    guard scene.locked else { return }
    scene.setLocked(false, now: now)
    unlocks += 1
    desk.ask(.store(area: "Lock", name: "Lock:Locked", value: .bool(false)))
    for (t, n) in lockNodes { t.ready(n) }
    noteChanges()
    wake()
  }

  func vblank(_ n: Int64) -> Int64 { t0 + n * period }
  /// The first vblank at or after `time`.
  func vblankAfter(_ time: Int64) -> Int64 { time <= t0 ? 0 : (time - t0 + period - 1) / period }

  func windowList() -> [RadharcIPC.WindowInfo] {
    scene.windows.filter { !$0.isView && $0.popupOf == nil }.map {
      RadharcIPC.WindowInfo(id: $0.id, area: RadharcIPC.Area(x: Int32($0.content.x), y: Int32($0.content.y),
                                                             width: Int32($0.content.width),
                                                             height: Int32($0.content.height)),
                            focused: $0.id == scene.focused, title: $0.title)
    }
  }

  /// After anything that may change the list: subscribers hear if it did.
  func noteChanges() {
    // Another workspace shown: its theme (D119).
    if scene.current != desk.themedSpace {
      desk.themedSpace = scene.current
      desk.ask(.theme)
    }
    let now = windowList()
    // Hiding and showing are changes too (M6l: Deskbar marks hidden ones).
    let hiddenNow = scene.windows.filter { $0.hidden }.map { $0.id }
    // So are the workspaces (D116: Deskbar shows them).
    let spacesNow = scene.workspaceInfos()
    guard now != listed || hiddenNow != listedHidden || spacesNow != listedSpaces else { return }
    listed = now
    listedHidden = hiddenNow
    listedSpaces = spacesNow
    listGeneration += 1
    for s in subscribers where s.server != 0 { dispatcher.wake(s.server) }
  }

  func window(_ id: UInt32) -> WindowState? { windows.first { $0.id == id } }

  /// Something for the next vblank.
  func wake() { try? Counter.add(work, 1) }

  /// The vblank's work: each window's oldest drawn present (a hidden
  /// window's at most once a second), composed with the rest of the
  /// damage, copied out, and the windows told. Under the lock.
  func latch(vblank: Int64, now: Int64) {
    var latched: [(WindowState, Int64)] = []
    for ws in windows {
      guard let q = ws.queue.first else { continue }
      if scene.isHidden(ws.id) && vblank - ws.lastLatched < 1_000_000_000 - period / 2 { continue }
      let drawn = ws.images.allSatisfy { i in !q.used.contains(i.id) || ((try? Counter.read(i.acquire)) ?? 0) >= q.acquire }
      guard drawn else { continue }
      ws.queue.removeFirst()
      scene.present(ws.id, seq: q.seq, size: q.size, layers: q.layers, damage: q.damage)
      // What the last present read and this one doesn't is free.
      if let shown = ws.shown {
        for i in ws.images where shown.used.contains(i.id) && !q.used.contains(i.id) { release(i, to: shown.number) }
      }
      ws.shown = (q.number, q.used)
      ws.lastLatched = vblank
      if q.theme != 0 { ws.shownTheme = q.theme }
      latched.append((ws, q.number))
    }
    render()
    let done = Clock.monotonic()
    latches += 1
    desk.latched(latches)
    noteThemeSwitch()
    record(&lateness, now - (vblank - latchLead))
    // A latch begun after its vblank: that frame missed it.
    if now > vblank { missedFrames += 1 }
    record(&shownAfter, done - vblank)
    notePacing()
    for (ws, _) in latched {
      if !ws.everShown {
        ws.everShown = true
        firstShown = (scene.window(ws.id)?.title ?? "", done)
      }
      if !desktopUp, let w = scene.window(ws.id) {
        deskShown = deskShown || w.desktop
        panelShown = panelShown || w.panel
      }
      if let k = ws.keyAt, let drawn = ws.keyDrawn {
        let frames = latches - k.latch
        keyDraw = (drawn, max(keyDraw.most, drawn), frames, max(keyDraw.mostFrames, frames), keyDraw.timed + 1)
        ws.keyAt = nil
        ws.keyDrawn = nil
      }
    }
    if deskShown, panelShown, !desktopUp {
      // Monotonic time is from kernel entry: the boot to the desktop.
      desktopUp = true
      print("radharc: desktop up at \(done / 1_000_000) ms")
      print("  budget name=boot.desktop value=\(done) unit=ns limit=3000000000")
    }
    for (ws, number) in latched {
      ws.frames.append(RadharcIPC.Frame(presented: number, presentedAt: max(done, vblank), vblank: vblank,
                                        target: vblank + period,
                                        credits: UInt32(ws.latency - ws.queue.count)))
      if ws.server != 0 { dispatcher.wake(ws.server) }
    }
  }

  /// Raises an image's release counter to `value` (counters only add, D25).
  func release(_ i: ImageState, to value: Int64) {
    let now = (try? Counter.read(i.release)) ?? value
    if value > now { try? Counter.add(i.release, value - now) }
  }

  /// Whether the next vblank has work: damage, or a present to take now.
  /// The time a throttled present comes due, if that's all there is.
  func due(at vblank: Int64) -> Int64? {
    if !scene.damage.isEmpty { return 0 }
    // The timers (D114): idle, and the clocks' next minute, which `tick`
    // turns into damage when it comes.
    var next: Int64? = idle ? nextMinute : min(lastInput + idleAfter, nextMinute ?? .max)
    // The lock's (D118).
    if lockAfter > 0, !scene.locked, canUnlock { next = min(next ?? .max, lastInput + lockAfter) }
    for ws in windows where !ws.queue.isEmpty {
      guard scene.isHidden(ws.id) else { return 0 }
      let at = ws.lastLatched + 1_000_000_000 - period / 2
      if at <= vblank { return 0 }
      next = min(next ?? at, at)
    }
    return next
  }

  func record(_ samples: inout [Int64], _ v: Int64) {
    if samples.count == 120 { samples.removeFirst() }
    samples.append(v)
  }

  /// Composes the damage into the shadow, and copies it to the framebuffer.
  func render() {
    refreshFrames()
    refreshClocks()
    let d = scene.takeDamage()
    guard !d.isEmpty else { return }
    // The GPU's (D121) where there is one, else the CPU's.
    if !(unsafe gpu?.render(scene, damage: d, into: shadow) ?? false) {
      let font = Font.spleen8x16
      unsafe scene.compose(d, into: shadow, stride: scene.width) { c in
        var rows = InlineArray<16, UInt8>(repeating: 0)
        guard let g = font.glyph(c) else { return rows }
        for y in 0..<16 { rows[y] = UInt8(truncatingIfNeeded: font.row(g, y) >> 24) }
        return rows
      }
    }
    unsafe framebuffer.copy(d, from: shadow, width: scene.width)
    frames += 1
  }

  /// Acts on what the scene asked: configures and focus, as events.
  func apply(_ effects: [SceneEffect]) {
    for e in effects {
      switch e {
      case .configure(let id, let w, let h, let seq, let focused):
        guard let ws = window(id) else { continue }
        ws.last = RadharcIPC.Configure(seq: seq, width: UInt32(w), height: UInt32(h), focused: focused)
        queue(ws, ws.last)
      case .focus(let id):
        for ws in windows where ws.last.seq != 0 && ws.last.focused != (ws.id == id) {
          ws.last.focused = ws.id == id
          queue(ws, ws.last)
        }
      case .moved(let id, let x, let y):
        guard let ws = window(id) else { continue }
        ws.moves.append((Int32(x), Int32(y)))
        if ws.server != 0 { dispatcher.wake(ws.server) }
      case .viewGone(let id, let embedding):
        guard let ws = window(id) else { continue }
        ws.viewsGone.append(embedding)
        if ws.server != 0 { dispatcher.wake(ws.server) }
      case .closeRequested(let id):
        guard let ws = window(id) else { continue }
        ws.closeAsked = true
        if ws.server != 0 { dispatcher.wake(ws.server) }
      case .dragOver(let id, let types, let x, let y): tell(id, .over(types, Int32(x), Int32(y)))
      case .dragLeft(let id): tell(id, .left)
      case .drop(let id, let types, let x, let y):
        if let e = dragEntry { dropped = (id, e) }
        dragEntry = nil
        drops += 1
        tell(id, .drop(types, Int32(x), Int32(y)))
      case .dragEnded(let id, let dropped):
        if !dropped { dragEntry = nil }
        tell(id, .ended(dropped))
      case .arrange(let n):
        desk.ask(.arrange(n))
      }
    }
  }

  /// The theme in force: the scene's colours, and a painter for the frames,
  /// each of which is drawn again (under the lock).
  /// A theme's switch is done once every visible window that follows the
  /// theme shows a present drawn in it (D119).
  func noteThemeSwitch() {
    guard let since = themeSince else { return }
    for ws in windows where ws.drawingTheme != 0 && !scene.isHidden(ws.id) && ws.shownTheme < themeGeneration {
      return
    }
    themeSwitchFrames = latches - since
    themeSwitches += 1
    themeSince = nil
  }

  func setTheme(_ theme: Theme, generation: UInt64) {
    themeGeneration = generation
    themeSince = latches
    scene.decorations = Decorations(theme)
    guard !faces.isEmpty else { return }
    if drawer == nil { drawer = FrameDrawer(self) }
    drawer?.use(Painter(theme: theme, fonts: Fonts(theme: theme, from: faces),
                        cache: GlyphCache(coverageSize: 512, fieldSize: 64)))
    for w in scene.windows { scene.setChrome(w.id, nil) }
    for ws in windows {
      ws.templates = []
      ws.asked = []
      ws.clockFaces = []
      ws.clockAsked = []
    }
    for w in scene.windows where w.clock != nil { scene.setClockFace(w.id, nil) }
  }

  /// Each decorated window's frame drawn again if its title, focus or size
  /// changed since it was (under the lock, before the damage is taken).
  /// Its frame drawn by the drawer, on its thread, for its title and
  /// focus once, and made at its size from that here; until it is drawn,
  /// the window keeps the frame it had (or the scene's own, a new one's).
  func refreshFrames() {
    guard let drawer else { return }
    for w in scene.windows where !w.undecorated && !w.isView {
      let focused = w.id == scene.focused
      if let c = w.chrome, c.fits(title: w.title, focused: focused, contentWidth: w.content.width,
                                  contentHeight: w.content.height) { continue }
      guard let ws = window(w.id) else { continue }
      func same(_ t: String) -> Bool { t.utf8.elementsEqual(w.title.utf8) }
      guard let t = ws.templates.first(where: { $0.focused == focused && same($0.title) }) else {
        if !ws.asked.contains(where: { $0.focused == focused && same($0.title) }) {
          ws.asked.append((w.title, focused))
          drawer.ask(window: w.id, title: w.title, focused: focused)
        }
        continue
      }
      scene.setChrome(w.id, WindowChrome(t, contentWidth: w.content.width, contentHeight: w.content.height))
    }
  }

  /// A template drawn: the window's, if it is still there and the theme
  /// the same (under the lock).
  func drawn(_ t: FrameTemplate, window id: UInt32) {
    guard let ws = window(id) else { return }
    ws.asked.removeAll { $0.focused == t.focused && $0.title.utf8.elementsEqual(t.title.utf8) }
    ws.templates = ws.templates.filter { $0.focused != t.focused } + [t]
    wake()
  }

  /// Each clock's face for the time it shows, if drawn; else asked of the
  /// drawer, with the next minute's, drawn ahead (under the lock).
  func refreshClocks() {
    guard let drawer else { return }
    for w in scene.windows {
      guard let c = w.clock, let ws = window(w.id) else { continue }
      let now = scene.clockString(w)
      let next = ClockText.text(minuteOfDay: (scene.clockText.minuteOfDay + 1) % (24 * 60), hours24: c.hours24)
      let (width, height) = (c.area.width, c.area.height)
      if !(w.clockFace?.fits(text: now, width: width, height: height) ?? false),
        let f = ws.clockFaces.first(where: { $0.fits(text: now, width: width, height: height) })
      {
        scene.setClockFace(w.id, f)
      }
      ws.clockFaces.removeAll { !$0.fits(text: now, width: width, height: height) && !$0.fits(text: next, width: width, height: height) }
      for text in [now, next] where !ws.clockFaces.contains(where: { $0.fits(text: text, width: width, height: height) })
        && !ws.clockAsked.contains(where: { $0.utf8.elementsEqual(text.utf8) })
      {
        ws.clockAsked.append(text)
        drawer.ask(clock: w.id, text: text, width: width, height: height)
      }
    }
  }

  /// A clock's face drawn: the window's, if it is still there and the theme
  /// the same (under the lock).
  func drawn(_ f: ClockFace, window id: UInt32) {
    guard let ws = window(id) else { return }
    ws.clockAsked.removeAll { $0.utf8.elementsEqual(f.text.utf8) }
    ws.clockFaces.append(f)
    refreshClocks()
    wake()
  }

  /// The timers on the latch thread's one wait (D114), at `now`: the
  /// desktop idle once `idleAfter` passes without input; the clocks' time
  /// at each minute, and when the next starts.
  func tick(_ now: Int64) {
    if !idle && now - lastInput >= idleAfter {
      idle = true
      for w in watchers { w.tree.ready(w.idle) }
    }
    if lockAfter > 0, !scene.locked, now - lastInput >= lockAfter { _ = lockScreen(now: now) }
    guard scene.windows.contains(where: { $0.clock != nil }) else {
      nextMinute = nil
      return
    }
    let real = Clock.realtime()
    let minute = ClockText.minuteOfDay(real)
    if !scene.clockText.set || scene.clockText.minuteOfDay != minute {
      if scene.clockText.set { clockFrames += 1 }
      scene.clockText = (minute, true)
      refreshClocks()
    }
    nextMinute = now + (60_000_000_000 - real % 60_000_000_000)
  }

  /// Input came (before it is routed): the desktop is active again.
  func input(_ now: Int64) {
    lastInput = now
    guard idle else { return }
    idle = false
    for w in watchers { w.tree.ready(w.idle) }
    wake()  // the idle deadline is armed again
  }

  /// After a latch: the pacing's p99 lateness, told when it moves 100 us.
  func notePacing() {
    let p = pacingP99
    guard p > pacingShown ? p - pacingShown >= 100 : pacingShown - p >= 100 else { return }
    pacingShown = p
    for w in watchers { w.tree.ready(w.pacing) }
  }

  /// The 99th percentile of the recent latches' lateness, in microseconds.
  var pacingP99: Int64 {
    guard !lateness.isEmpty else { return 0 }
    let sorted = lateness.sorted()
    return max(0, sorted[min(sorted.count - 1, sorted.count * 99 / 100)] / 1000)
  }

  /// A drag's event for window `id`.
  func tell(_ id: UInt32, _ e: DragEvent) {
    guard let ws = window(id) else { return }
    ws.drags.append(e)
    if ws.server != 0 { dispatcher.wake(ws.server) }
  }

  /// A key or a press reached window `id`: what was dropped on it can't
  /// be read any more.
  func inputReached(_ id: UInt32) {
    if dropped?.window == id { dropped = nil }
  }

  func queue(_ ws: WindowState, _ c: RadharcIPC.Configure) {
    ws.pending.append(c)
    if ws.server != 0 { dispatcher.wake(ws.server) }
  }

  /// What the prompt's input came to: an answer goes to the open that
  /// asked, whose read waits for it, or confirms/cancels a file chooser.
  /// Under the lock.
  func prompted(_ o: Prompts.Outcome) {
    guard case .answered(let id, let reply) = o else { return }
    if desk.answered(id, reply) { return }
    if let i = asks.firstIndex(where: { $0.id == id }) {
      let ask = asks.remove(at: i)
      ask.reply = reply
      if let node = ask.node { ask.tree.ready(node) }
      return
    }
    guard let i = choosers.firstIndex(where: { $0.id == id }) else { return }
    let c = choosers[i]
    if reply.starts(with: "once".utf8) {
      guard !c.confirming else { return }
      c.confirming = true
      _ = try? Thread.spawn { [self] in
        confirmChooser(c)
      }.release()
    } else {
      choosers.remove(at: i)
      finishChooser(c, file: nil)
    }
  }

  func confirmChooser(_ c: ChooserAsk) {
    let answer = confirmLock.withLock { () -> Result<UInt32, IPCError<RadharcIPC.WindowError>> in
      // (lock and unlock: withLock returns only a copyable value.)
      chooserLock.lock()
      var client = chooser.take()
      chooserOut = client != nil
      chooserLock.unlock()
      guard client != nil else { return .failure(.remote(.unavailable)) }
      let result: Result<UInt32, IPCError<RadharcIPC.WindowError>>
      do throws(IPCError<RadharcIPC.WindowError>) {
        result = .success(try client!.confirm(id: c.id).release())
      } catch {
        result = .failure(error)
      }
      chooserLock.lock()
      chooserOut = false
      // Back, unless another registered meanwhile.
      if chooser == nil { chooser = client.take() }
      if chooser != nil {
        for id in chooserCancels { try? chooser!.cancel(id: id) }
      }
      chooserCancels.removeAll()
      chooserLock.unlock()
      return result
    }
    do throws(IPCError<RadharcIPC.WindowError>) {
      let raw = try answer.get()
      lock.withLock {
        c.confirming = false
        guard let i = choosers.firstIndex(where: { $0 === c }) else {
          _ = Handle(raw: raw)
          return
        }
        choosers.remove(at: i)
        scene.withdraw(c.id, now: Clock.monotonic())
        finishChooser(c, file: raw)
      }
    } catch {
      if case .remote(.invalid) = error {
        lock.withLock {
          c.confirming = false
          wake()
        }
        return
      }
      lock.withLock {
        c.confirming = false
        guard let i = choosers.firstIndex(where: { $0 === c }) else { return }
        choosers.remove(at: i)
        scene.withdraw(c.id, now: Clock.monotonic())
        finishChooser(c, file: nil)
      }
    }
  }

  func finishChooser(_ c: ChooserAsk, file: UInt32?) {
    if file == nil {
      chooserLock.withLock {
        if chooserOut {
          chooserCancels.append(c.id)
        } else if chooser != nil {
          try? chooser!.cancel(id: c.id)
        }
      }
    }
    apply(scene.close(c.view))
    if let ws = window(c.window) {
      if let raw = file {
        if ws.chosenFile != 0 { _ = Handle(raw: ws.chosenFile) }
        ws.chosenFile = raw
        ws.chosen.append(true)
      } else {
        ws.chosen.append(false)
      }
      if ws.server != 0 { dispatcher.wake(ws.server) }
    } else if let raw = file {
      _ = Handle(raw: raw)
    }
    wake()
  }
}

/// One `choose` question on the trusted prompt: its window and its embedded
/// chooser view.
final class ChooserAsk: @unchecked Sendable {
  let id: UInt64
  let window: UInt32
  let view: UInt32
  var confirming = false
  init(id: UInt64, window: UInt32, view: UInt32) {
    self.id = id
    self.window = window
    self.view = view
  }
}

struct ChooserProviderSession: RadharcIPC.ChooserProviderHandler {
  let state: State
  func register(chooser: consuming Handle) {
    let raw = chooser.release()
    state.chooserLock.withLock { state.chooser = .some(RadharcIPC.ChooserClient(channel: Handle(raw: raw))) }
  }
}

/// One open of `prompt`: the question it asked (0 until it writes one),
/// and its answer once given.
final class PromptAsk: @unchecked Sendable {
  let tree: NodeTree
  var node: TreeNode?
  var id: UInt64 = 0
  var reply: [UInt8]?
  var read = false
  init(tree: NodeTree, node: TreeNode?) {
    self.tree = tree
    self.node = node
  }
}

/// One channel at `snarf` or a clipboard file: what it reads, taken from
/// the entry at its first read, and what it writes, collected until it
/// closes.
final class ClipChannel: @unchecked Sendable {
  var bytes: [UInt8]?
  var at = 0
  var writer: ClipWriter
  var refused = false
  init(snarf: Bool) { writer = ClipWriter(snarf: snarf) }
}

/// What a clipboard channel reads.
enum ClipSource {
  /// `snarf`'s text.
  case text
  /// A representation, by its name in `clip`.
  case named(String)
  case nothing
}

/// The clipboard's channel for `client`: reading `source` if it may
/// (D112), and writing an entry (`snarf`'s text or `clip/new`'s entry;
/// nil: not writable), committed when the channel closes.
func clipChannel(_ state: State, client: String, reads source: ClipSource, writes snarf: Bool?) -> NodeStreamChannel {
  let c = ClipChannel(snarf: snarf ?? false)
  let write: (([UInt8]) throws(NodeError) -> UInt32?)? =
    snarf == nil
    ? nil
    : { (bytes: [UInt8]) throws(NodeError) -> UInt32? in
      guard !c.refused else { throw .invalid }
      do throws(ClipRefusal) { try c.writer.write(bytes) } catch {
        c.refused = true
        print("radharc: clip: \(client): \(error.reason)")
        throw .invalid
      }
      return UInt32(bytes.count)
    }
  return NodeStreamChannel(take: { (max: Int) throws(NodeError) -> [UInt8]? in
    if case .nothing = source { return [] }
    return try state.lock.withLock { () throws(NodeError) -> [UInt8]? in
      state.clip.expire(now: Clock.monotonic())
      guard state.scene.mayRead(client: client) else {
        state.clipRefused += 1
        throw .denied
      }
      if c.bytes == nil {
        switch source {
        case .text: c.bytes = state.clip.text
        case .named(let name): c.bytes = state.clip.bytes(named: name) ?? []
        case .nothing: c.bytes = []
        }
      }
      let bytes = c.bytes ?? []
      let end = min(bytes.count, c.at + max)
      defer { c.at = end }
      return Array(bytes[c.at..<end])
    }
  }, write: write, closed: {
    guard c.writer.wrote, !c.refused else { return }
    let entry: ClipEntry
    do throws(ClipRefusal) { entry = try c.writer.finish() } catch {
      print("radharc: clip: \(client): \(error.reason)")
      return
    }
    let now = Clock.monotonic()
    let readers = state.lock.withLock { () -> [(NodeTree, TreeNode)] in
      state.clip.commit(entry, now: now)
      guard !entry.secret else { return [] }
      // Who wrote it (D117): its window's app, and the title of its
      // focused window, or its first.
      let own = state.scene.windows.filter { !$0.isView && same($0.owner, client) }
      let w = own.first { $0.id == state.scene.focused } ?? own.first
      let app = w.map { $0.app.isEmpty ? client : $0.app } ?? client
      state.clipFeed.add(entry, seq: state.clip.commits, source: app, origin: w?.title ?? "")
      return state.clipReaders
    }
    for (tree, node) in readers { tree.ready(node) }
    // A secret entry is cleared after its life, whatever reads it.
    if entry.secret {
      _ = try? Thread.spawn {
        sleep(until: now + Clipboard.secretLife)
        state.lock.withLock { state.clip.expire(now: Clock.monotonic()) }
      }.release()
    }
  })
}

/// One channel at `lock` (D118): ready once it says so.
final class LockChannel: @unchecked Sendable {
  var ready = false
  var sent = ""
}

/// A `lock` channel: reads `locked` or `unlocked`, each read waiting for
/// a change; takes `ready [user=NAME]` and, once ready, `unlock`.
func lockChannel(_ state: State, client: String) -> NodeStreamChannel {
  let c = LockChannel()
  state.lock.withLock { state.lockChannels.append(c) }
  return NodeStreamChannel(take: { (max: Int) throws(NodeError) -> [UInt8]? in
    state.lock.withLock { () -> [UInt8]? in
      let now = state.scene.locked ? "locked\n" : "unlocked\n"
      guard !same(now, c.sent) else { return nil }
      c.sent = now
      return Array(now.utf8.prefix(max))
    }
  }, write: { (bytes: [UInt8]) throws(NodeError) -> UInt32? in
    let word = bytes.split(whereSeparator: { $0 == 0x20 || $0 == 0x0A }).first.map { String(decoding: $0, as: UTF8.self) }
    let ok = state.lock.withLock { () -> Bool in
      if let word, same(word, "ready") {
        c.ready = true
        state.wake()  // the lock's deadline may be armed now
        return true
      }
      guard let word, same(word, "unlock"), c.ready else { return false }
      state.unlockScreen(now: Clock.monotonic())
      return true
    }
    guard ok else {
      print("radharc: lock: \(client): not a word it takes")
      throw .invalid
    }
    return UInt32(bytes.count)
  }, closed: {
    state.lock.withLock { state.lockChannels.removeAll { $0 === c } }
  })
}

/// A `clipboard` channel (D117): each entry committed after it opened
/// that isn't secret, whole, in order; a read waits for the next.
func clipFeedChannel(_ state: State) -> NodeStreamChannel {
  final class Reader: @unchecked Sendable {
    var seq = 0
    var bytes: [UInt8] = []
    var at = 0
  }
  let r = Reader()
  r.seq = state.lock.withLock { state.clip.commits }
  return NodeStreamChannel(take: { (max: Int) throws(NodeError) -> [UInt8]? in
    if r.at == r.bytes.count {
      guard let next = state.lock.withLock({ state.clipFeed.next(after: r.seq) }) else { return nil }
      r.seq = next.seq
      r.bytes = next.bytes
      r.at = 0
    }
    let end = min(r.bytes.count, r.at + max)
    defer { r.at = end }
    return Array(r.bytes[r.at..<end])
  })
}

/// A drag's event for a window, queued for its server.
enum DragEvent {
  case over([String], Int32, Int32)
  case left
  case drop([String], Int32, Int32)
  case ended(Bool)
}

/// A client's `drag`: an entry in `clip/new`'s form, which starts a drag
/// when the channel closes, if the left button is held on one of the
/// client's windows' content since it pressed there.
func dragChannel(_ state: State, client: String) -> NodeStreamChannel {
  let c = ClipChannel(snarf: false)
  return NodeStreamChannel(take: { _ in [] }, write: { (bytes: [UInt8]) throws(NodeError) -> UInt32? in
    guard !c.refused else { throw .invalid }
    do throws(ClipRefusal) { try c.writer.write(bytes) } catch {
      c.refused = true
      print("radharc: drag: \(client): \(error.reason)")
      throw .invalid
    }
    return UInt32(bytes.count)
  }, closed: {
    guard c.writer.wrote, !c.refused, let entry = try? c.writer.finish() else { return }
    state.lock.withLock {
      let types = entry.representations.map { $0.type }
      for w in state.scene.windows where w.owner.utf8.elementsEqual(client.utf8) {
        guard let effects = state.scene.startDrag(source: w.id, types: types) else { continue }
        state.dragEntry = entry
        state.drags += 1
        state.apply(effects)
        state.noteChanges()
        state.wake()
        return
      }
      print("radharc: drag: \(client): no press held on its windows")
    }
  })
}

/// A representation dropped on one of `client`'s windows, by name, while
/// it may still be read.
func dropChannel(_ state: State, client: String, name: String) -> NodeStreamChannel {
  let c = ClipChannel(snarf: false)
  return NodeStreamChannel(take: { (max: Int) throws(NodeError) -> [UInt8]? in
    try state.lock.withLock { () throws(NodeError) -> [UInt8]? in
      if c.bytes == nil {
        guard let d = state.dropped, let w = state.scene.window(d.window), w.owner.utf8.elementsEqual(client.utf8) else { throw .denied }
        c.bytes = d.entry.representations.first { $0.name.utf8.elementsEqual(name.utf8) }?.bytes ?? []
      }
      let bytes = c.bytes ?? []
      let end = min(bytes.count, c.at + max)
      defer { c.at = end }
      return Array(bytes[c.at..<end])
    }
  })
}

/// The clipboard's representations shown in a client's `clip`.
final class ClipShown: @unchecked Sendable {
  var names: [String] = []
}

func rect(_ a: RadharcIPC.Area) -> Radharc.Rect {
  Radharc.Rect(x: Int(a.x), y: Int(a.y), width: Int(a.width), height: Int(a.height))
}

struct WindowSession: RadharcIPC.WindowHandler {
  let state: State
  let ws: WindowState
  let end: WindowEnd
  /// Its client, as the launcher named it.
  let client: String

  func setTitle(_ title: String) {
    state.lock.withLock {
      if let w = state.scene.window(ws.id) {
        state.scene.add(damage: w.frame)
        w.title = title
        state.noteChanges()
        state.wake()
      }
    }
  }

  func addImage(id: UInt32, vmo: consuming Handle, width: UInt32, height: UInt32, stride: UInt32,
                acquire: consuming Handle, release: consuming Handle) throws(RadharcIPC.WindowError)
  {
    guard id != 0, id != Scene.clockImage, width > 0, height > 0, stride >= width, width <= 8192, height <= 8192 else {
      throw .invalid
    }
    let bytes = Int(stride) * Int(height) * 4
    guard let size = try? VMO.size(vmo), size >= bytes,
      let mapping = try? VMO.map(vmo, length: (bytes + 4095) & ~4095, writable: false)
    else {
      throw .invalid
    }
    let pixels = unsafe Pixels(unsafe: mapping.address, width: Int(width), height: Int(height), stride: Int(stride))
    let image = ImageState(id: id, mapping: mapping, acquire: acquire, release: release)
    state.lock.withLock {
      ws.images.removeAll { $0.id == id }
      state.scene.window(ws.id)?.images.removeAll { $0.id == id }
      ws.images.append(image)
      state.scene.window(ws.id)?.images.append((id, pixels))
    }
  }

  func removeImage(id: UInt32) {
    state.lock.withLock {
      // Shown: free from that present on (it's read no more).
      if let shown = ws.shown, shown.used.contains(id) {
        for i in ws.images where i.id == id { state.release(i, to: shown.number) }
      }
      ws.images.removeAll { $0.id == id }
      state.scene.window(ws.id)?.images.removeAll { $0.id == id }
    }
  }

  func tagImage(id: UInt32, tag: RadharcIPC.PixelTag) throws(RadharcIPC.WindowError) {
    // Only sRGB is composed until each output has its colour (D110).
    guard tag.transfer == .srgb else { throw .transfer }
    guard tag.primaries == .bt709 else { throw .primaries }
    let found = state.lock.withLock { state.scene.tag(window: ws.id, image: id, alpha: tag.alpha) }
    guard found else { throw .noImage }
  }

  func setFullscreen(_ on: Bool) throws(RadharcIPC.WindowError) {
    try change { state.scene.setFullscreen(ws.id, on) }
  }

  func present(seq: UInt64, width: UInt32, height: UInt32, layers: [RadharcIPC.Layer], damage: [RadharcIPC.Area],
               acquire: Int64, number: Int64) throws(RadharcIPC.WindowError)
  {
    let d: Radharc.Rect? = damage.isEmpty ? nil : damage.dropFirst().reduce(rect(damage[0])) { $0.union(rect($1)) }
    let q = Queued(seq: seq, size: (Int(width), Int(height)),
                   layers: layers.map { Layer(image: $0.image, color: $0.color, rect: rect($0.area)) }, damage: d,
                   acquire: acquire, number: number, used: layers.map { $0.image }.filter { $0 != 0 })
    let taken = state.lock.withLock { () -> Bool in
      guard ws.queue.count < ws.latency else { return false }
      var q = q
      q.theme = ws.drawingTheme
      ws.queue.append(q)
      if let k = ws.keyAt, ws.keyDrawn == nil { ws.keyDrawn = Clock.monotonic() - k.time }
      return true
    }
    guard taken else { throw .noCredit }
    state.wake()
  }

  func place(x: Int32, y: Int32) throws(RadharcIPC.WindowError) {
    try change { state.scene.place(ws.id, x: Int(x), y: Int(y)) }
  }

  func setRole(_ role: RadharcIPC.WindowRole) throws(RadharcIPC.WindowError) {
    try change { state.scene.setDesktop(ws.id, role == .desktop) }
  }

  func setPanel(_ on: Bool) throws(RadharcIPC.WindowError) {
    try change { state.scene.setPanel(ws.id, on) }
  }

  func openPopup(title: String, x: Int32, y: Int32, width: UInt32, height: UInt32)
    throws(RadharcIPC.WindowError) -> RadharcIPC.Opened
  {
    guard width >= 1, height >= 1, Int(width) <= state.scene.width, Int(height) <= state.scene.height else {
      throw .invalid
    }
    return try startWindow(state: state, client: client, title: title, width: width, height: height,
                           kind: .popup(owner: ws.id, x: Int(x), y: Int(y)), token: 0)
  }

  func setPopupArea(x: Int32, y: Int32, width: UInt32, height: UInt32) throws(RadharcIPC.WindowError) {
    guard width >= 1, height >= 1, Int(width) <= state.scene.width, Int(height) <= state.scene.height else {
      throw .invalid
    }
    try change { state.scene.setPopupArea(ws.id, x: Int(x), y: Int(y), width: Int(width), height: Int(height)) }
  }

  func listID() -> UInt32 { ws.id }

  func choose(mode: RadharcIPC.ChooseMode, types: [String], name: String) throws(RadharcIPC.WindowError) {
    // One at a time: asked, or chosen and not yet taken.
    let already = state.lock.withLock { state.choosers.contains { $0.window == ws.id } || ws.chosenFile != 0 }
    if already { throw .invalid }
    let hasChooser = state.chooserLock.withLock {
      guard state.chooser != nil else { return false }
      return (try? state.chooser!.connection.channel.wait(for: Signals.peerClosed, deadline: 0)) == nil
    }
    guard hasChooser else { throw .unavailable }
    let (w, h, app, qid) = state.lock.withLock {
      let cw = max(1, min(PromptLayout.width, state.scene.width) - 2 * PromptLayout.margin)
      let a = state.scene.window(ws.id)?.app ?? ""
      return (UInt32(cw), UInt32(PromptLayout.chooserHeight), a.isEmpty ? client : a, state.scene.newPromptID())
    }
    var viewID: UInt32 = 0
    var opened: RadharcIPC.Opened? = try startWindow(state: state, client: "tracker",
                                                     title: mode == .save ? "Save File" : "Open File",
                                                     width: w, height: h, kind: .view, token: 0, onID: { viewID = $0 })
    let started = state.chooserLock.withLock { () -> Bool in
      guard let view = opened.take(), state.chooser != nil else { return false }
      return (try? state.chooser!.begin(id: qid, view: view, mode: mode, types: types, name: name, app: app)) != nil
    }
    guard started else {
      state.lock.withLock {
        state.apply(state.scene.close(viewID))
        state.windows.removeAll { $0.id == viewID }
      }
      throw .unavailable
    }
    state.lock.withLock {
      let q = PromptQuestion(choosing: mode == .save, id: qid, asker: client, app: app, types: types, view: viewID)
      state.choosers.append(ChooserAsk(id: qid, window: ws.id, view: viewID))
      state.asked += 1
      state.scene.ask(q, now: Clock.monotonic())
      state.wake()
    }
  }

  func takeChosen() throws(RadharcIPC.WindowError) -> Handle {
    let raw = state.lock.withLock { () -> UInt32 in
      let r = ws.chosenFile
      ws.chosenFile = 0
      return r
    }
    guard raw != 0 else { throw .unavailable }
    return Handle(raw: raw)
  }

  /// Radharc draws the time in `area` of this window's content (D114);
  /// an empty area takes it away.
  func drawnIn(generation: UInt64) { state.lock.withLock { ws.drawingTheme = generation } }

  func showClock(area: RadharcIPC.Area, hours24: Bool) throws(RadharcIPC.WindowError) {
    guard area.width >= 0, area.height >= 0, area.width <= 8192, area.height <= 8192 else { throw .invalid }
    state.lock.withLock {
      let shown = area.width > 0 && area.height > 0
      state.scene.setClock(ws.id, area: shown ? rect(area) : nil, hours24: hours24)
      ws.clockFaces = []
      ws.clockAsked = []
      state.tick(Clock.monotonic())
      state.refreshClocks()
      state.wake()
    }
  }

  func acceptDrag(types: [String]) {
    state.lock.withLock {
      state.scene.acceptDrag(ws.id, types: types)
      state.wake()
    }
  }

  func setApp(_ name: String) {
    // Spatial memory (D116): the app's first window opens where its last
    // one closed, read off the lock.
    let kept = name.isEmpty ? nil : state.desk.ns.flatMap { keptFrame(name, $0) }
    state.lock.withLock {
      guard let w = state.scene.window(ws.id), !w.app.utf8.elementsEqual(name.utf8) else { return }
      w.app = name
      if let kept { placeAtKept(ws.id, name, kept, state) }
      state.noteChanges()
      state.wake()
    }
  }

  /// Shows the view whose token this is (a channel end whose peer is the
  /// end Radharc kept) at `area` of this window's content.
  func embed(_ token: consuming Handle, id: UInt32, area: RadharcIPC.Area) throws(RadharcIPC.WindowError) {
    guard area.width > 0, area.height > 0, area.width <= 8192, area.height <= 8192,
      let peer = try? token.info().relatedKoid
    else { throw .invalid }
    let views = state.lock.withLock { state.windows.filter { $0.token != 0 }.map { ($0.id, $0.token) } }
    var found: UInt32? = nil
    for (vid, raw) in views {
      let kept = Handle(raw: raw)
      if (try? kept.info().koid) == peer { found = vid }
      _ = kept.release()
    }
    guard let view = found else { throw .invalid }
    try change { state.scene.embed(host: ws.id, view: view, id: id, area: rect(area)) }
  }

  func placeEmbedding(id: UInt32, area: RadharcIPC.Area) throws(RadharcIPC.WindowError) {
    guard area.width > 0, area.height > 0, area.width <= 8192, area.height <= 8192 else { throw .invalid }
    try change { state.scene.placeEmbedding(host: ws.id, id: id, area: rect(area)) }
  }

  func unembed(id: UInt32) {
    state.lock.withLock {
      state.scene.unembed(host: ws.id, id: id)
      state.noteChanges()
      state.wake()
    }
  }

  /// A change to the scene: its effects (nil: no such window) applied.
  func change(_ verb: () -> [SceneEffect]?) throws(RadharcIPC.WindowError) {
    let ok = state.lock.withLock { () -> Bool in
      guard let effects = verb() else { return false }
      state.apply(effects)
      state.noteChanges()
      state.wake()
      return true
    }
    guard ok else { throw .invalid }
  }

  func setLatency(frames: UInt32) throws(RadharcIPC.WindowError) {
    guard frames >= 1 && frames <= 3 else { throw .invalid }
    state.lock.withLock { ws.latency = Int(frames) }
  }
}

/// Held by a window's server: when the client closes it, the window goes.
final class WindowEnd: @unchecked Sendable {
  let state: State
  let id: UInt32
  init(state: State, id: UInt32) {
    self.state = state
    self.id = id
  }
  deinit {
    let state = self.state, id = self.id
    state.lock.withLock {
      if let w = state.scene.window(id) { keepFrame(w, state) }
      state.apply(state.scene.close(id))
      // A view's token's peer and any unclaimed chosen file go with it.
      if let ws = state.windows.first(where: { $0.id == id }) {
        if ws.token != 0 { _ = Handle(raw: ws.token) }
        if ws.chosenFile != 0 { _ = Handle(raw: ws.chosenFile) }
      }
      for c in state.choosers where c.window == id || (c.view == id && !c.confirming) {
        state.scene.withdraw(c.id, now: Clock.monotonic())
        state.finishChooser(c, file: nil)
      }
      state.choosers.removeAll { $0.window == id || ($0.view == id && !$0.confirming) }
      state.windows.removeAll { $0.id == id }
      state.noteChanges()
      state.wake()
    }
  }
}

/// The launcher's side: a tree for each client.
struct RadharcClients: LaunchIPC.ClientsHandler {
  let dispatcher: IPCDispatcher
  let populate: (NodeTree, String, [String]) -> Void
  func open(client: String, grants: [String], node: consuming Handle) throws(LaunchIPC.ClientsError) {
    // The prompt, the chooser, layouts, shortcuts, the clipboard's entries
    // and the lock (D111, D116, D117, D118); the other gated services come
    // later.
    let known = ["prompt", "chooser", "layout", "shortcuts", "clipboard", "lock"]
    guard grants.allSatisfy({ g in known.contains { same($0, g) } }) else { throw .refused }
    let tree = NodeTree(dispatcher: dispatcher)
    populate(tree, client, grants)
    do throws(Status) { try tree.serve(node) } catch { throw .refused }
  }
}

struct CompositorSession: RadharcIPC.CompositorHandler {
  let state: State
  /// Who this connection is (the launcher named it: Radharc serves each
  /// client its own tree).
  let client: String

  func screen() -> RadharcIPC.ScreenInfo {
    state.lock.withLock {
      RadharcIPC.ScreenInfo(width: UInt32(state.scene.width), height: UInt32(state.scene.height),
                            windows: UInt32(state.windows.count))
    }
  }

  func open(title: String, width: UInt32, height: UInt32) throws(RadharcIPC.WindowError) -> RadharcIPC.Opened {
    guard width >= 16, height >= 16, Int(width) <= state.scene.width, Int(height) <= state.scene.height else {
      throw .invalid
    }
    return try startWindow(state: state, client: client, title: title, width: width, height: height, kind: .normal,
                           token: 0)
  }

  /// A view (M6j): a window shown only where another embeds its token, a
  /// channel's end; Radharc keeps the other, and knows the view by it.
  func openView(title: String, width: UInt32, height: UInt32) throws(RadharcIPC.WindowError) -> RadharcIPC.OpenedView {
    guard width >= 1, height >= 1, width <= 8192, height <= 8192 else { throw .invalid }
    guard let pair = try? Channel.create() else { throw .unavailable }
    let opened = try startWindow(state: state, client: client, title: title, width: width, height: height, kind: .view,
                                 token: pair.b.release())
    return RadharcIPC.OpenedView(opened: opened, token: pair.a)
  }
}

/// A window's kind as it opens: a window, a view (M6j), or a popup of a
/// window at a place in its content (M6m).
enum WindowKind {
  case normal
  case view
  case popup(owner: UInt32, x: Int, y: Int)
}

/// Opens a window of `kind` for `client`: its scene window, its input
/// ring, and its server; the first configure goes back in the reply.
func startWindow(state: State, client: String, title: String, width: UInt32, height: UInt32, kind: WindowKind,
                 token: UInt32, onID: ((UInt32) -> Void)? = nil) throws(RadharcIPC.WindowError) -> RadharcIPC.Opened
{
  var refused = false
  do throws(Status) {
    let size = (WindowInput.size + 4095) & ~4095
    let vmo = try VMO.create(size: size)
    let mapping = try VMO.map(vmo, length: size)
    let shared = try vmo.duplicate([.transfer, .duplicate, .wait, .inspect, .read, .write, .map, .getProperty])
    let doorbell = try Counter.create()
    let theirs = try doorbell.duplicate([.transfer, .duplicate, .wait, .inspect, .read])
    let channel = try Channel.create()
    guard let io = InputOut(mapping: mapping, doorbell: doorbell) else { throw Status.internal }
    let opened = state.lock.withLock { () -> (WindowState, RadharcIPC.Configure)? in
      let made: (SceneWindow, [SceneEffect])?
      switch kind {
      case .normal: made = state.scene.open(title: title, width: Int(width), height: Int(height))
      case .view: made = state.scene.openView(title: title, width: Int(width), height: Int(height))
      case .popup(let owner, let x, let y):
        made = state.scene.openPopup(owner: owner, title: title, x: x, y: y, width: Int(width), height: Int(height))
      }
      guard let (w, effects) = made else { return nil }
      w.owner = client
      let ws = WindowState(id: w.id, io: io)
      ws.token = token
      state.windows.append(ws)
      state.apply(effects)
      let first = ws.pending.removeFirst()  // the first configure goes back in the reply
      state.noteChanges()
      state.wake()
      return (ws, first)
    }
    guard let (ws, first) = opened else {
      refused = true
      throw Status.notSupported
    }
    onID?(ws.id)
    let server = RadharcIPC.WindowServer(channel: channel.b,
                                         impl: WindowSession(state: state, ws: ws, end: WindowEnd(state: state, id: ws.id),
                                                             client: client))
    let id = try state.dispatcher.add(server) { (s: inout RadharcIPC.WindowServer<WindowSession>) throws(IPCError<Never>) in
      let (pending, frames, moves, gone, closeAsked, drags, chosen) = state.lock.withLock {
        () -> ([RadharcIPC.Configure], [RadharcIPC.Frame], [(x: Int32, y: Int32)], [UInt32], Bool, [DragEvent], [Bool]) in
        defer {
          ws.pending = []
          ws.frames = []
          ws.moves = []
          ws.viewsGone = []
          ws.closeAsked = false
          ws.drags = []
          ws.chosen = []
        }
        return (ws.pending, ws.frames, ws.moves, ws.viewsGone, ws.closeAsked, ws.drags, ws.chosen)
      }
      for d in drags {
        switch d {
        case .over(let types, let x, let y): try RadharcIPC.WindowEventSender.sendDragOver(types: types, x: x, y: y, on: s.connection)
        case .left: try RadharcIPC.WindowEventSender.sendDragLeft(on: s.connection)
        case .drop(let types, let x, let y): try RadharcIPC.WindowEventSender.sendDrop(types: types, x: x, y: y, on: s.connection)
        case .ended(let dropped): try RadharcIPC.WindowEventSender.sendDragEnded(dropped: dropped, on: s.connection)
        }
      }
      for ch in chosen { try RadharcIPC.WindowEventSender.sendChosen(ch, on: s.connection) }
      for g in gone { try RadharcIPC.WindowEventSender.sendViewGone(g, on: s.connection) }
      for c in pending { try RadharcIPC.WindowEventSender.sendConfigure(c, on: s.connection) }
      for f in frames { try RadharcIPC.WindowEventSender.sendFrame(f, on: s.connection) }
      // Only where it is now.
      if let m = moves.last { try RadharcIPC.WindowEventSender.sendMoved(x: m.x, y: m.y, on: s.connection) }
      if closeAsked { try RadharcIPC.WindowEventSender.sendCloseRequested(on: s.connection) }
    }
    state.lock.withLock {
      ws.server = id
      if !ws.pending.isEmpty || !ws.frames.isEmpty { state.dispatcher.wake(id) }
    }
    return RadharcIPC.Opened(window: channel.a, input: shared, doorbell: theirs, first: first)
  } catch {
    throw refused ? .invalid : .unavailable
  }
}

/// Held by a `windows` server: when its client goes, so does the subscriber.
final class SubscriberEnd: @unchecked Sendable {
  let state: State
  let key: UInt64
  init(state: State, key: UInt64) {
    self.state = state
    self.key = key
  }
  deinit {
    let state = self.state, key = self.key
    state.lock.withLock { state.subscribers.removeAll { $0.key == key } }
  }
}

struct WindowsSession: RadharcIPC.WindowsHandler {
  let state: State
  let end: SubscriberEnd

  func list() -> [RadharcIPC.WindowInfo] { state.lock.withLock { state.windowList() } }

  func entries() -> [RadharcIPC.WindowEntry] {
    state.lock.withLock {
      state.scene.windows.filter { !$0.isView && $0.popupOf == nil }.map { w in
        RadharcIPC.WindowEntry(id: w.id, title: w.title, app: w.app,
                               area: RadharcIPC.Area(x: Int32(w.content.x), y: Int32(w.content.y),
                                                     width: Int32(w.content.width), height: Int32(w.content.height)),
                               focused: w.id == state.scene.focused, desktop: w.desktop, panel: w.panel)
      }
    }
  }

  func move(id: UInt32, x: Int32, y: Int32) throws(RadharcIPC.WindowError) {
    try change { state.scene.move(id, x: Int(x), y: Int(y)) }
  }

  func resize(id: UInt32, width: UInt32, height: UInt32) throws(RadharcIPC.WindowError) {
    guard width >= 16, height >= 16, width <= 8192, height <= 8192 else { throw .invalid }
    try change { state.scene.resize(id, width: Int(width), height: Int(height)) }
  }

  func top(id: UInt32) throws(RadharcIPC.WindowError) { try change { state.scene.top(id) } }

  func hide(id: UInt32) throws(RadharcIPC.WindowError) { try change { state.scene.hide(id) } }
  func show(id: UInt32) throws(RadharcIPC.WindowError) { try change { state.scene.show(id) } }
  func close(id: UInt32) throws(RadharcIPC.WindowError) { try change { state.scene.requestClose(id) } }
  func zoom(id: UInt32) throws(RadharcIPC.WindowError) { try change { state.scene.zoom(id) } }
  func hidden() -> [UInt32] {
    state.lock.withLock { state.scene.windows.filter { $0.hidden }.map { $0.id } }
  }

  // D116's verbs, as `ctl`'s words.
  func workspaces() -> [RadharcIPC.WorkspaceInfo] { state.lock.withLock { state.scene.workspaceInfos() } }
  func workspace(_ number: UInt32) throws(RadharcIPC.WindowError) { try verb("workspace \(number)") }
  func send(id: UInt32, to number: UInt32) throws(RadharcIPC.WindowError) { try verb("send \(number) \(id)") }
  func setMode(_ number: UInt32, _ mode: RadharcIPC.WorkspaceMode) throws(RadharcIPC.WindowError) {
    try verb("mode \(mode == .tile ? "tile" : "space") \(number)")
  }
  func act(_ verb: String) throws(RadharcIPC.WindowError) { try self.verb("act " + verb) }
  func verb(_ words: String) throws(RadharcIPC.WindowError) {
    guard state.lock.withLock({ deskVerb(words, state) }) else { throw .invalid }
  }

  /// A verb on the scene: its effects (nil: no such window) applied.
  func change(_ verb: () -> [SceneEffect]?) throws(RadharcIPC.WindowError) {
    let done = state.lock.withLock { () -> Bool in
      guard let effects = verb() else { return false }
      state.apply(effects)
      state.noteChanges()
      state.wake()
      return true
    }
    guard done else { throw .invalid }
  }
}

/// An input event, routed: the pointer moves the cursor and works the
/// scene; keys go to the focused window; the pointer's events go to the
/// window under it, in its content's coordinates. Under the lock.
func route(_ e: InputEvent, _ state: State) {
  let scene = state.scene
  // The mouse's absolute positions are in the boot framebuffer's pixels:
  // on a display's outputs (D120), the desk's.
  var e = e
  if e.kind == .pointerAbsolute, let from = state.pointerSpace, from.width > 0, from.height > 0 {
    e.x = Int32(Int(e.x) * scene.width / from.width)
    e.y = Int32(Int(e.y) * scene.height / from.height)
  }
  let now = Clock.monotonic()
  state.input(now)
  // Control-Alt-Delete (D118): Radharc's alone, always. Unlocked, it
  // locks; locked, it empties the unlock field.
  let both = InputEvent.Modifier.control | InputEvent.Modifier.alt
  if e.kind == .keyDown || e.kind == .keyUp, e.code == 0x4C, e.modifiers & both == both {
    state.keys += 1
    if e.kind == .keyDown, e.flags & InputEvent.isRepeat == 0 {
      state.attentions += 1
      if scene.locked { scene.clearUnlock(now: now) } else { _ = state.lockScreen(now: now) }
    }
    state.wake()
    return
  }
  // Locked with no question up: nothing hears anything.
  if scene.locked && scene.prompts.showing == nil {
    switch e.kind {
    case .keyDown, .keyUp: state.keys += 1
    case .pointerMotion: _ = scene.moveBy(Int(e.ax), Int(e.ay))
    case .pointerAbsolute: _ = scene.moveTo(Int(e.x), Int(e.y))
    default: break
    }
    state.wake()
    return
  }
  // The prompt up: the pointer moves the cursor and works it, and no
  // window hears anything (except a chooser prompt's embedded view).
  if let q = scene.prompts.showing {
    let view = q.view != 0 ? state.window(q.view) : nil
    let chooser = scene.promptLayout?.chooser
    switch e.kind {
    case .keyDown, .keyUp:
      state.keys += 1
      if e.code != 0x29, let view { view.deliver(e) }
    case .pointerMotion:
      state.pointer += 1
      _ = scene.moveBy(Int(e.ax), Int(e.ay))
      if let view, let c = chooser {
        var out = e
        out.kind = .pointerAbsolute
        out.x = Int32(scene.pointer.x - c.x)
        out.y = Int32(scene.pointer.y - c.y)
        view.deliver(out)
      }
    case .pointerAbsolute:
      state.pointer += 1
      _ = scene.moveTo(Int(e.x), Int(e.y))
      if let view, let c = chooser {
        var out = e
        out.x = Int32(scene.pointer.x - c.x)
        out.y = Int32(scene.pointer.y - c.y)
        view.deliver(out)
      }
    case .buttonDown, .buttonUp:
      state.pointer += 1
      if let view, let c = chooser, c.contains(scene.pointer.x, scene.pointer.y) || e.kind == .buttonUp {
        var out = e
        out.x = Int32(scene.pointer.x - c.x)
        out.y = Int32(scene.pointer.y - c.y)
        view.deliver(out)
      }
      if e.code == 1 { state.prompted(scene.promptButton(down: e.kind == .buttonDown, now: Clock.monotonic())) }
    case .wheel:
      state.pointer += 1
      if let view, let c = chooser, c.contains(scene.pointer.x, scene.pointer.y) { view.deliver(e) }
    }
    state.wake()
    return
  }
  switch e.kind {
  case .keyDown, .keyUp:
    state.keys += 1
    // Chords first (D116): a holder's chord goes to it and nowhere else.
    if chordTaken(e, state) { break }
    // Escape cancels a drag, and goes no further.
    if scene.drag != nil && e.code == 0x29 {
      if e.kind == .keyDown { state.apply(scene.cancelDrag()) }
      break
    }
    if let ws = state.window(scene.focused) {
      ws.deliver(e)
      if e.kind == .keyDown {
        if ws.keyAt == nil { ws.keyAt = (state.latches, Clock.monotonic()) }
        scene.gave(ws.id)
        state.inputReached(ws.id)
      }
    }
  case .pointerMotion:
    state.pointer += 1
    state.apply(scene.moveBy(Int(e.ax), Int(e.ay)))
    pointerToWindow(e, state)
  case .pointerAbsolute:
    // The mouse's pixels: the screen is the framebuffer both know.
    state.pointer += 1
    state.apply(scene.moveTo(Int(e.x), Int(e.y)))
    pointerToWindow(e, state)
  case .buttonDown, .buttonUp:
    state.pointer += 1
    if e.code == 1 { state.apply(scene.button(down: e.kind == .buttonDown)) }
    pointerToWindow(e, state)
  case .wheel:
    state.pointer += 1
    pointerToWindow(e, state)
  }
  state.noteChanges()
  state.wake()
}

func pointerToWindow(_ e: InputEvent, _ state: State) {
  guard let t = state.scene.pointerTarget() else { return }
  var out = e
  if e.kind == .pointerMotion || e.kind == .pointerAbsolute || e.kind == .buttonDown || e.kind == .buttonUp {
    out.kind = e.kind == .pointerMotion ? .pointerAbsolute : e.kind
    out.x = Int32(t.x)
    out.y = Int32(t.y)
  }
  guard let ws = state.window(t.window) else { return }
  ws.deliver(out)
  if e.kind == .buttonDown {
    state.scene.gave(ws.id)
    state.inputReached(ws.id)
  }
}

/// The latch's timing for `status`: medians and maxima of recent frames.
func timing(_ state: State, _ admission: String) -> String {
  func stat(_ v: [Int64]) -> String {
    guard !v.isEmpty else { return "-" }
    let s = v.sorted()
    return "median \(s[s.count / 2] / 1000) us max \(s[s.count - 1] / 1000) us"
  }
  return "vblank synthetic \(state.period) ns\nlatch \(admission)\nlatches \(state.latches)\n"
    + "late \(stat(state.lateness))\nshown \(stat(state.shownAfter))\n"
}

func hexColor(_ p: UInt32) -> String {
  let digits = Array("0123456789abcdef".utf8)
  var out: [UInt8] = []
  for shift in stride(from: 20, through: 0, by: -4) { out.append(digits[Int((p >> UInt32(shift)) & 0xF)]) }
  return String(decoding: out, as: UTF8.self)
}

/// Reads `path` for good on a thread of its own, giving each read's bytes
/// to `body` under the state's lock: /dev/kbd's and /dev/mouse's readers.
func reading(_ ns: Namespace, _ path: String, _ state: State, _ body: @escaping @Sendable ([UInt8]) -> Void) -> Bool {
  guard var file = try? ns.open(path) else { return false }
  let raw = file.takeChannel().release()
  do throws(Status) {
    _ = try Thread.spawn {
      var file = NodeIPC.NodeClient(channel: Handle(raw: raw))
      while let bytes = try? file.read(offset: 0, max: 256), !bytes.isEmpty {
        state.lock.withLock { body(bytes) }
      }
      print("radharc: \(path) ended")
    }.release()
  } catch {
    return false
  }
  return true
}

/// A reader of `theme/events`: the lines it hasn't read yet.
final class ThemeReader: @unchecked Sendable {
  var bytes: [UInt8] = []
}

/// The theme tree (theming.md §3): one, mounted at `theme` in every
/// client's tree. `active` (the theme in force), `themes/` (each installed
/// theme's file), `ctl` (ThemeControl's commands; a read gives why the last
/// one was refused), `events` (a line a change, each reader its own) and
/// `resolved` (the theme in force as one wire message, memory to map). A
/// change redraws the decorations.
@safe final class ThemeTree: @unchecked Sendable {
  let lock = Lock()
  var control: ThemeControl
  let tree: NodeTree
  let state: State
  var readers: [ThemeReader] = []
  var events: TreeNode? = nil
  var resolved: TreeNode? = nil

  /// The themes it can load: fixed when it starts.
  let names: [String]

  init(state: State, dispatcher: IPCDispatcher, control: ThemeControl) {
    self.state = state
    self.control = control
    names = control.names
    tree = NodeTree(dispatcher: dispatcher)
    for t in control.installed { tree.file("themes/" + t.name, t.text) }
    tree.text("active", read: { self.lock.withLock { self.control.active } })
    tree.text("ctl", read: { self.lock.withLock { self.control.refusal.map { $0 + "\n" } ?? "" } },
              write: { (text: String) throws(NodeError) in try self.command(text) })
    events = tree.stream("events", NodeStream(perChannel: {
      let reader = ThemeReader()
      self.lock.withLock { self.readers.append(reader) }
      return NodeStreamChannel(take: { max in
        self.lock.withLock { () -> [UInt8]? in
          guard !reader.bytes.isEmpty else { return nil }
          let n = min(max, reader.bytes.count)
          defer { reader.bytes.removeFirst(n) }
          return Array(reader.bytes[..<n])
        }
      }, closed: { self.lock.withLock { self.readers.removeAll { $0 === reader } } })
    }))
    publish()
  }

  /// A ctl write: the theme changes, or the write fails and its readers
  /// hear why.
  /// Whether `name` is a theme it can load (any thread, any lock).
  func installed(_ name: String) -> Bool { names.contains { same($0, name) } }

  /// The theme Settings hold (D119): in force if it changed.
  func settle(theme: String, highContrast: Bool, knobs: [(name: String, value: String)]) {
    let changed = lock.withLock { () -> Bool in
      do throws(ThemeCommandError) {
        return try control.settle(theme: theme, highContrast: highContrast, knobs: knobs)
      } catch {
        print("radharc: theme: \(error.reason)")
        return false
      }
    }
    if changed { publish() }
  }

  func command(_ text: String) throws(NodeError) {
    let refused = lock.withLock { () -> String? in
      do throws(ThemeCommandError) {
        _ = try control.command(text)
        // What it set is kept as Settings' (D119): the theme, high
        // contrast, the accent.
        let w = text.utf8.split(whereSeparator: { $0 == 0x20 || $0 == 0x0A }).map { String(decoding: $0, as: UTF8.self) }
        var keep: (String, SettingValue)?
        if w.count == 2, same(w[0], "load") {
          keep = (Settings.theme.name, .string(w[1]))
        } else if w.count == 2, same(w[0], "contrast") {
          keep = (Settings.highContrast.name, .bool(same(w[1], "on")))
        } else if w.count == 3, same(w[0], "knob"), same(w[1], "accent") {
          let v = w[2].utf8.starts(with: "accent.".utf8) ? String(decoding: w[2].utf8.dropFirst(7), as: UTF8.self) : "theme"
          keep = (Settings.accent.name, .string(v))
        }
        if let keep { state.lock.withLock { state.desk.ask(.store(area: "Appearance", name: keep.0, value: keep.1)) } }
        return nil
      } catch {
        tell("refused \(error.reason)\n")
        return error.reason
      }
    }
    guard refused == nil else {
      print("radharc: theme: \(refused!)")
      throw .invalid
    }
    publish()
  }

  /// To every reader of `events` (under the lock).
  func tell(_ line: String) {
    for r in readers { r.bytes += Array(line.utf8) }
    if let events { tree.ready(events) }
  }

  /// The theme in force out: `resolved`, the decorations, and a line to
  /// `events`.
  func publish() {
    let (theme, wire, line) = lock.withLock { () -> (Theme, [UInt8]?, String) in
      let c = control
      let line = "theme \(c.name) variant \(c.variant ?? "none") generation \(c.generation)"
      tell(line + "\n")
      return (c.theme, RadharcIPC.ResolvedTheme(c.theme, generation: c.generation).encoded(), line)
    }
    if let wire {
      do throws(Status) {
        let vmo = try VMO.create(size: wire.count)
        let m = try VMO.map(vmo, length: (wire.count + 4095) & ~4095)
        m.write(wire, at: 0)
        if let resolved { tree.setMemory(resolved, vmo, size: UInt64(wire.count)) } else {
          resolved = tree.memory("resolved", vmo, size: UInt64(wire.count), executable: false)
        }
      } catch {
        print("radharc: theme: can't keep the resolved theme: \(error.rawValue)")
      }
    } else {
      print("radharc: theme: the resolved theme is larger than a message")
    }
    let generation = lock.withLock { control.generation }
    state.lock.withLock { state.setTheme(theme, generation: generation) }
    state.wake()
    print("radharc: \(line)")
  }
}

/// Windows' frames drawn off the latch thread: a thread of its own with
/// the painter, which keeps its glyphs and their places together, taking
/// the windows' asks in turn. A new theme's painter drops what was asked.
final class FrameDrawer: @unchecked Sendable {
  /// A window's frame for a title and focus, or its clock's face for a
  /// time and an area's size (D114).
  enum Job {
    case frame(window: UInt32, title: String, focused: Bool)
    case clock(window: UInt32, text: String, width: Int, height: Int)
  }
  let lock = Lock()
  var painter: Painter?
  var generation = 0
  var jobs: [Job] = []
  let bell: UInt32
  var rung: Int64 = 0

  init?(_ state: State) {
    guard let c = try? Counter.create() else { return nil }
    bell = c.release()
    let bell = bell
    _ = try? Thread.spawn { [self] in
      var seen: Int64 = 0
      while true {
        let next = lock.withLock { () -> (Int, Job, Painter)? in
          guard !jobs.isEmpty, let p = painter else { return nil }
          return (generation, jobs.removeFirst(), p)
        }
        guard let (g, job, p) = next else {
          let counter = Handle(raw: bell)
          _ = try? Counter.wait(counter, until: seen + 1)
          seen = (try? Counter.read(counter)) ?? seen + 1
          _ = counter.release()
          continue
        }
        var painter = p
        switch job {
        case .frame(let window, let title, let focused):
          let t = FrameTemplate(&painter, title: title, focused: focused)
          if keep(g, painter) { state.lock.withLock { state.drawn(t, window: window) } }
        case .clock(let window, let text, let width, let height):
          let f = ClockFace(&painter, text: text, width: width, height: height)
          if keep(g, painter) { state.lock.withLock { state.drawn(f, window: window) } }
        }
      }
    }.release()
  }

  /// Its glyphs kept for the next, unless the theme changed meanwhile:
  /// whether what was drawn is still wanted.
  func keep(_ g: Int, _ p: Painter) -> Bool {
    lock.withLock { () -> Bool in
      guard g == generation else { return false }
      painter = p
      return true
    }
  }

  /// The theme's painter from now on; what was asked before is dropped.
  func use(_ p: Painter) {
    lock.withLock {
      painter = p
      generation += 1
      jobs = []
    }
    ring()
  }

  func ask(window: UInt32, title: String, focused: Bool) {
    lock.withLock { jobs.append(.frame(window: window, title: title, focused: focused)) }
    ring()
  }

  func ask(clock window: UInt32, text: String, width: Int, height: Int) {
    lock.withLock { jobs.append(.clock(window: window, text: text, width: width, height: height)) }
    ring()
  }

  func ring() {
    let counter = Handle(raw: bell)
    try? Counter.add(counter, 1)
    _ = counter.release()
  }
}

/// The faces in /lib/fonts (a directory a family, a file a face).
func faces(_ ns: Namespace) -> [OpenType.Font] {
  guard let families = try? ns.list("/lib/fonts") else { return [] }
  var out: [OpenType.Font] = []
  for family in families {
    let dir = "/lib/fonts/" + family.name
    // (Bytes compared: tier 0 has no Unicode tables.)
    for face in (try? ns.list(dir)) ?? []
    where face.name.utf8.reversed().starts(with: ".ttf".utf8.reversed())
      || face.name.utf8.reversed().starts(with: ".otf".utf8.reversed()) {
      if var f = try? ns.open(dir + "/" + face.name), let bytes = try? f.readAll(), let font = try? OpenType.Font(bytes) {
        out.append(font)
      }
    }
  }
  return out
}

/// Whether devmgr is still binding drivers (its status hasn't said
/// `bound N` yet): a display may still come.
func devmgrBinding(_ ns: Namespace) -> Bool {
  guard var f = try? ns.open("/svc/devmgr/status"), let text = try? f.readAll() else { return false }
  return !text.split(separator: 0x0A).contains { $0.starts(with: Array("bound ".utf8)) }
}

@main struct RadharcService {
  static func main() {
    let start = Startup.current
    let ns: Namespace
    do throws(NamespaceError) { ns = try Namespace(start) } catch { Process.fail("no namespace") }
    let dispatcher: IPCDispatcher
    let work: Handle
    do throws(Status) {
      dispatcher = try IPCDispatcher()
      work = try Counter.create()
    } catch { Process.fail("can't make a dispatcher") }
    let workRaw = work.raw

    // The boot framebuffer, as the console maps it.
    guard let mmio = start.take(HandleType.info(HandleType.resource(.mmio))) else {
      Process.fail("no MMIO resource (its manifest's `resource mmio`)")
    }
    guard let bootData = start.take(HandleType.info(HandleType.vmoBootData)) else {
      Process.fail("no boot data (its manifest's `bootdata`)")
    }
    guard let fb = BootFramebuffer(bootData: bootData), let format = PixelFormat(zbi: fb.format) else {
      Process.fail("no linear framebuffer in the boot data")
    }
    let pageBase = fb.base & ~4095
    let size = Int((fb.base - pageBase + UInt64(fb.stride * fb.height * 4) + 4095) & ~4095)
    let mapping: Mapping
    do throws(Status) {
      let resource = try Sys.Resource.create(parent: mmio, kind: .mmio, base: pageBase, size: UInt64(size),
                                             name: "framebuffer")
      let vmo = try VMO.physical(resource: resource, address: pageBase, size: size)
      try VMO.setCachePolicy(vmo, .writeCombining)
      mapping = try VMO.map(vmo, length: size)
    } catch {
      Process.fail("can't map the framebuffer: \(error.rawValue)")
    }
    // A display driver's outputs (D120), once devmgr has bound one: it
    // binds as it goes, so a few seconds are given it; else the boot
    // framebuffer.
    var sink: DisplaySink?
    var displayName = "display0"
    if (try? ns.list("/dev")) != nil {
      let until = Clock.monotonic() + 5_000_000_000
      while sink == nil && Clock.monotonic() < until {
        if let found = DisplaySink.first(ns) {
          sink = found.sink
          displayName = found.name
        } else {
          guard devmgrBinding(ns) else { break }
          sleep(until: Clock.monotonic() + 100_000_000)
        }
      }
    }
    let out = unsafe FramebufferOut(mapping.address + Int(fb.base - pageBase), stride: fb.stride,
                                    swap: format == .bgr888x, display: sink)
    let state = State(width: sink?.width ?? fb.width, height: sink?.height ?? fb.height, framebuffer: out,
                      dispatcher: dispatcher, work: work)
    if let sink {
      followOutputs(ns, "/dev/\(displayName)/display", sink, state.lock)
      state.pointerSpace = (fb.width, fb.height)
      // A GPU with Venus composes (D121); else the CPU.
      state.gpu = GPURenderer.open(ns, width: state.scene.width, height: state.scene.height)
    }
    // The faces windows' titles are drawn in (its manifest's /lib/fonts).
    state.faces = faces(ns)
    print("radharc: \(state.faces.count) faces for the windows' frames")
    let display = sink.map { "\(displayName) outputs \($0.summary)" }
      ?? "framebuffer \(fb.width)x\(fb.height) stride \(fb.stride) \(format == .rgbx888 ? "rgbx888" : "bgr888x")"

    // The latch thread: at the vblank after each change.
    let latchThread: Handle
    do throws(Status) {
      latchThread = try Thread.spawn {
        let work = Handle(raw: workRaw)  // borrowed: the state keeps it
        var seen: Int64 = 0  // the work counter's value last looked at
        var latched: Int64 = 0  // the last vblank latched
        while true {
          // Until there's work, or a throttled present comes due.
          let now = Clock.monotonic()
          let due = state.lock.withLock { () -> Int64? in
            state.tick(now)
            return state.due(at: state.vblank(state.vblankAfter(now) + 1))
          }
          if due != 0 {
            _ = try? Counter.wait(work, until: seen + 1, deadline: due ?? infiniteDeadline)
            seen = (try? Counter.read(work)) ?? seen
            let again = state.lock.withLock { () -> Int64? in
              let woke = Clock.monotonic()
              state.tick(woke)
              return state.due(at: woke + state.period)
            }
            if again != 0 { continue }
          } else {
            seen = (try? Counter.read(work)) ?? seen
          }
          // The next vblank that can still be made and isn't latched yet,
          // latched its lead before.
          var n = max(state.vblankAfter(Clock.monotonic() + state.latchLead), latched + 1)
          if Clock.monotonic() > state.vblank(n) - state.latchLead { n += 1 }
          latched = n
          let vblank = state.vblank(n)
          sleep(until: vblank - state.latchLead)
          let woke = Clock.monotonic()
          state.lock.withLock { state.latch(vblank: vblank, now: woke) }
        }
      }
    } catch {
      Process.fail("can't start the latch thread")
    }
    // A deadline profile on its periods: 4 ms of each frame.
    var admission = "none (no system resource)"
    if let system = start.take(HandleType.info(HandleType.resource(.system))) {
      if let r = try? Sys.Resource.create(parent: system, kind: .system, base: Profile.systemBase, size: 1, name: "radharc"),
        let profile = try? Profile.deadline(resource: r, capacity: 4_000_000, deadline: state.period, period: state.period)
      {
        let refusal = (try? Profile.apply(profile, to: latchThread)) ?? 0xFFFF
        admission = refusal == 0 ? "deadline 4 ms of each 16.7 ms, admitted" : "refused (\(refusal))"
      } else {
        admission = "none (no profile)"
      }
    }

    // Input: kbdfs's keys and the mouse's pointer, routed.
    let keyboard = Locked(KeyboardDecoder())
    let haveKeys = reading(ns, "/dev/kbd", state) { bytes in
      let events = keyboard.withLock { $0.decode(bytes, time: Clock.monotonic()) }
      for e in events { route(e, state) }
      for rune in KeyboardDecoder.typed(bytes) where state.scene.prompts.showing != nil {
        state.prompted(state.scene.promptTyped(rune, now: Clock.monotonic()))
        state.wake()
      }
    }
    let mouse = Locked(MouseDecoder())
    let havePointer = reading(ns, "/dev/mouse", state) { bytes in
      let events = mouse.withLock { $0.decode(bytes) }
      for e in events { route(e, state) }
    }
    if !haveKeys { print("radharc: no /dev/kbd: no keys") }
    if !havePointer { print("radharc: no /dev/mouse: no pointer") }
    let inputs = (haveKeys ? "keys /dev/kbd" : "no keys") + ", " + (havePointer ? "pointer /dev/mouse" : "no pointer")

    // The themes installed (/lib/theme), Platinum Indigo in force.
    var installed: [(name: String, text: [UInt8])] = []
    if let entries = try? ns.list("/lib/theme") {
      for e in entries where e.qid.kind != .directory {
        if var f = try? ns.open("/lib/theme/" + e.name), let text = try? f.readAll() { installed.append((e.name, text)) }
      }
    }
    let control = ThemeControl(preferred: "platinum-indigo", installed: installed)
    if let why = control.refusal { print("radharc: theme: \(why)") }
    // Its own dispatcher and thread: each client's tree forwards to it as a
    // mount, waiting for its answer.
    let themes: ThemeTree
    do throws(Status) {
      let own = try IPCDispatcher()
      themes = ThemeTree(state: state, dispatcher: own, control: control)
      _ = try Thread.spawn {
        do throws(Status) { try own.run() } catch { print("radharc: the theme tree stopped: \(error.rawValue)") }
      }.release()
    } catch {
      Process.fail("can't serve the theme tree: \(error.rawValue)")
    }

    let admitted = admission
    // Workspaces as kept (D116), and the worker that calls layouts and
    // writes Settings; the Grants that let `shortcuts` in, followed.
    state.desk.ns = ns
    state.lock.withLock {
      restoreWorkspaces(state, ns)
      restoreLock(state, ns)
    }
    state.desk.themes = themes
    state.lock.withLock {
      state.desk.themedSpace = state.scene.current
      state.desk.ask(.theme)
    }
    _ = try? Thread.spawn { runDesk(state, ns) }.release()
    _ = try? Thread.spawn { followGrants(state, ns) }.release()
    // `prompt`, in the tree of a client granted it: each open asks one
    // question, which a read then waits to hear answered.
    func promptFile(_ tree: NodeTree, client: String, unlocks: Bool) {
      var node: TreeNode? = nil
      node = tree.stream("prompt", NodeStream(perChannel: {
        let ask = PromptAsk(tree: tree, node: node)
        return NodeStreamChannel(take: { max in
          state.lock.withLock { () -> [UInt8]? in
            guard ask.id != 0, !ask.read else { return [] }  // nothing asked, or the answer read
            guard let reply = ask.reply else { return nil }
            ask.read = true
            return Array(reply.prefix(max))
          }
        }, write: { (bytes: [UInt8]) throws(NodeError) -> UInt32? in
          let refusal = state.lock.withLock { () -> String? in
            guard ask.id == 0 else { return "one question an open" }
            do throws(PromptRefusal) {
              let q = try PromptQuestion(parsing: bytes, id: state.scene.newPromptID(), asker: client)
              // Only the lock's holder asks to unlock (D118).
              if q.kind == .unlock && !unlocks { return "ask=unlock is the lock's holder's" }
              ask.id = q.id
              state.asks.append(ask)
              state.asked += 1
              state.scene.ask(q, now: Clock.monotonic())
              return nil
            } catch {
              return error.reason
            }
          }
          if let refusal {
            print("radharc: prompt: \(client): \(refusal)")
            throw .invalid
          }
          state.wake()
          return UInt32(bytes.count)
        }, closed: {
          // Closed unanswered: withdrawn.
          state.lock.withLock {
            guard ask.id != 0, ask.reply == nil else { return }
            state.asks.removeAll { $0 === ask }
            state.scene.withdraw(ask.id, now: Clock.monotonic())
          }
          state.wake()
        })
      }))
    }
    // Each client's own tree (`export per-client`): the same nodes for all,
    // its windows marked as its own.
    func populate(_ tree: NodeTree, client: String, grants: [String]) {
      func granted(_ g: String) -> Bool { grants.contains { same($0, g) } }
      let prompt = granted("prompt"), chooser = granted("chooser")
      tree.text("status", read: {
        // The theme in force, under the theme tree's own lock, not the state's.
        let theme = themes.lock.withLock { "theme \(themes.control.name) variant \(themes.control.variant ?? "none")\n" }
        return theme + state.lock.withLock {
          "screen \(state.scene.width)x\(state.scene.height)\ndisplay \(display)\ninput \(inputs)\n"
            + timing(state, admitted)
            + "windows \(state.windows.count)\nfocused \(state.scene.focused)\nframes \(state.frames)\n"
            + "pointer \(state.scene.pointer.x) \(state.scene.pointer.y)\nkeys \(state.keys) pointer events \(state.pointer)\n"
            + "prompts \(state.scene.prompts.queue.count) asked \(state.asked) ignored \(state.scene.prompts.ignored)\n"
            + "clip commits \(state.clip.commits) refused \(state.clipRefused) fed \(state.clipFeed.fed)\n"
            + "drags \(state.drags) drops \(state.drops)\n"
            + "clocks \(state.scene.windows.filter { $0.clock != nil }.count) frames \(state.clockFrames)\n"
            + (state.idle ? "idle\n" : "active\n")
            + "workspace \(state.scene.current) of \(state.scene.spaces.count)\n"
            + "layouts \(state.desk.layouts.isEmpty ? "-" : state.desk.layouts.joined(separator: " "))"
            + " refused \(state.desk.refused) failed \(state.desk.failed) replaced \(state.desk.replaced)\n"
            + "missed \(state.missedFrames) frames\n"
            + "switch \(state.desk.switchFrames) frames switches \(state.desk.switches)\n"
            + "shortcuts \(state.desk.holders.count) chords \(state.desk.chords.count) pressed \(state.desk.chordsPressed)\n"
            + "lock \(state.scene.locked ? "locked" : "unlocked") ready \(state.lockChannels.filter { $0.ready }.count)"
            + " locks \(state.locks) unlocks \(state.unlocks) attentions \(state.attentions)\n"
            + "theme switch \(state.themeSwitchFrames) frames switches \(state.themeSwitches)\n"
            + "key draw \(state.keyDraw.last / 1000) us most \(state.keyDraw.most / 1000) us shown \(state.keyDraw.frames) frames"
            + " most \(state.keyDraw.mostFrames) timed \(state.keyDraw.timed)\n"
            + (state.firstShown.map { "first frame at \($0.at) \($0.title)\n" } ?? "")
            + (state.gpu.map { "renderer gpu frames \($0.frames) last \($0.lastFrame / 1000) us\n" } ?? "renderer cpu\n")
        }
      })
      // D114: whether someone is at the desktop, and the pacing, each read
      // when it changes.
      let idle = tree.changing("idle", { state.lock.withLock { state.idle ? "idle\n" : "active\n" } })
      let pacing = tree.changing("pacing", { state.lock.withLock { "p99 \(state.pacingShown)\n" } })
      state.lock.withLock { state.watchers.append((tree, idle, pacing)) }
      if prompt { promptFile(tree, client: client, unlocks: granted("lock")) }
      // The lock screen (D118): its holder says it can unlock (`ready`),
      // reads `locked` or `unlocked` at each change, and `unlock`s.
      if granted("lock") {
        let node = tree.stream("lock", NodeStream(perChannel: { lockChannel(state, client: client) }))
        state.lock.withLock { state.lockNodes.append((tree, node)) }
      }
      // Workspaces (D116): `workspaces` a line each, `ctl` the verbs as
      // words; `layout` registers a layout, `shortcuts` is gated.
      tree.text("workspaces", read: { state.lock.withLock { workspacesText(state) } })
      tree.text("ctl", read: { "" }, write: { (text: String) throws(NodeError) in
        guard state.lock.withLock({ deskVerb(text, state) }) else { throw .invalid }
      })
      if granted("layout") {
        tree.service("layout") { (channel: consuming Handle) throws(Status) in
          try dispatcher.add(RadharcIPC.LayoutProviderServer(channel: channel, impl: LayoutProviderSession(state: state)))
        }
      }
      if granted("shortcuts") {
        gated(tree, "shortcuts", client: client, ns, state) { raw, recorded in
          serveShortcuts(raw, client, recorded: recorded, state)
        }
      }
      // The clipboard's entries for the shell's history (D117): each
      // committed after the channel opened that isn't secret.
      if granted("clipboard") {
        let node = tree.stream("clipboard", NodeStream(perChannel: { clipFeedChannel(state) }))
        state.lock.withLock { state.clipReaders.append((tree, node)) }
      }
      if chooser {
        tree.service("chooser") { (channel: consuming Handle) throws(Status) in
          try dispatcher.add(RadharcIPC.ChooserProviderServer(channel: channel, impl: ChooserProviderSession(state: state)))
        }
      }
      // The clipboard: `snarf` its text, `clip` its representations (only
      // those the client may read), `clip/new` a whole entry.
      tree.stream("snarf", NodeStream(perChannel: { clipChannel(state, client: client, reads: .text, writes: true) }))
      tree.stream("clip/new", NodeStream(perChannel: { clipChannel(state, client: client, reads: .nothing, writes: false) }))
      // Drag and drop: `drag` starts one, `drop` has what was dropped on
      // one of the client's windows, until that window's next input.
      tree.stream("drag", NodeStream(perChannel: { dragChannel(state, client: client) }))
      let dropShown = ClipShown()
      tree.refresh("drop") {
        func has(_ names: [String], _ n: String) -> Bool { names.contains { $0.utf8.elementsEqual(n.utf8) } }
        let names = state.lock.withLock { () -> [String] in
          guard let d = state.dropped, let w = state.scene.window(d.window), w.owner.utf8.elementsEqual(client.utf8) else { return [] }
          return d.entry.representations.map { $0.name }
        }
        for n in dropShown.names where !has(names, n) {
          if let node = tree.node("drop/" + n) { tree.remove(node) }
        }
        for n in names where !has(dropShown.names, n) {
          tree.stream("drop/" + n, NodeStream(perChannel: { dropChannel(state, client: client, name: n) }))
        }
        dropShown.names = names
      }
      let shown = ClipShown()
      tree.refresh("clip") {
        func has(_ names: [String], _ n: String) -> Bool { names.contains { $0.utf8.elementsEqual(n.utf8) } }
        let names = state.lock.withLock { () -> [String] in
          state.clip.expire(now: Clock.monotonic())
          return state.scene.mayRead(client: client) ? state.clip.names : []
        }
        for n in shown.names where !has(names, n) {
          if let node = tree.node("clip/" + n) { tree.remove(node) }
        }
        for n in names where !has(shown.names, n) {
          tree.stream("clip/" + n, NodeStream(perChannel: { clipChannel(state, client: client, reads: .named(n), writes: nil) }))
        }
        shown.names = names
      }
      tree.text("list", read: {
        state.lock.withLock {
          // (Views aren't windows: they show only inside one.)
          state.scene.windows.filter { !$0.isView }.map {
            "\($0.id) \($0.content.x) \($0.content.y) \($0.content.width) \($0.content.height) \($0.id == state.scene.focused ? "focused" : "-") \($0.title)\n"
          }.joined()
        }
      })
      tree.text("pixel", read: {
        state.lock.withLock {
          let (x, y) = state.probe
          guard x >= 0, y >= 0, x < state.scene.width, y < state.scene.height else { return "outside\n" }
          if state.scene.promptLayout?.panel.contains(x, y) == true { return "000000\n" }
          return hexColor(unsafe state.shadow[y * state.scene.width + x]) + "\n"
        }
      }, write: { (text: String) throws(NodeError) in
        var words: [Int] = []
        for w in text.utf8.split(whereSeparator: { $0 == 0x20 || $0 == 0x0A }) {
          guard w.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), w.count <= 6 else { throw .invalid }
          words.append(w.reduce(0) { $0 * 10 + Int($1 - 0x30) })
        }
        guard words.count == 2 else { throw .invalid }
        state.lock.withLock { state.probe = (words[0], words[1]) }
      })
      if let ends = try? Channel.create(), (try? themes.tree.serve(ends.b)) != nil {
        tree.mount("theme", ends.a)
      }
      tree.service("compositor") { (channel: consuming Handle) throws(Status) in
        try dispatcher.add(RadharcIPC.CompositorServer(channel: channel, impl: CompositorSession(state: state, client: client)))
      }
      tree.service("windows") { (channel: consuming Handle) throws(Status) in
        let key = state.lock.withLock { () -> UInt64 in
          state.nextSubscriber += 1
          return state.nextSubscriber
        }
        let session = WindowsSession(state: state, end: SubscriberEnd(state: state, key: key))
        let id = try dispatcher.add(RadharcIPC.WindowsServer(channel: channel, impl: session)) {
          (s: inout RadharcIPC.WindowsServer<WindowsSession>) throws(IPCError<Never>) in
          let news = state.lock.withLock { () -> [RadharcIPC.WindowInfo]? in
            guard let i = state.subscribers.firstIndex(where: { $0.key == key }),
              state.subscribers[i].sent != state.listGeneration
            else { return nil }
            state.subscribers[i].sent = state.listGeneration
            return state.listed
          }
          if let news { try RadharcIPC.WindowsEventSender.sendChanged(news, on: s.connection) }
        }
        state.lock.withLock {
          if state.listed.isEmpty { state.listed = state.windowList() }
          state.subscribers.append((key, id, state.listGeneration))
        }
      }
    }
    let root = NodeTree(dispatcher: dispatcher)
    root.service("clients") { (channel: consuming Handle) throws(Status) in
      try dispatcher.add(LaunchIPC.ClientsServer(channel: channel, impl: RadharcClients(dispatcher: dispatcher, populate: populate)))
    }
    guard let export = start.export() else { Process.fail("no export (its manifest's `export per-client`)") }
    do throws(Status) { try root.serve(export) } catch { Process.fail("can't serve: \(error.rawValue)") }

    // The console moves into a window (decided: Radharc's first client).
    var handedOver = false
    if let handoff = try? ns.connect("/svc/console/handoff"), let ends = try? Channel.create() {
      if (try? dispatcher.add(RadharcIPC.CompositorServer(channel: ends.b, impl: CompositorSession(state: state, client: "console")))) != nil {
        var client = RadharcIPC.HandoffClient(channel: handoff)
        handedOver = (try? client.take(compositor: ends.a)) != nil
      }
    }
    print("radharc: \(state.scene.width)x\(state.scene.height) on "
      + (sink.map { "\(displayName)'s outputs \($0.summary)" } ?? "the boot framebuffer") + ", \(inputs), latch \(admitted)"
      + (handedOver ? ", the console in a window" : ", no console to take over"))
    // Everything, from the first frame on.
    state.lock.withLock { state.scene.damageAll() }
    state.wake()
    do throws(Status) { try dispatcher.run() } catch { Process.fail("can't serve: \(error.rawValue)") }
    _ = consume mapping
    _ = consume latchThread
  }
}
