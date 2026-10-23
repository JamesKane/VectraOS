// SPDX-License-Identifier: BSD-3-Clause

// vx reload: a hot image onto a node (hotreload(2), vx-reload(1), D122):
// built, if asked (the image's own command, ninja's last for it: the tree
// is built already), then copied through a cpu session's /mnt/term to a
// temporary name beside TO and renamed into place, which the program's
// HotHost sees. With --status, the session waits for the program's status
// to show another load (or a refusal), and vx says how long it all took.
//
//   vx reload [-k NODEKEY] [--key FILE] [--build DIR TARGET] [--status FILE] NODE IMAGE TO

import CpuProtocol
import CpuTerminal
import FoundationEssentials
import Glibc
import Noise
import Synchronization

private let usage =
  "usage: vx reload [-k NODEKEY] [--key FILE] [--build DIR TARGET] [--status FILE] NODE IMAGE TO"

/// What the session printed.
final class Captured: Sendable {
  let bytes = Mutex<[UInt8]>([])
}

func reloadCommand(_ args: [String]) -> Bool {
  var given: String?, keyPath = TerminalKey.defaultPath
  var build: (dir: String, target: String)?, status: String?
  var words: [String] = []
  var rest = args[...]
  while let a = rest.popFirst() {
    switch a {
    case "-k":
      guard let k = rest.popFirst() else { fail(usage) }
      given = k
    case "--key":
      guard let p = rest.popFirst() else { fail(usage) }
      keyPath = p
    case "--build":
      guard let d = rest.popFirst(), let t = rest.popFirst() else { fail(usage) }
      build = (d, t)
    case "--status":
      guard let s = rest.popFirst() else { fail(usage) }
      status = s
    default:
      guard !a.hasPrefix("-") else { fail(usage) }
      words.append(a)
    }
  }
  guard words.count == 3, let (host, port) = cpuAddress(words[0]) else { fail(usage) }
  let image = words[1], to = words[2]
  let started = monotonicNanoseconds()
  // The image's own command alone: ninja's whole graph would first run
  // SwiftPM (the `vx` target) and CMake's glob check, seconds of a reload.
  if let build {
    guard let command = capture(["ninja", "-C", build.dir, "-t", "commands", "-s", build.target]),
      !command.isEmpty, run(["/bin/sh", "-c", command], log: nil).ok
    else {
      complain("reload: building \(build.target) failed")
      return false
    }
  }
  let slash = image.lastIndex(of: "/")
  let root = slash.map { String(image[..<$0]) } ?? "."
  let name = slash.map { String(image[image.index(after: $0)...]) } ?? image
  let key: StaticKey
  do throws(TerminalError) { key = try TerminalKey.load(keyPath) } catch { fail("reload: \(error)") }
  // The copy and the rename; then, with --status, a wait of up to 3 s for
  // its fourth word (`loads N`'s N) to change or a refusal.
  var command = "cp /mnt/term/root/\(name) \(to).new && mv \(to).new \(to)"
  if let status {
    command = "s=`{cat \(status)}; n=$s(4); \(command) && { i=(); t=$s; "
      + "while(~ $t(4) $n && ! ~ $t refused && ! ~ $#i 300){ sleep 0.01; i=($i x); t=`{cat \(status)} }; echo hot: $t }"
  }
  let captured = Captured()
  let console = Console(read: { _ in [] },
                        write: { bytes in
                          captured.bytes.withLock { $0 += bytes }
                          _ = bytes.withUnsafeBytes { Glibc.write(1, $0.baseAddress, $0.count) }
                        },
                        // No notes, ever: wait as a terminal with none to send does.
                        note: {
                          while true { pause() }
                        })
  do throws(TerminalError) {
    let link = try Link.tcp(host, port: port)
    try CpuTerminal.run(link, key: key, node: nodeKey(given, "reload"), command: command,
                        tree: TerminalTree(root: root, console: console))
  } catch {
    complain("reload: \(error)")
    return false
  }
  let took = monotonicNanoseconds() - started
  guard status != nil else { return true }
  let said = String(decoding: captured.bytes.withLock { $0 }, as: UTF8.self)
  guard said.contains("hot: image"), !said.contains("refused") else {
    complain("reload: \(to) wasn't taken")
    return false
  }
  print("reload: \(name) running in \(took / 1_000_000) ms")
  print("  budget name=reload.module_10k value=\(took) unit=ns limit=1000000000")
  return true
}

private func monotonicNanoseconds() -> Int64 {
  var t = timespec()
  clock_gettime(CLOCK_MONOTONIC, &t)
  return Int64(t.tv_sec) * 1_000_000_000 + Int64(t.tv_nsec)
}
