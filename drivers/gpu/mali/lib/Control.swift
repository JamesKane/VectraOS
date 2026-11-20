// SPDX-License-Identifier: BSD-3-Clause

// The GPU's control sequences, over its registers (chinese-wall's panthor
// 02 section 2.3 to 2.7, 03 section 3.3 and 3.4, 04 section 4.3, 05 section
// 5.3.2 and 5.5, 11 section 11.8): soft reset, the coherency protocol, the
// Sky1's system-cache values, the L2's power, an address space's
// programming and the MCU's start. Each step either completes or throws
// the step's name and why, with the registers that explain it.
//
// Generic over a register file and a clock, so the host tests run the same
// code against a model GPU and the driver runs it over its mapped BAR 1.
// Nothing here waits on an interrupt: every interrupt block is masked (the
// raw status registers are read, which the spec allows with the mask at 0,
// 03 section 2.1.1), so a step's wait is a bounded poll.

/// The GPU's registers, in 32-bit accesses at byte offsets from its BAR.
public protocol GPURegisterFile {
  func load32(_ offset: Int) -> UInt32
  func store32(_ offset: Int, _ value: UInt32)
  /// Makes every earlier store to memory the GPU reads visible before the
  /// next register write.
  func barrier()
}

/// Time, in nanoseconds on a monotonic clock.
public protocol GPUClock {
  func now() -> Int64
  /// Waits about `nanoseconds` (a short wait may spin).
  func pause(nanoseconds: Int64)
}

/// The control block's registers beyond the probe's (`GPURegister`).
public enum GPUControlRegister {
  public static let irqRawStat = 0x20
  public static let irqClear = 0x24
  public static let irqMask = 0x28
  public static let command = 0x30
  public static let faultStatus = 0x3C
  /// 64 bits.
  public static let faultAddress = 0x40
  /// 64 bits, a free-running counter.
  public static let timestamp = 0x98
  public static let l2Ready = 0x160
  /// 64 bits, write.
  public static let l2PowerOn = 0x1A0
  public static let l2PowerTransition = 0x220
  public static let coherencyFeatures = 0x300
  public static let coherencyProtocol = 0x304
  /// Four registers from here.
  public static let sysPBHAOverride = 0x320
  /// Eight registers from here.
  public static let sysAlloc = 0x340
  public static let mcuControl = 0x700
  public static let mcuStatus = 0x704
  public static let jobIrqRawStat = 0x1000
  public static let jobIrqClear = 0x1004
  public static let jobIrqMask = 0x1008
  public static let mmuIrqRawStat = 0x2000
  public static let mmuIrqClear = 0x2004
  public static let mmuIrqMask = 0x2008
  /// Slot `n`'s registers are at `as0 + n * asStride`.
  public static let as0 = 0x2400
  public static let asStride = 0x40
  /// Doorbell `i` is at `doorbells + i * doorbellStride`.
  public static let doorbells = 0x80000
  public static let doorbellStride = 0x10000
}

/// An address space slot's registers, from its base.
public enum ASRegister {
  public static let translationTable = 0x00
  public static let memoryAttributes = 0x08
  public static let command = 0x18
  public static let faultStatus = 0x1C
  public static let faultAddress = 0x20
  public static let status = 0x28
  public static let translationConfig = 0x30
}

/// GPU_CMD's values and the interrupt bits the control steps wait for.
public enum GPUCommand {
  public static let softReset: UInt32 = 0x101
}

public enum GPUInterrupt {
  public static let resetCompleted: UInt32 = 1 << 8
}

/// The JOB block's bit the firmware raises for the global interface.
public enum JobInterrupt {
  public static let global: UInt32 = 1 << 31
}

/// MCU_CONTROL's and MCU_STATUS's values.
public enum MCU {
  public static let enableAuto: UInt32 = 2
  public static func statusName(_ v: UInt32) -> String {
    switch v {
    case 0: return "disabled"
    case 1: return "enabled"
    case 2: return "halted"
    case 3: return "fatal"
    default: return "unknown"
    }
  }
}

/// AS_COMMAND's UPDATE, and AS_STATUS's active bit.
public enum ASCommand {
  public static let update: UInt32 = 1
  public static let active: UInt32 = 1
}

