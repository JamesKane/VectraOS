// SPDX-License-Identifier: BSD-3-Clause

// lightgen: Light's tables from the sRGB formula (ui/light/gen, D110).
//
//   .build/debug/lightgen ui/light/lib/Tables.swift

import Foundation
import LightGen

let args = CommandLine.arguments
guard args.count == 2 else {
  FileHandle.standardError.write(Data("usage: lightgen OUTPUT.swift\n".utf8))
  exit(2)
}
do {
  let t = try tables()
  try swiftTables(t).write(toFile: args[1], atomically: true, encoding: .utf8)
  print("lightgen: \(t.decode.count) bytes decoded, \(t.encode.count) levels encoded, \(contrastSteps) contrast curves")
} catch {
  FileHandle.standardError.write(Data("lightgen: \(error)\n".utf8))
  exit(1)
}
