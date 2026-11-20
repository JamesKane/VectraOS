// SPDX-License-Identifier: BSD-3-Clause

// The dispatch recipe's stream decoded back and checked against valhall 02's
// recipe (2.2.3 the queue's initial state, 2.9.1 the stream tail) and 01's
// staging registers; the records it lays out read back from its memory image;
// and the hand-assembled shader against every literal word the spec prints for
// the same instructions.

import MaliCore
import Testing

// MARK: The hand-assembled shader

@Test func theComposerReproducesTheWordsTheSpecPrints() {
  // 11b section 11b.3.5: SHADD.u64 [r0:r1], u1, [r60:r61].w0, shift:2
  #expect(BringUpShader.shadd64(dst: 0, src0: BringUpShader.fauSource(slot: 1), src1: BringUpShader.registerSource(60),
                                widenW0: true, shift: 2) == 0x01A3_C000_2027_3C82)
  // 12a section 12a.4.2.
  #expect(BringUpShader.storeI32(data: 0, address: BringUpShader.registerSource(2, lastUse: true), flow: 10)
    == 0x5061_4002_1800_0042)
  #expect(BringUpShader.store(width: 7, count: 4, data: 4, address: BringUpShader.registerSource(0, lastUse: true),
                              flow: BringUpShader.flowEnd) == 0x7861_4408_3800_0040)
  #expect(BringUpShader.store(width: 7, count: 4, data: 4, address: BringUpShader.registerSource(2, lastUse: true))
    == 0x0061_4408_3800_0042)
  // The source bytes of 10 section 10.5.1: r5, r5 last use, u5.w0 of a page, the constant zero is 0xC0.
  #expect(BringUpShader.registerSource(5) == 0x05 && BringUpShader.registerSource(5, lastUse: true) == 0x45)
  #expect(BringUpShader.fauSource(slot: 5) == 0x8A && BringUpShader.fauSource(slot: 5, word: 1) == 0x8B)
}

@Test func theBringUpShaderIsTwoInstructionsDerivedFromTheTables() {
  #expect(BringUpShader.addressWord == 0x01A3_C000_2027_3C80)
  #expect(BringUpShader.storeWord == 0x7861_7C02_1800_0000)
  #expect(BringUpShader.words == [0x01A3_C000_2027_3C80, 0x7861_7C02_1800_0000])
  // The flow of the last instruction is `end` (15, 13 section 13.3.3's 0x7800) and no other has flow.
  #expect(BringUpShader.storeWord >> 59 & 0xF == 15 && BringUpShader.addressWord >> 59 & 0xF == 0)
  // Class [56:52]: 26 (D2) and 6 (S2); every top bit [63] clear.
  #expect(BringUpShader.addressWord >> 52 & 0x1F == 26 && BringUpShader.storeWord >> 52 & 0x1F == 6)
  #expect(BringUpShader.addressWord >> 63 == 0 && BringUpShader.storeWord >> 63 == 0)
  // r60 (global invocation id x) is preloaded: bit 12 of the mask (r48 + 12).
  #expect(BringUpShader.preloadMask == 0x1000 && 48 + 12 == 60)
  let s = BringUpShader.globalIDStore()
  #expect(s.registerClass == .r64 && s.code.count == 2 && s.stackBytes == 0 && s.workgroupMemoryBytes == 0)
}

// MARK: Decoding a stream

private struct Machine {
  var r = [UInt32](repeating: 0, count: 256)
  var run: UInt64?
  var opcodes: [UInt64] = []

  func pair(_ n: Int) -> UInt64 { UInt64(r[n]) | UInt64(r[n + 1]) << 32 }

  /// Execute the register moves; note the others, and stop at RUN_COMPUTE with the registers as they were.
  mutating func step(_ w: UInt64) {
    let op = w >> 56
    opcodes.append(op)
    switch op {
    case 1:
      let d = Int(w >> 48 & 0xFF)
      r[d] = UInt32(truncatingIfNeeded: w)
      r[d + 1] = UInt32(w >> 32 & 0xFFFF)
    case 2: r[Int(w >> 48 & 0xFF)] = UInt32(truncatingIfNeeded: w)
    case 4: run = w
    default: break
    }
  }
}

private let regs = CSRegisterMap(workRegisters: 128, unpreserved: 4)
private let sbs = CSScoreboards(count: 16)
private let base: UInt64 = 0x10_0000

private func dispatch(_ r: ComputeDispatchRequest, capacity: Int = 16384) throws -> ComputeDispatchImage {
  try ComputeDispatch.build(at: base, capacity: capacity, request: r, registers: regs, scoreboards: sbs)
}

