// SPDX-License-Identifier: BSD-3-Clause

// Radharc on the display class (D120): where devmgr has bound a display
// driver (the first `/dev/display<n>` with an output: virtio-gpu's, or
// the Sky1's lit engine's, linlon's), each enabled output gets an
// image of its size that Radharc maps, attaches and shows, and the desk is
// the outputs side by side, left to right in the device's order, tops
// aligned. A frame's damage is copied from the composed desk into each
// output's image it touches and flushed there. Without a display driver,
// the boot framebuffer is the one output, as before. A thread hears the
// driver's `outputsChanged` and says what the outputs are now.

import DisplayDevice
import IPC
import Node
import Radharc
import Sys

/// One output's image, mapped.
final class OutputImage {
  let id: UInt32
  let x: Int
  let width: Int
  let height: Int
  let image: UInt32
  let address: UInt
  let mapping: Mapping
  init(id: UInt32, x: Int, width: Int, height: Int, image: UInt32, mapping: consuming Mapping) {
    self.id = id
    self.x = x
    self.width = width
    self.height = height
    self.image = image
    address = unsafe UInt(bitPattern: mapping.address)
    self.mapping = mapping
  }
}

/// The outputs of a display driver, as one desk.
final class DisplaySink: @unchecked Sendable {
  var client: DisplayDeviceIPC.DisplayClient
  let outputs: [OutputImage]
  var flushes = 0, failures = 0
  /// The driver's outputs since it last said they changed, and how often.
  var changes = 0
  var now = ""

  init(client: consuming DisplayDeviceIPC.DisplayClient, outputs: [OutputImage]) {
    self.client = client
    self.outputs = outputs
  }

  var width: Int { outputs.map { $0.x + $0.width }.max() ?? 0 }
  var height: Int { outputs.map { $0.height }.max() ?? 0 }

  /// What `status` says: each output, `<id> <w>x<h>+<x>`.
  var summary: String { outputs.map { "\($0.id) \($0.width)x\($0.height)+\($0.x)" }.joined(separator: ", ") }

  /// The outputs of the driver at `path`, attached and shown; nil if there
  /// is none, or it has no enabled output.
  static func open(_ ns: Namespace, _ path: String) -> DisplaySink? {
    guard let ch = try? ns.connect(path) else { return nil }
    var client = DisplayDeviceIPC.DisplayClient(channel: ch)
    guard let all = try? client.outputs() else {
      print("radharc: \(path) doesn't answer `outputs`")
      return nil
    }
    var outputs: [OutputImage] = []
    var x = 0
    for o in all where o.enabled && o.width > 0 && o.height > 0 {
      let w = Int(o.width), h = Int(o.height), bytes = (w * h * 4 + 4095) & ~4095
      guard let vmo = try? VMO.create(size: bytes), let mapping = try? VMO.map(vmo, length: bytes),
        let dup = try? vmo.duplicate(), let image = try? client.attach(vmo: dup, width: o.width, height: o.height),
        (try? client.show(output: o.id, image: image)) != nil
      else { continue }
      outputs.append(OutputImage(id: o.id, x: x, width: w, height: h, image: image, mapping: mapping))
      x += w
    }
    guard !outputs.isEmpty else {
      print("radharc: \(path) has no output it can show an image on")
      return nil
    }
    return DisplaySink(client: client, outputs: outputs)
  }

  /// The first display driver at /dev/display<n> with an output it can
  /// show an image on (a board has a driver for each display engine, and
  /// firmware lights one), and its name there.
  static func first(_ ns: Namespace) -> (sink: DisplaySink, name: String)? {
    var n = 0
    while (try? ns.list("/dev/display\(n)")) != nil {
      if let s = open(ns, "/dev/display\(n)/display") { return (s, "display\(n)") }
      n += 1
    }
    return nil
  }

  /// `d` of the composed desk to each output it touches, flushed there.
  func copy(_ d: Radharc.Rect, from shadow: UnsafeMutablePointer<UInt32>, width: Int) {
    for o in outputs {
      let r = d.intersection(Radharc.Rect(x: o.x, y: 0, width: o.width, height: o.height))
      guard !r.isEmpty else { continue }
      for y in r.y..<r.maxY {
        let dst = unsafe UnsafeMutablePointer<UInt32>(bitPattern: o.address + UInt(y * o.width * 4))! + (r.x - o.x)
        unsafe dst.update(from: shadow + y * width + r.x, count: r.width)
      }
      let area = DisplayDeviceIPC.Area(x: UInt32(r.x - o.x), y: UInt32(r.y), width: UInt32(r.width),
                                       height: UInt32(r.height))
      if (try? client.flush(image: o.image, damage: [area])) != nil { flushes += 1 } else { failures += 1 }
    }
  }
}

/// Hears the driver's `outputsChanged` on a channel of its own, for good:
/// each change, the outputs as they are now, for `status`.
func followOutputs(_ ns: Namespace, _ path: String, _ sink: DisplaySink, _ lock: Lock) {
  guard let ch = try? ns.connect(path) else { return }
  let raw = ch.release()
  _ = try? Thread.spawn {
    var client = DisplayDeviceIPC.DisplayClient(channel: Handle(raw: raw))
    _ = try? client.outputs()
    while let e = try? client.nextEvent() {
      guard case .outputsChanged = e else { continue }
      let now = ((try? client.outputs()) ?? []).filter { $0.enabled }.map { "\($0.id) \($0.width)x\($0.height)" }
      lock.withLock {
        sink.changes += 1
        sink.now = now.joined(separator: ", ")
      }
      print("radharc: the outputs changed: \(now.isEmpty ? "none" : now.joined(separator: ", "))")
    }
  }.release()
}
