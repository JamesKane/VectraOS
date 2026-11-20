// SPDX-License-Identifier: BSD-3-Clause

// The GPU's address-space slots: slot 0 is the MCU's, the other AS_PRESENT
// bits go to the VMs of resident groups, and a VM that goes idle keeps its
// slot until another needs it, the least recently idled first
// (chinese-wall's panthor 04 section 4.2).

/// What a VM's activation needs the driver to do.
public enum ASActivation: Equatable, Sendable {
  /// The VM still holds `slot` and it is programmed: no register access.
  case resident(slot: Int)
  /// Program the free `slot` with the VM.
  case program(slot: Int)
  /// Disable `slot` of the idle VM `from` (the recycle form) and program
  /// it with this VM.
  case recycle(slot: Int, from: Int)
  /// Every slot is in use by a running VM; the scheduler prevents this by
  /// bounding its distinct VMs (04 section 4.2.2).
  case busy
}

public struct ASSlots: Sendable {
  public static let mcu = -1  // the owner name of the MCU's VM

  /// AS_PRESENT, with slot 0 for the MCU.
  public let present: UInt32
  var owner: [Int]  // VM id, `mcu`, or -2 for none
  var users: [Int]
  /// When a slot's VM went idle (its LRU place); larger is later.
  var idleStamp: [UInt64]
  var faulted: [Bool]
  var clock: UInt64 = 0

  static let none = -2

  public init(present: UInt32) {
    self.present = present
    owner = [Int](repeating: ASSlots.none, count: 32)
    users = [Int](repeating: 0, count: 32)
    idleStamp = [UInt64](repeating: 0, count: 32)
    faulted = [Bool](repeating: false, count: 32)
  }

  /// The slots VMs may use: AS_PRESENT without slot 0, searched as a mask
  /// rather than assumed contiguous.
  public var userSlots: Int { (present & ~1).nonzeroBitCount }

  public func slot(of vm: Int) -> Int? {
    for s in 0..<32 where owner[s] == vm { return s }
    return nil
  }

  public func users(of slot: Int) -> Int { users[slot] }

  /// The MCU's VM takes slot 0 and is never idle.
  public mutating func activateMCU() -> Int {
    owner[0] = ASSlots.mcu
    users[0] = 1
    faulted[0] = false
    return 0
  }

  /// A fault left the slot unusable until it is programmed again (04
  /// section 4.9): the VM's next activation reprograms it.
  public mutating func markFaulted(slot: Int) { faulted[slot] = true }

  public mutating func activate(vm: Int) -> ASActivation {
    if let s = slot(of: vm) {
      if users[s] == 0 && faulted[s] {
        faulted[s] = false
        users[s] = 1
        return .program(slot: s)
      }
      users[s] += 1
      return .resident(slot: s)
    }
    var s = 1
    while s < 32 {
      if present >> UInt32(s) & 1 == 1 && owner[s] == ASSlots.none { break }
      s += 1
    }
    if s < 32 {
      owner[s] = vm
      users[s] = 1
      faulted[s] = false
      return .program(slot: s)
    }
    var best = -1
    for t in 1..<32 where present >> UInt32(t) & 1 == 1 && users[t] == 0 && owner[t] >= 0 {
      if best < 0 || idleStamp[t] < idleStamp[best] { best = t }
    }
    if best < 0 { return .busy }
    let from = owner[best]
    owner[best] = vm
    users[best] = 1
    faulted[best] = false
    return .recycle(slot: best, from: from)
  }

  /// One user of the VM's slot is gone; the last one puts the VM at the
  /// LRU's tail and leaves the slot programmed.
  public mutating func deactivate(vm: Int) {
    guard let s = slot(of: vm), users[s] > 0 else { return }
    users[s] -= 1
    if users[s] == 0 {
      clock += 1
      idleStamp[s] = clock
    }
  }

  /// The VM is destroyed: its slot is free (the driver disables it).
  public mutating func release(vm: Int) -> Int? {
    guard let s = slot(of: vm) else { return nil }
    owner[s] = ASSlots.none
    users[s] = 0
    return s
  }

  /// A GPU reset: no slot holds anything.
  public mutating func reset() {
    for s in 0..<32 {
      owner[s] = ASSlots.none
      users[s] = 0
      faulted[s] = false
    }
  }
}
