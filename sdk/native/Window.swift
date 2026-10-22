// SPDX-License-Identifier: BSD-3-Clause

// Windows, surfaces and frames (sdk(2)): a client of Radharc (RadharcIPC).
// Each window is its own channel; its configures and frames arrive there
// as events, its input on a ring of its own with a counter for its
// doorbell, both bound to the loop's port. A CPU surface is one of two
// images in VMOs Radharc reads, each with an acquire counter the SDK
// raises at present and a release counter Radharc raises once a later
// present stops reading it. Frames: Radharc answers each latched present
// with a `frame` (when it was shown, the next vblank); a frame asked for
// with no present in flight is the loop's own, at the next vblank it
// estimates from the last (at once, before the first).
//
// Crash survival: the SDK keeps what Radharc holds of its windows (title,
// size, images, the last present). When Radharc goes, the program carries
// on: presents are kept, frames come from the loop's own estimate, and
// every 20 ms it tries the compositor again; once the launcher has
// restarted it, each window is opened again, its images added and its
// last present replayed, and the program sees one `configure`.

import IPC
import Node
import Radharc
import Sys
import Trace

let frameErrorName = TraceName("frame.error")

public enum WindowError: Error, Equatable {
  /// No compositor, or it refused the window (why).
  case unavailable(String)
  /// The window was closed, or never existed.
  case unknownWindow
  /// A buffer drawn for an older configuration (never stretched).
  case staleConfig
  /// The compositor or the kernel failed (the status, or the window's error).
  case system(Int32)
}

extension WindowError: CustomStringConvertible {
  public var description: String {
    switch self {
    case .unavailable(let why): "no window: \(why)"
    case .unknownWindow: "the window was closed, or never existed"
    case .staleConfig: "the buffer was drawn for an older configuration"
    case .system(let e): "the compositor or the kernel failed (\(e))"
    }
  }
}

/// Raises a counter to `value` (counters only add, D25).
func raise(_ counter: borrowing Handle, to value: Int64) {
  let now = (try? Counter.read(counter)) ?? value
  if value > now { try? Counter.add(counter, value - now) }
}

/// A buffer: an image Radharc knows by `image`.
final class NativeBuffer {
  let image: UInt32
  let vmo: Handle
  let mapping: Mapping
  let acquire: Handle
  let release: Handle
  let width: Int
  let height: Int
  let stride: Int
  /// The last present that used it (0: never), and its place in the
  /// window's presents, for `age`.
  var number: Int64 = 0
  var presented: UInt32 = 0

  init(image: UInt32, vmo: consuming Handle, mapping: consuming Mapping, acquire: consuming Handle,
       release: consuming Handle, width: Int, height: Int, stride: Int)
  {
    self.image = image
    self.vmo = vmo
    self.mapping = mapping
    self.acquire = acquire
    self.release = release
    self.width = width
    self.height = height
    self.stride = stride
  }

  /// Radharc reads it no more.
  var free: Bool { number == 0 || ((try? Counter.read(release)) ?? 0) >= number }

  /// Gives it to a window of Radharc's under its id.
  func add(to client: inout RadharcIPC.WindowClient) -> Bool {
    guard let v = try? vmo.duplicate(), let a = try? acquire.duplicate(), let r = try? release.duplicate() else {
      return false
    }
    return (try? client.addImage(id: image, vmo: v, width: UInt32(width), height: UInt32(height),
                                 stride: UInt32(stride / 4), acquire: a, release: r)) != nil
  }

  /// Nothing reads it (Radharc went, or never had it).
  func markFree() { if number != 0 { raise(release, to: number) } }
}

/// A window's input ring, mapped, and its doorbell.
final class NativeInput {
  let mapping: Mapping
  var ring: InputConsumer
  let doorbell: Handle
  init?(vmo: borrowing Handle, doorbell: consuming Handle) {
    guard let size = try? VMO.size(vmo), let mapping = try? VMO.map(vmo, length: size),
      let ring = unsafe InputConsumer(attaching: mapping.address, size: size)
    else { return nil }
    self.mapping = mapping
    self.ring = ring
    self.doorbell = doorbell
  }
}

