// SPDX-License-Identifier: BSD-3-Clause

// SCMI's messages as bin/scmi sends them, and its ctl's commands.

import SCMI
import Testing

@Test func headersPackTheMessageProtocolAndToken() {
  // CLOCK_CONFIG_SET (7) on the clock protocol (0x14), token 5.
  #expect(header(.clock, message: Message.clockConfigSet, token: 5) == 0x0014_5007)
  // The token wraps at 10 bits; the type stays 0, a command.
  #expect(header(.power, message: Message.powerStateSet, token: 0x401) == 0x0004_4404)
}

@Test func answersAreCheckedByTheirStatusWord() throws {
  #expect(try result([0, 0x2_0000]) == [0x2_0000])
  #expect(throws: SCMIError.status(-4)) { try result([UInt32(bitPattern: -4)]) }
  #expect(throws: SCMIError.short) { try result([]) }
  #expect(SCMIError.status(-3).description == "status -3 (denied)")
  #expect(versionText(0x0002_0000) == "2.0")
  // The base protocol's vendor, "cix", NUL-ended in 16 bytes.
  #expect(nameText([0x0078_6963, 0, 0, 0][...]) == "cix")
  #expect(nameText([0x6B6C_6367, 0x7570_675F][...]) == "gclk_gpu")
}

@Test func ctlLinesBecomeCommands() {
  #expect(Command("power 21 on") == .power(domain: 21, on: true))
  #expect(Command("clock 0x1f off") == .clock(id: 31, on: false))
  #expect(Command("clock 0x1F on")?.request.payload == [31, 1])
  #expect(Command("power 21 off")?.request.payload == [0, 21, 1 << 30])
  #expect(Command("power 21 on")?.request.proto == .power)
  for bad in ["power 21", "power x on", "clock 21 maybe", "reset 9 on", "power 0x on", "clock 99999999999 on"] {
    #expect(Command(bad) == nil)
  }
  #expect(Command("power 21 on")?.description == "power 21 on")
}

@Test func rateLinesSetAClocksRate() {
  // CLOCK_RATE_SET: flags 0 (synchronous, rounded down), the id, the rate's two words.
  let c = Command("clock 41 rate 148500000")
  #expect(c == .rate(id: 41, hertz: 148_500_000))
  #expect(c?.request.message == Message.clockRateSet)
  #expect(c?.request.payload == [0, 41, 148_500_000, 0])
  #expect(c?.description == "clock 41 rate 148500000")
  #expect(Command("clock 41 rate 1 2") == nil)
  #expect(Command("clock 41 speed 5") == nil)
  // A rate replaces the clock's last rate, not its gate.
  #expect(Command.rate(id: 41, hertz: 1).sameSubject(.rate(id: 41, hertz: 2)))
  #expect(!Command.rate(id: 41, hertz: 1).sameSubject(.clock(id: 41, on: true)))
}

@Test func rateWithoutARateAsksForTheClocksRate() {
  // CLOCK_RATE_GET: the id alone.
  let c = Command("clock 253 rate")
  #expect(c == .rateGet(id: 253))
  #expect(c?.request.message == Message.clockRateGet)
  #expect(c?.request.payload == [253])
  #expect(c?.description == "clock 253 rate")
  #expect(Command("clock rate") == nil && Command("power 3 rate") == nil)
  // Its answer replaces the rate the clock was last given.
  #expect(Command.rateGet(id: 5).sameSubject(.rate(id: 5, hertz: 1)))
  #expect(!Command.rateGet(id: 5).sameSubject(.clock(id: 5, on: true)))
}

