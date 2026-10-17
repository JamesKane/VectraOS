// SPDX-License-Identifier: BSD-3-Clause

@testable import Guide
import Testing

@Test func aPageForATerminal() throws {
  let out = string(try Render.text(page(ls)))
  #expect(out == """
    LS(1)                                                                      LS(1)

    NAME
         ls, lc — list contents of directory

    SYNOPSIS
         ls [-dlmnpqrstuFQT] [file ...]

    DESCRIPTION
         For each directory argument, ls lists the contents of the directory; for
         each <file> argument, it repeats its name. See namespace(7).

         -d   If an argument is a directory, list it, not its contents.

         -l   List in long format.

    TWO EXAMPLES

    EXAMPLES
         - one
         - two, continued

         Flag  Meaning
         -l    long

    SOURCE
         shell/commands/lib/Commands.swift

    SEE ALSO
         the commands (intro(1)), https://9p.io

    """)
}

@Test func oneNodeAtAWidth() throws {
  let out = string(try Render.text(page(ls), node: Array("examples".utf8), width: 40))
  #expect(out == """
    TWO EXAMPLES

    EXAMPLES
         - one
         - two, continued

         Flag  Meaning
         -l    long

    SEE ALSO
         the commands (intro(1)),
         https://9p.io

    """)
  #expect(throws: GuideError("ls(1): no node 'none'")) { try Render.text(page(ls), node: Array("none".utf8)) }
}

@Test func aLongTermGetsItsOwnLine() throws {
  let p = try page("page a 1\nsummary s\n\n: `--verbose`\n  Says more.\n: `x`\n")
  #expect(string(try Render.text(p)).hasSuffix("""
    NAME
         a — s

         --verbose
              Says more.

         x

    """))
}

@Test func linesFitTheirWidth() throws {
  // Refilled text breaks at spaces; only a word longer than the width runs
  // past it. (Fences are shown as written.)
  let p = try page("""
    page a 1
    summary words to fill

    # DESCRIPTION

    Text with `a literal`, <param>, a {link|rc(1)} and averyveryverylongwordthatnolinecanhold in it.

    - an item that goes on for a while, to be refilled under itself
    : `-t`
      A definition whose description is long enough to need two lines.

    """)
  for width in [20, 30, 50, 80] {
    for line in string(try Render.text(p, width: width)).split(separator: "\n") where line.count > width {
      #expect(!line.drop { $0 == " " }.contains(" "), "\(width): \(line)")
    }
  }
}
