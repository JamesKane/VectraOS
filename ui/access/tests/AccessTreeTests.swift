// SPDX-License-Identifier: BSD-3-Clause

// The packed accessibility tree (M6i part 4): what's packed comes back,
// a transform scales and moves every rectangle, and a reader refuses
// every damaged tree (any byte of the header or a node changed to
// something wrong, any truncation).

import AccessTree
import Testing

private func sample() -> AccessTree {
  AccessTree(nodes: [
    AccessNode(key: 1, parent: -1, role: .window, label: "Trip-hop, 90s · query", value: "", x: 0, y: 0,
               width: 600, height: 300, states: [], action: -1),
    AccessNode(key: 2, parent: 0, role: .textField, label: "Query", value: "Audio:Year in 1990..<2000", x: 10,
               y: 10, width: 300, height: 24, states: [.focusable, .focused, .editable], action: -1),
    AccessNode(key: 3, parent: 0, role: .button, label: "Save", value: "", x: 320, y: 10, width: 60, height: 24,
               states: [.focusable], action: 0),
    AccessNode(key: 4, parent: 0, role: .list, label: "Results", value: "", x: 0, y: 40, width: 600, height: 260,
               states: [], action: -1),
    AccessNode(key: 5, parent: 3, role: .row, label: "", value: "", x: 0, y: 40, width: 600, height: 22,
               states: [.selected], action: -1),
  ], actions: ["file.save", "route.edit"])
}

@Test func aTreeRoundTrips() throws {
  let t = sample()
  let bytes = t.encoded()
  #expect(bytes.count == 16 + 5 * 56 + 2 * 8 + t.nodes.reduce(0) { $0 + $1.label.utf8.count + $1.value.utf8.count }
    + "file.saveroute.edit".utf8.count)
  #expect(try AccessTree(decoding: bytes) == t)
  #expect(try AccessTree(decoding: AccessTree().encoded()) == AccessTree())
  #expect(t.focused == 1)
}

@Test func aTransformScalesThenMoves() {
  var t = sample()
  t.transform(scale: 2, dx: 100, dy: 50)
  #expect(t.nodes[2].x == 740 && t.nodes[2].y == 70 && t.nodes[2].width == 120 && t.nodes[2].height == 48)
}

@Test func aDamagedTreeIsRefused() {
  let bytes = sample().encoded()
  func refused(_ b: [UInt8]) -> Bool { (try? AccessTree(decoding: b)) == nil }
  // Truncated anywhere before the strings' end.
  for n in [0, 3, 15, 16, 70, 16 + 5 * 56, bytes.count - 1] { #expect(refused(Array(bytes[0..<n]))) }
  func with(_ at: Int, _ v: UInt8) -> [UInt8] {
    var b = bytes
    b[at] = v
    return b
  }
  #expect(refused(with(0, 0x55)))  // magic
  #expect(refused(with(4, 2)))  // version
  #expect(refused(with(8, 0xFF)))  // node count
  #expect(refused(with(12, 9)))  // action count
  let node = 16 + 2 * 56
  #expect(refused(with(node + 8, 2)))  // its parent after it
  #expect(refused(with(16 + 8, 0)))  // the root with a parent
  #expect(refused(with(node + 12, 2)))  // an action out of range
  #expect(refused(with(node + 20, 99)))  // a role nobody knows
  #expect(refused(with(node + 21, 1)))  // padding
  #expect(refused(with(node + 44, 0xFF)))  // a label past the strings
}
