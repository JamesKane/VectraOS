// SPDX-License-Identifier: BSD-3-Clause

// The Inspector (inspector(4), D115; desktop.md's system visibility):
// every process proc(4) serves, a row each in Tracker's table: its name,
// its state, its CPU share over the last reading, its memory and its pid.
// It is what Plan 9's `ps` lists, kept current. Its host reads /proc once
// a second while someone is at the desktop and hands it the status lines;
// while nobody is, it says it's paused.

import Kit
import UICore

/// A process, as its /proc/<pid>/status gives it.
public struct ProcLine: Equatable, Sendable {
  public var pid: UInt64
  public var name: String
  public var state: String
  /// Milliseconds on a CPU, all told.
  public var milliseconds: UInt64
  public var kib: UInt64

  public init(pid: UInt64, name: String, state: String, milliseconds: UInt64, kib: UInt64) {
    self.pid = pid
    self.name = name
    self.state = state
    self.milliseconds = milliseconds
    self.kib = kib
  }

  /// Plan 9's status line: the name, user and state, then nine numbers.
  /// Read from the right, so a name with spaces or past its column reads
  /// whole.
  public static func parse(pid: UInt64, _ text: String) -> ProcLine? {
    let w = text.split(whereSeparator: { $0 == " " || $0.isNewline }).map(String.init)
    guard w.count >= 12 else { return nil }
    let n = w.suffix(9).compactMap { UInt64($0) }
    guard n.count == 9 else { return nil }
    let state = w[w.count - 10]
    let name = w[..<(w.count - 11)].joined(separator: " ")
    return ProcLine(pid: pid, name: name, state: state, milliseconds: n[0], kib: n[6])
  }
}

@MainActor public final class Inspector: App {
  public private(set) var processes: [ProcLine] = []
  /// Each process's CPU share over the last interval (0 to 1, all CPUs'
  /// time counting as one), by pid.
  public private(set) var cpuShare: [UInt64: Float] = [:]
  public var selected: UInt64?
  /// Nobody at the desktop: the host doesn't read.
  public var paused = false
  var last: (at: Int64, ms: [UInt64: UInt64])?
  var none = ""

  public init() {}

  public var title: String { "Inspector" }

  /// A reading: every process's status, and when it was read (ns).
  public func update(_ lines: [ProcLine], at now: Int64) {
    var ms: [UInt64: UInt64] = [:]
    for p in lines { ms[p.pid] = p.milliseconds }
    if let l = last, now > l.at {
      var share: [UInt64: Float] = [:]
      for (k, m) in ms {
        guard let before = l.ms[k], m >= before else { continue }
        share[k] = max(0, min(1, Float(m - before) * 1_000_000 / Float(now - l.at)))
      }
      cpuShare = share
    }
    last = (now, ms)
    processes = lines.sorted { $0.pid < $1.pid }
    if let s = selected, !processes.contains(where: { $0.pid == s }) { selected = nil }
  }

  /// A row's cells: Name, State, CPU, Memory, PID.
  public func cells(_ p: ProcLine) -> [String] {
    let share = cpuShare[p.pid].map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
    return [p.name, p.state, share, Self.size(p.kib << 10), "\(p.pid)"]
  }

  static func size(_ b: UInt64) -> String {
    if b < 1024 { return "\(b) B" }
    if b < 1 << 20 { return "\(b >> 10) KiB" }
    let tenths = (b * 10 + (1 << 19)) >> 20
    return "\(tenths / 10).\(tenths % 10) MiB"
  }

  public var counts: String {
    let kib = processes.reduce(UInt64(0)) { $0 + $1.kib }
    return "\(processes.count) processes · \(Self.size(kib << 10))"
  }

  /// Control-Q: the host ends it.
  public var onQuit: (() -> Void)?

  public var actions: [ActionHandler] {
    func ctrl(_ c: Character) -> KeyPress { KeyPress(.character(c.unicodeScalars.first!.value), control: true) }
    return [ActionHandler(Action("inspector.quit", label: "Quit Inspector", key: ctrl("q"))) { [self] _ in onQuit?() }]
  }

  public var body: Group {
    VStack(width: .percent(1), height: .percent(1)) {
      MenuBar([MenuSpec("Inspector", ["inspector.quit"])])
      InspectorTable(app: self)
      HStack(class: "status", width: .percent(1)) {
        Text(counts, class: "status")
        Spacer()
        Text(paused ? "paused: nobody at the desktop" : "/proc · once a second", class: "status")
      }
    }
  }
}

struct InspectorTable: View {
  let app: Inspector

  @MainActor func build(_ c: inout BuildContext, id: String) {
    let a = app
    let rows = a.processes
    let cq = Theme.cqw
    let columns = ["Name", "State", "CPU", "Memory", "PID"]
    var widths: [Float] = [0, cq(8), cq(6), cq(7), cq(6)]
    widths[0] = max(cq(14), c.ui.width - widths.dropFirst().reduce(0, +))
    let events = c.ui.table("processes", label: "Processes", count: rows.count, rowHeight: cq(1.7), columns: columns,
                            widths: widths, numeric: [false, false, true, true, true], editText: &a.none) { r in
      let p = rows[r]
      return TableRow(cells: a.cells(p), state: a.selected == p.pid ? "selected" : "")
    }
    for (r, s) in events.rows where r < rows.count && s.pressed { a.selected = rows[r].pid }
  }
}
