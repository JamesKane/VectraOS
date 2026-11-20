// SPDX-License-Identifier: BSD-3-Clause

// The GPU's control sequences (panthor 03 section 3.3 and 3.4, 04 section
// 4.3, 05 section 5.3.2 and 5.5, 11 section 11.5 to 11.8) against a model
// GPU: registers that answer after a delay in a model clock, and a log of
// every store, so the order of the writes is checked as well as their values.

import Mali
import Testing

final class ModelClock: GPUClock {
  var time: Int64 = 0
  var pauses = 0
  func now() -> Int64 { time }
  func pause(nanoseconds: Int64) {
    time += nanoseconds
    pauses += 1
  }
}

/// A GPU's control block that does what the spec says each command does,
/// after a delay; a flag turns each step's completion off.
final class ModelGPU: GPURegisterFile {
  let clock: ModelClock
  var stores: [(offset: Int, value: UInt32)] = []
  var memory: [Int: UInt32] = [:]
  var barriers = 0

  var resetCompletes = true
  var l2Powers = true
  var mcuBoots = true
  var asBusyForever = false
  var coherencyReadsBack = true
  var timestampRate: UInt64 = 1_000_000_000

  var resetAt: Int64?
  var resetRaw = false
  var l2At: Int64?
  var l2Ready: UInt32 = 0
  var mcuAt: Int64?
  var jobRaw: UInt32 = 0
  var asStatusPolls = 0
  var asCommandAt: Int64?

  init(clock: ModelClock) { self.clock = clock }

  func barrier() { barriers += 1 }

  func load32(_ o: Int) -> UInt32 {
    switch o {
    case GPUControlRegister.irqRawStat:
      if let at = resetAt, clock.time >= at {
        resetRaw = true
        resetAt = nil
      }
      return resetRaw ? GPUInterrupt.resetCompleted : 0
    case GPUControlRegister.l2Ready:
      if let at = l2At, clock.time >= at {
        l2Ready = 1
        l2At = nil
      }
      return l2Ready
    case GPUControlRegister.l2PowerTransition:
      return 0
    case GPUControlRegister.jobIrqRawStat:
      if let at = mcuAt, clock.time >= at {
        jobRaw |= JobInterrupt.global
        mcuAt = nil
      }
      return jobRaw
    case GPUControlRegister.coherencyProtocol:
      return coherencyReadsBack ? memory[o] ?? 0 : 0
    case GPUControlRegister.coherencyFeatures:
      return 0x21  // ACE-Lite and the shareable-cache bit
    case GPUControlRegister.timestamp:
      return UInt32(truncatingIfNeeded: UInt64(clock.time) * timestampRate / 1_000_000_000)
    case GPUControlRegister.timestamp + 4:
      return UInt32(truncatingIfNeeded: (UInt64(clock.time) * timestampRate / 1_000_000_000) >> 32)
    case GPUControlRegister.as0 + ASRegister.status:
      if asBusyForever { return ASCommand.active }
      if let at = asCommandAt, clock.time < at { return ASCommand.active }
      return 0
    default:
      return memory[o] ?? 0
    }
  }

  func store32(_ o: Int, _ v: UInt32) {
    stores.append((o, v))
    memory[o] = v
    switch o {
    case GPUControlRegister.irqClear:
      if v & GPUInterrupt.resetCompleted != 0 { resetRaw = false }
    case GPUControlRegister.command:
      if v == GPUCommand.softReset, resetCompletes { resetAt = clock.time + 300_000 }
    case GPUControlRegister.l2PowerOn:
      if v & 1 != 0, l2Powers { l2At = clock.time + 1_000_000 }
    case GPUControlRegister.jobIrqClear:
      jobRaw &= ~v
    case GPUControlRegister.mcuControl:
      if v == MCU.enableAuto, mcuBoots { mcuAt = clock.time + 40_000_000 }
    case GPUControlRegister.as0 + ASRegister.command:
      asCommandAt = clock.time + 50_000
    default: break
    }
  }

