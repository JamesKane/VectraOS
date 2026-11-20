// SPDX-License-Identifier: BSD-3-Clause

// Checks over a whole machine's description (D171): the Orange Pi 6 Plus's
// captured ACPI tables and the Orange Pi RV2's tree pass, and each check
// has a control, a description that must fail it. A check that passes the
// boards and fails nothing proves nothing, so a control is a board built
// to break exactly that check, and the same board mended passes.

import BoardCheck
import DevMgr
import DeviceTreeBus
import Dtc
import Foundation
import Testing

// MARK: Boards

let root = repositoryRoot(from: #filePath)!

/// `vx acpi`'s capture of the Orange Pi 6 Plus, out of the tree.
let sky1Directory = root + "/.cache/acpi/orangepi-6-plus"
let hasSky1 = fileBytes(sky1Directory + "/DSDT") != nil
let skyNote: Comment = "no capture of the Orange Pi 6 Plus's tables in .cache/acpi/orangepi-6-plus (vx acpi import); its checks are skipped"

let clang: String? = {
  var dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
  dirs.append("\(NSHomeDirectory())/.local/share/swiftly/toolchains/6.4.0/usr/bin")
  return dirs.map { "\($0)/clang" }.first { FileManager.default.isExecutableFile(atPath: $0) }
}()
let rv2Note: Comment = "no clang to preprocess the RV2's devicetree; its checks are skipped"

/// The RV2's tree from firmware/dts, through the preprocessor, as `vx dtc` makes it.
func rv2Tree() throws -> [UInt8] {
  let dts = root + "/firmware/dts/vectraos/spacemit/k1-orangepi-rv2.dts"
  let out = FileManager.default.temporaryDirectory.appendingPathComponent("boardcheck-\(UUID().uuidString).i")
  defer { try? FileManager.default.removeItem(at: out) }
  let p = Process()
  p.executableURL = URL(fileURLWithPath: clang!)
  p.arguments = ["-E", "-nostdinc", "-undef", "-D__DTS__", "-x", "assembler-with-cpp",
                 "-I", (dts as NSString).deletingLastPathComponent, "-I", root + "/firmware/dts/include", dts, "-o", out.path]
  try p.run()
  p.waitUntilExit()
  try #require(p.terminationStatus == 0)
  return try DtsParser.parse(String(contentsOf: out, encoding: .utf8), file: dts) { name, from in
    let here = (from as NSString).deletingLastPathComponent
    for dir in [here, root + "/firmware/dts/include"] {
      let path = dir + "/" + name
      if let text = try? String(contentsOfFile: path, encoding: .utf8) { return (text, path) }
    }
    return nil
  }.flatten()
}

func sky1() throws -> Board { try Board.acpi(name: "orangepi-6-plus", directory: sky1Directory) }
func rv2() throws -> Board { try Board.tree(name: "orangepi-rv2", dtb: try rv2Tree(), coherentByDefault: true) }
func index() throws -> DriverIndex { try DriverIndex.load(root: root) }

func report(_ findings: [Finding]) -> Comment { Comment(rawValue: findings.map { $0.description }.joined(separator: "\n")) }

// MARK: The boards pass

@Test(.enabled(if: hasSky1, skyNote))
func theSky1sTablesPassEveryCheck() throws {
  let board = try sky1()
  // Not vacuous: the tables make a machine's worth of devices, IOMMU units and masters.
  #expect(board.devices.count > 200, "\(board.devices.count) devices")
  #expect(board.units.count == 2 && board.masters.count > 10, "\(board.units.count) units, \(board.masters.count) masters")
  #expect(board.masters.contains { !$0.streams.isEmpty } && board.firmware.count == 1)
  let findings = BoardChecks.run(board, index: try index())
  #expect(findings.isEmpty, report(findings))
}

/// The RV2's tree passes every check but one, which is open: its two EHCI
/// controllers' second `reg` is a word of the APMU's page (0xd428287c and
/// 0xd4282bc4, their VBUS drive bits), which k1-syscon(3) owns, so devmgr's
/// exclusive grants (D167) refuse the controllers' hosts that page. The fix
/// is a syscon link through the APMU's tree, in ehci(3); when it lands this
/// test says the tree is clean.
@Test(.enabled(if: clang != nil, rv2Note))
func theRV2sTreePassesEveryCheckButOneOpenOne() throws {
  let board = try rv2()
  #expect(board.devices.count > 25, "\(board.devices.count) devices")
  let findings = BoardChecks.run(board, index: try index())
  let open = findings.filter { $0.check == .pages }
  #expect(open.count == 1 && open[0].subject == "page 0xd4282000"
          && open[0].detail.contains("dt-system-controller@d4282800") && open[0].detail.contains("dt-ehci@c0900100")
          && open[0].detail.contains("dt-ehci1@c0980100"), report(open))
  let rest = findings.filter { $0.check != .pages }
  #expect(rest.isEmpty, report(rest))
}

