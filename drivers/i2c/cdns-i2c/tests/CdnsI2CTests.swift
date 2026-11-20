// SPDX-License-Identifier: BSD-3-Clause

// The Sky1's I2C controller as bin/cdns-i2c drives it: its dividers, a
// transfer's messages, a long read's re-arm, and what its failures mean.

import CdnsI2C
import Testing

@Test func theDividerMakesTheNearestRateNotOverTheTarget() {
  // 100 MHz in: 100 kHz wants 100M / 2200 = 45.45, so B + 1 = 46 (A = 0): 98.814 kHz.
  let d100 = CdnsI2C.dividers(input: 100_000_000, target: 100_000)
  #expect(d100 == CdnsI2C.Dividers(a: 0, b: 45, rate: 98_814))
  // 400 kHz: 11.36, so 12: 378.787 kHz.
  #expect(CdnsI2C.dividers(input: 100_000_000, target: 400_000) == CdnsI2C.Dividers(a: 0, b: 11, rate: 378_787))
  // 200 MHz: 400 kHz is 22.7, so 23 (A = 0, B = 22): 395.256 kHz.
  #expect(CdnsI2C.dividers(input: 200_000_000, target: 400_000)?.rate == 395_256)
  // 100 kHz is 90.9 (B + 1 over 64), so A = 1 and 46: the first of the pairs that tie at 98.814 kHz.
  #expect(CdnsI2C.dividers(input: 200_000_000, target: 100_000) == CdnsI2C.Dividers(a: 1, b: 45, rate: 98_814))
  // An input that divides exactly: 22 MHz at 100 kHz is B + 1 = 10, A = 0.
  #expect(CdnsI2C.dividers(input: 22_000_000, target: 100_000) == CdnsI2C.Dividers(a: 0, b: 9, rate: 100_000))
  // The register bits: B in 13:8, A in 15:14.
  #expect(CdnsI2C.Dividers(a: 2, b: 5, rate: 0).bits == 2 << 14 | 5 << 8)
  #expect(CdnsI2C.base(d100!) == 0b1110 | 45 << 8)
}

@Test func aDividerOutOfRangeIsNone() {
  // The input is below 22 x the target: the rate can't be made.
  #expect(CdnsI2C.dividers(input: 2_000_000, target: 400_000) == nil)
  // Far over 256 x 22 x the target.
  #expect(CdnsI2C.dividers(input: 2_000_000_000, target: 100_000) == nil)
  #expect(CdnsI2C.dividers(input: 0, target: 100_000) == nil && CdnsI2C.dividers(input: 100_000_000, target: 0) == nil)
}

@Test func aTransferIsItsMessagesAndWhichHoldTheBus() {
  let w = CdnsI2C.messages(write: 3, read: 0)
  #expect(w.count == 1 && w[0].last && !w[0].holdAtStart && !w[0].read)
  let r = CdnsI2C.messages(write: 0, read: 4)
  #expect(r.count == 1 && r[0].read && r[0].last && !r[0].holdAtStart && r[0].releasesAtStart)
  // A register read: the register written with HOLD, then the read.
  let wr = CdnsI2C.messages(write: 1, read: 2)
  #expect(wr.count == 2 && !wr[0].last && wr[0].holdAtStart && wr[1].last && !wr[1].holdAtStart)
  // A read longer than the FIFO is held from the start and released late.
  let long = CdnsI2C.messages(write: 0, read: 40)[0]
  #expect(long.holdAtStart && !long.releasesAtStart)
  // A write longer than the FIFO is held too.
  #expect(CdnsI2C.messages(write: 17, read: 0)[0].holdAtStart && !CdnsI2C.messages(write: 16, read: 0)[0].holdAtStart)
  // Nothing to send or read is one byte read and dropped.
  #expect(CdnsI2C.messages(write: 0, read: 0) == [CdnsI2C.Message(read: true, length: 1, last: true, discard: true)])
}

