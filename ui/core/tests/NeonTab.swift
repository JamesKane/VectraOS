// SPDX-License-Identifier: BSD-3-Clause

// The themes UICore's tests draw in (D109): Neon Tab's file from the tree,
// and its high-contrast variant, which is todhchai's accessible theme.

import FoundationEssentials
import UICore

extension Theme {
  static func tree(_ name: String, variant: String? = nil) -> Theme {
    var dir = #filePath
    for _ in 0..<4 { dir = String(dir[..<dir.lastIndex(of: "/")!]) }  // ui/core/tests/NeonTab.swift
    let installed = { (n: String) -> [UInt8]? in
      (try? Data(contentsOf: URL(filePath: "\(dir)/ui/theme/themes/\(n)"))).map { [UInt8]($0) }
    }
    do { return try Theme.resolve(ThemeStack(theme: name, variant: variant), installed: installed) } catch {
      fatalError(error.text)
    }
  }

  static let neonTab = Theme.tree("neon-tab")
  static let accessible = Theme.tree("neon-tab", variant: "high-contrast")
}

/// Neon Tab's colours under the names todhchai's tests gave its tokens.
struct NeonColors {
  let theme: Theme
  var bg0: UInt32 { theme.color("desk") }
  var bg1: UInt32 { theme.color("chrome") }
  var ink: UInt32 { theme.color("ink") }
  var dim: UInt32 { theme.color("ink.dim") }
  var edge: UInt32 { theme.color("outline") }
  var cyan: UInt32 { theme.color("neon.cyan") }
  var magenta: UInt32 { theme.color("neon.magenta") }
  var amber: UInt32 { theme.color("neon.amber") }
  var phosphor: UInt32 { theme.color("neon.phosphor") }
}

extension Theme {
  var neon: NeonColors { NeonColors(theme: self) }
}