private let fauWord: UInt64 = 0x20_0000

@Test func theRecipeStreamIsSection2sSequence() throws {
  let req = ComputeDispatchRequest(shader: BringUpShader.globalIDStore(), grid: Dim3(4), fau: [fauWord])
  let img = try dispatch(req)
  let words = img.stream.words
  #expect(img.stream.address & 63 == 0 && img.stream.size == words.count * 8)
  // 2.2.3 step 2: endpoint 3, wait mask slot 3, other 0, deferred 1, stream mask the rotating slots but 3.
  #expect(Array(words[0..<5]) == [
    CSInstruction.setState(.endpointSlot, immediate: 3),
    CSInstruction.setState(.waitMask, immediate: 0x0008),
    CSInstruction.setState(.otherSlot, immediate: 0),
    CSInstruction.setState(.deferredSlot, immediate: 1),
    CSInstruction.setState(.streamMask, immediate: 0xFFF0),
  ])
  // 2.9.3: the compute resource, once.
  #expect(words[5] == CSInstruction.requestResources(.compute))
  // Run the moves, up to RUN_COMPUTE.
  var m = Machine()
  var at = 0
  while m.run == nil { m.step(words[at]); at += 1 }
  let run = m.run!
  // 01 section 1.9.2: staging registers.
  #expect(m.pair(CSRegisterMap.srt()) == 0)  // no resources, no SRT
  #expect(m.pair(CSRegisterMap.fau()) == img.fau | 1 << 56)
  #expect(m.pair(CSRegisterMap.spd()) == img.spd)
  #expect(m.pair(CSRegisterMap.tsd()) == img.tsd)
  #expect(m.r[32] == 0)
  #expect(m.r[33] == 15)  // 16 x 1 x 1 minus one in each axis
  #expect(m.r[34] == 0 && m.r[35] == 0 && m.r[36] == 0)
  #expect(m.r[37] == 4 && m.r[38] == 1 && m.r[39] == 1)
  // No limits known: one workgroup a task along X, no per-core limit, all four selects 0, stage 0.
  #expect(run == CSInstruction.runCompute(taskIncrement: 1, taskAxis: 0))
  // 2.9.1: WAIT for every slot, the flush id's zero, FLUSH_CACHE2 clean L2 and LSC on slot 0, WAIT for slot 0.
  let tail = Array(words[at...])
  #expect(tail == [
    CSInstruction.wait(mask: 0xFFFF),
    CSInstruction.mov32(66, 0),
    CSInstruction.flushCache2(l2: .clean, lsc: .clean, other: .none, flushIDRegister: 66, signalSlot: 0),
    CSInstruction.wait(mask: 0x0001),
  ])
  // No instruction touches a register the kernel's job sequence clobbers (the top 4 of 128: 124 to 127).
  for w in words {
    let op = w >> 56
    if op == 1 || op == 2 { #expect(Int(w >> 48 & 0xFF) < 124) }
  }
}

@Test func theQueueSetupAndTheResourceRequestAreOptional() throws {
  let req = ComputeDispatchRequest(shader: BringUpShader.globalIDStore(), grid: Dim3(1), fau: [fauWord],
                                   requestComputeResource: false, initialiseQueue: false)
  let img = try dispatch(req)
  var m = Machine()
  for w in img.stream.words { m.step(w) }
  #expect(!m.opcodes.contains(0x1C) && !m.opcodes.contains(0x22))
  #expect(m.opcodes.first == 0x01 && m.opcodes.filter { $0 == 4 }.count == 1)
}

@Test func theRecordsAreInTheImageWhereTheRegistersPointAndAligned() throws {
  let req = ComputeDispatchRequest(shader: BringUpShader.globalIDStore(), grid: Dim3(4), fau: [fauWord])
  let img = try dispatch(req)
  func off(_ a: UInt64) -> Int { Int(a - base) }
  #expect(img.spd & 31 == 0 && img.tsd & 63 == 0 && img.shader & 127 == 0 && img.fau & 7 == 0)
  // SPD: compute, class 64, preload r60, the binary's address.
  let m = img.memory
  #expect(m.load32(at: off(img.spd)) == 0x18 && m.load32(at: off(img.spd) + 4) == 0x1000)
  #expect(m.load64(at: off(img.spd) + 8) == img.shader)
  // TSD: no memory of either kind.
  #expect((0..<8).map { m.load32(at: off(img.tsd) + 4 * $0) } == [0, 31, 0, 0, 0, 0, 0, 0])
  // The binary, and the FAU's slot 0: the buffer's address.
  #expect(m.load64(at: off(img.shader)) == BringUpShader.words[0] && m.load64(at: off(img.shader) + 8) == BringUpShader.words[1])
  #expect(m.load64(at: off(img.fau)) == fauWord)
  // The stream is the last thing and its image is the stream.
  #expect(img.stream.address == base + UInt64(m.count - img.stream.size))
  for (i, w) in img.stream.words.enumerated() { #expect(m.load64(at: off(img.stream.address) + 8 * i) == w) }
  // The records don't overlap: spd, tsd, fau, shader, stream in address order.
  #expect(img.spd + 32 <= img.tsd && img.tsd + 32 <= img.fau && img.fau + 8 <= img.shader
    && img.shader + 16 <= img.stream.address)
}

