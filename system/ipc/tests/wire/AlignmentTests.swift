// SPDX-License-Identifier: BSD-3-Clause

import IPCWire
import Testing

@Test func alignsToEightBytes() {
  #expect(wireAligned(0) == 0)
  #expect(wireAligned(1) == 8)
  #expect(wireAligned(8) == 8)
  #expect(wireAligned(9) == 16)
}
