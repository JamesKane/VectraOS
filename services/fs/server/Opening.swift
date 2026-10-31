// SPDX-License-Identifier: BSD-3-Clause

// An encrypted volume before fs mounts it (S2, D153 §3): `status` says it
// is locked, and `ctl` takes `unlock PASSPHRASE`, which must open a slot
// of the keybag read from its superblock, or, for a volume `--format
// --encrypt` is to make, becomes the new keybag's first slot. The same
// passphrase is asked for on the console, as a boot's LUKS or geli asks:
// read from kbdfs's cons with raw mode on, so nothing typed is shown, and
// asked again until a slot takes it. Every service that mounts the volume
// waits meanwhile; the console, which none of them is, shows the prompt.
// Each swarm slot's member is asked meanwhile too, through /net: the
// slot's key and a blinded request, answered by a point that opens the
// slot (McCallum-Relyea), asked again until one does, the wait doubling
// from a second to half a minute.
// The volume's thread waits for the key, then mounts and serves, and
// `status` and `ctl` are the service's from then on. PBKDF2 makes an
// unlock take about a second.

import Node
import Sys
import Taisce

/// The volume before it is served. An encrypted one waits for `unlock` on
/// `ctl`, whose passphrase must open a slot of its keybag, or, for a volume
/// --encrypt is to make, becomes its first slot. Then `status` and `ctl`
/// are the service's.
public final class Opening: @unchecked Sendable {
  let lock = Lock()
  /// The keybag read from the volume; nil for a volume yet to be made.
  let keybag: Keybag?
  /// Whether the volume is (or is to be) encrypted; a plain one is only
  /// mounting until it serves.
  let encrypted: Bool
  let device: String
  var key: VolumeKey?
  /// A new volume's keybag, made by its first `unlock`.
  var made: Keybag?
  var service: FsService?
  let bell: Handle
  /// The prompt's and the swarm's threads say a line at a time (a
  /// process's threads printing at once mix their lines).
  let saying = Lock()

  public init(keybag: Keybag?, encrypted: Bool, device: String) throws(Status) {
    self.keybag = keybag
    self.encrypted = encrypted
    self.device = device
    bell = try Counter.create()
  }

  public var status: String {
    if let s = lock.withLock({ service }) { return s.status }
    let unlocked = lock.withLock { key != nil }
    let state = !encrypted ? "mounting" : unlocked ? "unlocked, mounting" : keybag == nil ? "locked, new" : "locked"
    return "volume " + state + "\ndevice \(device)\n"
  }

  /// A `ctl` line: the service's once it serves; `unlock PASSPHRASE` until
  /// then, which `denied` refuses.
  public func control(_ line: String) throws(NodeError) {
    if let s = lock.withLock({ service }) { return try s.control(line) }
    guard encrypted, line.utf8.split(whereSeparator: { $0 == 0x20 || $0 == 0x0A || $0 == 0x09 }).first
      .map({ Array($0) == Array("unlock".utf8) }) ?? false
    else { throw .invalid }
    try unlock(FsService.rest(line, after: 1))
  }

  /// Takes `key` (and a new volume's keybag), for the volume's thread.
  func take(_ key: VolumeKey, made: Keybag?) throws(NodeError) {
    try lock.withLock { () throws(NodeError) in
      guard self.key == nil else { throw .exists }
      self.key = key
      self.made = made
    }
    try? Counter.add(bell, 1)
  }

  /// The volume key from `passphrase`, for the volume's thread; `denied` if
  /// no slot takes it.
  func unlock(_ passphrase: [UInt8]) throws(NodeError) {
    guard !passphrase.isEmpty else { throw .invalid }
    guard lock.withLock({ key == nil }) else { throw .exists }
    let key: VolumeKey
    var made: Keybag? = nil
    if let keybag {
      guard let k = keybag.unlock(passphrase) else { throw .denied }
      key = k
    } else {
      guard let bytes = try? CPRNG.draw(count: 64) else { throw .io }
      key = VolumeKey(Array(bytes[0..<32]))
      made = Keybag([.passphrase(passphrase, key: key, salt: Array(bytes[32..<64]))])
    }
    try take(key, made: made)
  }

  /// Waits for `unlock`: the volume key, and a new volume's keybag.
  public func waitForKey() -> (VolumeKey, Keybag?) {
    while lock.withLock({ key == nil }) { try? Counter.wait(bell, until: 1) }
    return lock.withLock { (key!, made) }
  }

