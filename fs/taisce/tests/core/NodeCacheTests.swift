// SPDX-License-Identifier: BSD-3-Clause

// The store's node cache: it keeps to its budget, finds what it holds
// after any mix of puts, removals and evictions, and evicts a node not
// read before one that was.

@testable import Taisce
import Testing

func leaf(_ n: Int) -> Node {
  var node = Node(level: 0)
  for i in 0..<n { _ = node.insert(at: i, [UInt8(i >> 8), UInt8(i & 0xFF)], [UInt8](repeating: UInt8(i & 0xFF), count: 100)) }
  return node
}

@Test func theNodeCacheKeepsToItsBudgetAndFindsWhatItHolds() {
  let cost = NodeCache.cost(leaf(50))
  var cache = NodeCache(bytes: 40 * cost)
  var model: [UInt64: Int] = [:]  // block: the leaf's size
  var rng = SplitMix(state: 7)
  for _ in 0..<20_000 {
    let block = UInt64(rng.below(200)) * 4
    if rng.below(4) == 0 {
      cache.remove(block)
      model[block] = nil
    } else {
      let n = 40 + rng.below(20)
      cache.put(block, leaf(n))
      model[block] = n
    }
    #expect(cache.bytes <= cache.budget)
  }
  var held = 0
  for (block, n) in model {
    if let node = cache.node(block) {
      #expect(node.count == n)
      held += 1
    }
  }
  // Every node it holds is found; what it dropped was evicted for room.
  #expect(held == cache.count && held > 30)
}

@Test func aNodeReadSinceTheHandPassedIsSpared() {
  var cache = NodeCache(bytes: 3 * NodeCache.cost(leaf(60)))  // three, above the one-node floor
  for b in [UInt64(4), 8, 12] { cache.put(b, leaf(60)) }
  _ = cache.node(4)
  cache.put(16, leaf(60))  // evicts 8, the first not read
  #expect(cache.node(4) != nil && cache.node(8) == nil && cache.node(12) != nil && cache.node(16) != nil)
}
