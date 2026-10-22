// SPDX-License-Identifier: BSD-3-Clause

// Tracker's model (tracker(4)), over the fs service on a RAM disk in
// memory: listings in batches with attributes, sorting (folders first),
// a folder kept current by its watch, the window state and icon places in
// attributes, rename, new folders, the Trash and back, file types set
// once, confined chosen-file capabilities (D111); and the columns' text as
// board 01 shows it.

import Foundation
import Fs
import FsServer
import IPC
import Node
import Sd
import Sys
import struct Taisce.FileSystem
import Testing
import Tracker

/// A dispatcher run on a thread of its own until stopped.
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

/// An fs service over memory, and a Volume over its root.
final class Rig: @unchecked Sendable {
  let disk: Running
  let unit: SdUnit
  let fsThread: Running
  let service: FsService

  init(blocks: Int = 16384) throws {
    let diskDispatcher = try IPCDispatcher()
    let memory = try MemoryDisk(name: "ramdisk0", try VMO.create(size: blocks * 4096), sectors: UInt64(blocks),
                                sectorSize: 4096)
    unit = SdUnit(memory, dispatcher: diskDispatcher)
    disk = Running(diskDispatcher)
    var dir = NodeIPC.NodeClient(channel: try unit.channel())
    let data = try dir.open("data").takeChannel()
    var ctlDir = NodeIPC.NodeClient(channel: try unit.channel())
    let ctl = try ctlDir.open("ctl").takeChannel()
    let device = try NodeDevice(data, ctl: ctl)
    let fs = try FileSystem.format(device, label: Array("test".utf8), uuid: [UInt8](repeating: 7, count: 16),
                                   now: FsService.now)
    let fsDispatcher = try IPCDispatcher()
    service = try FsService(fs, device: "/dev/sdZ0/data", dispatcher: fsDispatcher)
    fsThread = Running(fsDispatcher)
  }

  func volume() throws -> Tracker.Volume {
    Tracker.Volume(root: FsIPC.DirectoryClient(channel: try service.root()))
  }

  /// A file at `path` holding `bytes`.
  func file(_ v: Tracker.Volume, _ path: String, _ bytes: [UInt8] = []) throws {
    let (folder, name) = Path.split(path)
    var dir = FsIPC.DirectoryClient(channel: try service.root())
    if !folder.isEmpty { dir = try dir.directory(folder) }
    var f = try dir.makeFile(name)
    if !bytes.isEmpty { try f.write(bytes) }
    _ = v
  }

  func stop() {
    fsThread.stop()
    disk.stop()
  }
}

@Test func columnsAsTheStoryboardShowsThem() {
  #expect(Format.size(512) == "512 B")
  #expect(Format.size(14 * 1024 + 300) == "14 KiB")
  #expect(Format.size(UInt64(3.1 * 1048576) + 10) == "3.1 MiB")
  #expect(Format.size(1023 * 1024) == "1023 KiB" && Format.size(10 * 1048576) == "10 MiB")
  #expect(Format.size(3_250_009) == "3.1 MiB" && Format.size(1_048_300) == "1.0 MiB")
  // 2026-10-10T12:00Z.
  #expect(Format.date(1_791_633_600 * 1_000_000_000) == "2026-10-10")
  #expect(Format.date(0) == "1970-01-01" && Format.date(-1) == "1969-12-31")
  let folder = Entry(name: "Music", node: 2, isDirectory: true, size: 4096, modified: 0)
  #expect(folder.text(Column.size) == "—" && folder.text(Column.type) == "directory")
  let notes = Entry(name: "render-notes.md", node: 3, isDirectory: false, size: 14 * 1024, modified: 0,
                    attributes: [Column.type: .type("text/markdown")])
  #expect(notes.text(Column.type) == "text/markdown" && notes.text("Audio:Year") == "—")
  #expect(Column.title(Column.modified) == "Modified" && Column.title("sys:type") == "sys:type")
}

