// SPDX-License-Identifier: BSD-3-Clause

// bin/k1-pcie (k1-pcie(3)): a SpacemiT K1 PCIe host, a DesignWare root
// complex, brought up as spacemit-k1 09 §9.4 orders it, its bus given
// to devmgr (D154). devmgr grants its registers (DBI, iATU, the config
// window and the K1's link registers, in its `reg`'s order) and its MSI
// interrupt, gives its node at /dev/dt, and starts it after its providers:
// the APMU, which holds its control register (its `spacemit,apmu` offset)
// and its clocks and resets; its root port's PHY; and its slot's supply.
// It holds its PHY in reset, turns the slot's power on, resets its
// controller, asserts PERST# for 100 ms, makes it a root complex, turns
// its PHY on, releases PERST#, sets up the root port (its bus numbers,
// its MSI block's target, an iATU window for the bus's memory) and starts
// link training, waiting up to 900 ms for the link and 100 ms after it.
// Then it finds the function in the slot through a second iATU window,
// fixed on bus 1's device 0, and places its BARs in the window. Its tree:
//   status   the core's version, the link, what it found and where it put
//            each BAR, or what failed
//   pci      the bus for devmgr (DriverHost's HostedBus); empty with no
//            link
// devmgr reads `pci` once and binds the functions it lists.

import DriverHost
import IPC
import Node
import Sys

/// Its DMA memory: the page its MSI block's target is, kept for its life.
nonisolated(unsafe) var memory: PinnedMemory?

/// What the bring-up found, for the tree: `status`'s lines and `pci`,
/// set once it ends.
final class Found: @unchecked Sendable {
  let lock = Lock()
  var status = ["bringing the link up"]
  var pci = ""
  var done = false

  func finish(_ lines: [String], _ bus: HostedBus) {
    for l in lines { print("k1-pcie: \(l)") }
    lock.withLock {
      status = lines
      pci = bus.functions.isEmpty ? "" : bus.text
      done = true
    }
  }

  /// `pci`, once the bring-up has ended (up to 5 s).
  var bus: String {
    let deadline = Clock.monotonic() + 5_000_000_000
    while Clock.monotonic() < deadline {
      if let text = lock.withLock({ done ? pci : nil }) { return text }
      sleep(until: Clock.monotonic() + 10_000_000)
    }
    return ""
  }
}

final class Bringup: @unchecked Sendable {
  let dbi: Registers
  let atu: Registers
  let config: Registers
  let link: Registers
  let ns: Namespace?
  let links: [ProvidedLink]
  let apmu: String
  let control: UInt32

  init(dbi: consuming Registers, atu: consuming Registers, config: consuming Registers, link: consuming Registers,
       ns: Namespace?, links: [ProvidedLink], apmu: String, control: UInt32) {
    self.dbi = dbi
    self.atu = atu
    self.config = config
    self.link = link
    self.ns = ns
    self.links = links
    self.apmu = apmu
    self.control = control
  }

  /// A command to the APMU's k1-syscon(3).
  func syscon(_ c: String) -> Bool { ns?.writeText("/dev/provider/\(apmu)/ctl", c + "\n") == true }
  func pcie(_ field: String, _ on: Bool) -> Bool { syscon("pcie 0x\(String(control, radix: 16)) \(field) \(on ? "on" : "off")") }

  func provider(_ kind: String, _ name: String = "") -> String? {
    links.first { $0.isKind(kind) && (name.isEmpty || $0.name.utf8.elementsEqual(name.utf8)) && !$0.provider.isEmpty }?.provider
  }

  static func pause(_ ms: Int64) { sleep(until: Clock.monotonic() + ms * 1_000_000) }

  /// The root port's capability `id`'s offset in DBI.
  func capability(_ id: UInt8) -> Int? {
    var at = Int(dbi.load8(0x34) & 0xFC), seen = 0
    while at >= 0x40, at < 0x100, seen < 48 {
      if dbi.load8(at) == id { return at }
      at = Int(dbi.load8(at + 1) & 0xFC)
      seen += 1
    }
    return nil
  }

