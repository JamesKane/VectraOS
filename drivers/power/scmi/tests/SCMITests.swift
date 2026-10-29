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
  #expect(Command("clock 41 rate") == nil)
  #expect(Command("clock 41 speed 5") == nil)
  // A rate replaces the clock's last rate, not its gate.
  #expect(Command.rate(id: 41, hertz: 1).sameSubject(.rate(id: 41, hertz: 2)))
  #expect(!Command.rate(id: 41, hertz: 1).sameSubject(.clock(id: 41, on: true)))
}