final class NativeWindow {
  let id: WindowID
  let slot: Int
  var title: String
  var client: RadharcIPC.WindowClient
  var input: NativeInput
  /// Open in the current compositor (false while it's gone).
  var connected = true
  var config: Configure
  var buffers: [NativeBuffer] = []
  var nextImage: UInt32 = 1
  /// The last buffer presented, replayed to a restarted compositor.
  var shown: NativeBuffer?
  var number: Int64 = 0
  var presents: UInt32 = 0
  /// A present Radharc hasn't answered with a frame.
  var inFlight = false
  var frameRequested = false
  /// When the loop's own frame comes, if it owes one.
  var frameDue: Deadline?
  var lastVblank: Int64?
  var period: Int64?
  var presentedAt: Deadline?
  var frameSeq: UInt64 = 0
  /// What it asked of Radharc, replayed to a restarted compositor.
  var fullscreen = false
  var placedAt: (x: Int32, y: Int32)?
  var desktop = false
  var panel = false
  var app = ""
  /// A popup of another window: not reopened with a restarted compositor
  /// (its owner's is new); its program opens another.
  var isPopup = false
  /// A view's token, until the program takes it (raw; 0: none).
  var viewToken: UInt32 = 0
  /// The target of the last frame event, and of the present drawn for it
  /// (its number): the frame error is when that present reached the glass
  /// against it.
  var lastTarget: Deadline?
  var presentTarget: (number: Int64, target: Deadline)?
  var pointer = (x: 0.0, y: 0.0)

  init(id: WindowID, slot: Int, title: String, client: consuming RadharcIPC.WindowClient, input: NativeInput,
       config: Configure)
  {
    self.id = id
    self.slot = slot
    self.title = title
    self.client = client
    self.input = input
    self.config = config
  }

  /// Binds its channel and its doorbell to the loop's port, and says on
  /// the ring that it sleeps, so that Radharc rings (taking what came
  /// before).
  func bind(loop: inout Loop) {
    try? client.connection.channel.bind(port: loop.port, key: Loop.channelKeys + UInt64(slot),
                                        signals: Signals.readable | Signals.peerClosed, persistent: true)
    try? Port.bind(loop.port, Binding.changes(input.doorbell.raw, key: Loop.inputKeys + UInt64(slot)))
    drainInput(loop: &loop)
  }

  func unbind(_ port: borrowing Handle) {
    try? Port.cancel(port, source: client.connection.channel, key: Loop.channelKeys + UInt64(slot))
    try? Port.cancel(port, source: input.doorbell, key: Loop.inputKeys + UInt64(slot))
  }

  /// Everything on the ring, until it is empty with the sleep said.
  func drainInput(loop: inout Loop) {
    while true {
      while let e = input.ring.pop() { deliver(e, loop: &loop) }
      if input.ring.prepareSleep() { break }
    }
  }

  func deliver(_ e: InputEvent, loop: inout Loop) {
    var m: Modifiers = []
    if e.modifiers & InputEvent.Modifier.shift != 0 { m.insert(.shift) }
    if e.modifiers & InputEvent.Modifier.control != 0 { m.insert(.control) }
    if e.modifiers & InputEvent.Modifier.alt != 0 { m.insert(.alt) }
    if e.modifiers & InputEvent.Modifier.superKey != 0 { m.insert(.super) }
    if e.modifiers & InputEvent.Modifier.capsLock != 0 { m.insert(.capsLock) }
    func button(_ code: UInt16) -> PointerButton {
      switch code {
      case 1: .left
      case 2: .right
      case 3: .middle
      default: .other(UInt32(code))
      }
    }
    switch e.kind {
    case .keyDown, .keyUp:
      let key = Key(usage: KeyUsage(rawValue: e.code), modifiers: m, character: e.character,
                    isRepeat: e.flags & InputEvent.isRepeat != 0,
                    time: e.time > 0 ? Deadline(ns: UInt64(e.time)) : nil)
      loop.append(e.kind == .keyDown ? .keyDown(key) : .keyUp(key), window: id)
    case .pointerAbsolute, .pointerMotion:
      pointer = (Double(e.x), Double(e.y))
      loop.append(.pointer(Pointer(action: .motion, x: pointer.x, y: pointer.y, modifiers: m)), window: id)
    case .buttonDown, .buttonUp:
      let action: Pointer.Action = e.kind == .buttonDown ? .down(button(e.code)) : .up(button(e.code))
      loop.append(.pointer(Pointer(action: action, x: pointer.x, y: pointer.y, modifiers: m)), window: id)
    case .wheel:
      // A notch is 10 points; Radharc's is positive up, the SDK's down.
      let sx = Double(e.x), sy = -Double(e.y)
      loop.append(.wheel(Wheel(dx: sx * 10, dy: sy * 10, stepsX: sx, stepsY: sy, modifiers: m)), window: id)
    }
  }
}

