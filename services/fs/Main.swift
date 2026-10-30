// SPDX-License-Identifier: BSD-3-Clause

// bin/fs [--format LABEL] [--check] [--daily HH:MM] PARTITION ... (fs(4)): a Taisce volume on a
// disk's partition in its namespace, the first of those named to be there (`/dev/sdZ0/data`, ramdisk(4)'s),
// served at `volume` in its tree, beside its snapshots at `snap` (S2, D153), `ctl` and `status`. With --format, a partition
// that holds no volume gets one labelled LABEL, its UUID from the
// kernel's CPRNG. With --check, every invariant of the volume is checked
// once it is mounted (FileSystem.check, what fsck checks) by the volume's
// own thread before it answers a request, while the tree already answers,
// so the launcher hears the service at once however long the check takes;
// the result is said on the console and in `status`. The volume's channels
// are served on a thread of their own; the tree forwards walks into
// `volume` and `snap` to them. With --daily, a snapshot is taken each day
// at HH:MM UTC, by a thread asleep until then.

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

let usage = "usage: fs [--format LABEL] [--check] [--daily HH:MM] PARTITION ..."

/// HH:MM as nanoseconds into a day, or nil.
func dayTime(_ text: String) -> Int64? {
  let b = Array(text.utf8)
  guard b.count == 5, b[2] == 0x3A, b.indices.allSatisfy({ $0 == 2 || (b[$0] >= 0x30 && b[$0] <= 0x39) }) else { return nil }
  let h = Int64(b[0] - 0x30) * 10 + Int64(b[1] - 0x30), m = Int64(b[3] - 0x30) * 10 + Int64(b[4] - 0x30)
  guard h < 24, m < 60 else { return nil }
  return (h * 60 + m) * 60_000_000_000
}

/// Nanoseconds from now until the day's next `at` (UTC).
func untilNext(_ at: Int64) -> Int64 {
  let day: Int64 = 86_400_000_000_000
  let into = Clock.realtime() % day
  let wait = (at - into + day) % day
  return wait == 0 ? day : wait
}

@main struct FsProgram {
  static func main() {
    let start = Startup.current
    var paths: [String] = [], label: String?, check = false, daily: Int64?
    var args = start.args.dropFirst()
    while let arg = args.popFirst() {
      if NodeIPC.same(arg, "--format") {
        guard let l = args.popFirst() else { Process.fail(usage) }
        label = l
      } else if NodeIPC.same(arg, "--check") {
        check = true
      } else if NodeIPC.same(arg, "--daily") {
        guard let t = args.popFirst(), let at = dayTime(t) else { Process.fail(usage) }
        daily = at
      } else {
        paths.append(arg)
      }
    }
    guard !paths.isEmpty else { Process.fail(usage) }
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
    // The partition again, for the file cache's pager thread (D131).
    let second = try? ns.open(path).takeChannel()
    var fs: FileSystem<NodeDevice>
    var pager = false
    // The volume's nodes are cached up to a 64th of the RAM (as FreeBSD
    // sizes its vnodes and ZFS its cache from it), and never below the
    // store's default.
    let cacheBytes = Swift.max(Store<NodeDevice>.defaultCacheBytes, Int(KMemStats.physical / 64))
    do throws(TaisceError) {
      let device = try NodeDevice(channel, ctl: ctl, reader: second)
      pager = device.readsConcurrently
      do throws(TaisceError) {
        fs = try FileSystem.mount(device, cacheBytes: cacheBytes)
      } catch .notAVolume where label != nil {
        guard let uuid = try? CPRNG.draw(count: 16) else { Process.fail("no random bytes") }
        fs = try FileSystem.format(device, label: Array(label!.utf8), uuid: uuid, now: FsService.now,
                                   cacheBytes: cacheBytes)
      }
    } catch {
      Process.fail("no volume on \(path)")
    }
    do throws(Status) {
      let volume = try IPCDispatcher()
      let service = try FsService(fs, device: path, dispatcher: volume, checked: check ? "check running" : "",
                                  pager: pager)
      let root: Handle, snap: Handle
      do throws(NodeError) {
        root = try service.root()
        snap = try service.snapshotRoot()
      } catch {
        Process.fail("no root")
      }
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
      tree.text("ctl", read: { "" }, write: { (line: String) throws(NodeError) in try service.control(line) })
      tree.mount("volume", root, removeWhenGone: false)
      tree.mount("snap", snap, removeWhenGone: false)
      if let daily {
        _ = try Thread.spawn {
          while true {
            sleep(until: Clock.monotonic() + untilNext(daily))
            try? service.control("snap")
          }
        }.release()
      }
      guard let export = start.export() else { Process.fail("no export (its manifest's `export`)") }
      try tree.serve(export)
      try dispatcher.run()
    } catch {
      Process.fail("can't serve: \(error)")
    }
  }
}
