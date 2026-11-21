// SPDX-License-Identifier: BSD-3-Clause

// loinnir-test's check of the heap's texel buffers on the Mali backend (D174; gpucore(2); valhall 03 3.4.1, 3.5 and 12b.14): two
// compute shaders through the core's own commands, each judged exactly against what the CPU says the memory holds.
//
//  1. texelbuffer.comp: texel i of the first uniform texel buffer (r32uint) fetched, stored (three times it, plus i) to the first
//     storage one (r32uint), and given an atomic add of one: the result is src * 3 + i + 1.
//  2. texelfill.comp: texel i of four uniform views (r32float, rgba8, rg32float and r8, binding 3's elements 0 to 3) fetched as a vec4,
//     the four channels' bits written out, and the views' sizes. The channels a view lacks are what 12b.14.1 only infers from the pixel
//     format word's component order (LD_CVT filling an r32f fetch as four channels with (0, 0, 1)); the board says: the check prints
//     what each view read, and counts a mismatch with the inference as a failure.

import GPUCore
import GPUCoreMali
import Loinnir
import Sys

extension CoreChecks {
  func texelBuffers() throws(GPUError) {
    let a = try gpu.makeComputePipeline(spirv: LoinnirShaders.texelbufferComp)
    let b = try gpu.makeComputePipeline(spirv: LoinnirShaders.texelfillComp)

    // 1. A uniform r32uint buffer into a storage one.
    let count = 16
    let source = try upload(count * 4)
    let target = try gpu.allocate(.readback, bytes: count * 4)
    var words: [UInt32] = []
    for i in 0..<count { words.append(UInt32(i * 11 + 2)) }
    put32(source, words)
    for i in 0..<count { unsafe target.pointer!.storeBytes(of: 0xDEAD_BEEF, toByteOffset: i * 4, as: UInt32.self) }
    try gpu.writeTexelBuffer(0, BufferView(source, format: .r32uint))
    try gpu.writeStorageTexelBuffer(0, BufferView(target, format: .r32uint))
    var list = GPUCommandList()
    list.dispatch(a, root: 0, x: 1, y: 1, z: 1)
    try run(list)
    var wrong = 0
    for i in 0..<count where word(target, i) != words[i] &* 3 &+ UInt32(i) &+ 1 { wrong += 1 }
    if wrong != 0 {
      throw failure("texel buffers: \(wrong) of \(count) texels wrong, the first is \(word(target, 0)), expected \(words[0] * 3 + 1)")
    }
    print("loinnir-test: ok: texel buffers (\(count) r32uint texels fetched from a uniform texel buffer, stored to a storage one and given an atomic add: exact)")

    // 2. Four views fetched as vec4.
    let floats = try upload(count * 4)
    let colours = try upload(count * 4)
    let pairs = try upload(count * 8)
    let bytes = try upload(count)
    var f: [UInt32] = []
    var c: [UInt32] = []
    var p: [UInt32] = []
    for i in 0..<count {
      f.append((Float(i) * 0.5 + 0.25).bitPattern)
      var texel: UInt32 = 0
      for k in 0..<4 { texel |= (UInt32(truncatingIfNeeded: i * 16 + k * 40 + 3) & 0xFF) << UInt32(8 * k) }
      c.append(texel)
      p.append((Float(i) + 0.125).bitPattern)
      p.append((Float(i) * 4 + 0.5).bitPattern)
    }
    put32(floats, f)
    put32(colours, c)
    put32(pairs, p)
    for i in 0..<count { unsafe bytes.pointer!.storeBytes(of: UInt8(truncatingIfNeeded: i * 17 + 1), toByteOffset: i, as: UInt8.self) }
    try gpu.writeTexelBuffer(0, BufferView(floats, format: .r32float))
    try gpu.writeTexelBuffer(1, BufferView(colours, format: .rgba8))
    try gpu.writeTexelBuffer(2, BufferView(pairs, format: .rg32float))
    try gpu.writeTexelBuffer(3, BufferView(bytes, format: .r8))
    let out = try gpu.allocate(.readback, bytes: 4096)
    for i in 0..<1024 { unsafe out.pointer!.storeBytes(of: 0xDEAD_BEEF, toByteOffset: i * 4, as: UInt32.self) }
    let params = try upload(64)
    put32(params, [UInt32(truncatingIfNeeded: out.address), UInt32(truncatingIfNeeded: out.address >> 32)])
    list = GPUCommandList()
    list.dispatch(b, root: params.address, x: 1, y: 1, z: 1)
    try run(list)

    func channels(_ k: Int, _ i: Int) -> [UInt32] { (0..<4).map { word(out, (k * 16 + i) * 4 + $0) } }
    let one = Float(1).bitPattern
    var exact = 0
    var mismatches: [String] = []
    func judgeChannels(_ name: String, _ k: Int, _ want: (Int) -> [UInt32]) {
      var bad = 0
      for i in 0..<count where channels(k, i) != want(i) {
        if bad == 0 { mismatches.append("\(name) texel \(i): read \(channels(k, i).map { String($0, radix: 16) }), expected \(want(i).map { String($0, radix: 16) })") }
        bad += 1
      }
      exact += count - bad
    }
    judgeChannels("r32f", 0) { [f[$0], 0, 0, one] }
    judgeChannels("rgba8", 1) { i in (0..<4).map { (Float(c[i] >> UInt32(8 * $0) & 0xFF) / 255).bitPattern } }
    judgeChannels("rg32f", 2) { [p[2 * $0], p[2 * $0 + 1], 0, one] }
    judgeChannels("r8", 3) { [(Float(UInt8(truncatingIfNeeded: $0 * 17 + 1)) / 255).bitPattern, 0, 0, one] }
    // What each lacking view read in the channels it has not, for the report (the first texel).
    func hex(_ w: UInt32) -> String { "0x" + String(w, radix: 16) }
    for (k, name) in ["r32f", "rgba8", "rg32f", "r8"].enumerated() {
      let t = channels(k, 1)
      print("loinnir-test: texel buffer fetch as vec4: \(name) texel 1 reads (\(t.map(hex).joined(separator: ", ")))")
    }
    let r = channels(0, 5)
    print("loinnir-test: texel buffer channel fill: an r32f texel fetched as a vec4 reads (g, b, a) = (\(hex(r[1])), \(hex(r[2])), \(hex(r[3])))"
      + " (valhall 12b.14.1 infers (0x0, 0x0, 0x3f800000))")
    let sizes = (0..<4).map { word(out, 256 + $0) }
    print("loinnir-test: texel buffer sizes: \(sizes) (expected \([count, count, count, count]))")
    if !mismatches.isEmpty {
      for m in mismatches { print("loinnir-test: texel buffer mismatch: \(m)") }
      throw failure("texel buffer fetches as four channels: \(4 * count - exact) of \(4 * count) texels differ from the formats' definitions")
    }
    if sizes != [UInt32](repeating: UInt32(count), count: 4) { throw failure("texel buffer sizes \(sizes)") }
    print("loinnir-test: ok: texel buffers fetched as vec4 (r32f, rgba8, rg32f and r8: \(exact) texels exact, the channels a format lacks read as (0, 0, 1) by the hardware)")
  }
}