/// The connection to the compositor.
final class CompositorLink {
  var client: RadharcIPC.CompositorClient
  init(_ client: consuming RadharcIPC.CompositorClient) { self.client = client }
  var closed: Bool { (try? client.connection.channel.wait(for: Signals.peerClosed, deadline: 0)) != nil }
}

/// What the SDK makes of a configure: logical points, at 1× (Radharc on
/// the boot framebuffer has one scale).
func configure(_ c: RadharcIPC.Configure) -> Configure {
  Configure(width: Int32(c.width), height: Int32(c.height), pixelWidth: Int32(c.width), pixelHeight: Int32(c.height),
            scale: 120, configSeq: c.seq, focused: c.focused)
}

/// Every window, and the compositor.
final class WindowSystem {
  static let path = "/svc/windows/compositor"
  static let retry: UInt64 = 20_000_000
  var link: CompositorLink?
  var slots: [NativeWindow?] = []
  var generation: UInt32 = 0
  /// The compositor went: when to try it again.
  var lost = false
  var retryAt: Deadline?
  /// Times it has been reopened.
  var reconnections = 0

  init(link: CompositorLink) { self.link = link }

  func window(_ id: WindowID) -> NativeWindow? {
    guard id.index >= 1, Int(id.index) <= slots.count, let w = slots[Int(id.index) - 1], w.id == id else { return nil }
    return w
  }

  /// A window opened in Radharc, in a free slot, bound to the loop.
  func adopt(_ opened: consuming RadharcIPC.Opened, title: String, popup: Bool, loop: inout Loop) throws(WindowError)
    -> WindowID
  {
    guard let doorbell = try? opened.doorbell.duplicate(), let input = NativeInput(vmo: opened.input, doorbell: doorbell)
    else { throw .system(Status.noMemory.rawValue) }
    let first = opened.first
    let client = RadharcIPC.WindowClient(channel: opened.takeWindow())
    let slot = slots.firstIndex { $0 == nil } ?? slots.count
    if slot == slots.count { slots.append(nil) }
    generation &+= 1
    let id = WindowID(index: UInt32(slot + 1), generation: generation)
    let w = NativeWindow(id: id, slot: slot, title: title, client: client, input: input, config: configure(first))
    w.isPopup = popup
    slots[slot] = w
    loop.append(.configure(w.config), window: id)
    w.bind(loop: &loop)
    return id
  }

  /// The earliest frame the loop owes, or try at the compositor.
  func nextFrameDue() -> Deadline? {
    var due: Deadline? = lost ? retryAt : nil
    for case let w? in slots where w.frameRequested && !w.inFlight {
      if let d = w.frameDue { due = due.map { min($0, d) } ?? d }
    }
    return due
  }

  func emitDueFrames(loop: inout Loop) {
    let now = Deadline.now
    for case let w? in slots where w.frameRequested && !w.inFlight {
      guard let due = w.frameDue, due <= now else { continue }
      emitFrame(w, target: idleTarget(w), loop: &loop)
    }
  }

  func emitFrame(_ w: NativeWindow, target: Deadline, estimated: Bool = true, loop: inout Loop) {
    w.frameRequested = false
    w.frameDue = nil
    w.frameSeq += 1
    w.lastTarget = target
    let refresh = w.period.map { Duration.nanoseconds($0) }
    loop.append(.frame(Frame(frameSeq: w.frameSeq, target: target, presentedAt: w.presentedAt, refresh: refresh,
                             estimated: estimated)), window: w.id)
  }

  /// The next vblank after now, from the last one Radharc named. A frame
  /// asked for while none is in flight is drawn at once (a key's glyph
  /// shouldn't wait for a vblank to start), for the next vblank there's
  /// still time to make: Radharc latches before each, so one closer than
  /// 5 ms is the one after.
  func idleTarget(_ w: NativeWindow) -> Deadline {
    let v = nextVblank(w)
    guard let p = w.period, p > 0 else { return v }
    return Int64(v.ns) - Int64(Deadline.now.ns) < 5_000_000 ? Deadline(ns: v.ns &+ UInt64(p)) : v
  }

