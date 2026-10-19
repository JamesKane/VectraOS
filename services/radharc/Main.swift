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
import Sys
import Themes
import UICore

func fail(_ what: String) -> Never {
  print("radharc: \(what)")
  Process.exit(code: 1)
}

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
}

/// The output on the boot framebuffer: write-combining, written in runs.
@safe final class FramebufferOut: @unchecked Sendable {
  let address: UInt
  let stride: Int
  let swap: Bool  // the framebuffer's pixels are 0x00BBGGRR
  init(_ address: UnsafeMutableRawPointer, stride: Int, swap: Bool) {
    self.address = UInt(bitPattern: address)
    self.stride = stride
    self.swap = swap
  }

  func copy(_ d: Radharc.Rect, from shadow: UnsafeMutablePointer<UInt32>, width: Int) {
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
  var frames: [RadharcIPC.Frame] = []
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
  /// Its frame as drawn for its title, focused and not (Frames.swift),
  /// and those asked of the drawer and not yet drawn.
  var templates: [FrameTemplate] = []
  var asked: [(title: String, focused: Bool)] = []
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
  var listGeneration: UInt64 = 0
  /// The questions asked on `prompt` and not yet answered, and how many
  /// have been.
  var asks: [PromptAsk] = []
  var asked = 0
  /// The clipboard, and the reads it refused.
  var clip = Clipboard()
  var clipRefused = 0
  /// The entry a drag under way carries, and the one dropped: readable by
  /// the drop's window's client until that window's next key or press.
  /// The faces in /lib/fonts, and a painter in the theme in force and the
  /// faces its typefaces name: what windows' frames are drawn with (none
  /// read: the scene's own plain frames).
  var faces: [OpenType.Font] = []
  var drawer: FrameDrawer?
  var dragEntry: ClipEntry?
  var dropped: (window: UInt32, entry: ClipEntry)?
  var drags = 0, drops = 0

  init(width: Int, height: Int, framebuffer: FramebufferOut, dispatcher: IPCDispatcher, work: consuming Handle) {
    self.work = work
    scene = Scene(width: width, height: height)
    shadowAddress = UInt(bitPattern: UnsafeMutablePointer<UInt32>.allocate(capacity: width * height))
    self.framebuffer = framebuffer
    self.dispatcher = dispatcher
    t0 = Clock.monotonic()
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
    let now = windowList()
    // Hiding and showing are changes too (M6l: Deskbar marks hidden ones).
    let hiddenNow = scene.windows.filter { $0.hidden }.map { $0.id }
    guard now != listed || hiddenNow != listedHidden else { return }
    listed = now
    listedHidden = hiddenNow
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
      latched.append((ws, q.number))
    }
    render()
    let done = Clock.monotonic()
    latches += 1
    record(&lateness, now - (vblank - latchLead))
    record(&shownAfter, done - vblank)
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
    var next: Int64?
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
    let d = scene.takeDamage()
    guard !d.isEmpty else { return }
    let font = Font.spleen8x16
    unsafe scene.compose(d, into: shadow, stride: scene.width) { c, row in
      guard let g = font.glyph(c) else { return 0 }
      return UInt8(truncatingIfNeeded: font.row(g, row) >> 24)
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
      }
    }
  }

  /// The theme in force: the scene's colours, and a painter for the frames,
  /// each of which is drawn again (under the lock).
  func setTheme(_ theme: Theme) {
    scene.decorations = Decorations(theme)
    guard !faces.isEmpty else { return }
    if drawer == nil { drawer = FrameDrawer(self) }
    drawer?.use(Painter(theme: theme, fonts: Fonts(theme: theme, from: faces),
                        cache: GlyphCache(coverageSize: 512, fieldSize: 64)))
    for w in scene.windows { scene.setChrome(w.id, nil) }
    for ws in windows {
      ws.templates = []
      ws.asked = []
    }
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
  /// asked, whose read waits for it. Under the lock.
  func prompted(_ o: Prompts.Outcome) {
    guard case .answered(let id, let reply) = o, let i = asks.firstIndex(where: { $0.id == id }) else { return }
    let ask = asks.remove(at: i)
    ask.reply = reply
    if let node = ask.node { ask.tree.ready(node) }
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
    state.lock.withLock { state.clip.commit(entry, now: now) }
    // A secret entry is cleared after its life, whatever reads it.
    if entry.secret {
      _ = try? Thread.spawn {
        sleep(until: now + Clipboard.secretLife)
        state.lock.withLock { state.clip.expire(now: Clock.monotonic()) }
      }.release()
    }
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
    guard id != 0, width > 0, height > 0, stride >= width, width <= 8192, height <= 8192 else { throw .invalid }
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
      ws.queue.append(q)
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

  func acceptDrag(types: [String]) {
    state.lock.withLock {
      state.scene.acceptDrag(ws.id, types: types)
      state.wake()
    }
  }

  func setApp(_ name: String) {
    state.lock.withLock {
      guard let w = state.scene.window(ws.id), !w.app.utf8.elementsEqual(name.utf8) else { return }
      w.app = name
      state.noteChanges()
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
      state.apply(state.scene.close(id))
      // A view's token's peer goes with it.
      if let ws = state.windows.first(where: { $0.id == id }), ws.token != 0 { _ = Handle(raw: ws.token) }
      state.windows.removeAll { $0.id == id }
      state.noteChanges()
      state.wake()
    }
  }
}

/// The launcher's side: a tree for each client.
struct RadharcClients: LaunchIPC.ClientsHandler {
  let dispatcher: IPCDispatcher
  let populate: (NodeTree, String, Bool) -> Void
  func open(client: String, grants: [String], node: consuming Handle) throws(LaunchIPC.ClientsError) {
    // Only the prompt is granted yet: the privileged services come later
    // (D111).
    guard grants.allSatisfy({ $0.utf8.elementsEqual("prompt".utf8) }) else { throw .refused }
    let tree = NodeTree(dispatcher: dispatcher)
    populate(tree, client, !grants.isEmpty)
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
                 token: UInt32) throws(RadharcIPC.WindowError) -> RadharcIPC.Opened
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
    let server = RadharcIPC.WindowServer(channel: channel.b,
                                         impl: WindowSession(state: state, ws: ws, end: WindowEnd(state: state, id: ws.id),
                                                             client: client))
    let id = try state.dispatcher.add(server) { (s: inout RadharcIPC.WindowServer<WindowSession>) throws(IPCError<Never>) in
      let (pending, frames, moves, gone, closeAsked, drags) = state.lock.withLock {
        () -> ([RadharcIPC.Configure], [RadharcIPC.Frame], [(x: Int32, y: Int32)], [UInt32], Bool, [DragEvent]) in
        defer {
          ws.pending = []
          ws.frames = []
          ws.moves = []
          ws.viewsGone = []
          ws.closeAsked = false
          ws.drags = []
        }
        return (ws.pending, ws.frames, ws.moves, ws.viewsGone, ws.closeAsked, ws.drags)
      }
      for d in drags {
        switch d {
        case .over(let types, let x, let y): try RadharcIPC.WindowEventSender.sendDragOver(types: types, x: x, y: y, on: s.connection)
        case .left: try RadharcIPC.WindowEventSender.sendDragLeft(on: s.connection)
        case .drop(let types, let x, let y): try RadharcIPC.WindowEventSender.sendDrop(types: types, x: x, y: y, on: s.connection)
        case .ended(let dropped): try RadharcIPC.WindowEventSender.sendDragEnded(dropped: dropped, on: s.connection)
        }
      }
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
  // The prompt up: the pointer moves the cursor and works it, and no
  // window hears anything (its text comes from /dev/kbd's `c`).
  if scene.prompts.showing != nil {
    switch e.kind {
    case .keyDown, .keyUp: state.keys += 1
    case .pointerMotion:
      state.pointer += 1
      _ = scene.moveBy(Int(e.ax), Int(e.ay))
    case .pointerAbsolute:
      state.pointer += 1
      _ = scene.moveTo(Int(e.x), Int(e.y))
    case .buttonDown, .buttonUp:
      state.pointer += 1
      if e.code == 1 { state.prompted(scene.promptButton(down: e.kind == .buttonDown, now: Clock.monotonic())) }
    case .wheel: state.pointer += 1
    }
    state.wake()
    return
  }
  switch e.kind {
  case .keyDown, .keyUp:
    state.keys += 1
    // Escape cancels a drag, and goes no further.
    if scene.drag != nil && e.code == 0x29 {
      if e.kind == .keyDown { state.apply(scene.cancelDrag()) }
      break
    }
    if let ws = state.window(scene.focused) {
      ws.deliver(e)
      if e.kind == .keyDown {
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

  init(state: State, dispatcher: IPCDispatcher, control: ThemeControl) {
    self.state = state
    self.control = control
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
  func command(_ text: String) throws(NodeError) {
    let refused = lock.withLock { () -> String? in
      do throws(ThemeCommandError) {
        _ = try control.command(text)
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
    state.lock.withLock { state.setTheme(theme) }
    state.wake()
    print("radharc: \(line)")
  }
}

/// Windows' frames drawn off the latch thread: a thread of its own with
/// the painter, which keeps its glyphs and their places together, taking
/// the windows' asks in turn. A new theme's painter drops what was asked.
final class FrameDrawer: @unchecked Sendable {
  let lock = Lock()
  var painter: Painter?
  var generation = 0
  var jobs: [(window: UInt32, title: String, focused: Bool)] = []
  let bell: UInt32
  var rung: Int64 = 0

  init?(_ state: State) {
    guard let c = try? Counter.create() else { return nil }
    bell = c.release()
    let bell = bell
    _ = try? Thread.spawn { [self] in
      var seen: Int64 = 0
      while true {
        let next = lock.withLock { () -> (Int, (window: UInt32, title: String, focused: Bool), Painter)? in
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
        let t = FrameTemplate(&painter, title: job.title, focused: job.focused)
        // Its glyphs kept for the next, unless the theme changed meanwhile.
        let current = lock.withLock { () -> Bool in
          guard g == generation else { return false }
          self.painter = painter
          return true
        }
        if current { state.lock.withLock { state.drawn(t, window: job.window) } }
      }
    }.release()
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
    lock.withLock { jobs.append((window, title, focused)) }
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

@main struct RadharcService {
  static func main() {
    let start = Startup.current
    let ns: Namespace
    do throws(NamespaceError) { ns = try Namespace(start) } catch { fail("no namespace") }
    let dispatcher: IPCDispatcher
    let work: Handle
    do throws(Status) {
      dispatcher = try IPCDispatcher()
      work = try Counter.create()
    } catch { fail("can't make a dispatcher") }
    let workRaw = work.raw

    // The boot framebuffer, as the console maps it.
    guard let mmio = start.take(HandleType.info(HandleType.resource(.mmio))) else {
      fail("no MMIO resource (its manifest's `resource mmio`)")
    }
    guard let bootData = start.take(HandleType.info(HandleType.vmoBootData)) else {
      fail("no boot data (its manifest's `bootdata`)")
    }
    guard let fb = BootFramebuffer(bootData: bootData), let format = PixelFormat(zbi: fb.format) else {
      fail("no linear framebuffer in the boot data")
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
      fail("can't map the framebuffer: \(error.rawValue)")
    }
    let out = unsafe FramebufferOut(mapping.address + Int(fb.base - pageBase), stride: fb.stride,
                                    swap: format == .bgr888x)
    let state = State(width: fb.width, height: fb.height, framebuffer: out, dispatcher: dispatcher, work: work)
    // The faces windows' titles are drawn in (its manifest's /lib/fonts).
    state.faces = faces(ns)
    print("radharc: \(state.faces.count) faces for the windows' frames")
    let display = "framebuffer \(fb.width)x\(fb.height) stride \(fb.stride) \(format == .rgbx888 ? "rgbx888" : "bgr888x")"

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
          let due = state.lock.withLock { state.due(at: state.vblank(state.vblankAfter(now) + 1)) }
          if due != 0 {
            _ = try? Counter.wait(work, until: seen + 1, deadline: due ?? infiniteDeadline)
            seen = (try? Counter.read(work)) ?? seen
            if state.lock.withLock({ state.due(at: Clock.monotonic() + state.period) }) != 0 { continue }
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
      fail("can't start the latch thread")
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
      fail("can't serve the theme tree: \(error.rawValue)")
    }

    let admitted = admission
    // `prompt`, in the tree of a client granted it: each open asks one
    // question, which a read then waits to hear answered.
    func promptFile(_ tree: NodeTree, client: String) {
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
    func populate(_ tree: NodeTree, client: String, prompt: Bool) {
      tree.text("status", read: {
        state.lock.withLock {
          "screen \(state.scene.width)x\(state.scene.height)\ndisplay \(display)\ninput \(inputs)\n"
            + timing(state, admitted)
            + "windows \(state.windows.count)\nfocused \(state.scene.focused)\nframes \(state.frames)\n"
            + "pointer \(state.scene.pointer.x) \(state.scene.pointer.y)\nkeys \(state.keys) pointer events \(state.pointer)\n"
            + "prompts \(state.scene.prompts.queue.count) asked \(state.asked) ignored \(state.scene.prompts.ignored)\n"
            + "clip commits \(state.clip.commits) refused \(state.clipRefused)\n"
            + "drags \(state.drags) drops \(state.drops)\n"
        }
      })
      if prompt { promptFile(tree, client: client) }
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
    guard let export = start.export() else { fail("no export (its manifest's `export per-client`)") }
    do throws(Status) { try root.serve(export) } catch { fail("can't serve: \(error.rawValue)") }

    // The console moves into a window (decided: Radharc's first client).
    var handedOver = false
    if let handoff = try? ns.connect("/svc/console/handoff"), let ends = try? Channel.create() {
      if (try? dispatcher.add(RadharcIPC.CompositorServer(channel: ends.b, impl: CompositorSession(state: state, client: "console")))) != nil {
        var client = RadharcIPC.HandoffClient(channel: handoff)
        handedOver = (try? client.take(compositor: ends.a)) != nil
      }
    }
    print("radharc: \(fb.width)x\(fb.height) on the boot framebuffer, \(inputs), latch \(admitted)"
      + (handedOver ? ", the console in a window" : ", no console to take over"))
    // Everything, from the first frame on.
    state.lock.withLock { state.scene.damageAll() }
    state.wake()
    do throws(Status) { try dispatcher.run() } catch { fail("can't serve: \(error.rawValue)") }
    _ = consume mapping
    _ = consume latchThread
  }
}
