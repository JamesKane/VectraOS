// SPDX-License-Identifier: BSD-3-Clause

import Risk
import Testing

let header = riskColumns.joined(separator: "\t")

/// A risk.tsv of `rows`, each written with | for its tabs.
func table(_ rows: String...) -> String {
  ([header] + rows.map { $0.split(separator: "|", omittingEmptySubsequences: false).joined(separator: "\t") })
    .joined(separator: "\n")
}

let tested = ["amd64", "arm64"]

func rows(_ text: String) -> [RiskRow] {
  let (rows, problems) = parseRisk(text)
  #expect(problems.isEmpty)
  return rows
}

let map = rows(table(
  "kernel/|all|AbiTests|boot-smoke,boot-lean|-",
  "kernel/arch/amd64/|amd64|-|all|-",
  "kernel/arch/rv64/|rv64|-|all|-",
  "shell/|all|RcTests,CommandsTests|boot-launch|man",
  "docs/|-|-|-|-",
  "man/|-|-|-|man",
  "README.md|-|-|-|-"))

@Test func theLongestPathWins() {
  #expect(row(for: "kernel/arch/amd64/Cpu.swift", in: map)?.path == "kernel/arch/amd64/")
  #expect(row(for: "kernel/Kernel/Vm/Vmo.swift", in: map)?.path == "kernel/")
  #expect(row(for: "README.md", in: map)?.path == "README.md")
  #expect(row(for: "README.md.orig", in: map) == nil)
  #expect(row(for: "tools/vx/main.swift", in: map) == nil)
}

@Test func aChangeRunsItsRowsTestsOnly() {
  let p = plan(map, changed: ["shell/rc/lib/Interpreter.swift"], tested: tested)
  #expect(p.host == ["CommandsTests", "RcTests"])
  #expect(p.arches.map(\.arch) == ["amd64", "arm64"])
  #expect(p.arches.map(\.boots) == [["boot-launch"], ["boot-launch"]])
  #expect(p.checks == ["man"])
  #expect(p.unmapped.isEmpty)
}

@Test func rowsUnite() {
  let p = plan(map, changed: ["shell/rc/Main.swift", "kernel/Kernel/Object/Notes.swift"], tested: tested)
  #expect(p.host == ["AbiTests", "CommandsTests", "RcTests"])
  #expect(p.arches.map(\.boots) == [["boot-launch", "boot-lean", "boot-smoke"], ["boot-launch", "boot-lean", "boot-smoke"]])
}

@Test func aWholeSuiteAbsorbsNames() {
  let p = plan(map, changed: ["kernel/Kernel/Vm/Vmo.swift", "kernel/arch/amd64/Cpu.swift"], tested: tested)
  #expect(p.arches.map(\.arch) == ["amd64", "arm64"])
  #expect(p.arches.map(\.boots) == [nil, ["boot-lean", "boot-smoke"]])
}

@Test func anArchOffByDefaultIsBuiltNotTested() {
  let p = plan(map, changed: ["kernel/arch/rv64/Trap.swift"], tested: tested)
  #expect(p.arches.map(\.arch) == ["rv64"])
  #expect(p.arches.map(\.boots) == [[]])
  #expect(p.host == [])
}

@Test func docsRunNothingAndPagesTheirCheck() {
  #expect(plan(map, changed: ["docs/roadmap.md", "README.md"], tested: tested).isEmpty)
  let p = plan(map, changed: ["man/1/ps"], tested: tested)
  #expect(p.host == [] && p.arches.isEmpty && p.checks == ["man"])
}

@Test func anUnmappedFileRunsEverything() {
  let p = plan(map, changed: ["docs/roadmap.md", "tools/vx/main.swift"], tested: tested)
  #expect(p.host == nil)
  #expect(p.arches.map(\.arch) == tested)
  #expect(p.arches.map(\.boots) == [nil, nil])
  #expect(p.checks == riskChecks)
  #expect(p.unmapped == ["tools/vx/main.swift"])
}

@Test func badRowsAreProblems() {
  let (_, problems) = parseRisk(table("kernel/|all|-|-", "kernel/|all|-|-|-", "kernel/|all|-|-|-"))
  #expect(problems.count == 2)
  #expect(parseRisk("path\tarch\n").1.count == 1)
}

