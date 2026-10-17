// SPDX-License-Identifier: BSD-3-Clause

// The crash harness (filesystem.md §9): record every write from a formatted
// image through a workload of transaction groups, then rebuild the disk as
// power loss could have left it and mount it:
//   - every prefix of the writes, block by block (a multi-block write can
//     tear anywhere);
//   - within each barrier window, random subsets of its writes, since writes
//     between barriers may land in any order.
// Each crashed image must mount, pass every invariant with no leaked
// blocks, and hold exactly the state after some transaction group: never
// less than what had been committed, never part of a group.

import Taisce
import Testing

typealias State = [UInt64: [[UInt8]: [UInt8]]]

struct Unit {
  var block: UInt64?  // nil: a barrier
  var bytes: [UInt8]
}

struct Workload {
  var image: MemoryDevice
  var units: [Unit] = []
  var states: [State] = [[:]]  // after each committed group
  /// For each group, the unit count when its commit started and returned.
  var started: [Int] = [0]
  var returned: [Int] = [0]
}

func record(seed: UInt64, groups: Int) throws -> Workload {
  var rng = SplitMix(state: seed)
  let formatted = try Engine.format(MemoryDevice(blocks: 1024), label: [], uuid: Array(1...16), now: 0)
  var w = Workload(image: formatted.store.volume.device)
  var e = try Engine.mount(RecordingDevice(w.image))
  var model: State = [:]
  func units(_ device: RecordingDevice<MemoryDevice>) -> Int {
    device.log.reduce(0) { n, op in
      if case .write(_, let bytes) = op { n + bytes.count / 4096 } else { n + 1 }
    }
  }
  for _ in 0..<groups {
    for _ in 0..<(1 + rng.below(3)) {
      var batch: [Message] = []
      var keys: [(UInt64, [UInt8])] = []  // existing keys with room for a delta
      for (t, entries) in model { for (k, v) in entries where v.count >= 8 { keys.append((t, k)) } }
      for _ in 0..<(1 + rng.below(25)) {
        let tree = [1, 2, 7][rng.below(3)] as UInt64
        let key = [UInt8(rng.below(6)), UInt8(rng.below(64))]
        switch rng.below(10) {
        case 0..<6:
          let v = (0..<(16 + rng.below(700))).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
          batch.append(.insert(tree: tree, key: key, value: v))
        case 6..<8:
          batch.append(.delete(tree: tree, key: key))
        default:
          // A delta on a key that exists before the batch. (One the batch
          // itself deletes first fails it, which the model reproduces.)
          if let (t, k) = keys.isEmpty ? nil : keys[rng.below(keys.count)] {
            batch.append(.delta(tree: t, key: k, .add(offset: 0, value: 1)))
          }
        }
      }
      // Now and then a batch that must fail, to check it leaves nothing.
      if rng.below(8) == 0 { batch.append(.delta(tree: 3, key: [0xff], .add(offset: 0, value: 1))) }
      let expected = try? contentsAfter(batch, on: model)
      do {
        try e.apply(batch)
        #expect(expected != nil, "the engine applied a batch the model rejects")
        model = expected ?? model
      } catch {
        #expect(expected == nil, "the engine rejected a batch the model applies: \(error)")
      }
      // Sometimes an fsync: durable through the intent log, mid-group.
      if rng.below(3) == 0 {
        w.started.append(units(e.store.volume.device))
        try e.fsync()
        w.returned.append(units(e.store.volume.device))
        w.states.append(model.filter { !$0.value.isEmpty })
      }
    }
    w.started.append(units(e.store.volume.device))
    try e.commitGroup()
    w.returned.append(units(e.store.volume.device))
    w.states.append(model.filter { !$0.value.isEmpty })
  }
  // A workload that barely changes proves nothing (an early version's
  // batches nearly all failed): most groups must leave a new state.
  #expect(Set(w.states.map { "\($0)" }).count > groups * 3 / 4, "the workload hardly changed the volume")
  // Expand the log into units.
  for op in e.store.volume.device.log {
    switch op {
    case .flush: w.units.append(Unit(block: nil, bytes: []))
    case .write(let block, let bytes):
      for i in 0..<(bytes.count / 4096) {
        w.units.append(Unit(block: block + UInt64(i), bytes: Array(bytes[(i * 4096)..<((i + 1) * 4096)])))
      }
    }
  }
  return w
}