@Test func buffersGetATableAnEntryAndAnSRT() throws {
  let bufs = [BufferDescriptor.storage(address: 0x30_0000, byteSize: 256), BufferDescriptor.uniform(address: 0x31_0000, byteSize: 16)]
  let req = ComputeDispatchRequest(shader: BringUpShader.globalIDStore(), grid: Dim3(1), fau: [fauWord], buffers: bufs)
  let img = try dispatch(req)
  func off(_ a: UInt64) -> Int { Int(a - base) }
  #expect(img.resourceTable & 63 == 0 && img.tables & 31 == 0)
  #expect(img.srtRegister == img.resourceTable | 4)
  let m = img.memory
  // Entry 0: the table's address, descriptors, 64 bytes; entries 1 to 3 unused.
  #expect(m.load32(at: off(img.resourceTable)) == UInt32(truncatingIfNeeded: img.tables))
  #expect(m.load32(at: off(img.resourceTable) + 4) == 1 << 24 && m.load64(at: off(img.resourceTable) + 8) == 64)
  #expect(m.load64(at: off(img.resourceTable) + 16) == 0 && m.load64(at: off(img.resourceTable) + 56) == 0)
  // The descriptors in index order.
  for (i, b) in bufs.enumerated() {
    #expect((0..<8).map { m.load32(at: off(img.tables) + 32 * i + 4 * $0) } == b.words())
  }
  // The stream loads the SRT register with it.
  var machine = Machine()
  var at = 0
  while machine.run == nil { machine.step(img.stream.words[at]); at += 1 }
  #expect(machine.pair(CSRegisterMap.srt()) == img.srtRegister)
}

@Test func theGridGoesToTheJobSizeRegistersAndTheTaskToTheRun() throws {
  let limits = ComputeLimits(maxThreadsPerCore: 2048, maxThreadsPerWorkgroup: 1024, registersPerCore: 32768, tasksPerCore: 8,
                             shaderPresent: 0x0055_0555)
  var shader = BringUpShader.globalIDStore(workgroupSize: Dim3(8, 8, 1))
  shader.registerClass = .r32
  let img = try dispatch(ComputeDispatchRequest(shader: shader, grid: Dim3(100, 100, 1), fau: [fauWord], limits: limits))
  var m = Machine()
  var at = 0
  while m.run == nil { m.step(img.stream.words[at]); at += 1 }
  #expect(m.r[37] == 100 && m.r[38] == 100 && m.r[39] == 1)
  #expect(m.r[33] == 7 | 7 << 10)
  // 16 section 16.4.2: class 32 tasks of 2 workgroups along X; Ep limit = the tasks a core runs (8).
  #expect(m.run == CSInstruction.runCompute(taskIncrement: 2, taskAxis: 0, epLimit: 8))
  // The SPD names class 32.
  #expect(img.memory.load32(at: Int(img.spd - base)) >> 30 == 2)
}

@Test func mergingIsAllowedOnlyForAShaderThatAllowsItWithNoSharedMemory() throws {
  var s = BringUpShader.globalIDStore()
  s.allowsWorkgroupMerging = true
  var m = Machine()
  for w in try dispatch(ComputeDispatchRequest(shader: s, grid: Dim3(1), fau: [fauWord])).stream.words { m.step(w) }
  #expect(m.r[33] == 15 | 1 << 31)
}

