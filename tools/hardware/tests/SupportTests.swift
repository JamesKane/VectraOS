// SPDX-License-Identifier: BSD-3-Clause

import Hardware
import Testing

let header = supportColumns.joined(separator: "\t")

/// A support.tsv of `rows`, each written with | for its tabs.
func table(_ rows: String...) -> String {
  ([header] + rows.map { $0.split(separator: "|", omittingEmptySubsequences: false).joined(separator: "\t") })
    .joined(separator: "\n")
}

let qemu = "qemu-x|platform|-|amd64|supported|-|V0|D2|yes|-|vx test amd64|-|q"
let qemuConsole = "x-console|component|qemu-x|amd64|supported|yes|V0|D2|-|-|boot-smoke|-|c"
let board = "board|platform|-|arm64|planned|-|V4|D5|yes|-|-|-|b"
let boardUart = "b-uart|component|board|arm64|planned|yes|V4|D5|-|-|-|-|u"

func facts(ctest: [String]? = ["boot-smoke"], fresh: Bool? = true) -> Facts {
  Facts(
    decisions: ["D2", "D5", "D63"], milestones: ["V0", "V3", "V4"], ctest: { _ in ctest },
    exists: { $0.hasPrefix("kernel/") }, fresh: { _, _ in fresh })
}

func problems(_ text: String, runs: [Run] = [], facts f: Facts = facts()) -> [String] {
  let (rows, bad) = parseSupport(text)
  return bad + check(rows, runs: runs, facts: f)
}

@Test func theSeededShapeIsClean() {
  #expect(problems(table(qemu, qemuConsole, board, boardUart)) == [])
}

@Test func malformedLinesAreNamed() {
  let (rows, bad) = parseSupport(table("x|platform|-|amd64|supported", "y|gadget|-|amd64|planned|-|V0|D2|-|-|-|-|n"))
  #expect(rows.isEmpty)
  #expect(bad.count == 2)
  #expect(bad.first?.hasPrefix("support.tsv:2: 5 fields") == true)
  #expect(parseSupport("id\tkind").problems.first?.hasPrefix("support.tsv:1: the header") == true)
}

@Test func decisionsAndMilestonesMustExist() {
  let p = problems(table("b|platform|-|arm64|planned|-|V9|D99|yes|-|-|-|n"))
  #expect(p.contains { $0.hasSuffix("decision D99 doesn't exist") })
  #expect(p.contains { $0.hasSuffix("milestone V9 isn't in the roadmap") })
  #expect(problems(table("b|platform|-|arm64|planned|-|open|D5|yes|-|-|-|n")) == [])
  #expect(problems(table("r|platform|-|arm64|research|-|-|-|no|-|-|-|n")) == [])
  #expect(problems(table("p|platform|-|arm64|planned|-|-|D5|no|-|-|-|n")).first?.hasSuffix("needs a milestone, or open") == true)
}

@Test func developmentNeedsPathsThatExist() {
  #expect(problems(table(board, "b-dev|component|board|arm64|development|no|V4|D5|-|-|-|-|n"))
    .contains { $0.hasSuffix("development needs its code's paths as evidence") })
  #expect(problems(table(board, "b-dev|component|board|arm64|development|no|V4|D5|-|-|kernel/Uart.swift|-|n")) == [])
  #expect(problems(table(board, "b-dev|component|board|arm64|development|no|V4|D5|-|-|drivers/gone.swift|-|n"))
    .contains { $0.hasSuffix("evidence drivers/gone.swift doesn't exist") })
}

@Test func qemuRowsNeedTheirTestsInCtest() {
  let missing = "x-gone|component|qemu-x|amd64|supported|no|V0|D2|-|-|boot-gone|-|n"
  #expect(problems(table(qemu, qemuConsole, missing)).contains { $0.contains("x-gone: supported on QEMU needs tests") })
  #expect(problems(table(qemu, qemuConsole), facts: facts(ctest: nil)).contains { $0.contains("vx build first") })
}

