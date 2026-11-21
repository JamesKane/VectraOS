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

    // 1. A uniform r32uint buffer into a storage one, with an atomic add: where the device claims atomics.
    var firstProblem: GPUError?
    let count = 16
    var list = GPUCommandList()
    if gpu.limits.formats(.r32uint).storageTexelBufferAtomic {
    let source = try upload(count * 4)
    let target = try gpu.allocate(.readback, bytes: count * 4)
    var words: [UInt32] = []
    for i in 0..<count { words.append(UInt32(i * 11 + 2)) }
    put32(source, words)
    for i in 0..<count { unsafe target.pointer!.storeBytes(of: 0xDEAD_BEEF, toByteOffset: i * 4, as: UInt32.self) }
    try gpu.writeTexelBuffer(0, BufferView(source, format: .r32uint))
    try gpu.writeStorageTexelBuffer(0, BufferView(target, format: .r32uint))
    list = GPUCommandList()
    list.dispatch(a, root: 0, x: 1, y: 1, z: 1)
    try run(list)
    var wrong = 0
    for i in 0..<count where word(target, i) != words[i] &* 3 &+ UInt32(i) &+ 1 { wrong += 1 }
    if wrong != 0 {
      var got: [String] = []
      for i in 0..<4 { got.append(String(word(target, i))) }
      print("loinnir-test: texel buffers: stores read \(got.joined(separator: ", ")) for the first four texels, expected \((0..<4).map { String(words[$0] * 3 + UInt32($0) + 1) }.joined(separator: ", "))")
      firstProblem = failure("texel buffers: \(wrong) of \(count) texels wrong, the first is \(word(target, 0)), expected \(words[0] * 3 + 1)")
    } else {
    print("loinnir-test: ok: texel buffers (\(count) r32uint texels fetched from a uniform texel buffer, stored to a storage one and given an atomic add: exact)")
    }
    } else {
      print("loinnir-test: skipped: texel buffer atomics (the device does not claim them)")
    }

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
    print("loinnir-test: texel buffer sizes: \(sizes.map { String($0) }.joined(separator: ", ")) (expected \(count) each)")
    if !mismatches.isEmpty {
      for m in mismatches { print("loinnir-test: texel buffer mismatch: \(m)") }
      if let p = firstProblem { print("loinnir-test: (the stores check failed too: \(p))") }
      throw failure("texel buffer fetches as four channels: \(4 * count - exact) of \(4 * count) texels differ from the formats' definitions")
    }
    if sizes != [UInt32](repeating: UInt32(count), count: 4) { throw failure("texel buffer sizes differ from \(count)") }
    print("loinnir-test: ok: texel buffers fetched as vec4 (r32f, rgba8, rg32f and r8: \(exact) texels exact, the channels a format lacks read as (0, 0, 1) by the hardware)")
    if let p = firstProblem { throw p }
  }

  /// One invocation's accesses to one storage texel in program order (texelorder.comp): which of a read after a store and a read after an atomic
  /// sees what the access before it did, and whether an atomic alone adds.
  func texelOrder() throws(GPUError) {
    let count = 16
    let pipeline = try gpu.makeComputePipeline(spirv: LoinnirShaders.texelorderComp)
    let first = try gpu.allocate(.readback, bytes: count * 4)
    let second = try gpu.allocate(.readback, bytes: count * 4)
    for i in 0..<count {
      unsafe first.pointer!.storeBytes(of: 5, toByteOffset: i * 4, as: UInt32.self)
      unsafe second.pointer!.storeBytes(of: 0, toByteOffset: i * 4, as: UInt32.self)
    }
    try gpu.writeStorageTexelBuffer(0, BufferView(first, format: .r32uint))
    try gpu.writeStorageTexelBuffer(1, BufferView(second, format: .r32uint))
    let out = try gpu.allocate(.readback, bytes: 4096)
    for i in 0..<1024 { unsafe out.pointer!.storeBytes(of: 0xDEAD_BEEF, toByteOffset: i * 4, as: UInt32.self) }
    let other = try upload(count * 4)
    let params = try upload(64)
    put32(params, [UInt32(truncatingIfNeeded: out.address), UInt32(truncatingIfNeeded: out.address >> 32),
                   UInt32(truncatingIfNeeded: other.address), UInt32(truncatingIfNeeded: other.address >> 32)])
    for i in 0..<count { unsafe out.pointer!.storeBytes(of: 0, toByteOffset: (48 + i) * 4, as: UInt32.self) }
    for i in 0..<count { unsafe out.pointer!.storeBytes(of: 0xDEAD_BEEF, toByteOffset: (64 + i) * 4, as: UInt32.self) }
    for i in 0..<count { unsafe first.pointer!.storeBytes(of: 0x5A5A_5A5A, toByteOffset: (count + i) * 4, as: UInt32.self) }
    var list = GPUCommandList()
    list.dispatch(pipeline, root: params.address, x: 1, y: 1, z: 1)
    try run(list)
    func line(_ name: String, _ got: [UInt32], _ want: [UInt32]) -> Int {
      var bad = 0
      for i in 0..<count where got[i] != want[i] { bad += 1 }
      print("loinnir-test: texel buffer order: \(name): \(bad) of \(count) differ; texel 3 read \(got[3]), program order says \(want[3])")
      return bad
    }
    let a = (0..<count).map { word(out, $0) }
    let b = (0..<count).map { word(out, 16 + $0) }
    let c = (0..<count).map { word(out, 32 + $0) }
    let f = (0..<count).map { word(first, $0) }
    let s = (0..<count).map { word(second, $0) }
    // The reads and the store are judged. The atomics are the device's to claim (`storageTexelBufferAtomic`): where it does not, what they did is
    // printed, as a probe, and not judged.
    var bad = line("a read", a, [UInt32](repeating: 5, count: count))
    // Past the end (a guarded store and atomic: the atomic gives 0 and nothing after the buffer changes, with no fault).
    bad += line("an atomic past the end", (0..<count).map { word(out, 64 + $0) }, [UInt32](repeating: 0, count: count))
    bad += line("memory past the end after a store", (0..<count).map { word(first, count + $0) }, [UInt32](repeating: 0x5A5A_5A5A, count: count))
    bad += line("a read after a store", b, (0..<count).map { UInt32(100 + $0) })
    let atomics = gpu.limits.formats(.r32uint).storageTexelBufferAtomic
    var atomicBad = line("a read after an atomic add", c, (0..<count).map { UInt32(101 + $0) })
    atomicBad += line("the texel at the end", f, (0..<count).map { UInt32(101 + $0) })
    atomicBad += line("an atomic add alone", s, [UInt32](repeating: 1, count: count))
    let g = (0..<count).map { word(out, 48 + $0) }
    let h = (0..<count).map { word(other, $0) }
    atomicBad += line("an atomic add on a buffer's word (readback memory)", g, [UInt32](repeating: 1, count: count))
    atomicBad += line("an atomic add on a buffer's word (upload memory)", h, [UInt32](repeating: 1, count: count))
    if atomics { bad += atomicBad } else if atomicBad != 0 {
      print("loinnir-test: atomic probe: no atomic add took effect on this GPU, on a texel buffer or a plain buffer (\(atomicBad) of 7 x \(count) values differ): the device does not claim texel-buffer atomics")
    }
    if bad != 0 { throw failure("texel buffer accesses in program order: \(bad) values differ") }
    print("loinnir-test: ok: texel buffer accesses of one invocation are in program order (a read, a store and a read after it\(atomics ? ", an atomic add and a read after it" : ""))")
  }
}
