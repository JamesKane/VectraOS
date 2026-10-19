// SPDX-License-Identifier: BSD-3-Clause

// vx theme check: theme check on the dev machine (D109, theming.md §7),
// the device's code. Each argument is a theme of ui/theme/themes by name,
// or a theme file by path, which may inherit from the tree's themes; with
// none, the base and every theme in the tree. `--layer FILE` puts a layer
// over each (several stack in order).

import FoundationEssentials
import Themes

let themesDirectory = "ui/theme/themes"

func themeCommand(_ args: [String]) -> Bool {
  guard args.first == "check" else { fail("usage: vx theme check [THEME|FILE]... [--layer FILE]...") }
  var names: [String] = []
  var files: [String: [UInt8]] = [:]
  var layers: [ThemeLayer] = []
  var rest = args.dropFirst()
  while let a = rest.popFirst() {
    if a == "--layer" {
      guard let path = rest.popFirst() else { fail("--layer needs a file") }
      guard let data = FileManager.default.contents(atPath: path) else { fail("can't read \(path)") }
      layers.append(ThemeLayer(label: path, text: [UInt8](data)))
    } else if a.contains("/") || FileManager.default.fileExists(atPath: a) {
      guard let data = FileManager.default.contents(atPath: a) else { fail("can't read \(a)") }
      let bytes = [UInt8](data)
      let name: String
      do { name = try ThemeFile(parsing: bytes, label: a).name ?? "" } catch { fail(error.text) }
      guard !name.isEmpty else { fail("\(a) has no theme= record: it's a layer (--layer)") }
      files[name] = bytes
      names.append(name)
    } else {
      names.append(a)
    }
  }
  if names.isEmpty {
    let listing = (try? FileManager.default.contentsOfDirectory(atPath: themesDirectory)) ?? []
    names = ["base"] + listing.filter { !$0.hasPrefix(".") }.sorted()
  }
  let installed = { (name: String) -> [UInt8]? in
    files[name] ?? FileManager.default.contents(atPath: "\(themesDirectory)/\(name)").map { [UInt8]($0) }
  }
  var ok = true
  for name in names {
    let findings = ThemeCheck.check(name, layers: layers, installed: installed)
    if findings.isEmpty {
      say("\(name): ok")
    } else {
      for f in findings { complain(f) }
      ok = false
    }
  }
  return ok
}