@Test func aWritePushesWhatTheFIFOHolds() {
  #expect(CdnsI2C.pushable(remaining: 40, queued: 0) == 16)
  #expect(CdnsI2C.pushable(remaining: 40, queued: 10) == 6)
  #expect(CdnsI2C.pushable(remaining: 3, queued: 0) == 3)
  #expect(CdnsI2C.pushable(remaining: 5, queued: 16) == 0)
}

@Test func aLongReadRearmsItsCounterBeforeItRunsOut() {
  #expect(CdnsI2C.largestChunk(readBack: 255) == 252)
  #expect(CdnsI2C.firstChunk(length: 40, largest: 252) == 40 && CdnsI2C.firstChunk(length: 256, largest: 252) == 252)
  // 256 bytes, armed for 252: draining stops with 17 of the armed still to come (235 drained).
  #expect(!CdnsI2C.needsRearm(total: 256, drained: 234, armed: 252))
  #expect(CdnsI2C.needsRearm(total: 256, drained: 235, armed: 252))
  let (chunk, armed) = CdnsI2C.rearm(total: 256, drained: 235, largest: 252)
  #expect(chunk == 5 && armed == 256)
  // Once armed for everything it never rearms.
  #expect(!CdnsI2C.needsRearm(total: 256, drained: 240, armed: 256))
  // A message of several chunks: the next chunk is the largest.
  #expect(CdnsI2C.rearm(total: 1000, drained: 100, largest: 252) == (chunk: 252, armed: 368))
  // A read of 40 never needs it; the clear of HOLD is with 16 or fewer to come.
  #expect(!CdnsI2C.needsRearm(total: 40, drained: 23, armed: 40))
  #expect(!CdnsI2C.releasesHold(last: true, expected: 17) && CdnsI2C.releasesHold(last: true, expected: 16))
  #expect(!CdnsI2C.releasesHold(last: false, expected: 1))
  #expect(CdnsI2C.readFits(length: 256, largest: 252) && !CdnsI2C.readFits(length: 100, largest: 12))
  #expect(CdnsI2C.readFits(length: 10, largest: 12))
}

@Test func theInterruptBitsSayWhatFailed() {
  let i = CdnsI2C.Interrupt.self
  #expect(CdnsI2C.failure(isr: i.complete, moved: 0) == nil && CdnsI2C.failure(isr: i.complete | i.data, moved: 4) == nil)
  // A NACK before any byte moved is nothing answering the address; after, a byte refused.
  #expect(CdnsI2C.failure(isr: i.nack, moved: 0) == .noDevice)
  #expect(CdnsI2C.failure(isr: i.nack | i.complete, moved: 2) == .nak)
  #expect(CdnsI2C.failure(isr: i.arbitrationLost | i.nack, moved: 0) == .arbitrationLost)
  for bit in [i.rxOverflow, i.txOverflow, i.rxUnderflow] { #expect(CdnsI2C.failure(isr: bit, moved: 3) == .busError) }
  // The hold timeout is masked and not a failure.
  #expect(CdnsI2C.failure(isr: i.timeout, moved: 0) == nil)
  #expect(i.all == 0x2FF)
}

@Test func theInputClockAndTheBusRateAreRead() {
  let status = "mailbox: SCMI 2.0, vendor cix\nclock 253 on\nclock 253 rate 200000000\ncommands 2, failed 0\n"
  #expect(CdnsI2C.clockRate(status: status, id: 253) == 200_000_000)
  #expect(CdnsI2C.clockRate(status: status, id: 254) == nil)
  #expect(CdnsI2C.clockRate(status: "clock 253 rate 0\n", id: 253) == nil)
  #expect(CdnsI2C.clockRate(status: "clock 0xfd rate 100000000\n", id: 253) == 100_000_000)
  #expect(CdnsI2C.firstNumber("253 \n") == 253 && CdnsI2C.firstNumber("") == nil)
  #expect(CdnsI2C.busRate(properties: "ClockName fch_i2c3_apb\nclock-frequency 400000\n") == 400_000)
  #expect(CdnsI2C.busRate(properties: "clock-frequency 3400000\n") == 400_000)
  #expect(CdnsI2C.busRate(properties: "") == 100_000 && CdnsI2C.busRate(properties: "clock-frequency x\n") == 100_000)
}
