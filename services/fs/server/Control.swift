// SPDX-License-Identifier: BSD-3-Clause

// fs's `ctl` (fs(4)): a line asks the volume's thread for something, and
// `status`'s last few lines say how it went. `snap` and `unsnap NAME` take
// and delete snapshots (S2, D153 §1); on an encrypted volume, `slot add
// passphrase WORDS`, `slot add swarm ADDRESS KEY` and `slot remove N`
// change its keybag (D153 §3).
// `unlock`, for a volume not yet mounted, is fs's Main's.

import Node
import Sys
import Taisce

/// What `ctl` asks of the volume's thread.
enum ControlRequest {
  case snap
  case unsnap([UInt8])
  case addPassphrase([UInt8])
  /// A swarm member's address and mcr key.
  case addSwarm(String, [UInt8])
  case removeSlot(Int)
}

extension FsService {
  /// A `ctl` line, on the tree's thread, run on the volume's.
  public func control(_ line: String) throws(NodeError) {
    let words = Self.words(line)
    let request: ControlRequest
    if words == [Array("snap".utf8)] {
      request = .snap
    } else if words.count == 2, words[0] == Array("unsnap".utf8) {
      request = .unsnap(words[1])
    } else if words.count >= 4, words[0] == Array("slot".utf8), words[1] == Array("add".utf8),
      words[2] == Array("passphrase".utf8)
    {
      guard volumeKey != nil else { throw .unsupported }
      request = .addPassphrase(Self.rest(line, after: 3))
    } else if words.count == 5, words[0] == Array("slot".utf8), words[1] == Array("add".utf8),
      words[2] == Array("swarm".utf8), words[3].count <= Keybag.Slot.addressSize, let key = Self.unhex(words[4]),
      key.count == 32
    {
      guard volumeKey != nil else { throw .unsupported }
      request = .addSwarm(String(decoding: words[3], as: UTF8.self), key)
    } else if words.count == 3, words[0] == Array("slot".utf8), words[1] == Array("remove".utf8),
      words[2].count == 1, words[2][0] >= 0x30, Int(words[2][0] - 0x30) < Keybag.count
    {
      guard volumeKey != nil else { throw .unsupported }
      request = .removeSlot(Int(words[2][0] - 0x30))
    } else {
      throw .invalid
    }
    lock.withLock { requests.append(request) }
    try? Counter.add(requestBell, 1)
  }

  static func words(_ line: String) -> [[UInt8]] {
    line.utf8.split(whereSeparator: { $0 == 0x20 || $0 == 0x0A || $0 == 0x09 }).map { Array($0) }
  }

  /// 64 lowercase hex digits as 32 bytes.
  static func unhex(_ digits: [UInt8]) -> [UInt8]? {
    guard digits.count == 64 else { return nil }
    var out: [UInt8] = []
    for i in stride(from: 0, to: 64, by: 2) {
      var b: UInt8 = 0
      for d in digits[i...(i + 1)] {
        switch d {
        case 0x30...0x39: b = b << 4 | (d - 0x30)
        case 0x61...0x66: b = b << 4 | (d - 0x61 + 10)
        default: return nil
        }
      }
      out.append(b)
    }
    return out
  }

  /// What follows the first `count` words of `line` and the blanks after
  /// them, to its end or newline: a passphrase, whose own spaces count.
  public static func rest(_ line: String, after count: Int) -> [UInt8] {
    var b = Array(line.utf8)
    if let newline = b.firstIndex(of: 0x0A) { b = Array(b[..<newline]) }
    var at = 0
    for _ in 0..<count {
      while at < b.count, b[at] == 0x20 || b[at] == 0x09 { at += 1 }
      while at < b.count, b[at] != 0x20, b[at] != 0x09 { at += 1 }
    }
    while at < b.count, b[at] == 0x20 || b[at] == 0x09 { at += 1 }
    return Array(b[at...])
  }

