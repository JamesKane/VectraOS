// SPDX-License-Identifier: BSD-3-Clause

// A large folder (the file browser's criterion, 100k entries listed and
// sorted warm in under 100 ms): made, then listed with the list view's
// columns and sorted by name, twice, the second timed.
// TODHCHAI_TRACKER_ENTRIES=N makes N (2,000 by default);
// TODHCHAI_TRACKER_LISTS=N lists it N times (2), for a profile.

import Fs
import Glibc
import IPC
import Node
import Sys
import Testing
@testable import Tracker

@Test func aLargeFolderIsListedAndSorted() throws {
  let n = Int(String(cString: getenv("TODHCHAI_TRACKER_ENTRIES") ?? strdup("2000"))) ?? 2000
  let rig = try Rig(blocks: 1 << 18)
  defer { rig.stop() }
  let v = try rig.volume()
  _ = try v.makeFolder(in: "", named: "big")
  let t0 = Clock.monotonic()
  for i in 0..<n { _ = try v.makeFile(in: "big", named: "file \(String(i * 7919 % n)).txt") }
  let made = Clock.monotonic() - t0
  print("large folder: fs " + rig.service.status.split(separator: "\n").filter { $0.hasPrefix("blocks") }.joined())
  var times: [Int64] = []
  var count = 0
  let lists = max(2, Int(String(cString: getenv("TODHCHAI_TRACKER_LISTS") ?? strdup("2"))) ?? 2)
  for _ in 0..<lists {
    let start = Clock.monotonic()
    var folder = Folder(path: "big", sort: SortOrder())
    var listing = try v.list("big", columns: FolderState.defaultColumns)
    while !listing.done { folder.add(try listing.next()) }
    let listed = Clock.monotonic()
    count = folder.ordered().count
    times.append(Clock.monotonic() - start)
    print("large folder: listed in \((listed - start) / 1_000_000) ms, sorted in \((Clock.monotonic() - listed) / 1_000_000) ms")
  }
  print("large folder: \(n) made in \(made / 1_000_000) ms; listed and sorted in \(times[0] / 1_000_000) ms,"
    + " warm \(times[times.count - 1] / 1_000_000) ms")
  #expect(count == n)
}

/// The keyed sort (made once per entry) orders as the full comparison
/// does: names differing only in case, accents, folders, sizes, values
/// missing, mixed kinds, descending.
@Test func theKeyedSortOrdersAsTheFullComparison() {
  let names = ["b", "B", "a", "A", "Ábhar", "abhar", "zeta", "Zeta", "10", "9", "file 2", "File 10", "é", "e", "E"]
  var entries: [Entry] = []
  for (i, n) in names.enumerated() {
    var attributes: [String: AttributeValue] = [:]
    if i % 3 != 0 { attributes["Audio:Artist"] = .string(names[(i * 7) % names.count]) }
    if i % 4 != 0 { attributes["Audio:Year"] = .int(Int64(1990 + i % 5)) }
    if i == 5 { attributes["Mixed"] = .int(1) } else { attributes["Mixed"] = .string("x") }
    entries.append(Entry(name: n, node: UInt64(i + 1), isDirectory: i % 5 == 0, size: UInt64(i % 4) * 100,
                         modified: Int64(i % 3), attributes: attributes))
  }
  for column in [Column.name, Column.size, Column.modified, Column.type, "Audio:Artist", "Audio:Year", "Mixed"] {
    for descending in [false, true] {
      let s = SortOrder(column, descending: descending)
      var folder = Folder(path: "", sort: s)
      folder.add(entries)
      let full = entries.sorted { Folder.before($0, $1, s) }
      #expect(folder.ordered().map(\.node) == full.map(\.node), "\(column) descending \(descending)")
    }
  }
}
