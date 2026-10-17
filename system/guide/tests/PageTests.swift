// SPDX-License-Identifier: BSD-3-Clause

@testable import Guide
import Testing

func page(_ text: String) throws(GuideError) -> Page { try Page(Array(text.utf8), file: "p") }

func failure(_ text: String) -> String? {
  do throws(GuideError) {
    _ = try page(text)
    return nil
  } catch {
    return error.description
  }
}

func string(_ b: [UInt8]) -> String { String(decoding: b, as: UTF8.self) }

let ls = """
  page ls 1
  summary list contents of directory
  names ls lc
  src shell/commands/lib/Commands.swift
  keys directory listing

  # SYNOPSIS

  ```usage
  ls [-dlmnpqrstuFQT] [file ...]
  ```

  # DESCRIPTION

  For each directory argument, `ls` lists the contents of the directory;
  for each <file> argument, it repeats its name. See namespace(7).

  : `-d`
    If an argument is a directory, list it, not its contents.
  : `-l`
    List in long format.

  @node examples Two examples

  # EXAMPLES

  - one
  - two,
    continued

  | Flag | Meaning |
  | `-l` | long |

  # SEE ALSO

  {the commands|intro(1)}, {https://9p.io}

  """

@Test func aWholePage() throws {
  let p = try page(ls)
  #expect(p.header.page == "ls" && p.header.section == 1)
  #expect(p.header.summary == "list contents of directory")
  #expect(p.header.names == ["ls", "lc"])
  #expect(p.header.sources == ["shell/commands/lib/Commands.swift"])
  #expect(p.header.keys == ["directory", "listing"])
  #expect(p.blocks.map(\.kind) == [
    .heading, .fence, .heading, .paragraph, .definition, .definition, .node, .heading, .item, .item, .row, .row,
    .heading, .paragraph,
  ])
  #expect(p.blocks[0].line == 7)
  #expect(p.blocks[1].fence == .usage && string(p.blocks[1].text) == "ls [-dlmnpqrstuFQT] [file ...]\n")
  #expect(string(p.blocks[3].text).hasSuffix("repeats its name. See namespace(7)."))
  #expect(string(p.blocks[4].text) == "`-d`")
  #expect(string(p.blocks[4].body) == "  If an argument is a directory, list it, not its contents.")
  #expect(string(p.blocks[6].node) == "examples" && string(p.blocks[6].title) == "Two examples")
  #expect(string(p.blocks[9].text) == "two,\n  continued")
}

@Test func theHeadersDefaultsAndFlags() throws {
  let p = try page("@guide 1\npage cat 1\nsummary concatenate files\nlang rc\nhost\n\nText.\n")
  #expect(p.header.names == ["cat"] && p.header.language == .rc && p.header.host)
  #expect(p.blocks.count == 1 && p.blocks[0].line == 7)
}

@Test func headersAreChecked() {
  #expect(failure("summary s\npage a 1\n") == "p:1: 'page' must come first")
  #expect(failure("page A 1\nsummary s\n") == "p:1: 'page' takes a name and a section")
  #expect(failure("page a 9\nsummary s\n") == "p:1: a section is 1 to 8")
  #expect(failure("page a 1\nsummary s\nsummary t\n") == "p:3: a second 'summary'")
  #expect(failure("page a 1\nsummary ends.\n") == "p:2: a summary has no full stop")
  #expect(failure("page a 1\nsee b\n") == "p:2: unknown directive 'see'")
  #expect(failure("page a 1\n") == "p:1: no 'summary'")
  #expect(failure("page a 1\nsummary s\nlang go\n") == "p:3: 'lang' takes swift, c or rc")
  #expect(failure("page a 1\nsummary s\nnames a b(c\n") == "p:3: bad name 'b(c'")
  #expect(failure("@guide 2\npage a 1\nsummary s\n") == "p:1: a version of guide this parser doesn't know")
}

@Test func bodiesAreChecked() {
  let h = "page a 1\nsummary s\n\n"
  #expect(failure(h + "#X\n") == "p:4: a heading is # or ##, then a space")
  #expect(failure(h + "# NAME\n") == "p:4: NAME and SOURCE are made from the header")
  #expect(failure(h + "  stray\n") == "p:4: a continuation line with nothing to continue")
  #expect(failure(h + "```go\n```\n") == "p:4: a fence kind guide doesn't know")
  #expect(failure(h + "text\n\n```\nopen\n") == "p:6: a fence that is never closed")
  #expect(failure(h + "@index x\n") == "p:4: a directive guide doesn't know")
  #expect(failure(h + "@guide 1\n") == "p:4: '@guide' comes first, before the header")
  #expect(failure(h + "@node Big\n") == "p:4: '@node' takes an id: a-z, 0-9 and -")
  #expect(failure(h + "@node a\n\n@node a\n") == "p:6: a node id used twice")
  #expect(failure(h + ":  \n") == "p:4: a definition with no term")
  #expect(failure(h + "one\ntwo `open\n") == "p:4: a literal that is never closed")
  #expect(failure(h + "| a | {b |\n") == "p:4: a { link } that is never closed")
  #expect(failure(h + "- {x|ftp://y}\n") == "p:4: a link to no target guide knows")
}

@Test func onlyUTF8() {
  var bytes = Array("page a 1\nsummary s\n\nok\n".utf8)
  bytes += [0xC3, 0x28, 0x0A]  // a lead byte, then no continuation
  #expect(throws: GuideError("p:5: not UTF-8")) { try Page(bytes, file: "p") }
  #expect(invalidUTF8(Array("é ü → 𝄞".utf8)) == nil)
  #expect(invalidUTF8([0xED, 0xA0, 0x80]) == 1)  // a surrogate
  #expect(invalidUTF8([0xC0, 0x80]) == 1)  // overlong
}