/// The model after `batch`, applied as the engine does: sorted by tree and
/// key, in batch order within a key.
func contentsAfter(_ batch: [Message], on model: State) throws -> State {
  func tk(_ m: Message) -> (UInt64, [UInt8]) {
    switch m {
    case .insert(let t, let k, _), .delete(let t, let k), .delta(let t, let k, _): (t, k)
    }
  }
  let order = batch.indices.sorted { a, b in
    let (ta, ka) = tk(batch[a]), (tb, kb) = tk(batch[b])
    if ta != tb { return ta < tb }
    if ka != kb { return ka.lexicographicallyPrecedes(kb) }
    return a < b
  }
  var s = model
  for i in order {
    switch batch[i] {
    case .insert(let t, let k, let v): s[t, default: [:]][k] = v
    case .delete(let t, let k): s[t]?[k] = nil
    case .delta(let t, let k, .add(let offset, let n)):
      guard var v = s[t]?[k] else { throw TaisceError.missingKey }
      var x: UInt64 = 0
      for j in 0..<8 { x |= UInt64(v[offset + j]) << (8 * j) }
      x &+= n
      for j in 0..<8 { v[offset + j] = UInt8(truncatingIfNeeded: x >> (8 * j)) }
      s[t]![k] = v
    case .delta: break
    }
  }
  return s
}

/// Mounts a crashed image and checks it against the workload, given how
/// many units reached the disk (a prefix) or which groups could have.
func verify(_ image: MemoryDevice, _ w: Workload, durableThrough lower: Int, atMost upper: Int) throws {
  var e = try Engine.mount(image)
  _ = try e.check()
  let state = try contents(&e).filter { !$0.value.isEmpty }
  let g = w.states.indices.filter { w.states[$0] == state }
  #expect(g.contains { $0 >= lower && $0 <= upper }, "state matches groups \(g), want \(lower)...\(upper)")
  // The mounted volume takes new work.
  try e.apply([.insert(tree: 99, key: [1], value: [1])])
  try e.commitGroup()
  var again = try Engine.mount(e.store.volume.device)
  #expect(try again.get(99, [1]) == [1])
}

@Test(arguments: [UInt64(11), 12])
func everyPrefixOfTheWritesMounts(seed: UInt64) throws {
  let w = try record(seed: seed, groups: 20)
  var image = w.image
  for k in 0...w.units.count {
    if k > 0, let block = w.units[k - 1].block { try image.write(block, w.units[k - 1].bytes) }
    // Groups whose commit returned are durable; one started may be too.
    let lower = w.returned.lastIndex { $0 <= k } ?? 0
    let upper = w.started.lastIndex { $0 <= k } ?? 0
    try verify(image, w, durableThrough: lower, atMost: upper)
  }
}

@Test(arguments: [UInt64(21), 22])
func writesBetweenBarriersLandInAnyOrder(seed: UInt64) throws {
  let w = try record(seed: seed, groups: 16)
  var rng = SplitMix(state: seed &* 7)
  var image = w.image
  var at = 0
  while at < w.units.count {
    // The window: the units up to the next barrier.
    var end = at
    while end < w.units.count, w.units[end].block != nil { end += 1 }
    // The crash comes at the window's end, before its barrier: whatever
    // returned by then promised durability (a commit or fsync whose own
    // barrier closes the window returns after it, so isn't counted).
    let lower = w.returned.lastIndex { $0 <= end } ?? 0
    let upper = w.started.lastIndex { $0 <= end } ?? 0
    for _ in 0..<4 {
      var crashed = image
      for u in w.units[at..<end] where rng.below(2) == 0 { try crashed.write(u.block!, u.bytes) }
      try verify(crashed, w, durableThrough: lower, atMost: upper)
    }
    for u in w.units[at..<end] { try image.write(u.block!, u.bytes) }
    at = end + 1  // past the barrier
  }
}
