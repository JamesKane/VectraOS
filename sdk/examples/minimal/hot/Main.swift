// SPDX-License-Identifier: BSD-3-Clause

// minimal-hot: minimal, the SDK's reference app, hot reloading its frame
// (hotreload(2)). The image named by its argument draws each frame through
// HotHost, which reloads it when the file changes; the frames drawn live
// in the state block, so they carry on across reloads. With Radharc it
// draws in a window, as minimal does; without, 320x180 pixels of its own,
// at 60 frames a second. Its `status` says which image runs and how the
// last reload went; so does IMAGE.status beside the image, written at each
// load or refusal, for a cpu session, which can't see the app's tree.

import Hot
import IPC
import Node
import Sys
import VX

nonisolated(unsafe) var statusText = ""
let statusLock = Lock()

/// `text` as the whole of `path`, made if it isn't there.
func write(_ ns: Namespace, _ path: String, _ text: String) {
  var file: NodeIPC.NodeClient
  if let f = try? ns.open(path) { file = f } else if let f = try? ns.create(path, kind: .file) { file = f } else { return }
  try? file.wstat(NodeIPC.Wstat(size: 0))
  try? file.writeText(text)
}

func fail(_ what: String) -> Never {
  print("minimal-hot: \(what)")
  Process.exit(code: 1)
}

@main struct MinimalHot {
  static func main() {
    let start = Startup.current
    let args = processArguments()
    guard args.count > 1 else { fail("usage: minimal-hot IMAGE") }
    let ns: Namespace
    do throws(NamespaceError) { ns = try Namespace(start) } catch { fail("no namespace") }
    var host: HotHost
    do throws(HotHost.Failure) { host = try HotHost(image: args[1], namespace: ns) } catch {
      fail(HotHost.describe(error))
    }
    if let export = start.export(), let dispatcher = try? IPCDispatcher() {
      let tree = NodeTree(dispatcher: dispatcher)
      tree.text("status", read: { statusLock.withLock { statusText } })
      if (try? tree.serve(export)) != nil { _ = try? Thread.spawn { try? dispatcher.run() }.release() }
    }

    var loop: Loop
    do { loop = try Loop() } catch { fail("no loop") }
    let window = try? loop.openWindow("minimal-hot", width: 320, height: 180)
    var own = [UInt32](repeating: 0, count: 320 * 180)
    var seq: UInt64 = 0
    var frames: Int64 = 0
    var version: Int32 = 0
    var loads = 0
    var refusal: String?
    if let window { loop.requestFrame(window) } else { loop.timer(at: .now, repeating: .milliseconds(16)) }

    func draw(_ pixels: UInt, _ width: Int, _ height: Int, _ stride: Int, target: UInt64) {
      var f = HotFrame()
      f.pixels = pixels
      f.width = Int32(width)
      f.height = Int32(height)
      f.stride = Int32(stride)
      f.frame = frames
      f.target = Int64(target)
      // A load happens at a frame's end: the frame after is the new image's.
      let loaded = host.loads
      version = host.frame(&f, now: Sys.Clock.monotonic())
      frames += 1
      let drawn = unsafe host.block.load(fromByteOffset: 16, as: Int64.self)
      let line = "image \(version) loads \(host.loads) last \(host.lastLoad / 1000) us frames \(frames) drawn \(drawn)\n"
        + (host.refused.map { "refused \($0)\n" } ?? "")
      statusLock.withLock { statusText = line }
      let refusedNow = host.refused != nil && host.refused?.utf8.elementsEqual((refusal ?? "").utf8) != true
      if loaded != loads || refusedNow {
        loads = loaded
        refusal = host.refused
        print("minimal-hot: image \(version), load \(loads) in \(host.lastLoad / 1000) us")
        if let why = host.refused { print("minimal-hot: refused: \(why)") }
        write(ns, args[1] + ".status", line)
      }
    }

    while true {
      for e in loop.wait() {
        switch e.payload {
        case .configure(let c): seq = c.configSeq
        case .frame(let f):
          if let window, let px = loop.cpuSurface(window) {
            draw(UInt(bitPattern: unsafe px.pixels.baseAddress), Int(px.width), Int(px.height), px.stride / 4,
                 target: f.target.ns)
            try? loop.present(window, px, configSeq: seq)
            loop.requestFrame(window)
          }
        case .timer:
          own.withUnsafeMutableBufferPointer { b in
            draw(UInt(bitPattern: b.baseAddress), 320, 180, 320, target: Deadline.now.ns)
          }
        case .keyDown(let k) where k.usage == .escape: return
        case .close: return
        default: break
        }
      }
    }
  }
}
