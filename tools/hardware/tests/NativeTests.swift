// SPDX-License-Identifier: BSD-3-Clause

// The native suite's judging from a board's console (vx remote test).

import Hardware
import Testing

@Test func budgetLinesAreReadWhereverTheyStart() {
  #expect(Budget(line: "[00012.388] 03052:03058> m2: budget name=process.spawn_to_main value=14299374 unit=ns limit=200000")
    == Budget(name: "process.spawn_to_main", value: 14_299_374, unit: "ns", limit: 200_000))
  #expect(Budget(line: "  budget name=boot.loader value=168845310 unit=ns")!.limit == nil)
  #expect(Budget(line: "  budget name=boot.userboot_start value=221 unit=ns target=100")!.over == false)
  #expect(Budget(line: "m2: budget name=x value=3 unit=count limit=1")!.over)
  #expect(Budget(line: "m2: 9 budget(s) over (reported, not enforced: see vx bench)") == nil)
  #expect(Budget(line: "budget name=x unit=ns") == nil)
}

@Test func aRunPassesOnItsLastLineAndFailsOnAPanic() {
  var run = NativeRun()
  #expect(run.feed("userboot: bin/m2 exited with 0") == .running)  // the old boot's: before the banner
  #expect(run.feed("croi kernel (arm64)") == .running)
  #expect(run.feed("  budget name=boot.loader value=1 unit=ns") == .running)
  #expect(run.feed("[00012.901] 03046:03048> userboot: bin/m2 exited with 0") == .passed)
  #expect(run.budgets.count == 1 && run.lines == 3)

  var panicked = NativeRun()
  _ = panicked.feed("croi kernel (arm64)")
  #expect(panicked.feed("croi kernel: PANIC: suites: a suite failed (its FAILED line is above)")
    == .failed("croi kernel: PANIC: suites: a suite failed (its FAILED line is above)"))
  #expect(panicked.feed("userboot: bin/m2 exited with 0") != .passed)

  var exited = NativeRun()
  _ = exited.feed("croi kernel (arm64)")
  #expect(exited.feed("userboot: bin/m2 exited with 1") == .failed("bin/m2 exited with 1"))
}
