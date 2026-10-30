// SPDX-License-Identifier: BSD-3-Clause

// Tracker's windows (tracker(4)), hosted, over the fs service on a RAM
// disk in memory, driven as a person would: a large folder shows at once
// and fills in; clicks select (Shift a range, Control one more), a
// double-click opens; the keyboard moves, opens, trashes, renames in
// place and finds by typing; a header sorts and the folder keeps it; the
// icon view puts entries in a grid and keeps where one is dragged; the
// watch's changes come in; the window's frame is kept; a right-click's
// menu routes first; and the chooser view (D111) filters by type, walks
// folders, and returns a confined file channel.

import Foundation
import Fs
import FsServer
import Glibc
import GlyphAtlas
import IPC
import Kit
import Node
import OpenType
import Sd
import Synchronization
import Sys
import struct Taisce.FileSystem
import Testing
import TextLayout
import Tracker
import TrackerApp
import UICore

final class Running: @unchecked Sendable {
  let dispatcher: IPCDispatcher
  let thread: Foundation.Thread
  init(_ dispatcher: IPCDispatcher) {
    self.dispatcher = dispatcher
    thread = Foundation.Thread { try? dispatcher.run() }
    thread.start()
  }
  func stop() { dispatcher.stop() }
}

final class Rig: @unchecked Sendable {
  let disk: Running, unit: SdUnit, fsThread: Running, service: FsService
  init() throws {
    let diskDispatcher = try IPCDispatcher()
    let memory = try MemoryDisk(name: "ramdisk0", try VMO.create(size: 16384 * 4096), sectors: 16384, sectorSize: 4096)
    unit = SdUnit(memory, dispatcher: diskDispatcher)
    disk = Running(diskDispatcher)
    var dir = NodeIPC.NodeClient(channel: try unit.channel())
    let data = try dir.open("data").takeChannel()
    var ctlDir = NodeIPC.NodeClient(channel: try unit.channel())
    let ctl = try ctlDir.open("ctl").takeChannel()
    let device = VolumeDevice(try NodeDevice(data, ctl: ctl))
    let fs = try FileSystem.format(device, label: Array("test".utf8), uuid: [UInt8](repeating: 7, count: 16),
                                   now: FsService.now)
    let fsDispatcher = try IPCDispatcher()
    service = try FsService(fs, device: "/dev/sdZ0/data", dispatcher: fsDispatcher)
    fsThread = Running(fsDispatcher)
  }
  func volume() throws -> Tracker.Volume {
    Tracker.Volume(root: FsIPC.DirectoryClient(channel: try service.root()))
  }
  func file(_ path: String, _ bytes: [UInt8] = []) throws {
    let (folder, name) = Path.split(path)
    var dir = FsIPC.DirectoryClient(channel: try service.root())
    if !folder.isEmpty { dir = try dir.directory(folder) }
    var f = try dir.makeFile(name)
    if !bytes.isEmpty { try f.write(bytes) }
  }
  func stop() {
    fsThread.stop()
    disk.stop()
  }
}

@MainActor final class Host: TrackerHost {
  var opened: [String] = []
  var closed = 0
  func open(folder path: String) { opened.append(path) }
  func close(_ window: any App) { closed += 1 }
  var queries: [String] = []
  var runs: [String] = []
  func open(query path: String) { queries.append(path) }
  func run(_ query: QueryWindow) { runs.append(query.text) }
  func quit() {}
  var routes: [(path: String, type: String)] = []
  func route(_ path: String, type: String) -> String? {
    routes.append((path, type))
    return nil
  }
  var addOnList: [AddOn] = []
  var ran: [(service: String, paths: [String])] = []
  func addOns() -> [AddOn] { addOnList }
  func run(addOn service: String, paths: [String]) -> String? {
    ran.append((service, paths))
    return nil
  }
}

let repository = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
  .deletingLastPathComponent().deletingLastPathComponent().path

func shipped(_ name: String) throws -> Theme {
  try Theme.resolve(ThemeStack(theme: name, variant: nil)) { n in
    (try? Data(contentsOf: URL(filePath: "\(repository)/ui/theme/themes/\(n)"))).map { [UInt8]($0) }
  }
}

func storyboardFonts() throws -> Fonts {
  var fonts = Fonts()
  for (path, role, weight) in [("barlow-condensed/BarlowCondensed-Medium.ttf", FontRole.ui, 500),
                               ("barlow-condensed/BarlowCondensed-SemiBold.ttf", .ui, 600),
                               ("ibm-plex-sans/IBMPlexSans-Regular.ttf", .body, 400),
                               ("ibm-plex-sans/IBMPlexSans-Medium.ttf", .body, 500),
                               ("ibm-plex-mono/IBMPlexMono-Regular.ttf", .mono, 400),
                               ("chakra-petch/ChakraPetch-Medium.ttf", .display, 500)] {
    let data = try #require(try? Data(contentsOf: URL(filePath: "\(repository)/data/fonts/\(path)")))
    fonts.add(try Font([UInt8](data)), role: role, weight: weight)
  }
  return fonts
}