  /// Runs what `ctl` asked, on the volume's thread.
  func runRequests() {
    let asked = lock.withLock { () -> [ControlRequest] in
      defer { requests = [] }
      return requests
    }
    for request in asked {
      switch request {
      case .snap:
        // Writes behind first: a snapshot is what's committed.
        let failed = writeBackAll()
        do throws(TaisceError) {
          let s = try fs.takeSnapshot(now: Self.now)
          cleaned()
          commits += 1
          noteRequest("snap " + String(decoding: s.name, as: UTF8.self)
            + (failed == nil ? " taken" : " taken, without a write behind that failed"))
        } catch {
          noteRequest("snap failed: " + Self.words(error))
        }
      case .unsnap(let name):
        do throws(TaisceError) {
          guard let s = try fs.snapshots().first(where: { $0.name == name }) else { throw .notFound }
          try fs.deleteSnapshot(s)
          commits += 1
          noteRequest("unsnap " + String(decoding: name, as: UTF8.self) + " deleted")
        } catch {
          noteRequest("unsnap " + String(decoding: name, as: UTF8.self) + " failed: " + Self.words(error))
        }
      case .addPassphrase(let passphrase):
        guard let key = volumeKey, var keybag = fs.keybag else { break }
        guard let free = keybag.slots.firstIndex(where: { $0 == nil }) else {
          noteRequest("slot add failed: every slot is taken")
          break
        }
        guard let salt = try? CPRNG.draw(count: 32) else {
          noteRequest("slot add failed: no random bytes")
          break
        }
        keybag.slots[free] = .passphrase(passphrase, key: key, salt: salt)
        setKeybag(keybag, "slot \(free) passphrase added")
      case .addSwarm(let address, let member):
        guard let key = volumeKey, var keybag = fs.keybag else { break }
        guard let free = keybag.slots.firstIndex(where: { $0 == nil }) else {
          noteRequest("slot add failed: every slot is taken")
          break
        }
        guard let random = try? CPRNG.draw(count: 64) else {
          noteRequest("slot add failed: no random bytes")
          break
        }
        guard let slot = Keybag.Slot.swarm(member: member, address: address, key: key, random: random) else {
          noteRequest("slot add failed: the key isn't a point of the group")
          break
        }
        keybag.slots[free] = slot
        setKeybag(keybag, "slot \(free) swarm \(address) added")
      case .removeSlot(let slot):
        guard var keybag = fs.keybag else { break }
        guard keybag.slots[slot] != nil else {
          noteRequest("slot remove \(slot) failed: the slot is empty")
          break
        }
        guard keybag.slots.contains(where: { $0 != nil && $0 != keybag.slots[slot] }) else {
          noteRequest("slot remove \(slot) failed: it is the last")
          break
        }
        keybag.slots[slot] = nil
        setKeybag(keybag, "slot \(slot) removed", failed: "slot remove \(slot) failed: ")
      }
    }
    render()
  }

  /// Commits `keybag`, and notes `done`, or `failed` and why.
  func setKeybag(_ keybag: Keybag, _ done: String, failed: String = "slot add failed: ") {
    do throws(TaisceError) {
      try fs.setKeybag(keybag)
      commits += 1
      noteRequest(done)
    } catch {
      noteRequest(failed + Self.words(error))
    }
  }

  /// `status`'s last few lines about what was asked, and the count of
  /// snapshots.
  func noteRequest(_ line: String) {
    let count = (try? fs.snapshots().count) ?? 0
    lock.withLock {
      shown.snapshots = count
      shown.requestLines.append(line)
      if shown.requestLines.count > 4 { shown.requestLines.removeFirst() }
    }
  }

  static func words(_ e: TaisceError) -> String {
    switch e {
    case .notFound: "no such snapshot"
    case .noSpace: "no space"
    case .readOnly: "the volume takes no changes"
    case .tooLarge: "too large"
    case .corrupt: "the volume is damaged"
    case .io: "an I/O error"
    default: "an error"
    }
  }
}
