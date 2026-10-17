// SPDX-License-Identifier: BSD-3-Clause

// The fuzzer: mutated pages are parsed, and those that parse are rendered
// at several widths and each node alone. A refusal is expected; a trap is
// the failure. `swift test` runs a few thousand from a fixed seed, so a
// crash there repeats; GUIDE_FUZZ=N runs N, each mutant's seed written to
// stderr first, unbuffered, so a crash names its input.

import Glibc
@testable import Guide
import Testing

struct Xorshift {
  var state: UInt64
  mutating func next() -> UInt64 {
    state ^= state << 13
    state ^= state >> 7
    state ^= state << 17
    return state
  }
  mutating func below(_ n: Int) -> Int { Int(next() % UInt64(max(n, 1))) }
}

/// Bytes guide gives meaning to, and some it refuses.
let interesting: [UInt8] = Array("`<>{}|()#@:- \n\t1289az_.+".utf8) + [0x0D, 0xC3, 0xA9, 0xE2, 0x80, 0xFF]

func mutate(_ page: [UInt8], _ rng: inout Xorshift) -> [UInt8] {
  var b = page
  for _ in 0..<(1 + rng.below(6)) {
    guard !b.isEmpty else { break }
    let at = rng.below(b.count)
    switch rng.below(6) {
    case 0: b[at] = interesting[rng.below(interesting.count)]
    case 1: b[at] ^= UInt8(1 << rng.below(8))
    case 2: b.removeSubrange(at..<min(b.count, at + 1 + rng.below(12)))
    case 3: b.insert(contentsOf: (0..<(1 + rng.below(6))).map { _ in interesting[rng.below(interesting.count)] }, at: at)
    case 4:  // a line copied elsewhere
      let from = rng.below(b.count), n = min(1 + rng.below(40), b.count - from)
      b.insert(contentsOf: Array(b[from..<(from + n)]), at: at)
    default: b.insert(0x0A, at: at)
    }
  }
  return b
}

@Test func fuzzPages() {
  let asked = getenv("GUIDE_FUZZ").flatMap { Int(String(cString: $0)) }
  let runs = asked ?? 3000
  let seeds = [ls, "page a 1\nsummary s\n\n@node x X\n\n| `a|b` | {c|d(2)#e} |\n|f\n\n```rc\n% ls\n```\n"]
  var rng = Xorshift(state: 0x9E37_79B9_7F4A_7C15)
  var parsed = 0
  for n in 0..<runs {
    let seed = rng.next()
    if asked != nil {
      let line = Array("guide fuzz \(n) seed \(seed)\n".utf8)
      _ = line.withUnsafeBytes { write(2, $0.baseAddress, $0.count) }
    }
    var local = Xorshift(state: seed | 1)
    let input = mutate(Array(seeds[n % seeds.count].utf8), &local)
    guard let p = try? Page(input, file: "fuzz") else { continue }
    parsed += 1
    for width in [1, 20, 80] {
      let out = try? Render.text(p, width: width)
      #expect(out != nil)
    }
    for b in p.blocks where b.kind == .node { _ = try? Render.text(p, node: b.node) }
  }
  // The mutations keep enough pages whole for rendering to be exercised.
  #expect(parsed > runs / 20)
}
