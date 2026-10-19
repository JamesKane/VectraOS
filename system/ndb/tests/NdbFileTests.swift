// SPDX-License-Identifier: BSD-3-Clause

// ndb(6)'s format (system/ndb): entries, quoting, comments, and the file
// line each pair came from.

import NdbFile
import Testing

let sample = """
  # A comment at the margin doesn't end an entry.
  sys=gate ip=10.0.2.2 vendor="QEMU user network"
  \tdom=gate.lab
  theme=neon-tab title="Neon Tab" inherits=base
  \tauthor="todhchai's storyboard, ported"   # a comment after the pairs
  typeface=body family="IBM Plex Sans" weight=400
  flag
  """

@Test func valuesWithSpacesAreQuoted() {
  let db = NdbDatabase(parsing: Array(sample.utf8))
  #expect(db.entries.count == 4)
  #expect(db.value("sys", "gate", want: "vendor") == "QEMU user network")
  #expect(db.value("theme", "neon-tab", want: "title") == "Neon Tab")
  #expect(db.value("theme", "neon-tab", want: "author") == "todhchai's storyboard, ported")
  #expect(db.value("typeface", "body", want: "family") == "IBM Plex Sans")
  #expect(db.value("typeface", "body", want: "weight") == "400")
}

@Test func pairsKnowTheirLines() {
  let db = NdbDatabase(parsing: Array(sample.utf8))
  let gate = db.entries[0].pairs
  #expect(gate.map { $0.source } == [2, 2, 2, 3])
  #expect(gate.map { $0.line } == [0, 0, 0, 1])
  #expect(db.entries[3].pairs.map { $0.attr } == ["flag"])
  #expect(db.entries[3].pairs[0].value == "")
}

@Test func linesQuoteWhatNeedsIt() {
  let db = NdbDatabase(parsing: Array(sample.utf8))
  #expect(db.entries[0].lines == ["sys=gate ip=10.0.2.2 vendor=\"QEMU user network\"", "dom=gate.lab"])
  #expect(ndbQuoted("a#b") == "\"a#b\"")
  #expect(ndbQuoted("plain") == "plain")
}
