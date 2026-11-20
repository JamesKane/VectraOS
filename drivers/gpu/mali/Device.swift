// SPDX-License-Identifier: BSD-3-Clause

// bin/mali's hardware binding: the GPU's registers (BAR 1) as the control
// sequences' register file and the doorbells, the shared interface section
// as `SharedMemory`, the MCU's address space (AS 0: GPU page tables over
// write-combining pinned memory, the firmware's sections mapped at their
// addresses) and the bring-up that runs Sky1's order (D173 section 2) to a
// firmware that answers a ping.
//
// Everything the GPU or the MCU reads is write-combining pinned memory
// (D173 section 3): the CPU does no cache maintenance, only a barrier
// before a register write that tells the GPU to look.
//
// Interrupts: devmgr grants a host the first interrupt of its device only
// (the JOB line, positional 0, panthor 11.4), and its handle's info word
// names the trigger mode alone, so the MMU and GPU lines can't be told
// from it. Every wait here polls the raw status of the block it waits on,
// with all three masks at 0 (panthor 03 section 2.1.1 allows it). The
// scheduler (part 5, 6) needs the JOB and MMU lines served; that is a
// devmgr and DeviceResources change, not this file's.

import CroiMMIO
import DriverHost
import Sys

/// A step that failed, and why.
struct StepFailed: Error {
  let step: String
  let text: String
}

/// The GPU's registers, BAR 1, as the control sequences' register file and
/// the doorbells' pages.
final class GPUWindow: GPURegisterFile, CSFDoorbell {
  let regs: Registers

  init(_ regs: consuming Registers) { self.regs = regs }

  func load32(_ offset: Int) -> UInt32 { regs.load32(offset) }
  func store32(_ offset: Int, _ value: UInt32) { regs.store32(offset, value) }
  func barrier() { croi_dma_barrier() }

  /// Doorbell `id`: every store to the shared section visible first.
  func ring(_ id: Int) {
    croi_dma_barrier()
    regs.store32(GPUControlRegister.doorbells + id * GPUControlRegister.doorbellStride, 1)
  }
}

struct DeviceClock: GPUClock {
  func now() -> Int64 { Clock.monotonic() }
  func pause(nanoseconds: Int64) {
    // A short wait spins: a sleep is at least a timer's tick.
    if nanoseconds >= 200_000 { sleep(until: Clock.monotonic() + nanoseconds) }
  }
}

/// Memory the GPU reads, pinned, write-combining and zeroed: its CPU address
/// and the address the GPU uses.
struct Block {
  let address: UInt
  let bus: UInt64
  let size: Int

  init(_ memory: PinnedMemory, bytes: Int) throws(Status) {
    let (pointer, bus) = try unsafe memory.allocate(bytes: bytes)
    address = unsafe UInt(bitPattern: pointer)
    self.bus = bus
    size = (bytes + 4095) & ~4095
  }

  /// `count` bytes of `bytes` from `from`, at `offset` in the block.
  func write(_ bytes: [UInt8], from: Int, count: Int, at offset: Int) {
    precondition(from >= 0 && count >= 0 && from + count <= bytes.count && offset >= 0 && offset + count <= size)
    if count == 0 { return }
    bytes.withUnsafeBytes { source in
      unsafe UnsafeMutableRawPointer(bitPattern: address + UInt(offset))!
        .copyMemory(from: source.baseAddress! + from, byteCount: count)
    }
  }

  func zero(from offset: Int, to end: Int) {
    precondition(offset >= 0 && offset <= end && end <= size)
    if offset == end { return }
    unsafe UnsafeMutableRawPointer(bitPattern: address + UInt(offset))!
      .initializeMemory(as: UInt8.self, repeating: 0, count: end - offset)
  }
}

/// The firmware's shared interface section, as the host reads and writes it:
/// each access one volatile 32-bit load or store (the memory is write-
/// combining, never cached on either side), the barrier where the protocol
/// orders them. One thread uses it until the scheduler's, so no locks.
final class SharedSection: SharedMemory {
  let block: Block
  let length: Int

  init(_ block: Block, length: Int) {
    self.block = block
    self.length = length
  }

  var size: Int { length }

  private func at(_ offset: Int) -> UInt64 {
    precondition(offset >= 0 && offset & 3 == 0 && offset + 4 <= length)
    return UInt64(block.address) + UInt64(offset)
  }

