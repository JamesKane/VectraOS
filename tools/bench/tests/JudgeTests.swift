// SPDX-License-Identifier: BSD-3-Clause

import Bench
import Testing

func samples(_ name: String, _ seconds: [Double]) -> [Sample] {
  seconds.map { Sample(date: "d", commit: "c", name: name, seconds: $0) }
}

@Test func firstRunIsNew() {
  #expect(judge("b", seconds: 9, history: [], rule: .buildTime).verdict == .new)
}

@Test func baselineIsTheMedianOfTheRecentWindow() {
  // Old slow runs fall out of the window of 5.
  let history = samples("b", [50, 50, 10, 10, 11, 9, 10])
  let j = judge("b", seconds: 10.5, history: history, rule: .buildTime)
  #expect(j.baseline == 10)
  #expect(j.verdict == .ok)
}

@Test func regressionNeedsBothTheFractionAndTheFloor() {
  let slow = samples("b", [10, 10, 10])
  #expect(judge("b", seconds: 11.2, history: slow, rule: .buildTime).verdict == .regressed)  // +12%, +1.2 s
  #expect(judge("b", seconds: 10.9, history: slow, rule: .buildTime).verdict == .ok)  // +9%
  let fast = samples("b", [1.0, 1.0, 1.0])
  #expect(judge("b", seconds: 1.2, history: fast, rule: .buildTime).verdict == .ok)  // +20%, but only 0.2 s
  #expect(judge("b", seconds: 1.3, history: fast, rule: .buildTime).verdict == .regressed)
}

@Test func cleanBuildsHaveAWiderRule() {
  #expect(Rule.for("build.clean.hosted").tolerance == 0.20)
  #expect(Rule.for("build.incremental.IPC").tolerance == 0.10)
  let history = samples("build.clean.hosted", [16.0])
  #expect(judge("build.clean.hosted", seconds: 17.9, history: history, rule: .for("build.clean.hosted")).verdict == .ok)
  #expect(judge("build.clean.hosted", seconds: 20, history: history, rule: .for("build.clean.hosted")).verdict == .regressed)
}

@Test func limitsFailWhateverTheHistory() {
  let rule = Rule.for("trace.zone.enabled")
  #expect(judge("trace.zone.enabled", seconds: 14e-9, history: [], rule: rule).verdict == .new)
  #expect(judge("trace.zone.enabled", seconds: 25e-9, history: [], rule: rule).verdict == .overLimit)
  #expect(formatValue(14.06e-9) == "14.1 ns" && formatValue(2.5e-3) == "2.5 ms" && formatValue(16.0044) == "16.004 s")
  let tiny = Sample(date: "d", commit: "c", name: "trace.zone.enabled", seconds: 1.4e-8)
  #expect(parseHistory(tiny.line).first?.seconds == 1.4e-8)
}

@Test func otherMeasurementsDontCount() {
  let history = samples("a", [1, 1, 1])
  #expect(judge("b", seconds: 5, history: history, rule: .buildTime).verdict == .new)
}

@Test func historyLinesRoundTrip() {
  let s = Sample(date: "2026-10-09T12:00Z", commit: "abc-dirty", name: "build.noop.hosted", seconds: 1.2345)
  #expect(s.line == "2026-10-09T12:00Z\tabc-dirty\tbuild.noop.hosted\t1.235")
  #expect(parseHistory("# comment\n" + s.line + "\nnot a sample\n").first?.seconds == 1.235)
  #expect(format(0.05) == "0.050")
  #expect(median([3, 1, 2]) == 2 && median([4, 1, 2, 3]) == 2.5)
}

@Test func ratesFailWhenTheyFall() {
  // Higher is better, so a fall past both parts fails.
  let name = "rate"
  let rule = Rule(tolerance: 0.15, floor: 1, window: 5, unit: .rate("Mpx/s"))
  #expect(rule.higherIsBetter)
  let history = samples(name, [100, 100, 100])
  #expect(judge(name, seconds: 150, history: history, rule: rule).verdict == .ok)  // faster
  #expect(judge(name, seconds: 90, history: history, rule: rule).verdict == .ok)  // -10%
  #expect(judge(name, seconds: 80, history: history, rule: rule).verdict == .regressed)  // -20%
  let slow = samples(name, [4, 4, 4])
  #expect(judge(name, seconds: 3.2, history: slow, rule: rule).verdict == .ok)  // -20%, but under 1 Mpx/s
  // A rate's limit is a floor.
  var floored = rule
  floored.limit = 50
  #expect(judge(name, seconds: 40, history: [], rule: floored).verdict == .overLimit)
  #expect(judge(name, seconds: 60, history: [], rule: floored).verdict == .new)
  #expect(floored.summary == "-15%, 1.0 Mpx/s; ≥ 50.0 Mpx/s")
  #expect(rule.format(412.3) == "412 Mpx/s" && rule.format(41.23) == "41.2 Mpx/s" && rule.format(0.654) == "0.65 Mpx/s")
}

@Test func bootBudgetsUseTheKernelTable() {
  // croi's RULES, in seconds: channel_call +15% and 150 ns.
  let rule = Rule.for("ipc.channel_call")
  #expect(rule.tolerance == 0.15 && rule.floor == 150e-9)
  let history = samples("ipc.channel_call", [1.4e-6, 1.4e-6, 1.4e-6])
  #expect(judge("ipc.channel_call", seconds: 1.55e-6, history: history, rule: rule).verdict == .ok)  // +11%
  #expect(judge("ipc.channel_call", seconds: 1.7e-6, history: history, rule: rule).verdict == .regressed)
  #expect(Rule.for("idle.wakeups").floor == 0.5)
}

@Test func budgetLinesFromASerialConsole() {
  // CR LF line ends, a prefix before the line, and the kernel's exclusive
  // limit (value < limit) read as Judge's inclusive one.
  let console = "boot\r\n  budget name=syscall.null value=40 unit=ns limit=100\r\n"
    + "m2: budget name=idle.wakeups value=0 unit=count limit=1\r\n"
    + "  budget name=ipc.channel_call value=1450 unit=ns limit=1600 target=1000\r\nnoise\r\n"
  let b = parseBudgets(console)
  #expect(b.count == 3)
  #expect(b["syscall.null"] == Reported(value: 40e-9, limit: 99e-9, target: nil, unit: .seconds))
  #expect(b["idle.wakeups"] == Reported(value: 0, limit: 0, target: nil, unit: .count))
  #expect(b["ipc.channel_call"]?.target == 1000e-9)
  let rule = Rule(tolerance: 0, floor: 0.5, window: 5, limit: b["idle.wakeups"]!.limit, unit: .count)
  #expect(judge("idle.wakeups", seconds: 1, history: [], rule: rule).verdict == .overLimit)
}
