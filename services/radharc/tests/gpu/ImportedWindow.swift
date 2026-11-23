// SPDX-License-Identifier: BSD-3-Clause

// compose-test's check of a window's image sampled where it lies (the board's, D174, "Presentation, as designed"): a client
// device of its own (another context of the GPU, as a window's program has) makes a window's frame with `makePresentImage`,
// direct on Mali, and clears it (the Mali backend clears a pass with no draw on the CPU, into the image's own pages); the
// window's handle is mapped as Radharc maps a client's image, with the frame's stride, and Radharc's GPU renderer composes a
// scene with it. Frames 128 and 100 pixels wide (rows of 512 bytes, and of 400 padded to 448) the renderer must import,
// uploading nothing, and its frame must show the client's colour where the window is, as the CPU's renderer composes it;
// then the client clears the same pages to another colour and presents again, and the next frame must show that one.

import GPUCore
import GPUCoreMali
import Node
import Radharc
import RadharcGPU
import Sys

func importedWindowCheck(_ ns: Namespace) {
  let width = 640, height = 480
  guard let gpu = GPURenderer.open(ns, width: width, height: height), gpu.backend.utf8.elementsEqual("mali".utf8)
  else { return }
  let client: MaliDevice
  do { client = try MaliDevice() } catch {
    check(false, "a second context of the GPU, for a window's program (\(error))")
    return
  }
  let shown = UnsafeMutablePointer<UInt32>.allocate(capacity: width * height)
  let fromCPU = UnsafeMutablePointer<UInt32>.allocate(capacity: width * height)
  defer {
    unsafe shown.deallocate()
    unsafe fromCPU.deallocate()
  }
  var signal: UInt64 = 0
  var source: UInt64 = 0
  for w in [128, 100] {
    let h = 60
    let frame: PresentImage
    do { frame = try client.makePresentImage(format: .bgra8, width: Int32(w), height: Int32(h), usage: .renderTarget) } catch {
      check(false, "a window's frame of \(w)x\(h) on the client's device (\(error))")
      continue
    }
    /// The client clears its frame to 0x00RRGGBB.
    func draw(_ rgb: UInt32) -> Bool {
      let r = Float(rgb >> 16 & 0xFF) / 255, g = Float(rgb >> 8 & 0xFF) / 255, b = Float(rgb & 0xFF) / 255
      var list = GPUCommandList()
      list.render(RenderingInfo(colors: [Attachment(image: frame.image, load: .clear(r, g, b, 1))])) { _ in }
      signal += 1
      do { try client.run(list, signal: signal) } catch { return false }
      return true
    }
    guard frame.isDirect, draw(0x30_80C0), let raw = frame.exportHandle(client) else {
      check(false, "the client's \(w)x\(h) frame is its own pages, drawn and given to a window")
      client.destroy(frame)
      continue
    }
    let vmo = Handle(raw: raw)
    guard let mapping = try? VMO.map(vmo, length: (frame.bytes + 4095) & ~4095, writable: false) else {
      check(false, "the window's handle maps as Radharc maps a client's image")
      client.destroy(frame)
      continue
    }
    var pixels = unsafe Pixels(unsafe: mapping.address, width: w, height: h, stride: Int(frame.stridePixels))
    pixels.vmo = vmo.raw
    source += 1
    pixels.source = source
    let scene = Scene(width: width, height: height)
    let (win, _) = scene.open(title: "imported", width: w, height: h)
    win.images.append((1, pixels))
    /// Presents the client's frame and composes it on the GPU and the CPU: the pixels of the window's content that differ
    /// by more than 3 steps, and the CPU's centre pixel (the client's colour, read through the window's mapping).
    func compose(_ seq: UInt64) -> (differ: Int, centre: UInt32)? {
      scene.present(win.id, seq: seq, size: (w, h), layers: [Layer(image: 1, rect: Rect(x: 0, y: 0, width: w, height: h))], damage: nil)
      scene.damageAll()
      guard unsafe gpu.render(scene, damage: scene.takeDamage(), into: shown) else { return nil }
      scene.damageAll()
      unsafe scene.compose(scene.takeDamage(), into: fromCPU, stride: width) { _ in InlineArray<16, UInt8>(repeating: 0) }
      var differ = 0
      let c = win.content
      for y in c.y..<(c.y + c.height) {
        for x in c.x..<(c.x + c.width) {
          let a = unsafe shown[y * width + x], b = unsafe fromCPU[y * width + x]
          for shift in [UInt32(0), 8, 16] {
            let d = Int(a >> shift & 0xFF) - Int(b >> shift & 0xFF)
            if d > 3 || d < -3 {
              differ += 1
              break
            }
          }
        }
      }
      return (differ, unsafe fromCPU[(c.y + c.height / 2) * width + c.x + c.width / 2] & 0xFF_FFFF)
    }
    let before = gpu.imported
    let how = "sampled where it lies (rows of \(frame.stridePixels * 4) bytes)"
    if let first = compose(1) {
      check(gpu.imported - before == 1,
            "a \(w)-pixel window's GPU image is \(how) by Radharc's GPU renderer (\(gpu.imported - before) presents imported)")
      check(first.differ == 0 && first.centre == 0x30_80C0,
            "the \(w)-pixel window's image composes as the CPU's renderer does (\(first.differ) pixels differ, the centre 0x\(String(first.centre, radix: 16)))")
    } else {
      check(false, "a frame with a \(w)-pixel window's GPU image composes on the GPU (\(gpu.failure ?? "?"))")
    }
    // The client clears the same pages again and presents: the next frame shows the new colour.
    if draw(0xC0_4010), let second = compose(2) {
      check(second.differ == 0 && second.centre == 0xC0_4010,
            "the \(w)-pixel window's next frame, in the same pages, is what the GPU renderer composes (\(second.differ) pixels differ, the centre 0x\(String(second.centre, radix: 16)))")
    } else {
      check(false, "the client's second \(w)-pixel frame is drawn and composed")
    }
    _ = consume mapping
    _ = consume vmo
    client.destroy(frame)
  }
}
