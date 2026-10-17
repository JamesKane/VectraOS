// SPDX-License-Identifier: BSD-3-Clause

// vx cpu: a cpu session on a node (D77, vx-cpu(1)): rc there, with this
// terminal's /dev/cons and its files at /mnt/term (tools/cpu).
//
//   vx cpu -k NODEKEY [-r ROOT] [-c COMMAND] [--key FILE] NODE
//   vx cpu --show-key [--key FILE]
//
// NODE is a host, host!port or tcp!host!port (port 17019 if none).

import CpuProtocol
import CpuTerminal
import FoundationEssentials
import Glibc
import Noise

private let usage = "usage: vx cpu -k NODEKEY [-r ROOT] [-c COMMAND] [--key FILE] NODE | vx cpu --show-key [--key FILE]"

/// NODE's host and port.
func cpuAddress(_ node: String) -> (host: String, port: Int)? {
  var parts = node.split(separator: "!", omittingEmptySubsequences: false).map(String.init)
  if parts.count == 3, parts[0] == "tcp" { parts.removeFirst() }
  guard let host = parts.first, !host.isEmpty, parts.count <= 2 else { return nil }
  guard parts.count == 2 else { return (host, CpuProtocol.port) }
  guard let port = Int(parts[1]), port > 0, port < 65536 else { return nil }
  return (host, port)
}

func cpuCommand(_ args: [String]) -> Bool {
  var nodeKey: [UInt8]?
  var root = "/", command = "", keyPath = TerminalKey.defaultPath
  var showKey = false
  var node: String?
  var rest = args[...]
  while let a = rest.popFirst() {
    switch a {
    case "-k":
      guard let k = rest.popFirst().flatMap(unhex), k.count == Noise.keySize else { fail("cpu: -k takes 64 hex digits") }
      nodeKey = k
    case "-r":
      guard let r = rest.popFirst() else { fail(usage) }
      root = r
    case "-c":
      guard let c = rest.popFirst() else { fail(usage) }
      command = c
    case "--key":
      guard let p = rest.popFirst() else { fail(usage) }
      keyPath = p
    case "--show-key":
      showKey = true
    default:
      guard node == nil, !a.hasPrefix("-") else { fail(usage) }
      node = a
    }
  }
  let key: StaticKey
  do throws(TerminalError) { key = try TerminalKey.load(keyPath) } catch { fail("cpu: \(error)") }
  if showKey {
    print(hex(key.publicKey))
    return true
  }
  guard let node, let (host, port) = cpuAddress(node) else { fail(usage) }
  guard let nodeKey else {
    fail("cpu: the node's key is -k KEY, from its console's `cpu: listening on ..., key KEY`")
  }
  guard let d = opendir(root) else { fail("cpu: \(root): not a directory") }
  closedir(d)
  do throws(TerminalError) {
    let link = try Link.tcp(host, port: port)
    try CpuTerminal.run(link, key: key, node: nodeKey, command: command,
                        tree: TerminalTree(root: root, console: .standard()))
  } catch {
    complain("cpu: \(error)")
    return false
  }
  return true
}

/// vx boot [ARCH] [--cpu [KEY]]: builds the arch and boots it. With
/// --cpu, the cpu image (bootfs-cpu.img, D77) boots the launcher with a
/// cpu server for the terminal whose key is KEY (this terminal's by
/// default), its port 17019 forwarded from localhost's.
func bootCommand(_ args: [String]) -> Bool {
  var rest = args[...], arch: String?, cpu: [UInt8]?
  while let a = rest.popFirst() {
    if a == "--cpu" {
      if let k = rest.first, let key = unhex(k), key.count == Noise.keySize {
        rest.removeFirst()
        cpu = key
      } else {
        do throws(TerminalError) { cpu = try TerminalKey.load().publicKey } catch { fail("boot: \(error)") }
      }
    } else {
      guard arch == nil else { fail("usage: vx boot [ARCH] [--cpu [KEY]]") }
      arch = arches([a]).first
    }
  }
  let target = arch ?? "amd64"
  guard build(target) else { return false }
  guard let cpu else { return run(["ninja", "-C", "build/\(target)", "run"], log: nil).ok }
  // The key, rewritten only if it changed, so the image isn't rebuilt.
  let dir = "build/\(target)/cpu", file = dir + "/terminal", text = hex(cpu) + "\n"
  makeDirectory(dir)
  if (try? String(contentsOfFile: file, encoding: .utf8)) != text {
    guard (try? text.write(toFile: file, atomically: true, encoding: .utf8)) != nil else { fail("boot: can't write \(file)") }
  }
  say("vx boot: a cpu server for \(hex(cpu)); its console says the node's key, for vx cpu -k KEY localhost")
  return run(["ninja", "-C", "build/\(target)", "run-cpu"], log: nil).ok
}
