// SPDX-License-Identifier: BSD-3-Clause

// bin/ramdisk SIZE (ramdisk(4)): a disk in memory, served as sd(3)'s
// directory for its kind (D82), 9front's sdram's: `sdZ0/ctl` says its
// geometry and `sdZ0/data` is the disk, a VMO of SIZE bytes (K, M or G:
// binary) written in place, its pages taken as they are first written.
// The disk lasts as long as the service: fs(4)'s restarts find their
// volume, a reboot doesn't.

import IPC
import Node
import Sys

func fail(_ what: String) -> Never {
  print("ramdisk: \(what)")
  Process.exit(code: 2)
}

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
      fail("usage: ramdisk SIZE (a multiple of 4096 bytes: K, M or G)")
    }
    let sectors = bytes / sector
    do throws(Status) {
      let dispatcher = try IPCDispatcher()
      let tree = NodeTree(dispatcher: dispatcher)
      try tree.memory("sdZ0/data", writable: try VMO.create(size: Int(bytes)), size: bytes)
      tree.text("sdZ0/ctl", read: {
        "inquiry ramdisk0\ngeometry \(sectors) \(sector)\nalignment \(sector) 0\npart data 0 \(sectors)\n"
      })
      tree.text("status", read: { "ramdisk0 sdZ0 \(bytes) bytes\n" })
      guard let export = start.export() else { fail("no export (its manifest's `export`)") }
      try tree.serve(export)
      try dispatcher.run()
    } catch {
      fail("can't serve: \(error)")
    }
  }
}
