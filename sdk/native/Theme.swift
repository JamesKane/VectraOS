// SPDX-License-Identifier: BSD-3-Clause

// The theme in force (D91): Radharc keeps it resolved, one wire message in
// read-only memory at `theme/resolved`, which a program maps and reads its
// Theme from without parsing a theme file. A change is a line on
// `theme/events`, whose read waits; the loop reads it on a thread of its
// own, as it reads the plumber's ports, and hands each change to the loop
// as a `.themeChanged` event, after which `theme()` maps the new one.

import IPC
import Node
import Radharc
import Sys
import Themes

extension Loop {
  static let themePath = "/svc/windows/theme"

  /// The theme Radharc has in force, mapped now; nil without Radharc.
  public func theme() -> Theme? {
    guard let ns = NativeProcess.namespace,
      let memory = try? ns.memory(Self.themePath + "/resolved", executable: false),
      let m = try? VMO.map(memory.vmo, length: (Int(memory.size) + 4095) & ~4095, writable: false),
      let wire = RadharcIPC.ResolvedTheme(decoding: m.read(at: 0, count: Int(memory.size)))
    else { return nil }
    return Theme(wire)
  }

  /// Follows the theme: each change from now on comes as a `.themeChanged`
  /// event. False without Radharc; following twice is following once.
  @discardableResult
  public mutating func followTheme() -> Bool {
    if followingTheme { return true }
    guard let ns = NativeProcess.namespace, let events = try? ns.open(Self.themePath + "/events") else { return false }
    let raw = events.takeConnection().takeChannel().release()
    let shared = self.shared
    do {
      _ = try Sys.Thread.spawn {
        var file = NodeIPC.NodeClient(channel: Handle(raw: raw))
        while let bytes = try? file.read(offset: 0, max: 4096) {
          // A line a change, `theme ... generation G`; a refusal changes
          // nothing.
          var changed = false
          var generation: UInt64 = 0
          for line in bytes.split(separator: 0x0A) where line.starts(with: Array("theme ".utf8)) {
            changed = true
            let words = line.split(separator: 0x20)
            if let i = words.firstIndex(where: { $0.elementsEqual("generation".utf8) }), i + 1 < words.count {
              generation = words[i + 1].reduce(0) { $1 >= 0x30 && $1 <= 0x39 ? $0 &* 10 &+ UInt64($1 - 0x30) : $0 }
            }
          }
          if changed { shared.themeChange(generation: generation) }
        }
      }
    } catch {
      _ = Handle(raw: raw)
      return false
    }
    followingTheme = true
    return true
  }
}
