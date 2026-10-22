// SPDX-License-Identifier: BSD-3-Clause

// Notices (notices(4), D117), hosted: posts parsed and refused, slips
// shown at most three, going after their life unless they stay, waiting
// for room, a burst kept but not shown; the `clipboard` service's entries
// (Radharc's ClipFeed) parsed back whole across any split; clips kept
// within their limits; and the slips and drawer clicked.

import Foundation
import GlyphAtlas
import Kit
import Notices
import NoticesApp
import OpenType
import Radharc
import Testing
import TextLayout
import UICore

let second: Int64 = 1_000_000_000

@Test func postsAreParsedAndRefused() throws {
  let p = try NoticeBoard.parse("title=\"Build done\" body=\"amd64 in 156 s\" lamp=done\n")
  #expect(p.title == "Build done" && p.body == "amd64 in 156 s" && p.lamp == .done)
  #expect(try NoticeBoard.parse("title=Hi").lamp == .info)
  #expect(throws: NoticeRefusal.self) { try NoticeBoard.parse("body=nothing") }
  #expect(throws: NoticeRefusal.self) { try NoticeBoard.parse("title=x lamp=red") }
  #expect(throws: NoticeRefusal.self) { try NoticeBoard.parse("title=x colour=red") }
  #expect(throws: NoticeRefusal.self) { try NoticeBoard.parse("title=" + String(repeating: "a", count: 81)) }
}

@Test func slipsGoAfterTheirLifeUnlessTheyStay() throws {
  var b = NoticeBoard()
  try b.post("title=one", app: "a", now: 0)
  try b.post("title=two lamp=fail", app: "a", now: second)
  #expect(b.shown.map { $0.title } == ["two", "one"])
  #expect(b.nextExpiry == NoticeBoard.life)
  let early = b.expire(now: NoticeBoard.life - 1), due = b.expire(now: NoticeBoard.life)
  #expect(!early && due)
  #expect(b.shown.map { $0.title } == ["two"])
  #expect(b.nextExpiry == nil)
  let dismissed = b.dismiss(2, now: 10 * second)
  #expect(dismissed && b.shown.isEmpty && b.history.count == 2)
}

@Test func pastThreeTheOldestThatMayGoGoesElseTheNewWaits() throws {
  var b = NoticeBoard()
  try b.post("title=a lamp=warn", app: "x", now: 0)
  try b.post("title=b", app: "x", now: 0)
  try b.post("title=c lamp=warn", app: "x", now: 0)
  try b.post("title=d", app: "x", now: 0)
  #expect(b.shown.map { $0.title } == ["d", "c", "a"])
  try b.post("title=e lamp=fail", app: "x", now: 0)
  #expect(b.shown.map { $0.title } == ["e", "c", "a"])
  try b.post("title=f", app: "x", now: second)
  #expect(b.shown.map { $0.title } == ["e", "c", "a"] && b.waiting == [6])
  let dismissed = b.dismiss(1, now: 2 * second)
  #expect(dismissed && b.shown.map { $0.title } == ["f", "e", "c"] && b.waiting.isEmpty)
  // A waiting slip's life starts when it shows.
  #expect(b.nextExpiry == 2 * second + NoticeBoard.life)
}

@Test func aBurstIsKeptButNotShown() throws {
  var b = NoticeBoard()
  for i in 0..<12 { try b.post("title=n\(i)", app: "chatty", now: Int64(i) * 100_000_000) }
  try b.post("title=other", app: "quiet", now: 2 * second)
  #expect(b.history.count == 13)
  #expect(b.history.filter { !$0.shown }.map { $0.title } == ["n10", "n11"])
  #expect(b.shown.first?.title == "other")
  try b.post("title=later", app: "chatty", now: 20 * second)
  #expect(b.history.last?.shown == true)
}

@Test func theHistoryKeepsTheLastHundred() throws {
  var b = NoticeBoard()
  for i in 0..<120 { try b.post("title=n\(i)", app: "a\(i)", now: Int64(i) * second) }
  #expect(b.history.count == 100 && b.history.first?.title == "n20")
}

