// SPDX-License-Identifier: BSD-3-Clause

// crash-test's plan: each file's bytes the same however they're read, and
// a volume after a cut judged as groups committing in order allow.

import CrashPlan
import Testing

@Test func aFilesBytesAreTheSameReadInPieces() {
  let whole = CrashPlan.bytes(41, count: CrashPlan.size(41))
  #expect(whole.count == CrashPlan.size(41) && whole.count % 4096 == 0)
  #expect(CrashPlan.bytes(41, offset: 4093, count: 11) == Array(whole[4093..<4104]))
  #expect(CrashPlan.bytes(42, count: 64) != Array(whole[0..<64]))
  #expect((0..<200).allSatisfy { CrashPlan.size($0) >= 4096 && CrashPlan.size($0) <= 262_144 })
}

@Test func aCrashMayLeaveEmptyFilesAfterTheWholeOnes() {
  let ok = CrashPlan.judge([.whole, .whole, .whole, .partial, .empty])
  #expect(ok == CrashPlan.Verdict(whole: 3, empty: 2, wrong: 0, wholeAfterGap: 0) && ok.passed)
  #expect(ok.text == "3 whole in a row from f0, 2 partial or empty, 0 wrong, 0 whole after a gap: passed")
  // A wrong byte, or a later group without an earlier one: failed.
  #expect(!CrashPlan.judge([.whole, .wrong]).passed)
  #expect(!CrashPlan.judge([.whole, .empty, .whole]).passed)
  #expect(CrashPlan.judge([]).passed)
}