/// A rule of a board's record that covers nothing on the board is stale.
func staleRules(_ board: Board, prefix: String) throws -> [String] {
  var out: [String] = []
  for l in try index().leftAlone where l.name.hasPrefix(prefix) {
    for rule in l.rules {
      let one = DriverIndex(drivers: [], leftAlone: [LeftAlone(name: l.name, rules: [rule], reason: l.reason)])
      let covers: Bool
      if case .iommu(let base) = rule {
        covers = board.units.contains { $0.base == base }
      } else {
        covers = board.devices.contains { one.leftAlone($0) != nil }
      }
      if !covers { out.append("\(l.origin): '\(l.name)' rule '\(rule.description)' covers nothing on \(board.name)") }
    }
  }
  return out
}

@Test(.enabled(if: hasSky1, skyNote))
func everyLeaveRuleOfTheSky1CoversSomething() throws {
  let stale = try staleRules(try sky1(), prefix: "sky1-")
  #expect(stale.isEmpty, Comment(rawValue: stale.joined(separator: "\n")))
}

@Test(.enabled(if: clang != nil, rv2Note))
func everyLeaveRuleOfTheRV2CoversSomething() throws {
  let stale = try staleRules(try rv2(), prefix: "rv2-")
  #expect(stale.isEmpty, Comment(rawValue: stale.joined(separator: "\n")))
}

// MARK: The index's records

@Test func aLeaveRecordIsReadWithItsRulesAndReason() throws {
  let text = """
    driver edu
    class test
    match pci 1234:11e8
    leave consoles
    match acpi ARMH0011
    match acpi-path \\_SB_.TZ*
    match iommu b1b0000
    reason no driver yet
    driver other
    match dt vendor,thing
    """
  let index = try DriverIndex(text: text, file: "t")
  #expect(index.drivers.map { $0.name } == ["edu", "other"])
  #expect(index.leftAlone.count == 1)
  #expect(index.leftAlone[0].rules == [.acpi("ARMH0011"), .acpiPath("\\_SB_.TZ*"), .iommu(0xb1b_0000)])
  #expect(index.leftAlone[0].reason == "no driver yet")
  func acpi(_ path: String, _ hid: String?) -> Device {
    Device(acpi: Device.ACPIDevice(path: path, hid: hid, cids: [], status: 15))
  }
  #expect(index.leftAlone(acpi("\\_SB_.COM0", "ARMH0011")) != nil)
  #expect(index.leftAlone(acpi("\\_SB_.TZGB", nil)) != nil)
  #expect(index.leftAlone(acpi("\\_SB_.TZ", nil)) != nil)
  #expect(index.leftAlone(acpi("\\_SB_.TXGB", nil)) == nil)
  #expect(index.leftAlone(acpi("\\_SB_.COM0", "PNP0501")) == nil)
}

@Test func aLeaveRecordWithoutARuleOrAReasonIsRefused() {
  #expect(throws: IndexError.self) { try DriverIndex(text: "leave x\nreason why\n", file: "t") }
  #expect(throws: IndexError.self) { try DriverIndex(text: "leave x\nmatch acpi A\n", file: "t") }
  // A driver's directives and a leave record's don't mix.
  #expect(throws: IndexError.self) { try DriverIndex(text: "leave x\nclass test\n", file: "t") }
  #expect(throws: IndexError.self) { try DriverIndex(text: "driver d\nmatch acpi A\nreason why\n", file: "t") }
  // A driver doesn't match by path or unit.
  #expect(throws: IndexError.self) { try DriverIndex(text: "driver d\nmatch acpi-path \\_SB_.X\n", file: "t") }
  #expect(throws: IndexError.self) { try DriverIndex(text: "driver d\nmatch iommu 1000\n", file: "t") }
  #expect(throws: IndexError.self) { try DriverIndex(text: "leave x\nmatch iommu zz\nreason r\n", file: "t") }
}