  /// `5.20a`: the register holds `520*` in ASCII.
  var version: String {
    let v = dbi.load32(DBI.version)
    let b = [v >> 24, v >> 16, v >> 8].map { UInt8(truncatingIfNeeded: $0) }
    guard b.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return "unknown" }
    return String(decoding: [b[0], UInt8(ascii: "."), b[1], b[2], UInt8(ascii: "a")], as: UTF8.self)
  }

  enum Failure: Error { case step(String) }

  /// Up to the link: true if it came up.
  func start(msiTarget: UInt64) throws(Failure) -> Bool {
    guard pcie("hold-phy", true) else { throw .step("the APMU refused hold-phy") }
    if let s = provider("supply", "vpcie3v3"), ns?.writeText("/dev/provider/\(s)/ctl", "on\n") != true {
      throw .step("the slot's supply refused on")
    }
    guard pcie("soft-reset", true) else { throw .step("the APMU refused soft-reset") }
    Self.pause(2)
    _ = pcie("soft-reset", false)
    for l in links where l.isKind("clock") || l.isKind("reset") {
      guard let c = l.enabling, !l.provider.isEmpty, ns?.writeText("/dev/provider/\(l.provider)/ctl", c + "\n") == true
      else { throw .step("\(l.kind) \(l.cells.first ?? 0) not on") }
    }
    // PERST# for 100 ms once power is stable (PCIe CEM's T_PVPERL).
    guard pcie("perst", true) else { throw .step("the APMU refused perst") }
    Self.pause(100)
    _ = pcie("rc", true)
    _ = pcie("aux-power", true)
    if let p = provider("phy"), ns?.writeText("/dev/provider/\(p)/ctl", "on\n") != true {
      throw .step("its PHY didn't turn on")
    }
    _ = pcie("perst", false)

    // The root port, with its read-only registers writable.
    dbi.store32(DBI.miscControl1, dbi.load32(DBI.miscControl1) | DBI.readOnlyWritable)
    dbi.store32(DBI.portLinkControl, dbi.load32(DBI.portLinkControl) & ~DBI.fastLinkMode | DBI.dllLinkEnable)
    // Its MSI block: every vector enabled and masked until the kernel
    // unmasks it, and the address devices write.
    for c in 0..<8 {
      dbi.store32(DBI.msiMask + 12 * c, 0xFFFF_FFFF)
      dbi.store32(DBI.msiEnable + 12 * c, 0xFFFF_FFFF)
    }
    dbi.store32(DBI.msiAddressLow, UInt32(truncatingIfNeeded: msiTarget))
    dbi.store32(DBI.msiAddressHigh, UInt32(truncatingIfNeeded: msiTarget >> 32))
    dbi.store32(0x10, 0)
    dbi.store32(0x14, 0)
    dbi.store32(0x3C, dbi.load32(0x3C) & 0xFFFF_00FF | 0x100)
    dbi.store32(0x18, dbi.load32(0x18) & 0xFF00_0000 | 0x00FF_0100)
    dbi.store32(0x04, dbi.load32(0x04) & 0xFFFF_0000 | 0x0107)
    dbi.store16(0x0A, 0x0604)
    // No ASPM L1: some NVMe drives misbehave with it on the K1
    // (spacemit-k1 09 §9.2).
    if let e = capability(0x10) { dbi.store32(e + 0x0C, dbi.load32(e + 0x0C) & ~(UInt32(1) << 11)) }
    dbi.store32(DBI.linkWidthSpeedControl, dbi.load32(DBI.linkWidthSpeedControl) | DBI.speedChange)
    dbi.store32(DBI.miscControl1, dbi.load32(DBI.miscControl1) & ~DBI.readOnlyWritable)

    // Training.
    guard pcie("hold-phy", false), pcie("ltssm", true) else { throw .step("the APMU refused ltssm") }
    link.store32(Link.intrEnable, Link.msiInterrupt)
    link.store32(Link.interruptEnable, link.load32(Link.interruptEnable) | Link.pcieInterrupt)
    for _ in 0..<10 {
      if link.load32(Link.status) & Link.up == Link.up { break }
      Self.pause(90)
    }
    guard link.load32(Link.status) & Link.up == Link.up else { return false }
    Self.pause(100)
    return true
  }

  func ltssm() -> String {
    let s = dbi.load32(DBI.linkDebug0) & 0x3F
    let what = s <= 1 ? "no device" : s <= 3 ? "a device, not active" : "training"
    return "\(what) (LTSSM 0x\(String(s, radix: 16)))"
  }

  func program(_ writes: [(offset: Int, value: UInt32)]) {
    for w in writes { atu.store32(w.offset, w.value) }
  }
}

