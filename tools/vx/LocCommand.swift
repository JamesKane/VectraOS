// SPDX-License-Identifier: BSD-3-Clause

// vx loc: the size budgets (principle 2, docs/performance.md "Size").
//
//   vx loc            lines per component, by language, and how many came
//                     from croi, todhchai or NeoVectra (IMPORTS.tsv)
//   vx loc --check    also fails if the syscall count is over its ceiling,
//                     a library is over its size ceiling, IMPORTS.tsv
//                     names a file that isn't here, or code makes a call
//                     by number rather than the ABI's name

import FoundationEssentials
import Glibc

/// The syscall ceiling. It only ever goes down (D2): lowering it is part
/// of the change that removes the calls; raising it is a decision entry.
let syscallCeiling = 91

/// Libraries with a ceiling of their own: Swift lines under a directory,
/// each set by the decision that made the library. Lowering one is part
/// of any change; raising it is a decision entry.
let sizeCeilings: [(directory: String, lines: Int, decision: String)] = [
  ("system/guide/lib/", 1500, "D86"),  // the manual's parser and renderer
]

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

/// Calls made by number, not by the ABI's `CROI_SYS_` names (D45): the
/// headers are the one source, so a hardcoded number is a second one, and
/// todhchai's `td_syscall6` is the entry its number tables went through.
/// Device code only: the kernel's dispatch is the numbers' other side.
func abiViolations(_ paths: [String]) -> [String] {
  let entries = ["syscall(", "syscall6(", "sys(", "sys6(", "Sys.call("]
  var found: [String] = []
  for path in paths where [".swift", ".c", ".h", ".S"].contains(where: { path.hasSuffix($0) })
    && ["user/", "lib/", "system/", "services/", "drivers/", "shell/"].contains(where: { path.hasPrefix($0) })
  {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
    for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
      let numbered = entries.contains { entry in
        var rest = line[...]
        while let r = rest.firstRange(of: entry) {
          if rest[r.upperBound...].drop(while: { $0 == " " }).first?.isNumber == true { return true }
          rest = rest[r.upperBound...]
        }
        return false
      }
      if numbered || line.contains("td_syscall") { found.append("\(path):\(n + 1)") }
    }
  }
  return found
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
  var ceilingLines = [Int](repeating: 0, count: sizeCeilings.count)
  for path in listing.split(separator: "\n").map(String.init) {
    guard let language = languages.first(where: { path.hasSuffix($0.suffix) })?.name,
          let data = FileManager.default.contents(atPath: path) else { continue }
    let lines = data.count { $0 == UInt8(ascii: "\n") }
    for (i, c) in sizeCeilings.enumerated() where path.hasPrefix(c.directory) && language == "Swift" {
      ceilingLines[i] += lines
    }
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
  for (i, c) in sizeCeilings.enumerated() {
    out += "\(c.directory): \(ceilingLines[i]) lines (ceiling \(c.lines), \(c.decision)).\n"
  }
  say(out)

  guard check else { return true }
  var ok = true
  if syscalls > syscallCeiling {
    complain("\(syscalls) syscalls, over the ceiling of \(syscallCeiling)")
    ok = false
  }
  for (i, c) in sizeCeilings.enumerated() where ceilingLines[i] > c.lines {
    complain("\(c.directory) has \(ceilingLines[i]) lines, over its ceiling of \(c.lines) (\(c.decision))")
    ok = false
  }
  for place in abiViolations(listing.split(separator: "\n").map(String.init)) {
    complain("\(place): a call by number; name it from the ABI headers (D45)")
    ok = false
  }
  for path in imported.keys.sorted() where !FileManager.default.fileExists(atPath: path) {
    complain("IMPORTS.tsv names \(path), which isn't in the tree")
    ok = false
  }
  return ok
}
