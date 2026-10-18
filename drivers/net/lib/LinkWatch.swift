// SPDX-License-Identifier: BSD-3-Clause

// When a NIC driver reads its link's state (D82). The read is of the
// device's registers, which under a hypervisor is an exit each, and a
// driver read it at every interrupt: under KVM, a fifth of a copy's CPU
// went in virtio-net's. A device that says when its configuration changed
// (virtio's ISR bit 1, with INTx) is read only then; one whose interrupt
// can't say (one MSI-X vector for its queues and its configuration) is
// read at most every `interval`, and an interrupt meanwhile asks for a
// read at the interval's end, which the driver waits for (`deadline`), so
// a change is seen within an interval however quiet the link is after it.

public struct LinkWatch: Sendable {
  public static let interval: Int64 = 500_000_000

  /// When it may be read next.
  var next: Int64 = .min
  /// An interrupt came since the last read, too soon to read then.
  var pending = false

  public init() {}

  /// An interrupt that may be the configuration's, at `now`: whether to
  /// read the link now.
  public mutating func interrupt(now: Int64) -> Bool {
    guard now >= next else {
      pending = true
      return false
    }
    read(now)
    return true
  }

  /// A wake at `now` that wasn't an interrupt: whether a read put off is
  /// due.
  public mutating func due(now: Int64) -> Bool {
    guard pending, now >= next else { return false }
    read(now)
    return true
  }

  /// When the driver must wake for a read put off; nil if none is.
  public var deadline: Int64? { pending ? next : nil }

  mutating func read(_ now: Int64) {
    pending = false
    next = now + Self.interval
  }
}
