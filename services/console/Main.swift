// SPDX-License-Identifier: BSD-3-Clause

// bin/console (M3j; V2 item 8): the framebuffer text console. It maps the
// GOP framebuffer that croi's boot data names (`bootdata`; a physical VMO
// under its `resource mmio`, write-combining) and shows the system's log
// as it comes: it reads the debuglog's ring (`debuglog`, D38) from the
// oldest record kept, each record a line as croi's console prints it,
// warnings amber and errors magenta. Text written to its `write` leaf is
// shown too: kbdfs (D83) writes its echo and what is written to its cons
// there, so the console is the window of the shell on it (rc, `shell`).
//
// Radharc takes the framebuffer from it (D107, todhchai's M4c): it calls
// the console's `handoff` with a channel to itself, and the console stops
// drawing to the framebuffer and opens a window there, of the screen less
// a margin, drawing its grid into the window's one image from then on.
//
// Its tree:
//   status   the framebuffer, the grid, when the first frame was drawn
//            (monotonic time, which starts at kernel entry), records shown
//   screen   the grid's text, a line a row
//   write    text written here is shown (ink)
//   kprint   the log as text, read from its oldest line kept and then as
//            it comes (`log -f`; manifests mount it at /dev/kprint)
//   handoff  RadharcIPC.Handoff: the compositor takes the framebuffer

import Console
import IPC
import Node
import Radharc
import Ring
import Sys

func fail(_ what: String) -> Never {
  print("console: \(what)")
  Process.exit(code: 1)
}

/// A debuglog record (log.h's croi_log_record_t, then its text).
struct Record {
  var sequence: UInt64
  var severity: UInt8
  var timestamp: Int64
  var pid: UInt64
  var tid: UInt64
  var text: [UInt8]

  static let header = 40

  init?(_ slot: [UInt8]) {
    guard slot.count >= Self.header else { return nil }
    func u64(_ at: Int) -> UInt64 { (0..<8).reduce(0) { $0 | UInt64(slot[at + $1]) << (8 * UInt64($1)) } }
    let length = Int(slot[12]) | Int(slot[13]) << 8
    guard Self.header + length <= slot.count else { return nil }
    sequence = u64(0)
    severity = slot[14]
    timestamp = Int64(bitPattern: u64(16))
    pid = u64(24)
    tid = u64(32)
    text = Array(slot[Self.header..<Self.header + length])
  }

  /// The record as croi's console prints it: `[sssss.mmm] pid:tid> text`.
  var line: [UInt8] {
    func digits(_ v: UInt64, _ width: Int) -> String {
      var s = String(v)
      while s.utf8.count < width { s = "0" + s }
      return s
    }
    let ms = UInt64(max(timestamp, 0)) / 1_000_000
    let head = "[\(digits(ms / 1000, 5)).\(digits(ms % 1000, 3))] \(digits(pid, 5)):\(digits(tid, 5))> "
    var body = text
    while body.last == 0x0A { body.removeLast() }
    return Array(head.utf8) + body + [0x0A]
  }

  /// Its line's color by severity: magenta for errors, amber for warnings.
  var color: UInt8 {
    switch severity {
    case 0x50...: 4
    case 0x40...: 3
    default: 0
    }
  }
}

/// The grid, shared by the log's thread and the tree's.
/// The log as text for `kprint` (D79's `log -f`): its last `limit` bytes
/// of lines, each record's as the screen shows it, and where they start
/// in all the log has had, so each reader keeps its own place.
final class Kept: @unchecked Sendable {
  let lock = Lock()
  var bytes: [UInt8] = []
  /// The offset of `bytes[0]` in the whole log.
  var start: UInt64 = 0
  /// Told when lines come (the tree's `ready` for the stream).
  var added: (@Sendable () -> Void)?
  static let limit = 65536

  func append(_ line: [UInt8]) {
    let tell = lock.withLock { () -> (@Sendable () -> Void)? in
      bytes += line
      if bytes.count > Self.limit {
        let cut = bytes.count - Self.limit
        bytes.removeFirst(cut)
        start += UInt64(cut)
      }
      return added
    }
    tell?()
  }

