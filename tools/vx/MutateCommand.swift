// SPDX-License-Identifier: BSD-3-Clause

// vx mutate: a suite shown able to fail (D165). Each suite's mutants file
// names edits that each remove a safeguard; this runs the suite on a copy
// of the tree, unchanged (a control) and once for each edit.
//
//   vx mutate --list                 the suites that have a mutants file
//   vx mutate SUITE [NAME ...]       SUITE is the file's directory or its suite's name;
//                                    NAMEs pick the mutants to run

import HostSystem
import Mutate

private let mutateLog = "build/vx/mutate.log"

/// A mutants file in the tree, read.
private struct MutantsSource {
  var path: String
  var directory: String
  var file: MutantsFile
}

/// Every mutants file the tree has (tracked or not yet), read; problems
/// are reported where the file is.
private func mutantsSources(files: [String]) -> (sources: [MutantsSource], problems: [String]) {
  var sources: [MutantsSource] = []
  var problems: [String] = []
  for path in files where path == "mutants" || path.hasSuffix("/mutants") {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
      problems.append("\(path): can't be read")
      continue
    }
    let (file, p) = parseMutants(text, file: path)
    problems += p
    if let file {
      sources.append(MutantsSource(path: path, directory: String(path.dropLast("mutants".count).dropLast(path == "mutants" ? 0 : 1)), file: file))
    }
  }
  return (sources, problems)
}

private func treeFiles() -> [String] {
  (capture(["git", "ls-files", "--cached", "--others", "--exclude-standard"]) ?? "").split(whereSeparator: \.isNewline).map(String.init)
}

/// The suites whose safeguards a change touches: one whose tests or
/// whose mutants' files it changed. Advisory: `vx mutate` isn't in `vx test`.
func suitesAtRisk(changed: [String]) -> [String] {
  let (sources, _) = mutantsSources(files: treeFiles())
  return sources.filter { s in
    changed.contains { c in
      (!s.directory.isEmpty && c.hasPrefix(s.directory + "/")) || s.file.mutants.contains { $0.path == c }
    }
  }.map(\.file.suite)
}

/// Each mutants file's suite is a test target and each edit's file is in
/// the tree (vx test --check).
func mutantsCheck(hostTargets: [String]) -> Bool {
  let files = treeFiles()
  let (sources, problems) = mutantsSources(files: files)
  var bad = problems
  for s in sources {
    if !hostTargets.contains(s.file.suite) { bad.append("\(s.path): suite \(s.file.suite) isn't a test target of Package.swift") }
    for m in s.file.mutants where !files.contains(m.path) {
      bad.append("\(s.path):\(m.line): mutant \(m.name) edits \(m.path), which isn't in the tree")
    }
  }
  for p in bad { complain(p) }
  say("vx: mutants: \(bad.isEmpty ? "ok" : "\(bad.count) problems") (\(sources.count) files)")
  return bad.isEmpty
}

/// Brings the copy at `copy` to the working tree's `files`: what differs
/// is copied, what the tree no longer has is removed. Its own `.build` and
/// the files vx keeps there are left alone.
private func syncCopy(_ copy: String, files: [String]) -> Bool {
  let fm = FileManager.default
  let manifest = copy + "/.vx-mutate-files"
  let extras = ["Package.resolved"].filter { fm.fileExists(atPath: $0) }
  let wanted = files + extras
  let had = ((try? String(contentsOfFile: manifest, encoding: .utf8)) ?? "").split(whereSeparator: \.isNewline).map(String.init)
  let keep = Set(wanted)
  for p in had where !keep.contains(p) { try? fm.removeItem(atPath: copy + "/" + p) }
  var made = Set<String>()
  var listed: [String] = []
  for p in wanted {
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: p, isDirectory: &isDir), !isDir.boolValue else { continue }
    listed.append(p)
    let dst = copy + "/" + p
    if let link = try? fm.destinationOfSymbolicLink(atPath: p) {
      if (try? fm.destinationOfSymbolicLink(atPath: dst)) == link { continue }
      try? fm.removeItem(atPath: dst)
    } else if let a = fm.contents(atPath: p), let b = fm.contents(atPath: dst), a == b {
      continue
    }
    let dir = String(dst.dropLast(dst.split(separator: "/").last!.count + 1))
    if made.insert(dir).inserted { makeDirectory(dir) }
    try? fm.removeItem(atPath: dst)
    do { try fm.copyItem(atPath: p, toPath: dst) } catch {
      complain("copying \(p): \(error)")
      return false
    }
  }
  // The mirror SwiftPM resolves its one dependency through, and what it
  // has fetched, so the copy builds offline.
  for extra in [".swiftpm"] where fm.fileExists(atPath: extra) && !fm.fileExists(atPath: copy + "/" + extra) {
    _ = run(["cp", "-R", extra, copy + "/" + extra], log: nil)
  }
  try? listed.joined(separator: "\n").write(toFile: manifest, atomically: true, encoding: .utf8)
  return true
}

/// The suite run in the copy: how it ended, and its output (colour
/// removed), also appended to the log under `title`.
private func runSuite(_ copy: String, target: String, root: String, title: String) -> (HostTestResult, String) {
  let out = copy + "/.vx-mutate-run"
  unlink(out)
  FileManager.default.changeCurrentDirectoryPath(copy)
  let result = runHostTests(target, log: out)
  FileManager.default.changeCurrentDirectoryPath(root)
  let text = plain((try? String(contentsOfFile: out, encoding: .utf8)) ?? "")
  if let handle = FileHandle(forWritingAtPath: root + "/" + mutateLog) {
    handle.seekToEndOfFile()
    handle.write(Data("==== \(title) ====\n\(text)\n".utf8))
    try? handle.close()
  }
  return (result, text)
}