/// A window on `path`, and a runner for it.
@MainActor func window(_ v: Tracker.Volume, _ path: String, host: Host, width: Float = 640, height: Float = 360,
                       scale: Float = 1) throws -> (FolderWindow, Runner)
{
  let w = try FolderWindow(path: path, volume: v, host: host)
  let theme = try shipped("neon-tab")
  let painter = Painter(theme: theme, fonts: try storyboardFonts(), scale: scale,
                        cache: GlyphCache(coverageSize: 1024, fieldSize: 128))
  return (w, Runner(app: w, painter: painter, width: width, height: height))
}

/// A frame of keys or text, and the handlers it started run.
@MainActor func type(_ r: Runner, _ input: FrameInput) async {
  r.frame(input)
  await r.settle()
  r.frame(FrameInput())
}

/// Frames until the window has nothing left to do.
@MainActor func settle(_ r: Runner, _ w: FolderWindow) {
  for _ in 0..<200 where w.busy || r.wantsFrame { r.frame(FrameInput()) }
}

/// The middle of the row showing `name`, from the frame's tree.
@MainActor func row(_ r: Runner, _ name: String) -> (x: Float, y: Float)? {
  guard let cell = r.ui.access.first(where: { ($0.role == .cell || $0.role == .row) && $0.label == name }) else {
    return nil
  }
  return (cell.x + cell.width / 2, cell.y + cell.height / 2)
}

@MainActor var clock: Int64 = 1_000_000_000
/// A click (press, then release) at `at`, `ms` after the last.
@MainActor func click(_ r: Runner, _ at: (x: Float, y: Float), shift: Bool = false, control: Bool = false,
                      ms: Int64 = 1000)
{
  clock += ms * 1_000_000
  var down = FrameInput(pointerX: at.x, pointerY: at.y, down: true, pressed: true)
  (down.shift, down.control, down.time) = (shift, control, clock)
  r.frame(FrameInput(pointerX: at.x, pointerY: at.y))
  r.frame(down)
  var up = FrameInput(pointerX: at.x, pointerY: at.y, released: true)
  (up.shift, up.control, up.time) = (shift, control, clock + 50_000_000)
  r.frame(up)
}

@MainActor @Test func aLargeFolderShowsAtOnceAndFillsIn() async throws {
  let rig = try Rig()
  defer { rig.stop() }
  let v = try rig.volume()
  _ = try v.makeFolder(in: "", named: "big")
  for i in 0..<1500 { try rig.file("big/f\(i).txt") }
  let host = Host()
  let (w, r) = try window(v, "big", host: host)
  r.frame(FrameInput())
  #expect(w.folder.entries.count > 0 && w.folder.entries.count < 1500 && !w.loaded && w.busy)
  #expect(r.ui.access.contains { $0.label.hasSuffix("entries…") })
  settle(r, w)
  #expect(w.loaded && w.folder.entries.count == 1500 && !w.busy)
  #expect(r.ui.access.contains { $0.label == "1500 entries" })
}

