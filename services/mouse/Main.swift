// SPDX-License-Identifier: BSD-3-Clause

// bin/mouse (D83): the pointer, after 9front's devmouse. Pointer drivers
// write records to `mousein`; its tree, which manifests mount at /dev
// after kbdfs's, serves:
//   mouse     `m x y buttons msec` messages, 49 bytes, as the pointer
//             changes (a read waits, D84); each channel reads its own
//   mousein   records from drivers, `m dx dy b`, `A x y b`, `a x y b`;
//             a read gives the state without waiting
//   mousectl  `buttonmap`, `swap`, `scrollswap`, `accelerated`, `linear`, `reset`
// The screen the pointer stays inside is the boot framebuffer's.
// Everything runs on its dispatcher's thread, the Mouse's state with it.

import IPC
import Mouse
import Node
import Sys

func fail(_ what: String) -> Never {
  print("mouse: \(what)")
  Process.exit(code: 2)
}

/// Milliseconds since boot, as a record's time.
func msec() -> UInt32 { UInt32(truncatingIfNeeded: Clock.monotonic() / 1_000_000) }

@main struct MouseService {
  static func main() {
    let start = Startup.current
    // The screen: the boot framebuffer's size (1024x768 if there's none).
    var width = 1024, height = 768
    if let bootData = start.take(HandleType.info(HandleType.vmoBootData)), let fb = BootFramebuffer(bootData: bootData) {
      (width, height) = (fb.width, fb.height)
    }
    let mouse = Mouse(width: Int32(width), height: Int32(height))
    let dispatcher: IPCDispatcher
    do throws(Status) { dispatcher = try IPCDispatcher() } catch { fail("can't make a dispatcher") }
    let tree = NodeTree(dispatcher: dispatcher)

    var node: TreeNode?
    /// After the pointer changes: its readers may have a message.
    func ready() { if let node { tree.ready(node) } }

    node = tree.stream("mouse", NodeStream(perChannel: {
      let reader = mouse.open()
      return NodeStreamChannel(take: { _ in mouse.read(reader) }, closed: { mouse.close(reader) })
    }, write: { (data: [UInt8]) throws(NodeError) -> UInt32 in
      guard mouse.move(data, msec: msec()) else { throw .invalid }
      ready()
      return UInt32(data.count)
    }))
    tree.stream("mousein", NodeStream(perChannel: {
      let writer = MouseWriter()
      return NodeStreamChannel(take: { _ in mouse.current() }, write: { (data: [UInt8]) throws(NodeError) -> UInt32 in
        let taken = mouse.mousein(data, from: writer, msec: msec())
        ready()
        guard taken else { throw .invalid }
        return UInt32(data.count)
      }, closed: {
        mouse.closed(writer, msec: msec())
        ready()
      })
    }))
    tree.stream("mousectl", NodeStream(
      take: { _ in [] },
      write: { (data: [UInt8]) throws(NodeError) -> UInt32 in
        guard mouse.control(data) else { throw .invalid }
        return UInt32(data.count)
      }))
    guard let export = start.export() else { fail("no export (its manifest's `export`)") }
    do throws(Status) {
      try tree.serve(export)
      try dispatcher.run()
    } catch {
      fail("can't serve: \(error.rawValue)")
    }
  }
}