  func nextVblank(_ w: NativeWindow) -> Deadline {
    let now = Deadline.now
    guard let v = w.lastVblank, let p = w.period, p > 0 else { return now }
    let n = Int64(now.ns) > v ? (Int64(now.ns) - v) / p + 1 : 1
    return Deadline(ns: UInt64(v + n * p))
  }

  /// The window's channel is readable or closed.
  func channelReady(slot: Int, loop: inout Loop) {
    guard slot < slots.count, let w = slots[slot], w.connected else { return }
    drainEvents(w, loop: &loop)
    guard (try? w.client.connection.channel.wait(for: Signals.peerClosed, deadline: 0)) != nil else { return }
    // The compositor went with it: carry on, and open it again later.
    if link?.closed ?? true {
      lose(loop: &loop)
      return
    }
    // Radharc closed it (its owner's, for a popup).
    w.unbind(loop.port)
    w.connected = false
    loop.append(.close, window: w.id)
  }

  /// Its doorbell rang.
  func inputReady(slot: Int, loop: inout Loop) {
    guard slot < slots.count, let w = slots[slot], w.connected else { return }
    w.input.ring.endSleep()
    w.drainInput(loop: &loop)
  }

  /// The compositor is gone. Every window keeps its state; nothing reads
  /// the buffers now but the last shown, kept to replay; frames come from
  /// the loop until it's back.
  func lose(loop: inout Loop) {
    guard !lost else { return }
    lost = true
    link = nil
    retryAt = Deadline(ns: Deadline.now.ns + Self.retry)
    for case let w? in slots where w.connected {
      w.connected = false
      w.unbind(loop.port)
      for b in w.buffers where b !== w.shown { b.markFree() }
      w.inFlight = false
      // (While the compositor's away the loop paces frames by the vblank
      // it knew: at once would spin a program that draws every frame.)
      if w.frameRequested { w.frameDue = nextVblank(w) }
    }
  }

  /// Tries the compositor again if it's time: each window opened again with
  /// its images and its last present; a popup is closed.
  func reconnectIfDue(loop: inout Loop) {
    guard lost, let at = retryAt, at <= Deadline.now else { return }
    retryAt = Deadline(ns: Deadline.now.ns + Self.retry)
    if link == nil || link!.closed {
      guard let ns = NativeProcess.namespace, let channel = try? ns.connect(Self.path) else { return }
      link = CompositorLink(RadharcIPC.CompositorClient(channel: channel))
    }
    for case let w? in slots where !w.connected && !w.isPopup {
      guard reopen(w, loop: &loop) else { return }
    }
    for case let w? in slots where !w.connected && w.isPopup { loop.append(.close, window: w.id) }
    lost = false
    retryAt = nil
    reconnections += 1
  }

  func reopen(_ w: NativeWindow, loop: inout Loop) -> Bool {
    guard let link else { return false }
    let opened: RadharcIPC.Opened
    do {
      opened = try link.client.open(title: w.title, width: UInt32(w.config.width), height: UInt32(w.config.height))
    } catch {
      return false
    }
    guard let doorbell = try? opened.doorbell.duplicate(), let input = NativeInput(vmo: opened.input, doorbell: doorbell)
    else { return false }
    let first = opened.first
    var client = RadharcIPC.WindowClient(channel: opened.takeWindow())
    for b in w.buffers {
      guard b.add(to: &client) else { return false }
    }
    if w.fullscreen { try? client.setFullscreen(true) }
    if w.desktop { try? client.setRole(.desktop) }
    if w.panel { try? client.setPanel(true) }
    if !w.app.isEmpty { try? client.setApp(w.app) }
    if let at = w.placedAt { try? client.place(x: at.x, y: at.y) }
    w.client = client
    w.input = input
    w.connected = true
    // Its last present again, for the new configure: shown at its own size.
    w.inFlight = false
    if let b = w.shown {
      let all = RadharcIPC.Area(x: 0, y: 0, width: Int32(b.width), height: Int32(b.height))
      if (try? w.client.present(seq: first.seq, width: UInt32(b.width), height: UInt32(b.height),
                                layers: [RadharcIPC.Layer(image: b.image, color: 0, area: all)], damage: [],
                                acquire: b.number, number: b.number)) != nil
      {
        w.inFlight = b.number == w.number
      }
    }
    if !w.inFlight && w.frameRequested { w.frameDue = Deadline.now } else if w.inFlight { w.frameDue = nil }
    w.config = configure(first)
    loop.append(.configure(w.config), window: w.id)
    w.bind(loop: &loop)
    return true
  }