@main struct K1PcieHost {
  /// The function at 01:00.0 through `config`: its BARs sized with
  /// decoding off and placed in `window`, and the root port's bridge
  /// window over them; lines for `status`, and whether it can be bound.
  static func endpoint(_ config: borrowing Registers, _ dbi: borrowing Registers,
                       window: (minimum: UInt64, maximum: UInt64)) -> (lines: [String], ok: Bool) {
    let id = config.load32(0)
    guard id != 0xFFFF_FFFF, id != 0 else { return (["no function answers at 01:00.0"], false) }
    guard config.load8(0x0E) & 0x7F == 0 else {
      return (["01:00.0 is a bridge: a switch behind the root port isn't supported"], false)
    }
    config.store16(4, config.load16(4) & ~0x7)
    var bars: [SizedBAR] = []
    var i = 0
    while i < 6 {
      let at = 0x10 + 4 * i
      let original = config.load32(at)
      config.store32(at, 0xFFFF_FFFF)
      let mask = config.load32(at)
      var upper: UInt32 = 0xFFFF_FFFF
      let wide = original & 0x7 == 0x4 && i < 5
      if wide {
        let o = config.load32(at + 4)
        config.store32(at + 4, 0xFFFF_FFFF)
        upper = config.load32(at + 4)
        config.store32(at + 4, o)
      }
      config.store32(at, original)
      if let s = SizedBAR(index: i, original: original, mask: mask, upperMask: upper) { bars.append(s) }
      i += wide ? 2 : 1
    }
    var lines = ["function 01:00.0 \(hex4(UInt16(truncatingIfNeeded: id))):\(hex4(UInt16(truncatingIfNeeded: id >> 16))) "
      + "class \(String(config.load32(8) >> 8, radix: 16))"]
    guard let placed = Placement.place(bars, in: window) else { return (lines + ["its BARs don't fit the window"], false) }
    var low = UInt64.max, high: UInt64 = 0
    for p in placed {
      let at = 0x10 + 4 * p.index
      let bar = bars.first { $0.index == p.index }!
      config.store32(at, UInt32(truncatingIfNeeded: p.address) | config.load32(at) & 0xF)
      if bar.wide { config.store32(at + 4, UInt32(truncatingIfNeeded: p.address >> 32)) }
      low = min(low, p.address)
      high = max(high, p.address + bar.size - 1)
      lines.append("bar\(p.index) 0x\(String(p.address, radix: 16)) \(bar.size)")
    }
    // The root port forwards what was placed, in 1 MiB units, and no
    // prefetchable memory or I/O.
    dbi.store32(0x20, Placement.bridgeWindow(placed.isEmpty ? nil : (low & ~0xF_FFFF, high | 0xF_FFFF)))
    dbi.store32(0x24, 0x0000_FFF0)
    dbi.store32(0x1C, dbi.load32(0x1C) & 0xFFFF_0000 | 0x00F0)
    return (lines, true)
  }

