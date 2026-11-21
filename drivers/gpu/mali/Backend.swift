// SPDX-License-Identifier: BSD-3-Clause

// bin/mali's backend for the `csf` capset's service (Service.swift, D173
// section 6 and 7): `MaliDevice` is the `CSFBackend` (and so the scheduler's
// `FirmwareLink`) over the real hardware. The CSF interface itself is the
// link's (lib/Link.swift, host-tested against the model firmware); what is
// here is what needs the GPU's registers and the host's memory:
//
//  - client buffers: VMOs made write-combining and pinned through the BTI,
//    which the client maps and the GPU's tables point at;
//  - VMs: a page-table tree each (lib/pagetables over pinned table pages),
//    bound to an address-space slot when the scheduler asks (AS_TRANSTAB,
//    AS_MEMATTR, AS_TRANSCFG, UPDATE), changed under LOCK, a cache flush and
//    UNLOCK while the VM holds a slot (panthor 04 section 4.3 and 4.4);
//  - a group's memory: its suspend buffers and its queues' control pages in
//    the MCU's VM (in the 64 MiB window the firmware's interface section
//    opens), its rings and sync objects in its own VM's kernel region;
//  - the JOB and MMU interrupts' causes: a JOB interrupt's bits go to the
//    link, an MMU fault is decoded, its slot disabled and cleared and told to
//    the scheduler as the event that ends only that group (04 section 4.9);
//  - a full reset: soft reset, L2, the firmware reloaded and rebooted.
//
// Everything runs under the server's lock (ServiceIPC.swift) except the halt
// before the power goes, which cannot wait for it (`haltBeforePowerCut`).

import CroiMMIO
import DriverHost
import Sys

/// A client's buffer: a VMO made write-combining and pinned, a page to an
/// address.
final class ClientBuffer {
  let vmo: Handle
  let pmt: UInt32
  let pages: [UInt64]
  let size: Int

  init(vmo: consuming Handle, pmt: UInt32, pages: [UInt64], size: Int) {
    self.vmo = vmo
    self.pmt = pmt
    self.pages = pages
    self.size = size
  }

  deinit { try? DMA.unpin(pmt: pmt) }
}

/// A user VM: its tables, from pages of its own.
final class UserVM {
  let store: TableStore
  var tables: GPUTables

  init(store: TableStore, tables: GPUTables) {
    self.store = store
    self.tables = tables
  }
}

/// One group's memory: what the link reaches, and what to give back.
final class GroupMem {
  var vm = -1
  var queues: [LinkQueueMemory<SharedSection>] = []
  var blocks: [Block] = []
  var userMaps: [(va: UInt64, size: UInt64)] = []
  var mcuMaps: [(va: UInt64, size: UInt64)] = []
  var suspendVA: UInt64 = 0
  var protectedVA: UInt64 = 0
}

/// The groups' memory, by the scheduler's group id: the link's `LinkMemory`.
final class GroupTable: LinkMemory {
  typealias Memory = SharedSection
  var groups: [GroupMem?] = []

  func queue(group: Int, queue: Int) -> LinkQueueMemory<SharedSection>? {
    guard group >= 0, group < groups.count, let g = groups[group], queue >= 0, queue < g.queues.count else { return nil }
    return g.queues[queue]
  }

  func suspendBuffers(group: Int) -> (normal: UInt64, protected: UInt64) {
    guard group >= 0, group < groups.count, let g = groups[group] else { return (0, 0) }
    return (g.suspendVA, g.protectedVA)
  }
}

enum MapTarget {
  case mcu
  case user(Int)
}

final class MaliCore: @unchecked Sendable {
  let window: GPUWindow
  let control: GPUControl<GPUWindow, DeviceClock>
  let probe: Probe
  let memory: PinnedMemory
  let mcu: MCUVM
  let section: SharedSection
  let config: GlobalConfig
  let table: GroupTable
  var link: CSFLink<SharedSection, GPUWindow, GroupTable, DeviceClock>
  let coherent: Bool
  let info: CSFDeviceInfo

