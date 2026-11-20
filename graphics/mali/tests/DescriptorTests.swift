// SPDX-License-Identifier: BSD-3-Clause

// The descriptors against valhall 03's and 04's field tables and the worked
// examples of 04 section 4.7 and 16 section 16.4.2.

import MaliCore
import Testing

@Test func aResourceTableEntryPacksAddressFlagAndSize() {
  let e = ResourceTableEntry(address: 0x00AB_CDEF_1234_5640, containsDescriptors: true, size: 0x1_0000_0040)
  // Address in w0 and w1[23:0] (56 bits), the flag at w1[24], the size in w2 and w3.
  #expect(e.words == [0x1234_5640, 0x01AB_CDEF, 0x0000_0040, 0x1])
  #expect(ResourceTableEntry.unused.words == [0, 0, 0, 0])
}

@Test func theResourceTableHasAMultipleOfFourEntries() throws {
  let one = ResourceTableEntry(address: 0x1000, containsDescriptors: true, size: 64)
  let bytes = try ResourceTable.encode([one])
  #expect(bytes.count == 64)
  var m = MemoryImage()
  m.extend(to: 64)
  m.store(bytes: bytes, at: 0)
  #expect(m.load32(at: 0) == 0x1000 && m.load32(at: 4) == 1 << 24 && m.load32(at: 8) == 64)
  #expect(m.load64(at: 16) == 0 && m.load64(at: 48) == 0)
  #expect(try ResourceTable.encode([]).isEmpty)
  #expect(try ResourceTable.encode(Array(repeating: one, count: 5)).count == 128)
  #expect(throws: DescriptorError.outOfRange) { try ResourceTable.encode(Array(repeating: one, count: 61)) }
}

@Test func theSRTRegisterCarriesTheEntryCount() throws {
  #expect(try ResourceTable.pointer(address: 0x10_0040, entryCount: 4) == 0x10_0044)
  #expect(try ResourceTable.pointer(address: 0x10_0040, entryCount: 60) == 0x10_007C)
  #expect(try ResourceTable.pointer(address: 0, entryCount: 0) == 0)
  #expect(throws: DescriptorError.outOfRange) { try ResourceTable.pointer(address: 0x10_0040, entryCount: 6) }
  #expect(throws: DescriptorError.outOfRange) { try ResourceTable.pointer(address: 0x10_0040, entryCount: 64) }
  #expect(throws: DescriptorError.misaligned) { try ResourceTable.pointer(address: 0x10_0020, entryCount: 4) }
  #expect(ResourceTable.handle(table: 3, index: 5) == 0x0300_0005)
  #expect(ResourceTable.handle(table: 62, index: 0xFF_FFFF) == 0x3EFF_FFFF)
}

@Test func theBufferDescriptorIsThe03Layout() {
  let d = BufferDescriptor(address: 0x0000_0012_3456_7000, byteSize: 0x1_0000_1000)
  #expect(d.words() == [0x19, 0x1000, 0x3456_7000, 0x12, 0, 1, 0, 0])
  // Arch 10 has no size high word.
  #expect(d.words(arch: 10)[5] == 0)
  let s = BufferDescriptor(kind: .structure, address: 0x2000, byteSize: 96, stride: 12)
  #expect(s.words() == [0x39, 96, 0x2000, 0, 12, 0, 0, 0])
  #expect(BufferDescriptor.uniform(address: 0, byteSize: 17).byteSize == 32)
  #expect(BufferDescriptor.storage(address: 0, byteSize: 17).byteSize == 20)
  #expect(BufferDescriptor(kind: .tilerHeap, address: 0, byteSize: 1 << 33).words()[5] == 0)
}

@Test func theFAUPointerHasTheCountInTheTopByte() throws {
  #expect(try FAUPointer.value(address: 0x10_0040, words: 1) == 0x0100_0000_0010_0040)
  #expect(try FAUPointer.value(address: 0x10_0040, words: 255) == 0xFF00_0000_0010_0040)
  #expect(try FAUPointer.value(address: 0x10_0040, words: 0) == 0)
  #expect(throws: DescriptorError.outOfRange) { try FAUPointer.value(address: 0x10_0040, words: 256) }
  #expect(throws: DescriptorError.misaligned) { try FAUPointer.value(address: 0x10_0044, words: 1) }
  #expect(throws: DescriptorError.misaligned) { try FAUPointer.value(address: 1 << 56, words: 1) }
}

@Test func theShaderProgramDescriptorIsThe04Layout() {
  let d = ShaderProgramDescriptor(stage: .compute, registerClass: .r64, preloadMask: 0x1000, binary: 0x0000_0001_0010_0000)
  #expect(d.words == [0x18, 0x1000, 0x0010_0000, 0x1, 0, 0, 0, 0])
  let f = ShaderProgramDescriptor(stage: .fragment, registerClass: .r32, preloadMask: 0xF000, flushToZeroMode: 2,
                                  maxWarps: 4, binary: 0x2000)
  // type 8, stage 2 in [7:4], flush to zero 2 in [18:17], class 32 = 2 in [31:30]
  #expect(f.words[0] == 0x8 | 2 << 4 | 2 << 17 | 2 << 30)
  #expect(f.words[1] == 0x0004_F000)
  #expect(ShaderProgramDescriptor.size == 32 && ShaderProgramDescriptor.alignment == 32)
}