  static func main() {
    let start = Startup.current
    var resources = DeviceResources(take: { start.take($0)?.release() })
    let ns = try? Namespace(start)
    let links = ProvidedLink.parse(ns?.readText("/dev/dt/links") ?? "")
    let found = Found()

    let node = HostNode(node: ns?.readText("/dev/dt/node") ?? "")
    let syscon = links.first { $0.isKind("syscon") && !$0.provider.isEmpty }
    let dbiInfo = try? resources.bar(0), windowInfo = try? resources.bar(2)
    let gsi = try? resources.interruptNumber()
    let dbiMap = try? resources.map(bar: 0, extent: DBI.size), atuMap = try? resources.map(bar: 1)
    let configMap = try? resources.map(bar: 2), linkMap = try? resources.map(bar: 3)
    let bti = resources.takeBTI()
    if let s = syscon, let control = s.cells.first, let windowInfo, let dbiInfo, let gsi, let memoryWindow = node.memory,
      let dbi = dbiMap, let atu = atuMap, let config = configMap, let link = linkMap, let bti
    {
      let b = Bringup(dbi: dbi, atu: atu, config: config, link: link, ns: ns, links: links, apmu: s.provider,
                      control: control)
      memory = PinnedMemory(bti: bti, coherent: true)
      // Training takes up to a second: the tree is served meanwhile, and
      // `pci` answers once it ends.
      let bringUp = { @Sendable in
        var bus = HostedBus()
        var status: [String] = []
        do throws(Bringup.Failure) {
          guard let target = unsafe (try? memory?.allocate(bytes: 4096))?.bus else { throw .step("no page for MSIs") }
          let up = try b.start(msiTarget: target)
          status.append("version \(b.version)")
          if up {
            let e = b.capability(0x10)
            status.append("link up, " + (e.map { linkText(b.dbi.load16($0 + 0x12)) } ?? "?"))
            let version = b.dbi.load32(DBI.version)
            // Region 0: config requests for bus 1's device 0, function 0;
            // region 1, the bus's memory.
            b.program(ATU.outbound(index: 0, .config0, cpu: windowInfo.base, size: 4096,
                                   target: ATU.target(bus: 1, device: 0, function: 0), version: version))
            b.program(ATU.outbound(index: 1, .memory, cpu: memoryWindow.cpu, size: memoryWindow.size,
                                   target: memoryWindow.pci, version: version))
            let window = (minimum: memoryWindow.pci, maximum: memoryWindow.pci + memoryWindow.size - 1)
            let endpoint = Self.endpoint(b.config, b.dbi, window: window)
            status += endpoint.lines
            if endpoint.ok {
              bus.segment = node.domain
              // The CPU reaches the bus's memory at the same addresses
              // (the K1's ranges translate none).
              bus.memory = [window]
              bus.dmaBits = 31
              bus.msi = HostedBus.MSIBlock(registers: dbiInfo.base + UInt64(DBI.msiAddressLow), target: target, gsi: gsi)
              bus.functions = [HostedBus.Function(bus: 1, device: 0, function: 0, page: windowInfo.base)]
            }
          } else {
            status.append("link down: " + b.ltssm())
          }
          status.append("msi target 0x\(String(target, radix: 16)), interrupt \(gsi)")
        } catch {
          switch error {
          case .step(let s): status.append("FAILED: " + s)
          }
        }
        found.finish(status, bus)
      }
      do throws(Status) {
        _ = try Thread.spawn(bringUp).release()
      } catch {
        found.finish(["FAILED: no thread to bring it up on"], HostedBus())
      }
    } else {
      found.finish(["FAILED: its registers, interrupt, ranges, APMU link or DMA weren't given"], HostedBus())
    }

    do throws(Status) {
      let dispatcher = try IPCDispatcher()
      let tree = NodeTree(dispatcher: dispatcher)
      tree.text("status", read: { found.lock.withLock { found.status.map { $0 + "\n" }.joined() } })
      tree.text("pci", read: { found.bus })
      guard let export = start.export() else { Process.exit(code: 2) }
      try tree.serve(export)
      try dispatcher.run()
    } catch {
      Process.exit(code: 1)
    }
    _ = consume resources
  }
}

func hex4(_ v: UInt16) -> String {
  let s = String(v, radix: 16)
  return String(repeating: "0", count: max(0, 4 - s.utf8.count)) + s
}