@Test func valuesRoundTripTheirEncoding() {
  for v: AttributeValue in [.string("é"), .int(-5), .uint(7), .double(2.5), .time(123), .bool(true), .bytes([1, 2]),
                            .type("text/plain")]
  {
    let (k, b) = v.encoded
    #expect(AttributeValue(kind: k, value: b) == v)
  }
  #expect(AttributeValue(kind: 2, value: [1]) == nil && AttributeValue(kind: 99, value: []) == nil)
  #expect(AttributeValue.double(2.5).text == "2.5" && AttributeValue.int(1993).text == "1993")
  // Numbers of different kinds compare as numbers; strings without case.
  #expect(AttributeValue.ascending(.int(2), .uint(3)) && AttributeValue.ascending(.string("apple"), .string("Banana")))
}

@Test func aFolderListsInBatchesAndSortsFoldersFirst() throws {
  let rig = try Rig()
  defer { rig.stop() }
  let v = try rig.volume()
  _ = try v.makeFolder(in: "", named: "home")
  for (name, size) in [("b.txt", 300), ("A.txt", 10), ("c.bin", 2000)] {
    try rig.file(v, "home/" + name, [UInt8](repeating: 0x61, count: size))
  }
  _ = try v.makeFolder(in: "home", named: "Projects")
  _ = try v.makeFolder(in: "home", named: "music")
  try v.setAttribute("home/b.txt", "Audio:Year", .int(1994))
  try v.setAttribute("home/A.txt", "Audio:Year", .int(1991))

  var listing = try v.list("home", columns: FolderState.defaultColumns + ["Audio:Year"])
  var folder = Folder(path: "home")
  var batches = 0
  while !listing.done {
    let batch = try listing.next(max: 2)
    if !batch.isEmpty { batches += 1 }
    folder.add(batch)
  }
  #expect(batches == 3 && folder.entries.count == 5)
  // Listed once, it's kept: the next listing comes whole.
  var again = try v.list("home", columns: FolderState.defaultColumns + ["Audio:Year"])
  let whole = try again.next(max: 2)
  #expect(whole.count == 5 && again.done)
  #expect(folder.ordered().map(\.name) == ["music", "Projects", "A.txt", "b.txt", "c.bin"])
  #expect(folder.entry(named: "b.txt")?.attributes["Audio:Year"] == .int(1994))
  folder.sort = SortOrder(Column.size, descending: true)
  #expect(folder.ordered().map(\.name) == ["music", "Projects", "c.bin", "b.txt", "A.txt"])
  // Those without the attribute go last, by name.
  folder.sort = SortOrder("Audio:Year")
  #expect(folder.ordered().map(\.name) == ["music", "Projects", "A.txt", "b.txt", "c.bin"])
  folder.sort = SortOrder("Audio:Year", descending: true)
  #expect(folder.ordered().map(\.name) == ["music", "Projects", "b.txt", "A.txt", "c.bin"])
}

@Test func aFolderIsKeptCurrentByItsWatch() throws {
  let rig = try Rig()
  defer { rig.stop() }
  let v = try rig.volume()
  _ = try v.makeFolder(in: "", named: "home")
  var folder = Folder(path: "home")
  folder.add(try v.entries("home"))
  var watch = try v.watch("home")
  try rig.file(v, "home/new.txt", Array("hi".utf8))
  try v.rename("home/new.txt", to: "renamed.txt")
  // Each change names an entry: stat'ed again, or gone; the rename is one
  // change, under the new name.
  var seen: [NodeIPC.Change] = []
  for _ in 0..<50 where !seen.contains(where: { $0.name == "renamed.txt" }) {
    seen += watch.changes(deadline: Clock.monotonic() + 100_000_000)
  }
  try v.apply(seen, to: &folder, columns: FolderState.defaultColumns)
  #expect(folder.ordered().map(\.name) == ["renamed.txt"] && folder.entries[0].size == 2)
}

