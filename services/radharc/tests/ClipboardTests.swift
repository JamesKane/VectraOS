// SPDX-License-Identifier: BSD-3-Clause

// The clipboard (D112): an entry written on `clip/new`, its lines checked
// as they come and committed only whole; `snarf`'s text; a secret entry
// cleared after its life; and the read rule, the focused window's client
// after it has had input, until focus leaves.

import Radharc
import Testing

func clipEntry(_ parts: [String], chunk: Int = 3) throws(ClipRefusal) -> ClipEntry {
  var w = ClipWriter(snarf: false)
  let bytes = Array(parts.joined().utf8)
  var i = 0
  while i < bytes.count {
    try w.write(Array(bytes[i..<min(bytes.count, i + chunk)]))
    i += chunk
  }
  return try w.finish()
}

func clipRefusal(_ parts: [String]) -> String? {
  do throws(ClipRefusal) {
    _ = try clipEntry(parts)
    return nil
  } catch {
    return error.reason
  }
}

@Test func anEntryIsWrittenWholeOnClipNew() throws {
  let e = try clipEntry(["type=text/plain;charset=utf-8 length=5\n", "hello", "type=IMAGE/png length=4\n", "\u{1}\u{2}\u{3}\u{4}"])
  #expect(e.representations.map { $0.name } == ["text.plain", "image.png"] && !e.secret && e.size == 9)
  #expect(e.representations[0].type == "text/plain;charset=utf-8" && e.representations[0].bytes == Array("hello".utf8))
  // A line's bytes may hold newlines, and a representation may be empty.
  let n = try clipEntry(["type=text/uri-list length=2 secret=1\n", "\n\n", "type=text/x-empty length=0\n"], chunk: 1)
  #expect(n.secret && n.representations.map { $0.bytes.count } == [2, 0])

  #expect(clipRefusal(["type=text/plain length=5\n", "hel"]) == "it ends inside a representation")
  #expect(clipRefusal(["type=text/plain length=5\n", "hello", "type=image"]) == "it ends inside a representation")
  #expect(clipRefusal([]) == "an entry has a representation")
  #expect(clipRefusal(["type=text length=1\n"]) == "type= is a MIME type")
  #expect(clipRefusal(["type=text/plain\n"]) == "a line has type= and length=")
  #expect(clipRefusal(["type=text/plain length=-1\n"]) == "length= is a number")
  #expect(clipRefusal(["type=a/b length=0 note=x\n"]) == "a line is type=, length= and secret=")
  #expect(clipRefusal(["type=a/b length=0\n", "type=c/d length=0 secret=1\n"]) == "secret=1, on the first line")
  #expect(clipRefusal(["type=text/plain length=0\n", "type=TEXT/plain;x=y length=0\n"]) == "one text.plain an entry")
  #expect(clipRefusal(["type=text/plain length=1048577\n"]) == "text longer than 1 MiB")
  #expect(clipRefusal(["type=image/png length=16777217\n"]) == "longer than 16 MiB")
  #expect(clipRefusal([String(repeating: "x", count: 1025)]) == "a line longer than 1024 bytes")
  #expect(clipRefusal((0...16).map { "type=a/b\($0) length=0\n" }) == "more than 16 representations")
}

@Test func snarfIsText() throws {
  var w = ClipWriter(snarf: true)
  #expect(!w.wrote)
  try w.write(Array("type=not a header\n".utf8))
  try w.write(Array("more".utf8))
  let e = try w.finish()
  #expect(w.wrote && e.representations.count == 1 && e.representations[0].type == Clipboard.textType)
  var c = Clipboard()
  c.commit(e, now: 0)
  #expect(c.text == Array("type=not a header\nmore".utf8) && c.names == ["text.plain"] && c.commits == 1)
  // Too long: refused as it is written.
  var long = ClipWriter(snarf: true)
  try long.write([UInt8](repeating: 0x61, count: ClipWriter.maxText))
  do throws(ClipRefusal) {
    try long.write([0x61])
    Issue.record("a text past 1 MiB taken")
  } catch {
    #expect(error.reason == "text longer than 1 MiB")
  }
  // An entry without text has none for snarf.
  c.commit(try clipEntry(["type=image/png length=1\n", "x"]), now: 1)
  #expect(c.text.isEmpty && c.bytes(named: "image.png") == [0x78] && c.bytes(named: "text.plain") == nil)
}

@Test func aSecretEntryIsClearedAfterItsLife() throws {
  var c = Clipboard()
  c.commit(try clipEntry(["type=text/plain length=2 secret=1\n", "pw"]), now: 1_000)
  #expect(!c.expire(now: 1_000 + Clipboard.secretLife - 1) && c.text == Array("pw".utf8))
  #expect(c.expire(now: 1_000 + Clipboard.secretLife) && c.entry == nil && c.names.isEmpty)
  // An entry that isn't secret stays.
  c.commit(try clipEntry(["type=text/plain length=2\n", "ok"]), now: 0)
  #expect(!c.expire(now: Clipboard.secretLife * 10) && c.entry != nil)
}

@Test func onlyTheFocusedWindowReadsAfterInput() {
  let s = Scene(width: 800, height: 600)
  let (a, _) = s.open(title: "a", width: 200, height: 100)
  a.owner = "mail"
  let (b, _) = s.open(title: "b", width: 200, height: 100)
  b.owner = "notes"
  #expect(s.focused == b.id)
  // Focused, but given nothing yet: no.
  #expect(!s.mayRead(client: "notes"))
  // Input to a window without focus counts for nothing.
  s.gave(a.id)
  #expect(!s.mayRead(client: "mail") && !s.mayRead(client: "notes"))
  s.gave(b.id)
  #expect(s.mayRead(client: "notes") && !s.mayRead(client: "mail"))
  // Focus leaves: no more, and not again when it comes back without input.
  _ = s.top(a.id)
  #expect(!s.mayRead(client: "notes") && !s.mayRead(client: "mail"))
  _ = s.top(b.id)
  #expect(!s.mayRead(client: "notes"))
  s.gave(b.id)
  #expect(s.mayRead(client: "notes"))
}
