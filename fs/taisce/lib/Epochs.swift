// SPDX-License-Identifier: BSD-3-Clause

import Synchronization

/// Epoch-based reclamation for lock-free readers (S1f, after gefs's
/// blk.c): readers take no locks; the one writer retires what it replaces
/// (snapshots, blocks) and frees each only once no reader can still see it.
///
/// A reader announces the global epoch in its slot while it reads. The
/// writer advances the epoch only when no active reader is behind it, and
/// something retired in epoch `e` is safe once the epoch reaches `e + 2`:
/// by then every reader that could have seen it has left.
@safe public final class EpochManager: @unchecked Sendable {
  public static let readers = 64

  let epoch = Atomic<UInt64>(2)
  /// Each reader's announced epoch while reading; 0 when it isn't.
  let active: InlineArray<64, Atomic<UInt64>>
  let claimed: InlineArray<64, Atomic<Bool>>
  /// The published snapshot, retained, swapped by the writer.
  let published = unsafe Atomic<UnsafeMutableRawPointer?>(nil)

  public init() {
    active = InlineArray { _ in Atomic(0) }
    claimed = InlineArray { _ in Atomic(false) }
  }

  deinit {
    if let p = unsafe published.load(ordering: .acquiring) { unsafe Unmanaged<Snapshot>.fromOpaque(p).release() }
  }

  /// Publishes `s`; returns the snapshot it replaces, for the writer to
  /// keep in limbo until no reader can be looking at it.
  func publish(_ s: Snapshot) -> Snapshot? {
    let new = unsafe Unmanaged.passRetained(s).toOpaque()
    guard let old = unsafe published.exchange(new, ordering: .acquiringAndReleasing) else { return nil }
    return unsafe Unmanaged<Snapshot>.fromOpaque(old).takeRetainedValue()
  }

  /// The published snapshot. Only between `enter` and `exit`: that's what
  /// keeps the writer from dropping it before this retains it.
  func snapshot() -> Snapshot {
    let p = unsafe published.load(ordering: .acquiring)!
    return unsafe Unmanaged<Snapshot>.fromOpaque(p).takeUnretainedValue()
  }

  public var current: UInt64 { epoch.load(ordering: .acquiring) }

  /// A reader slot, or nil if all 64 are taken.
  public func register() -> Int? {
    for i in 0..<Self.readers where claimed[i].compareExchange(expected: false, desired: true,
                                                                ordering: .acquiringAndReleasing).exchanged {
      return i
    }
    return nil
  }

  public func unregister(_ slot: Int) {
    active[slot].store(0, ordering: .releasing)
    claimed[slot].store(false, ordering: .releasing)
  }

  /// Announces that `slot` is reading, in the current epoch.
  public func enter(_ slot: Int) {
    while true {
      let e = epoch.load(ordering: .acquiring)
      active[slot].store(e, ordering: .sequentiallyConsistent)
      if epoch.load(ordering: .sequentiallyConsistent) == e { return }
    }
  }

  public func exit(_ slot: Int) { active[slot].store(0, ordering: .releasing) }

  /// Moves the epoch on if no reading reader is behind it. Safe from any
  /// number of threads.
  @discardableResult
  public func tryAdvance() -> Bool {
    let e = epoch.load(ordering: .sequentiallyConsistent)
    for i in 0..<Self.readers {
      let a = active[i].load(ordering: .sequentiallyConsistent)
      if a != 0 && a < e { return false }
    }
    // From e only: another thread may have advanced meanwhile, and a plain
    // store would move the epoch back.
    return epoch.compareExchange(expected: e, desired: e + 1, ordering: .sequentiallyConsistent).exchanged
  }
}

/// What a reader sees (S1f): every tree's root and the group's changed
/// nodes, as one operation left them. Immutable: the writer publishes a new
/// one after each operation and commit, sharing what didn't change.
public final class Snapshot: Sendable {
  let trees: [(id: UInt64, tree: BTree, changed: Bool)]
  let dirty: DirtyNodes

  init(trees: [(id: UInt64, tree: BTree, changed: Bool)], dirty: DirtyNodes) {
    self.trees = trees
    self.dirty = dirty
  }

  func root(_ id: UInt64) -> BTree? {
    var lo = 0, hi = trees.count
    while lo < hi {
      let mid = (lo + hi) / 2
      if trees[mid].id < id { lo = mid + 1 } else { hi = mid }
    }
    return lo < trees.count && trees[lo].id == id ? trees[lo].tree : nil
  }
}