@Test func theLocalStorageRecordForNoMemoryIsAllZeroButWLSInstances() {
  #expect(LocalStorageDescriptor.none.words == [0, 31, 0, 0, 0, 0, 0, 0])
}

@Test func theStackWorkedExampleOf4_7_2() {
  // A 100-byte stack: 7 units of 16 bytes, field 3, 128 bytes a thread; 1024 resident threads, 12 cores:
  // 128 * 1024 * 12 = 1.5 MiB.
  let limits = ComputeLimits(maxThreadsPerCore: 1024, maxThreadsPerWorkgroup: 1024, registersPerCore: 32768, tasksPerCore: 8,
                             shaderPresent: 0xFFF)
  #expect(limits.coreRange == 12 && limits.coreCount == 12)
  #expect(ThreadStorageSizing.tlsField(stackBytes: 100) == 3)
  #expect(ThreadStorageSizing.perThreadBytes(stackBytes: 100) == 128)
  #expect(ThreadStorageSizing.tlsTotal(stackBytes: 100, limits: limits) == 1_572_864)
  // The doublings: 1 to 16 bytes is field 0, 17 to 32 is 1, 33 to 64 is 2; none is 0 bytes.
  #expect(ThreadStorageSizing.tlsField(stackBytes: 1) == 0 && ThreadStorageSizing.tlsField(stackBytes: 16) == 0)
  #expect(ThreadStorageSizing.tlsField(stackBytes: 17) == 1 && ThreadStorageSizing.tlsField(stackBytes: 32) == 1)
  #expect(ThreadStorageSizing.tlsField(stackBytes: 33) == 2 && ThreadStorageSizing.tlsField(stackBytes: 64) == 2)
  #expect(ThreadStorageSizing.perThreadBytes(stackBytes: 0) == 0)
  // The descriptor at 0x8_0000_0000: word 0 = 3, word 1 = 31, words 2 and 3 = 0x0800_0000 and 0x1000_0000.
  let d = LocalStorageDescriptor(tlsSize: 3, tlsBase: 0x8_0000_0000, addressMode: .packed,
                                 wlsInstances: LocalStorageDescriptor.noWorkgroupMemory, wlsSizeScale: 0, wlsBase: 0)
  #expect(d.words == [3, 31, 0x0800_0000, 0x1000_0000, 0, 0, 0, 0])
}

@Test func theWorkgroupMemoryWorkedExampleOf4_7_4() {
  // max_threads_core 2048, tasks_core 8, core_range 10; an 8 x 8 x 1 shader with 5000 bytes shared, 100 x 100 dispatch.
  let limits = ComputeLimits(maxThreadsPerCore: 2048, maxThreadsPerWorkgroup: 1024, registersPerCore: 65536, tasksPerCore: 8,
                             shaderPresent: 0x3FF)
  #expect(limits.coreRange == 10)
  #expect(ThreadStorageSizing.instancesPerCoreLimit(workgroupThreads: 64, limits: limits) == 32)
  let n = ThreadStorageSizing.wlsInstances(workgroupThreads: 64, grid: (100, 100, 1), limits: limits)
  #expect(n == 32 && log2Check(n) == 5)
  #expect(ThreadStorageSizing.wlsInstanceBytes(sharedBytes: 5000) == 8192)
  #expect(ThreadStorageSizing.wlsSizeScale(sharedBytes: 5000) == 14)
  #expect(ThreadStorageSizing.wlsTotal(sharedBytes: 5000, instances: n, limits: limits) == 2_621_440)
  // A 1 x 1 x 1 dispatch: one instance, field 0, 81 920 bytes.
  let one = ThreadStorageSizing.wlsInstances(workgroupThreads: 64, grid: (1, 1, 1), limits: limits)
  #expect(one == 1 && ThreadStorageSizing.wlsTotal(sharedBytes: 5000, instances: one, limits: limits) == 81_920)
  // An indirect dispatch takes the core limit.
  #expect(ThreadStorageSizing.wlsInstances(workgroupThreads: 64, grid: nil, limits: limits) == 32)
  // Sizes below 128 bytes round up to 128: scale 8; the usual 4, 16 and 32 KiB are 13, 15 and 16.
  #expect(ThreadStorageSizing.wlsSizeScale(sharedBytes: 4) == 8)
  #expect(ThreadStorageSizing.wlsSizeScale(sharedBytes: 4096) == 13)
  #expect(ThreadStorageSizing.wlsSizeScale(sharedBytes: 16384) == 15)
  #expect(ThreadStorageSizing.wlsSizeScale(sharedBytes: 32768) == 16)
  #expect(ThreadStorageSizing.wlsSizeScale(sharedBytes: 0) == 0)
  // The descriptor: instances 5 in word 1 [4:0], scale 14 at [12:8], the base in words 4 and 5.
  let d = LocalStorageDescriptor(tlsSize: 0, tlsBase: 0, addressMode: .flat, wlsInstances: 5, wlsSizeScale: 14,
                                 wlsBase: 0x1_2000_0000)
  #expect(d.words == [0, 5 | 14 << 8, 0, 0, 0x2000_0000, 1, 0, 0])
}