@Test func theTreesRecordsAreAnIndexWithNoConflicts() throws {
  let index = try index()
  #expect(index.drivers.count > 20 && index.leftAlone.count > 10)
  #expect(index.conflicts.isEmpty, Comment(rawValue: index.conflicts.joined(separator: "\n")))
}

// MARK: Controls

func tree(_ path: String, _ compatible: String = "vendor,thing", ranges: [(UInt64, UInt64)] = [], irqs: [UInt32] = [],
          links: [DeviceLink] = [], iommus: [TreeDevice.IOMMU] = []) -> Device {
  Device(dt: TreeDevice(path: path, name: String(path.split(separator: "/").last ?? ""), compatibles: [compatible],
                        ranges: ranges.map { TreeDevice.Range(base: $0.0, size: $0.1) },
                        interrupts: irqs.map { TreeDevice.Interrupt(gsi: $0, trigger: .levelHigh) }, iommus: iommus,
                        links: links))
}

/// An index that binds the compatible `vendor,thing` to a driver, and
/// leaves `vendor,idle` alone.
func driverIndex(leaving: [LeftAlone] = []) throws -> DriverIndex {
  var index = try DriverIndex(text: "driver thing\nmatch dt vendor,thing\n", file: "t")
  index.leftAlone = leaving
  return index
}

@Test func controlOverlappingRegistersFail() throws {
  let index = try driverIndex()
  var board = Board(name: "t", devices: [tree("/a", ranges: [(0x1000, 0x100)]), tree("/b", ranges: [(0x1080, 0x100)])])
  #expect(BoardChecks.run(.overlap, board, index: index).count == 1)
  // Mended: apart, or one inside the other.
  board.devices[1] = tree("/b", ranges: [(0x1100, 0x100)])
  #expect(BoardChecks.run(.overlap, board, index: index).isEmpty)
  board.devices = [tree("/bus", ranges: [(0x1000, 0x1000)]), tree("/bus/b", ranges: [(0x1100, 0x100)])]
  #expect(BoardChecks.run(.overlap, board, index: index).isEmpty)
}

@Test func controlADeviceNothingOwnsFails() throws {
  let idle = tree("/idle", "vendor,idle")
  let board = Board(name: "t", devices: [tree("/a"), idle])
  #expect(BoardChecks.run(.unowned, board, index: try driverIndex()).count == 1)
  // Mended by saying why it is left alone.
  let left = LeftAlone(name: "idle", rules: [.dt("vendor,idle")], reason: "nothing to drive")
  #expect(BoardChecks.run(.unowned, board, index: try driverIndex(leaving: [left])).isEmpty)
  // A record over a device a driver matches is stale: it fails too.
  let stale = LeftAlone(name: "stale", rules: [.dt("vendor,thing")], reason: "once had none")
  #expect(BoardChecks.run(.unowned, Board(name: "t", devices: [tree("/a")]), index: try driverIndex(leaving: [stale])).count == 1)
  // Two drivers matching one device alike is not an owner either.
  var two = try DriverIndex(text: "driver one\nmatch dt vendor,thing\ndriver two\nmatch dt vendor,thing\n", file: "t")
  two.leftAlone = []
  #expect(BoardChecks.run(.unowned, Board(name: "t", devices: [tree("/a")]), index: two).count == 1)
}

@Test func controlProvidersWithACycleOrNoProviderFail() throws {
  let index = try driverIndex()
  func clock(_ to: String) -> DeviceLink { DeviceLink(kind: "clock", name: "core", provider: to, cells: [1]) }
  // A chain is fine; a closes on itself through b is a cycle.
  var board = Board(name: "t", devices: [tree("/a", links: [clock("/b")]), tree("/b", links: [clock("/c")]), tree("/c")])
  #expect(BoardChecks.run(.providers, board, index: index).isEmpty)
  board.devices[2] = tree("/c", links: [clock("/a")])
  let cycle = BoardChecks.run(.providers, board, index: index)
  #expect(cycle.count == 1 && cycle[0].detail.contains("cycle"), report(cycle))
  // A link with no provider, and one naming a device that isn't there.
  board.devices[2] = tree("/c", links: [DeviceLink(kind: "supply", name: "vdd", provider: "")])
  #expect(BoardChecks.run(.providers, board, index: index).count == 1)
  board.devices[2] = tree("/c", links: [clock("/missing")])
  #expect(BoardChecks.run(.providers, board, index: index).count == 1)
  // A fixed clock the board lists is where a chain ends; one it doesn't is a missing provider.
  board.devices[2] = tree("/c", links: [DeviceLink(kind: "clock", name: "ref", provider: "", target: "/clocks/osc")])
  #expect(BoardChecks.run(.providers, board, index: index).count == 1)
  board.roots = ["/clocks/osc"]
  #expect(BoardChecks.run(.providers, board, index: index).isEmpty)
  // A device is not its own provider's trouble: a self link is no cycle.
  board.devices[2] = tree("/c", links: [clock("/c")])
  #expect(BoardChecks.run(.providers, board, index: index).isEmpty)
}

