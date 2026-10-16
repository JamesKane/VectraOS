// SPDX-License-Identifier: BSD-3-Clause

// idlc: reads Swift files that declare @IPCLibrary libraries and writes a C
// header for each library, and for each of its protocols a Markdown
// reference page and an API baseline checked against the recorded one
// (architecture §4).
//
//   idlc [--c-out DIR] [--doc-out DIR] [--baseline DIR [--update-baseline]] [--with FILE]... FILE...
//
// --with reads a library only so FILE's protocols can compose its
// protocols (`protocol Directory: NodeIPC.Node`); nothing is written for it.
//
// Exits 1 if a library can't be read or a protocol breaks its baseline.

// FoundationEssentials only, as principle 29 allows for tier 1.
import FoundationEssentials
import Glibc
import IDL

func complain(_ message: String) {
  let line = Array("idlc: \(message)\n".utf8)
  _ = line.withUnsafeBytes { write(2, $0.baseAddress, $0.count) }
}

func fail(_ message: String) -> Never {
  complain(message)
  exit(1)
}

/// `value`, or exit with `message` if there is none.
func need(_ value: String?, _ message: String) -> String {
  guard let value else { fail(message) }
  return value
}

func join(_ dir: String, _ name: String) -> String { dir.hasSuffix("/") ? dir + name : dir + "/" + name }

var cOut: String?
var docOut: String?
var baselineDir: String?
var updateBaseline = false
var files: [String] = []
var withFiles: [String] = []
var args = CommandLine.arguments.dropFirst()
while let arg = args.popFirst() {
  switch arg {
  case "--c-out": cOut = need(args.popFirst(), "--c-out needs a directory")
  case "--doc-out": docOut = need(args.popFirst(), "--doc-out needs a directory")
  case "--baseline": baselineDir = need(args.popFirst(), "--baseline needs a directory")
  case "--update-baseline": updateBaseline = true
  case "--with": withFiles.append(need(args.popFirst(), "--with needs a file"))
  default:
    if arg.hasPrefix("-") { fail("unknown option \(arg)") }
    files.append(arg)
  }
}
if files.isEmpty { fail("no input files") }

let sources = files.map { path in
  (path: path, text: need(try? String(contentsOfFile: path, encoding: .utf8), "can't read \(path)"))
}
let references = withFiles.map { path in
  (path: path, text: need(try? String(contentsOfFile: path, encoding: .utf8), "can't read \(path)"))
}
let interface: Interface
do {
  interface = try scan(sources, references: references)
} catch {
  fail(error.description)
}
if interface.libraries.isEmpty { fail("no @IPCLibrary libraries in \(files.joined(separator: ", "))") }

func save(_ text: String, to dir: String, _ name: String) {
  try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
  let path = join(dir, name)
  do { try text.write(toFile: path, atomically: true, encoding: .utf8) } catch { fail("can't write \(path)") }
}

var broken = false
let source = files.count == 1 ? files[0] : "\(files.count) files"
for l in interface.libraries {
  if let cOut { save(cHeader(l, source: source), to: cOut, "\(snakeName(l)).h") }
}
for (l, p) in interface.protocols {
  let composed: [Interface.ComposedMethod]
  do { composed = try interface.composedMethods(p, in: l) } catch { fail(error.description) }
  if let docOut { save(markdown(p, l, source: source, composed: composed), to: docOut, "\(p.name).md") }
  if let baselineDir {
    let path = join(baselineDir, "\(p.id).api")
    let new = Baseline(p, l, composed: composed)
    if let text = try? String(contentsOfFile: path, encoding: .utf8) {
      guard let old = Baseline(text: text) else { fail("\(path) is not a baseline") }
      let problems = compatibility(old: old, new: new)
      for problem in problems {
        complain("\(p.id): \(problem)")
      }
      broken = broken || !problems.isEmpty
      if problems.isEmpty && updateBaseline { save(new.text, to: baselineDir, "\(p.id).api") }
    } else if updateBaseline {
      save(new.text, to: baselineDir, "\(p.id).api")
    } else {
      fail("\(p.id) has no baseline at \(path); run with --update-baseline to record one")
    }
  }
}
if broken { exit(1) }