@Test func theWindowStateAndPlacesAreAttributes() throws {
  let rig = try Rig()
  defer { rig.stop() }
  let v = try rig.volume()
  _ = try v.makeFolder(in: "", named: "home")
  try rig.file(v, "home/a.txt")
  #expect(try v.state("home") == FolderState())
  var state = FolderState()
  state.frame = (160, 80, 512, 307)
  state.view = .icons
  state.columns = ["name", "Audio:Artist", "Audio:Year"]
  state.sort = SortOrder("Audio:Year", descending: true)
  try v.save(state, "home")
  #expect(try v.state("home") == state)
  // As text, so Terminal can read and change them.
  #expect(try v.attribute("home", FolderState.frameAttribute) == .string("160 80 512 307"))
  #expect(try v.attribute("home", FolderState.sortAttribute) == .string("-Audio:Year"))
  try v.setAttribute("home", FolderState.viewAttribute, .string("list"))
  #expect(try v.state("home").view == .list)
  // A nonsense frame is no frame.
  try v.setAttribute("home", FolderState.frameAttribute, .string("1 2 3"))
  #expect(try v.state("home").frame == nil)
  // An entry's place, which listings bring.
  try v.place("home/a.txt", x: 24, y: 96)
  let e = try #require(try v.entries("home").first)
  #expect(e.place?.x == 24 && e.place?.y == 96)
}

@Test func renameNewFoldersAndTheTrash() throws {
  let rig = try Rig()
  defer { rig.stop() }
  let v = try rig.volume()
  _ = try v.makeFolder(in: "", named: "home")
  try rig.file(v, "home/notes.md", Array("# notes".utf8))
  try rig.file(v, "home/other.md")
  #expect(try v.makeFolder(in: "home") == "New folder")
  #expect(try v.makeFolder(in: "home") == "New folder 2")
  #expect(try v.rename("home/notes.md", to: "render-notes.md") == "home/render-notes.md")
  #expect(throws: TrackerError.exists) { try v.rename("home/other.md", to: "render-notes.md") }
  #expect(throws: TrackerError.badName) { try v.rename("home/other.md", to: "a/b") }
  // To the Trash and back; a name taken there or back home gets " 2".
  try rig.file(v, "render-notes.md")
  let trashed = try v.trash(["home/render-notes.md", "render-notes.md"])
  #expect(trashed == ["Trash/render-notes.md", "Trash/render-notes 2.md"])
  #expect(try v.attribute("Trash/render-notes.md", Tracker.Volume.originAttribute) == .string("home/render-notes.md"))
  #expect(try v.entries("home").map(\.name).sorted() == ["New folder", "New folder 2", "other.md"])
  try rig.file(v, "home/render-notes.md")
  #expect(try v.restore("Trash/render-notes.md") == "home/render-notes 2.md")
  #expect(try v.attribute("home/render-notes 2.md", Tracker.Volume.originAttribute) == nil)
  #expect(throws: TrackerError.notFound) { try v.restore("home/other.md") }
}

@Test func filesGetTheirTypeOnce() throws {
  let rig = try Rig()
  defer { rig.stop() }
  let v = try rig.volume()
  let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + [UInt8](repeating: 0, count: 24)
  try rig.file(v, "picture", png)  // no extension: by content
  try rig.file(v, "notes.md", Array("# notes\n".utf8))
  try rig.file(v, "README", Array("plain words\n".utf8))
  try rig.file(v, "blob", [0, 1, 2, 3, 0xFF])
  try rig.file(v, "empty.txt")
  try rig.file(v, "empty")
  #expect(try v.type("picture") == "image/png")
  #expect(try v.type("notes.md") == "text/markdown")
  #expect(try v.type("README") == "text/plain")
  #expect(try v.type("blob") == "application/octet-stream")
  #expect(try v.type("empty.txt") == "text/plain" && v.type("empty") == nil)
  // Kept: a type the file has stands, whatever its content.
  try v.setAttribute("README", Column.type, .type("text/x-readme"))
  #expect(try v.type("README") == "text/x-readme")
  let e = try #require(try v.entries("").first { $0.name == "picture" })
  #expect(e.type == "image/png" && e.attributes[Column.type] == .type("image/png"))
  // UTF-8 cut at the end of what was read is still text; a stray byte isn't.
  #expect(FileTypes.sniff(Array("caf".utf8) + [0xC3], name: "x") == "text/plain")
  #expect(FileTypes.sniff([0x61, 0xC3, 0x28], name: "x") == "application/octet-stream")
  // MIME filter matching for the chooser.
  #expect(FileTypes.matches("text/markdown", allowed: ["image/*", "text/*"]))
  #expect(!FileTypes.matches("application/pdf", allowed: ["image/*", "text/plain"]))
  #expect(FileTypes.matches("application/octet-stream", allowed: []))
}

