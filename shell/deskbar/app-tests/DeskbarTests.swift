// SPDX-License-Identifier: BSD-3-Clause

// Deskbar (deskbar(4)), hosted: the launcher's apps read, windows
// grouped into running apps, the VECTRAOS menu starting one, a running
// app's windows' menu, the panel's height following, the gauges read from
// /proc/cpu and Radharc's pacing, and the clock's place left for Radharc.
// VECTRAOS_DESKBAR_SAMPLE=FILE draws board 01's Deskbar through the app.

import DeskbarApp
import Foundation
import GlyphAtlas
import Kit
import OpenType
import Testing
import TextLayout
import UICore

@MainActor final class Host: DeskbarHost {
  var started: [String] = []
  var raised: [UInt32] = []
  var hidden: [UInt32] = [], shown: [UInt32] = [], closed: [UInt32] = []
  func start(_ service: String) { started.append(service) }
  func top(_ window: UInt32) { raised.append(window) }
  func hide(_ window: UInt32) { hidden.append(window) }
  func show(_ window: UInt32) { shown.append(window) }
  func close(_ window: UInt32) { closed.append(window) }
  var found = 0, opened: [(String, RecentKind)] = []
  func find() { found += 1 }
  func open(recent item: String, kind: RecentKind) { opened.append((item, kind)) }
  var shownWorkspaces: [Int] = []
  func workspace(_ n: Int) { shownWorkspaces.append(n) }
  var drawers = 0
  func drawer() { drawers += 1 }
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
                               ("ibm-plex-sans/IBMPlexSans-Regular.ttf", .body, 400),
                               ("ibm-plex-mono/IBMPlexMono-Regular.ttf", .mono, 400),
                               ("chakra-petch/ChakraPetch-Medium.ttf", .display, 500)] {
    let data = try #require(try? Data(contentsOf: URL(filePath: "\(repository)/data/fonts/\(path)")))
    fonts.add(try Font([UInt8](data)), role: role, weight: weight)
  }
  return fonts
}

@MainActor func deskbar(scale: Float = 1) throws -> (Deskbar, Runner, Host) {
  let host = Host()
  let bar = Deskbar(host: host)
  let painter = Painter(theme: try shipped("neon-tab"), fonts: try storyboardFonts(), scale: scale,
                        cache: GlyphCache(coverageSize: 1024, fieldSize: 128))
  return (bar, Runner(app: bar, painter: painter, width: Theme.cqw(15), height: 400), host)
}

let windows = [
  WindowItem(id: 1, title: "Taisce", app: "Tracker", focused: false, furniture: true),
  WindowItem(id: 2, title: "home", app: "Tracker", focused: true, furniture: false),
  WindowItem(id: 3, title: "Terminal", app: "Terminal", focused: false, furniture: false),
  WindowItem(id: 4, title: "Music", app: "Tracker", focused: false, furniture: false),
  WindowItem(id: 5, title: "Deskbar", app: "Deskbar", focused: false, furniture: true),
]

@MainActor func press(_ r: Runner, _ label: String, role: Role? = nil) async throws {
  let n = try #require(r.ui.access.first { $0.label == label && (role == nil || $0.role == role!) })
  let at = (n.x + n.width / 2, n.y + n.height / 2)
  r.frame(FrameInput(pointerX: at.0, pointerY: at.1))
  r.frame(FrameInput(pointerX: at.0, pointerY: at.1, down: true, pressed: true))
  r.frame(FrameInput(pointerX: at.0, pointerY: at.1, released: true))
  await r.settle()
  r.frame(FrameInput())
}

@Test func theLaunchersAppsAreRead() {
  #expect(AppEntry.parse("terminal\tTerminal\tstopped\ntracker\tTracker\trunning\nbad line\n") == [
    AppEntry(service: "terminal", name: "Terminal", running: false),
    AppEntry(service: "tracker", name: "Tracker", running: true),
  ])
}

@MainActor @Test func windowsAreGroupedIntoRunningApps() throws {
  let (bar, r, _) = try deskbar()
  bar.update(windows)
  #expect(bar.running.map(\.name) == ["Tracker", "Terminal"])
  #expect(bar.running[0].windows.map(\.id) == [2, 4] && bar.running[0].focused && !bar.running[1].focused)
  r.frame(FrameInput())
  #expect(r.ui.access.contains { $0.role == .button && $0.label == "Tracker" && $0.value == "2" })
  // The order apps were first seen in stays as windows come and go.
  bar.update([windows[2], windows[1]])
  #expect(bar.running.map(\.name) == ["Tracker", "Terminal"])
}

