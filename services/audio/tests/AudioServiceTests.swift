// SPDX-License-Identifier: BSD-3-Clause

// The audio service's graph (D179): push streams queued and mixed a
// quantum at a time into a device's format, clipped; a late stream's
// underruns its own; a closed stream played out, then dropped.

import AudioMix
import Testing

func frames(_ pairs: [(Int16, Int16)]) -> [UInt8] {
  var b: [UInt8] = []
  for (l, r) in pairs {
    let l = UInt16(bitPattern: l), r = UInt16(bitPattern: r)
    b += [UInt8(truncatingIfNeeded: l), UInt8(truncatingIfNeeded: l >> 8), UInt8(truncatingIfNeeded: r),
          UInt8(truncatingIfNeeded: r >> 8)]
  }
  return b
}

func s16(_ b: [UInt8]) -> [Int16] {
  stride(from: 0, to: b.count, by: 2).map { Int16(bitPattern: UInt16(b[$0]) | UInt16(b[$0 + 1]) << 8) }
}

func render(_ g: Graph, _ n: Int, _ format: DeviceFormat) -> ([UInt8], Bool) {
  var out = [UInt8](repeating: 0xEE, count: n * format.frameBytes)
  let gave = out.withUnsafeMutableBytes { g.render(frames: n, format: format, into: $0) }
  return (out, gave)
}

let stereo16 = DeviceFormat(sample: .s16, channels: 2)

@Test func aStreamQueuesWritesWholeAndRefusesOnceFull() {
  let s = PushStream(id: 1)
  #expect(s.write([UInt8](repeating: 0, count: 40000)) == 40000)
  #expect(s.write([UInt8](repeating: 0, count: 30000)) == nil)  // 70000 > 65536
  #expect(s.write([UInt8](repeating: 0, count: 20000)) == 20000)
  #expect(s.buffered == 60000)
  // An empty stream takes any write, even one past its capacity.
  let t = PushStream(id: 2)
  #expect(t.write([UInt8](repeating: 0, count: 70000)) == 70000)
}

@Test func twoStreamsAreSummedIntoTheDevicesFormat() {
  let g = Graph()
  let a = g.open(), b = g.open()
  _ = a.write(frames([(1000, -1000), (2000, 0)]))
  _ = b.write(frames([(500, 500), (-3000, 100)]))
  #expect(g.pending)
  let (out, gave) = render(g, 2, stereo16)
  #expect(gave)
  let v = s16(out)
  // Each within a step of the exact sum, scaled 32768 in and 32767 out.
  let want: [Int16] = [1500, -500, -1000, 100]
  #expect(zip(v, want).allSatisfy { abs(Int($0) - Int($1)) <= 1 })
  #expect(!g.pending)
  #expect(a.frames == 2 && b.frames == 2)
}

@Test func theMixIsClippedNotWrapped() {
  let g = Graph()
  _ = g.open().write(frames([(30000, -30000)]))
  _ = g.open().write(frames([(30000, -30000)]))
  let (out, _) = render(g, 1, stereo16)
  #expect(s16(out) == [32767, -32767])
}

@Test func otherDeviceFormatsAndChannels() {
  let g = Graph()
  _ = g.open().write(frames([(16384, -16384)]))
  let (mono, _) = render(g, 1, DeviceFormat(sample: .s16, channels: 1))
  #expect(s16(mono) == [0])
  _ = g.open().write(frames([(16384, 0)]))
  let (wide, _) = render(g, 1, DeviceFormat(sample: .s16, channels: 4))
  #expect(s16(wide) == [16384, 0, 0, 0])
  _ = g.open().write(frames([(-32768, 16384)]))
  let (f, _) = render(g, 1, DeviceFormat(sample: .f32, channels: 2))
  let l = Float(bitPattern: UInt32(f[0]) | UInt32(f[1]) << 8 | UInt32(f[2]) << 16 | UInt32(f[3]) << 24)
  let r = Float(bitPattern: UInt32(f[4]) | UInt32(f[5]) << 8 | UInt32(f[6]) << 16 | UInt32(f[7]) << 24)
  #expect(l == -1 && r == 0.5)
  _ = g.open().write(frames([(16384, 0)]))
  let (s, _) = render(g, 1, DeviceFormat(sample: .s32, channels: 2))
  let s32 = Int32(bitPattern: UInt32(s[0]) | UInt32(s[1]) << 8 | UInt32(s[2]) << 16 | UInt32(s[3]) << 24)
  #expect(abs(Int(s32) - 1_073_741_823) < 256)
  #expect(DeviceFormat(sampleIndex: 2, channels: 2) == stereo16)
  #expect(DeviceFormat(sampleIndex: 0, channels: 2) == nil)
}

@Test func aLateStreamIsSilenceAndCountsItsOwnUnderruns() {
  let g = Graph()
  let s = g.open()
  // Not started: silence, no underrun.
  var (out, gave) = render(g, 4, stereo16)
  #expect(!gave && out.allSatisfy { $0 == 0 } && s.underruns == 0)
  _ = s.write(frames([(100, 100), (100, 100), (100, 100), (100, 100), (7, 7)]))
  (out, gave) = render(g, 4, stereo16)
  #expect(gave && s.underruns == 0)
  // One frame of the next quantum: the rest silence, an underrun.
  (out, gave) = render(g, 4, stereo16)
  #expect(gave && s16(out) == [7, 7, 0, 0, 0, 0, 0, 0])
  #expect(s.underruns == 1)
  (out, gave) = render(g, 4, stereo16)
  #expect(!gave && s.underruns == 1)
  #expect(g.quanta == 4 && g.audible == 2)
}

@Test func aClosedStreamPlaysOutThenGoes() {
  let g = Graph()
  let s = g.open()
  _ = s.write(frames([(1, 1), (2, 2), (3, 3)]))
  s.close()
  #expect(g.all.count == 1)
  let (out, _) = render(g, 2, stereo16)
  #expect(s16(out) == [1, 1, 2, 2])
  let (rest, _) = render(g, 2, stereo16)
  #expect(s16(rest) == [3, 3, 0, 0])
  #expect(s.underruns == 0)  // closing, not late
  _ = render(g, 2, stereo16)
  #expect(g.all.isEmpty)
}

@Test func droppingAStreamLeavesNothingAndCountsNothing() {
  let s = PushStream(id: 1)
  _ = s.write(frames([(1, 1)]))
  s.drop()
  #expect(s.buffered == 0 && s.underruns == 0)
}
