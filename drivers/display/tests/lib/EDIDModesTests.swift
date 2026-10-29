// SPDX-License-Identifier: BSD-3-Clause

// An output's modes from its monitor's EDID (D146): the Orange Pi 6
// Plus's DELL ST2421L, as dptx(3) read it through the PS185.

import DisplayDevice
import Testing

let st2421l: [UInt8] = hexBytes("""
  00ffffffffffff0010ac70a055464631 2f15010380351e78ea9265a655559f28 0d5054a54b00714f8180d1c001010101
  010101010101023a801871382d40582c 4500132b2100001e000000ff00545044 5450314245314646550a000000fc0044
  454c4c205354323432314c0a000000fd 00384c1e5311000a2020202020200140 02031ff14c9005040302071601141f12
  132309070765030c0010008301000002 3a801871382d40582c4500132b210000 1e011d8018711c1620582c2500132b21
  00009e011d007251d01e206e28550013 2b2100001e8c0ad08a20e02d10103e96 00132b21000018000000000000000000
  0000000000000000000000000000001b
  """)

func hexBytes(_ s: String) -> [UInt8] {
  var out: [UInt8] = [], high: UInt8?
  for c in s.utf8 {
    let v: UInt8
    switch c {
    case 0x30...0x39: v = c - 0x30
    case 0x61...0x66: v = c - 0x57
    default: continue
    }
    if let h = high {
      out.append(h << 4 | v)
      high = nil
    } else {
      high = v
    }
  }
  return out
}

@Test func theMonitorsModesArePreferredThenLargest() {
  let modes = EDID.modes(st2421l)
  #expect(modes.count == 16)
  // The first detailed timing, its syncs positive.
  #expect(modes[0] == ModeTiming(148_500, (1920, 2008, 2052, 2200), (1080, 1084, 1089, 1125), true, true))
  #expect(modes[0].refresh == 60_000)
  // 1080i (an interlaced detailed timing, codes 5 and 20) is left out;
  // 720p's detailed timing and code 4 are one mode.
  #expect(modes.filter { $0.hActive == 1280 && $0.vActive == 720 }.count == 2)
  #expect(!modes.contains { $0.vActive == 540 })
  // Established and standard timings from the DMT table: 640x480 at 60 negative.
  let vga = modes.first { $0.hActive == 640 && $0.refresh < 60_000 }
  #expect(vga?.clock == 25175 && vga?.hPositive == false && vga?.refresh == 59_940)
  #expect(modes.contains { $0.hActive == 1152 && $0.vActive == 864 })
  #expect(modes.last!.hActive == 720 && modes.last!.vActive == 400)
  #expect(EDID.modes([]) == [])
}
