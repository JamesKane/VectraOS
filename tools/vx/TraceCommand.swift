// SPDX-License-Identifier: BSD-3-Clause

// vx trace: reads traces (docs/trace-format.md), and collects the ones a
// guest's TraceSession exported over its console (system/trace/session).
//
//   vx trace collect CONSOLE DIR     the console's td-trace files, as DIR/NAME.trace
//   vx trace print FILE...           every record, merged by time
//   vx trace summary FILE...         zones per name: count, total, p50, p99, max
//   vx trace diff A B                summaries side by side, B against A
//   vx trace profile DIR [ARCH] [--kernel FILE] [--bootfs FILE] [--push NAME=FILE] [--top N] [--folded]
//                                    a node's samples (trace(8)'s DIR), by process and function

import Bench
import FoundationEssentials
import Glibc
import ImageFormats
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
  guard let sub = args.first else { fail("usage: vx trace collect|print|summary|diff|profile FILE...") }
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
        // Nanoseconds since the recording's start: a record's time to the
        // counter's resolution, so gaps under a millisecond show.
        let at = "\(Int64(t.seconds(r.time &- t.start) * 1e9)) ns"
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
  case "profile":
    return profileCommand(rest)
  default:
    fail("unknown trace command \(sub)")
  }
}

private let profileUsage =
  "usage: vx trace profile DIR [ARCH] [--kernel FILE] [--bootfs FILE] [--push NAME=FILE] [--top N] [--folded]"

/// vx trace profile: DIR's kernel.trace and procs (trace(8)'s), named from
/// the build's kernel and cpu bootfs (ARCH's, amd64's by default) unless
/// given others.
func profileCommand(_ args: [String]) -> Bool {
  var dir: String?, arch: String?, kernel: String?, bootfs: String?
  var pushed: [String: String] = [:]
  var top = 40, folded = false
  var rest = args[...]
  func value() -> String {
    guard let v = rest.popFirst() else { fail(profileUsage) }
    return v
  }
  while let a = rest.popFirst() {
    switch a {
    case "--kernel": kernel = value()
    case "--bootfs": bootfs = value()
    case "--push":
      let v = value()
      guard let eq = v.firstIndex(of: "=") else { fail(profileUsage) }
      pushed[String(v[..<eq])] = String(v[v.index(after: eq)...])
    case "--top":
      guard let n = Int(value()), n > 0 else { fail(profileUsage) }
      top = n
    case "--folded": folded = true
    default:
      guard !a.hasPrefix("-") else { fail(profileUsage) }
      if dir == nil { dir = a } else if arch == nil, allArches.contains(a) { arch = a } else { fail(profileUsage) }
    }
  }
  guard let dir else { fail(profileUsage) }
  let target = arch ?? "amd64"
  let kernelPath = kernel ?? "build/\(target)/kernel/kernel.elf"
  let bootfsPath = bootfs ?? "build/\(target)/bootfs-cpu.img"
  guard let procs = FileManager.default.contents(atPath: "\(dir)/procs") else { fail("can't read \(dir)/procs") }
  let trace = readTrace("\(dir)/kernel.trace")
  func bytes(_ path: String) -> [UInt8]? { FileManager.default.contents(atPath: path).map { [UInt8]($0) } }
  let kernelELF = bytes(kernelPath), image = bytes(bootfsPath)
  if kernelELF == nil { complain("vx trace: no \(kernelPath): the kernel's addresses go unnamed (--kernel)") }
  if image == nil { complain("vx trace: no \(bootfsPath): the programs' addresses go unnamed (--bootfs)") }
  var pushedELFs: [String: [UInt8]] = [:]
  for (name, path) in pushed {
    guard let b = bytes(path) else { fail("can't read \(path)") }
    pushedELFs[name] = b
  }
  let symbolizer = Symbolizer(kernel: kernelELF, bootfs: image, pushed: pushedELFs)
  var names: [String: String] = [:]
  let profile = Profile(trace: trace, processes: ProcessTable(text: String(decoding: procs, as: UTF8.self))) { at, ret in
    guard let s = symbolizer.symbol(image: at.image, offset: at.offset, returnAddress: ret) else { return nil }
    if names[s.function] == nil { names[s.function] = demangled(s.function) }
    return Profile.Frame(function: names[s.function]!, image: s.image)
  }
  if folded {
    for f in profile.folded { say("\(f.stack) \(f.count)") }
    return true
  }
  say(profileReport(profile, title: dir, top: top))
  return true
}