/// The fs protocol's error a call was refused with, if it was.
func fsRefusal(_ body: () throws(IPCError<FsIPC.FsError>) -> Void) -> FsIPC.FsError? {
  do throws(IPCError<FsIPC.FsError>) { try body() } catch {
    if case .remote(let e) = error { return e }
    return .io
  }
  return nil
}

/// The Node protocol's error a call was refused with, if it was.
func nodeRefusal(_ body: () throws(NodeIPC.NodeClient.Failure) -> Void) -> NodeIPC.NodeError? {
  do throws(NodeIPC.NodeClient.Failure) { try body() } catch {
    if case .remote(let e) = error { return e }
    return .io
  }
  return nil
}

@Test func aChosenFileChannelIsConfinedAndRespectsWritable() throws {
  let rig = try Rig()
  defer { rig.stop() }
  let v = try rig.volume()
  _ = try v.makeFolder(in: "", named: "home")
  try rig.file(v, "home/notes.md", Array("hello".utf8))
  try rig.file(v, "home/secret.txt", Array("secret".utf8))

  // Choosing a read-only file: can read it, cannot write or walk out or remove.
  let roHandle = try v.choose("home/notes.md", writable: false, types: ["text/*"])
  var roFile = FsIPC.FileClient(channel: roHandle)
  #expect(try roFile.readAll() == Array("hello".utf8))
  #expect(nodeRefusal { () throws(NodeIPC.NodeClient.Failure) in try roFile.write(Array("nope".utf8)) } == .denied)
  #expect(fsRefusal { () throws(IPCError<FsIPC.FsError>) in try roFile.resize(0) } == .readOnly)
  #expect(fsRefusal { () throws(IPCError<FsIPC.FsError>) in try roFile.setAttribute(.string("x", "y")) } == .readOnly)
  #expect(nodeRefusal { () throws(NodeIPC.NodeClient.Failure) in
    try roFile.node { (c: inout NodeIPC.NodeClient) throws(NodeIPC.NodeClient.Failure) in _ = try c.run([.remove]) }
  } == .denied)
  #expect(nodeRefusal { () throws(NodeIPC.NodeClient.Failure) in
    try roFile.node { (c: inout NodeIPC.NodeClient) throws(NodeIPC.NodeClient.Failure) in
      try c.wstat(NodeIPC.Wstat(name: "renamed.md"))
    }
  } == .denied)
  #expect(nodeRefusal { () throws(NodeIPC.NodeClient.Failure) in
    try roFile.node { (c: inout NodeIPC.NodeClient) throws(NodeIPC.NodeClient.Failure) in _ = try c.run([.walk(names: [".."])]) }
  } == .denied)

  // Choosing a file whose type doesn't match the filter is refused; a folder is refused.
  #expect(throws: TrackerError.badName) {
    _ = try v.choose("home/notes.md", writable: false, types: ["image/*"])
  }
  #expect(throws: TrackerError.badName) {
    _ = try v.choose("home", writable: false)
  }

  // Choosing a writable file in save mode creates it if missing, allows writes,
  // and still refuses walking out or unlinking/renaming.
  let rwHandle = try v.choose("home/saved.txt", writable: true)
  var rwFile = FsIPC.FileClient(channel: rwHandle)
  try rwFile.write(Array("saved!".utf8))
  #expect(try rwFile.readAll() == Array("saved!".utf8))
  // Saving over a file hands it over as it is: the app resizes it.
  var again = FsIPC.FileClient(channel: try v.choose("home/saved.txt", writable: true))
  #expect(try again.readAll() == Array("saved!".utf8))
  try again.resize(0)
  try again.write(Array("new".utf8))
  #expect(try again.readAll() == Array("new".utf8))
  #expect(nodeRefusal { () throws(NodeIPC.NodeClient.Failure) in
    try rwFile.node { (c: inout NodeIPC.NodeClient) throws(NodeIPC.NodeClient.Failure) in _ = try c.run([.remove]) }
  } == .denied)
  #expect(nodeRefusal { () throws(NodeIPC.NodeClient.Failure) in
    try rwFile.node { (c: inout NodeIPC.NodeClient) throws(NodeIPC.NodeClient.Failure) in
      try c.wstat(NodeIPC.Wstat(name: "other.txt"))
    }
  } == .denied)
  #expect(nodeRefusal { () throws(NodeIPC.NodeClient.Failure) in
    try rwFile.node { (c: inout NodeIPC.NodeClient) throws(NodeIPC.NodeClient.Failure) in _ = try c.run([.walk(names: [".."])]) }
  } == .denied)
}

