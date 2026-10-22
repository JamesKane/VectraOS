// SPDX-License-Identifier: BSD-3-Clause

// Settings (D107, D111, D113; principle 18: "Preferences are Be's"). The
// system's settings live in a folder of the volume, a file an area
// (`/data/Settings/Keyboard`), each setting a typed Taisce attribute
// (`Keyboard:RepeatDelay`, int64); a file or attribute that isn't there
// means its default. Settings writes them, rc's `attr` too; whoever
// applies one reads its area's file and watches the folder (Node's watch):
// a change names the file or attribute. Tier 0: services read them as apps
// do.

import Fs
import IPC
import Node
import Sys

func same(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }

/// A setting's value (Taisce's kinds: int64 2, bool 6, string 1).
public enum SettingValue: Equatable, Sendable {
  case int(Int64)
  case bool(Bool)
  case string(String)

  public static func == (a: SettingValue, b: SettingValue) -> Bool {
    switch (a, b) {
    case (.int(let x), .int(let y)): return x == y
    case (.bool(let x), .bool(let y)): return x == y
    case (.string(let x), .string(let y)): return same(x, y)
    default: return false
    }
  }

  public init?(_ a: FsIPC.Attribute) {
    switch a.kind {
    case 2 where a.value.count == 8:
      var u: UInt64 = 0
      for i in 0..<8 { u |= UInt64(a.value[i]) << (8 * UInt64(i)) }
      self = .int(Int64(bitPattern: u))
    case 6 where a.value.count == 1: self = .bool(a.value[0] != 0)
    case 1: self = .string(String(decoding: a.value, as: UTF8.self))
    default: return nil
    }
  }

  public init?(_ a: NodeIPC.Attribute) { self.init(FsIPC.Attribute(name: a.name, kind: a.kind, value: a.value)) }

  public func attribute(_ name: String) -> FsIPC.Attribute {
    switch self {
    case .int(let v):
      let u = UInt64(bitPattern: v)
      var b: [UInt8] = []
      for i in 0..<8 { b.append(UInt8(truncatingIfNeeded: u >> (8 * UInt64(i)))) }
      return FsIPC.Attribute(name: name, kind: 2, value: b)
    case .bool(let v): return FsIPC.Attribute(name: name, kind: 6, value: [v ? 1 : 0])
    case .string(let s): return FsIPC.Attribute(name: name, kind: 1, value: Array(s.utf8))
    }
  }

  public var int: Int64? {
    if case .int(let v) = self { return v }
    return nil
  }
  public var bool: Bool? {
    if case .bool(let v) = self { return v }
    return nil
  }
  public var string: String? {
    if case .string(let v) = self { return v }
    return nil
  }
}

/// A setting: its area (the file), name (the attribute), default, and
/// what it may be.
public struct Setting: Sendable {
  public var area: String
  public var name: String
  public var label: String
  public var fallback: SettingValue
  /// For an int, its range; for a string, its choices (none: any).
  public var range: (Int64, Int64)?
  public var choices: [String]

  public init(_ area: String, _ name: String, _ label: String, _ fallback: SettingValue, range: (Int64, Int64)? = nil,
              choices: [String] = [])
  {
    self.area = area
    self.name = name
    self.label = label
    self.fallback = fallback
    self.range = range
    self.choices = choices
  }

  /// A value it may take: the default otherwise (out of range, or another
  /// kind).
  public func accept(_ v: SettingValue?) -> SettingValue {
    guard let v else { return fallback }
    switch (v, fallback) {
    case (.int(let x), .int):
      if let r = range { return x >= r.0 && x <= r.1 ? v : fallback }
      return v
    case (.bool, .bool): return v
    case (.string(let s), .string): return choices.isEmpty || choices.contains(where: { same($0, s) }) ? v : fallback
    default: return fallback
    }
  }
}

public enum Settings {
  /// Where they live, in a namespace that mounts the volume at /data.
  public static let folder = "/data/Settings"

