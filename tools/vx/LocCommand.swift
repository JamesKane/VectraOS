// SPDX-License-Identifier: BSD-3-Clause

// vx loc: the size budgets (principle 2, docs/performance.md "Size").
//
//   vx loc            lines per component, by language, and how many came
//                     from croi, todhchai or NeoVectra (IMPORTS.tsv)
//   vx loc --check    also fails if the syscall count is over its ceiling
//                     or IMPORTS.tsv names a file that isn't here

import FoundationEssentials
import Glibc

/// The syscall ceiling. It only ever goes down (D2): lowering it is part
/// of the change that removes the calls; raising it is a decision entry.
let syscallCeiling = 135

private let languages: [(suffix: String, name: String)] = [
  (".swift", "Swift"), (".c", "C"), (".h", "C"), (".S", "asm"), (".py", "Python"), (".sh", "shell"),
  (".cmake", "CMake"), ("CMakeLists.txt", "CMake"), (".ld", "ld"),
]

/// The syscalls the C ABI defines: `CROI_SYS_<NAME> = <n>,` lines.
func syscallCount() -> Int {
  guard let text = try? String(contentsOfFile: "user/include/croi/syscall.h", encoding: .utf8) else { return 0 }
  return text.split(separator: "\n").count { line in
    let t = line.drop { $0 == " " }
    return t.hasPrefix("CROI_SYS_") && t.contains("=")
  }
}

func locCommand(_ args: [String]) -> Bool {
  var check = false
  for a in args {
    switch a {
    case "--check": check = true
    default: fail("unknown option \(a)")
    }
  }
  guard let listing = capture(["git", "ls-files", "--cached", "--others", "--exclude-standard"]) else {
    fail("git ls-files failed")
  }
  let imports = (try? String(contentsOfFile: "IMPORTS.tsv", encoding: .utf8)) ?? ""
  var imported: [String: String] = [:]
  for line in imports.split(separator: "\n") where !line.hasPrefix("#") {
    let f = line.split(separator: "\t")
    if f.count >= 2 { imported[String(f[0])] = String(f[1]) }
  }

  // component -> language -> (first-party lines, imported lines)
  var table: [String: [String: (ours: Int, theirs: Int)]] = [:]
  for path in listing.split(separator: "\n").map(String.init) {
    guard let language = languages.first(where: { path.hasSuffix($0.suffix) })?.name,
          let data = FileManager.default.contents(atPath: path) else { continue }
    let lines = data.count { $0 == UInt8(ascii: "\n") }
    let component = path.contains("/") ? String(path.split(separator: "/").first!) : "(root)"
    var entry = table[component, default: [:]][language, default: (0, 0)]
    if imported[path] != nil { entry.theirs += lines } else { entry.ours += lines }
    table[component, default: [:]][language] = entry
  }

  var out = "| Component | Language | First-party | Imported | Total |\n|---|---|---:|---:|---:|\n"
  var ours = 0, theirs = 0
  for component in table.keys.sorted() {
    for (language, n) in table[component]!.sorted(by: { $0.key < $1.key }) {
      out += "| \(component) | \(language) | \(n.ours) | \(n.theirs) | \(n.ours + n.theirs) |\n"
      ours += n.ours
      theirs += n.theirs
    }
  }
  out += "| **all** | | **\(ours)** | **\(theirs)** | **\(ours + theirs)** |\n"
  let syscalls = syscallCount()
  out += "\nSyscalls: \(syscalls) (ceiling \(syscallCeiling)).\n"
  say(out)

  guard check else { return true }
  var ok = true
  if syscalls > syscallCeiling {
    complain("\(syscalls) syscalls, over the ceiling of \(syscallCeiling)")
    ok = false
  }
  for path in imported.keys.sorted() where !FileManager.default.fileExists(atPath: path) {
    complain("IMPORTS.tsv names \(path), which isn't in the tree")
    ok = false
  }
  return ok
}
