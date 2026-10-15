// SPDX-License-Identifier: BSD-3-Clause

// vx todhchai-check [ARCH] [--build DIR] [--tree DIR]... [--program P]...
// [--timeout S] (croi's tools/todhchai-check.py, in Swift): boots
// Todhchai's test programs on this tree's loader and kernel.
//
// Todhchai (../todhchai, ../todhchai-c0) runs on this kernel; its `td ci`
// builds croi from croi's last commit, so a kernel change here reaches it
// only through this check. It runs the programs td starts with `td boot
// --next` (sys-test, pthread-test, tls-test, services-test). A change to
// the root filter or resource rules broke sys-test once (port 0xCF9, croi
// review round 1) with every kernel test passing.
//
// The ESP is assembled under build/<arch>/todhchai/: the loader and kernel
// from build/<arch>/esp, Todhchai's newest bootfs.img for the arch (from
// the last `td boot` there), and td's command line for a --next boot.
// QEMU runs as td boot runs it (Todhchai's tools/td/BootCommand.swift
// `qemuCommand`: KVM on amd64 when /dev/kvm is usable), not as qemu.sh
// does, whose extra devices (an IOMMU, edu) Todhchai's tests don't expect.
// Nothing in Todhchai's trees is written.
//
// Exit status: 0 all passed, 1 a failure (the console's tail is shown), 77
// no Todhchai bootfs for the arch (ctest's SKIP_RETURN_CODE).

import FoundationEssentials
import Glibc
import ImageFormats

private let programs = ["bin/sys-test", "bin/pthread-test", "bin/tls-test", "bin/services-test"]
private let edk2 = "/usr/share/edk2"

private func modified(_ path: String) -> Double {
  var st = stat()
  guard stat(path, &st) == 0 else { return 0 }
  return Double(st.st_mtim.tv_sec) + Double(st.st_mtim.tv_nsec) / 1e9
}

private func copyFile(_ from: String, _ to: String, size: Int? = nil) {
  removeTree(to)
  do { try FileManager.default.copyItem(atPath: from, toPath: to) } catch { fail("can't copy \(from): \(error)") }
  if let size { truncate(to, off_t(size)) }
}

/// td boot's QEMU (qemuCommand), plus its test-mode console options.
private func qemuCommand(_ arch: String, esp: String, work: String) -> [String] {
  func varsCopy(_ template: String, _ name: String, size: Int? = nil) -> String {
    let path = "\(work)/\(name)"
    if !FileManager.default.fileExists(atPath: path) { copyFile(template, path, size: size) }
    return path
  }
  var q: [String]
  switch arch {
  case "amd64":
    q = ["qemu-system-x86_64", "-machine", "q35", "-cpu", "max",
         "-drive", "if=pflash,format=raw,readonly=on,file=\(edk2)/ovmf/OVMF_CODE.fd",
         "-drive", "if=pflash,format=raw,file=\(varsCopy("\(edk2)/ovmf/OVMF_VARS.fd", "amd64-vars.fd"))"]
    if access("/dev/kvm", R_OK | W_OK) == 0 { q += ["-accel", "kvm"] }
  case "arm64":
    q = ["qemu-system-aarch64", "-machine", "virt,acpi=on,iommu=smmuv3,gic-version=3", "-cpu", "max",
         "-device", "ramfb",
         "-drive", "if=pflash,format=raw,readonly=on,file=\(edk2)/aarch64/QEMU_EFI-pflash.raw",
         "-drive", "if=pflash,format=raw,file=\(varsCopy("\(edk2)/aarch64/vars-template-pflash.raw", "arm64-vars.raw"))"]
  default:
    let code = "\(work)/rv64-code.fd"
    if !FileManager.default.fileExists(atPath: code) { copyFile("\(edk2)/riscv/RISCV_VIRT_CODE.fd", code, size: 32 << 20) }
    q = ["qemu-system-riscv64", "-machine", "virt,acpi=on", "-cpu", "max", "-device", "ramfb",
         "-drive", "if=pflash,format=raw,unit=0,readonly=on,file=\(code)",
         "-drive", "if=pflash,format=raw,unit=1,file=\(varsCopy("\(edk2)/riscv/RISCV_VIRT_VARS.fd", "rv64-vars.fd", size: 32 << 20))"]
  }
  return q + ["-m", "512M", "-smp", "4", "-net", "none",
              "-drive", "if=none,format=raw,file=fat:rw:\(esp),id=esp", "-device", "virtio-blk-pci,drive=esp",
              "-device", "virtio-rng-pci",
              "-display", "none", "-serial", "stdio", "-monitor", "none", "-no-reboot"]
}

