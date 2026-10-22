// SPDX-License-Identifier: BSD-3-Clause

// bin/chords (D116): the desktop's chords. It holds Radharc's gated
// `shortcuts` (the user is asked once, on Radharc's prompt), registers
// each chord in the map (ChordMap: Settings' `Chords`, or the defaults),
// and on a press writes the chord's action to /svc/windows/ctl, so a
// script does whatever a chord does. A change to the map ends it, and the
// launcher starts it again on the new one. Refused, or revoked, it ends
// without failing and isn't restarted.

import IPC
import Node
import Radharc
import Settings
import Sys

/// The map as Settings keeps it now.
func readMap(_ ns: Namespace) -> [(key: ChordKey, chord: String, action: String)] {
  var attributes: [(name: String, action: String)] = []
  for (name, value) in Settings.read(ChordMap.area, ns) {
    if case .string(let s) = value { attributes.append((name, s)) }
  }
  return ChordMap.map(attributes)
}

@main struct ChordsService {
  static func main() {
    let start = Startup.current
    let ns: Namespace
    do throws(NamespaceError) { ns = try Namespace(start) } catch {
      print("chords: no namespace")
      Process.exit(code: 2)
    }
    let map = readMap(ns)
    guard let ch = try? ns.connect("/svc/windows/shortcuts") else {
      print("chords: no /svc/windows/shortcuts (its manifest's `grant windows shortcuts`)")
      Process.exit(code: 2)
    }
    var shortcuts = RadharcIPC.ShortcutsClient(channel: ch)
    // The first call waits while the user is asked.
    var ids: [(id: UInt32, action: String)] = []
    for c in map {
      do throws(IPCError<RadharcIPC.WindowError>) {
        let id = try shortcuts.register(RadharcIPC.Chord(code: c.key.code, modifiers: c.key.modifiers))
        ids.append((id, c.action))
      } catch .remote {
        print("chords: \(c.chord) is another's")
      } catch {
        print("chords: refused")
        Process.exit(code: 0)
      }
    }
    print("chords: \(ids.count) chords")
    // The map changed (a change the watch can't name may have touched
    // it: read it again): start again on it.
    let shown = map.map { $0.chord + "=" + $0.action }
    if let watch = Settings.watch(ns) {
      let raw = watch.takeChannel().release()
      _ = try? Thread.spawn {
        var w = NodeIPC.NodeClient(channel: Handle(raw: raw))
        while let e = try? w.nextEvent() {
          guard case .changed(let c) = e, Settings.touches(c, ChordMap.area) else { continue }
          let now = readMap(ns).map { $0.chord + "=" + $0.action }
          guard now.count != shown.count || !zip(now, shown).allSatisfy({ $0.utf8.elementsEqual($1.utf8) }) else { continue }
          print("chords: the map changed")
          Process.exit(code: 1)
        }
      }.release()
    }
    while let e = try? shortcuts.nextEvent() {
      guard case .pressed(let id) = e, let action = ids.first(where: { $0.id == id })?.action else { continue }
      if var ctl = try? ns.open("/svc/windows/ctl"), (try? ctl.writeText(action + "\n")) != nil {
        continue
      }
      print("chords: \(action): refused")
    }
    print("chords: revoked")
    Process.exit(code: 0)
  }
}