  public static let theme = Setting("Appearance", "Appearance:Theme", "Theme", .string("platinum-indigo"),
                                    choices: ["platinum-indigo", "neon-tab"])
  public static let repeatDelay = Setting("Keyboard", "Keyboard:RepeatDelay", "Repeat after (ms)", .int(500),
                                          range: (150, 2000))
  public static let repeatRate = Setting("Keyboard", "Keyboard:RepeatRate", "Repeats a second", .int(30), range: (2, 60))
  public static let pointerSpeed = Setting("Mouse", "Mouse:Speed", "Pointer speed", .int(5), range: (1, 10))
  public static let clock24 = Setting("Deskbar", "Deskbar:Clock24", "24-hour clock", .bool(true))
  public static let gauges = Setting("Deskbar", "Deskbar:Gauges", "Gauges", .bool(true))

  /// Every setting, by area, in Settings' order.
  public static let all = [theme, repeatDelay, repeatRate, pointerSpeed, clock24, gauges]
  public static let areas = ["Appearance", "Keyboard", "Mouse", "Deskbar"]

  /// An area's file's attributes (none if it isn't there), as values.
  public static func read(_ area: String, _ ns: Namespace) -> [(name: String, value: SettingValue)] {
    guard var n = try? ns.open(folder + "/" + area), let st = try? n.stat(fields: NodeIPC.Fields.attributes) else {
      return []
    }
    var out: [(name: String, value: SettingValue)] = []
    for a in st.attributes {
      if let v = SettingValue(a) { out.append((a.name, v)) }
    }
    return out
  }

  /// A setting's value now (its default if unset or out of range).
  public static func value(_ s: Setting, _ ns: Namespace) -> SettingValue {
    s.accept(read(s.area, ns).first { same($0.name, s.name) }?.value)
  }

  /// Sets one: its folder and file made if need be. Whether it could.
  public static func set(_ s: Setting, _ v: SettingValue, _ ns: Namespace) -> Bool {
    write(s.area, s.accept(v).attribute(s.name), ns)
  }

  /// Writes an attribute of area `area`'s file, made if need be.
  static func write(_ area: String, _ a: FsIPC.Attribute, _ ns: Namespace) -> Bool {
    guard let ch = try? ns.connect("/data") else { return false }
    var data = FsIPC.DirectoryClient(channel: ch)
    if (try? data.directory("Settings")) == nil { _ = try? data.makeDirectory("Settings") }
    guard var dir = try? data.directory("Settings") else { return false }
    if (try? dir.file(area)) == nil { _ = try? dir.makeFile(area) }
    guard var f = try? dir.file(area) else { return false }
    return (try? f.setAttribute(a)) != nil
  }

  /// Whether a change the folder's watch reports touches `area`: its file
  /// made or removed (the area's name), one of its attributes set or
  /// removed (the attribute's name, `Area:Name`), or changes missed (look
  /// again).
  public static func touches(_ c: NodeIPC.Change, _ area: String) -> Bool {
    c.kind == .overflow || c.name.isEmpty || same(c.name, area) || c.name.utf8.starts(with: (area + ":").utf8)
  }

  /// A watch on the folder (made if need be): its channel's `changed`
  /// events name the area's file or the attribute changed (`touches`).
  /// nil if there's no volume.
  public static func watch(_ ns: Namespace) -> NodeIPC.NodeClient? {
    if let ch = try? ns.connect("/data") {
      var data = FsIPC.DirectoryClient(channel: ch)
      if (try? data.directory("Settings")) == nil { _ = try? data.makeDirectory("Settings") }
    }
    guard var n = try? ns.open(folder), (try? n.watch(since: 0)) != nil else { return nil }
    return n
  }
}

/// D111's recorded grants for gated services: asked through the trusted
/// prompt and kept as `Grants:APP.SERVICE` bools in /data/Settings/Grants.
/// Settings and rc's `attr` list and revoke them; revoking removes the
/// attribute, waking any watcher on Grants so channels opened under it
/// close.
public enum Grants {
  public static let area = "Grants"

