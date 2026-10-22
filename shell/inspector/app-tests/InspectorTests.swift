// SPDX-License-Identifier: BSD-3-Clause

// The Inspector (inspector(4)), hosted, over /proc's status lines as
// proc(4) gives them: the lines parsed, CPU shares between two readings,
// a row selected, and paused while nobody is at the desktop.
// VECTRAOS_INSPECTOR_SAMPLE=FILE draws it.

import Foundation
import GlyphAtlas
import InspectorApp
import Kit
import OpenType
import Testing
import TextLayout
import UICore

/// proc's status line (Proc.statusLine): name, user and state padded to
/// 27, 27 and 11, then nine numbers of 11.
func status(_ name: String, _ state: String, ms: UInt64, kib: UInt64) -> String {
  func left(_ t: String, _ w: Int) -> String { t + String(repeating: " ", count: max(0, w - t.count)) }
  func right(_ n: UInt64) -> String { let t = "\(n)"; return String(repeating: " ", count: max(0, 11 - t.count)) + t }
  return left(name, 27) + " " + left("none", 27) + " " + left(state, 11)
    + [ms, 0, 0, 0, 0, 0, kib, 0, 0].map { " " + right($0) }.joined() + "\n"
}

func reading(consoleMs: UInt64) -> [ProcLine] {
  [ProcLine.parse(pid: 1068, status("console", "Running", ms: consoleMs, kib: 1400)),
   ProcLine.parse(pid: 1148, status("devmgr", "Running", ms: 90, kib: 2400)),
   ProcLine.parse(pid: 1031, status("a name past its twenty-seven columns", "New", ms: 0, kib: 3))].compactMap { $0 }
}

let repository = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
  .deletingLastPathComponent().deletingLastPathComponent().path

func shipped(_ name: String) throws -> Theme {
  try Theme.resolve(ThemeStack(theme: name, variant: nil)) { n in
    (try? Data(contentsOf: URL(filePath: "\(repository)/ui/theme/themes/\(n)"))).map { [UInt8]($0) }
  }
}

func fonts() throws -> Fonts {
  var f = Fonts()
  for (path, role, weight) in [("barlow-condensed/BarlowCondensed-Medium.ttf", FontRole.ui, 500),
                               ("ibm-plex-sans/IBMPlexSans-Regular.ttf", .body, 400),
                               ("ibm-plex-mono/IBMPlexMono-Regular.ttf", .mono, 400)] {
    let data = try #require(try? Data(contentsOf: URL(filePath: "\(repository)/data/fonts/\(path)")))
    f.add(try Font([UInt8](data)), role: role, weight: weight)
  }
  return f
}

@Test func procsStatusLinesAreRead() {
  let p = reading(consoleMs: 52)
  #expect(p.count == 3)
  #expect(p[0] == ProcLine(pid: 1068, name: "console", state: "Running", milliseconds: 52, kib: 1400))
  #expect(p[2].name == "a name past its twenty-seven columns" && p[2].state == "New")
  #expect(ProcLine.parse(pid: 1, "console Running 1 2\n") == nil)
}

@MainActor @Test func cpuSharesComeFromTwoReadings() {
  let a = Inspector()
  a.update(reading(consoleMs: 52), at: 1_000_000_000)
  #expect(a.cells(a.processes.first { $0.pid == 1068 }!) == ["console", "Running", "—", "1.4 MiB", "1068"])
  // A second later, the console has had 250 ms more.
  a.update(reading(consoleMs: 302), at: 2_000_000_000)
  #expect(a.cpuShare[1068] == 0.25 && a.cpuShare[1148] == 0)
  #expect(a.cells(a.processes.first { $0.pid == 1068 }!)[2] == "25%")
  #expect(a.processes.map { $0.pid } == [1031, 1068, 1148])
  #expect(a.counts == "3 processes · 3.7 MiB")
}

@MainActor @Test func aRowIsSelectedAndAGoneOneIsNot() throws {
  let a = Inspector()
  a.update(reading(consoleMs: 52), at: 1)
  let r = Runner(app: a, painter: Painter(theme: try shipped("neon-tab"), fonts: try fonts(), scale: 2,
                                          cache: GlyphCache(coverageSize: 1024, fieldSize: 128)),
                 width: 640, height: 420)
  r.frame(FrameInput())
  #expect(r.ui.access.contains { $0.role == .cell && $0.label == "devmgr" })
  #expect(r.ui.access.contains { $0.label == "/proc · once a second" })
  let row = try #require(r.ui.access.first { $0.role == .cell && $0.label == "devmgr" })
  let at = (row.x + row.width / 2, row.y + row.height / 2)
  r.frame(FrameInput(pointerX: at.0, pointerY: at.1))
  r.frame(FrameInput(pointerX: at.0, pointerY: at.1, down: true, pressed: true))
  r.frame(FrameInput(pointerX: at.0, pointerY: at.1, released: true))
  #expect(a.selected == 1148)
  a.update(reading(consoleMs: 60).filter { $0.pid != 1148 }, at: 2)
  #expect(a.selected == nil)
  a.paused = true
  r.frame(FrameInput())
  #expect(r.ui.access.contains { $0.label == "paused: nobody at the desktop" })
  guard let path = ProcessInfo.processInfo.environment["VECTRAOS_INSPECTOR_SAMPLE"] else { return }
  var canvas = Canvas(width: 1280, height: 840, color: 0x0A0A12)
  r.ui.painter.render(into: &canvas)
  var ppm = Array("P6\n\(canvas.width) \(canvas.height)\n255\n".utf8)
  for p in canvas.pixels { ppm += [UInt8(p >> 16 & 0xFF), UInt8(p >> 8 & 0xFF), UInt8(p & 0xFF)] }
  try Data(ppm).write(to: URL(filePath: path))
}
