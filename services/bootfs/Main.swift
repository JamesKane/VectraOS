// SPDX-License-Identifier: BSD-3-Clause

// bin/bootfs (D71): the boot image as a tree, read only, as Fuchsia's
// /boot. Each of its files at its path (bin/rc, lib/..., etc/manifests/...)
// is a read-only copy-on-write child of the image's VMO, as Fuchsia's
// bootsvc makes them (a slice can't be snapshotted, and the loader
// snapshots a program's writable segments), read by mapping it and
// given as memory (Node's `memory`) that may run: the image's programs
// and libraries are what the system runs. A manifest mounts its bin/ at
// /bin (`mount /bin bootfs/bin`), and a process starts what it finds
// there. Beside them, `status`.

import IPC
import Node
import Sys

func fail(_ what: String) -> Never {
  print("bootfs: \(what)")
  Process.exit(code: 2)
}

@main struct BootfsMain {
  static func main() {
    let start = Startup.current
    guard let bootfs = start.take(HandleType.info(HandleType.vmoBootfs)) else {
      fail("no boot image (its manifest's `bootfs`)")
    }
    do throws(Status) {
      let dispatcher = try IPCDispatcher()
      let tree = NodeTree(dispatcher: dispatcher)
      let files = try ProgramEntry.bootfs(bootfs)
      for f in files {
        // Its pages (each file starts on a page, padded to one), read only:
        // NO_WRITE keeps EXECUTE, which the image has.
        guard f.length > 0 else {
          tree.file(f.name, [])
          continue
        }
        let file = try VMO.child(bootfs, options: VMO.ChildOptions.snapshotAtLeastOnWrite | VMO.ChildOptions.noWrite,
                                 offset: UInt64(f.offset), size: (f.length + 4095) & ~4095)
        // Named after the file, so a process's mappings of it say which it
        // is (/proc/trace's procs, D102).
        try? file.setName(f.name)
        tree.memory(f.name, file, size: UInt64(f.length), executable: true)
      }
      let count = files.count
      tree.text("status", read: { "serving \(count) files\n" })
      guard let export = start.export() else { fail("no export (its manifest's `export`)") }
      try tree.serve(export)
      try dispatcher.run()
    } catch {
      fail("can't serve: \(error.rawValue)")
    }
  }
}