@Test func perfLinesAskForAPerformanceDomainsLevelAndLimits() {
  // PERFORMANCE_LEVEL_SET: the domain and the level; PERFORMANCE_LEVEL_GET and LIMITS_GET: the domain.
  let set = Command("perf 0 level 1000000")
  #expect(set == .level(domain: 0, level: 1_000_000))
  #expect(set?.request.proto == .performance && set?.request.message == Message.performanceLevelSet)
  #expect(set?.request.payload == [0, 1_000_000])
  #expect(set?.description == "perf 0 level 1000000")
  let get = Command("perf 0 level")
  #expect(get == .levelGet(domain: 0))
  #expect(get?.request.message == Message.performanceLevelGet && get?.request.payload == [0])
  let limits = Command("perf 0x2 limits")
  #expect(limits == .limitsGet(domain: 2))
  #expect(limits?.request.message == Message.performanceLimitsGet && limits?.request.payload == [2])
  #expect(Command.limits(domain: 2, lowest: 72000, highest: 1_000_000).description == "perf 2 limits 72000 1000000")
  #expect(Command("perf 0") == nil && Command("perf 0 level x") == nil && Command("perf 0 speed 1") == nil)
  // A level read replaces the level set, and limits the limits; neither is the other's, nor a clock's.
  #expect(Command.levelGet(domain: 0).sameSubject(.level(domain: 0, level: 1)))
  #expect(Command.limits(domain: 0, lowest: 1, highest: 2).sameSubject(.limitsGet(domain: 0)))
  #expect(!Command.levelGet(domain: 0).sameSubject(.limitsGet(domain: 0)))
  #expect(!Command.levelGet(domain: 0).sameSubject(.clock(id: 0, on: true)))
}

@Test func cppcLinesBecomeWrites() {
  #expect(CPPCWrite("cppc 0x659009c 8192 32") == CPPCWrite(address: 0x0659_009C, value: 8192, width: 32))
  #expect(CPPCWrite("cppc 100 0x10 8")?.address == 100)
  #expect(CPPCWrite(address: 0x0659_009C, value: 8192, width: 32).description == "cppc 0x659009c 8192 32")
  for bad in ["cppc 0x1 2", "cppc 0x1 2 3 4", "cppc 0x1 2 12", "cppc x 2 32", "cppc 0x1 -2 32", "clock 1 on",
              "cppc 0x1 99999999999999999999 32"] {
    #expect(CPPCWrite(bad) == nil)
  }
  // The other commands aren't cppc's.
  #expect(Command("cppc 0x659009c 8192 32") == nil)
}

@Test func devmgrsRegistersAreArguments() {
  let r = CPPCRegister(address: 0x0659_009C, width: 32)
  #expect(r.argument == "--cppc=0x659009c/32")
  #expect(CPPCRegister(argument: r.argument) == r)
  for bad in ["--cppc=0x659009c", "--cppc=659009c/32", "--cppc=0x/32", "--cppc=0x1/7", "--cppc=0x1/", "--bar=0:shmem"] {
    #expect(CPPCRegister(argument: bad) == nil)
  }
}

@Test func aWriteIsRefusedOutsideTheListedRegistersAndGrantedPages() {
  let listed = [CPPCRegister(address: 0x0659_009C, width: 32), CPPCRegister(address: 0x0659_00A0, width: 32)]
  // Mailbox 6's range, mapped to its page's end.
  let windows: [(base: UInt64, size: UInt64)] = [(0x0659_0000, 0x1000)]
  func verdict(_ a: UInt64, _ v: UInt64 = 8192, _ w: UInt8 = 32) -> CPPCWrite.Verdict {
    CPPCWrite(address: a, value: v, width: w).verdict(registers: listed, windows: windows)
  }
  #expect(verdict(0x0659_009C) == .write(window: 0, offset: 0x9C))
  #expect(verdict(0x0659_00A0, 0xFFFF_FFFF) == .write(window: 0, offset: 0xA0))
  // An address devmgr didn't list, in a granted page: refused.
  #expect(verdict(0x0659_0100) == .notListed)
  // Listed at another width, or the value too wide for it.
  #expect(verdict(0x0659_009C, 1, 16) == .notListed)
  #expect(verdict(0x0659_009C, 0x1_0000_0000) == .tooWide)
  // Listed, but in a page no range of this agent holds.
  let elsewhere = CPPCWrite(address: 0x0659_009C, value: 1, width: 32)
  #expect(elsewhere.verdict(registers: listed, windows: [(0x0660_0000, 0x1000)]) == .notGranted)
  #expect(elsewhere.verdict(registers: listed, windows: []) == .notGranted)
  // Nothing listed: nothing is written.
  #expect(elsewhere.verdict(registers: [], windows: windows) == .notListed)
  // A register must lie wholly in one window.
  let last = CPPCWrite(address: 0x0659_0FFC, value: 1, width: 32)
  let lastListed = [CPPCRegister(address: 0x0659_0FFC, width: 32)]
  #expect(last.verdict(registers: lastListed, windows: windows) == .write(window: 0, offset: 0xFFC))
  #expect(last.verdict(registers: lastListed, windows: [(0x0659_0000, 0xFFC)]) == .notGranted)
}