func facts(ctest: [String]? = ["boot-smoke", "boot-lean", "boot-launch"]) -> RiskFacts {
  RiskFacts(
    arches: ["amd64", "arm64", "rv64"], tested: tested, hostTargets: ["AbiTests", "RcTests", "CommandsTests"],
    ctest: { _ in ctest }, exists: { _ in true })
}

@Test func theSeededMapIsClean() {
  #expect(check(map, facts: facts()) == [])
}

@Test func unknownNamesAreProblems() {
  let bad = rows(table(
    "kernel/|all|AbiTests,NoTests|boot-smoke,boot-nope|lint",
    "shell/|mips|RcTests,CommandsTests|boot-launch,boot-lean|-",
    "x/|-|-|boot-smoke|-"))
  let problems = check(bad, facts: facts())
  #expect(problems.count == 5)
  #expect(problems.contains { $0.hasSuffix("no test target NoTests") })
  #expect(problems.contains { $0.hasSuffix("no test boot-nope on amd64, arm64") })
  #expect(problems.contains { $0.hasSuffix("unknown check lint") })
  #expect(problems.contains { $0.hasSuffix("unknown arch mips") })
  #expect(problems.contains { $0.hasSuffix("boots without an arch") })
}

@Test func everyTestNeedsARow() {
  let some = rows(table("kernel/|all|AbiTests|boot-smoke|-"))
  let problems = check(some, facts: facts())
  #expect(problems.contains { $0.hasSuffix("no row names test target RcTests") })
  #expect(problems.contains { $0.hasSuffix("no row names amd64's test boot-launch") })
  // A row that runs everything names nothing: 3 targets, 3 boots on each arch.
  let whole = rows(table("kernel/|all|all|all|-"))
  #expect(check(whole, facts: facts()).count == 9)
}

@Test func unconfiguredTreesArentJudged() {
  #expect(check(rows(table("kernel/|all|AbiTests,RcTests,CommandsTests|boot-x|-")), facts: facts(ctest: nil)) == [])
}

@Test func patternsAreExact() {
  #expect(ctestPattern(["boot-smoke", "boot-node-test-t1"]) == "^(boot-smoke|boot-node-test-t1)$")
  #expect(hostPattern(["RcTests"]) == "^(RcTests)\\.")
  #expect(ctestPattern(["a.b"]) == "^(a\\.b)$")
}

@Test func allHostTargetsRunsSwiftTestWhole() {
  let m = rows(table("Package.swift|-|all|-|-", "shell/|all|RcTests|boot-launch|-"))
  let p = plan(m, changed: ["shell/rc/Main.swift", "Package.swift"], tested: tested)
  #expect(p.host == nil)
  #expect(p.arches.map(\.boots) == [["boot-launch"], ["boot-launch"]])
}

/// A build file's changed lines are read for the sources and tests they
/// name, through variables set elsewhere in the file.
@Test func buildFileChangesNameWhatTheyTouch() {
  let text = """
    set(_hot_frame ${PROJECT_SOURCE_DIR}/sdk/examples/minimal/hot/Frame.swift)
    file(GLOB _hot CONFIGURE_DEPENDS ${PROJECT_SOURCE_DIR}/sdk/hot/*.swift)
    croi_user_library(${CMAKE_CURRENT_BINARY_DIR}/libminimalframe.so SYS IPC SWIFT ${_hot_frame})
    add_test(NAME boot-reload COMMAND "${CMAKE_SOURCE_DIR}/sdk/tests/hot/boot-reload.sh ${VX}")
    """
  let lines = text.split(separator: "\n").map(String.init)
  let r = buildReferences(changed: Array(lines[2...]), text: text)
  #expect(r.paths == ["sdk/examples/minimal/hot/Frame.swift", "sdk/tests/hot/boot-reload.sh"])
  #expect(r.tests == ["boot-reload"])
  #expect(buildReferences(changed: [lines[1]], text: text).paths == ["sdk/hot/"])
  #expect(buildReferences(changed: ["  COMMENT \"Building\")"], text: text) == ([], []))
  // A global, the means of running a test, isn't followed.
  let qemu = "set(CROI_QEMU ${PROJECT_SOURCE_DIR}/tools/qemu.sh)\n"
  #expect(buildReferences(changed: ["add_test(NAME boot-x COMMAND ${CROI_QEMU})"], text: qemu + text).paths == [])
}
