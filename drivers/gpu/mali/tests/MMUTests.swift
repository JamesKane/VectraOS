// SPDX-License-Identifier: BSD-3-Clause

// The MMU's sequences (panthor 04 section 4.3 to 4.5 and 4.9): the lock
// region's encoding against the spec's worked example, the cache flush and
// the order of a slot's lock, unlock and disable, and a fault's decoding.

import Mali
import Testing

/// A register file with address spaces and a cache flush that completes: it
/// records every store and answers the status registers as the spec says.
final class MMUModel: GPURegisterFile {
  var stores: [(offset: Int, value: UInt32)] = []
  var memory: [Int: UInt32] = [:]
  var flushCompletes = true
  var flushes = 0
  var raw: UInt32 = 0
  var stuckActive = false

  func barrier() {}

  func load32(_ o: Int) -> UInt32 {
    if o == GPUControlRegister.irqRawStat { return raw }
    for slot in 0..<16 where o == GPUControlRegister.as0 + slot * GPUControlRegister.asStride + ASRegister.status {
      return stuckActive ? ASCommand.active : 0
    }
    return memory[o] ?? 0
  }

  func store32(_ o: Int, _ v: UInt32) {
    stores.append((o, v))
    memory[o] = v
    if o == GPUControlRegister.command, v == GPUCommand.flushCaches {
      flushes += 1
      if flushCompletes { raw |= GPUInterrupt.cleanCachesCompleted }
    }
    if o == GPUControlRegister.irqClear { raw &= ~v }
  }

  func asBase(_ slot: Int) -> Int { GPUControlRegister.as0 + slot * GPUControlRegister.asStride }
  func commands(_ slot: Int) -> [UInt32] {
    stores.filter { $0.offset == asBase(slot) + ASRegister.command }.map { $0.value }
  }
  func index(of offset: Int, _ value: UInt32? = nil) -> Int? {
    stores.firstIndex { $0.offset == offset && (value == nil || $0.value == value) }
  }
}

func mmuRig() -> (MMUModel, GPUControl<MMUModel, ModelClock>) {
  let gpu = MMUModel()
  return (gpu, GPUControl(regs: gpu, clock: ModelClock()))
}

@Test func theLockRegionOfTheSpecsExampleIs32KiBAtItsBase() {
  // 04 section 4.4.2: 0x1_0000_3000 to 0x1_0000_5000 is 32 KiB at 0x1_0000_0000, written 0x1_0000_000E.
  #expect(ASLock.region(start: 0x1_0000_3000, end: 0x1_0000_5000) == 0x0000_0001_0000_000E)
}

@Test func aLockRegionIsNeverUnder32KiBAndIsNaturallyAligned() {
  // One page: still the 32 KiB minimum (w = 14), based at the 32 KiB below.
  #expect(ASLock.region(start: 0x2_0000_9000, end: 0x2_0000_A000) == 0x2_0000_8000 | 14)
  // A range across a 32 KiB boundary widens to the block that holds both ends.
  #expect(ASLock.region(start: 0x7000, end: 0x9000) == 0x0 | 15)
  // 2 MiB aligned, exactly 2 MiB: w = 20.
  #expect(ASLock.region(start: 0x4000_0000, end: 0x4020_0000) == 0x4000_0000 | 20)
  // The whole 48-bit space: w = 47, base 0.
  #expect(ASLock.region(start: 0, end: 1 << 48) == 47)
  // The block is always aligned to its own size and holds the range.
  for (s, e) in [(UInt64(0x1234_5000), UInt64(0x1236_0000)), (0x8000, 0x8001), (0xFFFF_F000, 0x1_0000_1000)] {
    let r = ASLock.region(start: s, end: e)
    let w = r & 63
    let base = r & ~63
    let size = UInt64(1) << (w + 1)
    #expect(base % size == 0 || w < 15)
    #expect(base <= s && e <= base + size)
    #expect(w >= 14)
  }
}

@Test func aCacheFlushIsTheCommandAndItsCompletionIsCleared() throws {
  let (gpu, control) = mmuRig()
  try control.flushCaches()
  #expect(gpu.flushes == 1)
  #expect(GPUCommand.flushCaches == 0x0002_3304)
  #expect(gpu.raw & GPUInterrupt.cleanCachesCompleted == 0)
  // The stale completion was cleared before the command, so an old one doesn't end the wait.
  let clear = try #require(gpu.index(of: GPUControlRegister.irqClear))
  let command = try #require(gpu.index(of: GPUControlRegister.command))
  #expect(clear < command)
}