@Test func controlAMasterBehindAnUnsuppliedIOMMUFails() throws {
  let domain = DeviceLink(kind: "power-domain", provider: "/pd", cells: [3])
  let master = tree("/dpu", links: [domain], iommus: [TreeDevice.IOMMU(unit: "/smmu", id: [1])])
  func board(unit smmu: Device) -> Board {
    Board(name: "t", devices: [master, smmu, tree("/pd")], units: [IOMMUNode(name: "/smmu", device: "/smmu")],
          masters: [DMAMaster(name: "/dpu", device: "/dpu", streams: [StreamIDs(unit: "/smmu", first: 1, count: 0)])])
  }
  let index = try driverIndex()
  #expect(BoardChecks.run(.iommuSupply, board(unit: tree("/smmu")), index: index).count == 1)
  // Mended: the unit is in a power domain of its own.
  #expect(BoardChecks.run(.iommuSupply, board(unit: tree("/smmu", links: [domain])), index: index).isEmpty)
  // A unit no device holds has none either, unless a record says why.
  var orphan = board(unit: tree("/smmu"))
  orphan.units = [IOMMUNode(name: "0x1000", device: nil, base: 0x1000)]
  orphan.masters[0].streams[0].unit = "0x1000"
  #expect(BoardChecks.run(.iommuSupply, orphan, index: index).count == 1)
  let left = LeftAlone(name: "smmu", rules: [.iommu(0x1000)], reason: "the kernel's")
  #expect(BoardChecks.run(.iommuSupply, orphan, index: try driverIndex(leaving: [left])).isEmpty)
}

@Test func controlAnInterruptTwoDriversHaveFails() throws {
  let left = LeftAlone(name: "idle", rules: [.dt("vendor,idle")], reason: "core of the one above")
  let index = try driverIndex(leaving: [left])
  var board = Board(name: "t", devices: [tree("/a", irqs: [40]), tree("/b", irqs: [41, 40])])
  let findings = BoardChecks.run(.interrupts, board, index: index)
  #expect(findings.count == 1 && findings[0].subject == "interrupt 40", report(findings))
  // Mended: the second is a device no driver takes (a core beside its host).
  board.devices[1] = tree("/b", "vendor,idle", irqs: [41, 40])
  #expect(BoardChecks.run(.interrupts, board, index: index).isEmpty)
}

@Test func controlAStreamIDTwoMastersHaveFails() throws {
  func masters(_ second: UInt32, count: UInt32 = 0) -> Board {
    Board(name: "t", devices: [], units: [IOMMUNode(name: "u", device: nil), IOMMUNode(name: "v", device: nil)],
          masters: [DMAMaster(name: "a", device: nil, streams: [StreamIDs(unit: "u", first: 4, count: 3)]),
                    DMAMaster(name: "b", device: nil, streams: [StreamIDs(unit: "u", first: second, count: count)])])
  }
  let index = try driverIndex()
  #expect(BoardChecks.run(.streamIDs, masters(6), index: index).count == 1)  // 6 is in 4...7
  #expect(BoardChecks.run(.streamIDs, masters(2, count: 2), index: index).count == 1)  // 2...4 meets 4
  #expect(BoardChecks.run(.streamIDs, masters(8), index: index).isEmpty)
  // The same id on another unit is another id.
  var other = masters(6)
  other.masters[1].streams[0].unit = "v"
  #expect(BoardChecks.run(.streamIDs, other, index: index).isEmpty)
}