func entry(_ reps: [(String, String)], secret: Bool = false) throws -> ClipEntry {
  var out: [ClipRepresentation] = []
  for (t, b) in reps { out.append(try ClipRepresentation(type: t, bytes: Array(b.utf8))) }
  return ClipEntry(out, secret: secret)
}

@Test func theFeedIsParsedBackWholeAcrossAnySplit() throws {
  var feed = ClipFeed()
  feed.add(try entry([("text/plain;charset=utf-8", "hello\nworld"), ("text/html", "<b>hello</b>")]), seq: 1,
           source: "Terminal", origin: "rc \"build\"")
  feed.add(try entry([("text/plain", "secret")], secret: true), seq: 2, source: "Keys", origin: "")
  feed.add(try entry([("image/png", "")]), seq: 3, source: "Tracker", origin: "")
  #expect(feed.items.map { $0.seq } == [1, 3] && feed.fed == 2)
  #expect(feed.next(after: 1)?.seq == 3 && feed.next(after: 3) == nil)
  let stream = feed.items.flatMap { $0.bytes }
  for split in [1, 3, 7, 50, stream.count] {
    var p = ClipFeedParser()
    var got: [FedEntry] = []
    var i = 0
    while i < stream.count {
      got += p.feed(Array(stream[i..<min(stream.count, i + split)]))
      i += split
    }
    #expect(!p.broken)
    #expect(got.map { $0.source } == ["Terminal", "Tracker"])
    #expect(got.first?.origin == "rc 'build'")
    #expect(got.first?.types == ["text/plain;charset=utf-8", "text/html"])
    #expect(got.last?.types == ["image/png"])
    // A clip's file is the entry in clip/new's form: Radharc reads it back.
    if let first = got.first {
      var w = ClipWriter(snarf: false)
      try w.write(first.bytes)
      #expect(try w.finish().representations.map { $0.name } == ["text.plain", "text.html"])
      #expect(ClipFeedParser.text(first.bytes) == Array("hello\nworld".utf8))
      #expect(Clip.preview(text: ClipFeedParser.text(first.bytes), types: first.types) == "hello")
    }
  }
  var bad = ClipFeedParser()
  _ = bad.feed(Array("nonsense\n".utf8))
  #expect(bad.broken)
}

@Test func feedKeepsTheLastEight() throws {
  var feed = ClipFeed()
  for i in 1...10 { feed.add(try entry([("text/plain", "\(i)")]), seq: i, source: "a", origin: "") }
  #expect(feed.items.map { $0.seq } == Array(3...10))
  #expect(feed.next(after: 0)?.seq == 3)
}

@Test func clipsAreKeptWithinTheirLimits() {
  var s = ClipShelf()
  s.maxCount = 3
  s.maxMiB = 1
  let day: Int64 = 86_400
  func clip(_ n: Int, _ time: Int64, _ size: Int = 10) -> Clip {
    Clip(number: n, source: "a", origin: "", time: time, types: ["text/plain"], size: size, preview: "")
  }
  #expect(s.nextNumber == 1)
  for n in 1...3 {
    let gone = s.add(clip(n, 100 * day), now: 100 * day)
    #expect(gone.isEmpty)
  }
  let byCount = s.add(clip(4, 100 * day), now: 100 * day)
  let bySize = s.add(clip(5, 100 * day, (1 << 20) - 15), now: 100 * day)
  let byAge = s.prune(now: 131 * day)
  #expect(byCount == [1] && bySize == [2, 3] && byAge == [4, 5])
  s.load([clip(9, 0), clip(7, 0)])
  #expect(s.clips.map { $0.number } == [7, 9] && s.nextNumber == 10)
  let once = s.remove(7), twice = s.remove(7), all = s.removeAll()
  #expect(once && !twice && all == [9] && s.clips.isEmpty)
  #expect(Clip.preview(text: nil, types: ["image/png", "text/uri-list"]) == "image/png, text/uri-list")
  #expect(Clip.preview(text: Array(String(repeating: "x", count: 70).utf8), types: []).count == 60)
}