  func load32(_ offset: Int) -> UInt32 { croi_mmio_read32(at(offset)) }
  func store32(_ offset: Int, _ value: UInt32) { croi_mmio_write32(at(offset), value) }
  func writeBarrier() { croi_dma_barrier() }
}

/// Table pages for the GPU's page tables: one pinned region, handed out in
/// order, zeroed to begin with. Part 5's VMs take theirs from the same pool
/// kind.
struct TablePool: PageTableMemory {
  let block: Block
  let pages: Int
  private(set) var used = 0

  init(_ block: Block) {
    self.block = block
    pages = block.size / 4096
  }

  mutating func allocateTable() -> UInt64? {
    guard used < pages else { return nil }
    used += 1
    return block.bus + UInt64((used - 1) * 4096)
  }

  func tableAddress(_ phys: UInt64) -> UInt { block.address + UInt(phys - block.bus) }
}

/// The MCU's page tables, of the depth its VA bits need.
enum MCUTables {
  case four(FormattedPageTableBuilder<TablePool, GPUPageTable>)
  case three(FormattedPageTableBuilder<TablePool, GPUPageTable39>)

  init(vaBits: Int, pool: TablePool) throws(StepFailed) {
    do throws(MapError) {
      switch GPUAddressSpace.levels(vaBits: vaBits) {
      case 4: self = .four(try FormattedPageTableBuilder(memory: pool))
      case 3: self = .three(try FormattedPageTableBuilder(memory: pool))
      default: throw MapError.outOfMemory
      }
    } catch {
      throw StepFailed(step: "MCU VM", text: "no page tables for \(vaBits) VA bits (\(GPUAddressSpace.levels(vaBits: vaBits)) levels)")
    }
  }

  var root: UInt64 {
    switch self {
    case .four(let b): return b.rootLow
    case .three(let b): return b.rootLow
    }
  }

  var pagesUsed: Int {
    switch self {
    case .four(let b): return b.memory.used
    case .three(let b): return b.memory.used
    }
  }

  mutating func map(virt: UInt64, phys: UInt64, size: UInt64, _ a: MapAttributes) throws(MapError) {
    switch self {
    case .four(var b):
      try b.map(virt: virt, phys: phys, size: size, a)
      self = .four(b)
    case .three(var b):
      try b.map(virt: virt, phys: phys, size: size, a)
      self = .three(b)
    }
  }
}

/// The MCU's VM: page tables, and the firmware's sections in pinned
/// memory mapped at their addresses. The sections' initial bytes stay in
/// `file`, to load again after a GPU reset (05 section 5.7.3).
final class MCUVM {
  struct Loaded {
    let section: FirmwareSection
    let block: Block
  }

  var tables: MCUTables
  var loaded: [Loaded] = []
  /// The MCU's window for the driver's own objects, the shared section's
  /// range taken.
  var window = VARegion.mcuWindow()
  let image: FirmwareImage
  let file: [UInt8]
  let memory: PinnedMemory
  let vaBits: Int

  /// Page tables of `vaBits`, and every section mapped (write-combining,
  /// at the permissions its flags give) with its bytes copied.
  init(memory: PinnedMemory, vaBits: Int, image: FirmwareImage, file: [UInt8]) throws(StepFailed) {
    self.memory = memory
    self.vaBits = vaBits
    self.image = image
    self.file = file
    let pool: Block
    do throws(Status) { pool = try Block(memory, bytes: 128 * 4096) } catch {
      throw StepFailed(step: "MCU VM", text: "no memory for the page tables: \(error.rawValue)")
    }
    tables = try MCUTables(vaBits: vaBits, pool: TablePool(pool))
    for section in image.sections {
      let block: Block
      do throws(Status) { block = try Block(memory, bytes: section.size) } catch {
        throw StepFailed(step: "firmware load", text: "no memory for section \(sectionName(section)) (\(section.size) bytes): \(error.rawValue)")
      }
      do throws(MapError) {
        try tables.map(virt: UInt64(section.vaStart), phys: block.bus, size: UInt64(block.size),
                       MapAttributes(writable: section.writable, executable: section.executable, cache: .writeCombining))
      } catch {
        throw StepFailed(step: "firmware load", text: "mapping section \(sectionName(section)) at 0x"
          + hexDigits(UInt64(section.vaStart)) + " overlaps another or the tables are full")
      }
      _ = window.reserve(at: UInt64(section.vaStart), size: UInt64(section.size))
      loaded.append(Loaded(section: section, block: block))
    }
    copyContents()
  }

