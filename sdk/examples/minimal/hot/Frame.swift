// SPDX-License-Identifier: BSD-3-Clause

// minimal's frame as a hot image (hotreload(2)): libminimal-frame.so,
// which minimal-hot reloads while it runs. It fills the window with a
// colour that moves with the frames it has drawn, which its state keeps
// across reloads, and returns its version. Built four ways for the test:
// version 1; HOT_V2, version 2 in another colour, over the same state;
// HOT_LAYOUT2, whose state has another layout, which the host refuses;
// and HOT_10K, version 4, with 10,000 generated lines beside it, whose
// reload is timed from the build (reload.module_10k).

import Hot

#if HOT_LAYOUT2
@HotState struct MinimalState {
  var drawn: Int64
  var stride: Int32
}
let version: Int32 = 3
let base: UInt32 = 0x339966
#else
@HotState struct MinimalState {
  var drawn: Int64
}
#if HOT_V2
let version: Int32 = 2
let base: UInt32 = 0x993366
#elseif HOT_10K
let version: Int32 = 4
let base: UInt32 = 0x666633
#else
let version: Int32 = 1
let base: UInt32 = 0x336699
#endif
#endif

@c public func hot_frame(_ state: UnsafeMutableRawPointer, _ frame: UnsafeMutableRawPointer) -> Int32 {
  let s = unsafe state.assumingMemoryBound(to: MinimalState.self)
  let f = unsafe frame.load(as: HotFrame.self)
  let shade = UInt32(truncatingIfNeeded: unsafe s.pointee.drawn) & 0x3F
  f.fill(x: 0, y: 0, width: Int(f.width), height: Int(f.height), base &+ shade)
  unsafe s.pointee.drawn += 1
  return version
}