  var vms: [UserVM?] = []
  var buffers: [ClientBuffer?] = []
  /// What each address-space slot holds: a VM's id, -1 for nothing, -2 for the MCU.
  var slotVM = [Int](repeating: -1, count: 32)
  /// MMU_IRQ_MASK as written: a fault bit for each slot that holds a user VM.
  var mmuMask: UInt32 = 0
  var jobMask: UInt32 = 0
  var pendingEvents: [LinkEvent] = []
  /// GPU_IRQ_MASK as written: the GPU-control events, once the line is served (else the pump handles the faults).
  var gpuMask: UInt32 = 0
  /// Set when the MCU has been halted for the power: nothing more is asked of it.
  var stopped = false

  // What status says.
  var jobInterrupts = 0
  var mmuFaults = 0
  var resets = 0
  var gpuFaults = 0
  var gpuInterrupts = 0
  /// The driver's own lines, each with its time (ms since the host started).
  var journal: EventLog
  var served = ""
  var interruptThreads: [(String, InterruptThread)] = []

  init(booted b: BootedFirmware, memory: PinnedMemory, noncoherent: Bool) {
    journal = EventLog(origin: b.start, capacity: 24)
    window = b.window
    control = b.control
    probe = b.probe
    self.memory = memory
    mcu = b.vm
    section = b.vm.shared
    config = b.config
    coherent = !noncoherent
    let layout = b.host.layout
    let first = layout.groups[0].streams[0].features
    info = CSFDeviceInfo(
      gpuID: b.probe.id.raw, csfID: b.probe.csfID, interfaceVersion: layout.version.raw, features: b.probe.features,
      shaderPresent: b.probe.shaderPresent, tilerPresent: b.probe.tilerPresent, l2Present: b.probe.l2Present,
      asPresent: b.probe.asPresent, vaBits: Int(b.probe.mmuFeatures & 0xFF), groupSlots: layout.groupCount,
      queuesPerGroup: layout.streamCount, workRegisters: layout.workRegisters, scoreboards: first.scoreboards,
      threadMaxThreads: b.probe.threadMaxThreads, threadMaxWorkgroupSize: b.probe.threadMaxWorkgroupSize,
      threadMaxBarrierSize: b.probe.threadMaxBarrierSize, threadFeatures: b.probe.threadFeatures,
      l2LineSize: 1 << Int(min(b.probe.l2Features & 0xFF, 12)))
    let groups = GroupTable()
    table = groups
    link = CSFLink(host: b.host, door: b.window, memory: groups, clock: DeviceClock(),
                   policy: LinkPolicy(shaderPresent: b.probe.shaderPresent, tilerPresent: b.probe.tilerPresent),
                   origin: b.start)
    slotVM[0] = -2
    jobMask = 1 << UInt32(CSF.Section.globalInterruptBit) | (layout.groupCount >= 32 ? UInt32.max : (1 << UInt32(layout.groupCount)) - 1)
  }

  func note(_ line: String) { journal.add(line, at: Clock.monotonic()) }

  /// A control step that failed: said in status, and the GPU is reset (04
  /// section 4.3.3 and 4.4.1: a command that times out schedules a reset).
  func fail(_ f: ControlFailure) {
    note("\(f.step): \(f.why)")
    let cause = "\(f.step): \(f.why)"
    if !pendingEvents.contains(where: { if case .resetRequested = $0 { return true } else { return false } }) {
      pendingEvents.append(.resetRequested(cause: cause))
    }
  }

  // MARK: Interrupts

  /// Unmasks the JOB interrupt's global and CSG bits, the MMU's fault bits of the slots in use, and the
  /// GPU block's events where its line is served (`gpuMask`; panthor 03 section 3.8.3: the stale ones
  /// cleared first).
  func enableInterrupts() {
    if gpuMask != 0 { window.store32(GPUControlRegister.irqClear, gpuMask) }
    window.store32(GPUControlRegister.irqMask, gpuMask)
    window.store32(GPUControlRegister.jobIrqMask, jobMask)
    window.store32(GPUControlRegister.mmuIrqMask, mmuMask)
  }

  func setFaultMask(slot: Int, _ on: Bool) {
    if on { mmuMask |= MMUMask.bit(slot: slot) } else { mmuMask &= ~MMUMask.bit(slot: slot) }
    window.store32(GPUControlRegister.mmuIrqMask, mmuMask)
  }

  /// When the watchdog next needs looking at, in `Clock.monotonic`'s time.
  var nextWatchdog: Int64 { link.nextWatchdog }

