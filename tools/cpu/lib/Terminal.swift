// SPDX-License-Identifier: BSD-3-Clause

// vx cpu's session (D77): calls a node's cpu server, seals the call with
// Noise IK as the terminal whose key the node's image pins, sends the
// command, and serves the terminal's tree until the node hangs up, when
// rc there has ended.

import CpuProtocol
import HostSystem
import Noise

public enum CpuTerminal {
  /// Runs a session over `raw` to the node whose key is `node`: `command`
  /// for rc -c, or an interactive rc if empty; `tree` is what the node
  /// sees at /mnt/term. Returns when the node hangs up.
  public static func run(_ raw: Link, key: StaticKey, node: [UInt8], command: String, tree: TerminalTree,
                         random: () -> [UInt8] = { SealedLink.random(Noise.keySize) }) throws(TerminalError) {
    let link = try SealedLink(raw, key: key, remote: node, prologue: CpuProtocol.prologue, random: random)
    defer { link.close() }
    guard let record = CpuProtocol.record(Array(command.utf8)) else {
      throw TerminalError("command longer than \(CpuProtocol.maxCommand) bytes")
    }
    try link.write(record)
    TerminalServer(tree, link: link).serve()
  }
}

/// The terminal's static key: 32 random bytes in a file only its owner
/// may read, made the first time.
public enum TerminalKey {
  /// Where vx keeps the terminal's: $XDG_CONFIG_HOME/vectraos/cpu.key, or
  /// under ~/.config.
  public static var defaultPath: String { directory + "/cpu.key" }

  static var directory: String {
    let env = ProcessInfo.processInfo.environment
    let config = env["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? ((env["HOME"] ?? "") + "/.config")
    return config + "/vectraos"
  }

  public static func load(_ path: String = defaultPath) throws(TerminalError) -> StaticKey {
    if let data = FileManager.default.contents(atPath: path) {
      guard data.count == Noise.keySize else { throw TerminalError("\(path): not a key (\(data.count) bytes)") }
      return StaticKey(privateKey: Array(data))
    }
    let bytes = SealedLink.random(Noise.keySize)
    do {
      try FileManager.default.createDirectory(atPath: String(path[..<(path.lastIndex(of: "/") ?? path.startIndex)]),
                                              withIntermediateDirectories: true)
    } catch { throw TerminalError("\(path): \(error)") }
    let fd = HostSystem.open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw TerminalError("\(path): \(String(cString: strerror(errno)))") }
    defer { HostSystem.close(fd) }
    guard bytes.withUnsafeBytes({ HostSystem.write(fd, $0.baseAddress, $0.count) }) == bytes.count else {
      throw TerminalError("\(path): can't write it")
    }
    return StaticKey(privateKey: bytes)
  }
}

/// The nodes' public keys vx knows, by the host it reaches each at, as
/// ssh's known_hosts: a node makes its own key on first boot (D152), so
/// vx learns it once, from `-k` (the node's console prints it), and keeps
/// it in `nodes` beside the terminal's key, a `host key` line each.
public enum NodeKeys {
  public static var path: String { TerminalKey.directory + "/nodes" }

  /// `host`'s key, if vx has learned it.
  public static func key(_ host: String) -> [UInt8]? {
    for (h, k) in all() where h == host { return k }
    return nil
  }

  /// Learns `key` as `host`'s, replacing what was kept for it.
  public static func learn(_ host: String, _ key: [UInt8]) throws(TerminalError) {
    var lines = all().filter { $0.host != host }.map { "\($0.host) \(hex($0.key))" }
    lines.append("\(host) \(hex(key))")
    let text = lines.joined(separator: "\n") + "\n"
    do {
      try FileManager.default.createDirectory(atPath: TerminalKey.directory, withIntermediateDirectories: true)
      try Data(text.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
    } catch { throw TerminalError("\(path): \(error)") }
  }

  static func all() -> [(host: String, key: [UInt8])] {
    guard let data = FileManager.default.contents(atPath: path) else { return [] }
    var out: [(host: String, key: [UInt8])] = []
    for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
      let w = line.split(separator: " ")
      guard w.count == 2, let k = unhex(String(w[1])), k.count == Noise.keySize else { continue }
      out.append((String(w[0]), k))
    }
    return out
  }
}

/// Lowercase hex, and back.
public func hex(_ bytes: [UInt8]) -> String {
  let digits = Array("0123456789abcdef".utf8)
  return String(decoding: bytes.flatMap { [digits[Int($0 >> 4)], digits[Int($0 & 15)]] }, as: UTF8.self)
}

public func unhex(_ text: String) -> [UInt8]? {
  let digits = Array(text.utf8)
  guard digits.count % 2 == 0 else { return nil }
  var out: [UInt8] = []
  for i in stride(from: 0, to: digits.count, by: 2) {
    guard let b = UInt8(String(decoding: digits[i..<i + 2], as: UTF8.self), radix: 16) else { return nil }
    out.append(b)
  }
  return out
}

extension Console {
  /// The process's own terminal: stdin and stdout, which stays in cooked
  /// mode, so the dev machine's terminal edits each line; ^C (SIGINT) is
  /// the note `interrupt`, and ends nothing here.
  public static func standard() -> Console {
    let notes = Notes.shared
    notes.catchInterrupts()
    return Console(
      read: { max in
        var buffer = [UInt8](repeating: 0, count: max)
        while true {
          let n = buffer.withUnsafeMutableBytes { HostSystem.read(0, $0.baseAddress, max) }
          if n < 0, errno == EINTR { continue }
          return n > 0 ? Array(buffer[0..<n]) : []
        }
      },
      write: { bytes in
        var at = 0
        while at < bytes.count {
          let n = bytes[at...].withUnsafeBytes { HostSystem.write(1, $0.baseAddress, $0.count) }
          if n < 0, errno == EINTR { continue }
          guard n > 0 else { return }
          at += n
        }
      },
      note: { notes.next() })
  }
}

/// SIGINT as notes: the handler writes a byte down a pipe, which a
/// dev/cpunote read waits on.
final class Notes: @unchecked Sendable {
  static let shared = Notes()
  let ends: (read: Int32, write: Int32)

  init() {
    var fds: [Int32] = [-1, -1]
    _ = pipe(&fds)
    ends = (fds[0], fds[1])
    notesPipe = fds[1]
  }

  func catchInterrupts() {
    signal(SIGINT) { _ in
      var b: UInt8 = 1
      _ = HostSystem.write(notesPipe, &b, 1)
    }
  }

  /// Waits for the next ^C.
  func next() -> String? {
    var b: UInt8 = 0
    while true {
      let n = HostSystem.read(ends.read, &b, 1)
      if n < 0, errno == EINTR { continue }
      return n == 1 ? "interrupt" : nil
    }
  }
}

/// The pipe's write end, for the signal handler (which can capture nothing).
nonisolated(unsafe) var notesPipe: Int32 = -1
