// SPDX-License-Identifier: BSD-3-Clause

// The Mali backend's indexed and indirect work and its queries over the fake transport (D174 section 5): the words the
// streams are made of. The registers a draw's run reads are followed through the stream as the GPU would load them, so
// each check says what the hardware is given, in the staging registers' own numbers (valhall 01 section 1.9.3).

import Foundation
import GPUCore
import MaliFakeTransport
import ShaderTestKit
import Testing

@testable import GPUCoreMali

/// A shader of graphics/loinnir/tests/shaders, as bytes.
func spirv(_ name: String) throws -> [UInt8] {
  let here = URL(fileURLWithPath: #filePath)
  let root = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  return [UInt8](try Data(contentsOf: root.appendingPathComponent("loinnir/tests/shaders/" + name + ".spv")))
}

/// The registers of a stream as the instructions before a RUN_IDVS2 (opcode 12) leave them, and what loads follow.
struct DrawRun {
  var registers: [UInt32]
  /// LOAD_MULTIPLEs issued since the previous run: (base register, mask, address register pair's value).
  var loads: [(base: Int, mask: Int, address: UInt64)]
  var waitedForLoads: Bool
  func pair(_ r: Int) -> UInt64 { UInt64(registers[r]) | UInt64(registers[r + 1]) << 32 }
}

func runs(_ stream: [UInt64], opcode: UInt64 = 12) -> [DrawRun] {
  var regs = [UInt32](repeating: 0, count: 256)
  var loads: [(base: Int, mask: Int, address: UInt64)] = []
  var waited = true
  var out: [DrawRun] = []
  for w in stream {
    let op = w >> 56
    let dst = Int(w >> 48 & 0xFF)
    switch op {
    case 1:
      regs[dst] = UInt32(truncatingIfNeeded: w)
      regs[dst + 1] = UInt32(truncatingIfNeeded: w >> 32 & 0xFFFF)
    case 2: regs[dst] = UInt32(truncatingIfNeeded: w)
    case 20:
      let address = UInt64(regs[Int(w >> 40 & 0xFF)]) | UInt64(regs[Int(w >> 40 & 0xFF) + 1]) << 32
      loads.append((dst, Int(w >> 16 & 0xFFFF), address))
      waited = false
      if opcode == 20 { out.append(DrawRun(registers: regs, loads: loads, waitedForLoads: waited)) }
    case 3: if w >> 16 & 1 == 1 { waited = true }
    case opcode:
      out.append(DrawRun(registers: regs, loads: loads, waitedForLoads: waited))
      loads = []
    default: break
    }
  }
  return out
}

func indexedPipeline(_ gpu: MaliDevice) throws -> GPUPipeline { try trianglePipeline(gpu) }

@Suite struct FeatureTests {
  @Test func theFeaturesTheBackendDoesAreOn() throws {
    let (gpu, _) = try device()
    let f = gpu.limits.features
    #expect(f.indexedDraw && f.indirectDraw && f.indirectDispatch && f.occlusionQueries && f.timestampQueries)
    #expect(f.multipleDrawsPerPass && f.storageImages)
  }

  @Test func anIndexedDrawGivesTheTilerItsIndicesTheirTypeAndTheOffsets() throws {
    let (gpu, t) = try device()
    let pipeline = try indexedPipeline(gpu)
    let target = try gpu.makeImage(ImageDescriptor(format: .rgba8, width: 64, height: 64, usage: .renderTarget))
    let indices = try gpu.allocate(.upload, bytes: 256)
    var list = GPUCommandList()
    list.render(RenderingInfo(colors: [Attachment(image: target, load: .clear(0, 0, 0, 1))])) { r in
      r.drawIndexed(pipeline, root: 0x1000, indices: indices, indexOffset: 16, indexType: .uint16, count: 6, instances: 2,
                    firstIndex: 3, vertexOffset: -4, firstInstance: 0)
      r.drawIndexed(pipeline, root: 0x1000, indices: indices, indexType: .uint32, count: 6)
    }
    try gpu.graphicsQueue.submit(list, wait: 0, signal: 1)
    let first = runs(t.streams[0]).prefix(2)
    #expect(first.count == 2)
    let a = first[first.startIndex], b = first[first.startIndex + 1]
    // Counts, first index, base vertex (signed), the data's address, the bytes from it, and the index type in TILER_FLAGS.
    #expect(a.registers[33] == 6 && a.registers[34] == 2 && a.registers[35] == 3)
    #expect(Int32(bitPattern: a.registers[36]) == -4 && a.registers[37] == 0)
    #expect(a.pair(48) == indices.address + 16 && a.registers[50] == 240)
    #expect(a.registers[56] >> 8 & 7 == 2, "16-bit indices")
    #expect(b.pair(48) == indices.address && b.registers[50] == 256 && b.registers[56] >> 8 & 7 == 3, "32-bit indices")
    // A non-indexed draw after them has no index type.
    #expect(a.registers[56] & 0xF == 8, "triangles")
  }

  @Test func aDrawFromAFirstVertexAndInstanceIsTheRegistersAndANonIndexedDrawHasNoIndexType() throws {
    let (gpu, t) = try device()
    let pipeline = try trianglePipeline(gpu)
    let target = try gpu.makeImage(ImageDescriptor(format: .rgba8, width: 64, height: 64, usage: .renderTarget))
    var list = GPUCommandList()
    list.render(RenderingInfo(colors: [Attachment(image: target, load: .clear(0, 0, 0, 1))])) { r in
      r.draw(pipeline, root: 0x1000, vertices: 6, instances: 1, firstVertex: 2, firstInstance: 5)
    }
    try gpu.graphicsQueue.submit(list, wait: 0, signal: 1)
    let run = runs(t.streams[0])[0]
    #expect(run.registers[33] == 6 && run.registers[36] == 2 && run.registers[37] == 5)
    #expect(run.registers[56] >> 8 & 7 == 0)
  }

  @Test func anIndirectDrawIsLoadedFromMemoryByTheStreamAndWaitedFor() throws {
    let (gpu, t) = try device()
    let pipeline = try trianglePipeline(gpu)
    let target = try gpu.makeImage(ImageDescriptor(format: .rgba8, width: 64, height: 64, usage: .renderTarget))
    let args = try gpu.allocate(.upload, bytes: 512)
    let indices = try gpu.allocate(.upload, bytes: 64)
    var list = GPUCommandList()
    list.render(RenderingInfo(colors: [Attachment(image: target, load: .clear(0, 0, 0, 1))])) { r in
      r.drawIndirect(pipeline, root: 0x1000, arguments: args, offset: 32, drawCount: 2, stride: 48)
      r.drawIndexedIndirect(pipeline, root: 0x1000, indices: indices, indexOffset: 8, indexType: .uint16, arguments: args,
                            offset: 256, drawCount: 1)
    }
    try gpu.graphicsQueue.submit(list, wait: 0, signal: 1)
    let all = runs(t.streams[0])
    #expect(all.count == 3)
    // One load of the four words into registers 33, 34, 36 and 37 for each of the two draws, from where each is.
    #expect(all[0].loads.count == 1 && all[0].loads[0].base == 33 && all[0].loads[0].mask == 0b11011)
    #expect(all[0].loads[0].address == args.address + 32 && all[1].loads[0].address == args.address + 80)
    // The five of an indexed draw into 33 to 37; the index data's own registers are the command's.
    #expect(all[2].loads.count == 1 && all[2].loads[0].base == 33 && all[2].loads[0].mask == 0b11111)
    #expect(all[2].loads[0].address == args.address + 256)
    #expect(all[2].pair(48) == indices.address + 8 && all[2].registers[56] >> 8 & 7 == 2)
    #expect(all.allSatisfy { $0.waitedForLoads }, "the run waits for the load/store slot")
    // Each draw's run is guarded (06 section 6.4.7): BRANCH (22) when register 33 is zero over the next two instructions
    // and when register 34 is zero over the next one, which is the run.
    let words = t.streams[0]
    var guards = 0
    for (i, w) in words.enumerated() where w >> 56 == 22 {
      guards += 1
      let register = w >> 40 & 0xFF, condition = w >> 28 & 0xF, offset = Int16(truncatingIfNeeded: w & 0xFFFF)
      #expect(condition == 2, "taken when the value is zero")
      #expect(register == 33 && offset == 2 || register == 34 && offset == 1)
      if register == 34 { #expect(words[i - 1] >> 56 == 22, "the two guards are adjacent") }
    }
    #expect(guards == 6, "two guards for each of the three indirect draws")
  }

  @Test func anIndirectDispatchLoadsTheGridAndGivesTheShaderItsNumWorkgroups() throws {
    let (gpu, t) = try device()
    let fill = try gpu.makeComputePipeline(spirv: try spirv("fill.comp"))
    let args = try gpu.allocate(.upload, bytes: 64)
    var list = GPUCommandList()
    list.dispatchIndirect(fill, root: 0x2000, arguments: args, offset: 12)
    try gpu.graphicsQueue.submit(list, wait: 0, signal: 1)
    let stream = t.streams[0]
    // LOAD_MULTIPLE (20) into JOB_SIZE_X/Y/Z (37 to 39) of three words, RUN_COMPUTE (4) and never RUN_COMPUTE_INDIRECT (44).
    #expect(stream.contains { $0 >> 56 == 20 && $0 >> 48 & 0xFF == 37 && $0 >> 16 & 0xFFFF == 7 })
    #expect(stream.contains { $0 >> 56 == 21 && $0 >> 48 & 0xFF == 37 && $0 >> 16 & 0xFFFF == 7 }, "into the FAU block too")
    #expect(stream.contains { $0 >> 56 == 4 } && !stream.contains { $0 >> 56 == 44 })
    let load = runs(stream, opcode: 20)[0]
    #expect(load.pair(66) == args.address + 12)
    // A zero dimension runs nothing (06 section 6.4.7): three BRANCHes, each taken when its register is zero, over the rest of
    // the guards and the run.
    let branches = stream.enumerated().filter { $0.element >> 56 == 22 }
    #expect(branches.count == 3)
    for (axis, b) in branches.enumerated() {
      #expect(b.element >> 40 & 0xFF == UInt64(37 + axis) && b.element >> 28 & 0xF == 2 && b.element & 0xFFFF == UInt64(3 - axis))
    }
    #expect(stream[branches[2].offset + 1] >> 56 == 4, "the run follows the last guard")
  }

  @Test func aDirectDispatchIsStillTheGridsImmediates() throws {
    let (gpu, t) = try device()
    let fill = try gpu.makeComputePipeline(spirv: try spirv("fill.comp"))
    var list = GPUCommandList()
    list.dispatch(fill, root: 0x2000, x: 5, y: 3, z: 2)
    try gpu.graphicsQueue.submit(list, wait: 0, signal: 1)
    #expect(!t.streams[0].contains { $0 >> 56 == 20 })
  }

  @Test func anOcclusionQueryIsTheDrawsCounterAndStartsAtZero() throws {
    let (gpu, t) = try device()
    let pipeline = try trianglePipeline(gpu)
    let target = try gpu.makeImage(ImageDescriptor(format: .rgba8, width: 64, height: 64, usage: .renderTarget))
    let set = try gpu.makeQuerySet(.occlusion, count: 4)
    var list = GPUCommandList()
    list.render(RenderingInfo(colors: [Attachment(image: target, load: .clear(0, 0, 0, 1))])) { r in
      r.draw(pipeline, root: 0x1000, vertices: 3)
      r.beginQuery(set, index: 2)
      r.draw(pipeline, root: 0x1000, vertices: 3)
      r.draw(pipeline, root: 0x1000, vertices: 3)
      r.endQuery(set, index: 2)
      r.draw(pipeline, root: 0x1000, vertices: 3)
    }
    try gpu.graphicsQueue.submit(list, wait: 0, signal: 1)
    let all = runs(t.streams[0])
    let address = gpu.queries[set.handle]!.region.address + 16
    #expect(all.count == 4)
    // The counter's address is in OQ (register 64) and draw flags 0 `[15:14]` is 3 (counter) for the two draws inside.
    #expect(all.map { $0.pair(64) } == [0, address, address, 0])
    #expect(all.map { $0.registers[57] >> 14 & 3 } == [0, 3, 3, 0])
    // The fragment queue zeroes the report with a store before its fragment work (06 section 6.11.1): MOVE48 of the
    // report's address, STORE_MULTIPLE (21) of two zeroed registers, and a clean flush, all before RUN_FRAGMENT (7).
    let fragment = t.streams[1]
    let store = fragment.firstIndex { $0 >> 56 == 21 }
    let run = fragment.firstIndex { $0 >> 56 == 7 }
    #expect(store != nil && run != nil && store! < run!)
    #expect(fragment.contains { $0 >> 56 == 1 && $0 & 0xFFFF_FFFF_FFFF == address })
    #expect(!t.streams[0].contains { $0 >> 56 == 21 }, "not on the tiling queue")
    #expect(t.cacheableBound.contains(gpu.queries[set.handle]!.region.address), "the counters live in the GPU's caches")
    // The CPU doesn't write it: the other three queries are untouched.
    #expect(try gpu.results(set, first: 0, count: 4) == [0, 0, 0, 0])
  }

  @Test func anOcclusionQuerySetIsMappedCacheableForTheGPUAndATimestampSetIsNot() throws {
    let (gpu, t) = try device()
    #expect(gpu.limits.features.occlusionQueries)
    let occlusion = try gpu.makeQuerySet(.occlusion, count: 1)
    let timestamps = try gpu.makeQuerySet(.timestamp, count: 1)
    #expect(t.cacheableBound.contains(gpu.queries[occlusion.handle]!.region.address))
    #expect(!t.cacheableBound.contains(gpu.queries[timestamps.handle]!.region.address))
  }

  @Test func memoryAndStorageImagesAreMappedCacheableForTheGPUAndOtherImagesAreNot() throws {
    let (gpu, t) = try device()
    #expect(gpu.limits.features.shaderAtomic32 && gpu.limits.features.shaderImageAtomics)
    #expect(gpu.limits.formats(.r32uint).storageAtomic && gpu.limits.formats(.r32uint).storageTexelBufferAtomic)
    for intent in [MemoryIntent.device, .upload, .readback] {
      let m = try gpu.allocate(intent, bytes: 64)
      #expect(t.cacheableBound.contains(m.address), "\(intent)")
    }
    let storage = try gpu.makeImage(ImageDescriptor(format: .r32uint, width: 8, height: 8, usage: .storage))
    let target = try gpu.makeImage(ImageDescriptor(format: .rgba8, width: 8, height: 8, usage: .renderTarget))
    #expect(t.cacheableBound.contains(gpu.images[storage.handle]!.region.address))
    #expect(!t.cacheableBound.contains(gpu.images[target.handle]!.region.address))
  }

  @Test func aQueryMustEndInItsPass() throws {
    let (gpu, _) = try device()
    let pipeline = try trianglePipeline(gpu)
    let target = try gpu.makeImage(ImageDescriptor(format: .rgba8, width: 64, height: 64, usage: .renderTarget))
    let set = try gpu.makeQuerySet(.occlusion, count: 1)
    var open = GPUCommandList()
    open.render(RenderingInfo(colors: [Attachment(image: target, load: .clear(0, 0, 0, 1))])) { r in
      r.beginQuery(set, index: 0)
      r.draw(pipeline, root: 0x1000, vertices: 3)
    }
    #expect(throws: GPUError.self) { try gpu.graphicsQueue.submit(open, wait: 0, signal: 1) }
    var nested = GPUCommandList()
    nested.render(RenderingInfo(colors: [Attachment(image: target, load: .clear(0, 0, 0, 1))])) { r in
      r.beginQuery(set, index: 0)
      r.beginQuery(set, index: 0)
    }
    #expect(throws: GPUError.self) { try gpu.graphicsQueue.submit(nested, wait: 1, signal: 2) }
    #expect(throws: GPUError.self) { try gpu.makeQuerySet(.occlusion, count: 0) }
  }

  @Test func timestampsAreTheCountersValueAndThePeriodIsMeasured() throws {
    // The fake GPU's counter at 1 GHz: a tick is 1000 ps.
    let (gpu, t) = try device()
    #expect(gpu.limits.timestampPeriodPicoseconds == 1000)
    // At 24 MHz: 41666 ps (the period of the rounded frequency, whole picoseconds).
    let slow = FakeTransport()
    slow.timerHertz = 24_000_000
    let slowGPU = try MaliDevice(transport: slow)
    #expect(slowGPU.limits.timestampPeriodPicoseconds == 41666)

    let set = try gpu.makeQuerySet(.timestamp, count: 3)
    var list = GPUCommandList()
    list.writeTimestamp(set, index: 0)
    list.barrier()
    list.writeTimestamp(set, index: 2, after: .fragment)
    let before = t.timestampsStored.count
    try gpu.graphicsQueue.submit(list, wait: 0, signal: 1)
    let r = try gpu.results(set, first: 0, count: 3)
    #expect(t.timestampsStored.count == before + 2)
    #expect(r[0] != 0 && r[1] == 0 && r[2] > r[0], "two stores, in order, and the one that wasn't written is zero")
    // Each store is its own stream on the compute queue.
    #expect(gpu.completed == 1)
    var wrong = GPUCommandList()
    wrong.writeTimestamp(set, index: 3)
    #expect(throws: GPUError.self) { try gpu.graphicsQueue.submit(wrong, wait: 1, signal: 2) }
  }

  @Test func theCPUCountersFrequencyIsThePeriodAndOnlyAZeroOneIsMeasured() throws {
    // CNTFRQ_EL0 reads 24 MHz: the period is its inverse, and no stream runs to measure it.
    let read = FakeTransport()
    read.timerHertz = 24_000_000
    read.cpuCounterHertz = 24_000_000
    let readGPU = try MaliDevice(transport: read)
    #expect(readGPU.limits.timestampPeriodPicoseconds == 41666 && readGPU.limits.features.timestampQueries)
    #expect(read.timestampsStored.isEmpty)
    // CNTFRQ_EL0 reads 0 (firmware never set it): the device measures the counter against the CPU's clock.
    let measured = FakeTransport()
    measured.timerHertz = 24_000_000
    measured.cpuCounterHertz = 0
    let measuredGPU = try MaliDevice(transport: measured)
    #expect(measuredGPU.limits.timestampPeriodPicoseconds == 41666)
    #expect(measured.timestampsStored.count >= 3)
  }

  @Test func aPassThatLoadsItsTargetHasAPreFrameShaderThatReadsTheImage() throws {
    let (gpu, t) = try device()
    #expect(gpu.limits.features.loadAttachments)
    let pipeline = try trianglePipeline(gpu)
    let target = try gpu.makeImage(ImageDescriptor(format: .rgba8, width: 64, height: 64, usage: .renderTarget | .copySource))
    var list = GPUCommandList()
    list.render(RenderingInfo(colors: [Attachment(image: target, load: .load)])) { r in r.draw(pipeline, root: 0x1000, vertices: 3) }
    try gpu.graphicsQueue.submit(list, wait: 0, signal: 1)
    let blocks = Array(zip(t.boundAtSubmit, t.memory.suffix(t.boundAtSubmit.count)))
    func word(_ a: UInt64) -> UInt32? {
      for (region, words) in blocks where a >= region.address && a + 4 <= region.address + UInt64(region.size) {
        return words[Int(a - region.address) / 4]
      }
      return nil
    }
    func pair(_ a: UInt64) -> UInt64 { UInt64(word(a) ?? 0) | UInt64(word(a + 4) ?? 0) << 32 }
    // The framebuffer parameters: 64 x 64, and the first pre-frame shader's mode (word 0) is always, with its descriptors.
    var fbd: UInt64?
    for (region, words) in blocks {
      for i in 0..<(words.count - 32) where words[i + 8] == 63 | 63 << 16 && words[i] == 1 && words[i + 11] >> 24 != 0 {
        fbd = region.address + UInt64(i * 4)
      }
    }
    let params = try #require(fbd)
    let dcd = pair(params + 24)
    #expect(dcd != 0 && dcd & 63 == 0)
    // Flags 0: forward pixel kill both ways and clean fragment write; the three flag words, a blend descriptor of one, a
    // resource table, a program descriptor, the thread storage and a FAU block.
    let flags0 = try #require(word(dcd))
    #expect(flags0 & 3 == 3 && flags0 >> 9 & 1 == 1 && flags0 >> 2 & 3 == 0 && flags0 >> 4 & 3 == 0)
    #expect(word(dcd + 4)! >> 16 & 0xFFF == 1, "render target 0")
    #expect(word(dcd + 0x14)! >> 12 & 0xFFF == 1, "writes target 0")
    #expect(pair(dcd + 0x30) & 15 == 1 && pair(dcd + 0x30) & ~15 != 0)
    #expect(pair(dcd + 0x68) != 0 && pair(dcd + 0x70) != 0 && pair(dcd + 0x60) & 63 != 0)
    // The shader's heap is the sampler and the image's descriptor, and the table says where it is and how big.
    let table = pair(dcd + 0x60) & ~63
    let entry = pair(table + 16)
    #expect(entry != 0, "table 1 is the heap")
    // A pass that draws nothing and keeps the contents is no work.
    let before = t.submits.count
    var keep = GPUCommandList()
    keep.render(RenderingInfo(colors: [Attachment(image: target, load: .load)])) { _ in }
    try gpu.graphicsQueue.submit(keep, wait: 1, signal: 2)
    #expect(t.submits.count == before)
    // A pass that clears has no pre-frame shader.
    var cleared = GPUCommandList()
    cleared.render(RenderingInfo(colors: [Attachment(image: target, load: .clear(0, 0, 0, 1))])) { r in
      r.draw(pipeline, root: 0x1000, vertices: 3)
    }
    try gpu.graphicsQueue.submit(cleared, wait: 2, signal: 3)
    var modes: [UInt32] = []
    for (_, words) in zip(t.boundAtSubmit, t.memory.suffix(t.boundAtSubmit.count)) {
      for i in 0..<(words.count - 32) where words[i + 8] == 63 | 63 << 16 && words[i + 11] >> 24 != 0 {
        modes.append(words[i] | (words[i + 6] != 0 || words[i + 7] != 0 ? 0x100 : 0))
      }
    }
    // The last pass's framebuffer is the last found: the submissions' memory is the arena's, taken in order.
    #expect(modes.last == 0, "mode never and no descriptors")
  }

  @Test func aStorageImageIsADescriptorInTable2AndTheShadersHandleNamesIt() throws {
    let (gpu, t) = try device()
    let image = try gpu.makeImage(ImageDescriptor(format: .rgba8, width: 64, height: 64, usage: .storage | .copySource))
    let sampledOnly = try gpu.makeImage(ImageDescriptor(format: .rgba8, width: 8, height: 8, usage: .sampled))
    #expect(throws: GPUError.self) { try gpu.writeStorageImage(0, sampledOnly) }
    #expect(throws: GPUError.self) { try gpu.writeStorageImage(1024, image) }
    #expect(throws: GPUError.self) { try gpu.writeTexture(0, image) }
    try gpu.writeStorageImage(3, image)
    let record = gpu.images[image.handle]!
    // The descriptor is the texture descriptor of the view: type 2, 64 x 64, one level, the plane array after the texels.
    let d = Array(gpu.storageWords[24..<32])
    #expect(d[0] & 0xF == 2 && d[1] == 63 | 63 << 16 && d[2] >> 16 & 0x1F == 0)
    #expect(UInt64(d[4]) | UInt64(d[5]) << 32 == record.region.address + UInt64(record.planeAt!))
    #expect(gpu.storageWords[0..<24].allSatisfy { $0 == 0 }, "slots before it are empty")

    let store = try gpu.makeComputePipeline(spirv: try spirv("store.comp"))
    let params = try gpu.allocate(.upload, bytes: 16)
    var list = GPUCommandList()
    list.dispatch(store, root: params.address, x: 8, y: 8)
    try gpu.graphicsQueue.submit(list, wait: 0, signal: 1)
    // The dispatch's resource table has table 2: an entry whose address holds that descriptor.
    var found = false
    let blocks = Array(zip(t.boundAtSubmit, t.memory.suffix(t.boundAtSubmit.count)))
    for (_, words) in blocks {
      for i in 0..<(words.count - 8) where words[i] & 0xF == 2 && words[i + 1] == 63 | 63 << 16 { found = true }
    }
    #expect(found, "the snapshot of the storage descriptors is in the dispatch's memory")
    // The handle the FAU holds for the array is table 2, index 0: 0x02000000.
    var handle = false
    for (_, words) in blocks { for w in words where w == 0x0200_0000 { handle = true } }
    #expect(handle)
  }

  @Test func aGPUWhoseCounterDoesNotCountHasNoTimestamps() throws {
    let t = FakeTransport()
    t.timerHertz = 0
    let gpu = try MaliDevice(transport: t)
    #expect(gpu.limits.features.timestampQueries == false && gpu.limits.timestampPeriodPicoseconds == 0)
    #expect(throws: GPUError.self) { try gpu.makeQuerySet(.timestamp, count: 1) }
  }
}
