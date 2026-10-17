// SPDX-License-Identifier: BSD-3-Clause

// bin/kbdfs (D83): the keyboard and the console, after 9front's kbdfs(8).
// Keyboard drivers push HID usages to `kbin`; its tree, which manifests
// mount before /dev, serves:
//   kbd       `k` and `K` with the keys held, `c` with what was typed (a read waits, D84)
//   cons      what was typed, cooked into lines or raw; writes go to the console
//   consctl   `rawon`, `rawoff` (raw lasts while it is open)
//   kbmap     the keymap by usage, `layer usage rune` lines
//   kbin      usages pushed by drivers: a usage, then 1 pressed or 0 released
//   kbdin     `k`, `K`, `c`, `r` and `R` messages typed for someone else
// Everything runs on its dispatcher's thread, the Keyboard's state with it.

import IPC
import Kbdfs
import Node
import Sys

func fail(_ what: String) -> Never {
  print("kbdfs: \(what)")
  Process.exit(code: 2)
}

/// The console's output: what's written to cons, and cooking's echo. The
/// console (V2 item 8) shows the debuglog; until it reads cons's writes
/// itself, they go there.
func show(_ bytes: [UInt8]) { print(String(decoding: bytes, as: UTF8.self), terminator: "") }

@main struct KbdfsService {
  static func main() {
    let start = Startup.current
    let dispatcher: IPCDispatcher
    do throws(Status) { dispatcher = try IPCDispatcher() } catch { fail("can't make a dispatcher") }
    let tree = NodeTree(dispatcher: dispatcher)
    let keyboard = Keyboard(echo: show)
    let lock = Lock()  // the Keyboard's: the closures below run on the dispatcher's thread

    var kbd: TreeNode?
    var cons: TreeNode?
    /// After keys or messages arrive: the readers waiting may have them.
    func ready() {
      if let kbd { tree.ready(kbd) }
      if let cons { tree.ready(cons) }
    }

    kbd = tree.stream("kbd", NodeStream(
      take: { keyboard.takeKbd($0) },
      opened: { lock.withLock { keyboard.kbdOpen += 1 } },
      closed: { lock.withLock { keyboard.kbdOpen -= 1 } }))
    cons = tree.stream("cons", NodeStream(
      take: { keyboard.takeCons($0) },
      write: { (data: [UInt8]) throws(NodeError) -> UInt32 in
        show(data)
        return UInt32(data.count)
      }))
    tree.stream("consctl", NodeStream(
      take: { _ in [] },
      write: { (data: [UInt8]) throws(NodeError) -> UInt32 in
        guard lock.withLock({ keyboard.control(String(decoding: data, as: UTF8.self)) }) else { throw .invalid }
        ready()  // rawon gives cons the line typed so far
        return UInt32(data.count)
      },
      opened: { lock.withLock { keyboard.consctlOpen += 1 } },
      closed: { lock.withLock { keyboard.consctlClosed() } }))
    tree.text("kbmap", read: { lock.withLock { keyboard.map.text } },
              write: { (text: String) throws(NodeError) in
                guard lock.withLock({ keyboard.map.apply(text) }) else { throw .invalid }
              })
    tree.stream("kbin", NodeStream(
      take: { _ in [] },
      write: { (data: [UInt8]) throws(NodeError) -> UInt32 in
        lock.withLock {
          keyboard.kbin(data)
        }
        ready()
        return UInt32(data.count)
      }))
    tree.stream("kbdin", NodeStream(
      take: { _ in [] },
      write: { (data: [UInt8]) throws(NodeError) -> UInt32 in
        lock.withLock { keyboard.kbdin(data) }
        ready()
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