  func wrote(_ offset: Int) -> UInt32? { stores.last(where: { $0.offset == offset })?.value }
  func index(of offset: Int) -> Int? { stores.firstIndex(where: { $0.offset == offset }) }
}

func rig() -> (ModelGPU, GPUControl<ModelGPU, ModelClock>, ModelClock) {
  let clock = ModelClock()
  let gpu = ModelGPU(clock: clock)
  return (gpu, GPUControl(regs: gpu, clock: clock), clock)
}

@Test func theHarvestWordLeavesTheCoresItDoesNotFuseOff() {
  // No fuse set: the full part.
  #expect(Sky1GPU.availableShaders(harvest: 0) == 0x0055_0555)
  // A fuse for bit 2 (field bit 4 + 2 = 6) removes core 2; bits outside [27:4] mean nothing.
  #expect(Sky1GPU.availableShaders(harvest: 1 << 6) == 0x0055_0551)
  #expect(Sky1GPU.availableShaders(harvest: 0xF000_000F) == 0x0055_0555)
  #expect(Sky1GPU.availableShaders(harvest: 0x0FFF_FFF0) == 0)
  // A fuse on a bit the part has no core at changes nothing.
  #expect(Sky1GPU.availableShaders(harvest: 1 << 5) == 0x0055_0555)
}