func profileReport(_ p: Profile, title: String, top: Int) -> String {
  func share(_ n: Int) -> String { p.samples > 0 ? "\(Int((Double(n) * 100 / Double(p.samples)).rounded()))%" : "—" }
  var out = "# \(title): \(p.samples) samples at \(p.hz) Hz\n\n"
  out += "CPU time is samples over the rate: a sample a CPU each 1/\(p.hz) s it ran something.\n\n"
  out += "| Process | Samples | Share | CPU time |\n|---|---:|---:|---:|\n"
  for (name, n) in p.processes {
    out += "| `\(name)` | \(n) | \(share(n)) | \(formatValue(Double(n) / Double(max(p.hz, 1)))) |\n"
  }
  out += "\n| Function | Image | Process | Own | Own % | Inclusive | Inclusive % |\n|---|---|---|---:|---:|---:|---:|\n"
  for c in p.functions.prefix(top) {
    out += "| `\(c.frame.function)` | \(c.frame.image) | \(c.process) | \(c.own) | \(share(c.own)) | \(c.inclusive) | \(share(c.inclusive)) |\n"
  }
  if p.dropped > 0 { out += "\n\(p.dropped) records dropped: the rings were full (trace(8)'s pages).\n" }
  return out
}

@_silgen_name("swift_demangle")
private func swiftDemangle(_ mangled: UnsafePointer<CChar>?, _ length: Int, _ output: UnsafeMutablePointer<CChar>?,
                           _ outputLength: UnsafeMutablePointer<Int>?, _ flags: UInt32) -> UnsafeMutablePointer<CChar>?

/// A Swift symbol's name, demangled by the Swift runtime, its argument
/// types dropped; any other as it is.
func demangled(_ symbol: String) -> String {
  guard symbol.hasPrefix("$s") || symbol.hasPrefix("_$s") || symbol.hasPrefix("$e"),  // $e: Embedded Swift's
    let made = symbol.withCString({ swiftDemangle($0, strlen($0), nil, nil, 0) })
  else { return symbol }
  defer { free(made) }
  return shortened(String(cString: made))
}

/// A demangled name without its signature's types, nor `Swift.` and
/// specialization notes: `IP.receive(_:now:)`.
func shortened(_ name: String) -> String {
  var s = name
  // "… specialization <…> of NAME", as often as it is one of another.
  while ["generic specialization <", "function signature specialization <"].contains(where: { s.hasPrefix($0) }),
    let of = s.firstRange(of: "> of ")
  {
    s = String(s[of.upperBound...])
  }
  if s.hasPrefix("merged ") { s = String(s.dropFirst(7)) }
  // "(extension in IPC):IPCWire.Decoder" to "IPCWire.Decoder"; a private
  // name, "(objectCall in _F6500A8C)", to "objectCall".
  s = s.replacing(/\(extension in [^)]*\):/, with: "")
  s = s.replacing(/\((\w+) in _[0-9A-F]+\)/) { String($0.output.1) }
  // Arguments' labels kept, their types dropped, an unlabeled one `_`:
  // "(IP.Proto, Swift.Int, now: Swift.Int64) -> ()" to "(_:_:now:)".
  var out = "", depth = 0, nest = 0, angle = 0, label = ""
  var named = false, any = false  // the argument so far: labeled, or anything at all
  func endArgument() {
    if any && !named { out += "_:" }
    (named, any, label) = (false, false, "")
  }
  var i = s.startIndex
  while i < s.endIndex {
    let c = s[i]
    if depth == 0, c == "<" || angle > 0 {
      // A generic's parameters: `locked<A, B where B: Error>` to `locked`.
      if c == "<" { angle += 1 } else if c == ">" { angle -= 1 }
    } else if c == "(" {
      if depth == 0 { out += "("; (named, any, label) = (false, false, "") } else { any = true }
      depth += 1
    } else if c == ")" {
      depth -= 1
      if depth == 0 {
        endArgument()
        out += ")"
        // Drop the result type: up to " in " (a closure's context) or the end.
        let after = s[s.index(after: i)...]
        if let inAt = after.firstRange(of: " in ") { out += " in "; i = inAt.upperBound; continue }
        break
      }
    } else if depth == 1 {
      if c == "[" || c == "<" {
        nest += 1
        any = true
      } else if c == "]" || c == ">", nest > 0 {
        nest -= 1
      } else if nest > 0 {
      } else if c == ":", !named, !label.isEmpty {
        out += label + ":"
        named = true
      } else if c == "," {
        endArgument()
      } else if c == " " {
        label = ""
      } else {
        label.append(c)
        any = true
      }
    } else if depth == 0 {
      out.append(c)
    }
    i = s.index(after: i)
  }
  // What is left of a specialization or a thunk inside the name says
  // nothing a reader needs.
  for note in ["generic specialization  of ", "function signature specialization  of ", "partial apply forwarder for ",
               "@Sendable ", "Swift."] {
    out = out.replacing(note, with: "")
  }
  return out
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
