// SPDX-License-Identifier: BSD-3-Clause

// bin/fs [--format LABEL] PARTITION (fs(4)): a Taisce volume on a disk's
// partition in its namespace (`/dev/sdZ0/data`, ramdisk(4)'s), served
// at `volume` in its tree, beside `status`. With --format, a partition
// that holds no volume gets one labelled LABEL, its UUID from the
// kernel's CPRNG. The volume's channels are served on a thread of their
// own; the tree forwards walks into `volume` to them.

import Fs
import FsServer
import IPC
import Node
import Sys
import Taisce

func fail(_ what: String) -> Never {
  print("fs: \(what)")
  Process.exit(code: 1)
}

@main struct FsProgram {
  static func main() {
    let start = Startup.current
    var path: String?, label: String?
    var args = start.args.dropFirst()
    while let arg = args.popFirst() {
      if NodeIPC.same(arg, "--format") {
        guard let l = args.popFirst() else { fail("usage: fs [--format LABEL] PARTITION") }
        label = l
      } else {
        path = arg
      }
    }
    guard let path else { fail("usage: fs [--format LABEL] PARTITION") }
    let ns: Namespace
    do throws(NamespaceError) { ns = try Namespace(start) } catch { fail("no namespace") }
    let channel: Handle
    do throws(NamespaceError) { channel = try ns.open(path).takeChannel() } catch { fail("no partition \(path)") }
    var fs: FileSystem<NodeDevice>
    do throws(TaisceError) {
      let device = try NodeDevice(channel)
      do throws(TaisceError) {
        fs = try FileSystem.mount(device)
      } catch .notAVolume where label != nil {
        guard let uuid = try? CPRNG.draw(count: 16) else { fail("no random bytes") }
        fs = try FileSystem.format(device, label: Array(label!.utf8), uuid: uuid, now: FsService.now)
      }
    } catch {
      fail("no volume on \(path)")
    }
    do throws(Status) {
      let volume = try IPCDispatcher()
      let service = try FsService(fs, device: path, dispatcher: volume)
      let root: Handle
      do throws(NodeError) { root = try service.root() } catch { fail("no root") }
      _ = try Thread.spawn {
        do throws(Status) { try volume.run() } catch { fail("the volume's dispatcher: \(error)") }
      }.release()
      let dispatcher = try IPCDispatcher()
      let tree = NodeTree(dispatcher: dispatcher)
      tree.text("status", read: { service.status })
      tree.mount("volume", root, removeWhenGone: false)
      guard let export = start.export() else { fail("no export (its manifest's `export`)") }
      try tree.serve(export)
      try dispatcher.run()
    } catch {
      fail("can't serve: \(error)")
    }
  }
}
