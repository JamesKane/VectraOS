// SPDX-License-Identifier: BSD-3-Clause

// bin/fs [--format LABEL] [--check] PARTITION ... (fs(4)): a Taisce volume on a disk's
// partition in its namespace, the first of those named to be there (`/dev/sdZ0/data`, ramdisk(4)'s), served
// at `volume` in its tree, beside `status`. With --format, a partition
// that holds no volume gets one labelled LABEL, its UUID from the
// kernel's CPRNG. With --check, every invariant of the volume is checked
// once it is mounted (FileSystem.check, what fsck checks) by the volume's
// own thread before it answers a request, while the tree already answers,
// so the launcher hears the service at once however long the check takes;
// the result is said on the console and in `status`. The volume's channels
// are served on a thread of their own; the tree forwards walks into
// `volume` to them.

import Fs
import FsServer
import IPC
import Node
import Sys
import Taisce

/// A check's failure, in words (Taisce's errors carry no strings).
func words(_ e: TaisceError) -> String {
  switch e {
  case .io(let status): "an I/O error (\(status))"
  case .corrupt(let c):
    switch c {
    case .superblockLayout: "the superblock's layout"
    case .bitmapSize, .bitmapChecksum: "the free-space bitmap"
    case .node: "a tree's node"
    case .checksum(let block): "a checksum, block \(block)"
    case .catalog, .inode, .directory, .extent, .attribute, .index, .journal: "the catalog's records"
    case .fileSystem: "the file system's invariants"
    case .leakedBlocks: "blocks in use that no tree holds, or held twice"
    case .tree: "a tree's order, bounds, depth or fill"
    }
  default: "an error the check doesn't expect"
  }
}

@main struct FsProgram {
  static func main() {
    let start = Startup.current
    var paths: [String] = [], label: String?, check = false
    var args = start.args.dropFirst()
    while let arg = args.popFirst() {
      if NodeIPC.same(arg, "--format") {
        guard let l = args.popFirst() else { Process.fail("usage: fs [--format LABEL] [--check] PARTITION ...") }
        label = l
      } else if NodeIPC.same(arg, "--check") {
        check = true
      } else {
        paths.append(arg)
      }
    }
    guard !paths.isEmpty else { Process.fail("usage: fs [--format LABEL] [--check] PARTITION ...") }
    let ns: Namespace
    do throws(NamespaceError) { ns = try Namespace(start) } catch { Process.fail("no namespace") }
    // devmgr binds disks a moment into the boot: the partitions are waited
    // for, up to 10 s, and the first there is the volume's.
    var opened: Handle?, path = paths[0]
    let giveUp = Clock.monotonic() + 10_000_000_000
    while opened == nil {
      for p in paths where opened == nil {
        opened = try? ns.open(p).takeChannel()
        if opened != nil { path = p }
      }
      if opened == nil {
        guard Clock.monotonic() < giveUp else { Process.fail("no partition \(paths.joined(separator: " or "))") }
        sleep(until: Clock.monotonic() + 10_000_000)
      }
    }
    let channel = opened!
    // The unit's ctl beside it, where its barriers go as `flush` (D106).
    let unit = path.utf8.lastIndex(of: 0x2F).map { String(decoding: path.utf8[..<$0], as: UTF8.self) } ?? "."
    let ctl = try? ns.open(unit + "/ctl").takeChannel()
    var fs: FileSystem<NodeDevice>
    do throws(TaisceError) {
      let device = try NodeDevice(channel, ctl: ctl)
      do throws(TaisceError) {
        fs = try FileSystem.mount(device)
      } catch .notAVolume where label != nil {
        guard let uuid = try? CPRNG.draw(count: 16) else { Process.fail("no random bytes") }
        fs = try FileSystem.format(device, label: Array(label!.utf8), uuid: uuid, now: FsService.now)
      }
    } catch {
      Process.fail("no volume on \(path)")
    }
    do throws(Status) {
      let volume = try IPCDispatcher()
      let service = try FsService(fs, device: path, dispatcher: volume, checked: check ? "check running" : "")
      let root: Handle
      do throws(NodeError) { root = try service.root() } catch { Process.fail("no root") }
      _ = try Thread.spawn {
        // The check first, on the thread that alone touches the volume:
        // requests wait for it in their channels.
        if check {
          let t0 = Clock.monotonic()
          let result = service.checkVolume()
          let checked = result.map { "check FAILED: " + words($0) }
            ?? "check passed, \(service.nodes) nodes, \((Clock.monotonic() - t0) / 1_000_000) ms"
          service.setChecked(checked)
          print("fs: \(path): \(checked)")
        }
        do throws(Status) { try volume.run() } catch { Process.fail("the volume's dispatcher: \(error)") }
      }.release()
      let dispatcher = try IPCDispatcher()
      let tree = NodeTree(dispatcher: dispatcher)
      tree.text("status", read: { service.status })
      tree.mount("volume", root, removeWhenGone: false)
      guard let export = start.export() else { Process.fail("no export (its manifest's `export`)") }
      try tree.serve(export)
      try dispatcher.run()
    } catch {
      Process.fail("can't serve: \(error)")
    }
  }
}
