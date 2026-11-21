// SPDX-License-Identifier: BSD-3-Clause

// What bin/mali makes of a probe's reads.

import Mali
import Testing

@Test func theSky1sGPUReadsAsAG720() {
  // As FreeBSD's panthor read the Orange Pi 6 Plus's (AbyssBSD's notes).
  let id = GPUID(0xC870_0008)
  #expect(id.archMajor == 12 && id.archMinor == 8 && id.archRevision == 7 && id.productMajor == 0)
  #expect(id.versionMajor == 0 && id.versionMinor == 0 && id.versionStatus == 8)
  #expect(id.isPlausible)
  var p = Probe(id: id, l2Features: 0x0813_0306, tilerFeatures: 0x809, memFeatures: 0x301, mmuFeatures: 0x2830,
                asPresent: 0xFF, csfID: 0x0420_0412, shaderPresent: 0x55_0555, tilerPresent: 1, l2Present: 1)
  #expect(p.shaderCores == 10)
  #expect(p.name == "Mali-G720")
  p.features = 0x4
  #expect(p.name == "Mali-G720-Immortalis")
  #expect(p.lines[0] == "Mali-G720-Immortalis, GPU_ID 0xc8700008: architecture 12.8.7, r0p0 status 8")
  #expect(p.lines[1] == "shader cores 10 (0x00550555), tiler 0x00000001, L2 0x00000001")
}

@Test func theThreadRegistersAreWhereThe02MapPutsThem() {
  #expect(GPURegister.threadMaxThreads == 0x0A0 && GPURegister.threadMaxWorkgroupSize == 0x0A4)
  #expect(GPURegister.threadMaxBarrierSize == 0x0A8 && GPURegister.threadFeatures == 0x0AC)
}

@Test func theThreadLimitsAreReadFromTheProbeAndSaidInItsLines() {
  // valhall 16 section 16.4.2's worked inputs: 32768 registers, 8 tasks a core.
  let p = Probe(id: GPUID(0xC870_0008), threadMaxThreads: 2048, threadMaxWorkgroupSize: 1024, threadMaxBarrierSize: 1024,
                threadFeatures: 0x0800_8000, shaderPresent: 0x55_0555, tilerPresent: 1, l2Present: 1)
  #expect(p.registersPerCore == 32768 && p.tasksPerCore == 8)
  #expect(p.lines[3] == "threads 2048 a core, workgroup 1024, barrier 1024;"
    + " THREAD_FEATURES 0x08008000: 32768 registers a core, 8 tasks a core")
  // A probe that read none says zeros, which the user side refuses.
  let none = Probe(id: GPUID(0xC870_0008))
  #expect(none.registersPerCore == 0 && none.tasksPerCore == 0)
}

@Test func theJournalKeepsLinesInOrderWithTheirMillisecondsSinceTheOrigin() {
  var log = EventLog(origin: 1_000_000, capacity: 3)
  log.add("a", at: 1_500_000)
  log.add("b", at: 2_000_000_000)
  // A reading a little late never runs the time back.
  log.add("c", at: 1_999_000_000)
  #expect(log.lines == ["[0 ms] a", "[1999 ms] b", "[1999 ms] c"])
  #expect(log.entries.map(\.time) == [1_500_000, 2_000_000_000, 2_000_000_000])
  // The oldest goes first when it is full.
  log.add("d", at: 3_000_000_000)
  #expect(log.texts == ["b", "c", "d"])
  #expect(log.lines.last == "[2999 ms] d")
  // Before the origin is the origin.
  #expect(EventLog.stamp(-5) == "[0 ms]")
}

/// A GPU block whose raw status holds events, and clears the ones written to GPU_IRQ_CLEAR.
final class IRQRegisters: GPURegisterFile {
  var raw: UInt32 = 0
  var words: [Int: UInt32] = [:]
  var stores: [(offset: Int, value: UInt32)] = []
  func load32(_ offset: Int) -> UInt32 { offset == GPUControlRegister.irqRawStat ? raw : words[offset] ?? 0 }
  func store32(_ offset: Int, _ value: UInt32) {
    stores.append((offset, value))
    if offset == GPUControlRegister.irqClear { raw &= ~value }
    words[offset] = value
  }
  func barrier() {}
}

@Test func theGPUInterruptDecodesAFaultAndClearsItsBit() {
  let r = IRQRegisters()
  let control = GPUControl(regs: r, clock: ModelClock())
  r.raw = GPUInterrupt.fault
  r.words[GPUControlRegister.faultStatus] = 0x80  // GPU_BUS_FAULT
  r.words[GPUControlRegister.faultAddress] = 0x1234_5000
  r.words[GPUControlRegister.faultAddress + 4] = 0x1
  let result = control.serveGPUInterrupt(mask: GPUInterrupt.enabled)
  #expect(result.handled == GPUInterrupt.fault)
  #expect(result.faults == ["GPU fault: GPU_BUS_FAULT, GPU_FAULT_STATUS 0x00000080 at 0x0000000112345000"])
  #expect(!result.resetCompleted && !result.cachesCleaned)
  #expect(r.raw == 0)
  #expect(r.stores.first?.offset == GPUControlRegister.irqClear && r.stores.first?.value == GPUInterrupt.fault)
  // Nothing raised: nothing written.
  r.stores = []
  #expect(control.serveGPUInterrupt(mask: GPUInterrupt.enabled) == GPUInterruptResult())
  #expect(r.stores.isEmpty)
}

@Test func theGPUInterruptTakesOnlyTheEventsItWasGiven() {
  let r = IRQRegisters()
  let control = GPUControl(regs: r, clock: ModelClock())
  r.raw = GPUInterrupt.protectedFault | GPUInterrupt.resetCompleted | GPUInterrupt.cleanCachesCompleted | 1 << 9 | 1 << 10
  r.words[GPUControlRegister.faultStatus] = 0xC1  // a translation fault, level 1
  // Without the line the pump looks at the faults alone: the completions are the control steps'.
  let faults = control.serveGPUInterrupt(mask: GPUInterrupt.faults)
  #expect(faults.handled == GPUInterrupt.protectedFault && !faults.resetCompleted && !faults.cachesCleaned)
  #expect(faults.faults.count == 1 && faults.faults[0].hasPrefix("GPU fault in protected mode: TRANSLATION_FAULT level 1"))
  #expect(r.raw == GPUInterrupt.resetCompleted | GPUInterrupt.cleanCachesCompleted | 1 << 9 | 1 << 10)
  // With it: the completions are cleared and counted; the power changes (03 section 3.8.4) stay unmasked-out.
  let all = control.serveGPUInterrupt(mask: GPUInterrupt.enabled)
  #expect(all.handled == GPUInterrupt.resetCompleted | GPUInterrupt.cleanCachesCompleted && all.faults.isEmpty)
  #expect(all.resetCompleted && all.cachesCleaned)
  #expect(r.raw == 1 << 9 | 1 << 10)
  #expect(GPUInterrupt.enabled == 0x0002_0103)
}

@Test func whatNoGPUReadsAsIsntOne() {
  #expect(!GPUID(0).isPlausible)
  #expect(!GPUID(UInt32.max).isPlausible)
  #expect(!GPUID(0x6000_0000).isPlausible)  // Bifrost, before CSF
  #expect(Probe(id: GPUID(0xC871_0000), shaderPresent: 0x3).name == "Mali-G620")
  #expect(Probe(id: GPUID(0xF000_0000)).name == "an unknown Mali")
}

