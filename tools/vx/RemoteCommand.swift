// SPDX-License-Identifier: BSD-3-Clause

// vx remote boot (D101, vx-remote(1)): a node handed to a new kernel and
// bootfs from this machine, in one step: a cpu session runs warmboot(8)
// on them, and vx waits for the new boot's cpu server (tools/cpu's
// RemoteBoot).
//
//   vx remote boot [ARCH] [--kernel FILE] [--bootfs FILE] [-k NODEKEY]
//                  [--key FILE] NODE [OPTION ...]
//
// By default the images are ARCH's (amd64's) kernel and cpu bootfs, built
// first with this terminal's key and vx's node key; the options are the
// new boot's command line, or the node's own if none.

import CpuTerminal
import FoundationEssentials
import Glibc
import Noise

private let usage =
  "usage: vx remote boot [ARCH] [--kernel FILE] [--bootfs FILE] [-k NODEKEY] [--key FILE] NODE [OPTION ...]"

func remoteCommand(_ args: [String]) -> Bool {
  guard args.first == "boot" else { fail(usage) }
  var arch: String?, kernel: String?, bootfs: String?, given: String?
  var keyPath = TerminalKey.defaultPath
  var node: String?
  var options: [String] = []
  var rest = args.dropFirst()
  func value() -> String {
    guard let v = rest.popFirst() else { fail(usage) }
    return v
  }
  while let a = rest.popFirst() {
    if node != nil {
      options.append(a)
      continue
    }
    switch a {
    case "--kernel": kernel = value()
    case "--bootfs": bootfs = value()
    case "-k": given = value()
    case "--key": keyPath = value()
    default:
      guard !a.hasPrefix("-") else { fail(usage) }
      if arch == nil, allArches.contains(a) { arch = a } else { node = a }
    }
  }
  guard let node, let (host, port) = cpuAddress(node) else { fail(usage) }
  let key: StaticKey
  do throws(TerminalError) { key = try TerminalKey.load(keyPath) } catch { fail("remote: \(error)") }
  let target = arch ?? "amd64"
  if kernel == nil || bootfs == nil {
    guard FileManager.default.fileExists(atPath: "CMakePresets.json") else {
      fail("remote: run vx remote boot from the repository root, or give --kernel and --bootfs")
    }
    writeCpuKeys(target, terminal: key.publicKey, command: "remote")
    guard build(target), step("\(target)-bootfs-cpu", ["ninja", "-C", "build/\(target)", "bootfs-cpu"]) else {
      return false
    }
  }
  let images = [
    ("kernel.elf", kernel ?? "build/\(target)/kernel/kernel.elf"),
    ("bootfs.img", bootfs ?? "build/\(target)/bootfs-cpu.img"),
  ]
  // The tree the node sees at /mnt/term: the two images and nothing else.
  var template = Array("\(ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp")/vx-remote.XXXXXX".utf8CString)
  guard let made = template.withUnsafeMutableBufferPointer({ mkdtemp($0.baseAddress!) }) else {
    fail("remote: can't make a directory for the images")
  }
  let root = String(cString: made)
  defer { removeTree(root) }
  var bytes = 0
  for (name, path) in images {
    var s = stat()
    guard stat(path, &s) == 0 else { fail("remote: \(path): no such file") }
    bytes += Int(s.st_size)
    let absolute = path.hasPrefix("/") ? path : FileManager.default.currentDirectoryPath + "/" + path
    guard symlink(absolute, "\(root)/\(name)") == 0 else { fail("remote: can't link \(path) into \(root)") }
  }
  say("vx remote boot: \(node) into \(name(images[0].1)) and \(name(images[1].1))")
  let timing: RemoteBoot.Timing
  do throws(TerminalError) {
    timing = try RemoteBoot.run(
      host: host, port: port, key: key, node: nodeKey(given, "remote"), root: root,
      kernel: "/mnt/term/root/kernel.elf", bootfs: "/mnt/term/root/bootfs.img", options: options,
      output: { b in _ = b.withUnsafeBytes { write(1, $0.baseAddress, $0.count) } })
  } catch {
    complain("remote: \(error)")
    return false
  }
  let megabytes = Double(bytes) / 1e6
  say("vx remote boot: \(oneDecimal(megabytes)) MB copied in \(twoDecimals(timing.copy)) s (\(oneDecimal(megabytes / timing.copy)) MB/s)")
  say("vx remote boot: back on cpu \(twoDecimals(timing.back)) s after the copies")
  say("  budget name=remote.warmboot value=\(Int(timing.back * 1e9)) unit=ns limit=2000000000")
  return true
}

private func name(_ path: String) -> String { path.split(separator: "/").last.map(String.init) ?? path }
private func oneDecimal(_ v: Double) -> String { String(Double(Int((v * 10).rounded())) / 10) }
private func twoDecimals(_ v: Double) -> String { String(Double(Int((v * 100).rounded())) / 100) }