/// A step that did not complete: its name, and why.
public struct ControlFailure: Error, Equatable, Sendable {
  public let step: String
  public let why: String
  public init(step: String, why: String) {
    self.step = step
    self.why = why
  }
}

/// How long each step may take (03 section 3.3.1, 3.4.1; 04 section 4.3.3; 05
/// section 5.5), nanoseconds; the intervals are the polls' spacing.
public enum ControlTimeout {
  public static let reset: Int64 = 100_000_000
  public static let l2: Int64 = 20_000_000
  public static let addressSpace: Int64 = 100_000_000
  public static let mcuBoot: Int64 = 1_000_000_000
  public static let ping: Int64 = 100_000_000
  public static let resetInterval: Int64 = 100_000
  public static let l2Interval: Int64 = 100_000
  public static let addressSpaceInterval: Int64 = 10_000
  public static let mcuBootInterval: Int64 = 200_000
}

/// What the Sky1's order writes beyond the generic one (panthor 11
/// section 11.4 to 11.8).
extension Sky1GPU {
  /// The full part's shader mask (ten cores), which the RCSU's fuses reduce.
  public static let fullShaderMask: UInt32 = 0x0055_0555

  /// The cores a fuse word leaves (11.6): NOT((v AND 0x0FFFFFF0) >> 4) AND
  /// the full mask.
  public static func availableShaders(harvest v: UInt32) -> UInt32 {
    ~((v & 0x0FFF_FFF0) >> 4) & fullShaderMask
  }

  /// SYSC_PBHA_OVERRIDE3 (11.8.2); the other three override registers are left alone.
  public static let pbhaOverride3: UInt32 = 0x2200_0000
  /// SYSC_ALLOC0 to SYSC_ALLOC7 (11.8.2).
  public static let sysAlloc: [UInt32] = [
    0x0023_0000, 0x0000_0023, 0x0000_0000, 0x0000_0000, 0x0052_3222, 0x0052_3200, 0x0000_0022, 0x0000_0032,
  ]

  /// COHERENCY_PROTOCOL's values (02 section 2.3): ACE-Lite is 0, and bit
  /// 5 is added where COHERENCY_FEATURES has it (11.7).
  public static let aceLite: UInt32 = 0
  public static let shareableCacheBit: UInt32 = 1 << 5
  public static func coherencyProtocol(features: UInt32) -> UInt32 {
    aceLite | (features & shareableCacheBit)
  }
}

public struct GPUControl<R: GPURegisterFile, C: GPUClock> {
  public let regs: R
  public let clock: C

  public init(regs: R, clock: C) {
    self.regs = regs
    self.clock = clock
  }

  /// Polls `done` every `interval` until it holds or `timeout` passes; it
  /// is checked once more at the deadline (03 section 3.2). Whether it held.
  public func wait(timeout: Int64, interval: Int64, _ done: () -> Bool) -> Bool {
    let deadline = clock.now() + timeout
    while true {
      if done() { return true }
      if clock.now() >= deadline { return done() }
      clock.pause(nanoseconds: interval)
    }
  }

  func load64(_ o: Int) -> UInt64 { UInt64(regs.load32(o)) | UInt64(regs.load32(o + 4)) << 32 }

  /// A 64-bit register, low word first (02 section 2.1).
  func store64(_ o: Int, _ v: UInt64) {
    regs.store32(o, UInt32(truncatingIfNeeded: v))
    regs.store32(o + 4, UInt32(truncatingIfNeeded: v >> 32))
  }

  /// Every interrupt block masked and its events cleared: the control
  /// steps poll the raw status.
  public func maskInterrupts() {
    regs.store32(GPUControlRegister.irqMask, 0)
    regs.store32(GPUControlRegister.irqClear, 0xFFFF_FFFF)
    regs.store32(GPUControlRegister.jobIrqMask, 0)
    regs.store32(GPUControlRegister.jobIrqClear, 0xFFFF_FFFF)
    regs.store32(GPUControlRegister.mmuIrqMask, 0)
    regs.store32(GPUControlRegister.mmuIrqClear, 0xFFFF_FFFF)
  }