/// One boot of `program`: whether userboot says it exited with 0.
private func boot(_ arch: String, esp: String, work: String, program: String, timeout: Double) -> Bool {
  _ = try? "userboot.next=\(program) userboot.shutdown=poweroff croi.selftest=off\n"
    .write(toFile: "\(esp)/croi/cmdline", atomically: true, encoding: .utf8)
  let log = "\(work)/\(String(program.map { $0 == "/" ? "-" : $0 })).log"
  let done = "userboot: \(program) exited with 0", failed = "userboot: \(program) exited with"
  let r = watch(qemuCommand(arch, esp: esp, work: work), log: log, timeout: timeout) { lines in
    if lines.contains(done + "\n") || lines.contains(done + "\r") { return !lines.contains("PANIC") }
    if lines.contains(failed) || lines.contains("PANIC") { return false }
    return nil
  }
  guard r.verdict == true else {
    let tail = String(decoding: readBytes(log).suffix(3000), as: UTF8.self)
    say("todhchai-check: \(arch) \(program): FAILED (console: \(log))\n\(tail)")
    return false
  }
  say("todhchai-check: \(arch) \(program): ok (\(String(Double(Int(r.seconds * 10)) / 10)) s)")
  return true
}

/// Returns the exit status: 0, 1, or 77 (skipped).
func todhchaiCheckCommand(_ args: [String]) -> Int32 {
  var arch = "amd64", buildDir: String?, trees: [String] = [], chosen: [String] = [], timeout = 120.0
  var i = 0
  func value() -> String {
    i += 1
    guard i < args.count else { fail("\(args[i - 1]) needs a value") }
    return args[i]
  }
  while i < args.count {
    switch args[i] {
    case "--build": buildDir = value()
    case "--tree": trees.append(value())
    case "--program": chosen.append(value())
    case "--timeout": timeout = Double(value()) ?? timeout
    case let a where allArches.contains(a): arch = a
    default: fail("unknown option \(args[i])")
    }
    i += 1
  }
  // The repository root: this tree's build/ is under it, and Todhchai's
  // trees are beside it.
  let root = repositoryRoot()
  let build = buildDir ?? "\(root)/build/\(arch)"
  if trees.isEmpty { trees = ["\(root)/../todhchai", "\(root)/../todhchai-c0"] }
  let found = trees.map { "\($0)/build/boot/\(arch)/esp/croi/bootfs.img" }.filter { FileManager.default.fileExists(atPath: $0) }
  guard let bootfs = found.max(by: { modified($0) < modified($1) }) else {
    say("todhchai-check: no Todhchai bootfs for \(arch) (run td boot there once): skipped")
    return 77
  }
  let names = Bootfs.names(readBytes(bootfs))
  let wanted = chosen.isEmpty ? programs : chosen
  let present = wanted.filter { names.contains($0) }
  let missing = wanted.filter { !names.contains($0) }
  if !missing.isEmpty { say("todhchai-check: not in \(bootfs): \(missing.joined(separator: " "))") }
  if present.isEmpty { return 77 }

  let work = "\(build)/todhchai"
  let esp = "\(work)/esp"
  removeTree(esp)
  makeDirectory(work)
  do { try FileManager.default.copyItem(atPath: "\(build)/esp", toPath: esp) } catch { fail("can't copy \(build)/esp: \(error)") }
  removeTree("\(esp)/croi/cmdline")
  // A copy, not a link: QEMU's FAT drive is read-write, and Todhchai's
  // tree is never written.
  copyFile(bootfs, "\(esp)/croi/bootfs.img")
  say("todhchai-check: \(arch), kernel from \(build), bootfs \(bootfs)")
  var ok = true
  for program in present { ok = boot(arch, esp: esp, work: work, program: program, timeout: timeout) && ok }
  return ok ? 0 : 1
}

/// The directory holding Package.swift, from the current one up.
func repositoryRoot() -> String {
  var dir = FileManager.default.currentDirectoryPath
  while dir != "/" {
    if FileManager.default.fileExists(atPath: "\(dir)/Package.swift") && FileManager.default.fileExists(atPath: "\(dir)/CMakePresets.json") {
      return dir
    }
    dir = String(dir[..<(dir.lastIndex(of: "/") ?? dir.startIndex)])
    if dir.isEmpty { break }
  }
  fail("not inside the repository")
}