  func pollEvents() -> [LinkEvent] {
    if stopped { return [] }
    var out = pendingEvents
    pendingEvents = []
    let job = window.load32(GPUControlRegister.jobIrqRawStat)
    if job != 0 {
      window.store32(GPUControlRegister.jobIrqClear, job)
      if job & jobMask != 0 {
        jobInterrupts += 1
        out += link.events(jobStatus: job & jobMask)
      }
    }
    // The GPU block: faults are logged, no reset follows (03 section 3.8.5). With the line the
    // completions are cleared here too; without it only the faults are looked at.
    let served = control.serveGPUInterrupt(mask: gpuMask != 0 ? GPUInterrupt.enabled : GPUInterrupt.faults)
    if served.handled != 0 {
      gpuInterrupts += 1
      gpuFaults += served.faults.count
      for line in served.faults { note(line) }
    }
    let mmu = window.load32(GPUControlRegister.mmuIrqRawStat)
    if mmu != 0 {
      // [31:16] is each slot's command complete, which the commands poll for.
      if mmu & 0xFFFF_0000 != 0 { window.store32(GPUControlRegister.mmuIrqClear, mmu & 0xFFFF_0000) }
      for slot in 0..<16 where mmu >> UInt32(slot) & 1 == 1 { out.append(contentsOf: fault(slot: slot)) }
    }
    if let e = link.watchdog() { out.append(e) }
    return out
  }

  /// A page or bus fault in slot `slot` (04 section 4.9.1): decoded, marked,
  /// cleared, and the slot disabled so every access of its work faults; the
  /// scheduler gets the event that ends the group on it.
  func fault(slot: Int) -> [LinkEvent] {
    let f = control.fault(slot: slot)
    mmuFaults += 1
    note(f.text + (slotVM[slot] >= 0 ? ", VM \(slotVM[slot])" : ""))
    window.store32(GPUControlRegister.mmuIrqClear, MMUMask.bit(slot: slot))
    guard slot >= 1, slot < 16, mmuMask & MMUMask.bit(slot: slot) != 0 else { return [] }
    setFaultMask(slot: slot, false)
    do throws(ControlFailure) { try control.disableAddressSpace(slot: slot, locked: false) } catch { fail(error) }
    return [.mmuFault(addressSpace: slot)]
  }

  // MARK: Page tables

  func slot(of target: MapTarget) -> Int? {
    switch target {
    case .mcu: return 0
    case .user(let vm):
      for s in 1..<32 where slotVM[s] == vm { return s }
      return nil
    }
  }

  /// A change of a VM's tables over [start, end): under LOCK, a cache flush and
  /// UNLOCK where the VM holds a slot (04 section 4.4.1), plain otherwise.
  func update(_ target: MapTarget, start: UInt64, end: UInt64, _ body: (inout GPUTables) -> Bool) -> Bool {
    let held = slot(of: target)
    if let s = held {
      do throws(ControlFailure) { try control.lockAddressSpace(slot: s, start: start, end: end) } catch {
        fail(error)
        return false
      }
    }
    var ok = false
    switch target {
    case .mcu:
      ok = body(&mcu.tables)
    case .user(let vm):
      if vm >= 0, vm < vms.count, let u = vms[vm] { ok = body(&u.tables) }
    }
    window.barrier()
    if let s = held {
      do throws(ControlFailure) {
        try control.flushCaches()
        try control.unlockAddressSpace(slot: s)
      } catch {
        fail(error)
        return false
      }
    }
    return ok
  }

  func mapBlock(_ target: MapTarget, va: UInt64, block: Block, writable: Bool) -> Bool {
    let a = MapAttributes(writable: writable, executable: false, cache: .writeCombining)
    return update(target, start: va, end: va + UInt64(block.size)) { t in
      do throws(MapError) {
        try t.map(virt: va, phys: block.bus, size: UInt64(block.size), a)
        return true
      } catch { return false }
    }
  }

  func unmapRange(_ target: MapTarget, va: UInt64, size: UInt64) {
    _ = update(target, start: va, end: va + size) { t in
      do throws(MapError) {
        try t.unmap(virt: va, size: size)
        return true
      } catch { return false }
    }
  }

  // MARK: VMs

  func createVM(_ vm: Int) -> Bool {
    let store: TableStore
    do throws(Status) { store = try TableStore(memory: memory, firstPages: 8, limit: 1024) } catch { return false }
    let tables: GPUTables
    do throws(StepFailed) { tables = try GPUTables(vaBits: info.vaBits, store: store) } catch {
      store.freeAll()
      return false
    }
    while vms.count <= vm { vms.append(nil) }
    vms[vm] = UserVM(store: store, tables: tables)
    return true
  }

