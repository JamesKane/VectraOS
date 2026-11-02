// SPDX-License-Identifier: BSD-3-Clause

// The K1's I2C controller as bin/k1-i2c drives it: a transfer's bytes and
// the control word each is sent with.

import K1I2C
import Testing

@Test func aRegisterReadIsItsNumberThenARepeatedStart() {
  // The P1's version register (0xA1): written, then one byte read.
  let s = K1I2C.steps(address: 0x41, write: [0xA1], read: 1)
  #expect(s == [.address(0x82, stop: false), .send(0xA1, stop: false), .address(0x83, stop: false),
                .receive(last: true)])
  let base = K1I2C.base(frequency: 400_000)
  #expect(base & K1I2C.Control.fast != 0 && K1I2C.base(frequency: 100_000) & K1I2C.Control.fast == 0)
  #expect(s[0].control(base) == base | 0b1001)
  #expect(s[1].control(base) == base | 0b1000)
  // The last byte read is NAKed and the transfer STOPped.
  #expect(s[3].control(base) == base | 0b1110)
  #expect(s.map(\.done) == [K1I2C.Status.txEmpty, K1I2C.Status.txEmpty, K1I2C.Status.txEmpty, K1I2C.Status.rxFull])
}

@Test func aWriteEndsWithItsLastByteAndAProbeIsItsAddress() {
  let w = K1I2C.steps(address: 0x41, write: [0x7E, 0x04], read: 0)
  #expect(w == [.address(0x82, stop: false), .send(0x7E, stop: false), .send(0x04, stop: true)])
  #expect(K1I2C.steps(address: 0x41, write: [], read: 0) == [.address(0x82, stop: true)])
  #expect(K1I2C.steps(address: 0x41, write: [], read: 2) == [.address(0x83, stop: false), .receive(last: false),
                                                             .receive(last: true)])
  #expect(w.map(\.byte) == [0x82, 0x7E, 0x04] && K1I2C.Step.receive(last: true).byte == nil)
}
