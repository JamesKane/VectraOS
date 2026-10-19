// SPDX-License-Identifier: BSD-3-Clause

// iconsgen: the storyboard's icons as UICore's table (ui/icons/gen).
//
//   .build/debug/iconsgen ui/core/lib/generated/IconSheet.swift docs/design/shell-storyboard.html

import Foundation
import IconGen

let args = CommandLine.arguments
guard args.count == 3 else {
  FileHandle.standardError.write(Data("usage: iconsgen OUTPUT.swift docs/design/shell-storyboard.html\n".utf8))
  exit(2)
}
do {
  let icons = try readIcons(storyboard: String(contentsOfFile: args[2], encoding: .utf8))
  try swiftTable(icons).write(toFile: args[1], atomically: true, encoding: .utf8)
  print("iconsgen: \(icons.count) icons, \(icons.reduce(0) { $0 + $1.elements.count }) elements")
} catch {
  FileHandle.standardError.write(Data("iconsgen: \(error)\n".utf8))
  exit(1)
}