@MainActor @Test func clicksSelectAndADoubleClickOpens() async throws {
  let rig = try Rig()
  defer { rig.stop() }
  let v = try rig.volume()
  _ = try v.makeFolder(in: "", named: "home")
  _ = try v.makeFolder(in: "home", named: "Music")
  for n in ["a.txt", "b.txt", "c.txt"] { try rig.file("home/" + n, Array("words".utf8)) }
  let host = Host()
  let (w, r) = try window(v, "home", host: host)
  settle(r, w)
  func node(_ n: String) -> UInt64 { w.folder.entry(named: n)!.node }
  click(r, try #require(row(r, "a.txt")))
  #expect(w.folder.selection == [node("a.txt")])
  click(r, try #require(row(r, "c.txt")), shift: true)
  #expect(w.folder.selection == [node("a.txt"), node("b.txt"), node("c.txt")])
  click(r, try #require(row(r, "b.txt")), control: true)
  #expect(w.folder.selection == [node("a.txt"), node("c.txt")])
  #expect(r.ui.access.contains { $0.label == "2 of 4 entries selected" })
  // A double-click on a folder opens its window; on a file, routes it by
  // its type.
  let music = try #require(row(r, "Music"))
  click(r, music)
  click(r, music, ms: 200)
  #expect(host.opened == ["home/Music"])
  let a = try #require(row(r, "a.txt"))
  click(r, a)
  click(r, a, ms: 200)
  settle(r, w)
  #expect(host.routes.map(\.path) == ["home/a.txt"] && host.routes.map(\.type) == ["text/plain"])
  #expect(w.message == nil)
  // Too slow is two clicks.
  click(r, music, ms: 800)
  click(r, music, ms: 800)
  #expect(host.opened == ["home/Music"])
}

@MainActor @Test func theKeyboardMovesOpensTrashesRenamesAndFinds() async throws {
  let rig = try Rig()
  defer { rig.stop() }
  let v = try rig.volume()
  _ = try v.makeFolder(in: "", named: "home")
  for n in ["alpha.md", "beta.md", "gamma.md", "notes.md"] { try rig.file("home/" + n) }
  let host = Host()
  let (w, r) = try window(v, "home", host: host)
  settle(r, w)
  await type(r, FrameInput(keys: [KeyPress(.down)]))
  #expect(w.folder.selected().map(\.name) == ["alpha.md"])
  await type(r, FrameInput(keys: [KeyPress(.down), KeyPress(.down, shift: true)]))
  #expect(w.folder.selected().map(\.name) == ["beta.md", "gamma.md"])
  // Delete: to the Trash.
  await type(r, FrameInput(keys: [KeyPress(.delete)]))
  #expect(w.folder.entries.map(\.name).sorted() == ["alpha.md", "notes.md"])
  #expect(try v.entries("Trash").map(\.name).sorted() == ["beta.md", "gamma.md"])
  // Typing finds; F2 renames in place, Enter keeps it.
  await type(r, FrameInput(text: "no"))
  #expect(w.folder.selected().map(\.name) == ["notes.md"])
  await type(r, FrameInput(keys: [KeyPress(.function(2))]))
  r.frame(FrameInput())
  #expect(w.renaming != nil && w.renameText == "notes.md")
  await type(r, FrameInput(keys: [KeyPress(.home)]))
  await type(r, FrameInput(text: "my-"))
  await type(r, FrameInput(keys: [KeyPress(.enter)]))
  #expect(w.renaming == nil && w.folder.entry(named: "my-notes.md") != nil)
  #expect(try v.entries("home").map(\.name).sorted() == ["alpha.md", "my-notes.md"])
  // Escape leaves a rename as it was; Enter opens; Control-Up the parent.
  await type(r, FrameInput(keys: [KeyPress(.function(2))]))
  await type(r, FrameInput(text: "zzz"))
  await type(r, FrameInput(keys: [KeyPress(.escape)]))
  #expect(w.renaming == nil && w.folder.entry(named: "my-notes.md") != nil)
  await type(r, FrameInput(keys: [KeyPress(.up, control: true)]))
  #expect(host.opened == [""])
}

@MainActor @Test func aHeaderSortsAndTheFolderKeepsIt() async throws {
  let rig = try Rig()
  defer { rig.stop() }
  let v = try rig.volume()
  _ = try v.makeFolder(in: "", named: "home")
  for (n, size) in [("small", 10), ("large", 5000), ("medium", 300)] {
    try rig.file("home/" + n, [UInt8](repeating: 0x61, count: size))
  }
  let host = Host()
  let (w, r) = try window(v, "home", host: host)
  settle(r, w)
  let size = try #require(r.ui.access.first { $0.role == .columnHeader && $0.label == "Size" })
  click(r, (size.x + 4, size.y + size.height / 2))
  #expect(w.folder.ordered().map(\.name) == ["small", "medium", "large"])
  click(r, (size.x + 4, size.y + size.height / 2))
  #expect(w.folder.ordered().map(\.name) == ["large", "medium", "small"])
  #expect(try v.state("home").sort == SortOrder(Column.size, descending: true))
  // Its header shows it.
  r.frame(FrameInput())
  #expect(r.ui.access.contains { $0.role == .columnHeader && $0.label == "Size" })
  // A new window on it sorts the same.
  let (again, ar) = try window(v, "home", host: host)
  settle(ar, again)
  #expect(again.folder.ordered().map(\.name) == ["large", "medium", "small"])
}

@MainActor @Test func theIconViewPlacesAndKeepsAnIconDragged() async throws {
  let rig = try Rig()
  defer { rig.stop() }
  let v = try rig.volume()
  _ = try v.makeFolder(in: "", named: "home")
  for n in ["a", "b", "c"] { try rig.file("home/" + n + ".txt") }
  let host = Host()
  let (w, r) = try window(v, "home", host: host)
  settle(r, w)
  await type(r, FrameInput(keys: [KeyPress(.character(0x32), control: true)]))
  r.frame(FrameInput())
  #expect(w.state.view == .icons)
  #expect(try v.state("home").view == .icons)
  let b = try #require(r.ui.access.first { $0.role == .row && $0.label == "b.txt" })
  let from = (x: b.x + b.width / 2, y: b.y + 20)
  // Pressed, dragged 100 right and 60 down, let go.
  r.frame(FrameInput(pointerX: from.x, pointerY: from.y))
  r.frame(FrameInput(pointerX: from.x, pointerY: from.y, down: true, pressed: true))
  r.frame(FrameInput(pointerX: from.x + 100, pointerY: from.y + 60, down: true))
  r.frame(FrameInput(pointerX: from.x + 100, pointerY: from.y + 60, released: true))
  let placed = try #require(w.folder.entry(named: "b.txt")?.place)
  let grid = IconGrid.places(w.folder.ordered(), width: 640)
  let i = w.folder.ordered().firstIndex { $0.name == "b.txt" }!
  #expect(placed.x == grid[i].x && placed.y == grid[i].y)
  #expect(try v.entries("home").first { $0.name == "b.txt" }?.place != nil)
  // The others keep the grid's places; b leaves its own free.
  #expect(IconGrid.places(w.folder.ordered(), width: 640)[0].x == Theme.cqw(1))
}

@MainActor @Test func theWatchsChangesComeInAndFilesGetTypes() async throws {
  let rig = try Rig()
  defer { rig.stop() }
  let v = try rig.volume()
  _ = try v.makeFolder(in: "", named: "home")
  let host = Host()
  let (w, r) = try window(v, "home", host: host)
  settle(r, w)
  var watch = try v.watch("home")
  try rig.file("home/arrived.md", Array("# hi".utf8))
  var seen: [NodeIPC.Change] = []
  for _ in 0..<50 where seen.isEmpty { seen += watch.changes(deadline: Clock.monotonic() + 100_000_000) }
  w.deliver(seen)
  r.frame(FrameInput())
  settle(r, w)
  #expect(w.folder.entry(named: "arrived.md")?.type == "text/markdown")
  #expect(r.ui.access.contains { $0.label == "text/markdown" })
}

@MainActor @Test func theWindowsFrameIsKept() async throws {
  let rig = try Rig()
  defer { rig.stop() }
  let v = try rig.volume()
  _ = try v.makeFolder(in: "", named: "home")
  let host = Host()
  let (w, r) = try window(v, "home", host: host, width: 500, height: 300)
  settle(r, w)
  w.moved(x: 220, y: 140)
  #expect(try v.attribute("home", FolderState.frameAttribute) == .string("220 140 500 300"))
  r.ui.width = 640
  r.frame(FrameInput())
  #expect(try v.state("home").frame.map { [$0.x, $0.y, $0.width, $0.height] } == [220, 140, 640, 300])
  await type(r, FrameInput(keys: [KeyPress(.character(0x77), control: true)]))
  #expect(host.closed == 1)
}

@MainActor @Test func aRightClicksMenuRoutesFirst() async throws {
  let rig = try Rig()
  defer { rig.stop() }
  let v = try rig.volume()
  _ = try v.makeFolder(in: "", named: "home")
  try rig.file("home/notes.md")
  let host = Host()
  let (w, r) = try window(v, "home", host: host)
  settle(r, w)
  let at = try #require(row(r, "notes.md"))
  r.frame(FrameInput(pointerX: at.x, pointerY: at.y))
  r.frame(FrameInput(pointerX: at.x, pointerY: at.y, secondaryPressed: true))
  r.frame(FrameInput(pointerX: at.x, pointerY: at.y))
  let items = r.ui.access.filter { $0.role == .menuItem }.map(\.label)
  #expect(items == ["Route", "Open", "Rename", "Copy", "Cut", "Move to Trash", "Add-ons"])
  #expect(w.folder.selected().map(\.name) == ["notes.md"])
  // Route sends the file with its type (Tracker's own handler, not the
  // platform's text).
  let route = try #require(r.ui.access.first { $0.role == .menuItem && $0.label == "Route" })
  click(r, (route.x + route.width / 2, route.y + route.height / 2))
  await r.settle()
  let type = try #require(w.folder.entry(named: "notes.md")?.type)
  #expect(host.routes.map(\.path) == ["home/notes.md"] && host.routes.map(\.type) == [type])
}

@MainActor func feed(_ w: QueryWindow, _ live: inout Tracker.Volume.LiveQuery, _ r: Runner) {
  for _ in 0..<40 {
    let c = live.changes(deadline: Clock.monotonic() + 50_000_000)
    if c.isEmpty && w.results.current { break }
    w.deliver(c, generation: w.generation)
    r.frame(FrameInput())
  }
  settle(r, w)
}

@MainActor func settle(_ r: Runner, _ w: QueryWindow) {
  for _ in 0..<50 where r.wantsFrame { r.frame(FrameInput()) }
}

@MainActor @Test func aQueryWindowStaysLiveAndRunsItsBar() async throws {
  let rig = try Rig()
  defer { rig.stop() }
  let v = try rig.volume()
  _ = try v.makeFolder(in: "", named: "music")
  for (n, year) in [("Glory Box.flac", 1994), ("Overcome.flac", 1995), ("Old.flac", 1970)] {
    try rig.file("music/" + n)
    try v.setAttribute("music/" + n, "Audio:Year", .int(Int64(year)))
  }
  let q = try v.makeQuery(in: "", named: "Trip-hop, 90s", text: "Audio:Year in 1990..<2000")
  let host = Host()
  var t: Int64 = 0
  let w = try QueryWindow(path: q, volume: v, host: host) { t += 600_000; return t }
  let theme = try shipped("neon-tab")
  let painter = Painter(theme: theme, fonts: try storyboardFonts(), cache: GlyphCache(coverageSize: 1024, fieldSize: 128))
  let r = Runner(app: w, painter: painter, width: 700, height: 360)
  #expect(w.title == "Trip-hop, 90s · query")
  var live = try v.live(w.text)
  feed(w, &live, r)
  #expect(w.results.folder.entries.count == 2)
  #expect(r.ui.access.contains { $0.label == "2 matches · 0.6 ms" })
  #expect(r.ui.access.contains { $0.role == .columnHeader && $0.label == "Audio:Year" })
  // A file comes to match: its row is new, the status says so.
  try rig.file("music/Teardrop.flac")
  try v.setAttribute("music/Teardrop.flac", "Audio:Year", .int(1998))
  feed(w, &live, r)
  let tear = try #require(w.results.folder.entry(named: "Teardrop.flac"))
  #expect(w.results.arrived == [tear.node])
  #expect(r.ui.access.contains { $0.label.hasPrefix("live · added \"Teardrop.flac\" at journal seq ") })
  // Old changes are dropped once the bar runs new text, which the file keeps.
  let before = w.generation
  w.text = "Audio:Year < 1980"
  w.run()
  #expect(w.generation == before + 1 && host.runs == ["Audio:Year < 1980"] && w.results.folder.entries.isEmpty)
  #expect(try v.queryText(q) == "Audio:Year < 1980")
  w.deliver([FsIPC.QueryChange(kind: .added, node: tear.node, path: "/music/Teardrop.flac", seq: 1)], generation: before)
  r.frame(FrameInput())
  #expect(w.results.folder.entries.isEmpty)
  var again = try v.live(w.text)
  feed(w, &again, r)
  #expect(w.results.folder.ordered().map(\.name) == ["Old.flac"])
}

@MainActor @Test func aQueryFileOpensItsWindow() async throws {
  let rig = try Rig()
  defer { rig.stop() }
  let v = try rig.volume()
  _ = try v.makeQuery(in: "", named: "New mail", text: #"MAIL:status == "New""#)
  let host = Host()
  let (w, r) = try window(v, "", host: host)
  settle(r, w)
  #expect(w.folder.entry(named: "New mail")?.type == FileTypes.query)
  let at = try #require(row(r, "New mail"))
  click(r, at)
  click(r, at, ms: 200)
  #expect(host.queries == ["New mail"])
  // New query: a file here, opened.
  await type(r, FrameInput(keys: [KeyPress(.character(0x6E), shift: true, control: true)]))
  #expect(host.queries == ["New mail", "New query"])
  #expect(try v.queryText("New query") == #"name == "*""#)
}

@MainActor @Test func feedsDeliverAndRunAnew() async throws {
  let rig = try Rig()
  defer { rig.stop() }
  let v = try rig.volume()
  _ = try v.makeFolder(in: "", named: "home")
  let host = Host()
  let (w, r) = try window(v, "home", host: host)
  settle(r, w)
  let wakes = Atomic<Int>(0)
  let folderFeed = try Feed.folder("home", volume: try rig.volume(), window: w) { wakes.add(1, ordering: .relaxed) }
  try rig.file("home/arrived.md", Array("# hi".utf8))
  for _ in 0..<300 where w.folder.entry(named: "arrived.md") == nil {
    usleep(10_000)
    r.frame(FrameInput())
  }
  settle(r, w)
  #expect(w.folder.entry(named: "arrived.md")?.type == "text/markdown" && wakes.load(ordering: .relaxed) > 0)
  folderFeed.stop()

  try v.setAttribute("home/arrived.md", "Audio:Year", .int(1994))
  let q = try v.makeQuery(in: "", named: "90s", text: "Audio:Year in 1990..<2000")
  var t: Int64 = 0
  let qw = try QueryWindow(path: q, volume: v, host: host) { t += 1; return t }
  let qr = Runner(app: qw, painter: r.ui.painter, width: 600, height: 300)
  let queryFeed = try Feed.query(volume: try rig.volume(), window: qw) {}
  queryFeed.run(qw.text, generation: qw.generation)
  for _ in 0..<100 where !qw.results.current {
    usleep(10_000)
    qr.frame(FrameInput())
  }
  #expect(qw.results.folder.ordered().map(\.name) == ["arrived.md"])
  // A text that doesn't parse says so; a good one runs anew.
  qw.text = "Audio:Year >"
  qw.run()
  queryFeed.run(qw.text, generation: qw.generation)
  for _ in 0..<100 where qw.message == nil {
    usleep(10_000)
    qr.frame(FrameInput())
  }
  #expect(qw.message == "The query doesn't parse")
  qw.text = "Audio:Year < 1990"
  qw.run()
  queryFeed.run(qw.text, generation: qw.generation)
  try rig.file("old.md")
  try v.setAttribute("old.md", "Audio:Year", .int(1970))
  for _ in 0..<100 where qw.results.folder.entries.isEmpty {
    usleep(10_000)
    qr.frame(FrameInput())
  }
  #expect(qw.results.folder.ordered().map(\.name) == ["old.md"])
  queryFeed.stop()
}

@MainActor @Test func theGroundsMenuWalksMakesFromTemplatesAndCleansUp() async throws {
  let rig = try Rig()
  defer { rig.stop() }
  let v = try rig.volume()
  _ = try v.makeFolder(in: "", named: "home")
  _ = try v.makeFolder(in: "home", named: "docs")
  _ = try v.makeFolder(in: "", named: FolderWindow.templates)
  try rig.file("home/a.txt")
  try rig.file(FolderWindow.templates + "/Letter.md", Array("Dear ".utf8))
  try v.setAttribute(FolderWindow.templates + "/Letter.md", "Mail:Draft", .bool(true))
  let host = Host()
  let (w, r) = try window(v, "home", host: host)
  settle(r, w)
  await type(r, FrameInput(keys: [KeyPress(.character(0x32), control: true)]))
  #expect(w.state.view == .icons)
  func ground() {
    r.frame(FrameInput(pointerX: 600, pointerY: 300))
    r.frame(FrameInput(pointerX: 600, pointerY: 300, secondaryPressed: true))
    r.frame(FrameInput(pointerX: 600, pointerY: 300))
  }
  func item(_ label: String) -> (x: Float, y: Float)? {
    r.ui.access.last { $0.role == .menuItem && $0.label == label }.map { ($0.x + 8, $0.y + $0.height / 2) }
  }
  func rest(_ label: String) throws {
    let at = try #require(item(label))
    r.frame(FrameInput(pointerX: at.x, pointerY: at.y))
    r.frame(FrameInput(pointerX: at.x, pointerY: at.y))
  }
  ground()
  #expect(r.ui.access.filter { $0.role == .menuItem }.map(\.label)
            == ["Route", "Desktop", "New", "Paste", "As icons", "As mini icons", "As list", "Clean up", "Select…",
                "Select all", "Add-ons"])
  // Desktop ▸ home ▸ docs, chosen.
  try rest("Desktop")
  #expect(item(FolderWindow.templates) != nil && item("home") != nil)
  try rest("home")
  #expect(item("docs") != nil && item("a.txt") != nil)
  click(r, try #require(item("docs")))
  await r.settle()
  #expect(host.opened == ["home/docs"])
  // New ▸ Letter.md: a copy here, its attributes with it, being renamed.
  r.frame(FrameInput())
  ground()
  try rest("New")
  #expect(item("New folder") != nil && item("New query") != nil)
  click(r, try #require(item("Letter.md")))
  await r.settle()
  let made = try #require(w.folder.entry(named: "Letter.md"))
  #expect(w.renaming == made.node)
  #expect(try v.attribute("home/Letter.md", "Mail:Draft") == .bool(true))
  w.finishRename(keep: false)
  // Clean up: a kept place forgotten.
  try v.place("home/a.txt", x: 400, y: 200)
  if let e = try? v.stat("home/a.txt") { w.folder.update(e) }
  #expect(w.folder.entry(named: "a.txt")?.place != nil)
  w.cleanUp()
  let after = try v.stat("home/a.txt")
  #expect(w.folder.entry(named: "a.txt")?.place == nil && after.place == nil)
  // Mini icons: each a row of the field, in a grid across.
  await type(r, FrameInput(keys: [KeyPress(.character(0x33), control: true)]))
  r.frame(FrameInput())
  #expect(w.state.view == .mini && r.ui.access.contains { $0.role == .row && $0.label == "a.txt" })
}

@MainActor @Test func filesCopyCutPasteSelectAndAddOns() async throws {
  let rig = try Rig()
  defer { rig.stop() }
  let v = try rig.volume()
  _ = try v.makeFolder(in: "", named: "a")
  _ = try v.makeFolder(in: "", named: "b")
  try rig.file("a/one.md", Array("1".utf8))
  try rig.file("a/two.md", Array("2".utf8))
  try rig.file("a/three.txt")
  try rig.file("b/one.md")
  FileClipboard.shared.paths = []
  let host = Host()
  host.addOnList = [AddOn(service: "term", label: "Open Terminal here")]
  let (wa, ra) = try window(v, "a", host: host)
  let (wb, rb) = try window(v, "b", host: host)
  settle(ra, wa)
  settle(rb, wb)
  // Select… *.md, by its field.
  await type(ra, FrameInput(keys: [KeyPress(.character(0x61), shift: true, control: true)]))
  #expect(wa.selecting == "")
  await type(ra, FrameInput(text: "*.md"))
  await type(ra, FrameInput(keys: [KeyPress(.enter)]))
  #expect(wa.selecting == nil && Set(wa.folder.selected().map(\.name)) == ["one.md", "two.md"])
  // Copied, pasted in b: one.md is taken there, so "one 2.md".
  await type(ra, FrameInput(keys: [KeyPress(.character(0x63), control: true)]))
  await type(rb, FrameInput(keys: [KeyPress(.character(0x76), control: true)]))
  #expect(Set(try v.entries("b").map(\.name)) == ["one.md", "one 2.md", "two.md"])
  #expect(Set(wb.folder.selected().map(\.name)) == ["one 2.md", "two.md"])
  #expect(try v.entries("a").count == 3)  // copies: a keeps its own
  // Cut three.txt, pasted in b: moved, and the clipboard empties.
  wa.folder.clearSelection()
  wa.folder.select(try #require(wa.folder.entry(named: "three.txt")).node)
  await type(ra, FrameInput(keys: [KeyPress(.character(0x78), control: true)]))
  await type(rb, FrameInput(keys: [KeyPress(.character(0x76), control: true)]))
  #expect(try v.entries("b").contains { $0.name == "three.txt" } && !(try v.entries("a").contains { $0.name == "three.txt" }))
  #expect(FileClipboard.shared.paths.isEmpty)
  // Add-ons: the selection's paths, or the folder's.
  wb.runAddOn("term")
  wb.folder.clearSelection()
  wb.runAddOn("term")
  #expect(host.ran.map(\.service) == ["term", "term"])
  #expect(host.ran[0].paths == ["b/three.txt"] && host.ran[1].paths == ["b"])
  #expect(wb.addOnMenu().map { $0.label } == ["Open Terminal here"])
  host.addOnList = []
  #expect(wb.addOnMenu().map { $0.dimmed } == [true])
}

@MainActor @Test func theDesktopShowsItsVolume() async throws {
  let rig = try Rig()
  defer { rig.stop() }
  let v = try rig.volume()
  _ = try v.makeFolder(in: "", named: "home")
  let host = Host()
  let w = try FolderWindow(path: "", volume: v, host: host, desktop: true)
  w.volumes = [VolumeInfo(name: "main", bytes: 1 << 26, free: 1 << 25, boot: true)]
  let theme = try shipped("neon-tab")
  let painter = Painter(theme: theme, fonts: try storyboardFonts(), cache: GlyphCache(coverageSize: 1024, fieldSize: 128))
  let r = Runner(app: w, painter: painter, width: 800, height: 500)
  settle(r, w)
  let rows = r.ui.access.filter { $0.role == .row }.map(\.label)
  #expect(rows.first == "main" && rows.contains("home"))
  let main = try #require(r.ui.access.first { $0.role == .row && $0.label == "main" })
  let at = (x: main.x + main.width / 2, y: main.y + 20)
  click(r, at)
  click(r, at, ms: 100)
  #expect(host.opened == [""])
  // Its menu.
  r.frame(FrameInput(pointerX: at.x, pointerY: at.y))
  r.frame(FrameInput(pointerX: at.x, pointerY: at.y, secondaryPressed: true))
  r.frame(FrameInput(pointerX: at.x, pointerY: at.y))
  #expect(r.ui.access.filter { $0.role == .menuItem }.map(\.label) == ["Route", "Open", "Unmount"])
  #expect(r.ui.access.contains { $0.label == "Unmount" && $0.action < 0 })
  r.frame(FrameInput(keys: [KeyPress(.escape)]))
  r.frame(FrameInput())
  #expect(!r.ui.access.contains { $0.role == .menuItem && $0.label == "Unmount" })  // Escape closed it
  // The ground's Mount menu.
  r.frame(FrameInput(pointerX: 600, pointerY: 400))
  r.frame(FrameInput(pointerX: 600, pointerY: 400, secondaryPressed: true))
  r.frame(FrameInput(pointerX: 600, pointerY: 400))
  let mount = try #require(r.ui.access.last { $0.role == .menuItem && $0.label == "Mount" })
  r.frame(FrameInput(pointerX: mount.x + 8, pointerY: mount.y + 4))
  r.frame(FrameInput(pointerX: mount.x + 8, pointerY: mount.y + 4))
  #expect(r.ui.access.contains { $0.label == "main (mounted)" } && r.ui.access.contains { $0.label == "No other volumes" })
  // Escape closes the ground's menu too.
  r.frame(FrameInput(pointerX: 600, pointerY: 400, keys: [KeyPress(.escape)]))
  r.frame(FrameInput(pointerX: 600, pointerY: 400))
  #expect(!r.ui.access.contains { $0.role == .menuItem && $0.label == "Mount" })
}

/// The desk's grid only in a theme that has one: Neon Tab's lines, and
/// none in Platinum Indigo (not one at every pixel in the desk's colour).
@MainActor @Test func theDeskDrawsAGridOnlyWhereTheThemeHasOne() async throws {
  let rig = try Rig()
  defer { rig.stop() }
  let v = try rig.volume()
  let w = try FolderWindow(path: "", volume: v, host: Host(), desktop: true)
  func lines(_ theme: String) throws -> Int {
    let painter = Painter(theme: try shipped(theme), fonts: try storyboardFonts(),
                          cache: GlyphCache(coverageSize: 1024, fieldSize: 128))
    let r = Runner(app: w, painter: painter, width: 1280, height: 720)
    settle(r, w)
    return r.ui.painter.list.quads.filter { ($0.width == 1 && $0.height == 720) || ($0.width == 1280 && $0.height == 1) }
      .count
  }
  #expect(try lines("platinum-indigo") == 0)
  let neon = try lines("neon-tab")
  #expect(neon > 0 && neon < 200)
}

/// The chooser view (D111): lists folders and matching files, walks into a
/// folder on confirm or double-click, and returns a confined file channel
/// when a file is chosen or saved.
@MainActor @Test func theChooserViewFiltersWalksAndChooses() async throws {
  let rig = try Rig()
  defer { rig.stop() }
  let v = try rig.volume()
  _ = try v.makeFolder(in: "", named: "home")
  _ = try v.makeFolder(in: "home", named: "docs")
  try rig.file("home/docs/notes.md", Array("# hello".utf8))
  try rig.file("home/docs/blob.bin", [0, 1, 2, 0xFF])
  let theme = try shipped("neon-tab")
  let painter = Painter(theme: theme, fonts: try storyboardFonts(), cache: GlyphCache(coverageSize: 1024, fieldSize: 128))

  // Open mode with a text/* filter: folders show, matching files show, non-matching files are filtered out.
  let openChooser = try ChooserView(path: "home", volume: v, save: false, types: ["text/*"])
  let or = Runner(app: openChooser, painter: painter, width: 488, height: 220)
  for _ in 0..<50 where openChooser.busy || or.wantsFrame { or.frame(FrameInput()) }
  #expect(openChooser.visibleEntries().map(\.name) == ["docs"])
  openChooser.select(openChooser.visibleEntries()[0])
  // Confirming a folder enters it instead of finishing.
  if (try openChooser.confirm()) != nil { Issue.record("expected folder navigation") }
  #expect(openChooser.path == "home/docs")
  for _ in 0..<50 where openChooser.busy || or.wantsFrame { or.frame(FrameInput()) }
  #expect(openChooser.visibleEntries().map(\.name) == ["notes.md"])
  openChooser.select(openChooser.visibleEntries()[0])
  guard let chosen = try openChooser.confirm() else {
    Issue.record("no chosen file")
    return
  }
  var file = FsIPC.FileClient(channel: chosen.takeHandle())
  #expect(try file.readAll() == Array("# hello".utf8))
  var wrote = false
  do {
    try file.write([0x21])
    wrote = true
  } catch {}
  #expect(!wrote)

  // Save mode with a suggested name creates and returns a writable confined channel.
  let saveChooser = try ChooserView(path: "home/docs", volume: v, save: true, types: [], name: "draft.md")
  let sr = Runner(app: saveChooser, painter: painter, width: 488, height: 220)
  for _ in 0..<50 where saveChooser.busy || sr.wantsFrame { sr.frame(FrameInput()) }
  guard let saved = try saveChooser.confirm() else {
    Issue.record("no saved file")
    return
  }
  var savedFile = FsIPC.FileClient(channel: saved.takeHandle())
  try savedFile.write(Array("saved draft".utf8))
  #expect(try v.entries("home/docs").contains { $0.name == "draft.md" })
}
