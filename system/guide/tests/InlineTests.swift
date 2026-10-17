// SPDX-License-Identifier: BSD-3-Clause

@testable import Guide
import Testing

func spans(_ s: String) throws(InlineError) -> [Span] { try Inline.spans(Array(s.utf8)) }

@Test func theFourForms() throws {
  let s = try spans("Run `ls -l` on <file>, see rc(1) and {the intro|intro(1)}.")
  #expect(s.map(\.kind) == [
    .text, .space, .literal, .space, .text, .space, .parameter, .text, .space, .text, .space, .reference, .space,
    .text, .space, .link, .text,
  ])
  #expect(string(s[2].text) == "ls -l")
  #expect(string(s[6].text) == "<file>")
  #expect(string(s[11].name) == "rc" && s[11].section == 1)
  #expect(string(s[15].label) == "the intro" && string(s[15].target) == "intro(1)" && s[15].labelled)
}

@Test func literalsTakeTheirBackticks() throws {
  #expect(string(try spans("``a ` b``")[0].text) == "a ` b")
  #expect(string(try spans("`` `x` ``")[0].text) == "`x`")
  #expect(string(try spans("` `")[0].text) == " ")
  #expect(throws: InlineError.self) { try spans("``a`") }
}

@Test func whatIsNotAForm() throws {
  // `<` before a digit, and a section past 8.
  #expect(try spans("a <1> b(9)").allSatisfy { $0.kind == .text || $0.kind == .space })
  let r = try spans("Process.start(2)")
  #expect(r.count == 1 && r[0].kind == .reference && string(r[0].name) == "Process.start")
}

@Test func linkTargets() {
  #expect(Inline.isTarget(Array("rc(1)".utf8)))
  #expect(Inline.isTarget(Array("rc(1)#quoting".utf8)))
  #expect(Inline.isTarget(Array("#quoting".utf8)))
  #expect(Inline.isTarget(Array("https://9p.io/sys/doc".utf8)))
  #expect(Inline.isTarget(Array("gemini://x.y".utf8)))
  #expect(!Inline.isTarget(Array("https:".utf8)))
  #expect(!Inline.isTarget(Array("http://x.y".utf8)))
  #expect(!Inline.isTarget(Array("rc(1)#Q".utf8)))
  #expect(!Inline.isTarget(Array("rc".utf8)))
}

@Test func cells() {
  #expect(Inline.cells(Array(" a | b |".utf8)).map(string) == ["a", "b"])
  #expect(Inline.cells(Array(" a | b".utf8)).map(string) == ["a", "b"])
  #expect(Inline.cells(Array(" `x|y` | z |".utf8)).map(string) == ["`x|y`", "z"])
  #expect(Inline.cells(Array(" a || c |".utf8)).map(string) == ["a", "", "c"])
  #expect(Inline.cells(Array("  ".utf8)).isEmpty)
}