  /// The window's configures and frames, including those its own calls
  /// queued in the connection (where the channel's readable signal no
  /// longer shows them).
  func drainEvents(_ w: NativeWindow, loop: inout Loop) {
    while let e = try? w.client.nextEvent(deadline: 0) {
      switch e {
      case .configure(let c):
        w.config = configure(c)
        loop.append(.configure(w.config), window: w.id)
      case .closeRequested:
        // Its close box: the program decides.
        loop.append(.close, window: w.id)
      case .viewGone(let id):
        loop.append(.viewGone(id), window: w.id)
      case .dragOver(let types, let x, let y): loop.append(.dragOver(types: types, x: Double(x), y: Double(y)), window: w.id)
      case .dragLeft: loop.append(.dragLeft, window: w.id)
      case .drop(let types, let x, let y): loop.append(.drop(types: types, x: Double(x), y: Double(y)), window: w.id)
      case .dragEnded(let dropped): loop.append(.dragEnded(dropped: dropped), window: w.id)
      case .chosen(let chosen): loop.append(.chosen(chosen), window: w.id)
      case .moved(let x, let y):
        guard w.placedAt.map({ $0 != (x, y) }) ?? true else { continue }
        w.placedAt = (x, y)
        loop.append(.moved(x: x, y: y), window: w.id)
      case .frame(let f):
        guard f.presented == w.number else { continue }
        w.inFlight = false
        w.lastVblank = f.vblank
        w.period = f.target - f.vblank
        w.presentedAt = Deadline(ns: UInt64(max(0, f.presentedAt)))
        if let p = w.presentTarget, p.number == f.presented {
          Trace.counter(frameErrorName, f.presentedAt &- Int64(p.target.ns), .frame)
          w.presentTarget = nil
        }
        // Radharc's target is the vblank after the one it latched at; if
        // composing took longer than that, the next to come.
        let target = Deadline(ns: UInt64(max(0, f.target)))
        if w.frameRequested {
          emitFrame(w, target: target > Deadline.now ? target : nextVblank(w), estimated: false, loop: &loop)
        }
      }
    }
  }

  /// Two buffers of the configured size, made again when it changes.
  func ensureBuffers(_ w: NativeWindow) -> Bool {
    let width = Int(w.config.pixelWidth), height = Int(w.config.pixelHeight)
    if w.buffers.count == 2 && w.buffers[0].width == width && w.buffers[0].height == height { return true }
    guard w.connected else { return false }
    for b in w.buffers { try? w.client.removeImage(id: b.image) }
    w.buffers = []
    w.shown = nil
    for _ in 0..<2 {
      do throws(Status) {
        let bytes = width * height * 4
        let vmo = try VMO.create(size: bytes)
        let mapping = try VMO.map(vmo, length: (bytes + 4095) & ~4095)
        // Each page written once now: their faults come here, at the
        // window's first frame, not in a later frame's latency (a key's).
        for page in stride(from: 0, to: bytes, by: 4096) {
          unsafe mapping.address.storeBytes(of: 0, toByteOffset: page, as: UInt8.self)
        }
        let acquire = try Counter.create(), release = try Counter.create()
        let image = w.nextImage
        w.nextImage += 1
        let b = NativeBuffer(image: image, vmo: vmo, mapping: mapping, acquire: acquire, release: release,
                             width: width, height: height, stride: width * 4)
        guard b.add(to: &w.client) else { return false }
        w.buffers.append(b)
      } catch {
        return false
      }
    }
    return true
  }
}

extension Loop {
  /// The window system, connected the first time.
  mutating func windowSystem() throws(WindowError) -> WindowSystem {
    if let windows { return windows }
    guard let ns = NativeProcess.namespace, let channel = try? ns.connect(WindowSystem.path) else {
      throw .unavailable("no compositor at \(WindowSystem.path)")
    }
    let system = WindowSystem(link: CompositorLink(RadharcIPC.CompositorClient(channel: channel)))
    windows = system
    return system
  }