@Test func stackAndWorkgroupMemoryNeedLimitsAndAlignedStorage() throws {
  var s = BringUpShader.globalIDStore(workgroupSize: Dim3(8, 8, 1))
  s.stackBytes = 100
  s.workgroupMemoryBytes = 5000
  let limits = ComputeLimits(maxThreadsPerCore: 2048, maxThreadsPerWorkgroup: 1024, registersPerCore: 65536, tasksPerCore: 8,
                             shaderPresent: 0x3FF)
  let grid = Dim3(100, 100, 1)
  #expect(throws: DispatchError.needsLimits) { try dispatch(ComputeDispatchRequest(shader: s, grid: grid, fau: [fauWord])) }
  #expect(throws: DispatchError.needsLimits) {
    try dispatch(ComputeDispatchRequest(shader: s, grid: grid, fau: [fauWord], limits: limits))
  }
  #expect(throws: DispatchError.storageMisaligned) {
    try dispatch(ComputeDispatchRequest(shader: s, grid: grid, fau: [fauWord], threadStorage: 0x4000_0100,
                                        workgroupMemory: 0x5000_0000, limits: limits))
  }
  let sizing = ComputeSizing.of(shader: s, grid: grid, limits: limits)
  #expect(sizing.tlsField == 3 && sizing.tlsBytes == 128 * 2048 * 10)
  #expect(sizing.wlsInstancesLog2 == 5 && sizing.wlsSizeScale == 14 && sizing.wlsBytes == 2_621_440)
  let img = try dispatch(ComputeDispatchRequest(shader: s, grid: grid, fau: [fauWord], threadStorage: 0x8_0000_0000,
                                                workgroupMemory: 0x9_0000_0000, limits: limits))
  let t = (0..<8).map { img.memory.load32(at: Int(img.tsd - base) + 4 * $0) }
  #expect(t == [3, 5 | 14 << 8, 0x0800_0000, 0x1000_0000, 0, 9, 0, 0])
  // Without workgroup memory the sizing says "none".
  s.workgroupMemoryBytes = 0
  #expect(ComputeSizing.of(shader: s, grid: grid, limits: limits).wlsInstancesLog2 == 31)
}

@Test func badRequestsAreRefused() throws {
  let s = BringUpShader.globalIDStore()
  #expect(throws: DispatchError.fauTooShort) { try dispatch(ComputeDispatchRequest(shader: s, grid: Dim3(1))) }
  #expect(throws: DispatchError.badGrid) { try dispatch(ComputeDispatchRequest(shader: s, grid: Dim3(0), fau: [1])) }
  var empty = s
  empty.code = []
  #expect(throws: DispatchError.emptyShader) { try dispatch(ComputeDispatchRequest(shader: empty, grid: Dim3(1), fau: [1])) }
  #expect(throws: DispatchError.arch(10)) {
    try ComputeDispatch.build(at: base, capacity: 4096, request: ComputeDispatchRequest(shader: s, grid: Dim3(1), fau: [1]),
                              registers: regs, scoreboards: sbs, arch: 10)
  }
  #expect(throws: DispatchError.self) { try dispatch(ComputeDispatchRequest(shader: s, grid: Dim3(1), fau: [1]), capacity: 128) }
}

@Test func theBuilderRefusesWhatTheKernelClobbersAndWhatDoesntFit() throws {
  var b = CSBuilder(address: base, capacityBytes: 16, registers: regs, scoreboards: sbs)
  b.move32(124, 1)
  #expect(throws: CSBuildError.register(124)) { try b.finish() }
  var c = CSBuilder(address: base, capacityBytes: 16, registers: regs, scoreboards: sbs)
  c.waitAll()
  c.waitAll()
  c.waitAll()
  #expect(throws: CSBuildError.overflow(words: 3, capacity: 2)) { try c.finish() }
  #expect(throws: CSBuildError.empty) { try CSBuilder(address: base, capacityBytes: 16, registers: regs, scoreboards: sbs).finish() }
  var d = CSBuilder(address: base + 8, capacityBytes: 64, registers: regs, scoreboards: sbs)
  d.waitAll()
  #expect(throws: CSBuildError.misaligned) { try d.finish() }
  // move64 of a value over 48 bits adds a MOVE32 of the high word.
  var e = CSBuilder(address: base, capacityBytes: 64, registers: regs, scoreboards: sbs)
  e.move64(8, 0xAB00_1234_5678_9ABC)
  #expect(e.words == [CSInstruction.mov48(8, 0x1234_5678_9ABC), CSInstruction.mov32(9, 0xAB00_1234)])
  // Arch 10's 8 slots: the all mask and the rotating mask.
  let eight = CSScoreboards(count: 8)
  #expect(eight.allSlots == 0xFF && eight.rotatingSlots == 0xF8)
  #expect(sbs.allSlots == 0xFFFF && sbs.rotatingSlots == 0xFFF8)
}
