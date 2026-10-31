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
import HostSystem
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

/// The key of the node at `host`: -k's 64 hex digits, which vx then
/// keeps for `host` (NodeKeys), or the one it kept. A node makes its own
/// on first boot (D152) and prints it: `cpu: listening on ..., key KEY`.
func nodeKey(_ given: String?, _ host: String, _ command: String) -> [UInt8] {
  if let given {
    guard let k = unhex(given), k.count == Noise.keySize else { fail("\(command): -k takes 64 hex digits") }
    do throws(TerminalError) { try NodeKeys.learn(host, k) } catch { complain("\(command): \(error)") }
    return k
  }
  guard let k = NodeKeys.key(host) else {
    fail("\(command): no key for \(host): give -k with the one its console prints (cpu: listening on ..., key KEY)")
  }
  return k
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
  let nodeKey = nodeKey(given, host, "cpu")
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

/// vx cpu-keys DIR [KEY...], a build step: the keys a cpu image takes,
/// for this terminal's default key, the other nodes' KEYs it answers too
/// (D75), written into DIR (the board's cpu image,
/// which a terminal reaches without vx boot or vx remote boot).
func cpuKeysCommand(_ args: [String]) -> Bool {
  guard let dir = args.first, dir.first != "-" else { fail("usage: vx cpu-keys DIR [KEY...]") }
  let key: StaticKey
  do throws(TerminalError) { key = try TerminalKey.load() } catch { fail("cpu-keys: \(error)") }
  writeCpuKeys(dir, terminal: key.publicKey, peers: peerKeys(args.dropFirst(), "cpu-keys"), command: "cpu-keys")
  return true
}

/// Other nodes' public keys, hex; fails on one that isn't.
func peerKeys(_ words: ArraySlice<String>, _ command: String) -> [[UInt8]] {
  words.map { w in
    guard let k = unhex(w), k.count == Noise.keySize else { fail("\(command): \(w): not a key") }
    return k
  }
}

/// Writes the keys a cpu image takes into DIR, only if they changed, so an
/// image isn't rebuilt: terminal, the terminal's public key and then
/// `peers`', other nodes' (D75), a line each. The node's own key isn't
/// the image's: it makes it on first boot (D152).
func writeCpuKeys(_ dir: String, terminal: [UInt8], peers: [[UInt8]] = [], command: String) {
  makeDirectory(dir)
  let files = [
    ("terminal", ([terminal] + peers).map { hex($0) + "\n" }.joined()),
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

/// vx boot [ARCH] [--cpu [KEY] [--peer KEY]... | --desktop]: builds the
/// arch and boots it. With --cpu, the cpu image (bootfs-cpu.img, D77)
/// boots the launcher with a cpu server for the terminal whose key is KEY
/// (this terminal's by default) and for each --peer, another node (D75),
/// its port 17019 forwarded from localhost's; the node makes its own key. With --desktop, the desktop's image (bootfs-desktop.img,
/// D107) boots the launcher with Radharc.
func bootCommand(_ args: [String]) -> Bool {
  let usage = "usage: vx boot [ARCH] [--cpu [KEY] [--peer KEY]... | --desktop]"
  var rest = args[...], arch: String?, cpu: [UInt8]?, peers: [[UInt8]] = [], desktop = false
  while let a = rest.popFirst() {
    if a == "--peer" {
      guard let k = rest.popFirst() else { fail(usage) }
      peers += peerKeys([k], "boot")
    } else if a == "--desktop" {
      desktop = true
    } else if a == "--cpu" {
      if let k = rest.first, let key = unhex(k), key.count == Noise.keySize {
        rest.removeFirst()
        cpu = key
      } else {
        do throws(TerminalError) { cpu = try TerminalKey.load().publicKey } catch { fail("boot: \(error)") }
      }
    } else {
      guard arch == nil else { fail(usage) }
      arch = arches([a]).first
    }
  }
  guard !(desktop && cpu != nil), peers.isEmpty || cpu != nil else { fail(usage) }
  let target = arch ?? "amd64"
  guard build(target) else { return false }
  if desktop { return run(["ninja", "-C", "build/\(target)", "run-desktop"], log: nil).ok }
  guard let cpu else { return run(["ninja", "-C", "build/\(target)", "run"], log: nil).ok }
  writeCpuKeys("build/\(target)/cpu", terminal: cpu, peers: peers, command: "boot")
  say("vx boot: a cpu server for \(hex(cpu)); its console prints its key: vx cpu -k KEY localhost, once")
  return run(["ninja", "-C", "build/\(target)", "run-cpu"], log: nil).ok
}
