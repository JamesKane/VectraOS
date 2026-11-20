// SPDX-License-Identifier: BSD-3-Clause

import Testing
import UnsafeCount

@Test func countsKeywordAttributeAndModifier() {
  let src = """
    let a = unsafe foo()
    @unsafe struct S {}
    @unsafe public init(x: Int) {}
    nonisolated(unsafe) var g = 0
    let b = unsafe unsafe bar()
    """
  #expect(unsafeLines(in: src) == 5)
}

@Test func skipsCommentsStringsAndOtherIdentifiers() {
  let src = ##"""
    // unsafe here
    /* unsafe /* nested unsafe */ still comment unsafe */
    let s = "an unsafe string \(f("unsafe")) unsafe"
    let m = """
      unsafe "
      """
    let r = #"unsafe "quoted" unsafe"#
    let c = unsafeBitCast(x, to: Int.self)
    let w = p.withUnsafeBytes { $0 }
    let d = Kind.unsafe
    @safe(unchecked) struct T {}
    """##
  #expect(unsafeLines(in: src) == 0)
  #expect(unsafeLines(in: src + "\nlet z = unsafe f()\n") == 1)
}

@Test func unitsExcludeHostAndTests() {
  #expect(unsafeUnit(of: "drivers/block/nvme/Main.swift") == "drivers/block/nvme")
  #expect(unsafeUnit(of: "drivers/block/nvme/lib/Queues.swift") == "drivers/block/nvme")
  #expect(unsafeUnit(of: "drivers/block/lib/Sd.swift") == "drivers/block/lib")
  #expect(unsafeUnit(of: "drivers/devmgr/lib/Pages.swift") == "drivers/devmgr")
  #expect(unsafeUnit(of: "drivers/devmgr/Main.swift") == "drivers/devmgr")
  #expect(unsafeUnit(of: "drivers/host/DMA.swift") == nil)
  #expect(unsafeUnit(of: "drivers/block/tests/BlockTests.swift") == nil)
  #expect(unsafeUnit(of: "drivers/block/sdhci/tests/native/x.swift") == nil)
  #expect(unsafeUnit(of: "drivers/block/nvme/driver.manifest") == nil)
  #expect(unsafeUnit(of: "user/x.swift") == nil)
}

@Test func recordOnlyFalls() {
  let (record, problems) = parseUnsafeRecord("# c\ndrivers/a/b\t3\n")
  #expect(problems.isEmpty)
  #expect(judgeUnsafe(counts: ["drivers/a/b": 3], record: record).isEmpty)
  // The control: one more than recorded fails, naming the unit.
  let over = judgeUnsafe(counts: ["drivers/a/b": 4], record: record)
  #expect(over.count == 1 && over[0].contains("over its record of 3"))
  // A new driver starts at zero.
  #expect(judgeUnsafe(counts: ["drivers/a/b": 3, "drivers/a/new": 1], record: record).count == 1)
  // A count that fell says to lower the record.
  let under = judgeUnsafe(counts: ["drivers/a/b": 2], record: record)
  #expect(under.count == 1 && under[0].contains("lower it"))
  #expect(!parseUnsafeRecord("drivers/a/b\t0\nbad\n").problems.isEmpty)
}