  public func serving(_ service: FsService) { lock.withLock { self.service = service } }

  func say(_ line: String) { saying.withLock { print("fs: \(device): " + line) } }

  /// Whether the keybag has swarm slots to ask.
  public var asksSwarm: Bool { !(keybag?.swarmSlots.isEmpty ?? true) }

  /// Asks each swarm slot's member through `namespace`'s /net, round after
  /// round until one's answer opens its slot or the volume is unlocked
  /// another way. Why a member wasn't asked is said once. Run on a thread
  /// of its own.
  public func askSwarm(_ namespace: Namespace) {
    let slots = keybag?.swarmSlots ?? []
    for s in slots { say("asking the swarm member at \(s.address) too") }
    var said = [Bool](repeating: false, count: slots.count)
    var wait: Int64 = 1_000_000_000
    while lock.withLock({ key == nil }) {
      for (i, slot) in slots.enumerated() {
        switch Self.ask(namespace, slot) {
        case .key(let k):
          // Said first: the volume's thread, woken, says how it mounts.
          if lock.withLock({ key == nil }) { say("unlocked by the swarm member at \(slot.address)") }
          try? take(k, made: nil)
          return
        case .failed(let why):
          if !said[i] { say("\(slot.address): \(why); asking again") }
          said[i] = true
        }
      }
      sleep(until: Clock.monotonic() + wait)
      wait = Swift.min(2 * wait, 30_000_000_000)
    }
  }

  enum Asked {
    case key(VolumeKey)
    case failed(String)
  }

  /// One request to `slot`'s member: its key and the blinded point, 64
  /// bytes, answered by a point, 32.
  static func ask(_ namespace: Namespace, _ slot: Keybag.Slot) -> Asked {
    guard let random = try? CPRNG.draw(count: 64), let (message, blinding) = slot.request(random: random) else {
      return .failed("no random bytes")
    }
    var c: NetConnection
    do throws(DialError) { c = try namespace.dial(slot.address) } catch { return .failed(error.reason) }
    var answer: [UInt8] = []
    if (try? c.data.write(offset: 0, message)) != nil {
      while answer.count < 32, let b = try? c.data.read(offset: 0, max: UInt32(32 - answer.count)), !b.isEmpty {
        answer += b
      }
    }
    try? c.ctl.writeText("hangup")
    guard answer.count == 32 else { return .failed("no answer") }
    guard let key = slot.open(answer: answer, blinding: blinding) else { return .failed("an answer that opens nothing") }
    return .key(key)
  }

  /// Asks for the passphrase on the console until a slot takes one:
  /// written to and read from kbdfs's `cons`, with `consctl`'s raw mode on
  /// while it asks. Backspace and ^U edit the line, which shows nothing.
  /// Run on a thread of its own; it ends once the volume is unlocked.
  public func prompt(cons: consuming Handle, consctl: consuming Handle) {
    var control = NodeIPC.NodeClient(channel: consctl)
    var input = NodeIPC.NodeClient(channel: cons)
    guard (try? control.write(offset: 0, Array("rawon".utf8))) != nil else { return }
    say("encrypted; its passphrase is asked for on the console")
    var refused = false
    while lock.withLock({ key == nil }) {
      let ask = (refused ? "no slot takes that passphrase\n" : "") + "passphrase for \(device): "
      _ = try? input.write(offset: 0, Array(ask.utf8))
      var line: [UInt8] = []
      reading: while true {
        guard let bytes = try? input.read(offset: 0, max: 64), !bytes.isEmpty else { return }
        for b in bytes {
          switch b {
          case 0x0A, 0x0D: break reading
          case 0x08:  // a rune erased: its UTF-8 continuation bytes, then its first
            while let last = line.last, last & 0xC0 == 0x80 { line.removeLast() }
            if !line.isEmpty { line.removeLast() }
          case 0x15: line = []
          default: line.append(b)
          }
        }
      }
      _ = try? input.write(offset: 0, Array("\n".utf8))
      do throws(NodeError) {
        try unlock(line)
        say("unlocked")
      } catch .denied {
        refused = true
        say("a passphrase no slot takes")
      } catch {
        refused = false
      }
    }
    _ = consume control  // closed: raw mode off
  }
}