  /// Each section's initial bytes copied, and the rest zeroed where its
  /// flags say so (05 section 5.3.4), then made visible to the MCU.
  func copyContents() {
    for l in loaded {
      let s = l.section
      l.block.write(file, from: s.dataStart, count: s.dataSize, at: 0)
      if s.zero { l.block.zero(from: s.dataSize, to: l.block.size) }
    }
    croi_dma_barrier()
  }

  var bytesMapped: Int { loaded.reduce(0) { $0 + $1.block.size } }

  /// The shared section's block, as the host reads it.
  var shared: SharedSection {
    for l in loaded where l.section.vaStart == FirmwareImage.sharedAddress {
      return SharedSection(l.block, length: l.section.size)
    }
    preconditionFailure("parse leaves one")
  }
}

func sectionName(_ s: FirmwareSection) -> String {
  s.name.isEmpty ? "at 0x" + hexDigits(UInt64(s.vaStart)) : String(decoding: s.name, as: UTF8.self)
}

/// A firmware that booted: what the scheduler (part 5, 6) is built over.
struct BootedFirmware {
  let window: GPUWindow
  let control: GPUControl<GPUWindow, DeviceClock>
  let vm: MCUVM
  let host: CSFHost<SharedSection>
  let probe: Probe
  let milliseconds: Int64

  // TODO(part 5, 6): a `FirmwareLink` over `host`, `window` (doorbells) and
  // the VMs' tables, and the JOB and MMU interrupts served, to construct
  // `GroupScheduler(link:config:)`. The link needs the group VMs, their rings
  // and sync objects, which `csf`'s protocol (Service.swift) creates.
}

