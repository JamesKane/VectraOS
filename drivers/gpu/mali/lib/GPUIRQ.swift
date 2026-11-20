// SPDX-License-Identifier: BSD-3-Clause

// The GPU-control interrupt block (chinese-wall's panthor 02 section 2.3.2,
// 03 section 3.8): which of its events the driver enables, and what it does
// with each. FAULT and PROTM_FAULT are logged and no reset follows (3.8.5);
// RESET_COMPLETED and CLEAN_CACHES_COMPLETED are what the control steps wait
// for by polling the raw status (they only have to be cleared, and are
// counted); the power-change events stay masked (3.8.4: they are enabled
// only to trace power, which the driver polls instead).
//
// Over a register file, so the host tests run it against the model GPU. The
// driver's interrupt thread calls it where the line fires, and the pump calls
// it as the fallback where the line can't be had: it reads the raw status,
// which holds the events whatever the mask says (03 section 2.1.1).

extension GPUInterrupt {
  /// GPU_FAULT: a GPU-level fault, GPU_FAULT_STATUS and GPU_FAULT_ADDR say which.
  public static let fault: UInt32 = 1 << 0
  public static let protectedFault: UInt32 = 1 << 1

  /// GPU_IRQ_MASK once the line is served (03 section 3.8.4): faults, reset
  /// completed and the cache clean.
  public static let enabled: UInt32 = fault | protectedFault | resetCompleted | cleanCachesCompleted
  /// What the pump handles with no line: the faults alone, since the control
  /// steps clear the completions they poll for.
  public static let faults: UInt32 = fault | protectedFault
}

/// What serving the GPU block found.
public struct GPUInterruptResult: Equatable, Sendable {
  /// The raw bits handled and cleared.
  public var handled: UInt32 = 0
  /// A line for each fault, decoded.
  public var faults: [String] = []
  public var resetCompleted = false
  public var cachesCleaned = false

  public init() {}
}

extension GPUControl {
  /// The GPU-level fault GPU_FAULT_STATUS and GPU_FAULT_ADDR hold (03 section
  /// 3.8.5): [7:0] is the exception code (02 section 2.8).
  public func gpuFault(protected: Bool) -> String {
    let status = regs.load32(GPUControlRegister.faultStatus)
    let address = load64(GPUControlRegister.faultAddress)
    return "GPU fault" + (protected ? " in protected mode" : "") + ": " + MMUFault.exceptionName(status & 0xFF)
      + ", GPU_FAULT_STATUS " + hex(status) + " at " + hex64(address)
  }

  /// The events of `mask` that GPU_IRQ_RAWSTAT holds (03 section 3.8.2, the
  /// threaded part): cleared first, then each handled. Nothing if none is
  /// raised. A fault is read after its bit is cleared, as the spec's handler does.
  public func serveGPUInterrupt(mask: UInt32) -> GPUInterruptResult {
    var result = GPUInterruptResult()
    let raw = regs.load32(GPUControlRegister.irqRawStat) & mask
    if raw == 0 { return result }
    regs.store32(GPUControlRegister.irqClear, raw)
    result.handled = raw
    if raw & GPUInterrupt.fault != 0 { result.faults.append(gpuFault(protected: false)) }
    if raw & GPUInterrupt.protectedFault != 0 { result.faults.append(gpuFault(protected: true)) }
    result.resetCompleted = raw & GPUInterrupt.resetCompleted != 0
    result.cachesCleaned = raw & GPUInterrupt.cleanCachesCompleted != 0
    return result
  }
}
