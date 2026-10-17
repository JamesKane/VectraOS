// SPDX-License-Identifier: BSD-3-Clause

// fontgen: the console's fonts as a Swift table (text/fonts/gen).
//
//   .build/debug/fontgen services/console/lib/generated/Spleen.swift data/fonts/spleen
//
// It reads spleen-8x16.bdf and spleen-16x32.bdf from the directory.

import FontGen
import Foundation

let args = CommandLine.arguments
guard args.count == 3 else {
  FileHandle.standardError.write(Data("usage: fontgen OUTPUT.swift data/fonts/spleen\n".utf8))
  exit(2)
}
let dir = args[2]
do {
  let fonts = try [("spleen8x16", "spleen-8x16.bdf"), ("spleen16x32", "spleen-16x32.bdf")].map { name, file in
    (name: name, font: try BDFFont(bdf: String(contentsOfFile: "\(dir)/\(file)", encoding: .utf8)))
  }
  let text = swiftTable(fonts, spdx: "BSD-2-Clause", notice: spleenNotice)
  try text.write(toFile: args[1], atomically: true, encoding: .utf8)
  print("fontgen: \(fonts.map { "\($0.name) \($0.font.glyphs.count) glyphs" }.joined(separator: ", "))")
} catch {
  FileHandle.standardError.write(Data("fontgen: \(error)\n".utf8))
  exit(1)
}