  /// A recorded grant in `/data/Settings/Grants`.
  public struct Entry: Equatable, Sendable {
    public var app: String
    public var service: String
    public var allowed: Bool

    public init(app: String, service: String, allowed: Bool) {
      self.app = app
      self.service = service
      self.allowed = allowed
    }

    public static func == (a: Entry, b: Entry) -> Bool {
      same(a.app, b.app) && same(a.service, b.service) && a.allowed == b.allowed
    }
  }

  public static func name(_ app: String, _ service: String) -> String { area + ":" + app + "." + service }

  /// The recorded answer; nil if the user hasn't recorded one.
  public static func recorded(_ app: String, _ service: String, _ ns: Namespace) -> Bool? {
    let key = name(app, service)
    guard case .bool(let b)? = Settings.read(area, ns).first(where: { same($0.name, key) })?.value else {
      return nil
    }
    return b
  }

  /// Keeps the user's answer. Whether it could.
  @discardableResult
  public static func record(_ app: String, _ service: String, _ yes: Bool, _ ns: Namespace) -> Bool {
    Settings.write(area, SettingValue.bool(yes).attribute(name(app, service)), ns)
  }

  /// Every recorded grant on `/data/Settings/Grants`, in attribute order.
  public static func list(_ ns: Namespace) -> [Entry] {
    let prefix = Array((area + ":").utf8)
    var out: [Entry] = []
    for (n, v) in Settings.read(area, ns) {
      guard case .bool(let allowed) = v else { continue }
      let bytes = Array(n.utf8)
      guard bytes.starts(with: prefix) else { continue }
      let rest = Array(bytes.dropFirst(prefix.count))
      guard let dot = rest.lastIndex(of: 0x2E), dot > 0, dot + 1 < rest.count else { continue }
      let app = String(decoding: rest[..<dot], as: UTF8.self)
      let service = String(decoding: rest[(dot + 1)...], as: UTF8.self)
      out.append(Entry(app: app, service: service, allowed: allowed))
    }
    return out
  }

  /// Revokes a recorded grant by removing its `Grants:APP.SERVICE`
  /// attribute. Whether it was there and removed.
  @discardableResult
  public static func revoke(_ app: String, _ service: String, _ ns: Namespace) -> Bool {
    guard let ch = try? ns.connect("/data") else { return false }
    var data = FsIPC.DirectoryClient(channel: ch)
    guard var dir = try? data.directory("Settings"), var f = try? dir.file(area) else { return false }
    return (try? f.removeAttribute(name(app, service))) != nil
  }
}

/// What was opened lately (Be's Recent menus): documents, folders and apps,
/// newest first, ten each, kept as `Recent:Documents`, `Recent:Folders` and
/// `Recent:Apps` strings (a line an item) in /data/Settings/Recent. Tracker
/// notes documents ("TYPE<TAB>PATH") and folders (paths); Deskbar notes
/// apps (services) and shows all three.
public enum Recent {
  public static let area = "Recent"
  public static let documents = "Recent:Documents", folders = "Recent:Folders", apps = "Recent:Apps"
  public static let kept = 10

  /// A list, newest first.
  public static func list(_ name: String, _ ns: Namespace) -> [String] {
    guard case .string(let text)? = Settings.read(area, ns).first(where: { same($0.name, name) })?.value else {
      return []
    }
    return text.utf8.split(separator: 0x0A).map { String(decoding: $0, as: UTF8.self) }
  }

  /// `item` to the front of a list (once), the oldest dropped past ten.
  @discardableResult
  public static func note(_ name: String, _ item: String, _ ns: Namespace) -> Bool {
    var items = list(name, ns).filter { !same($0, item) }
    items.insert(item, at: 0)
    return Settings.write(area, SettingValue.string(items.prefix(kept).joined(separator: "\n")).attribute(name), ns)
  }
}