  func destroyVM(_ vm: Int) {
    guard vm >= 0, vm < vms.count, let u = vms[vm] else { return }
    // The tables must not go while a slot may still point at them (04 section 4.10).
    if let s = slot(of: .user(vm)) { disable(slot: s) }
    vms[vm] = nil
    u.store.freeAll()
  }

  /// The full disable of a slot.
  func disable(slot s: Int) {
    setFaultMask(slot: s, false)
    do throws(ControlFailure) { try control.disableAddressSpace(slot: s, locked: false) } catch { fail(error) }
    slotVM[s] = -1
  }

  /// The scheduler's: bind slot `s` to a VM, or (-1) free it.
  func setAddressSpace(slot s: Int, vm: Int) {
    guard s >= 1, s < 32 else { return }
    if vm < 0 {
      disable(slot: s)
      return
    }
    guard vm < vms.count, let u = vms[vm] else { return }
    let recycled = slotVM[s] >= 0 && slotVM[s] != vm
    if recycled {
      setFaultMask(slot: s, false)
      do throws(ControlFailure) { try control.disableAddressSpace(slot: s, locked: false, recycle: true) } catch { fail(error) }
    }
    let memAttr = GPUAddressSpace.memAttr(coherent: coherent)
    let transCfg = GPUAddressSpace.transCfg(vaBits: info.vaBits, coherent: coherent)
    do throws(ControlFailure) {
      try control.programAddressSpace(slot: s, root: u.tables.root, memAttr: memAttr, transCfg: transCfg)
    } catch {
      fail(error)
      return
    }
    slotVM[s] = vm
    setFaultMask(slot: s, true)
  }

  // MARK: Buffers

  func allocateBuffer(size: UInt64) -> Int? {
    guard size > 0, size <= 1 << 32 else { return nil }
    let bytes = (Int(size) + 4095) & ~4095
    guard let vmo = try? VMO.create(size: bytes) else { return nil }
    // Before it is pinned or mapped: the kernel cleans its cached lines.
    guard (try? VMO.setCachePolicy(vmo, .writeCombining)) != nil, let pinned = try? memory.pin(vmo, size: bytes) else {
      return nil
    }
    let b = ClientBuffer(vmo: vmo, pmt: pinned.pmt, pages: pinned.addresses, size: bytes)
    for i in 0..<buffers.count where buffers[i] == nil {
      buffers[i] = b
      return i + 1
    }
    buffers.append(b)
    return buffers.count
  }

  func freeBuffer(_ key: Int) {
    guard key >= 1, key <= buffers.count else { return }
    buffers[key - 1] = nil
  }

  /// One word stored into a buffer, for the GPU: a heap chunk's header, a heap context's zeroing. The page is
  /// mapped for the store and unmapped (the buffer is write-combining, so a barrier makes it visible).
  func storeBuffer(_ key: Int, offset: UInt64, value: UInt64) {
    guard key >= 1, key <= buffers.count, let b = buffers[key - 1], offset & 7 == 0, offset < UInt64(b.size),
      let m = try? VMO.map(b.vmo, offset: Int(offset & ~4095), length: 4096)
    else { return }
    m.store(value, at: Int(offset & 4095))
    window.barrier()
  }

  /// A VMO over the buffer for its client to map.
  func bufferVMO(_ key: Int) -> Handle? {
    guard key >= 1, key <= buffers.count, let b = buffers[key - 1] else { return nil }
    return try? b.vmo.duplicate()
  }