@Test func selectionByClickControlAndShift() {
  var f = Folder(path: "")
  f.add((1...5).map { Entry(name: "f\($0)", node: UInt64($0), isDirectory: false, size: 0, modified: 0) })
  f.select(2)
  f.select(4, .range)
  #expect(f.selection == [2, 3, 4])
  f.select(1, .toggle)
  #expect(f.selection == [1, 2, 3, 4])
  f.select(1, .toggle)
  #expect(f.selection == [2, 3, 4] && f.neighbour(1)?.node == 2)
  f.select(5)
  #expect(f.selection == [5] && f.neighbour(-1)?.node == 4 && f.neighbour(1)?.node == 5)
  f.remove(named: "f5")
  #expect(f.selection.isEmpty && f.neighbour(1)?.node == 1)
  f.selectAll()
  #expect(f.selected().map(\.name) == ["f1", "f2", "f3", "f4"])
}

@Test func aRenameReplacesItsRowAndAnOverflowListsAgain() throws {
  let rig = try Rig()
  defer { rig.stop() }
  let v = try rig.volume()
  try rig.file(v, "a.txt")
  try rig.file(v, "b.txt")
  var folder = Folder(path: "")
  folder.add(try v.entries(""))
  let a = try #require(folder.entry(named: "a.txt"))
  folder.select(a.node)
  try v.rename("a.txt", to: "z.txt")
  try v.apply([NodeIPC.Change(seq: 9, node: a.node, kind: .modified, name: "z.txt"),
               NodeIPC.Change(seq: 9, node: 1, kind: .modified, name: "")],
              to: &folder, columns: FolderState.defaultColumns)
  // The same node, its new name, still selected; the folder's own change passed over.
  #expect(folder.ordered().map(\.name) == ["b.txt", "z.txt"] && folder.selection == [a.node])
  try rig.file(v, "c.txt")
  try v.apply([NodeIPC.Change(seq: 10, node: 1, kind: .overflow, name: "")], to: &folder, columns: FolderState.defaultColumns)
  #expect(folder.ordered().map(\.name) == ["b.txt", "c.txt", "z.txt"] && folder.selection == [a.node])
}

@Test func aQuerysColumnsAreTheNameAndWhatItNames() {
  #expect(QueryResults.columns(for: #"Audio:Genre ~= "trip-hop" && Audio:Year in 1990..<2000 order by Audio:Year"#)
    == ["name", "Audio:Genre", "Audio:Year"])
  #expect(QueryResults.columns(for: #"sys:type == "text:plain" || size > 4KiB"#) == ["name", "sys:type"])
  #expect(QueryResults.columns(for: "mtime >= 2026-10-01T00:00Z") == ["name"])
}

