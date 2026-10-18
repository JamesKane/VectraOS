// SPDX-License-Identifier: BSD-3-Clause

// vx remote boot's session (D101, vx-remote(1)): a cpu session runs the
// node's warmboot(8) with a kernel and bootfs from the terminal's tree,
// and the terminal waits for the new boot's cpu server. The copies are
// done when the node reads the bootfs to its end, which the terminal
// serves; warmboot then hands over, and the terminal dials again until a
// new boot answers. rc's output can't say when: it reaches the terminal
// through a ring that a fast warm boot leaves undrained. If the kernel
// refuses, warmboot says `warmboot: refused`, and rc's last output
// drains as the old boot goes on. The first session's end says nothing
// alone: the link may drop with the old kernel, or not until a new one
// answers it. A node that answers is the new boot if its
// /dev/warm/kernel is empty; the old boot's holds the copy.

import FoundationEssentials
import Glibc
import Noise

public enum RemoteBoot {
  /// How long each step took, in seconds.
  public struct Timing: Sendable {
    /// The session's start to the bootfs read to its end: the copies.
    public var copy: Double
    /// From then to the new boot's cpu server answering.
    public var back: Double
  }

  /// The line warmboot(8) prints if the kernel refuses.
  public static let refusal = Array("warmboot: refused".utf8)

  /// Warm-boots the node at `host`!`port` into `kernel` and `bootfs`
  /// (paths under /mnt/term/root, which is `root`), with `options` as its
  /// command line, or this boot's if none. What rc prints goes to
  /// `output`. Gives up `patience` seconds after the copies.
  public static func run(host: String, port: Int, key: StaticKey, node: [UInt8], root: String,
                         kernel: String, bootfs: String, options: [String], patience: Double = 120,
                         output: @escaping @Sendable ([UInt8]) -> Void) throws(TerminalError) -> Timing {
    let start = now()
    let state = State()
    let quiet = Quiet()
    let console = Console(
      read: { _ in [] },
      write: { bytes in
        output(bytes)
        state.saw(bytes)
      },
      note: { quiet.wait() })
    let command = (["warmboot", kernel, bootfs] + options).map(quoted).joined(separator: " ")
    let image = bootfs.split(separator: "/").last.map(String.init) ?? bootfs
    let tree = TerminalTree(root: root, console: console, readToEnd: { names in
      if names == [image] { state.copied() }
    })
    let link = try Link.tcp(host, port: port)
    spawn {
      do throws(TerminalError) {
        try CpuTerminal.run(link, key: key, node: node, command: command, tree: tree)
        state.end(nil)
      } catch {
        state.end(error)
      }
    }
    defer {
      link.close()
      quiet.end()
    }
    // The copies, until the bootfs is read to its end or the session ends.
    while state.copiedAt == nil {
      if let ended = state.ended {
        throw TerminalError(ended.map { "\($0)" } ?? "warmboot ended before the copies were done (its output above)")
      }
      usleep(20_000)
    }
    // Probes overlap, one begun each 200 ms, at most 4 at once, each
    // given 1 s: a dial the node can't answer yet (one QEMU's port forward
    // accepts for it, say) waits out its timeout without holding up the
    // next, and is gone before the new boot can take it. Dials left
    // longer (16 at once, 5 s each) reached the new boot in a burst and
    // broke its cpu server (roadmap, Known issues).
    let copied = state.copiedAt!
    let probes = Probes()
    while now() - copied < patience {
      if state.refused { throw TerminalError("the node refused the warm boot (its output above)") }
      if let back = probes.newBoot { return Timing(copy: copied - start, back: back - copied) }
      if probes.oldBoot, state.ended != nil {
        throw TerminalError("warmboot ended without a warm boot (its output above)")
      }
      if probes.begin() {
        spawn {
          let answer = probe(host: host, port: port, key: key, node: node, root: root)
          probes.end(answer)
        }
      }
      usleep(200_000)
    }
    throw TerminalError("no new boot's cpu server on the node \(Int(patience)) s after the copies")
  }