  func map(vm: Int, buffer: Int, offset: UInt64, size: UInt64, va: UInt64, flags: CSFMapFlags) -> Bool {
    guard buffer >= 1, buffer <= buffers.count, let b = buffers[buffer - 1], offset & 4095 == 0, size & 4095 == 0, size > 0,
      offset + size <= UInt64(b.size), vm >= 0, vm < vms.count, vms[vm] != nil
    else { return false }
    let a = MapAttributes(writable: !flags.readOnly, executable: !flags.noExec, cache: .writeCombining)
    let first = Int(offset / 4096), count = Int(size / 4096)
    let ok = update(.user(vm), start: va, end: va + size) { t in
      do throws(MapError) {
        // What was bound there goes (a bind replaces).
        try t.unmap(virt: va, size: size)
        // Runs of contiguous pages are one mapping, so the tables can use blocks.
        var i = 0
        while i < count {
          var j = i + 1
          while j < count && b.pages[first + j] == b.pages[first + j - 1] + 4096 { j += 1 }
          try t.map(virt: va + UInt64(i) * 4096, phys: b.pages[first + i], size: UInt64(j - i) * 4096, a)
          i = j
        }
        return true
      } catch {
        // The tables ran out: what was mapped goes again.
        try? t.unmap(virt: va, size: size)
        return false
      }
    }
    return ok
  }

  func unmap(vm: Int, va: UInt64, size: UInt64) {
    guard vm >= 0, vm < vms.count, vms[vm] != nil, size > 0 else { return }
    unmapRange(.user(vm), va: va, size: size)
  }

  // MARK: Groups

  func block(_ g: GroupMem, bytes: Int) -> Block? {
    guard let b = try? Block(memory, bytes: bytes) else { return nil }
    g.blocks.append(b)
    return b
  }

  func attachGroup(group: Int, vm: Int, queues: [CSFQueueMemory]) -> Bool {
    guard !queues.isEmpty, vm >= 0, vm < vms.count, vms[vm] != nil, group >= 0 else { return false }
    let g = GroupMem()
    g.vm = vm
    func abort() -> Bool {
      teardown(g)
      return false
    }
    func mcuMap(_ b: Block) -> UInt64? {
      guard let va = mcu.window.allocate(size: UInt64(b.size)) else { return nil }
      guard mapBlock(.mcu, va: va, block: b, writable: true) else {
        _ = mcu.window.release(at: va, size: UInt64(b.size))
        return nil
      }
      g.mcuMaps.append((va, UInt64(b.size)))
      return va
    }
    // The sync objects, 16 bytes a queue, in one page the group's VM maps.
    guard let sync = block(g, bytes: 4096) else { return abort() }
    let syncPage = queues[0].syncVA & ~4095
    guard mapBlock(.user(vm), va: syncPage, block: sync, writable: true) else { return abort() }
    g.userMaps.append((syncPage, UInt64(sync.size)))
    let syncSection = SharedSection(sync, length: sync.size)
    for q in queues {
      guard let ring = block(g, bytes: q.ringSize), let control = block(g, bytes: 8192) else { return abort() }
      // The CS reads the ring through the group's VM; the firmware reaches the control area through its own.
      guard mapBlock(.user(vm), va: q.ringVA, block: ring, writable: false) else { return abort() }
      g.userMaps.append((q.ringVA, UInt64(ring.size)))
      guard let controlVA = mcuMap(control) else { return abort() }
      g.queues.append(LinkQueueMemory(
        ring: SharedSection(ring, length: ring.size), ringVA: q.ringVA, ringSize: q.ringSize,
        control: SharedSection(control, length: control.size), controlOffset: 0, controlVA: controlVA, sync: syncSection,
        syncOffset: Int(q.syncVA & 4095)))
    }
    // The suspend buffers, in the MCU's VM (07 section 7.2.1): both, as panthor does.
    let layout = link.host.layout.groups[0]
    if layout.suspendSize > 0 {
      guard let b = block(g, bytes: layout.suspendSize), let va = mcuMap(b) else { return abort() }
      g.suspendVA = va
    }
    if layout.protmSuspendSize > 0 {
      guard let b = block(g, bytes: layout.protmSuspendSize), let va = mcuMap(b) else { return abort() }
      g.protectedVA = va
    }
    while table.groups.count <= group { table.groups.append(nil) }
    table.groups[group] = g
    return true
  }

  func teardown(_ g: GroupMem) {
    if g.vm >= 0 { for m in g.userMaps { unmapRange(.user(g.vm), va: m.va, size: m.size) } }
    for m in g.mcuMaps {
      unmapRange(.mcu, va: m.va, size: m.size)
      _ = mcu.window.release(at: m.va, size: m.size)
    }
    for b in g.blocks { b.free(memory) }
    g.blocks = []
    g.queues = []
  }

  func detachGroup(group: Int) {
    guard group >= 0, group < table.groups.count, let g = table.groups[group] else { return }
    table.groups[group] = nil
    teardown(g)
  }