// MARK: The windows

@MainActor final class Host: NoticesHost {
  var dismissed: [Int] = [], pasted: [Int] = [], forgot: [Int] = []
  var cleared = 0
  func dismiss(_ id: Int) { dismissed.append(id) }
  func paste(_ number: Int) { pasted.append(number) }
  func forget(_ number: Int) { forgot.append(number) }
  func clear() { cleared += 1 }
}

let repository = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
  .deletingLastPathComponent().deletingLastPathComponent().path

@MainActor func painter() throws -> Painter {
  let theme = try Theme.resolve(ThemeStack(theme: "platinum-indigo", variant: nil)) { n in
    (try? Data(contentsOf: URL(filePath: "\(repository)/ui/theme/themes/\(n)"))).map { [UInt8]($0) }
  }
  var fonts = Fonts()
  let data = try #require(try? Data(contentsOf: URL(filePath: "\(repository)/data/fonts/ibm-plex-sans/IBMPlexSans-Regular.ttf")))
  fonts.add(try Font([UInt8](data)), role: .ui, weight: 400)
  fonts.add(try Font([UInt8](data)), role: .body, weight: 400)
  return Painter(theme: theme, fonts: fonts, scale: 1, cache: GlyphCache(coverageSize: 1024, fieldSize: 128))
}

@MainActor func press(_ r: Runner, _ label: String, value: String? = nil) async throws {
  let n = try #require(r.ui.access.first { $0.label == label && (value == nil || $0.value == value!) })
  let at = (n.x + n.width / 2, n.y + n.height / 2)
  r.frame(FrameInput(pointerX: at.0, pointerY: at.1))
  r.frame(FrameInput(pointerX: at.0, pointerY: at.1, down: true, pressed: true))
  r.frame(FrameInput(pointerX: at.0, pointerY: at.1, released: true))
  await r.settle()
  r.frame(FrameInput())
}

@MainActor @Test func aSlipClickedIsDismissedAndThePanelFitsTheSlips() async throws {
  var b = NoticeBoard()
  try b.post("title=one body=first", app: "a", now: 0)
  try b.post("title=two lamp=fail", app: "b", now: 0)
  let host = Host()
  let slips = Slips(host: host)
  slips.notices = b.shown
  let p = try painter()
  let r = Runner(app: slips, painter: p, width: Slips.width, height: 400)
  r.frame(FrameInput())
  #expect(slips.height(p) > 0)
  let one = slips.height(p)
  slips.notices = Array(b.shown.prefix(1))
  #expect(slips.height(p) < one)
  slips.notices = b.shown
  r.frame(FrameInput())
  try await press(r, "two")
  #expect(host.dismissed == [2])
  #expect(r.ui.access.contains { $0.label == "one" && $0.value == "info" })
  #expect(lampRole(.fail) == "alert" && p.theme.hasRole(lampRole(.fail)))
  for l in Lamp.allCases { #expect(p.theme.hasRole(lampRole(l))) }
}

@MainActor @Test func theDrawerPastesForgetsAndClears() async throws {
  let host = Host()
  let d = Drawer(host: host)
  d.clips = [Clip(number: 2, source: "Terminal", origin: "rc", time: 0, types: ["text/plain"], size: 5, preview: "hello"),
             Clip(number: 1, source: "Tracker", origin: "", time: 0, types: ["text/uri-list"], size: 9,
                  preview: "text/uri-list")]
  var b = NoticeBoard()
  try b.post("title=posted", app: "a", now: 0)
  d.notices = b.history
  let r = Runner(app: d, painter: try painter(), width: Theme.cqw(28), height: Theme.cqw(34))
  r.frame(FrameInput())
  #expect(r.ui.access.contains { $0.label == "posted" })
  try await press(r, "hello")
  #expect(host.pasted == [2])
  try await press(r, "Forget", value: "1")
  #expect(host.forgot == [1] && host.pasted == [2])
  try await press(r, "Forget all")
  #expect(host.cleared == 1)
}