  /// A reader from the oldest line kept: up to `max` bytes from its place
  /// (moved up to what is kept, if the log has passed it), nil when it
  /// has read everything so far (its read waits).
  func reader() -> NodeStreamChannel {
    var at = lock.withLock { start }
    return NodeStreamChannel(take: { [self] max in
      lock.withLock { () -> [UInt8]? in
        if at < start { at = start }
        let end = start + UInt64(bytes.count)
        guard at < end else { return nil }
        let from = Int(at - start), n = Swift.min(max, Int(end - at))
        at += UInt64(n)
        return Array(bytes[from..<(from + n)])
      }
    })
  }
}

final class Shared: @unchecked Sendable {
  let lock = Lock()
  var grid: TextGrid
  /// The framebuffer's, until Radharc takes it; then the window's (none
  /// between the two).
  var renderer: Renderer?
  var window: ConsoleWindow?
  var records = 0
  var dropped: UInt64 = 0
  var frames = 0
  var drawNanoseconds: Int64 = 0

  init(_ renderer: Renderer) {
    self.renderer = renderer
    grid = renderer.grid()
  }

  /// Under the lock.
  func show(_ color: UInt8, _ bytes: [UInt8]) {
    grid.color = color
    grid.write(bytes)
  }

  /// Under the lock.
  func draw() {
    guard let renderer else { return }  // handed over, the window not yet open
    let t = Clock.monotonic()
    let dirty = grid.dirty
    renderer.render(&grid)
    window?.drew(dirty: dirty, rowHeight: renderer.font.height)
    frames += 1
    drawNanoseconds += Clock.monotonic() - t
  }
}

struct Handoff: RadharcIPC.HandoffHandler {
  let taken: (consuming Handle) -> Void
  func take(compositor: consuming Handle) { taken(compositor) }
}

/// The console's window: one image the renderer draws into, presented
/// with the rows that changed. A present takes the window's one credit;
/// rows that change before its `frame` gives it back are presented then
/// (`events`, on a thread of its own, takes the window's events). The image
/// is drawn while it's shown: text can tear for a frame, which a console
/// can afford.
final class ConsoleWindow: @unchecked Sendable {
  var client: RadharcIPC.WindowClient
  let mapping: Mapping
  let acquire: Handle
  let release: Handle
  let width: Int
  let height: Int
  var seq: UInt64
  var number: Int64 = 0
  var credits = 1
  /// Rows drawn and not yet presented (pixel rows), all of them at first.
  var owed: (first: Int, last: Int)?
  var frames = 0

  init(client: consuming RadharcIPC.WindowClient, mapping: consuming Mapping, acquire: consuming Handle,
       release: consuming Handle, width: Int, height: Int, seq: UInt64)
  {
    self.client = client
    self.mapping = mapping
    self.acquire = acquire
    self.release = release
    self.width = width
    self.height = height
    self.seq = seq
    owed = (0, height)
  }

  var pixels: UnsafeMutableRawPointer { unsafe mapping.address }

  /// Opens the window: the screen less a margin, in whole cells.
  static func open(_ channel: consuming Handle, font: Font) -> ConsoleWindow? {
    var compositor = RadharcIPC.CompositorClient(channel: channel)
    let screen: RadharcIPC.ScreenInfo
    do { screen = try compositor.screen() } catch {
      print("console: the compositor's screen: \(error)")
      return nil
    }
    let columns = min(100, (Int(screen.width) - 64) / font.width)
    let rows = min(30, (Int(screen.height) - 96) / font.height)
    guard columns > 0, rows > 0 else {
      print("console: a screen of \(screen.width)x\(screen.height) is too small")
      return nil
    }
    let width = columns * font.width, height = rows * font.height
    let bytes = (width * height * 4 + 4095) & ~4095
    do throws(Status) {
      let opened: RadharcIPC.Opened
      do { opened = try compositor.open(title: "console", width: UInt32(width), height: UInt32(height)) } catch {
        print("console: opening a window: \(error)")
        return nil
      }
      let vmo = try VMO.create(size: bytes)
      let mapping = try VMO.map(vmo, length: bytes)
      let acquire = try Counter.create(), release = try Counter.create()
      let seq = opened.first.seq
      var client = RadharcIPC.WindowClient(channel: opened.takeWindow())
      do {
        try client.addImage(id: 1, vmo: try vmo.duplicate(), width: UInt32(width), height: UInt32(height),
                            stride: UInt32(width), acquire: try acquire.duplicate(), release: try release.duplicate())
      } catch {
        print("console: adding its image: \(error)")
        return nil
      }
      return ConsoleWindow(client: client, mapping: mapping, acquire: acquire, release: release, width: width,
                           height: height, seq: seq)
    } catch {
      print("console: making its image: \(error.rawValue)")
      return nil
    }
  }