  /// Opens a window `width` by `height` points; its first configure comes
  /// as an event.
  public mutating func openWindow(_ title: String, width: Int32, height: Int32) throws(WindowError) -> WindowID {
    let system = try windowSystem()
    guard let link = system.link, !system.lost else { throw .unavailable("the compositor is restarting") }
    let opened: RadharcIPC.Opened
    do { opened = try link.client.open(title: title, width: UInt32(width), height: UInt32(height)) } catch {
      if case .remote(let e) = error { throw .unavailable("the compositor refused the window (\(e.rawValue))") }
      throw .unavailable("the compositor failed")
    }
    return try system.adopt(opened, title: title, popup: false, loop: &self)
  }

  /// Opens a popup of window `owner` (a menu's own surface): `width` by
  /// `height` at (x, y) in its content, above every window, following it;
  /// a press in it keeps the owner focused. Its first configure comes as
  /// an event, its input as a window's. Closed when its owner is.
  public mutating func openPopup(_ owner: WindowID, _ title: String, x: Int32, y: Int32, width: Int32, height: Int32)
    throws(WindowError) -> WindowID
  {
    guard let system = windows, let o = system.window(owner), o.connected, !system.lost else {
      throw .unavailable("no compositor for a popup")
    }
    let opened: RadharcIPC.Opened
    do {
      opened = try o.client.openPopup(title: title, x: x, y: y, width: UInt32(width), height: UInt32(height))
    } catch {
      if case .remote(let e) = error { throw .unavailable("the compositor refused the popup (\(e.rawValue))") }
      throw .unavailable("the compositor failed")
    }
    return try system.adopt(opened, title: title, popup: true, loop: &self)
  }

  /// Opens a view `width` by `height` points: a window shown only where
  /// another embeds its token (`viewToken`, then the other's `embed`), its
  /// input the pointer over it there. Its first configure comes as an
  /// event. A restarted compositor doesn't reopen it, as it doesn't a
  /// popup: its token was the old one's; it closes.
  public mutating func openView(_ title: String, width: Int32, height: Int32) throws(WindowError) -> WindowID {
    let system = try windowSystem()
    guard let link = system.link, !system.lost else { throw .unavailable("the compositor is restarting") }
    let v: RadharcIPC.OpenedView
    do { v = try link.client.openView(title: title, width: UInt32(width), height: UInt32(height)) } catch {
      if case .remote(let e) = error { throw .unavailable("the compositor refused the view (\(e.rawValue))") }
      throw .unavailable("the compositor failed")
    }
    let first = v.first
    guard let input = try? v.input.duplicate(), let doorbell = try? v.doorbell.duplicate() else {
      throw .system(Status.noMemory.rawValue)
    }
    var token: Handle? = nil
    let window = v.takeWindow(token: &token)
    let id = try system.adopt(RadharcIPC.Opened(window: window, input: input, doorbell: doorbell, first: first),
                              title: title, popup: true, loop: &self)
    system.window(id)?.viewToken = token.take()?.release() ?? 0
    return id
  }

  /// View `id`'s token, for the window that will show it (once).
  public mutating func viewToken(_ id: WindowID) -> Handle? {
    guard let system = windows, let w = system.window(id), w.viewToken != 0 else { return nil }
    defer { w.viewToken = 0 }
    return Handle(raw: w.viewToken)
  }

  /// Shows the view whose token this is in window `host`'s content at
  /// (x, y), `width` by `height` points, as its embedding `id`; the view
  /// is configured for the area. The token goes whole (it can't be
  /// duplicated): `placeEmbedding` moves or sizes it after.
  public mutating func embed(_ host: WindowID, token: consuming Handle, id: UInt32, x: Int32, y: Int32, width: Int32,
                             height: Int32) throws(WindowError)
  {
    guard let system = windows, let w = system.window(host), w.connected else { throw .unknownWindow }
    do { try w.client.embed(token, id: id, area: RadharcIPC.Area(x: x, y: y, width: width, height: height)) } catch {
      throw .unavailable("the compositor refused the view")
    }
    system.drainEvents(w, loop: &self)
  }

  /// Window `host`'s embedding `id` moved or sized.
  public mutating func placeEmbedding(_ host: WindowID, id: UInt32, x: Int32, y: Int32, width: Int32, height: Int32)
    throws(WindowError)
  {
    guard let system = windows, let w = system.window(host), w.connected else { throw .unknownWindow }
    do { try w.client.placeEmbedding(id: id, area: RadharcIPC.Area(x: x, y: y, width: width, height: height)) } catch {
      throw .unavailable("the compositor has no such embedding")
    }
    system.drainEvents(w, loop: &self)
  }

