// SPDX-License-Identifier: BSD-3-Clause

// The preference apps (preferences(4)), hosted, over settings in memory:
// Keyboard's numbers in their steps, written as they change; Revert and
// Defaults; Appearance's choices; Deskbar's switches; another's change
// read again; Grants' recorded grants revoked.
// VECTRAOS_PREFERENCES_SAMPLE=FILE draws Keyboard's.

import Foundation
import GlyphAtlas
import Kit
import OpenType
import PreferencesApp
import Settings
import Testing
import TextLayout
import UICore

@MainActor final class Store: SettingsStore {
  var values: [String: SettingValue] = [:]
  var recorded: [Grants.Entry] = []
  var writes = 0
  func value(_ s: Setting) -> SettingValue { s.accept(values[s.name]) }
  func set(_ s: Setting, _ v: SettingValue) {
    values[s.name] = v
    writes += 1
  }
  func grants() -> [Grants.Entry] { recorded }
  func revoke(_ g: Grants.Entry) { recorded.removeAll { $0 == g } }
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

@MainActor func runner(_ app: PreferenceApp, scale: Float = 1) throws -> Runner {
  Runner(app: app, painter: Painter(theme: try shipped("neon-tab"), fonts: try fonts(), scale: scale,
                                    cache: GlyphCache(coverageSize: 1024, fieldSize: 128)), width: 420, height: 200)
}

/// Presses the button labelled `label` (the n-th, from 0).
@MainActor func press(_ r: Runner, _ label: String, _ n: Int = 0) throws {
  let found = r.ui.access.filter { $0.role == .button && $0.label == label }
  let b = try #require(n < found.count ? found[n] : nil)
  let at = (b.x + b.width / 2, b.y + b.height / 2)
  r.frame(FrameInput(pointerX: at.0, pointerY: at.1))
  r.frame(FrameInput(pointerX: at.0, pointerY: at.1, down: true, pressed: true))
  r.frame(FrameInput(pointerX: at.0, pointerY: at.1, released: true))
  r.frame(FrameInput())
}

@MainActor @Test func keyboardsNumbersMoveInStepsAndAreWrittenAtOnce() throws {
  let store = Store()
  let app = PreferenceApp(area: "Keyboard", store: store)
  #expect(app.title == "Keyboard" && app.settings.map { $0.name } == ["Keyboard:RepeatDelay", "Keyboard:RepeatRate"])
  #expect(app.values == [.int(500), .int(30)])
  let r = try runner(app)
  r.frame(FrameInput())
  try press(r, "+")  // the delay: 50 ms a step
  try press(r, "−", 1)  // the rate: 1 a step
  #expect(app.values == [.int(550), .int(29)] && store.values["Keyboard:RepeatDelay"] == .int(550))
  // Revert: as it opened; Defaults: the defaults.
  store.values["Keyboard:RepeatDelay"] = .int(800)
  app.reload()
  #expect(app.values[0] == .int(800))
  try press(r, "Revert")
  #expect(app.values == [.int(500), .int(30)] && store.values["Keyboard:RepeatRate"] == .int(30))
  try press(r, "+")
  try press(r, "Defaults")
  #expect(app.values == [.int(500), .int(30)])
  // Never past the range.
  for _ in 0..<40 { app.set(0, .int(app.values[0].int! + 50)) }
  #expect(app.values[0] == .int(2000))
}

@MainActor @Test func appearancesChoicesAndDeskbarsSwitches() throws {
  let store = Store()
  let look = PreferenceApp(area: "Appearance", store: store)
  let r = try runner(look)
  r.frame(FrameInput())
  #expect(r.ui.access.filter { $0.role == .button }.map { $0.label }.prefix(2) == ["platinum-indigo", "neon-tab"])
  try press(r, "neon-tab")
  #expect(store.values["Appearance:Theme"] == .string("neon-tab"))
  let bar = PreferenceApp(area: "Deskbar", store: store)
  let rb = try runner(bar)
  rb.frame(FrameInput())
  try press(rb, "On", 1)  // the gauges
  #expect(store.values["Deskbar:Gauges"] == .bool(false) && bar.values == [.bool(true), .bool(false)])
}

@MainActor @Test func grantsAreListedAndRevoked() throws {
  let store = Store()
  store.recorded = [Grants.Entry(app: "recorder", service: "capture", allowed: true),
                    Grants.Entry(app: "editor", service: "clipboard", allowed: false)]
  let app = PreferenceApp(area: "Grants", store: store)
  #expect(app.isGrants && app.settings.isEmpty && app.grants.count == 2)
  let r = try runner(app)
  r.frame(FrameInput())
  #expect(r.ui.access.contains { $0.label == "recorder · capture" })
  #expect(r.ui.access.contains { $0.label == "Refused" })
  // No Defaults or Revert: a recorded grant is an answer, not a setting.
  #expect(!r.ui.access.contains { $0.role == .button && ($0.label == "Defaults" || $0.label == "Revert") })
  try press(r, "Revoke")
  #expect(store.recorded.map { $0.app } == ["editor"] && app.grants.map { $0.app } == ["editor"])
  // Another's revoke, read again.
  store.recorded = []
  app.reload()
  r.frame(FrameInput())
  #expect(r.ui.access.contains { $0.label == "No grants recorded." })
}

@MainActor @Test func keyboardsPane() throws {
  let app = PreferenceApp(area: "Keyboard", store: Store())
  let r = try runner(app, scale: 2)
  r.frame(FrameInput())
  #expect(r.ui.access.contains { $0.label == "Repeat after (ms)" })
  guard let path = ProcessInfo.processInfo.environment["VECTRAOS_PREFERENCES_SAMPLE"] else { return }
  var canvas = Canvas(width: 840, height: 400, color: 0x0A0A12)
  r.ui.painter.render(into: &canvas)
  var ppm = Array("P6\n\(canvas.width) \(canvas.height)\n255\n".utf8)
  for p in canvas.pixels { ppm += [UInt8(p >> 16 & 0xFF), UInt8(p >> 8 & 0xFF), UInt8(p & 0xFF)] }
  try Data(ppm).write(to: URL(filePath: path))
}
