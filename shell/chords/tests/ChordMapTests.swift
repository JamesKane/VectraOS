// SPDX-License-Identifier: BSD-3-Clause

// The chord map (D116): chord names to keys, and Settings' `Chords` over
// the defaults.

import ChordMap
import Testing

@Test func chordNamesAreModifiersAndAKey() {
  #expect(ChordKey("super-1") == ChordKey(code: 0x1E, modifiers: 8))
  #expect(ChordKey("super-shift-t") == ChordKey(code: 0x17, modifiers: 9))
  #expect(ChordKey("ctrl-alt-return") == ChordKey(code: 0x28, modifiers: 6))
  #expect(ChordKey("super-0")?.code == 0x27 && ChordKey("super-f12")?.code == 0x45)
  // A key alone, shift alone, a modifier twice, or an unknown word aren't.
  for bad in ["t", "shift-t", "super-super-t", "hyper-t", "super-f13", "super-", "super-tt"] {
    #expect(ChordKey(bad) == nil)
  }
}

@Test func theDefaultsWithNoMapKept() {
  let m = ChordMap.map([])
  #expect(m.count == ChordMap.defaults.count)
  #expect(m.first { $0.chord == "super-shift-t" }?.action == "mode toggle")
  #expect(m.first { $0.chord == "super-2" }?.key == ChordKey(code: 0x1F, modifiers: 8))
}

@Test func aKeptMapReplacesTheDefaults() {
  let m = ChordMap.map([("Chords:super-t", "mode toggle"), ("Chords:bogus", "workspace 1"),
                        ("Chords:super-t", "workspace 2"), ("Chords:alt-1", ""), ("Other:super-1", "workspace 1")])
  #expect(m.count == 1 && m[0].chord == "super-t" && m[0].action == "mode toggle")
}
