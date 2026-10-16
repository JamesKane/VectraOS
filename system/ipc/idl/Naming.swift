// SPDX-License-Identifier: BSD-3-Clause

import IPCModel

/// "noteLoudly" → "note_loudly"; "EchoError" → "echo_error"; "TestIPC" →
/// "test_ipc" (a run of capitals is one word).
func snakeCase(_ name: String) -> String {
  let chars = Array(name)
  var out = ""
  for (i, c) in chars.enumerated() {
    if c.isUppercase {
      let previousLower = i > 0 && !chars[i - 1].isUppercase && chars[i - 1] != "_"
      let nextLower = i + 1 < chars.count && chars[i + 1].isLowercase
      let previousUpper = i > 0 && chars[i - 1].isUppercase
      if i > 0 && (previousLower || (previousUpper && nextLower)) { out += "_" }
      out += c.lowercased()
    } else {
      out.append(c)
    }
  }
  return out
}

func hex(_ value: UInt64) -> String { "0x" + String(value, radix: 16) }

/// The file name (without extension) idlc gives a library's C header.
public func snakeName(_ l: LibraryModel) -> String { snakeCase(l.name) }
