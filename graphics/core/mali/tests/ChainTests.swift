// SPDX-License-Identifier: BSD-3-Clause

// A list's steps chained on the GPU (Execute.swift, StepChain): one submit for the whole list, each step's streams waiting
// for the chain's sync object to pass the step before, each step adding one when it is done; passes of any number of
// draws; and the submissions' memory taken from the arena (Arena.swift), so a frame loop makes no buffers.

import GPUCore
import MaliFakeTransport
import Testing

@testable import GPUCoreMali

/// What a stream does with the chain: the references of its SYNC_WAIT64s and the count of its SYNC_ADD64s on `address`,
/// following MOVE48 and MOVE32 into the registers they name.
func chainUse(_ words: [UInt64], address: UInt64) -> (waits: [UInt64], adds: Int) {
  var registers = [UInt64](repeating: 0, count: 256)
  var waits: [UInt64] = []
  var adds = 0
  for w in words {
    let op = w >> 56
    let r = Int(w >> 48 & 0xFF)
    if op == 1 { registers[r] = w & 0xFFFF_FFFF_FFFF }
    if op == 2 { registers[r] = UInt64(UInt32(truncatingIfNeeded: w)) }
    func pair(_ i: Int) -> UInt64 { registers[i] | registers[i + 1] << 32 }
    let a = Int(w >> 40 & 0xFF), v = Int(w >> 32 & 0xFF)
    if op == 53 && pair(a) == address { waits.append(pair(v)) }
    if op == 51 && pair(a) == address && pair(v) == 1 { adds += 1 }
  }
  return (waits, adds)
}

@Suite struct ChainTests {
  @Test func aListOfStepsIsOneSubmitAndEachStepWaitsOnTheGPUForTheOneBefore() throws {
    let (gpu, t) = try device()
    let pipeline = try trianglePipeline(gpu)
    let a = try gpu.makeImage(ImageDescriptor(format: .rgba8, width: 64, height: 64, usage: .renderTarget | .sampled | .copySource))
    let b = try gpu.makeImage(ImageDescriptor(format: .rgba8, width: 64, height: 64, usage: .renderTarget | .copySource))
    let out = try gpu.allocate(.readback, bytes: 64 * 64 * 4)
    var list = GPUCommandList()
    list.render(RenderingInfo(colors: [Attachment(image: a, load: .clear(0, 0, 0, 1))])) { r in r.draw(pipeline, root: 0x1000, vertices: 3) }
    list.render(RenderingInfo(colors: [Attachment(image: b, load: .clear(0, 0, 0, 1))])) { r in r.draw(pipeline, root: 0x1000, vertices: 3) }
    list.copy(b, to: out)
    try gpu.run(list, signal: 1)
    #expect(t.submits.count == 1)
    let s = t.submits[0]
    // The three queues' start streams first (the group's first submit), then the steps.
    #expect(s.jobs.map { $0.queue } == [0, 1, 2, 0, 1, 0, 1, 2])
    #expect(s.signals.count == 1 && s.signals[0].value == 1)
    let chain = try #require(gpu.chainRegion).address
    #expect(t.streams.prefix(3).allSatisfy { chainUse($0, address: chain) == ([], 0) })
    let uses = t.streams.dropFirst(3).map { chainUse($0, address: chain) }
    // The first pass waits for nothing; the second pass's tiling stream waits for the first step (above 0), and its fragment
    // stream not (the first ended on its queue, whose order is the wait); the copy waits for the second (above 1). Each
    // step's last stream adds one: the passes' fragment streams and the copy's.
    #expect(uses.map { $0.waits } == [[], [], [0], [], [1]])
    #expect(uses.map { $0.adds } == [0, 1, 0, 1, 1])
    #expect(gpu.chainValue == 3)
    // The next list's first step waits for the last step of this one.
    t.streams = []
    try gpu.run(list, signal: 2)
    #expect(t.streams.map { chainUse($0, address: chain).waits } == [[2], [2], [3], [], [4]])
  }

  @Test func stepsOnTheQueueTheLastEndedOnDontWait() throws {
    let (gpu, t) = try device()
    let m = try gpu.allocate(.device, bytes: 4096)
    var list = GPUCommandList()
    list.fill(m, bytes: 4096, value: 1)
    list.fill(m, bytes: 4096, value: 2)
    try gpu.run(list, signal: 1)
    let chain = try #require(gpu.chainRegion).address
    // Two kernels on the compute queue: the second follows the first in the queue's order, and both add their one.
    #expect(t.streams.dropFirst(3).map { chainUse($0, address: chain).waits } == [[], []])
    #expect(t.streams.dropFirst(3).map { chainUse($0, address: chain).adds } == [1, 1])
    #expect(gpu.chainValue == 2)
  }

  @Test func aPassTakesAHundredDrawsAndMore() throws {
    let (gpu, t) = try device()
    let pipeline = try trianglePipeline(gpu)
    let target = try gpu.makeImage(ImageDescriptor(format: .rgba8, width: 64, height: 64, usage: .renderTarget))
    var list = GPUCommandList()
    list.render(RenderingInfo(colors: [Attachment(image: target, load: .clear(0, 0, 0, 1))])) { r in
      for i in 0..<300 { r.draw(pipeline, root: 0x1000, vertices: 3, firstVertex: UInt32(i)) }
      r.clearAttachments([.color(index: 0, .float(1, 0, 0, 1))], rects: [ClearRect(width: 8, height: 8)])
    }
    try gpu.run(list, signal: 1)
    #expect(t.submits.count == 1 && t.submits[0].jobs.count == 5)
    // The tiler's stream issues a RUN_IDVS2 (opcode 12) for each draw and the clear.
    let runs = t.streams[3].filter { $0 >> 56 == 12 }.count
    #expect(runs == 301)
  }

  @Test func aFrameLoopMakesNoBuffersOnceTheArenaHasItsChunk() throws {
    let (gpu, t) = try device()
    gpu.profiling = true
    let pipeline = try trianglePipeline(gpu)
    let target = try gpu.makeImage(ImageDescriptor(format: .rgba8, width: 64, height: 64, usage: .renderTarget | .copySource))
    let out = try gpu.allocate(.readback, bytes: 64 * 64 * 4)
    var list = GPUCommandList()
    list.render(RenderingInfo(colors: [Attachment(image: target, load: .clear(0, 0, 0, 1))])) { r in r.draw(pipeline, root: 0x1000, vertices: 3) }
    list.copy(target, to: out)
    try gpu.run(list, signal: 1)
    let bound = t.bound.count
    for n in 2...40 {
      try gpu.run(list, signal: UInt64(n))
      #expect(gpu.lastProfile.buffers == 0, "frame \(n)")
    }
    #expect(t.bound.count == bound)
    #expect(gpu.arena.chunks.count == 1)
  }

  @Test func theHeapIsCopiedOnlyWhenItWasWrittenSince() throws {
    let (gpu, _) = try device()
    var held: [Region] = []
    let first = try gpu.snapshotHeap(held: &held)
    #expect(try gpu.snapshotHeap(held: &held) === first && held.isEmpty)
    gpu.samplerWords[0] = 1
    let second = try gpu.snapshotHeap(held: &held)
    // A new copy, and the old one goes with the submission that replaced it.
    #expect(second !== first && held.count == 1 && held[0] === first)
  }
}