@MainActor @Test func theMenuStartsAnAppAndAppsRaiseTheirWindows() async throws {
  let (bar, r, host) = try deskbar()
  bar.apps = [AppEntry(service: "terminal", name: "Terminal", running: false),
              AppEntry(service: "tracker", name: "Tracker", running: true)]
  bar.update(windows)
  r.frame(FrameInput())
  let closed = bar.height(r.ui.painter)
  try await press(r, "VECTRAOS", role: .menu)
  #expect(bar.open == .apps && bar.height(r.ui.painter) >= closed)
  try await press(r, "Terminal", role: .menuItem)
  #expect(host.started == ["terminal"] && bar.open == nil)
  // An app's menu (Be's, M6l), its window chosen.
  try await press(r, "Terminal", role: .button)
  #expect(bar.open == .windows("Terminal"))
  try await press(r, "Terminal", role: .menuItem)
  #expect(host.raised == [3])
  try await press(r, "Tracker", role: .button)
  #expect(bar.open == .windows("Tracker"))
  try await press(r, "Music", role: .menuItem)
  #expect(host.raised == [3, 4] && bar.open == nil)
}

@MainActor @Test func theHeightFollowsTheRunningApps() throws {
  let (bar, r, _) = try deskbar()
  let empty = bar.height(r.ui.painter)
  bar.update(windows)
  #expect(bar.height(r.ui.painter) > empty)
}

@MainActor @Test func boardOnesDeskbar() throws {
  let scale: Float = 2
  let (bar, r, _) = try deskbar(scale: scale)
  bar.gauges = [Gauge(name: "CPU", fraction: 0.03, reading: "3%"), Gauge(name: "PACING", fraction: 0.08, reading: "p99 0.4")]
  bar.update([WindowItem(id: 2, title: "home", app: "Tracker", focused: true, furniture: false),
              WindowItem(id: 4, title: "Music", app: "Tracker", focused: false, furniture: false),
              WindowItem(id: 3, title: "Terminal", app: "Terminal", focused: false, furniture: false),
              WindowItem(id: 6, title: "Inbox", app: "Mail", focused: false, furniture: false)])
  r.ui.height = bar.height(r.ui.painter)
  r.frame(FrameInput())
  // The clock's place, at the tray's right, wide enough for "12:00 PM":
  // Radharc draws the time there.
  let clock = try #require(r.ui.access.first { $0.label == "Clock" })
  #expect(clock.width == Deskbar.clockWidth(r.ui.painter) && clock.x + clock.width <= Theme.cqw(15))
  #expect(clock.x > Theme.cqw(15) / 2 && clock.height > 0)
  // The gauges take their rows; off, the panel is shorter.
  let withGauges = bar.height(r.ui.painter)
  bar.gauges = []
  #expect(bar.height(r.ui.painter) < withGauges)
  bar.gauges = [Gauge(name: "CPU", fraction: 0.03, reading: "3%"), Gauge(name: "PACING", fraction: 0.08, reading: "p99 0.4")]
  guard let path = ProcessInfo.processInfo.environment["VECTRAOS_DESKBAR_SAMPLE"] else { return }
  var canvas = Canvas(width: Int(Theme.cqw(15) * scale), height: Int(r.ui.height * scale), color: 0x0A0A12)
  r.ui.painter.render(into: &canvas)
  var ppm = Array("P6\n\(canvas.width) \(canvas.height)\n255\n".utf8)
  for p in canvas.pixels { ppm += [UInt8(p >> 16 & 0xFF), UInt8(p >> 8 & 0xFF), UInt8(p & 0xFF)] }
  try Data(ppm).write(to: URL(filePath: path))
}

// The gauges (D114), read from the files answered on change.

@Test func theGaugesReadTheirFiles() {
  #expect(Gauges.cpu("busy 3\n") == Gauge(name: "CPU", fraction: 0.03, reading: "3%"))
  #expect(Gauges.cpu("busy 100\n").fraction == 1 && Gauges.cpu("").reading == "—")
  #expect(Gauges.pacing("p99 412\n").reading == "p99 0.4" && Gauges.pacing("p99 -1234\n").reading == "p99 0.0")
  #expect(Gauges.pacing("").reading == "—")
  let late = Gauges.pacing("p99 8333\n")
  #expect(late.fraction > 0.49 && late.fraction < 0.51)
}

/// Preference apps (6b, as Be's): under the menu's Preferences submenu.
@MainActor @Test func preferenceAppsAreASubmenu() async throws {
  let (bar, r, host) = try deskbar()
  bar.apps = AppEntry.parse("terminal\tTerminal\tstopped\tapp\nprefs-keyboard\tKeyboard\tstopped\tpreferences\n"
    + "prefs-mouse\tMouse\tstopped\tpreferences\n")
  #expect(bar.ordinaryApps.map(\.name) == ["Terminal"] && bar.preferenceApps.map(\.name) == ["Keyboard", "Mouse"])
  r.frame(FrameInput())
  try await press(r, "VECTRAOS", role: .menu)
  #expect(r.ui.access.filter { $0.role == .menuItem }.map(\.label)
            == ["Find…", "Drawer", "Recent documents →", "Recent folders →", "Recent applications →", "Terminal",
                "Preferences →"])
  try await press(r, "Preferences →", role: .menuItem)
  #expect(bar.open == .preferences)
  #expect(r.ui.access.filter { $0.role == .menuItem }.map(\.label) == ["Keyboard", "Mouse"])
  try await press(r, "Mouse", role: .menuItem)
  #expect(host.started == ["prefs-mouse"] && bar.open == nil)
}

