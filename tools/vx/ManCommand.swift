// SPDX-License-Identifier: BSD-3-Clause

// vx man: the manual on the dev machine (D86, vx-man(1)).
//
//   vx man [-w] [SECTION] TITLE [NODE]   a page, or one node of it, for
//                                        the terminal; -w its path
//   vx man --check                       the manual against itself and the
//                                        code (Manual's Check), run by vx ci
//   vx man --missing                     rows for what has no page and no row
//   vx man --index FILE                  the index, as TSV
//   vx man --usage                       writes the usage messages the
//                                        pages give (Manual's usageFiles)
//
// Programs are required from each arch's built boot image
// (build/ARCH/bootfs.img); with none built, they aren't checked.

import FoundationEssentials
import Glibc
import Guide
import ImageFormats
import Manual

func manCommand(_ args: [String]) -> Bool {
  let manual = Manual(root: ".")
  switch args.first {
  case "--check":
    let problems = Check.run(manual, requirements: requirements(), root: ".")
    for p in problems { complain(p) }
    say("vx man: \(manual.pages.count) pages, \(manual.missing.count) rows in man/missing, \(problems.count) problems")
    return problems.isEmpty
  case "--missing":
    let index = manual.index
    let wanted = requirements().filter { r in
      !manual.missing.contains { $0.requirement == r }
        && !index.contains { $0.node.isEmpty && $0.name == r.pageName && r.sections.contains($0.section) }
    }
    print(MissingRow.tsv(wanted), terminator: "")
    return true
  case "--usage":
    var ok = true
    for u in usageFiles {
      let commands = Requirements.strings(named: "names", in: Requirements.read(".", u.commands))
      switch UsageMessages.swift(manual, commands: commands) {
      case .success(let text):
        ok = FileManager.default.createFile(atPath: u.path, contents: Data(text.utf8)) && ok
      case .failure(let m):
        complain("\(u.path): no section 1 page with a usage fence for \(m.names.joined(separator: ", "))")
        ok = false
      }
    }
    return ok
  case "--index":
    guard args.count == 2 else { fail("usage: vx man --index FILE") }
    return FileManager.default.createFile(atPath: args[1], contents: Data(manual.indexTSV.utf8))
  default:
    break
  }
  var rest = args
  let pathOnly = rest.first == "-w"
  if pathOnly { rest.removeFirst() }
  var section: Int?
  if let s = rest.first, s.count == 1, let n = Int(s), (1...8).contains(n), rest.count > 1 {
    section = n
    rest.removeFirst()
  }
  guard (1...2).contains(rest.count) else { fail("usage: vx man [-w] [SECTION] TITLE [NODE]") }
  guard let p = manual.lookup(rest[0], section: section) else {
    complain("no page \(rest[0])\(section.map { "(\($0))" } ?? "")")
    return false
  }
  if pathOnly {
    print(p.path)
    return true
  }
  let width = getenv("COLUMNS").flatMap { Int(String(cString: $0)) } ?? 80
  do throws(GuideError) {
    let text = try Render.text(p.page, node: rest.count == 2 ? Array(rest[1].utf8) : nil, width: width)
    print(String(decoding: text, as: UTF8.self), terminator: "")
    return true
  } catch {
    complain(error.description)
    return false
  }
}

/// What needs a page: the tree's, and the programs of each built image.
func requirements() -> [Requirement] {
  guard let listing = capture(["git", "ls-files", "--cached", "--others", "--exclude-standard"]) else {
    fail("git ls-files failed")
  }
  var images: [[String]] = []
  for arch in allArches {
    if let data = FileManager.default.contents(atPath: "build/\(arch)/bootfs.img") {
      images.append(Bootfs.names(Array(data)))
    }
  }
  if images.isEmpty { say("vx man: no boot image built; programs are not checked") }
  return Requirements.all(root: ".", files: listing.split(separator: "\n").map(String.init), bootfs: images)
}
