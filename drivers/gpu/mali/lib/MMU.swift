// SPDX-License-Identifier: BSD-3-Clause

// The GPU's MMU as the driver drives it (chinese-wall's panthor 04 section
// 4.3 to 4.5 and 4.9): the lock region of a page-table change, a fault's
// decoding, the cache flush that goes before every UNLOCK, and the full
// disable of a slot that a fault or a recycle ends. Over a register file, so
// the host tests run it against the model GPU.

/// AS_LOCKADDR's value (04 section 4.4.2): the naturally aligned block of
/// 2^(w+1) bytes, at least 32 KiB, that covers [start, end).
public enum ASLock {
  public static func region(start: UInt64, end: UInt64) -> UInt64 {
    precondition(end > start)
    let last = end - 1
    // The index of the highest bit in which the two ends differ, plus one.
    let differing = start ^ last
    let h = differing == 0 ? 0 : UInt64(64 - differing.leadingZeroBitCount)
    let w = max(h, 15) - 1
    let size = w + 1 >= 64 ? 0 : UInt64(1) << (w + 1)
    let base = size == 0 ? 0 : start & ~(size - 1)
    return base | w
  }
}

/// A page or bus fault in an address space (AS_FAULTSTATUS, 04 section 4.9.1).
public struct MMUFault: Equatable, Sendable {
  public var slot: Int
  public var status: UInt32
  public var address: UInt64

  public init(slot: Int, status: UInt32, address: UInt64) {
    self.slot = slot
    self.status = status
    self.address = address
  }

  /// [7:0].
  public var exception: UInt32 { status & 0xFF }
  /// [9:8]: atomic, execute, read or write.
  public var access: UInt32 { status >> 8 & 3 }
  /// Bit 10: a decoder fault, else a slave fault (informational).
  public var decoder: Bool { status >> 10 & 1 == 1 }
  /// [31:16].
  public var sourceID: UInt32 { status >> 16 }

  public var accessName: String {
    switch access {
    case 0: return "atomic"
    case 1: return "execute"
    case 2: return "read"
    default: return "write"
    }
  }

  /// The exception's name (panthor 02 section 2.8).
  public static func exceptionName(_ code: UInt32) -> String {
    switch code {
    case 0x00: return "OK"
    case 0x40: return "CS_CONFIG_FAULT"
    case 0x41: return "CS_UNRECOVERABLE"
    case 0x44: return "CS_ENDPOINT_FAULT"
    case 0x48: return "CS_BUS_FAULT"
    case 0x49: return "CS_INSTR_INVALID"
    case 0x4A: return "CS_CALL_STACK_OVERFLOW"
    case 0x4B: return "CS_INHERIT_FAULT"
    case 0x50: return "INSTR_INVALID_PC"
    case 0x51: return "INSTR_INVALID_ENC"
    case 0x55: return "INSTR_BARRIER_FAULT"
    case 0x58: return "DATA_INVALID_FAULT"
    case 0x59: return "TILE_RANGE_FAULT"
    case 0x5A: return "ADDR_RANGE_FAULT"
    case 0x5B: return "IMPRECISE_FAULT"
    case 0x60: return "OUT_OF_MEMORY"
    case 0x68: return "CSF_FW_INTERNAL_ERROR"
    case 0x80: return "GPU_BUS_FAULT"
    case 0x88: return "GPU_SHAREABILITY_FAULT"
    case 0x89: return "SYSTEM_SHAREABILITY_FAULT"
    case 0x8A: return "GPU_CACHEABILITY_FAULT"
    case 0xC0...0xC4: return "TRANSLATION_FAULT level \(code - 0xC0)"
    case 0xC8...0xCB: return "PERMISSION_FAULT level \(code - 0xC8)"
    case 0xD9...0xDB: return "ACCESS_FLAG_FAULT level \(code - 0xD8)"
    case 0xE0: return "ADDRESS_SIZE_FAULT (input)"
    case 0xE4...0xE7: return "ADDRESS_SIZE_FAULT (output) level \(code - 0xE4)"
    case 0xE8...0xEB: return "MEMORY_ATTRIBUTE_FAULT level \(code - 0xE8)"
    default: return "exception " + hex(code)
    }
  }