private func log2Check(_ v: UInt64) -> Int { 63 - v.leadingZeroBitCount }

@Test func theSkyG720WorkedExampleOf16_4_2() {
  // 0x00550555: ten cores with gaps, core range 23; Tc 2048, Tw 1024, F 32768, K 8.
  let limits = ComputeLimits(maxThreadsPerCore: 2048, maxThreadsPerWorkgroup: 1024, registersPerCore: 32768, tasksPerCore: 8,
                             shaderPresent: 0x0055_0555)
  #expect(limits.coreCount == 10 && limits.coreRange == 23)
  #expect(limits.residentThreads(.r32) == 1024 && limits.residentThreads(.r64) == 512)
  // Thread storage for a 100-byte stack: 128 * 2048 * 23.
  #expect(ThreadStorageSizing.tlsTotal(stackBytes: 100, limits: limits) == 6_029_312)
  // Workgroup memory: 8 x 8 x 1, 5000 bytes, 100 x 100: 8192 * 32 * 23.
  let n = ThreadStorageSizing.wlsInstances(workgroupThreads: 64, grid: (100, 100, 1), limits: limits)
  #expect(n == 32 && ThreadStorageSizing.wlsTotal(sharedBytes: 5000, instances: n, limits: limits) == 6_029_312)
  // Threads per task: 2048 / 8 = 256 (workgroup memory rule) and ceil(1024 / 8) = 128 (class 32 compute rule).
  // With 8 x 8 workgroups the class 32 task is 128 / 64 = 2 workgroups, spread over a big grid.
  let task = ComputeRunState.task(workgroup: Dim3(8, 8, 1), grid: Dim3(100, 100, 1), registerClass: .r32, limits: limits)
  #expect(task == ComputeRunState.Task(increment: 2, axis: 0))
  // Class 64: ceil(512 / 8) = 64 threads, one workgroup.
  let t64 = ComputeRunState.task(workgroup: Dim3(8, 8, 1), grid: Dim3(100, 100, 1), registerClass: .r64, limits: limits)
  #expect(t64 == ComputeRunState.Task(increment: 1, axis: 0))
}

@Test func theTaskIsCappedByTheGridAndMovesOffAnAxisItExceeds() {
  let limits = ComputeLimits(maxThreadsPerCore: 2048, maxThreadsPerWorkgroup: 1024, registersPerCore: 65536, tasksPerCore: 8,
                             shaderPresent: 0x3FF)
  // 16 threads a workgroup: a task of ceil(1024 / 8) = 128 threads wants 8 workgroups, but a 4 x 1 x 1 grid
  // over 10 cores has one workgroup a core (rounded up).
  #expect(ComputeRunState.task(workgroup: Dim3(16), grid: Dim3(4), registerClass: .r32, limits: limits)
    == ComputeRunState.Task(increment: 1, axis: 0))
  // A grid 4 wide and 100 tall: 8 per task exceeds the 4 along X, so it moves to Y and divides: 8 / 4 = 2.
  #expect(ComputeRunState.task(workgroup: Dim3(16), grid: Dim3(4, 100, 1), registerClass: .r32, limits: limits)
    == ComputeRunState.Task(increment: 2, axis: 1))
  // The field is 14 bits.
  let big = ComputeLimits(maxThreadsPerCore: 1 << 20, maxThreadsPerWorkgroup: 1 << 20, registersPerCore: 1 << 21,
                          tasksPerCore: 1, shaderPresent: 1)
  #expect(ComputeRunState.task(workgroup: Dim3(1), grid: Dim3(1 << 20), registerClass: .r32, limits: big).increment == 0x3FFF)
}

@Test func theWorkgroupSizeWordHasTheAxesMinusOne() throws {
  #expect(try ComputeRunState.workgroupSizeWord(Dim3(16), allowMerging: false) == 15)
  #expect(try ComputeRunState.workgroupSizeWord(Dim3(8, 8, 4), allowMerging: false) == 7 | 7 << 10 | 3 << 20)
  #expect(try ComputeRunState.workgroupSizeWord(Dim3(1024, 1, 1), allowMerging: true) == 1023 | 1 << 31)
  #expect(throws: DescriptorError.outOfRange) { try ComputeRunState.workgroupSizeWord(Dim3(1025), allowMerging: false) }
  #expect(throws: DescriptorError.outOfRange) { try ComputeRunState.workgroupSizeWord(Dim3(0), allowMerging: false) }
}
