// SPDX-License-Identifier: BSD-3-Clause

// vx trace: reads traces (docs/trace-format.md), and collects the ones a
// guest's TraceSession exported over its console (system/trace/session).
//
//   vx trace collect CONSOLE DIR     the console's td-trace files, as DIR/NAME.trace
//   vx trace print FILE...           every record, merged by time
//   vx trace summary FILE...         zones per name: count, total, p50, p99, max
//   vx trace diff A B                summaries side by side, B against A

import Bench
import FoundationEssentials
import Glibc
import TraceFormat
import TraceReader

func readTrace(_ path: String) -> TraceFile {
  guard let data = FileManager.default.contents(atPath: path) else { fail("can't read \(path)") }
  do {
    return try TraceFile(bytes: [UInt8](data))
  } catch {
    fail("\(path): \(error)")
  }
}

/// Every trace file named, a directory standing for the .trace files in it.
func traceFiles(_ paths: [String]) -> [String] {
  paths.flatMap { path -> [String] in
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return [path] }
    return names.filter { $0.hasSuffix(".trace") }.sorted().map { "\(path)/\($0)" }
  }
}

func traceCommand(_ args: [String]) -> Bool {
  guard let sub = args.first else { fail("usage: vx trace collect|print|summary|diff FILE...") }
  let rest = Array(args.dropFirst())
  switch sub {
  case "collect":
    guard rest.count == 2 else { fail("vx trace collect CONSOLE DIR") }
    guard let data = FileManager.default.contents(atPath: rest[0]) else { fail("can't read \(rest[0])") }
    let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
    switch TraceExport.reassemble(lines) {
    case .success(let files):
      guard !files.isEmpty else { fail("\(rest[0]) carries no traces") }
      try? FileManager.default.removeItem(atPath: rest[1])
      try? FileManager.default.createDirectory(atPath: rest[1], withIntermediateDirectories: true)
      for f in files {
        guard (try? Data(f.bytes).write(to: URL(filePath: "\(rest[1])/\(f.name).trace"))) != nil else {
          fail("can't write \(rest[1])/\(f.name).trace")
        }
      }
      say("vx trace: \(files.count) trace file(s) in \(rest[1]) (vx trace summary \(rest[1]))")
      return true
    case .failure(let damage):
      fail("\(rest[0]): the trace is damaged: \(damage.description)")
    }
  case "print":
    for path in traceFiles(rest) {
      let t = readTrace(path)
      say("# \(path): process \(t.processID), \(t.records.count) records, \(t.dropped) dropped")
      for r in t.records {
        let at = formatValue(t.seconds(r.time &- t.start))
        let what: String = switch TraceKind(rawValue: r.kind) {
        case .zone?: "zone \(t.name(r.b)) \(formatValue(t.seconds(r.a &- r.time)))"
        case .mark?: "mark \(TraceFile.label(r))"
        case .flow?: "flow \(t.name(r.b)) id \(r.a)"
        case .counter?: "counter \(t.name(r.a)) = \(Int64(bitPattern: r.b))"
        case nil: "kind 0x\(String(r.kind, radix: 16)) a \(r.a) b \(r.b)"
        }
        say("\(at)\tthread \(r.tid)\t\(what)")
      }
    }
    return true
  case "summary":
    for path in traceFiles(rest) { say(summary(readTrace(path), title: path)) }
    // A recording on the kernel: its files read as one timeline.
    for dir in rest where FileManager.default.fileExists(atPath: "\(dir)/kernel.trace") {
      say(acrossProcesses(dir))
    }
    return true
  case "diff":
    guard rest.count == 2 else { fail("vx trace diff A B") }
    let a = readTrace(rest[0]).zones(), b = readTrace(rest[1]).zones()
    var out = "| Zone | A p50 | B p50 | A p99 | B p99 | p99 change |\n|---|---:|---:|---:|---:|---:|\n"
    for name in Set(a.keys).union(b.keys).sorted() {
      let da = Distribution(a[name] ?? []), db = Distribution(b[name] ?? [])
      let change = da.p99 > 0 ? "\(Int(((db.p99 - da.p99) / da.p99 * 100).rounded()))%" : "—"
      out += "| `\(name)` | \(formatValue(da.p50)) | \(formatValue(db.p50)) | \(formatValue(da.p99)) | \(formatValue(db.p99)) | \(change) |\n"
    }
    say(out)
    return true
  default:
    fail("unknown trace command \(sub)")
  }
}

func summary(_ t: TraceFile, title: String) -> String {
  var out = "# \(title)\n\n| Zone | Count | Total | p50 | p99 | Max |\n|---|---:|---:|---:|---:|---:|\n"
  for (name, durations) in t.zones().sorted(by: { $0.key < $1.key }) {
    let d = Distribution(durations)
    out += "| `\(name)` | \(d.count) | \(formatValue(d.total)) | \(formatValue(d.p50)) | \(formatValue(d.p99)) | \(formatValue(d.max)) |\n"
  }
  let flows = t.flows()
  if !flows.isEmpty {
    // A flow's span is its first step to its last: for an IPC call, the
    // call's write to its reply's read.
    out += "\n| Flow | Count | Steps | p50 | p99 | Max |\n|---|---:|---:|---:|---:|---:|\n"
    for (name, spans) in flows.sorted(by: { $0.key < $1.key }) {
      let d = Distribution(spans.map(\.seconds))
      let steps = Set(spans.map(\.steps)).sorted().map(String.init).joined(separator: ", ")
      out += "| `\(name)` | \(d.count) | \(steps) | \(formatValue(d.p50)) | \(formatValue(d.p99)) | \(formatValue(d.max)) |\n"
    }
  }
  if t.dropped > 0 { out += "\n\(t.dropped) records dropped: the rings were full.\n" }
  return out
}

/// A croi recording's directory (kernel.trace and N-process.trace files,
/// system/trace/session) as one timeline: each call's path through both ends
/// and croi, with the median time to each step.
func acrossProcesses(_ dir: String) -> String {
  let files = traceFiles([dir]).map { path -> (name: String, trace: TraceFile) in
    var name = String(path.split(separator: "/").last!.dropLast(".trace".count))
    if let dash = name.firstIndex(of: "-"), name[..<dash].allSatisfy(\.isNumber) { name = String(name[name.index(after: dash)...]) }
    return (name, readTrace(path))
  }
  let set = TraceSet(files)
  var out = "# \(dir): calls across processes and croi\n\n"
  out += "Each call's commonest path, with the median time from the step before to each step.\n\n"
  out += "| Flow | Count | p50 | Path |\n|---|---:|---:|---|\n"
  for b in set.breakdown() {
    var path = b.path.first ?? ""
    for (i, step) in b.path.dropFirst().enumerated() { path += " →\(formatValue(b.gaps[i])) \(step)" }
    out += "| `\(b.name)` | \(b.count) | \(formatValue(b.total)) | \(path) |\n"
  }
  return out
}