  /// The file chooser, for window `id`: a file of `types` (MIME types;
  /// none: any) to open, or one to save, `name` suggested. Radharc shows it
  /// on the trusted path, and what comes back is `.chosen(true)` (then
  /// `takeChosen` takes a confined channel to the file, never its path) or
  /// `.chosen(false)` if cancelled.
  public mutating func choose(_ id: WindowID, save: Bool = false, types: [String] = [], name: String = "")
    throws(WindowError)
  {
    guard let system = windows, let w = system.window(id), w.connected else { throw .unknownWindow }
    do { try w.client.choose(mode: save ? .save : .open, types: types, name: name) } catch {
      if case .remote(.unavailable) = error { throw .unavailable("the file chooser isn't there yet") }
      throw .unavailable("the compositor failed")
    }
    system.drainEvents(w, loop: &self)
  }

  /// Takes the channel to the file the user chose for window `id`, once
  /// `.chosen(true)` has arrived: a confined `FsIPC.File` channel, read-only
  /// for an open and writable for a save.
  public mutating func takeChosen(_ id: WindowID) -> Handle? {
    guard let system = windows, let w = system.window(id), w.connected else { return nil }
    defer { system.drainEvents(w, loop: &self) }
    return try? w.client.takeChosen()
  }

  /// Adopts a view already opened in Radharc (Tracker's chooser view,
  /// opened by Radharc for the trusted prompt).
  public mutating func adoptView(_ opened: consuming RadharcIPC.Opened, title: String) throws(WindowError) -> WindowID {
    let system = try windowSystem()
    return try system.adopt(opened, title: title, popup: true, loop: &self)
  }

  /// What window `id` would take of the drag over it (none: nothing): a
  /// release over it then drops.
  public mutating func acceptDrag(_ id: WindowID, types: [String]) {
    guard let system = windows, let w = system.window(id), w.connected else { return }
    try? w.client.acceptDrag(types: types)
    system.drainEvents(w, loop: &self)
  }

  /// Window `host` stops showing its embedding `id`.
  public mutating func unembed(_ host: WindowID, id: UInt32) {
    guard let system = windows, let w = system.window(host), w.connected else { return }
    try? w.client.unembed(id: id)
    system.drainEvents(w, loop: &self)
  }

  /// A popup's place in its owner's content and its size, again.
  public mutating func setPopupArea(_ id: WindowID, x: Int32, y: Int32, width: Int32, height: Int32) {
    guard let system = windows, let w = system.window(id), w.isPopup, w.connected else { return }
    try? w.client.setPopupArea(x: x, y: y, width: UInt32(width), height: UInt32(height))
    system.drainEvents(w, loop: &self)
  }

  public mutating func closeWindow(_ id: WindowID) {
    guard let system = windows, let w = system.window(id) else { return }
    if w.connected { w.unbind(port) }
    system.slots[w.slot] = nil
  }

  /// Asks for the window to fill the screen, undecorated (or not): a
  /// `configure` follows with its size.
  public mutating func setFullscreen(_ id: WindowID, _ on: Bool) {
    guard let system = windows, let w = system.window(id), w.fullscreen != on else { return }
    w.fullscreen = on
    if w.connected { try? w.client.setFullscreen(on) }
    system.drainEvents(w, loop: &self)
  }

  /// Gives the window a new title.
  public mutating func setTitle(_ id: WindowID, _ title: String) {
    guard let system = windows, let w = system.window(id), !w.title.utf8.elementsEqual(title.utf8) else { return }
    w.title = title
    if w.connected { try? w.client.setTitle(title) }
    system.drainEvents(w, loop: &self)
  }

  /// Makes the window a panel (or not): undecorated, above every other
  /// window, where it places itself (Deskbar).
  public mutating func setPanel(_ id: WindowID, _ on: Bool) {
    guard let system = windows, let w = system.window(id), w.panel != on else { return }
    w.panel = on
    if w.connected { try? w.client.setPanel(on) }
    system.drainEvents(w, loop: &self)
  }

  /// Says which app the window belongs to, as its user knows it: the
  /// window list carries it.
  public mutating func setApp(_ id: WindowID, _ name: String) {
    guard let system = windows, let w = system.window(id), !w.app.utf8.elementsEqual(name.utf8) else { return }
    w.app = name
    if w.connected { try? w.client.setApp(name) }
    system.drainEvents(w, loop: &self)
  }

