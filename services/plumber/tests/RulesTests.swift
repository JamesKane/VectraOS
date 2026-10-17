// SPDX-License-Identifier: BSD-3-Clause

// The plumber's rules (todhchai's router's core, M6k part k1): its regular expressions (Plan 9's
// syntax, whole and searched, with groups) and its rules (plumb(6)'s
// format: patterns, rewrites, $ expansion, ports and starts), on the
// plumber's own kinds of message: a compiler's file:line, a URL, an image.

import Plumber
import Testing

@Test func regularExpressions() {
  func whole(_ re: String, _ s: String) -> [String?]? { Regex(re)!.matchWhole(s) }
  #expect(whole("abc", "abc")?[0] == "abc" && whole("abc", "abcd") == nil)
  #expect(whole("a*b+c?", "aaabb")?[0] == "aaabb" && whole("a*b+c?", "c") == nil)
  #expect(whole("(cat|dog)s?", "dogs")?[1] == "dog")
  #expect(whole("[a-z_]+\\.swift", "main_view.swift") != nil && whole("[^0-9]+", "ab3") == nil)
  #expect(whole(".*", "x\ny") == nil && whole("a.c", "a\u{e9}c") != nil)
  let fileLine = "([a-zA-Z0-9_./-]+\\.swift):([0-9]+)(:([0-9]+))?"
  let g = whole(fileLine, "Sources/App/file.swift:120:7")
  #expect(g?[1] == "Sources/App/file.swift" && g?[2] == "120" && g?[4] == "7")
  #expect(whole(fileLine, "file.swift:12")?[3] == nil)
  // Searching: the leftmost.
  #expect(Regex("[0-9]+")!.search("abc 42 and 7")?[0] == "42")
  #expect(Regex("^b")!.search("a\nb")?[0] == "b" && Regex("a$")!.search("ab") == nil)
  #expect(Regex("(ab") == nil && Regex("*a") == nil && Regex("[ab") == nil)
}

let rules = """
  # Compiler output: a Swift file and line, in the editor.
  type is text
  data matches '([a-zA-Z0-9_./-]+\\.swift):([0-9]+)(:[0-9]+)?'
  arg isfile $1
  data set $file
  attr add line=$2
  plumb to edit
  plumb start viewer $file

  # URLs, to the browser.
  type is text
  data matches '(https?|ftp)://[^ ]+'
  plumb to web

  # Pictures, whatever their kind.
  type is image/*
  plumb to image
  plumb start viewer $data

  # A song by its artist's attribute.
  attr is Audio:Artist=Portishead
  plumb to music

  editor=viewer
  # A directory, to Tracker.
  type is text
  arg isdir $data
  data set $dir
  plumb to folder
  plumb start $editor --folder $dir
  """

@Test func messagesTakeTheFirstRulesetThatHolds() throws {
  let r = try Rules(rules)
  let files: (String) -> Rules.FileKind? = { $0 == "/home/me/src/main.swift" ? .file : $0 == "/home/me" ? .directory : nil }
  // file:line, relative to the message's wdir: the file found, its line an attribute.
  let a = try #require(r.route(RouteMessage(src: "terminal", wdir: "/home/me", data: "src/main.swift:42:7"), files: files))
  #expect(a.port == "edit" && a.message.data == "/home/me/src/main.swift" && a.message.attr("line") == "42")
  #expect(a.message.dst == "edit" && a.start == ["viewer", "/home/me/src/main.swift"] && a.line == 2)
  // No such file: the ruleset doesn't hold; nothing else does either.
  #expect(r.route(RouteMessage(wdir: "/home/me", data: "nope.swift:1"), files: files) == nil)
  #expect(r.route(RouteMessage(data: "see https://haiku-os.org/docs now")) == nil)  // matches is the whole text
  #expect(r.route(RouteMessage(data: "https://haiku-os.org/docs"))?.port == "web")
  let img = try #require(r.route(RouteMessage(type: "image/png", data: "/home/me/a.png")))
  #expect(img.port == "image" && img.start == ["viewer", "/home/me/a.png"])
  let song = RouteMessage(type: "audio/flac", data: "x.flac", attrs: [("Audio:Artist", "Portishead")])
  #expect(r.route(song)?.port == "music")
  // A variable defined between rulesets, and isdir's $dir.
  let dir = try #require(r.route(RouteMessage(data: "/home/me"), files: files))
  #expect(dir.port == "folder" && dir.start == ["viewer", "--folder", "/home/me"])
}

@Test func rulesFailWithTheirLine() {
  #expect(throws: RuleError(line: 2, message: "no verb was")) { try Rules("type is text\ndata was here\n") }
  #expect(throws: RuleError(line: 1, message: "an unclosed quote")) { try Rules("data matches 'abc\n") }
  #expect(throws: RuleError(line: 1, message: "a bad expression: (a")) { try Rules("data matches '(a'\n") }
  #expect(throws: RuleError(line: 3, message: "plumb to PORT")) { try Rules("type is text\n\nplumb to\n") }
  // Quotes: two for one; comments not inside quotes.
  let r = try? Rules("data is 'it''s # here' # a comment\nplumb to x\n")
  #expect(r?.route(RouteMessage(data: "it's # here"))?.port == "x")
}

