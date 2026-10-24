// SPDX-License-Identifier: BSD-3-Clause

// What bin/linlon makes of an engine's registers, and its two buffers.

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

@Test func eachFlushCopiesItsDamageAndWhatTheOtherBufferGotAlone() {
  var b = Buffers(width: 100, height: 50)
  let whole = Rect(x: 0, y: 0, width: 100, height: 50)
  // The first flush fills the buffer it shows.
  #expect(b.back == 0)
  #expect(b.flush(Rect(x: 10, y: 10, width: 5, height: 5)) == whole)
  b.flipped()
  #expect(b.front == 0 && b.back == 1)
  // The second fills the other, which lacks everything still.
  #expect(b.flush(Rect(x: 20, y: 0, width: 5, height: 5)) == whole)
  b.flipped()
  // The third: its damage and the second's, which buffer 0 lacks.
  #expect(b.flush(Rect(x: 0, y: 40, width: 5, height: 20)) == Rect(x: 0, y: 0, width: 25, height: 50))
  b.flipped()
  // An image shown anew: both stale again.
  b.invalidate()
  #expect(b.flush(Rect(x: 0, y: 0, width: 1, height: 1)) == whole)
}