  /// Soft reset (03 section 3.3.1): the stale completion cleared, the
  /// command, RESET_COMPLETED within 100 ms, then every interrupt masked
  /// (a reset may leave the masks as they were: 03's open question).
  public func softReset() throws(ControlFailure) {
    regs.store32(GPUControlRegister.irqClear, GPUInterrupt.resetCompleted)
    regs.store32(GPUControlRegister.command, GPUCommand.softReset)
    let done = wait(timeout: ControlTimeout.reset, interval: ControlTimeout.resetInterval) {
      regs.load32(GPUControlRegister.irqRawStat) & GPUInterrupt.resetCompleted != 0
    }
    guard done else {
      throw ControlFailure(step: "soft reset", why: "no RESET_COMPLETED in 100 ms, GPU_IRQ_RAWSTAT "
        + hex(regs.load32(GPUControlRegister.irqRawStat)))
    }
    maskInterrupts()
  }

  /// COHERENCY_PROTOCOL (11.7): ACE-Lite, plus the shareable-cache bit where
  /// COHERENCY_FEATURES has it, before the L2 powers up. The features read
  /// and the protocol read back.
  public func setCoherency() throws(ControlFailure) -> (features: UInt32, protocolValue: UInt32) {
    let features = regs.load32(GPUControlRegister.coherencyFeatures)
    let value = Sky1GPU.coherencyProtocol(features: features)
    regs.store32(GPUControlRegister.coherencyProtocol, value)
    let back = regs.load32(GPUControlRegister.coherencyProtocol)
    guard back == value else {
      throw ControlFailure(step: "coherency", why: "COHERENCY_PROTOCOL wrote \(hex(value)) and reads \(hex(back))"
        + " (COHERENCY_FEATURES \(hex(features)))")
    }
    return (features, back)
  }

  /// The Sky1's system-cache values (11.8.2), before the L2 powers up.
  public func programSystemCache() {
    regs.store32(GPUControlRegister.sysPBHAOverride + 12, Sky1GPU.pbhaOverride3)
    for (n, v) in Sky1GPU.sysAlloc.enumerated() { regs.store32(GPUControlRegister.sysAlloc + 4 * n, v) }
  }

  /// The L2's power, bit 0 of L2_PRESENT only (03 section 3.4.1, 11.9): its
  /// transitions settled, the power-on, L2_READY bit 0, each within 20 ms.
  public func powerL2(present: UInt64) throws(ControlFailure) {
    guard present & 1 != 0 else {
      throw ControlFailure(step: "L2 power", why: "L2_PRESENT \(hex64(present)) has no slice 0")
    }
    let settled = wait(timeout: ControlTimeout.l2, interval: ControlTimeout.l2Interval) {
      regs.load32(GPUControlRegister.l2PowerTransition) & 1 == 0
    }
    guard settled else {
      throw ControlFailure(step: "L2 power", why: "L2_PWRTRANS stays busy for 20 ms")
    }
    store64(GPUControlRegister.l2PowerOn, 1)
    let ready = wait(timeout: ControlTimeout.l2, interval: ControlTimeout.l2Interval) {
      regs.load32(GPUControlRegister.l2Ready) & 1 != 0
    }
    guard ready else {
      throw ControlFailure(step: "L2 power", why: "L2_READY \(hex(regs.load32(GPUControlRegister.l2Ready)))"
        + " after 20 ms, L2_PWRTRANS \(hex(regs.load32(GPUControlRegister.l2PowerTransition)))")
    }
  }

  /// One AS command (04 section 4.3.3): idle, the command, idle again.
  func asCommand(_ slot: Int, _ command: UInt32) throws(ControlFailure) {
    let base = GPUControlRegister.as0 + slot * GPUControlRegister.asStride
    func idle() -> Bool { regs.load32(base + ASRegister.status) & ASCommand.active == 0 }
    guard wait(timeout: ControlTimeout.addressSpace, interval: ControlTimeout.addressSpaceInterval, idle) else {
      throw ControlFailure(step: "address space \(slot)", why: "AS_STATUS active before the command")
    }
    regs.store32(base + ASRegister.command, command)
    guard wait(timeout: ControlTimeout.addressSpace, interval: ControlTimeout.addressSpaceInterval, idle) else {
      throw ControlFailure(step: "address space \(slot)", why: "AS_STATUS stays active after the command")
    }
  }

