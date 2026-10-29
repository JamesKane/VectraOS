// SPDX-License-Identifier: BSD-3-Clause

// Radharc on the display class (D120): where devmgr has bound a display
// driver (the first `/dev/display<n>` with an output: virtio-gpu's, or
// the Sky1's lit engine's, linlon's), each enabled output gets two
// images of its size that Radharc maps and attaches, and the desk is the
// outputs side by side, left to right in the device's order, tops
// aligned. A frame's damage is copied from the composed desk into the
// image of each output it touches that isn't shown, with what the last
// frames put only in the other (Buffers), and presented there (D146).
// Without a display driver, the boot framebuffer is the one output, as
// before. A thread hears the driver's `outputsChanged` and says what the
// outputs are now.

import DisplayDevice
import IPC
import Node
import Radharc
import Sys

/// One output's two images, mapped (D146): a frame copies into the one not
/// shown and presents it, so the driver can scan out each as it is and
/// nothing drawn tears.
final class OutputImage {
  let id: UInt32
  let x: Int
  let width: Int
  let height: Int
  let images: [UInt32]
  let addresses: [UInt]
  let mapping0: Mapping, mapping1: Mapping
  var buffers: Buffers
  init(id: UInt32, x: Int, width: Int, height: Int, images: [UInt32], mapping0: consuming Mapping,
       mapping1: consuming Mapping) {
    self.id = id
    self.x = x
    self.width = width
    self.height = height
    self.images = images
    addresses = unsafe [UInt(bitPattern: mapping0.address), UInt(bitPattern: mapping1.address)]
    self.mapping0 = mapping0
    self.mapping1 = mapping1
    buffers = Buffers(width: UInt32(width), height: UInt32(height))
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
    // An engine firmware left dark has none: nothing to say.
    guard !all.isEmpty else { return nil }
    var outputs: [OutputImage] = []
    var x = 0
    for o in all where o.enabled && o.width > 0 && o.height > 0 {
      let w = Int(o.width), h = Int(o.height), bytes = (w * h * 4 + 4095) & ~4095
      // Two images, the first frame's presented (nothing shown before).
      guard let vmo0 = try? VMO.create(size: bytes), let mapping0 = try? VMO.map(vmo0, length: bytes),
        let dup0 = try? vmo0.duplicate(), let image0 = try? client.attach(vmo: dup0, width: o.width, height: o.height)
      else { continue }
      guard let vmo1 = try? VMO.create(size: bytes), let mapping1 = try? VMO.map(vmo1, length: bytes),
        let dup1 = try? vmo1.duplicate(), let image1 = try? client.attach(vmo: dup1, width: o.width, height: o.height)
      else {
        _ = try? client.detach(image: image0)
        continue
      }
      outputs.append(OutputImage(id: o.id, x: x, width: w, height: h, images: [image0, image1], mapping0: mapping0,
                                 mapping1: mapping1))
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

  /// `d` of the composed desk to each output it touches: copied into the
  /// image not shown, with what the last frames put only in the other,
  /// and presented.
  func copy(_ d: Radharc.Rect, from shadow: UnsafeMutablePointer<UInt32>, width: Int) {
    for o in outputs {
      let r = d.intersection(Radharc.Rect(x: o.x, y: 0, width: o.width, height: o.height))
      guard !r.isEmpty else { continue }
      let back = o.buffers.back
      let c = o.buffers.draw(DisplayRect(x: UInt32(r.x - o.x), y: UInt32(r.y), width: UInt32(r.width),
                                         height: UInt32(r.height)))
      for y in Int(c.y)..<Int(c.y + c.height) {
        let dst = unsafe UnsafeMutablePointer<UInt32>(bitPattern: o.addresses[back] + UInt(y * o.width * 4))! + Int(c.x)
        unsafe dst.update(from: shadow + y * width + o.x + Int(c.x), count: Int(c.width))
      }
      let area = DisplayDeviceIPC.Area(x: c.x, y: c.y, width: c.width, height: c.height)
      if (try? client.present(output: o.id, image: o.images[back], damage: [area])) != nil {
        o.buffers.shown()
        flushes += 1
      } else {
        failures += 1
      }
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
