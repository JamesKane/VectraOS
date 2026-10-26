// SPDX-License-Identifier: BSD-3-Clause

// A node's page: a damaged page is refused, never trusted, and removed
// cells' bytes come back when the cells are packed.

@testable import Taisce
import Testing

/// A leaf of `n` entries, each a 2-byte key and a value of `size`.
func page(_ n: Int, size: Int) -> Node {
  var node = Node(level: 0)
  for i in 0..<n { _ = node.insert(at: i, [UInt8(i >> 8), UInt8(i & 0xFF)], [UInt8](repeating: UInt8(i & 0xFF), count: size)) }
  return node
}

@Test func aDamagedPageIsRefusedNeverTrusted() throws {
  let good = page(60, size: 200)
  #expect(try Node(page: good.page) == good)
  var rng = SplitMix(state: 11)
  var refused = 0
  for _ in 0..<5000 {
    var bytes = good.page
    // Damage the header or the slots, where a bad offset would point
    // outside the page.
    for _ in 0..<(1 + rng.below(3)) { bytes[rng.below(48 + 2 * 60)] ^= UInt8(1 << rng.below(8)) }
    guard let n = try? Node(page: bytes) else {
      refused += 1
      continue
    }
    // Accepted: every key and value is inside the page.
    for i in 0..<n.count {
      _ = n.key(i)
      if n.isLeaf { _ = n.value(i) } else { _ = n.child(i + 1) }
    }
  }
  #expect(refused > 4000)
  #expect(throws: TaisceError.corrupt(.node)) { try Node(page: [UInt8](repeating: 0, count: Node.bytes)) }
  #expect(throws: TaisceError.corrupt(.node)) { try Node(page: Array(good.page.prefix(4096))) }
}

@Test func removedCellsComeBackWhenPacked() throws {
  var node = page(60, size: 200)
  var model = (0..<60).map { [UInt8](repeating: UInt8($0), count: 200) }
  // Every other entry removed, then larger values in their place: they
  // fit only once the dead cells are packed.
  for i in stride(from: 58, through: 0, by: -2) {
    node.remove(i)
    model.remove(at: i)
  }
  #expect(node.garbage > 0)
  var added = 0
  while node.insert(at: node.count, [0xFF, UInt8(added)], [UInt8](repeating: 0xEE, count: 400)) {
    model.append([UInt8](repeating: 0xEE, count: 400))
    added += 1
  }
  #expect(added > 15)
  #expect(node.used <= Node.bytes && node.used + 2 + 406 > Node.bytes)
  #expect((0..<node.count).map { node.value($0) } == model)
  // A value replaced by a shorter one, then that room taken by a longer
  // one; one that won't fit leaves the node as it was.
  let shorter = node.replaceValue(0, [UInt8](repeating: 1, count: 50))
  #expect(shorter)
  model[0] = [UInt8](repeating: 1, count: 50)
  let longer = node.replaceValue(2, [UInt8](repeating: 2, count: 340))
  #expect(longer)
  model[2] = [UInt8](repeating: 2, count: 340)
  let tooLong = node.replaceValue(1, [UInt8](repeating: 1, count: BTree.maxValue))
  #expect(!tooLong)
  #expect((0..<node.count).map { node.value($0) } == model)
  #expect(try Node(page: node.page) == node)
}