@Test func theSystemCacheValuesAreTheSpecs() {
  #expect(Sky1GPU.pbhaOverride3 == 0x2200_0000)
  #expect(Sky1GPU.sysAlloc == [0x0023_0000, 0x0000_0023, 0, 0, 0x0052_3222, 0x0052_3200, 0x22, 0x32])
  let (gpu, control, _) = rig()
  control.programSystemCache()
  #expect(gpu.wrote(0x32C) == 0x2200_0000)
  for n in 0..<8 { #expect(gpu.wrote(0x340 + 4 * n) == Sky1GPU.sysAlloc[n]) }
  #expect(gpu.stores.count == 9)
}

@Test func aSoftResetIsClearedCommandedAndWaitedFor() throws {
  let (gpu, control, clock) = rig()
  try control.softReset()
  // The stale completion is cleared before the command, and the command is 0x101.
  let clear = try #require(gpu.index(of: GPUControlRegister.irqClear))
  let command = try #require(gpu.index(of: GPUControlRegister.command))
  #expect(clear < command)
  #expect(gpu.wrote(GPUControlRegister.command) == 0x101)
  #expect(clock.time >= 300_000 && clock.time < 5_000_000)
  // Every interrupt block is masked afterwards.
  for mask in [GPUControlRegister.irqMask, GPUControlRegister.jobIrqMask, GPUControlRegister.mmuIrqMask] {
    #expect(gpu.wrote(mask) == 0)
  }
}

@Test func aResetThatNeverCompletesStopsAtItsTimeout() {
  let (gpu, control, clock) = rig()
  gpu.resetCompletes = false
  do throws(ControlFailure) {
    try control.softReset()
    Issue.record("a reset that never completed passed")
  } catch {
    #expect(error.step == "soft reset")
  }
  #expect(clock.time >= ControlTimeout.reset)
  #expect(clock.time < ControlTimeout.reset + 1_000_000)
}

@Test func coherencyIsAceLiteWithTheShareableBitWhereTheGPUHasIt() throws {
  let (gpu, control, _) = rig()
  let c = try control.setCoherency()
  #expect(c.features == 0x21)
  #expect(c.protocolValue == 0x20)
  #expect(gpu.wrote(GPUControlRegister.coherencyProtocol) == 0x20)
  #expect(Sky1GPU.coherencyProtocol(features: 0x01) == 0)
  #expect(Sky1GPU.coherencyProtocol(features: 0x20) == 0x20)
}

@Test func aCoherencyProtocolThatDoesNotStickIsAFailure() {
  let (gpu, control, _) = rig()
  gpu.coherencyReadsBack = false
  do throws(ControlFailure) {
    _ = try control.setCoherency()
    Issue.record("a protocol that reads 0 passed")
  } catch {
    #expect(error.step == "coherency")
  }
}

@Test func theL2PowersSliceZeroOnlyAndIsWaitedFor() throws {
  let (gpu, control, clock) = rig()
  try control.powerL2(present: 0x1)
  // 64 bits, low word then high word: 1 and 0.
  let low = try #require(gpu.index(of: GPUControlRegister.l2PowerOn))
  #expect(gpu.stores[low].value == 1)
  #expect(gpu.stores[low + 1].offset == GPUControlRegister.l2PowerOn + 4 && gpu.stores[low + 1].value == 0)
  #expect(clock.time >= 1_000_000 && clock.time < 21_000_000)
  // More slices present: still bit 0 alone.
  let (gpu2, control2, _) = rig()
  try control2.powerL2(present: 0x3)
  #expect(gpu2.wrote(GPUControlRegister.l2PowerOn) == 1)
}

@Test func anL2ThatNeverComesReadyOrIsAbsentStopsTheStep() {
  let (gpu, control, clock) = rig()
  gpu.l2Powers = false
  do throws(ControlFailure) {
    try control.powerL2(present: 1)
    Issue.record("an L2 that never readied passed")
  } catch {
    #expect(error.step == "L2 power")
    #expect(clock.time >= ControlTimeout.l2)
  }
  do throws(ControlFailure) {
    try control.powerL2(present: 0x2)
    Issue.record("an L2 with no slice 0 passed")
  } catch {
    #expect(error.step == "L2 power")
  }
}

@Test func anAddressSpaceIsProgrammedRootFirstAndUpdatedLast() throws {
  let (gpu, control, _) = rig()
  try control.programAddressSpace(slot: 0, root: 0x8_8000_1000, memAttr: 0x4C4C_4C4C_8C4C_8F4C, transCfg: 0x4200_01C6)
  let base = GPUControlRegister.as0
  #expect(gpu.barriers == 1)
  // Each 64-bit register low word first.
  let t = try #require(gpu.index(of: base + ASRegister.translationTable))
  #expect(gpu.stores[t].value == 0x8000_1000 && gpu.stores[t + 1].value == 0x8)
  #expect(gpu.wrote(base + ASRegister.memoryAttributes) == 0x8C4C_8F4C)
  #expect(gpu.wrote(base + ASRegister.memoryAttributes + 4) == 0x4C4C_4C4C)
  #expect(gpu.wrote(base + ASRegister.translationConfig) == 0x4200_01C6)
  let update = try #require(gpu.index(of: base + ASRegister.command))
  #expect(gpu.stores[update].value == 1)
  #expect(update > t && update > (gpu.index(of: base + ASRegister.translationConfig) ?? Int.max))
  // Slot 3's registers are 0xC0 further on.
  try control.programAddressSpace(slot: 3, root: 0x1000, memAttr: 0, transCfg: 0)
  #expect(gpu.wrote(base + 3 * 0x40 + ASRegister.command) == 1)
}

@Test func anAddressSpaceThatStaysActiveStopsTheStep() {
  let (gpu, control, clock) = rig()
  gpu.asBusyForever = true
  do throws(ControlFailure) {
    try control.programAddressSpace(slot: 0, root: 0x1000, memAttr: 0, transCfg: 0)
    Issue.record("a busy AS passed")
  } catch {
    #expect(error.step == "address space 0")
    #expect(clock.time >= ControlTimeout.addressSpace)
  }
}

@Test func theMCUStartsAutoAndTheGlobalInterruptEndsTheWait() throws {
  let (gpu, control, clock) = rig()
  try control.startMCU()
  #expect(gpu.wrote(GPUControlRegister.mcuControl) == 2)
  // The job block is masked and cleared before the MCU is told to run.
  let clear = try #require(gpu.index(of: GPUControlRegister.jobIrqClear))
  let enable = try #require(gpu.index(of: GPUControlRegister.mcuControl))
  #expect(clear < enable)
  #expect(clock.time >= 40_000_000 && clock.time < 60_000_000)
  // Bit 31 is acknowledged and nothing else is left.
  #expect(gpu.jobRaw == 0)
}

@Test func anMCUThatNeverBootsStopsAtASecondAndSaysWhatItIs() {
  let (gpu, control, clock) = rig()
  gpu.mcuBoots = false
  do throws(ControlFailure) {
    try control.startMCU()
    Issue.record("an MCU that never booted passed")
  } catch {
    #expect(error.step == "MCU boot")
    #expect(error.why.utf8.starts(with: "no global interface interrupt in 1 s".utf8))
    #expect(clock.time >= ControlTimeout.mcuBoot && clock.time < ControlTimeout.mcuBoot + 1_000_000)
  }
}

@Test func theTimestampFrequencyIsMeasuredToAMegahertz() {
  let (gpu, control, _) = rig()
  #expect(control.measureTimestampFrequency() == 1_000_000_000)
  gpu.timestampRate = 24_000_000
  #expect(control.measureTimestampFrequency() == 24_000_000)
  gpu.timestampRate = 0
  #expect(control.measureTimestampFrequency() == nil)
}

@Test func theFirmwareTimersFollowTheMeasuredFrequency() {
  // 10 ms at 1 GHz: ceil(10_000 * 1e9 / 1.024e9) = 9766; and none known: the maximum.
  let known = GlobalConfig.boot(shaderPresent: 0x55_0555, timestampFrequency: 1_000_000_000, coreFrequency: nil)
  #expect(known.pwroffTimer == 9766)
  #expect(known.idleTimer == 782)
  #expect(known.allocEn == 0x55_0555)
  let unknown = GlobalConfig.boot(shaderPresent: 1, timestampFrequency: nil, coreFrequency: nil)
  #expect(unknown.pwroffTimer == 0xFFFF_FFFF && unknown.idleTimer == 0xFFFF_FFFF)
}

@Test func theInterfaceReadsAsLines() {
  var csg = CSGLayout(control: 0x1000, input: 0, output: 0, features: 0x7, suspendSize: 0x10000, protmSuspendSize: 0x2000,
                      streamStride: 0x100, streams: [])
  let cs = CSLayout(control: 0, input: 0, output: 0, features: CSFeatures(0x0007_0F1F))
  csg.streams = [CSFeatures](repeating: cs.features, count: 8).map { CSLayout(control: 0, input: 0, output: 0, features: $0) }
  let layout = CSFLayout(version: CSFVersion(4, 1, 0), features: 0x3, input: 0, output: 0, groupStride: 0x100,
                         groups: [csg, csg, csg])
  let lines = layout.statusLines
  #expect(lines.count == 2)
  #expect(lines[0].utf8.starts(with: "firmware interface 4.1.0, GLB_FEATURES 0x00000003".utf8))
  #expect(lines[1].utf8.starts(with: "3 CSG slots (CSG_FEATURES 0x00000007, suspend buffer 65536 bytes".utf8))
  #expect(lines[1].contains("8 CS slots each"))
  #expect(lines[1].contains("32 work registers, 15 scoreboards, compute fragment tiler"))
}

@Test func discoveryRefusalsAreNamed() {
  #expect(CSFError.notBooted.description == "GLB_VERSION reads 0")
  #expect(CSFError.groupCount(2).description == "2 CSG slots, not 3 to 31")
  #expect(CSFError.outsideSection(.groupInput, group: 1, stream: 0).description.contains("CSG input"))
  #expect(CSFError.mismatch(.streamFeatures, group: 2, stream: 3).description.contains("CS_FEATURES"))
}
