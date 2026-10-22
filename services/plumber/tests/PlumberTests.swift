// SPDX-License-Identifier: BSD-3-Clause

// The plumber (D85), as plumber(4) and plumb(6) describe it: messages in
// their text form both ways; every reader of a port gets a copy, one
// message a read; with no reader, `plumb client` holds the message for the
// app it starts and `plumb start` drops it, and with neither the send
// fails; rules appended make their ports, and bad ones keep the old.

import Plumber
import Testing

func packed(_ data: String, type: String = "text", wdir: String = "/src", attrs: [(name: String, value: String)] = [])
  -> [UInt8]
{
  RouteMessage(src: "test", wdir: wdir, type: type, data: data, attrs: attrs).packed
}

@Test func messagesInTheirTextForm() {
  let m = RouteMessage(src: "rc", dst: "", wdir: "/src", type: "text", data: "two\nlines",
                       attrs: [("addr", "12"), ("note", "it's here")])
  #expect(m.packed == Array("rc\n\n/src\ntext\naddr=12 note='it''s here'\n9\ntwo\nlines".utf8))
  #expect(RouteMessage(packed: m.packed) == m)
  #expect(RouteMessage(packed: Array("a\nb\nc\nd\n\n3\nxy".utf8)) == nil)  // ndata says 3
  #expect(RouteMessage(packed: Array("a\nb\nc\n".utf8)) == nil)
}

@Test func everyReaderOfAPortGetsACopy() throws {
  let files: (String) -> Rules.FileKind? = { $0 == "/src/main.swift" ? .file : nil }
  let p = try Plumber(rules: Rules.defaults, host: PlumberHost(files: files))
  #expect(p.portNames == ["edit", "man", "web", "mail", "image"])
  let a = try #require(p.open(port: "edit")), b = try #require(p.open(port: "edit"))
  #expect(try p.send(packed("main.swift:12")) == "edit")
  let got = RouteMessage(packed: a.take(4096) ?? [])
  #expect(got?.data == "/src/main.swift" && got?.dst == "edit" && got?.attr("addr") == "12")
  #expect(b.take(4096) == got?.packed)  // the same message, for the other reader
  // One message a read, a long one over several.
  _ = try p.send(packed("main.swift:1"))
  _ = try p.send(packed("main.swift:2"))
  let first = a.take(10) ?? []
  #expect(first.count == 10)
  let rest = a.take(4096) ?? []
  #expect(RouteMessage(packed: first + rest)?.attr("addr") == "1")
  #expect(RouteMessage(packed: a.take(4096) ?? [])?.attr("addr") == "2")
  #expect(a.take(4096) == nil)
  // A reader gone no longer hears.
  p.close(b, port: "edit")
  _ = try p.send(packed("main.swift:3"))
  #expect(p.status.utf8.starts(with: "port edit readers 1 held 0 delivered 4\n".utf8))
}

@Test func noReaderStartsHoldsOrFails() throws {
  var started: [[String]] = []
  let host = PlumberHost(start: { argv, wdir in
    started.append(argv + [wdir])
    return argv.first == "missing" ? "no such program" : nil
  })
  let p = try Plumber(rules: """
    type is text
    data matches 'hold (.*)'
    plumb to held
    plumb client cat /mnt/plumb/held

    type is text
    data matches 'drop .*'
    plumb to dropped
    plumb start echo $data

    type is text
    data matches 'broken'
    plumb to broken
    plumb start missing
    """, host: host)
  // client: started, the message held until the port is opened.
  #expect(try p.send(packed("hold this")) == "held")
  #expect(started == [["cat", "/mnt/plumb/held", "/src"]])
  let r = try #require(p.open(port: "held"))
  #expect(RouteMessage(packed: r.take(4096) ?? [])?.data == "hold this")
  // start: started, the message dropped.
  _ = try p.send(packed("drop that"))
  #expect(started.last == ["echo", "drop that", "/src"])
  // Neither, or a start that fails, or no rule: the send fails.
  #expect(throws: PlumbError.startFailed("no such program")) { try p.send(packed("broken")) }
  #expect(throws: PlumbError.noRule) { try p.send(packed("nothing takes this")) }
  #expect(throws: PlumbError.badMessage) { try p.send(Array("not a message".utf8)) }
  let q = try Plumber(rules: Rules.defaults, host: host)
  #expect(throws: PlumbError.noReader("web")) { try q.send(packed("https://example.org")) }
  #expect(q.status.utf8.reversed().starts(with: "sent refused: no reader for port web\n".utf8.reversed()))
}

@Test func rulesAppendedMakeTheirPorts() throws {
  let p = try Plumber(rules: Rules.defaults, host: PlumberHost())
  try p.append(rules: "type is text\ndata matches 'hi'\nplumb to greet\n")  // its own ruleset
  #expect(p.portNames.last == "greet")
  let g = try #require(p.open(port: "greet"))
  _ = try p.send(packed("hi"))
  #expect(g.take(4096) != nil)
  // A bad rule: its line counted across the whole set, the defaults first.
  #expect(throws: RuleError(line: 43, message: "no verb was")) { try p.append(rules: "\ndata was here\n") }
  #expect(p.portNames.last == "greet")  // kept
  #expect(p.open(port: "nowhere") == nil)
}

/// A page of the manual, `name(N)`, goes to `man` (guide(4)); a name
/// without a section, or with one guide hasn't, doesn't.
@Test func aPageOfTheManualGoesToMan() throws {
  let p = try Plumber(rules: Rules.defaults, host: PlumberHost(files: { _ in nil }))
  let man = try #require(p.open(port: "man"))
  #expect(try p.send(packed("rc(1)")) == "man")
  #expect(RouteMessage(packed: man.take(4096) ?? [])?.data == "rc(1)")
  #expect(try p.send(packed("master-stack(4)")) == "man")
  #expect(throws: PlumbError.self) { try p.send(packed("rc(9)")) }
  #expect(throws: PlumbError.self) { try p.send(packed("rc()")) }
}

/// With no reader on `man`, a page isn't taken: guide is an app the
/// user starts, which the plumber doesn't.
@Test func aPageWithNoReaderIsRefused() throws {
  var started: [String] = []
  var host = PlumberHost(files: { _ in nil })
  host.start = { argv, _ in
    started.append(argv.joined(separator: " "))
    return nil
  }
  let p = try Plumber(rules: Rules.defaults, host: host)
  #expect(throws: PlumbError.self) { try p.send(packed("rc(1)")) }
  #expect(started.isEmpty)
}

/// Text beyond ASCII matches and is captured scalar by scalar.
@Test func regexOverUnicode() throws {
  let r = try #require(Regex("(.)é+(€|😀)"))
  #expect(r.matchWhole("aéé😀")! == ["aéé😀", "a", "😀"])
  #expect(r.matchWhole("aée") == nil)
}
