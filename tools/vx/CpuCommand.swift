// SPDX-License-Identifier: BSD-3-Clause

// vx cpu: a cpu session on a node (D77, vx-cpu(1)): rc there, with this
// terminal's /dev/cons and its files at /mnt/term (tools/cpu).
//
//   vx cpu [-k NODEKEY] [-r ROOT] [-c COMMAND] [--key FILE] NODE
//   vx cpu --show-key [--key FILE]
//
// NODE is a host, host!port or tcp!host!port (port 17019 if none). The
// node's key is by default the one vx builds into its cpu images.

import CpuProtocol
import CpuTerminal
import FoundationEssentials
import Glibc
import Noise

private let usage = "usage: vx cpu [-k NODEKEY] [-r ROOT] [-c COMMAND] [--key FILE] NODE | vx cpu --show-key [--key FILE]"

/// NODE's host and port.
func cpuAddress(_ node: String) -> (host: String, port: Int)? {
  var parts = node.split(separator: "!", omittingEmptySubsequences: false).map(String.init)
  if parts.count == 3, parts[0] == "tcp" { parts.removeFirst() }
  guard let host = parts.first, !host.isEmpty, parts.count <= 2 else { return nil }
  guard parts.count == 2 else { return (host, CpuProtocol.port) }
  guard let port = Int(parts[1]), port > 0, port < 65536 else { return nil }
  return (host, port)
}

/// -k's 64 hex digits, or the public half of the node key vx builds into
/// its cpu images.
func nodeKey(_ given: String?, _ command: String) -> [UInt8] {
  if let given {
    guard let k = unhex(given), k.count == Noise.keySize else { fail("\(command): -k takes 64 hex digits") }
    return k
  }
  do throws(TerminalError) { return try TerminalKey.load(TerminalKey.nodePath).publicKey } catch { fail("\(command): \(error)") }
}

func cpuCommand(_ args: [String]) -> Bool {
  var given: String?
  var root = "/", command = "", keyPath = TerminalKey.defaultPath
  var showKey = false
  var node: String?
  var rest = args[...]
  while let a = rest.popFirst() {
    switch a {
    case "-k":
      guard let k = rest.popFirst() else { fail(usage) }
      given = k
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
  let nodeKey = nodeKey(given, "cpu")
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

/// Writes the keys bootfs-cpu.img takes, each only if it changed, so the
/// image isn't rebuilt: cpu/terminal, the terminal's public key, and
/// cpu/keys, factotum's line for the node's key (TerminalKey.nodePath).
func writeCpuKeys(_ target: String, terminal: [UInt8], command: String) {
  _ = nodeKey(nil, command)  // made if it isn't there
  guard let node = FileManager.default.contents(atPath: TerminalKey.nodePath) else {
    fail("\(command): can't read \(TerminalKey.nodePath)")
  }
  let dir = "build/\(target)/cpu"
  makeDirectory(dir)
  let files = [
    ("terminal", hex(terminal) + "\n"),
    ("keys", "key proto=noise-ik !private=\(node.base64EncodedString())\n"),
  ]
  for (name, text) in files {
    let file = dir + "/" + name
    if (try? String(contentsOfFile: file, encoding: .utf8)) == text { continue }
    let fd = open(file, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
    guard fd >= 0 else { fail("\(command): can't write \(file)") }
    let bytes = Array(text.utf8)
    let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    close(fd)
    guard n == bytes.count else { fail("\(command): can't write \(file)") }
  }
}

/// vx boot [ARCH] [--cpu [KEY] | --desktop]: builds the arch and boots
/// it. With --cpu, the cpu image (bootfs-cpu.img, D77) boots the launcher
/// with a cpu server for the terminal whose key is KEY (this terminal's by
/// default), with the node key vx keeps, its port 17019 forwarded from
/// localhost's. With --desktop, the desktop's image (bootfs-desktop.img,
/// D107) boots the launcher with Radharc.
func bootCommand(_ args: [String]) -> Bool {
  var rest = args[...], arch: String?, cpu: [UInt8]?, desktop = false
  while let a = rest.popFirst() {
    if a == "--desktop" {
      desktop = true
    } else if a == "--cpu" {
      if let k = rest.first, let key = unhex(k), key.count == Noise.keySize {
        rest.removeFirst()
        cpu = key
      } else {
        do throws(TerminalError) { cpu = try TerminalKey.load().publicKey } catch { fail("boot: \(error)") }
      }
    } else {
      guard arch == nil else { fail("usage: vx boot [ARCH] [--cpu [KEY] | --desktop]") }
      arch = arches([a]).first
    }
  }
  guard !(desktop && cpu != nil) else { fail("usage: vx boot [ARCH] [--cpu [KEY] | --desktop]") }
  let target = arch ?? "amd64"
  guard build(target) else { return false }
  if desktop { return run(["ninja", "-C", "build/\(target)", "run-desktop"], log: nil).ok }
  guard let cpu else { return run(["ninja", "-C", "build/\(target)", "run"], log: nil).ok }
  writeCpuKeys(target, terminal: cpu, command: "boot")
  say("vx boot: a cpu server for \(hex(cpu)), as \(hex(nodeKey(nil, "boot"))): vx cpu localhost")
  return run(["ninja", "-C", "build/\(target)", "run-cpu"], log: nil).ok
}