func mutateCommand(_ args: [String]) -> Bool {
  var list = false
  var names: [String] = []
  for a in args {
    if a == "--list" { list = true } else if a.hasPrefix("-") { fail("unknown option \(a)") } else { names.append(a) }
  }
  let files = treeFiles()
  let (sources, problems) = mutantsSources(files: files)
  for p in problems { complain(p) }
  guard problems.isEmpty else { return false }
  if list {
    for s in sources { say("\(s.file.suite)\t\(s.directory)\t\(s.file.mutants.count) mutants") }
    return true
  }
  guard let wanted = names.first else { fail("usage: vx mutate --list | SUITE [NAME ...]") }
  let key = wanted.hasSuffix("/") ? String(wanted.dropLast()) : wanted
  guard let source = sources.first(where: { $0.file.suite == key || $0.directory == key || $0.path == key }) else {
    fail("no mutants file for \(wanted); vx mutate --list says which suites have one")
  }
  let picked = Array(names.dropFirst())
  for n in picked where !source.file.mutants.contains(where: { $0.name == n }) {
    fail("\(source.file.suite) has no mutant \(n)")
  }
  let mutants = source.file.mutants.filter { picked.isEmpty || picked.contains($0.name) }
  let suite = source.file.suite

  let root = FileManager.default.currentDirectoryPath
  let copy = root + "/build/vx/mutate/" + suite
  makeDirectory(copy)
  makeDirectory("build/vx")
  try? "vx mutate \(suite): the tree at \(treeCommit())\n".write(toFile: mutateLog, atomically: true, encoding: .utf8)
  say("vx: mutate \(suite): copying the tree to build/vx/mutate/\(suite)")
  guard syncCopy(copy, files: files) else { return false }

  var controlMeasure: [String]?
  func control(_ title: String) -> Bool {
    let (r, text) = runSuite(copy, target: suite, root: root, title: title)
    let lines = measureLines(text, prefix: source.file.measure)
    let ok = r.ok
    say("  control  \(ok ? "passed" : "FAILED")  \(oneDecimal(r.seconds)) s" + (ok ? "" : "  \(r.built ? firstFailure(text) : "does not build: " + firstFailure(text))"))
    if !ok {
      complain("the unchanged \(suite) fails, so no mutant's failure would mean anything (see \(mutateLog)); on a busy machine, run it again")
      return false
    }
    if source.file.measure != nil, lines.isEmpty {
      complain("the unchanged \(suite) prints no line starting \"\(source.file.measure!)\"; its measure is empty")
      return false
    }
    if let first = controlMeasure, first != lines {
      complain("the unchanged \(suite)'s measure lines differ between controls; a run's measure isn't stable (see \(mutateLog))")
      return false
    }
    controlMeasure = lines
    return true
  }

  guard control("control") else { return false }
  var clean = true
  var counts: [Ending: Int] = [:]
  for (i, m) in mutants.enumerated() {
    let target = copy + "/" + m.path
    guard let original = try? String(contentsOfFile: target, encoding: .utf8) else {
      say("  \(m.name)  ERROR  \(m.path) can't be read")
      clean = false
      continue
    }
    let edited: String
    switch applyEdit(original, find: m.find, with: m.with) {
    case .failure(.missing):
      say("  \(m.name)  ERROR  its `find` isn't in \(m.path) (\(source.path):\(m.line))")
      clean = false
      continue
    case .failure(.ambiguous(let n)):
      say("  \(m.name)  ERROR  its `find` occurs \(n) times in \(m.path), not once (\(source.path):\(m.line))")
      clean = false
      continue
    case .success(let text): edited = text
    }
    do { try edited.write(toFile: target, atomically: true, encoding: .utf8) } catch {
      say("  \(m.name)  ERROR  \(m.path) can't be written")
      clean = false
      continue
    }
    let (r, text) = runSuite(copy, target: suite, root: root, title: m.name)
    try? original.write(toFile: target, atomically: true, encoding: .utf8)
    if !r.built {
      say("  \(m.name)  ERROR  \(oneDecimal(r.seconds)) s  the edit doesn't build: \(firstFailure(text))")
      clean = false
    } else {
      let ending = classify(
        passed: r.ok, measure: measureLines(text, prefix: source.file.measure), control: controlMeasure ?? [],
        measured: source.file.measure != nil, survives: m.survives)
      counts[ending, default: 0] += 1
      let detail: String
      switch ending {
      case .caught: detail = firstFailure(text)
      case .survivedExplained: detail = m.survives ?? ""
      case .survived: detail = "passed, and nothing says why it may (removes: \(m.why))"
      case .didNothing: detail = "passed with the control's measure lines; the edit changed nothing the suite looks at (removes: \(m.why))"
      }
      say("  \(m.name)  \(ending.rawValue)  \(oneDecimal(r.seconds)) s  \(detail)")
      if !ending.acceptable { clean = false }
    }
    if (i + 1) % 5 == 0 && i + 1 < mutants.count {
      guard control("control after \(i + 1)") else { return false }
    }
  }
  // Last, so that a run's failures aren't a machine's.
  guard control("control last") else { return false }
  let summary = [Ending.caught, .survivedExplained, .survived, .didNothing].map { "\(counts[$0] ?? 0) \($0.rawValue)" }.joined(separator: ", ")
  say("vx: mutate \(suite): \(summary)\(clean ? "" : "; FAILED") (\(mutateLog))")
  return clean
}
