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
// Radharc takes the framebuffer from it in V5 (the `handoff` service,
// todhchai's M4c), which comes with Radharc.
//
// Its tree:
//   status   the framebuffer, the grid, when the first frame was drawn
//            (monotonic time, which starts at kernel entry), records shown
//   screen   the grid's text, a line a row
//   write    text written here is shown (ink)

import Console
import IPC
import Node
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

/// The framebuffer the boot data names (zbi.h's croi_zbi_swfb_t).
func framebuffer(_ bootData: borrowing Handle) -> (base: UInt64, width: Int, height: Int, stride: Int, format: UInt32)? {
  guard let size = try? VMO.size(bootData), let m = try? VMO.map(bootData, length: size, writable: false) else {
    return nil
  }
  var at = 32  // past the container's header
  while at + 32 <= size {
    let type = m.load(UInt32.self, at: at)
    let length = Int(m.load(UInt32.self, at: at + 4))
    if type == 0x4246_5753, length >= 24, at + 32 + 24 <= size {  // "SWFB"
      let p = at + 32
      return (m.load(UInt64.self, at: p), Int(m.load(UInt32.self, at: p + 8)), Int(m.load(UInt32.self, at: p + 12)),
              Int(m.load(UInt32.self, at: p + 16)), m.load(UInt32.self, at: p + 20))
    }
    at += 32 + ((length + 7) & ~7)
  }
  return nil
}

/// The grid, shared by the log's thread and the tree's.
final class Shared: @unchecked Sendable {
  let lock = Lock()
  var grid: TextGrid
  let renderer: Renderer
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
    let t = Clock.monotonic()
    renderer.render(&grid)
    frames += 1
    drawNanoseconds += Clock.monotonic() - t
  }
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
    guard let fb = framebuffer(bootData), let format = PixelFormat(zbi: fb.format) else {
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
      }
    })
    tree.text("screen", read: {
      shared.lock.withLock { (0..<shared.grid.rows).map { shared.grid.text($0) + "\n" }.joined() }
    })
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