  // MARK: Reset

  /// A full GPU reset (07 section 7.11, 05 section 5.7.3): soft reset, the L2,
  /// the firmware's sections loaded again, the MCU started, the interface
  /// configured, and the slots all free. False if it did not come back.
  func reset(cause: String) -> Bool {
    resets += 1
    window.store32(GPUControlRegister.irqMask, 0)
    window.store32(GPUControlRegister.jobIrqMask, 0)
    window.store32(GPUControlRegister.mmuIrqMask, 0)
    note("GPU reset \(resets): cause \(cause)")
    do throws(ControlFailure) {
      try control.softReset()
      _ = try control.setCoherency()
      control.programSystemCache()
      try control.powerL2(present: probe.l2Present)
    } catch {
      note("reset: \(error.step): \(error.why)")
      return false
    }
    mcu.copyContents()
    for s in 0..<32 { slotVM[s] = -1 }
    slotVM[0] = -2
    mmuMask = 0
    pendingEvents = []
    let memAttr = GPUAddressSpace.memAttr(coherent: coherent)
    let transCfg = GPUAddressSpace.transCfg(vaBits: info.vaBits, coherent: coherent)
    do throws(ControlFailure) {
      try control.programAddressSpace(slot: 0, root: mcu.tables.root, memAttr: memAttr, transCfg: transCfg)
      try control.startMCU()
    } catch {
      note("reset: \(error.step): \(error.why); " + control.diagnostics())
      return false
    }
    let layout: CSFLayout
    do throws(CSFError) { layout = try CSFLayout.discover(section) } catch {
      note("reset: the interface: \(error)")
      return false
    }
    let host = CSFHost(memory: section, layout: layout)
    let initWait = host.initGlobal(config, window)
    let configured = control.wait(timeout: ControlTimeout.ping, interval: 100_000) { host.isDone(initWait) }
    let pingWait = host.ping(window)
    let answered = control.wait(timeout: ControlTimeout.ping, interval: 100_000) { host.isDone(pingWait) }
    guard configured, answered else {
      note("reset: the firmware does not answer: " + control.diagnostics())
      return false
    }
    window.store32(GPUControlRegister.jobIrqClear, 0xFFFF_FFFF)
    window.store32(GPUControlRegister.mmuIrqClear, 0xFFFF_FFFF)
    link.rebooted(host: host)
    enableInterrupts()
    note("GPU reset \(resets): the firmware answers")
    return true
  }

  // MARK: Before the power goes

  /// The supply is ending (D170): the MCU is halted while it still has power
  /// (06 section 6.4.5: by the interface's version), so the cut never lands on
  /// a running one, then stopped (MCU_CONTROL disable). It cannot wait for the
  /// server's lock, whose holder may be waiting on the very hardware that is
  /// going; `stopped` ends what the pump would ask of it. Returns the line to say.
  func haltBeforePowerCut(timeout: Int64) -> String {
    stopped = true
    window.store32(GPUControlRegister.irqMask, 0)
    window.store32(GPUControlRegister.jobIrqMask, 0)
    window.store32(GPUControlRegister.mmuIrqMask, 0)
    let start = Clock.monotonic()
    let halted = link.host.haltMCU(control, door: window, timeout: timeout)
    if halted { window.store32(GPUControlRegister.mcuControl, 0) }
    let ms = (Clock.monotonic() - start) / 1_000_000
    return halted ? "the MCU halted in \(ms) ms" : "the MCU did not halt in \(ms) ms (MCU_STATUS \(MCU.statusName(window.load32(GPUControlRegister.mcuStatus))))"
  }

  // MARK: Status

  func statusLines() -> [String] {
    var out = ["scheduler: " + served + ", JOB interrupts \(jobInterrupts), MMU faults \(mmuFaults), resets \(resets), GPU interrupts \(gpuInterrupts) (\(gpuFaults) faults)"]
    for (name, t) in interruptThreads {
      out.append("interrupt \(name): \(t.counts.interrupts) fired, \(t.counts.polls) polls")
    }
    out.append("address spaces: " + (0..<16).map { slotVM[$0] == -1 ? "-" : (slotVM[$0] == -2 ? "mcu" : "vm\(slotVM[$0])") }
      .joined(separator: " "))
    out.append("buffers \(buffers.filter { $0 != nil }.count), VMs \(vms.filter { $0 != nil }.count),"
      + " groups \(table.groups.filter { $0 != nil }.count)")
    for l in journal.lines { out.append("event: " + l) }
    for l in link.journal.lines { out.append("firmware: " + l) }
    return out
  }
}