@Test func controlARegisterPageTwoHostsHaveFails() throws {
  let index = try driverIndex()
  var board = Board(name: "t", devices: [tree("/a", ranges: [(0x1000, 0x80)]), tree("/b", ranges: [(0x1800, 0x80)])])
  let findings = BoardChecks.run(.pages, board, index: index)
  #expect(findings.count == 1 && findings[0].subject == "page 0x1000", report(findings))
  board.devices[1] = tree("/b", ranges: [(0x2000, 0x80)])
  #expect(BoardChecks.run(.pages, board, index: index).isEmpty)
  // A device no driver is bound to is no host: it holds no page.
  board.devices[1] = tree("/b", "vendor,idle", ranges: [(0x1800, 0x80)])
  #expect(BoardChecks.run(.pages, board, index: index).isEmpty)
  // Memory a board rule grants a host counts too.
  board.devices[1] = tree("/b")
  board.firmware = [FirmwareRange(device: "/b", base: 0x1900, size: 0x80)]
  #expect(BoardChecks.run(.pages, board, index: index).count == 1)
}

/// The same controls over the real Sky1: the board is mended by what it
/// has, and broken one way at a time.
@Test(.enabled(if: hasSky1, skyNote))
func controlsBreakTheSky1OneCheckAtATime() throws {
  let good = try sky1()
  let index = try index()
  func fails(_ check: Check, _ make: (inout Board) -> Void) -> Bool {
    var board = good
    make(&board)
    return !BoardChecks.run(check, board, index: index).isEmpty
  }
  // Stream ids: a second master with the first one's.
  #expect(fails(.streamIDs) { b in
    let m = b.masters.first { !$0.streams.isEmpty }!
    b.masters.append(DMAMaster(name: "intruder", device: nil, streams: m.streams))
  })
  // Overlap: a device inside no other's, half over a real one's registers.
  #expect(fails(.overlap) { b in
    let (base, size) = b.devices.compactMap { BoardChecks.firstRange($0) }.first { $0.1 >= 0x100 }!
    b.devices.append(Device(acpi: Device.ACPIDevice(path: "\\_SB_.XTRA", hid: "ARMH0011", cids: [], status: 15,
                                                    resources: [.mmio(base: base + size / 2, size: size)])))
  })
  // Interrupt: a bound device with another bound device's interrupt.
  #expect(fails(.interrupts) { b in
    let bound = b.devices.first { d in
      if case .driver = index.match(d), case .acpi(let a) = d.bus { return a.resources.contains { if case .interrupt = $0 { return true } else { return false } } }
      return false
    }!
    let irq = BoardChecks.firstInterrupt(bound)!
    b.devices.append(Device(acpi: Device.ACPIDevice(path: bound.acpi!.path + "X", hid: bound.acpi!.hid, cids: [], status: 15,
                                                    resources: [.interrupt(irq, .levelHigh)])))
  })
  // Unowned: a device with an id nothing matches.
  #expect(fails(.unowned) { b in
    b.devices.append(Device(acpi: Device.ACPIDevice(path: "\\_SB_.NEWD", hid: "ZZZZ0000", cids: [], status: 15)))
  })
  // Providers: a link to a device the tables don't have.
  #expect(fails(.providers) { b in
    b.devices.append(Device(acpi: Device.ACPIDevice(path: "\\_SB_.LONE", hid: "ARMH0011", cids: [], status: 15,
                                                    links: [DeviceLink(kind: "i2c", provider: "\\_SB_.NONE", cells: [1])])))
  })
  // IOMMU: a unit no device holds and no record names.
  #expect(fails(.iommuSupply) { b in
    b.units.append(IOMMUNode(name: "0x5000000", device: nil, base: 0x500_0000))
    b.masters.append(DMAMaster(name: "x", device: nil, streams: [StreamIDs(unit: "0x5000000", first: 1, count: 0)]))
  })
  // Pages: a driver-bound device with a register in another's page.
  #expect(fails(.pages) { b in
    let bound = b.devices.first { d in
      if case .driver = index.match(d), BoardChecks.firstRange(d) != nil { return true } else { return false }
    }!
    let (base, _) = BoardChecks.firstRange(bound)!
    b.devices.append(Device(acpi: Device.ACPIDevice(path: "\\_SB_.PAGE", hid: bound.acpi?.hid, cids: [], status: 15,
                                                    resources: [.mmio(base: base + 8, size: 8)])))
  })
}