/// Sky1's order after devmgr's power-up and the RCSU step (D173 section 2),
/// then the firmware: each step appends its status line and any failure
/// throws its name. `start` is the host's start, for the boot budget.
func bringUp(window: GPUWindow, probe: Probe, rcsuHarvest: UInt32, memory: PinnedMemory, noncoherent: Bool,
             file: [UInt8], image: FirmwareImage, start: Int64, status: inout [String]) throws(StepFailed)
  -> BootedFirmware
{
  let control = GPUControl(regs: window, clock: DeviceClock())
  func fail(_ f: ControlFailure) -> StepFailed {
    StepFailed(step: f.step, text: f.why + "; " + control.diagnostics())
  }

  // The harvest mask applies to SHADER_PRESENT everywhere after (11.6).
  var probe = probe
  let available = UInt64(Sky1GPU.availableShaders(harvest: rcsuHarvest))
  let full = probe.shaderPresent
  probe.shaderPresent = full & available
  status.append("harvest: RCSU \(hex(rcsuHarvest)) leaves shader cores \(hex64(probe.shaderPresent)) of \(hex64(full)),"
    + " \(probe.shaderCores) cores")
  if probe.shaderPresent == 0 { throw StepFailed(step: "harvest", text: "no shader core left") }

  // Soft reset, with every interrupt masked afterwards.
  let resetStart = Clock.monotonic()
  do throws(ControlFailure) { try control.softReset() } catch { throw fail(error) }
  status.append("soft reset: RESET_COMPLETED after \((Clock.monotonic() - resetStart) / 1000) us, interrupts masked (polled)")

  // Coherency, before the L2 powers.
  do throws(ControlFailure) {
    let c = try control.setCoherency()
    status.append("coherency: COHERENCY_FEATURES \(hex(c.features)), COHERENCY_PROTOCOL \(hex(c.protocolValue)) (ACE-Lite"
      + (c.protocolValue & Sky1GPU.shareableCacheBit != 0 ? ", shareable cache" : "")
      + (c.features & 1 == 0 ? "; ACE-Lite not advertised" : "") + ")")
  } catch { throw fail(error) }

  // The system cache's allocation (11.8.2), then the L2.
  control.programSystemCache()
  status.append("system cache: SYSC_PBHA_OVERRIDE3 \(hex(Sky1GPU.pbhaOverride3)), SYSC_ALLOC0-7 written")
  let l2Start = Clock.monotonic()
  do throws(ControlFailure) { try control.powerL2(present: probe.l2Present) } catch { throw fail(error) }
  status.append("L2 powered: slice 0 of \(hex64(probe.l2Present)) ready after \((Clock.monotonic() - l2Start) / 1000) us")

  // The MCU's VM and the firmware's sections.
  let vaBits = Int(probe.mmuFeatures & 0xFF)
  let vm = try MCUVM(memory: memory, vaBits: vaBits, image: image, file: file)
  status.append("MCU VM: \(vm.vaBits) VA bits in \(GPUAddressSpace.levels(vaBits: vm.vaBits)) levels, \(vm.tables.pagesUsed) table pages")
  status.append("firmware loaded: \(vm.loaded.count) sections, \(vm.bytesMapped / 1024) KiB mapped write-combining"
    + (image.protectedSkipped != 0 ? ", \(image.protectedSkipped) protected skipped" : ""))

  // AS 0.
  let coherent = !noncoherent
  let memAttr = GPUAddressSpace.memAttr(coherent: coherent)
  let transCfg = GPUAddressSpace.transCfg(vaBits: vaBits, coherent: coherent)
  do throws(ControlFailure) {
    try control.programAddressSpace(slot: 0, root: vm.tables.root, memAttr: memAttr, transCfg: transCfg)
  } catch { throw fail(error) }
  status.append("address space 0: TRANSTAB \(hex64(vm.tables.root)), MEMATTR \(hex64(memAttr)), TRANSCFG \(hex64(transCfg))")

  // The MCU.
  let bootStart = Clock.monotonic()
  do throws(ControlFailure) { try control.startMCU() } catch { throw fail(error) }
  status.append("MCU booted: global interface interrupt after \((Clock.monotonic() - bootStart) / 1_000_000) ms")

  // The interface.
  let section = vm.shared
  let layout: CSFLayout
  do throws(CSFError) { layout = try CSFLayout.discover(section) } catch {
    throw StepFailed(step: "interface", text: "\(error); " + control.diagnostics())
  }
  status += layout.statusLines
  let host = CSFHost(memory: section, layout: layout)

  // The global interface's first configuration (05 section 5.6.3).
  let frequency = control.measureTimestampFrequency()
  if let hz = frequency {
    status.append("GPU_TIMESTAMP counts at \(hz) Hz")
  } else {
    status.append("GPU_TIMESTAMP does not count: the firmware's timers are at their maximum")
  }
  let config = GlobalConfig.boot(shaderPresent: probe.shaderPresent, timestampFrequency: frequency, coreFrequency: nil)
  let initWait = host.initGlobal(config, window)
  let configured = control.wait(timeout: ControlTimeout.ping, interval: 100_000) { host.isDone(initWait) }
  status.append("global interface configured: ALLOC_EN \(hex64(config.allocEn)), PWROFF_TIMER \(hex(config.pwroffTimer)),"
    + " IDLE_TIMER \(hex(config.idleTimer)), PROGRESS_TIMER \(hex(config.progressTimer))"
    + (configured ? ", acknowledged" : ", NOT acknowledged in 100 ms"))

  // A ping, which the firmware must answer.
  let pingWait = host.ping(window)
  let answered = control.wait(timeout: ControlTimeout.ping, interval: 100_000) { host.isDone(pingWait) }
  guard answered else {
    throw StepFailed(step: "ping", text: "GLB_ACK \(hex(host.glbAck)) for GLB_REQ \(hex(host.glbReq)) after 100 ms; "
      + control.diagnostics())
  }
  let elapsed = (Clock.monotonic() - start) / 1_000_000
  window.store32(GPUControlRegister.jobIrqClear, 0xFFFF_FFFF)
  status.append("ping answered, GLB_ACK \(hex(host.glbAck))")
  // MMU_IRQ_RAWSTAT [31:16] is each address space's command complete (panthor 02
  // §2.7.1), which AS 0's UPDATE raises; [15:0] is a fault, which would be news.
  let mmu = window.load32(GPUControlRegister.mmuIrqRawStat)
  window.store32(GPUControlRegister.mmuIrqClear, mmu & 0xFFFF_0000)
  if mmu & 0xFFFF != 0 { status.append("WARNING: MMU_IRQ_RAWSTAT \(hex(mmu)), a fault; " + control.diagnostics()) }
  return BootedFirmware(window: window, control: control, vm: vm, host: host, probe: probe, milliseconds: elapsed)
}
