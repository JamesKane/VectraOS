// SPDX-License-Identifier: BSD-3-Clause

// A driver host's device (architecture §9): exactly the MMIO, IRQ, BTI and
// I/O port handles for it, which devmgr grants (drivers/devmgr/lib's
// Grants.swift) as startup handles of type `HandleType.device`, whose
// argument says which: 0-5 the BAR of that index, `configSpace` the
// configuration space, `interruptBase` plus the trigger mode the
// interrupt, `dmaBTI` the BTI, `msiAllocation` an MSI allocation,
// `firmwareCall` an SMC resource for the firmware it calls. A
// driver waits for its interrupt on a port bound to it (`InterruptPort`:
// V1's object_bind and interrupt_ack, D20, D40).

import Sys

public enum DeviceHandle {
  /// The argument of the configuration space's resource.
  public static let configSpace: UInt32 = 0x10

  /// The interrupt's argument, plus its mode's value (Interrupt.Mode).
  public static let interruptBase: UInt32 = 0x100
  public static let dmaBTI: UInt32 = 0x20
  public static var bti: UInt32 { HandleType.info(HandleType.device, dmaBTI) }
  /// An MSI allocation for a function with MSI-X or MSI (croi K9d).
  public static let msiAllocation: UInt32 = 0x30
  public static var msi: UInt32 { HandleType.info(HandleType.device, msiAllocation) }
  /// An SMC resource for firmware the device's driver calls (arm64).
  public static let firmwareCall: UInt32 = 0x40
  public static var smc: UInt32 { HandleType.info(HandleType.device, firmwareCall) }

  public static func bar(_ index: Int) -> UInt32 { HandleType.info(HandleType.device, UInt32(index)) }
  public static var config: UInt32 { HandleType.info(HandleType.device, configSpace) }
  public static func interrupt(_ mode: Interrupt.Mode) -> UInt32 {
    HandleType.info(HandleType.device, interruptBase + mode.rawValue)
  }
}

/// A driver host's device: the resources it was started with, taken by
/// their info words (natively `Startup.current.take`).
public struct DeviceResources: ~Copyable {
  var bars: [(index: Int, handle: UInt32)] = []
  var config: UInt32 = 0
  var irq: UInt32 = 0
  var bti: UInt32 = 0
  var msi: UInt32 = 0
  var smc: UInt32 = 0
  /// The interrupt's trigger mode, if one was granted.
  public private(set) var interruptMode: Interrupt.Mode?

  public init(take: (UInt32) -> UInt32?) {
    for i in 0..<6 {
      if let h = take(DeviceHandle.bar(i)) { bars.append((i, h)) }
    }
    config = take(DeviceHandle.config) ?? 0
    bti = take(DeviceHandle.bti) ?? 0
    msi = take(DeviceHandle.msi) ?? 0
    smc = take(DeviceHandle.smc) ?? 0
    for mode in [Interrupt.Mode.default, .edgeLow, .edgeHigh, .levelLow, .levelHigh] {
      if let h = take(DeviceHandle.interrupt(mode)) {
        irq = h
        interruptMode = mode
      }
    }
  }

  deinit {
    for b in bars { close(raw: b.handle) }
    if config != 0 { close(raw: config) }
    if irq != 0 { close(raw: irq) }
    if bti != 0 { close(raw: bti) }
    if msi != 0 { close(raw: msi) }
    if smc != 0 { close(raw: smc) }
  }

  /// The SMC resource for the firmware its driver calls, which the
  /// caller owns from then on.
  public mutating func takeSMC() -> Handle? {
    guard smc != 0 else { return nil }
    let h = Handle(raw: smc)
    smc = 0
    return h
  }

  /// Whether an MSI allocation was granted.
  public var hasMSI: Bool { msi != 0 }

  /// MSI interrupt `id` from the allocation, its MSI-X table at `offset` in
  /// BAR `bar` (a physical VMO over the BAR is made for croi to program it).
  public func msixInterrupt(id: UInt32, bar: Int, offset: Int) throws(Status) -> Handle {
    guard msi != 0, let raw = bars.first(where: { $0.index == bar })?.handle else { throw .notFound }
    let vmo = try borrowed(raw) { (h: borrowing Handle) throws(Status) in
      let info = try Resource.info(h)
      let base = info.base & ~4095
      return try VMO.physical(resource: h, address: base, size: Int((info.base - base + info.size + 4095) & ~4095))
    }
    return try borrowed(msi) { (allocation: borrowing Handle) throws(Status) in
      try Interrupt.msi(allocation: allocation, id: id, vmo: vmo, offset: offset, msix: true)
    }
  }

  /// The device's BTI, which the caller owns from then on.
  public mutating func takeBTI() -> Handle? {
    guard bti != 0 else { return nil }
    let h = Handle(raw: bti)
    bti = 0
    return h
  }

  /// The interrupt's number (the GSI), if one was granted.
  public func interruptNumber() throws(Status) -> UInt32 {
    guard irq != 0 else { throw .notFound }
    return try borrowed(irq) { (h: borrowing Handle) throws(Status) in UInt32(truncatingIfNeeded: try Resource.info(h).base) }
  }

  /// The device's interrupt object, to wait for through an `InterruptPort`.
  public func interrupt() throws(Status) -> Handle {
    guard irq != 0, let mode = interruptMode else { throw .notFound }
    let number = try interruptNumber()
    return try borrowed(irq) { (h: borrowing Handle) throws(Status) in
      try Interrupt.create(resource: h, number: number, mode: mode)
    }
  }

  /// The BARs it may use.
  public var barIndices: [Int] { bars.map { $0.index } }