  /// The window's id in Radharc's window list (`/svc/windows/windows`,
  /// whose verbs take it): nil while the compositor is gone. A restarted
  /// compositor gives it a new one.
  public mutating func listID(_ id: WindowID) -> UInt32? {
    guard let system = windows, let w = system.window(id), w.connected, let n = try? w.client.listID() else { return nil }
    system.drainEvents(w, loop: &self)
    return n
  }

  /// Places the window: its content's top left at (x, y) on the screen,
  /// kept where its tab can be grabbed; from then on `.moved` says where
  /// the user moves it, the place given included.
  public mutating func placeWindow(_ id: WindowID, x: Int32, y: Int32) {
    guard let system = windows, let w = system.window(id) else { return }
    w.placedAt = nil
    if w.connected { try? w.client.place(x: x, y: y) }
    system.drainEvents(w, loop: &self)
  }

  /// Makes the window the desktop (or not): the screen's size, undecorated,
  /// beneath every other window; a `configure` follows with its size.
  public mutating func setDesktop(_ id: WindowID, _ on: Bool) {
    guard let system = windows, let w = system.window(id), w.desktop != on else { return }
    w.desktop = on
    if w.connected { try? w.client.setRole(on ? .desktop : .normal) }
    system.drainEvents(w, loop: &self)
  }

  /// Asks for one `.frame` event for the window: with Radharc's answer to
  /// the present in flight, or at the next vblank.
  public mutating func requestFrame(_ id: WindowID) {
    guard let system = windows, let w = system.window(id) else { return }
    w.frameRequested = true
    if !w.inFlight { w.frameDue = w.connected ? Deadline.now : system.nextVblank(w) }
  }

  /// A buffer to draw the window's next frame into, at its configured
  /// size; nil while both are still being read.
  public mutating func cpuSurface(_ id: WindowID) -> CPUSurface? {
    guard let system = windows, let w = system.window(id), system.ensureBuffers(w) else { return nil }
    guard let i = w.buffers.firstIndex(where: { $0.free && $0.number != w.number }) ?? w.buffers.firstIndex(where: { $0.free })
    else { return nil }
    let b = w.buffers[i]
    let bytes = b.stride * b.height
    return unsafe CPUSurface(pixels: unsafe UnsafeMutableRawBufferPointer(start: b.mapping.address, count: bytes),
                             width: Int32(b.width), height: Int32(b.height), stride: b.stride,
                             age: b.presented == 0 ? 0 : w.presents - b.presented + 1, window: id, buffer: i)
  }

  /// Shows `surface`, drawn for `configSeq`, at the next vblank. `damage`:
  /// the pixels that changed since the last present, if the program knows
  /// (else all of them).
  public mutating func present(_ id: WindowID, _ surface: consuming CPUSurface, configSeq: UInt64,
                               damage: (x: Int32, y: Int32, width: Int32, height: Int32)? = nil) throws(WindowError)
  {
    guard let system = windows, let w = system.window(id) else { throw .unknownWindow }
    let index = surface.buffer
    guard configSeq == w.config.configSeq else { throw .staleConfig }
    guard index < w.buffers.count else { throw .unknownWindow }
    let b = w.buffers[index]
    w.number += 1
    w.presents += 1
    if let t = w.lastTarget { w.presentTarget = (w.number, t) }
    b.number = w.number
    b.presented = w.presents
    raise(b.acquire, to: w.number)
    let previous = w.shown
    w.shown = b
    if w.connected {
      let all = RadharcIPC.Area(x: 0, y: 0, width: Int32(b.width), height: Int32(b.height))
      do {
        try w.client.present(seq: configSeq, width: UInt32(b.width), height: UInt32(b.height),
                             layers: [RadharcIPC.Layer(image: b.image, color: 0, area: all)],
                             damage: damage.map { [RadharcIPC.Area(x: $0.x, y: $0.y, width: $0.width, height: $0.height)] } ?? [],
                             acquire: w.number, number: w.number)
        w.inFlight = true
        w.frameDue = nil
        system.drainEvents(w, loop: &self)
        return
      } catch {
        if case .remote(let e) = error {
          w.shown = previous
          throw .system(e.rawValue)
        }
        // The compositor went: kept, like the presents that follow.
        system.lose(loop: &self)
      }
    }
    // Kept for the compositor's return; the buffer it replaces is free.
    if let previous, previous !== b { previous.markFree() }
  }
}