@Test func aQueryIsAFileAndItsMatchesStayLive() throws {
  let rig = try Rig()
  defer { rig.stop() }
  let v = try rig.volume()
  _ = try v.makeFolder(in: "", named: "a")
  _ = try v.makeFolder(in: "", named: "b")
  try rig.file(v, "a/song.flac")
  try rig.file(v, "b/song.flac")  // the same name elsewhere: both match
  try rig.file(v, "a/old.flac")
  try v.setAttribute("a/song.flac", "Audio:Year", .int(1994))
  try v.setAttribute("b/song.flac", "Audio:Year", .int(1996))
  try v.setAttribute("a/old.flac", "Audio:Year", .int(1970))
  let q = try v.makeQuery(in: "", named: "90s", text: "Audio:Year in 1990..<2000")
  #expect(q == "90s")
  #expect(try v.queryText(q) == "Audio:Year in 1990..<2000")
  #expect(try v.stat(q).type == FileTypes.query)
  #expect(try v.state(q).columns == ["name", "Audio:Year"])

  var live = try v.live(try v.queryText(q))
  var results = QueryResults(path: q, sort: SortOrder("Audio:Year"))
  func take() {
    for _ in 0..<40 {
      let c = live.changes(deadline: Clock.monotonic() + 50_000_000)
      if c.isEmpty && results.current { return }
      results.apply(c, volume: v)
    }
  }
  take()
  #expect(results.current && results.folder.ordered().map { $0.attributes["Audio:Year"] } == [.int(1994), .int(1996)])
  #expect(results.arrived.isEmpty && results.lastAdded == nil)
  // One comes to match: new, with its sequence; one stops matching.
  try v.setAttribute("a/old.flac", "Audio:Year", .int(1999))
  try v.setAttribute("b/song.flac", "Audio:Year", .int(2001))
  take()
  #expect(results.folder.ordered().map { results.paths[$0.node] } == ["a/song.flac", "a/old.flac"])
  let old = try #require(results.folder.entry(named: "old.flac"))
  #expect(results.arrived == [old.node] && results.lastAdded?.name == "old.flac" && (results.lastAdded?.seq ?? 0) > 0)
  #expect(throws: TrackerError.badQuery) { _ = try v.live("Audio:Year >") }
}

/// Be's Select…: `*` and `?`, whole names, any case.
@Test func namePatternsMatchWholeNames() {
  #expect(NamePattern.matches("*.md", "Notes.MD") && NamePattern.matches("a?c", "abc"))
  #expect(!NamePattern.matches("*.md", "notes.md.bak") && !NamePattern.matches("a?c", "ac"))
  #expect(NamePattern.matches("*", "") && NamePattern.matches("*a*b*", "xxaYYb") && !NamePattern.matches("*a*b", "ba"))
}

/// Add-ons in the launcher's `apps`, and the `start` line quoting their paths.
@Test func addOnsComeFromTheLaunchersApps() {
  #expect(AddOn.parse("term\tTerminal\tstopped\tapp\tOpen Terminal here\nb\tB\trunning\tapp\n")
            == [AddOn(service: "term", label: "Open Terminal here")])
  #expect(AddOn.start("term", ["/data/New folder", "/data/it's"]) == "start term '/data/New folder' '/data/it''s'")
}

/// A volume from its fs service's status.
@Test func aVolumeIsReadFromItsServicesStatus() {
  let v = VolumeInfo.parse(fsStatus: "volume main\ndevice /svc/block/device\ncommits 3\nblocks 16384 free 16000 size 4096\n",
                           boot: true)
  #expect(v == VolumeInfo(name: "main", bytes: 16384 * 4096, free: 16000 * 4096, boot: true))
  #expect(VolumeInfo.parse(fsStatus: "commits 3\n", boot: true) == nil)
}

/// The system's folders at the volume's top (Router, Settings) aren't
/// shown there, listed or arriving; elsewhere a folder of that name is.
@Test func theSystemsFoldersAreHiddenAtTheTop() {
  func folder(_ name: String, _ node: UInt64) -> Entry {
    Entry(name: name, node: node, isDirectory: true, size: 0, modified: 0)
  }
  var top = Folder(path: "")
  top.add([folder("Router", 1), folder("home", 2)])
  top.update(folder("Settings", 3))
  #expect(top.ordered().map(\.name) == ["home"])
  top.replace([folder("Settings", 3), folder("music", 4)])
  #expect(top.ordered().map(\.name) == ["music"])
  var home = Folder(path: "home")
  home.add([folder("Settings", 5)])
  #expect(home.ordered().map(\.name) == ["Settings"])
}
