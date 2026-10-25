// SPDX-License-Identifier: BSD-3-Clause

// bin/ramdisk SIZE (ramdisk(4)): a disk in memory, served as sd(3)'s
// directory for its kind by the block class (D82, D106), as 9front's
// sdram names it, sdZ0: a VMO of SIZE bytes (K, M or G: binary) in
// 4096-byte sectors, its pages taken as they are first written. The disk
// lasts as long as the service: fs(4)'s restarts find their volume, a
// reboot doesn't.

import IPC
import Node
import Sd
import Sys

/// "64M": 64 MiB (K, M or G, binary), or bytes.
func size(_ text: String) -> UInt64? {
  guard let last = text.utf8.last else { return nil }
  let unit: UInt64? = switch last {
  case UInt8(ascii: "K"): 1 << 10
  case UInt8(ascii: "M"): 1 << 20
  case UInt8(ascii: "G"): 1 << 30
  default: nil
  }
  if let unit { return UInt64(String(decoding: text.utf8.dropLast(), as: UTF8.self)).map { $0 * unit } }
  return UInt64(text)
}

@main struct RamdiskProgram {
  static let sector: UInt64 = 4096

  static func main() {
    let start = Startup.current
    guard start.args.count == 2, let bytes = size(start.args[1]), bytes >= sector, bytes % sector == 0 else {
      Process.fail("usage: ramdisk SIZE (a multiple of 4096 bytes: K, M or G)")
    }
    let sectors = bytes / sector
    do throws(Status) {
      let dispatcher = try IPCDispatcher()
      let tree = NodeTree(dispatcher: dispatcher)
      let disk = try MemoryDisk(name: "ramdisk0", try VMO.create(size: Int(bytes)), sectors: sectors,
                                sectorSize: Int(sector))
      // The unit on a dispatcher of its own: the tree waits on its thread
      // for a mount's answers.
      let disks = try IPCDispatcher()
      let unit = SdUnit(disk, dispatcher: disks)
      _ = try Thread.spawn {
        do throws(Status) { try disks.run() } catch { Process.fail("the disk's dispatcher: \(error)") }
      }.release()
      _ = tree.mount("sdZ0", try unit.channel())
      tree.text("status", read: { "ramdisk0 sdZ0 \(bytes) bytes\n" })
      guard let export = start.export() else { Process.fail("no export (its manifest's `export`)") }
      try tree.serve(export)
      try dispatcher.run()
    } catch {
      Process.fail("can't serve: \(error)")
    }
  }
}