  /// One line for the status file.
  public var text: String {
    "address space \(slot): \(MMUFault.exceptionName(exception)) on a \(accessName) of " + hex64(address)
      + ", source \(hex(sourceID)), AS_FAULTSTATUS " + hex(status)
  }
}

/// GPU_CMD's cache flush and its completion (04 section 4.5).
extension GPUCommand {
  /// L2 and load/store cache clean and invalidate, other caches invalidate.
  public static let flushCaches: UInt32 = 0x0002_3304
}

extension GPUInterrupt {
  public static let cleanCachesCompleted: UInt32 = 1 << 17
}

extension ASRegister {
  public static let lockAddress = 0x10
}

extension ASCommand {
  public static let lock: UInt32 = 2
  public static let unlock: UInt32 = 3
  /// AS_TRANSCFG of a disabled slot (04 section 4.3.2): ADRMODE "unmapped",
  /// every access faults.
  public static let unmappedConfig: UInt64 = 1
}

/// MMU_IRQ_MASK and the fault bits of the address spaces (04 section 4.9.1):
/// bit n of [15:0] is a fault in slot n; [31:16] (command complete) is never
/// unmasked.
public enum MMUMask {
  public static func bit(slot: Int) -> UInt32 { 1 << UInt32(slot) }
  public static let faults: UInt32 = 0xFFFF
}

extension GPUControl {
  /// The whole-GPU cache flush (04 section 4.5): the command, then
  /// CLEAN_CACHES_COMPLETED within 100 ms, which is then cleared.
  public func flushCaches() throws(ControlFailure) {
    regs.store32(GPUControlRegister.irqClear, GPUInterrupt.cleanCachesCompleted)
    regs.store32(GPUControlRegister.command, GPUCommand.flushCaches)
    let done = wait(timeout: ControlTimeout.addressSpace, interval: ControlTimeout.addressSpaceInterval) {
      regs.load32(GPUControlRegister.irqRawStat) & GPUInterrupt.cleanCachesCompleted != 0
    }
    guard done else {
      throw ControlFailure(step: "cache flush", why: "no CLEAN_CACHES_COMPLETED in 100 ms, GPU_IRQ_RAWSTAT "
        + hex(regs.load32(GPUControlRegister.irqRawStat)))
    }
    regs.store32(GPUControlRegister.irqClear, GPUInterrupt.cleanCachesCompleted)
  }

  /// LOCK over [start, end) of slot `slot` (04 section 4.4.1 step 1): the
  /// region, then the command.
  public func lockAddressSpace(slot: Int, start: UInt64, end: UInt64) throws(ControlFailure) {
    let base = GPUControlRegister.as0 + slot * GPUControlRegister.asStride
    store64(base + ASRegister.lockAddress, ASLock.region(start: start, end: end))
    try asCommand(slot, ASCommand.lock)
  }

  /// UNLOCK (04 section 4.4.1 step 4).
  public func unlockAddressSpace(slot: Int) throws(ControlFailure) {
    try asCommand(slot, ASCommand.unlock)
  }

  /// The full disable of a slot (04 section 4.3.2): the caches flushed, an
  /// outstanding lock released, then no tables, no attributes and ADRMODE
  /// "unmapped", so every access faults. The caller has masked the slot's
  /// fault bit. `recycle`: stop after the unlock, the next enable overwrites
  /// the three registers.
  public func disableAddressSpace(slot: Int, locked: Bool, recycle: Bool = false) throws(ControlFailure) {
    try flushCaches()
    if locked { try unlockAddressSpace(slot: slot) }
    if recycle { return }
    let base = GPUControlRegister.as0 + slot * GPUControlRegister.asStride
    store64(base + ASRegister.translationTable, 0)
    store64(base + ASRegister.memoryAttributes, 0)
    store64(base + ASRegister.translationConfig, ASCommand.unmappedConfig)
    try asCommand(slot, ASCommand.update)
  }

  /// A slot's fault registers (04 section 4.9.1 step 1); AS_FAULTEXTRA is
  /// not read.
  public func fault(slot: Int) -> MMUFault {
    let base = GPUControlRegister.as0 + slot * GPUControlRegister.asStride
    return MMUFault(slot: slot, status: regs.load32(base + ASRegister.faultStatus),
                    address: load64(base + ASRegister.faultAddress))
  }
}
