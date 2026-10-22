// SPDX-License-Identifier: BSD-3-Clause

// A preference app (preferences(4), D115; as Be had them: a small app an
// area, not one app with panes). It shows its area's settings
// (`Settings.all`'s), each with its control: − and + for a number (in
// steps that suit its range), On and Off for a bool, a button a choice for
// a string; a change is written at once (each area is a file, each
// setting an attribute: rc's `attr` reaches them too). Defaults sets the
// area's defaults; Revert, what it had when the app opened. Grants is an
// area of its own: the recorded grants (D111), each with Revoke. Another's
// change (`attr`, another app) comes back through the host's watch
// (`reload`).

import Kit
import Settings
import UICore

/// Where settings are read and written (the volume's, natively; tests'
/// own).
@MainActor public protocol SettingsStore: AnyObject {
  func value(_ s: Setting) -> SettingValue
  func set(_ s: Setting, _ v: SettingValue)
  /// The recorded grants, and one revoked.
  func grants() -> [Grants.Entry]
  func revoke(_ g: Grants.Entry)
}

@MainActor public final class PreferenceApp: App {
  public let area: String
  public let settings: [Setting]
  let store: SettingsStore
  /// What they were when the app opened (Revert's).
  public let opened: [SettingValue]
  public private(set) var values: [SettingValue]
  /// Grants': the recorded grants.
  public private(set) var grants: [Grants.Entry] = []

  public init(area: String, store: SettingsStore) {
    self.area = area
    self.store = store
    settings = Settings.all.filter { $0.area == area }
    let now = settings.map { store.value($0) }
    opened = now
    values = now
    if isGrants { grants = store.grants() }
  }

  public var title: String { area }
  public var isGrants: Bool { area == Grants.area }

  /// Read again (another changed them).
  public func reload() {
    values = settings.map { store.value($0) }
    if isGrants { grants = store.grants() }
  }

  public func set(_ i: Int, _ v: SettingValue) {
    // A number steps up to its range's edge, not past it.
    var v = v
    if case .int(let n) = v, let r = settings[i].range { v = .int(min(max(n, r.0), r.1)) }
    let accepted = settings[i].accept(v)
    guard accepted != values[i] else { return }
    values[i] = accepted
    store.set(settings[i], accepted)
  }

  public func defaults() { for i in settings.indices { set(i, settings[i].fallback) } }
  public func revert() { for i in settings.indices { set(i, opened[i]) } }

  public func revoke(_ i: Int) {
    guard i < grants.count else { return }
    store.revoke(grants[i])
    grants = store.grants()
  }

  /// A number's step: 50 for ranges over a few hundred (milliseconds), else 1.
  static func step(_ s: Setting) -> Int64 {
    guard let r = s.range else { return 1 }
    return r.1 - r.0 > 300 ? 50 : 1
  }

  public var actions: [ActionHandler] {
    func ctrl(_ c: Character) -> KeyPress { KeyPress(.character(c.unicodeScalars.first!.value), control: true) }
    return [ActionHandler(Action("preferences.quit", label: "Close", key: ctrl("w"))) { [self] _ in onClose?() }]
  }

  /// Control-W: its host closes it.
  public var onClose: (() -> Void)?

  public var body: Group {
    VStack(class: "pane", width: .percent(1), height: .percent(1)) {
      if isGrants {
        if grants.isEmpty { Text("No grants recorded.") }
        let names = grants.map { $0.app + "." + $0.service }
        ForEach(Array(names.indices), id: { names[$0] }) { i in
          GrantRow(app: self, index: i)
        }
        Spacer()
      } else {
        let names = settings.map { $0.name }
        ForEach(Array(names.indices), id: { names[$0] }) { i in
          SettingRow(app: self, index: i)
        }
        Spacer()
        HStack(width: .percent(1)) {
          Spacer()
          Button("Defaults") { [self] in defaults() }.id("defaults")
          Spacer(Theme.cqw(0.6))
          Button("Revert") { [self] in revert() }.id("revert")
        }
      }
    }
  }
}

/// A setting's label and its control.
struct SettingRow: View {
  let app: PreferenceApp
  let index: Int

  @MainActor func build(_ c: inout BuildContext, id: String) {
    let s = app.settings[index]
    let v = app.values[index]
    let i = index
    let a = app
    let cq = Theme.cqw
    c.ui.open(id, class: "pane.row", width: .percent(1), height: .children(), axis: .horizontal)
    c.ui.label("label", s.label)
    c.ui.spacer("gap")
    switch v {
    case .int(let n):
      let step = PreferenceApp.step(s)
      if c.ui.button("minus", "−") { a.set(i, .int(n - step)) }
      c.ui.box("value", class: "pane.value", text: "\(n)", width: .pixels(cq(4.5)), height: .percent(1),
               flags: [.text, .centred])
      c.ui.accessible(.label, label: s.label, value: "\(n)")
      if c.ui.button("plus", "+") { a.set(i, .int(n + step)) }
    case .bool(let on):
      if c.ui.button("toggle", on ? "On" : "Off", class: on ? "button.primary" : "button") { a.set(i, .bool(!on)) }
    case .string(let chosen):
      for (k, choice) in s.choices.enumerated() {
        if k > 0 { c.ui.box("g\(k)", width: .pixels(cq(0.5)), height: .pixels(0)) }
        if c.ui.button("c\(k)", choice, class: choice == chosen ? "button.primary" : "button") { a.set(i, .string(choice)) }
      }
    }
    c.ui.close()
  }
}

/// A recorded grant: the app and the service, its answer, and Revoke.
struct GrantRow: View {
  let app: PreferenceApp
  let index: Int

  @MainActor func build(_ c: inout BuildContext, id: String) {
    // (A Revoke earlier in this frame shortens the list; the next frame's
    // rows are the new list's.)
    guard index < app.grants.count else { return }
    let g = app.grants[index]
    let i = index
    let a = app
    let cq = Theme.cqw
    c.ui.open(id, class: "pane.row", width: .percent(1), height: .children(), axis: .horizontal)
    c.ui.label("label", g.app + " · " + g.service)
    c.ui.spacer("gap")
    c.ui.label("answer", g.allowed ? "Allowed" : "Refused")
    c.ui.box("g", width: .pixels(cq(0.5)), height: .pixels(0))
    if c.ui.button("revoke", "Revoke") { a.revoke(i) }
    c.ui.close()
  }
}
