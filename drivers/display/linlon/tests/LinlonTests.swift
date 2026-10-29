// SPDX-License-Identifier: BSD-3-Clause

// What bin/linlon makes of an engine's registers.

import Linlon
import Testing

@Test func theBlocksAFlipNeedsAreFoundByType() {
  // A D71's window: the GCU, then pipeline 0's LPU and layers 0-3,
  // pipeline 1's layer 4, a writeback layer, a reserved block, and each
  // pipeline's output unit and timing controller.
  var window = [Int: UInt32]()
  let blocks: [UInt32] = [
    0x0100, 0x1000, 0x1010, 0x1020, 0x1030, 0x1040, 0x1100, 0xFF00, 0x0300, 0x3100, 0x0310, 0x3110,
  ]
  for (i, b) in blocks.enumerated() { window[(i + 1) * D71.blockSize] = b }
  let layout = Layout.scan(blocks: blocks.count + 1) { window[$0] ?? 0xFF00 }
  #expect(layout.layers.count == 5)
  #expect(layout.layers[0] == Layout.Layer(pipeline: 0, index: 0, offset: 0x400))
  #expect(layout.layers[4] == Layout.Layer(pipeline: 1, index: 0, offset: 0xC00))
  #expect(layout.outputUnits == [0x1200, 0x1600])
  #expect(layout.timing == [0x1400, 0x1800])
}

@Test func theSky1sEngineIsALinlonD6() {
  // CORE_ID as the Orange Pi 6 Plus's DPU4 reads.
  #expect(D71.productName(coreID: 0x0060_0000) == "Linlon-D6")
  #expect(D71.productName(coreID: 0x0071_2000) == "Mali-D71")
  #expect(D71.productName(coreID: 0x0055_0000) == nil)
}

@Test func theLivePipelineIsTheGCUsActiveOutput() {
  #expect(D71.livePipeline(gcuStatus: 0x8000_0003) == 0)
  #expect(D71.livePipeline(gcuStatus: 4) == 1)
  #expect(D71.livePipeline(gcuStatus: 5) == 0)
  #expect(D71.livePipeline(gcuStatus: 0) == nil)
  #expect(D71.livePipeline(gcuStatus: 1) == nil)
  #expect(D71.modeName(3) == "output 0 active")
}

@Test func aTimingControllerReadsAsItsMode() {
  // 1080p60's CEA timing: 88/44/148 and 4/5/36.
  let t = Timing(activeSize: 1080 << 16 | 1920, hIntervals: 148 << 16 | 88, vIntervals: 36 << 16 | 4,
                 sync: 5 << 16 | 44)
  #expect(t.width == 1920 && t.height == 1080)
  #expect(t.hTotal == 2200 && t.vTotal == 1125)
  #expect(t.text == "1920x1080, total 2200x1125 (h 88/44/148, v 4/5/36)")
  #expect(refresh(frames: 30, nanoseconds: 500_500_000) == 59_940)
  #expect(refresh(frames: 0, nanoseconds: 1) == 0)
}