  /// Binds a VM to slot `slot` (04 section 4.3.1, 05 section 5.3.2): its
  /// root table, memory attributes and translation configuration, then UPDATE.
  /// The tables' memory is written first (`barrier`).
  public func programAddressSpace(slot: Int, root: UInt64, memAttr: UInt64, transCfg: UInt64)
    throws(ControlFailure) {
    let base = GPUControlRegister.as0 + slot * GPUControlRegister.asStride
    regs.barrier()
    regs.store32(GPUControlRegister.mmuIrqClear, 1 << UInt32(slot))
    store64(base + ASRegister.translationTable, root)
    store64(base + ASRegister.memoryAttributes, memAttr)
    store64(base + ASRegister.translationConfig, transCfg)
    try asCommand(slot, ASCommand.update)
  }

  /// MCU_CONTROL auto, and the global interface's interrupt bit within 1 s
  /// (05 section 5.5 steps 5 to 7); the bit is then cleared. Everything the
  /// firmware raised before is cleared first.
  public func startMCU() throws(ControlFailure) {
    regs.store32(GPUControlRegister.jobIrqMask, 0)
    regs.store32(GPUControlRegister.jobIrqClear, 0xFFFF_FFFF)
    regs.barrier()
    regs.store32(GPUControlRegister.mcuControl, MCU.enableAuto)
    let booted = wait(timeout: ControlTimeout.mcuBoot, interval: ControlTimeout.mcuBootInterval) {
      regs.load32(GPUControlRegister.jobIrqRawStat) & JobInterrupt.global != 0
    }
    guard booted else {
      let status = regs.load32(GPUControlRegister.mcuStatus)
      throw ControlFailure(step: "MCU boot", why: "no global interface interrupt in 1 s, MCU_STATUS \(status)"
        + " (\(MCU.statusName(status))), JOB_IRQ_RAWSTAT \(hex(regs.load32(GPUControlRegister.jobIrqRawStat)))")
    }
    regs.store32(GPUControlRegister.jobIrqClear, JobInterrupt.global)
  }

  /// GPU_TIMESTAMP, read high, low, high until the highs agree (02 section 2.1).
  public func timestamp() -> UInt64 {
    while true {
      let high = regs.load32(GPUControlRegister.timestamp + 4)
      let low = regs.load32(GPUControlRegister.timestamp)
      if regs.load32(GPUControlRegister.timestamp + 4) == high { return UInt64(high) << 32 | UInt64(low) }
    }
  }

  /// The frequency GPU_TIMESTAMP counts at (the system timer's, 03 section
  /// 3.10), which the firmware's timers are given in: measured over 2 ms
  /// of the clock and rounded to a MHz. Nil if it does not count.
  public func measureTimestampFrequency() -> UInt64? {
    let span: Int64 = 2_000_000
    let t0 = clock.now()
    let c0 = timestamp()
    while clock.now() - t0 < span { clock.pause(nanoseconds: 100_000) }
    let t1 = clock.now()
    let c1 = timestamp()
    guard c1 > c0, t1 > t0 else { return nil }
    let hertz = (c1 - c0) * 1_000_000_000 / UInt64(t1 - t0)
    let rounded = (hertz + 500_000) / 1_000_000 * 1_000_000
    return rounded == 0 ? nil : rounded
  }

  /// What the GPU says when a step fails: the fault registers, the MCU and
  /// the interrupt blocks' raw status, and address space 0's fault.
  public func diagnostics() -> String {
    let as0 = GPUControlRegister.as0
    return "GPU_FAULT_STATUS \(hex(regs.load32(GPUControlRegister.faultStatus)))"
      + " addr \(hex64(load64(GPUControlRegister.faultAddress)))"
      + ", MCU_STATUS \(MCU.statusName(regs.load32(GPUControlRegister.mcuStatus)))"
      + ", GPU_IRQ_RAWSTAT \(hex(regs.load32(GPUControlRegister.irqRawStat)))"
      + ", JOB \(hex(regs.load32(GPUControlRegister.jobIrqRawStat)))"
      + ", MMU \(hex(regs.load32(GPUControlRegister.mmuIrqRawStat)))"
      + ", AS0 fault \(hex(regs.load32(as0 + ASRegister.faultStatus)))"
      + " at \(hex64(load64(as0 + ASRegister.faultAddress)))"
  }
}