  /// The rows `dirty` marks were drawn: presented now if there's a credit.
  func drew(dirty: [Bool], rowHeight: Int) {
    if let first = dirty.firstIndex(of: true), let last = dirty.lastIndex(of: true) {
      let rows = (first * rowHeight, min(height, (last + 1) * rowHeight))
      owed = owed.map { (min($0.first, rows.0), max($0.last, rows.1)) } ?? rows
    }
    events()
  }

  func presentOwed() {
    guard credits > 0, let rows = owed else { return }
    owed = nil
    credits -= 1
    number += 1
    try? Counter.add(acquire, 1)
    let all = RadharcIPC.Area(x: 0, y: 0, width: Int32(width), height: Int32(height))
    let damage = RadharcIPC.Area(x: 0, y: Int32(rows.first), width: Int32(width), height: Int32(rows.last - rows.first))
    do {
      try client.present(seq: seq, width: UInt32(width), height: UInt32(height),
                         layers: [RadharcIPC.Layer(image: 1, color: 0, area: all)], damage: [damage],
                         acquire: number, number: number)
    } catch {
      // No credit after all: kept for the next frame.
      owed = rows
      credits = 0
    }
  }

  /// Takes the events waiting: a configure's sequence (the console keeps
  /// its size), a frame's credit; and presents what's owed. A present's
  /// call queues events that come during it in the connection, where the
  /// channel's readable signal doesn't show them: so this drains again
  /// after each present.
  func events() {
    while true {
      while let e = try? client.nextEvent(deadline: 0) {
        switch e {
        case .configure(let c): seq = c.seq
        case .frame(let f):
          credits = Int(f.credits)
          frames += 1
        case .moved, .viewGone: break  // it doesn't place itself, nor embed
        case .closeRequested: break  // the system log stays (M6l)
        }
      }
      guard credits > 0, owed != nil else { return }
      presentOwed()
    }
  }

  /// The window's channel, to wait on (the client keeps it).
  var channelRaw: UInt32 { client.connection.channel.raw }
}