/// The backend: the core, as a value the scheduler holds as its link.
struct MaliDevice: CSFBackend {
  let core: MaliCore

  var device: CSFDeviceInfo { core.info }
  var nanoseconds: UInt64 { UInt64(max(0, Clock.monotonic())) }
  var userAddressSpace: UInt64 { 0 }

  mutating func allocateBuffer(size: UInt64) -> Int? { core.allocateBuffer(size: size) }
  mutating func freeBuffer(_ buffer: Int) { core.freeBuffer(buffer) }
  mutating func storeBuffer(_ buffer: Int, offset: UInt64, value: UInt64) {
    core.storeBuffer(buffer, offset: offset, value: value)
  }
  mutating func createVM(_ vm: Int) -> Bool { core.createVM(vm) }
  mutating func destroyVM(_ vm: Int) { core.destroyVM(vm) }
  mutating func map(vm: Int, buffer: Int, offset: UInt64, size: UInt64, va: UInt64, flags: CSFMapFlags) -> Bool {
    core.map(vm: vm, buffer: buffer, offset: offset, size: size, va: va, flags: flags)
  }
  mutating func unmap(vm: Int, va: UInt64, size: UInt64) { core.unmap(vm: vm, va: va, size: size) }
  mutating func attachGroup(group: Int, vm: Int, queues: [CSFQueueMemory]) -> Bool {
    core.attachGroup(group: group, vm: vm, queues: queues)
  }
  mutating func detachGroup(group: Int) { core.detachGroup(group: group) }
  func counterValue(_ counter: UInt32) -> UInt64 { CSFCounters.value(counter) }
  mutating func raiseCounter(_ counter: UInt32, to value: UInt64) { CSFCounters.raise(counter, to: value) }
  mutating func closeCounter(_ counter: UInt32) { CSFCounters.close(counter) }

  var csgSlotCount: Int { core.link.csgSlotCount }
  var queuesPerGroup: Int { core.link.queuesPerGroup }
  mutating func setAddressSpace(slot: Int, vm: Int) { core.setAddressSpace(slot: slot, vm: vm) }
  mutating func program(csg: Int, group: LinkGroupProgram) -> Bool { core.link.program(csg: csg, group: group) }
  mutating func setPriorities(_ updates: [LinkPriorityUpdate]) -> Bool { core.link.setPriorities(updates) }
  mutating func suspend(csg: Int) -> Bool { core.link.suspend(csg: csg) }
  mutating func terminate(csg: Int) -> Bool { core.link.terminate(csg: csg) }
  mutating func statusUpdate() -> Bool { core.link.statusUpdate() }
  func queueStatus(csg: Int, queue: Int) -> LinkQueueStatus { core.link.queueStatus(csg: csg, queue: queue) }
  mutating func storeRing(group: Int, queue: Int, byteOffset: Int, word: UInt64) {
    core.link.storeRing(group: group, queue: queue, byteOffset: byteOffset, word: word)
  }
  mutating func publishInsert(group: Int, queue: Int, insert: UInt64) {
    core.link.publishInsert(group: group, queue: queue, insert: insert)
  }
  func readSync(group: Int, queue: Int) -> SyncRecord { core.link.readSync(group: group, queue: queue) }
  mutating func writeSync(group: Int, queue: Int, record: SyncRecord) {
    core.link.writeSync(group: group, queue: queue, record: record)
  }
  mutating func ringDoorbell(csg: Int) { core.link.ringDoorbell(csg: csg) }
  mutating func acknowledgeFault(csg: Int, queue: Int) { core.link.acknowledgeFault(csg: csg, queue: queue) }
  func tilerOOMReport(csg: Int, queue: Int) -> TilerOOMReport { core.link.tilerOOMReport(csg: csg, queue: queue) }
  mutating func replyTilerHeap(csg: Int, queue: Int, chunk: UInt64) {
    core.link.replyTilerHeap(csg: csg, queue: queue, chunk: chunk)
  }
  mutating func pollEvents() -> [LinkEvent] { core.pollEvents() }
  mutating func reset(cause: String) -> Bool { core.reset(cause: cause) }
}