/// Be's app menu (M6l): an app's windows, a hidden one marked, then Hide
/// all, Show all and Close all; an app with only its desktop (Tracker) is
/// listed, its menu saying "No windows".
@MainActor @Test func anAppsMenuHidesShowsAndClosesItsWindows() async throws {
  let (bar, r, host) = try deskbar()
  bar.update([WindowItem(id: 1, title: "Taisce", app: "Tracker", focused: false, furniture: true, desktop: true),
              WindowItem(id: 3, title: "Terminal", app: "Terminal", focused: true, furniture: false),
              WindowItem(id: 7, title: "Terminal 2", app: "Terminal", focused: false, furniture: false, hidden: true),
              WindowItem(id: 5, title: "Deskbar", app: "Deskbar", focused: false, furniture: true)])
  #expect(bar.running.map(\.name) == ["Tracker", "Terminal"] && bar.running[0].windows.isEmpty)
  r.frame(FrameInput())
  #expect(r.ui.access.contains { $0.role == .button && $0.label == "Tracker" && $0.value == "0" })
  try await press(r, "Terminal", role: .button)
  #expect(r.ui.access.filter { $0.role == .menuItem }.map(\.label)
            == ["Terminal", "Terminal 2 (hidden)", "Hide all", "Show all", "Close all"])
  try await press(r, "Hide all", role: .menuItem)
  #expect(host.hidden == [3] && bar.open == nil)  // the hidden one stays
  try await press(r, "Terminal", role: .button)
  try await press(r, "Show all", role: .menuItem)
  #expect(host.shown == [3, 7])
  try await press(r, "Terminal", role: .button)
  try await press(r, "Close all", role: .menuItem)
  #expect(host.closed == [3, 7])
  // Tracker's: "No windows", which can't be chosen.
  try await press(r, "Tracker", role: .button)
  #expect(r.ui.access.filter { $0.role == .menuItem }.map(\.label) == ["No windows", "Hide all", "Show all", "Close all"])
  #expect(r.ui.access.contains { $0.label == "No windows" && $0.action < 0 })
  try await press(r, "No windows")
  #expect(bar.open == .windows("Tracker"))
}

/// Be's leaf menu (M6l): Find, and the Recent lists, each swapped in for
/// the menu (the panel can't hold a cascade).
@MainActor @Test func theLeafMenuFindsAndOpensRecents() async throws {
  let (bar, r, host) = try deskbar()
  bar.apps = AppEntry.parse("terminal\tTerminal\tstopped\tapp\n")
  bar.recent = [.documents: ["text/markdown\t/data/home/notes.md"], .folders: [], .apps: ["terminal"]]
  r.frame(FrameInput())
  try await press(r, "VECTRAOS", role: .menu)
  try await press(r, "Find…", role: .menuItem)
  #expect(host.found == 1)
  try await press(r, "VECTRAOS", role: .menu)
  try await press(r, "Drawer", role: .menuItem)
  #expect(host.drawers == 1 && bar.open == nil)
  try await press(r, "VECTRAOS", role: .menu)
  try await press(r, "Recent documents →", role: .menuItem)
  #expect(bar.open == .recent(.documents))
  #expect(r.ui.access.filter { $0.role == .menuItem }.map(\.label) == ["notes.md"])
  try await press(r, "notes.md", role: .menuItem)
  #expect(host.opened.map(\.0) == ["text/markdown\t/data/home/notes.md"] && bar.open == nil)
  try await press(r, "VECTRAOS", role: .menu)
  try await press(r, "Recent folders →", role: .menuItem)
  #expect(r.ui.access.contains { $0.label == "Nothing yet" && $0.action < 0 })
  bar.closeMenu()
  r.frame(FrameInput())
  try await press(r, "VECTRAOS", role: .menu)
  try await press(r, "Recent applications →", role: .menuItem)
  #expect(r.ui.access.filter { $0.role == .menuItem }.map(\.label) == ["Terminal"])
  try await press(r, "Terminal", role: .menuItem)
  #expect(host.opened.last?.0 == "terminal" && host.opened.last?.1 == .apps)
}

@MainActor @Test func theTrayShowsTheWorkspacesAndAClickSwitches() async throws {
  let (bar, r, host) = try deskbar()
  bar.workspaces = [WorkspaceItem(number: 1, tiled: true, current: true), WorkspaceItem(number: 2, tiled: false, current: false),
                    WorkspaceItem(number: 3, tiled: false, current: false), WorkspaceItem(number: 4, tiled: true, current: false)]
  r.frame(FrameInput())
  let buttons = r.ui.access.filter { $0.role == .button && $0.label.hasPrefix("Workspace ") }
  #expect(buttons.map { $0.value } == ["tile", "space", "space", "tile"])
  // Left of the clock, in the tray's row.
  let clock = try #require(r.ui.access.first { $0.label == "Clock" })
  #expect(buttons.allSatisfy { $0.x + $0.width <= clock.x && abs($0.y - clock.y) < 1 })
  try await press(r, "Workspace 2", role: .button)
  #expect(host.shownWorkspaces == [2])
}
