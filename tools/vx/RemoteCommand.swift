// SPDX-License-Identifier: BSD-3-Clause

// vx remote boot (D101, vx-remote(1)): a node handed to a new kernel and
// bootfs from this machine, in one step: a cpu session runs warmboot(8)
// on them, and vx waits for the new boot's cpu server (tools/cpu's
// RemoteBoot).
//
//   vx remote boot [ARCH] [--kernel FILE] [--bootfs FILE] [--image NAME] [-k NODEKEY]
//                  [--key FILE] NODE [OPTION ...]
//
// By default the images are ARCH's (amd64's) kernel and cpu bootfs (or
// bootfs-NAME.img with --image: board-cpu, the board's), built
// first with this terminal's key; the options are the
// new boot's command line, or the node's own if none. A board's image
// (board-*) is judged as a board's warm boot (remote.warmboot.board,
// < 5 s), any other as QEMU's (remote.warmboot, < 2 s).
//
//   vx remote trace [ARCH] [-k NODEKEY] [--key FILE] [--out DIR] [--kernel FILE] [--bootfs FILE]
//                   NODE SECONDS [WORD ...]
//
// A profile of the node (D102): a cpu session runs trace(8) for SECONDS
// (the words its start command's: hz N, pages N, categories), which
// copies the recording to DIR (build/vx/trace) through /mnt/term, and vx
// trace profile reads it, named from ARCH's build (or the --kernel and
// --bootfs given).

import CpuTerminal
import FoundationEssentials
import Glibc
import Noise

private let usage =
  "usage: vx remote boot [ARCH] [--kernel FILE] [--bootfs FILE] [--image NAME] [-k NODEKEY] [--key FILE] NODE [OPTION ...]"

private let traceUsage =
  "usage: vx remote trace [ARCH] [-k NODEKEY] [--key FILE] [--out DIR] [--kernel FILE] [--bootfs FILE] NODE SECONDS [WORD ...]"

func remoteCommand(_ args: [String]) -> Bool {
  if args.first == "trace" { return remoteTrace(Array(args.dropFirst())) }
  if args.first == "test" { return remoteTest(Array(args.dropFirst())) }
  guard args.first == "boot" else { fail(usage) }
  var arch: String?, kernel: String?, bootfs: String?, given: String?, image = "cpu"
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
    case "--image": image = value()
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
    writeCpuKeys("build/\(target)/cpu", terminal: key.publicKey, command: "remote")
    guard build(target), step("\(target)-bootfs-\(image)", ["ninja", "-C", "build/\(target)", "bootfs-\(image)"]) else {
      return false
    }
  }
  let images = [
    ("kernel.elf", kernel ?? "build/\(target)/kernel/kernel.elf"),
    ("bootfs.img", bootfs ?? "build/\(target)/bootfs-\(image).img"),
  ]
  let staged = stageImages(images)
  let root = staged.path, bytes = staged.bytes
  defer { removeTree(root) }
  say("vx remote boot: \(node) into \(name(images[0].1)) and \(name(images[1].1))")
  let timing: RemoteBoot.Timing
  do throws(TerminalError) {
    timing = try RemoteBoot.run(
      host: host, port: port, key: key, node: nodeKey(given, host, "remote"), root: root,
      kernel: "/mnt/term/root/kernel.elf", bootfs: "/mnt/term/root/bootfs.img", options: options,
      output: { b in _ = b.withUnsafeBytes { write(1, $0.baseAddress, $0.count) } })
  } catch {
    complain("remote: \(error)")
    return false
  }
  let megabytes = Double(bytes) / 1e6
  say("vx remote boot: \(oneDecimal(megabytes)) MB copied in \(twoDecimals(timing.copy)) s (\(oneDecimal(megabytes / timing.copy)) MB/s)")
  say("vx remote boot: back on cpu \(twoDecimals(timing.back)) s after the copies")
  let board = image.hasPrefix("board")
  say("  budget name=remote.warmboot\(board ? ".board" : "") value=\(Int(timing.back * 1e9)) unit=ns limit=\(board ? 5_000_000_000 : 2_000_000_000)")
  return true
}

func remoteTrace(_ args: [String]) -> Bool {
  var arch: String?, given: String?, node: String?, seconds: String?, kernel: String?, bootfs: String?
  var keyPath = TerminalKey.defaultPath
  var out = "build/vx/trace"
  var words: [String] = []
  var rest = args[...]
  func value() -> String {
    guard let v = rest.popFirst() else { fail(traceUsage) }
    return v
  }
  while let a = rest.popFirst() {
    if seconds != nil {
      words.append(a)
      continue
    }
    switch a {
    case "-k": given = value()
    case "--key": keyPath = value()
    case "--out": out = value()
    case "--kernel": kernel = value()
    case "--bootfs": bootfs = value()
    default:
      guard !a.hasPrefix("-") else { fail(traceUsage) }
      if node == nil, arch == nil, allArches.contains(a) { arch = a } else if node == nil { node = a } else { seconds = a }
    }
  }
  guard let node, let seconds, Double(seconds) != nil, let (host, port) = cpuAddress(node) else { fail(traceUsage) }
  let key: StaticKey
  do throws(TerminalError) { key = try TerminalKey.load(keyPath) } catch { fail("remote: \(error)") }
  removeTree(out)
  makeDirectory(out)
  let command = (["trace", seconds, "/mnt/term/root"] + words).joined(separator: " ")
  say("vx remote trace: \(node) for \(seconds) s, into \(out)")
  do throws(TerminalError) {
    let link = try Link.tcp(host, port: port)
    try CpuTerminal.run(link, key: key, node: nodeKey(given, host, "remote"), command: command,
                        tree: TerminalTree(root: out, console: .standard()))
  } catch {
    complain("remote: \(error)")
    return false
  }
  guard FileManager.default.fileExists(atPath: "\(out)/procs") else {
    complain("remote: trace(8) copied nothing to \(out) (its output above)")
    return false
  }
  // The images the node ran, kept with the recording: a later build
  // would name its addresses wrongly.
  let target = arch ?? "amd64"
  for (path, kept) in [(kernel ?? "build/\(target)/kernel/kernel.elf", "kernel.elf"),
                       (bootfs ?? "build/\(target)/bootfs-cpu.img", "bootfs.img")] {
    do { try FileManager.default.copyItem(atPath: path, toPath: "\(out)/\(kept)") } catch {
      complain("remote: can't keep \(path) with the recording: \(error)")
    }
  }
  return profileCommand([out])
}

private func name(_ path: String) -> String { path.split(separator: "/").last.map(String.init) ?? path }
private func twoDecimals(_ v: Double) -> String { String(Double(Int((v * 100).rounded())) / 100) }

/// The tree the node sees at /mnt/term: the images (published name, path)
/// linked into a new directory, and nothing else; their bytes.
func stageImages(_ images: [(String, String)]) -> (path: String, bytes: Int) {
  var template = Array("\(ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp")/vx-remote.XXXXXX".utf8CString)
  guard let made = template.withUnsafeMutableBufferPointer({ mkdtemp($0.baseAddress!) }) else {
    fail("remote: can't make a directory for the images")
  }
  let root = String(cString: made)
  var bytes = 0
  for (name, path) in images {
    var s = stat()
    guard stat(path, &s) == 0 else { fail("remote: \(path): no such file") }
    bytes += Int(s.st_size)
    let absolute = path.hasPrefix("/") ? path : FileManager.default.currentDirectoryPath + "/" + path
    guard symlink(absolute, "\(root)/\(name)") == 0 else { fail("remote: can't link \(path) into \(root)") }
  }
  return (root, bytes)
}