  /// Whether the node answering is a new boot (its /dev/warm/kernel
  /// empty), the old one, or nil: nothing answered.
  static func probe(host: String, port: Int, key: StaticKey, node: [UInt8], root: String) -> Bool? {
    guard let link = try? Link.tcp(host, port: port, timeout: 1) else { return nil }
    let got = Collected()
    let quiet = Quiet()
    defer { quiet.end() }
    let console = Console(read: { _ in [] }, write: { got.append($0) }, note: { quiet.wait() })
    do throws(TerminalError) {
      try CpuTerminal.run(link, key: key, node: node, command: "ls -l /dev/warm/kernel",
                          tree: TerminalTree(root: root, console: console))
    } catch {
      return nil
    }
    // `--rw-r--r-- M 0 none none LENGTH DATE NAME` (ls(1)).
    let words = String(decoding: got.bytes, as: UTF8.self).split(whereSeparator: { $0 == " " || $0.isNewline })
    guard words.count >= 6, let length = Int(words[5]) else { return nil }
    return length == 0
  }

  /// `word` quoted for rc.
  static func quoted(_ word: String) -> String {
    "'" + word.split(separator: "'", omittingEmptySubsequences: false).joined(separator: "''") + "'"
  }

  static func now() -> Double {
    var t = timespec()
    clock_gettime(CLOCK_MONOTONIC, &t)
    return Double(t.tv_sec) + Double(t.tv_nsec) / 1e9
  }

  /// What the first session has said and done, between its thread and
  /// the one waiting on it.
  final class State: @unchecked Sendable {
    let lock = Lock()
    var line: [UInt8] = []
    var copiedTime: Double?
    var refusedSeen = false
    var finished: TerminalError??

    var copiedAt: Double? { lock.withLock { copiedTime } }
    var refused: Bool { lock.withLock { refusedSeen } }
    var ended: TerminalError?? { lock.withLock { finished } }

    func copied() { lock.withLock { if copiedTime == nil { copiedTime = RemoteBoot.now() } } }

    /// Watches rc's output for the refusal.
    func saw(_ bytes: [UInt8]) {
      lock.withLock {
        for b in bytes {
          if b == 0x0A || b == 0x0D {
            if line.starts(with: RemoteBoot.refusal) { refusedSeen = true }
            line.removeAll()
          } else if line.count < 256 {
            line.append(b)
          }
        }
      }
    }

    func end(_ error: TerminalError?) { lock.withLock { finished = .some(error) } }
  }

  /// The probes under way, and what they found: when one first found the
  /// new boot, and whether one found the old.
  final class Probes: @unchecked Sendable {
    let lock = Lock()
    var running = 0
    var found: Double?
    var old = false

    var newBoot: Double? { lock.withLock { found } }
    var oldBoot: Bool { lock.withLock { old } }

    /// Whether another may begin: at most 4 at once.
    func begin() -> Bool {
      lock.withLock {
        guard running < 4 else { return false }
        running += 1
        return true
      }
    }

    func end(_ answer: Bool?) {
      let at = RemoteBoot.now()
      lock.withLock {
        running -= 1
        if answer == true, found == nil { found = at }
        if answer == false { old = true }
      }
    }
  }

  /// No notes, until the session is over: the node takes the end of
  /// dev/cpunote as the terminal gone, and posts rc `hangup`.
  final class Quiet: @unchecked Sendable {
    let ends: (read: Int32, write: Int32)

    init() {
      var fds: [Int32] = [-1, -1]
      _ = pipe(&fds)
      ends = (fds[0], fds[1])
    }

    deinit {
      Glibc.close(ends.read)
      Glibc.close(ends.write)
    }

    func wait() -> String? {
      var b: UInt8 = 0
      while Glibc.read(ends.read, &b, 1) < 0, errno == EINTR {}
      return nil
    }

    func end() {
      var b: UInt8 = 0
      _ = Glibc.write(ends.write, &b, 1)
    }
  }

  final class Collected: @unchecked Sendable {
    let lock = Lock()
    var all: [UInt8] = []
    var bytes: [UInt8] { lock.withLock { all } }
    func append(_ b: [UInt8]) { lock.withLock { all += b } }
  }
}
