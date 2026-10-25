// SPDX-License-Identifier: BSD-3-Clause

import Directives
import Testing

func read(_ text: String, known: [StaticString] = ["a", "b"], firstLine: Int = 1) throws(DirectiveError) -> [Directive] {
  try Directives.read(Array(text.utf8), file: "t", known: known, firstLine: firstLine)
}

@Test func directivesAndTheirWords() throws {
  let d = try read("a one  two\t three\n\n   \nb\n")
  #expect(d.count == 2)
  #expect(d[0].is("a") && d[0].line == 1 && d[0].arguments == ["one", "two", "three"])
  #expect(d[0].text == "one two three")
  #expect(d[1].is("b") && d[1].line == 4 && d[1].arguments.isEmpty)
}

@Test func commentsEndALine() throws {
  let d = try read("# a whole line\na x # and the rest\nb y#z\n")
  #expect(d.map(\.line) == [2, 3])
  #expect(d[0].arguments == ["x"])
  #expect(d[1].arguments == ["y"])
}

@Test func crLfAndNoFinalNewline() throws {
  let d = try read("a x\r\nb y")
  #expect(d.map(\.arguments) == [["x"], ["y"]])
}

@Test func anUnknownDirectiveStopsTheRead() {
  #expect(throws: DirectiveError("t:2: unknown directive 'c'")) { try read("a\nc\nb\n") }
}

@Test func linesAreNumberedFromWhereTheTextStarts() throws {
  #expect(try read("a\n\nb\n", firstLine: 3).map(\.line) == [3, 5])
  #expect(throws: DirectiveError("t:4: unknown directive 'z'")) { try read("a\nz\n", firstLine: 3) }
}

@Test func quotedWordsAreRcs() {
  func words(_ s: String) -> [String]? { Directives.quotedWords(Array(s.utf8))?.map { String(decoding: $0, as: UTF8.self) } }
  #expect(words("a  'b c'\td\r\n") == ["a", "b c", "d"])
  #expect(words("'it''s' ''") == ["it's", ""])
  #expect(words("x'y z'w") == ["xy zw"])
  #expect(words("'open") == nil)
}