  /// What resource `index` grants: base and size, and whether it is I/O ports.
  public func bar(_ index: Int) throws(Status) -> ResourceInfo {
    guard let raw = bars.first(where: { $0.index == index })?.handle else { throw .notFound }
    return try borrowed(raw) { (h: borrowing Handle) throws(Status) in try Resource.info(h) }
  }

  /// Calls `body` with BAR `index`'s resource, which stays this value's.
  public func borrowedBAR<R: ~Copyable>(_ index: Int, _ body: (borrowing Handle) throws(Status) -> R) throws(Status) -> R {
    guard let raw = bars.first(where: { $0.index == index })?.handle else { throw .notFound }
    return try borrowed(raw, body)
  }

  /// BAR `index` (memory) mapped uncached, as device registers are.
  public func map(bar index: Int) throws(Status) -> Registers {
    guard let raw = bars.first(where: { $0.index == index })?.handle else { throw .notFound }
    return try map(raw)
  }

  /// The function's configuration space, mapped.
  public func mapConfig() throws(Status) -> Registers {
    guard config != 0 else { throw .notFound }
    return try map(config)
  }

  func map(_ raw: UInt32) throws(Status) -> Registers {
    try borrowed(raw) { (h: borrowing Handle) throws(Status) in try Registers.map(h) }
  }

  func borrowed<R: ~Copyable>(_ raw: UInt32, _ body: (borrowing Handle) throws(Status) -> R) throws(Status) -> R {
    let h = Handle(raw: raw)  // still owned by the DeviceResources
    let result: Result<R, Status>
    do throws(Status) { result = .success(try body(h)) } catch { result = .failure(error) }
    _ = h.release()
    return try result.get()
  }
}

/// An interrupt waited for on a port of its own: each packet is one
/// firing, and a level interrupt stays masked from then until `ack`.
public struct InterruptPort: ~Copyable {
  let interrupt: Handle
  let port: Handle

  public init(_ interrupt: consuming Handle) throws(Status) {
    let port = try Port.create(bindToInterrupt: true)
    try Interrupt.bind(interrupt, port: port, key: 1)
    self.interrupt = interrupt
    self.port = port
  }

  /// Waits until it fires or `deadline` (timedOut); when it fired.
  public func wait(deadline: Int64 = infiniteDeadline) throws(Status) -> Int64 {
    Int64(bitPattern: try Port.wait(port, deadline: deadline).payload.0)
  }

  /// Re-arms it once the device has been served.
  public func ack() throws(Status) { try Interrupt.ack(interrupt) }
}

/// A device's interrupt served on a thread of its own. Each wait ends when
/// it fires, or with INTx, where one can be lost, after 50 ms (a poll);
/// `next`, when it gives a time, ends one sooner. `serve` is told whether
/// it fired, and acks it with `ack` where the device needs (before or
/// after reading the cause). The counts are a status's `interrupts` and
/// `polls`.
public final class InterruptThread: @unchecked Sendable {
  let lock = Lock()
  var fired = 0, polled = 0

  /// How many waits ended with the interrupt, and how many timed out.
  public var counts: (interrupts: Int, polls: Int) { lock.withLock { (fired, polled) } }

  public init(_ irq: borrowing Handle, msix: Bool, next: @escaping @Sendable () -> Int64? = { nil },
              serve: @escaping @Sendable (_ fired: Bool, _ ack: () -> Void) -> Void) throws(Status)
  {
    let port = try Port.create(bindToInterrupt: true)
    try Interrupt.bind(irq, port: port, key: 1)
    let portRaw = port.release(), irqRaw = try irq.duplicate().release()
    _ = try Thread.spawn { [self] in
      let port = Handle(raw: portRaw), irq = Handle(raw: irqRaw)
      while true {
        var deadline = msix ? infiniteDeadline : Clock.monotonic() + 50_000_000
        if let due = next() { deadline = min(deadline, due) }
        let interrupted = (try? Port.wait(port, deadline: deadline)) != nil
        lock.withLock { if interrupted { fired += 1 } else { polled += 1 } }
        serve(interrupted) { try? Interrupt.ack(irq) }
      }
    }.release()
  }
}

/// A PCI function's capability list in its configuration space: each
/// capability's offset, in order (at most 48, against a looped list).
public func pciCapabilities(_ config: borrowing Registers) -> [Int] {
  var list: [Int] = []
  guard config.load16(0x06) & 0x10 != 0 else { return list }
  var next = Int(config.load8(0x34) & 0xFC)
  while next >= 0x40, list.count < 48 {
    list.append(next)
    next = Int(config.load8(next + 1) & 0xFC)
  }
  return list
}

/// A PCI function's capability `id`: its offset, or nil.
public func pciCapability(_ config: borrowing Registers, _ id: UInt8) -> Int? {
  pciCapabilities(config).first { config.load8($0) == id }
}

/// A PCI function's interrupt for a driver that isn't virtio's: MSI-X
/// vector 0 where devmgr granted an allocation and the function has the
/// capability (its table where the capability says, MSI-X enabled and
/// INTx off), else its INTx, on.
public final class PCIInterrupt: @unchecked Sendable {
  public let handle: Handle
  public let msix: Bool

  public init(_ resources: borrowing DeviceResources, config: borrowing Registers) throws(Status) {
    if resources.hasMSI, let cap = pciCapability(config, 0x11) {
      let table = config.load32(cap + 4)
      if let h = try? resources.msixInterrupt(id: 0, bar: Int(table & 7), offset: Int(table & ~7)) {
        config.store16(cap + 2, (config.load16(cap + 2) | 0x8000) & ~UInt16(0x4000))
        config.store16(4, config.load16(4) | 0x400)
        handle = h
        msix = true
        return
      }
    }
    handle = try resources.interrupt()
    config.store16(4, config.load16(4) & ~UInt16(0x400))
    msix = false
  }
}
