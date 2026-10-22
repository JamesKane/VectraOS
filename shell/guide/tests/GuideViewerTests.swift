// SPDX-License-Identifier: BSD-3-Clause

// guide(4), hosted: the library from pages' headers; Contents, Index,
// Retrace and Browse; the links in rendered text; and the window, a link
// clicked moving it to the page it names.

import Foundation
import GlyphAtlas
import Guide
import GuideApp
import GuideViewer
import Kit
import OpenType
import Testing
import TextLayout
import UICore

func page(_ name: String, _ section: Int, _ summary: String, names: String = "", body: String = "") -> (String, [UInt8]) {
  let names = names.isEmpty ? "" : "names \(name) \(names)\n"
  return ("\(section)/\(name)", Array("page \(name) \(section)\nsummary \(summary)\n\(names)\n# DESCRIPTION\n\n\(body)\n".utf8))
}

let pages = [page("rc", 1, "the shell", names: "rcmain", body: "See man(1) and plumb(6). A sentence ends.(2) not a link."),
             page("man", 1, "print the manual", body: "Pages are guide(6)'s."),
             page("plumb", 6, "the plumber's rules"), page("guide", 6, "a page's format"),
             ("1/broken", Array("not a page".utf8))]

@Test func theLibraryIsThePagesHeaders() {
  let lib = ManualLibrary(pages: pages)
  #expect(lib.entries.map { $0.title } == ["man(1)", "rc(1)", "guide(6)", "plumb(6)"])
  #expect(lib.sections == [1, 6])
  #expect(lib.find("rcmain")?.title == "rc(1)" && lib.find("guide", section: 1) == nil)
  #expect(lib.index.map { $0.word } == ["guide", "man", "plumb", "rc", "rcmain"])
  #expect(lib.index(prefix: "rc").map { $0.word } == ["rc", "rcmain"])
}

@Test func retraceAndBrowseMoveTheViewer() throws {
  let lib = ManualLibrary(pages: pages)
  var v = ManualViewer()
  let rc = try #require(lib.find("rc"))
  v.go(.page(rc))
  let back = v.browse(forward: false, in: lib)
  #expect(back && v.place == .page(lib.find("man")!))
  let past = v.browse(forward: false, in: lib)
  #expect(!past)
  v.go(.index)
  var r = v.retrace()
  #expect(r && v.place == .page(lib.find("man")!))
  r = v.retrace()
  #expect(r && v.place == .page(rc))
  r = v.retrace()
  let none = v.retrace()
  #expect(r && !none && v.place == .contents)
}

@Test func linksAreNamesAndSections() {
  let line = Array("See rc(1), plumb(6) and man(9); x.(2) and .rc(1)".utf8)
  let links = ManualLinks.find(in: line)
  #expect(links.map { "\($0.name)(\($0.section))" } == ["rc(1)", "plumb(6)", "rc(1)"])
  #expect(String(decoding: line[links[0].range], as: UTF8.self) == "rc(1)")
  #expect(ManualLinks.parse("radharc(4)")! == ("radharc", 4))
  #expect(ManualLinks.parse("rc(9)") == nil && ManualLinks.parse("(1)") == nil)
}

@MainActor final class Host: GuideHost {
  func read(_ entry: ManualEntry) -> [UInt8]? { pages.first { $0.0 == entry.path }?.1 }
}

let repository = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
  .deletingLastPathComponent().deletingLastPathComponent().path

@MainActor func press(_ r: Runner, _ label: String) async throws {
  let n = try #require(r.ui.access.first { $0.label == label })
  let at = (n.x + n.width / 2, n.y + n.height / 2)
  r.frame(FrameInput(pointerX: at.0, pointerY: at.1))
  r.frame(FrameInput(pointerX: at.0, pointerY: at.1, down: true, pressed: true))
  r.frame(FrameInput(pointerX: at.0, pointerY: at.1, released: true))
  await r.settle()
  r.frame(FrameInput())
}

@MainActor @Test func aLinkClickedOpensItsPage() async throws {
  let theme = try Theme.resolve(ThemeStack(theme: "platinum-indigo", variant: nil)) { n in
    (try? Data(contentsOf: URL(filePath: "\(repository)/ui/theme/themes/\(n)"))).map { [UInt8]($0) }
  }
  var fonts = Fonts()
  let data = try #require(try? Data(contentsOf: URL(filePath: "\(repository)/data/fonts/ibm-plex-mono/IBMPlexMono-Regular.ttf")))
  for role in [FontRole.ui, .body, .mono] { fonts.add(try Font([UInt8](data)), role: role, weight: 400) }
  let host = Host()
  let app = GuideApp(library: ManualLibrary(pages: pages), host: host)
  let r = Runner(app: app, painter: Painter(theme: theme, fonts: fonts, scale: 1,
                                            cache: GlyphCache(coverageSize: 1024, fieldSize: 128)), width: 800, height: 600)
  r.frame(FrameInput())
  try await press(r, "rc(1)")
  #expect(app.viewer.place == .page(app.library.find("rc")!) && app.title == "Guide: rc(1)")
  try await press(r, "plumb(6)")
  #expect(app.viewer.place == .page(app.library.find("plumb")!))
  try await press(r, "Retrace")
  #expect(app.viewer.place == .page(app.library.find("rc")!))
  try await press(r, "Index")
  #expect(app.viewer.place == .index)
  #expect(!app.follow("nowhere", section: 1))
}