@Test func aPlatformIsCappedByItsRequiredComponents() {
  let devConsole = "x-console|component|qemu-x|amd64|development|yes|V0|D2|-|-|kernel/Uart.swift|-|c"
  #expect(problems(table(qemu, devConsole)).contains { $0.hasSuffix("above its required component x-console (development)") })
  // A component that isn't required doesn't cap it.
  let optional = "x-gpu|component|qemu-x|amd64|planned|no|V0|D2|-|-|-|-|g"
  #expect(problems(table(qemu, qemuConsole, optional)) == [])
}

@Test func boardsNeedARecordedPassThatIsFresh() {
  let exp = "board|platform|-|arm64|experimental|-|V4|D5|yes|-|native-suite|abc 2026-11-01|b"
  let uartExp = "b-uart|component|board|arm64|experimental|yes|V4|D5|-|-|-|-|u"
  let pass = Run(date: "2026-11-01", commit: "abc", platform: "board", passed: true, tests: ["native-suite"])
  #expect(problems(table(exp, uartExp), runs: [pass]) == [])
  #expect(problems(table(exp, uartExp)).contains { $0.hasSuffix("last_pass abc isn't a pass in runs.tsv") })

  let sup = "board|platform|-|arm64|supported|-|V4|D5|yes|-|native-suite|abc 2026-11-01|b"
  let uartSup = "b-uart|component|board|arm64|supported|yes|V4|D5|-|-|-|-|u"
  #expect(problems(table(sup, uartSup), runs: [pass]) == [])
  #expect(problems(table(sup, uartSup), runs: [pass], facts: facts(fresh: false))
    .contains { $0.contains("board: supported, but its last pass is stale") })
}

@Test func healthFollowsTheLastRun() {
  let sup = "board|platform|-|arm64|supported|-|V4|D5|yes|-|native-suite|abc 2026-11-01|b"
  let (rows, _) = parseSupport(table(sup, qemu, qemuConsole))
  let pass = Run(date: "d1", commit: "abc", platform: "board", passed: true, tests: [])
  let fail1 = Run(date: "d2", commit: "def", platform: "board", passed: false, tests: [])
  let fail2 = Run(date: "d3", commit: "123", platform: "board", passed: false, tests: [])
  #expect(health(of: rows[0], in: rows, runs: [pass], facts: facts()) == .fresh)
  #expect(health(of: rows[0], in: rows, runs: [pass], facts: facts(fresh: false)) == .stale)
  #expect(health(of: rows[0], in: rows, runs: [pass, fail1, fail2], facts: facts()) == .failing(since: "def"))
  #expect(health(of: rows[0], in: rows, runs: [], facts: facts()) == .unrecorded)
  #expect(health(of: rows[2], in: rows, runs: [], facts: facts()) == .ci)
}

@Test func gatesHoldUntilTheirTestPasses() {
  let mac = "mac|platform|-|amd64|experimental|-|V4|D63|yes|fan-fail-safe|native-suite|abc d|m"
  let without = Run(date: "d", commit: "abc", platform: "mac", passed: true, tests: ["native-suite"])
  let with = Run(date: "d", commit: "abc", platform: "mac", passed: true, tests: ["native-suite", "fan-fail-safe"])
  #expect(problems(table(mac), runs: [without]).contains { $0.hasSuffix("gate fan-fail-safe hasn't passed") })
  #expect(problems(table(mac), runs: [with]) == [])
  // Up to development, a gate doesn't block.
  #expect(problems(table("mac|platform|-|amd64|planned|-|V4|D63|yes|fan-fail-safe|-|-|m")) == [])
}

@Test func runsRoundTrip() {
  let run = Run(date: "2026-11-01", commit: "abc", platform: "radxa-q8b", passed: true, tests: ["a", "b"])
  #expect(parseRuns("# comment\n" + run.line + "\nnonsense") == [run])
}

@Test func freshnessCoversTheKernelAndTheBoardsCode() {
  let (rows, _) = parseSupport(table(board, "b-dev|component|board|arm64|development|no|V4|D5|-|-|kernel/Uart.swift|-|n"))
  #expect(freshnessPaths(of: rows[0], in: rows) == ["boot/", "kernel/", "lib/", "kernel/Uart.swift"])
}
