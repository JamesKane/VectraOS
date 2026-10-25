// SPDX-License-Identifier: BSD-3-Clause

// bin/warmboot-test (D101): run by userboot in boot-warmboot's image,
// whose bootfs holds this build's kernel at lib/warm/kernel.elf. The first
// boot warm-boots into that kernel and the same bootfs (Power.warmboot),
// with its own boot options and `warmboot.second=1`; the second finds
// that option and exits 0, the line the test waits for, so the test
// passes only through a warm boot that came back up.

import Sys

func fail(_ what: String) -> Never {
  print("warmboot-test: FAILED: \(what)")
  Process.exit(code: 1)
}

@main struct WarmbootTest {
  static func main() {
    if BootOptions.value("warmboot.second") != nil {
      print("warmboot-test: the second boot, after a warm boot")
      Process.exit(code: 0)
    }
    let start = Startup.current
    guard let resource = start.take(HandleType.info(HandleType.resource(.root))),
      let bootfs = start.take(HandleType.info(HandleType.vmoBootfs))
    else { fail("started without the root resource or bootfs") }
    do throws(Status) {
      // The kernel's ELF, from bootfs into a VMO of its own.
      guard let file = try ProgramEntry.bootfs(bootfs).first(where: { $0.name.utf8.elementsEqual("lib/warm/kernel.elf".utf8) })
      else { fail("no lib/warm/kernel.elf in bootfs") }
      let first = file.offset & ~4095
      let from = try VMO.map(bootfs, offset: first, length: file.offset + file.length - first, writable: false)
      let kernel = try VMO.create(size: file.length)
      try VMO.map(kernel, length: file.length).write(from.read(at: file.offset - first, count: file.length), at: 0)
      try VMO.setContentSize(kernel, UInt64(file.length))
      // This boot's options, and the one that says it is the second.
      let words = BootOptions.strings.filter { !$0.utf8.starts(with: "croi.spawn_ns=".utf8) } + ["warmboot.second=1"]
      let line = Array(words.joined(separator: " ").utf8)
      let cmdline = try VMO.create(size: line.count)
      try VMO.map(cmdline, length: line.count).write(line, at: 0)
      try VMO.setContentSize(cmdline, UInt64(line.count))
      print("warmboot-test: warm-booting into lib/warm/kernel.elf, \(file.length) bytes")
      try Power.warmboot(resource, kernel: kernel, bootfs: bootfs, cmdline: cmdline)
      fail("Power.warmboot returned")
    } catch {
      fail("Power.warmboot: \(error.rawValue)")
    }
  }
}