@main struct ConsoleProgram {
  static func main() {
    let start = Startup.current
    guard let mmio = start.take(HandleType.info(HandleType.resource(.mmio))) else {
      fail("no MMIO resource (its manifest's `resource mmio`)")
    }
    guard let bootData = start.take(HandleType.info(HandleType.vmoBootData)) else {
      fail("no boot data (its manifest's `bootdata`)")
    }
    guard let fb = BootFramebuffer(bootData: bootData), let format = PixelFormat(zbi: fb.format) else {
      fail("no linear framebuffer in the boot data")
    }
    let t0 = Clock.monotonic()
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
    let font = fb.width >= 2560 ? Font.spleen16x32 : Font.spleen8x16
    let renderer = unsafe Renderer(unsafe: mapping.address + Int(fb.base - pageBase), width: fb.width,
                                   height: fb.height, stride: fb.stride, format: format, font: font)
    let shared = Shared(renderer)
    let kept = Kept()
    let title = "VectraOS console: \(fb.width)x\(fb.height), \(shared.grid.columns)x\(shared.grid.rows) cells of Spleen \(font.width)x\(font.height)\n"
    shared.lock.withLock {
      shared.show(2, Array(title.utf8))
      shared.draw()
    }
    let firstFrame = Clock.monotonic()
    print("console: first frame at \(firstFrame / 1_000_000) ms (mapping and drawing \((firstFrame - t0) / 1000) us)")

    // The log, on a thread of its own: the ring read as an OVERWRITE
    // reader, waiting on its counter (the producer's cursor) when caught up.
    if let ringVMO = start.take(HandleType.info(HandleType.vmoDebuglog)),
      let counter = start.take(HandleType.info(HandleType.debuglogCounter))
    {
      let slotSize = 256, slots = 512
      let ringSize = RingLayout.size(slotSize: slotSize, count: slots)!
      let mapped = (ringSize + 4095) & ~4095
      do throws(Status) {
        let ringMapping = try VMO.map(ringVMO, length: mapped, writable: false)
        let base = unsafe ringMapping.address
        let counterRaw = counter.release()
        _ = try Thread.spawn {
          let counter = Handle(raw: counterRaw)
          guard var ring = unsafe NativeRing(attaching: base, size: ringSize, producer: false, slotSize: slotSize,
                                             format: 0x474F_4C44, flags: RingLayout.overwrite)
          else {
            print("console: the debuglog isn't a ring of its kind")
            return
          }
          var slot = [UInt8](repeating: 0, count: slotSize)
          while true {
            var records: [Record] = []
            var dropped: UInt64 = 0
            while unsafe slot.withUnsafeMutableBytes({ unsafe ring.read(to: $0.baseAddress!, dropped: &dropped) }) {
              if let r = Record(slot) { records.append(r) }
            }
            if !records.isEmpty || dropped > 0 {
              shared.lock.withLock {
                for r in records { shared.show(r.color, r.line) }
                shared.records += records.count
                shared.dropped += dropped
                shared.draw()
              }
              kept.append(records.flatMap { $0.line })
            }
            _ = try? Counter.wait(counter, until: Int64(ring.position) + 1)
            withExtendedLifetime(ringMapping) {}
          }
        }.release()
      } catch {
        print("console: can't read the log: \(error.rawValue)")
      }
    } else {
      print("console: no debuglog (its manifest's `debuglog`): the log isn't shown")
    }

    let dispatcher: IPCDispatcher
    do throws(Status) { dispatcher = try IPCDispatcher() } catch { fail("can't make a dispatcher") }
    let tree = NodeTree(dispatcher: dispatcher)
    let geometry = "framebuffer \(fb.width)x\(fb.height) stride \(fb.stride) \(format == .rgbx888 ? "rgbx888" : "bgr888x")\n"
      + "font spleen \(font.width)x\(font.height)\nfirst frame \(firstFrame) ns\n"
    tree.text("status", read: {
      shared.lock.withLock {
        geometry + "grid \(shared.grid.columns)x\(shared.grid.rows)\nrecords \(shared.records) dropped \(shared.dropped)\n"
          + "frames \(shared.frames) drawing \(shared.drawNanoseconds / 1000) us\n"
          + (shared.window.map { "window \($0.width)x\($0.height) presents \($0.number) frames \($0.frames)\n" } ?? (shared.renderer == nil ? "handed over\n" : ""))
      }
    })
    tree.text("screen", read: {
      shared.lock.withLock { (0..<shared.grid.rows).map { shared.grid.text($0) + "\n" }.joined() }
    })
    // kprint: the log as text, from the oldest line kept, each reader
    // waiting for more once it has read all there is (D84).
    let kprint = tree.stream("kprint", NodeStream(perChannel: { kept.reader() }))
    kept.lock.withLock { kept.added = { tree.ready(kprint) } }
    tree.service("handoff") { (channel: consuming Handle) throws(Status) in
      try dispatcher.add(RadharcIPC.HandoffServer(channel: channel, impl: Handoff { compositor in
        // Off the framebuffer now; the window is opened on a thread of its
        // own, since Radharc waits for this reply before it serves.
        shared.lock.withLock { shared.renderer = nil }
        let raw = compositor.release()
        _ = try? Thread.spawn {
          guard let window = ConsoleWindow.open(Handle(raw: raw), font: font) else {
            print("console: no window from the compositor")
            return
          }
          shared.lock.withLock {
            let columns = window.width / font.width, rows = window.height / font.height
            shared.grid = TextGrid(columns: columns, rows: rows, from: shared.grid)
            shared.renderer = unsafe Renderer(unsafe: window.pixels, width: window.width, height: window.height,
                                              stride: window.width, format: .rgbx888, font: font)
            shared.window = window
            shared.draw()
          }
          print("console: in a window of Radharc's, \(window.width)x\(window.height)")
          // Its events, as they come: borrowed, the window keeps its channel.
          let channel = Handle(raw: window.channelRaw)
          while true {
            guard let seen = try? channel.wait(for: Signals.readable | Signals.peerClosed),
              seen & Signals.readable != 0
            else { break }
            shared.lock.withLock { window.events() }
          }
          _ = channel.release()
        }
      }))
    }
    tree.text("write", read: { "" }, write: { (text: String) throws(NodeError) in
      shared.lock.withLock {
        shared.show(1, Array(text.utf8))
        shared.draw()
      }
    })
    guard let export = start.export() else { fail("no export (its manifest's `export`)") }
    do throws(Status) {
      try tree.serve(export)
      try dispatcher.run()
    } catch {
      fail("can't serve: \(error.rawValue)")
    }
    _ = consume mapping
  }
}