@Test func aCacheFlushThatDoesNotCompleteNamesItself() {
  let (gpu, control) = mmuRig()
  gpu.flushCompletes = false
  do {
    try control.flushCaches()
    Issue.record("a flush that never completes must fail")
  } catch {
    #expect(error.step == "cache flush")
  }
}

@Test func aLockIsItsRegionThenTheCommand() throws {
  let (gpu, control) = mmuRig()
  try control.lockAddressSpace(slot: 3, start: 0x1_0000_3000, end: 0x1_0000_5000)
  let base = gpu.asBase(3)
  #expect(gpu.memory[base + ASRegister.lockAddress] == 0x0000_000E)
  #expect(gpu.memory[base + ASRegister.lockAddress + 4] == 1)
  #expect(gpu.commands(3) == [ASCommand.lock])
  let region = try #require(gpu.index(of: base + ASRegister.lockAddress))
  let command = try #require(gpu.index(of: base + ASRegister.command))
  #expect(region < command)
  try control.unlockAddressSpace(slot: 3)
  #expect(gpu.commands(3) == [ASCommand.lock, ASCommand.unlock])
}

@Test func theFullDisableFlushesUnlocksThenUnmapsTheSlot() throws {
  let (gpu, control) = mmuRig()
  try control.disableAddressSpace(slot: 2, locked: true)
  let base = gpu.asBase(2)
  #expect(gpu.flushes == 1)
  #expect(gpu.commands(2) == [ASCommand.unlock, ASCommand.update])
  #expect(gpu.memory[base + ASRegister.translationTable] == 0)
  #expect(gpu.memory[base + ASRegister.memoryAttributes] == 0)
  #expect(gpu.memory[base + ASRegister.translationConfig] == 1)  // ADRMODE unmapped
  let flush = try #require(gpu.index(of: GPUControlRegister.command, GPUCommand.flushCaches))
  let unlock = try #require(gpu.index(of: base + ASRegister.command, ASCommand.unlock))
  let update = try #require(gpu.index(of: base + ASRegister.command, ASCommand.update))
  #expect(flush < unlock && unlock < update)
}

@Test func theRecycleFormStopsAfterTheUnlockAndAnUnlockedSlotSkipsIt() throws {
  let (gpu, control) = mmuRig()
  try control.disableAddressSpace(slot: 1, locked: true, recycle: true)
  #expect(gpu.commands(1) == [ASCommand.unlock])
  #expect(gpu.memory[gpu.asBase(1) + ASRegister.translationConfig] == nil)
  let (other, c2) = mmuRig()
  try c2.disableAddressSpace(slot: 1, locked: false)
  #expect(other.commands(1) == [ASCommand.update])
  #expect(other.flushes == 1)
}

@Test func aSlotThatStaysActiveFailsItsCommand() {
  let (gpu, control) = mmuRig()
  gpu.stuckActive = true
  do {
    try control.lockAddressSpace(slot: 1, start: 0, end: 4096)
    Issue.record("a stuck AS_STATUS must fail the command")
  } catch {
    #expect(error.step == "address space 1")
  }
}

@Test func aFaultIsDecodedFromItsStatusAndAddress() {
  let (gpu, control) = mmuRig()
  // Slot 2: a translation fault at level 3 on a read (access 2), source 0x0123, a decoder fault.
  let base = gpu.asBase(2)
  gpu.memory[base + ASRegister.faultStatus] = 0x0123_0000 | 1 << 10 | 2 << 8 | 0xC3
  gpu.memory[base + ASRegister.faultAddress] = 0xDEAD_B000
  gpu.memory[base + ASRegister.faultAddress + 4] = 0x1
  let f = control.fault(slot: 2)
  #expect(f.slot == 2)
  #expect(f.exception == 0xC3)
  #expect(f.accessName == "read")
  #expect(f.decoder)
  #expect(f.sourceID == 0x0123)
  #expect(f.address == 0x1_DEAD_B000)
  #expect(MMUFault.exceptionName(0xC3) == "TRANSLATION_FAULT level 3")
  #expect(MMUFault.exceptionName(0xC9) == "PERMISSION_FAULT level 1")
  #expect(MMUFault.exceptionName(0xDA) == "ACCESS_FLAG_FAULT level 2")
  #expect(f.text.contains("TRANSLATION_FAULT level 3 on a read of 0x00000001dead"))
}

@Test func theMMUMaskNeverUnmasksTheCommandCompleteHalf() {
  #expect(MMUMask.faults == 0xFFFF)
  #expect(MMUMask.bit(slot: 5) == 0x20)
}
