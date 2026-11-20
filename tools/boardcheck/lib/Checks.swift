// SPDX-License-Identifier: BSD-3-Clause

// Checks over a whole machine's description (D171, the backlog's B4): what
// devmgr would take as true of a board, judged before any driver runs.
// Each check reads the Board (Board.swift), devmgr's own model, and says
// what it found as findings; a board passes when there are none. Each
// check has a control in the tests, a description that must fail it.

import DevMgr
import DeviceTreeBus
import Sys

public enum Check: String, CaseIterable, Sendable {
  /// Register ranges overlap, and neither nests in the other.
  case overlap
  /// An enabled device no driver's record matches and no `leave` record covers.
  case unowned
  /// A link with no provider, or the providers' graph has a cycle.
  case providers
  /// A master behind an IOMMU unit that has no supply of its own.
  case iommuSupply = "iommu-supply"
  /// An interrupt two devices have.
  case interrupts
  /// A stream id two masters have on one unit.
  case streamIDs = "stream-ids"
  /// A register page two hosts are granted.
  case pages
}

public struct Finding: Equatable, Sendable, CustomStringConvertible {
  public var check: Check
  public var subject: String
  public var detail: String

  public init(_ check: Check, _ subject: String, _ detail: String) {
    self.check = check
    self.subject = subject
    self.detail = detail
  }

  public var description: String { "\(check.rawValue): \(subject): \(detail)" }
}

public enum BoardChecks {
  /// Every check, over `board`, with the drivers' records in `index`.
  public static func run(_ board: Board, index: DriverIndex) -> [Finding] {
    var out: [Finding] = []
    for c in Check.allCases { out += run(c, board, index: index) }
    return out
  }

  public static func run(_ check: Check, _ board: Board, index: DriverIndex) -> [Finding] {
    switch check {
    case .overlap: overlapping(board)
    case .unowned: unowned(board, index: index)
    case .providers: providers(board)
    case .iommuSupply: iommuSupply(board, index: index)
    case .interrupts: interrupts(board, index: index)
    case .streamIDs: streamIDs(board)
    case .pages: pages(board, index: index)
    }
  }

  // MARK: What a device says of itself

  /// The device's path, which names it in the description: an ACPI path or
  /// a node's.
  public static func path(_ d: Device) -> String {
    switch d.bus {
    case .acpi(let a): a.path
    case .dt(let t): t.path
    case .pci(let f): "pci " + f.address.description
    }
  }

  /// Its own register ranges, as the tables or the tree give them.
  static func ranges(_ d: Device) -> [(base: UInt64, size: UInt64)] {
    switch d.bus {
    case .acpi(let a):
      return a.resources.compactMap { r in
        if case .mmio(let base, let size) = r { return (base, size) }
        return nil
      }
    case .dt(let t): return t.ranges.map { ($0.base, $0.size) }
    case .pci: return []
    }
  }

  /// Its first register range, as the tests' controls take one to overlap.
  public static func firstRange(_ d: Device) -> (UInt64, UInt64)? { ranges(d).first }

  /// Its first interrupt.
  public static func firstInterrupt(_ d: Device) -> UInt32? { interruptNumbers(d).first }

  static func interruptNumbers(_ d: Device) -> [UInt32] {
    switch d.bus {
    case .acpi(let a):
      return a.resources.compactMap { r in
        if case .interrupt(let n, _) = r { return n }
        return nil
      }
    case .dt(let t): return t.interrupts.map { $0.gsi }
    case .pci: return []
    }
  }

  static func links(_ d: Device) -> [DeviceLink] {
    switch d.bus {
    case .acpi(let a): a.links
    case .dt(let t): t.links
    case .pci: []
    }
  }

  /// Whether `a` and `b` name one device: ACPI paths compare by segment.
  static func samePathOf(_ a: String, _ b: String) -> Bool { a == b || samePath(a, b) }

  // MARK: Overlapping registers

  /// Two devices' ranges that overlap, unless one lies wholly inside the
  /// other (a window and the registers within it, a bus and its devices).
  public static func overlapping(_ board: Board) -> [Finding] {
    var out: [Finding] = []
    let all = board.devices.map { (path($0), ranges($0)) }
    for i in all.indices {
      for j in all.indices where j > i {
        for a in all[i].1 where a.size > 0 {
          for b in all[j].1 where b.size > 0 {
            let aEnd = a.base &+ a.size, bEnd = b.base &+ b.size
            guard a.base < bEnd, b.base < aEnd else { continue }
            let nests = (a.base >= b.base && aEnd <= bEnd) || (b.base >= a.base && bEnd <= aEnd)
            if nests { continue }
            out.append(Finding(.overlap, "\(all[i].0) and \(all[j].0)",
                               "\(hex(a.base))+\(hex(a.size)) overlaps \(hex(b.base))+\(hex(b.size)), and neither nests in the other"))
          }
        }
      }
    }
    return out
  }

  // MARK: Devices nothing owns

  /// An enabled device whose match is nothing, or ambiguous, and which no
  /// `leave` record covers; and a `leave` record over a device a driver
  /// matches (the record is stale).
  public static func unowned(_ board: Board, index: DriverIndex) -> [Finding] {
    var out: [Finding] = []
    for d in board.devices {
      let left = index.leftAlone(d)
      switch index.match(d) {
      case .driver(let i):
        if let left {
          out.append(Finding(.unowned, path(d), "left alone ('\(left.name)') but driver '\(index.drivers[i].name)' matches it"))
        }
      case .none:
        if left == nil { out.append(Finding(.unowned, path(d), "\(d.ids): no driver's record matches it, and nothing leaves it alone")) }
      case .ambiguous(let names):
        out.append(Finding(.unowned, path(d), "\(d.ids): drivers \(names.joined(separator: ", ")) match it alike"))
      }
    }
    return out
  }

  // MARK: Providers

  /// Each link names a device that is there; the SCMI agent's clocks
  /// (CIX's CLKT names none) go to the device that has shared memory; and
  /// no device is its own provider's provider, however far round.
  public static func providers(_ board: Board) -> [Finding] {
    var out: [Finding] = []
    let paths = board.devices.map { path($0) }
    let agent = board.devices.indices.first { i in
      if case .acpi(let a) = board.devices[i].bus { return a.linked.contains { $0.role == "shmem" } }
      return false
    }
    var edges = [[Int]](repeating: [], count: paths.count)
    for (i, d) in board.devices.enumerated() {
      for l in links(d) {
        let what = l.kind + (l.name.isEmpty ? "" : " " + l.name)
        if l.provider.isEmpty, board.roots.contains(l.target) {
          continue  // a fixed clock: where the chain ends
        } else if l.provider.isEmpty {
          if case .acpi = d.bus, l.kind == "clock" || l.kind == "power-domain" {
            if let agent { edges[i].append(agent) } else { out.append(Finding(.providers, paths[i], "link \(what): no SCMI agent to provide it")) }
          } else {
            out.append(Finding(.providers, paths[i], "link \(what) has no provider" + (l.target.isEmpty ? "" : " (it names \(l.target))")))
          }
        } else if let j = paths.firstIndex(where: { samePathOf($0, l.provider) }) {
          if j != i { edges[i].append(j) }
        } else {
          out.append(Finding(.providers, paths[i], "link \(what) names \(l.provider), which is no device here"))
        }
      }
    }
    // Cycles: a depth-first walk, a node on the stack reached again.
    var state = [Int](repeating: 0, count: paths.count)  // 0 new, 1 on the stack, 2 done
    var stack: [Int] = []
    func visit(_ n: Int) {
      state[n] = 1
      stack.append(n)
      for m in edges[n] {
        if state[m] == 1, let at = stack.firstIndex(of: m) {
          let ring = stack[at...].map { paths[$0] } + [paths[m]]
          out.append(Finding(.providers, paths[m], "a cycle of providers: " + ring.joined(separator: " -> ")))
        } else if state[m] == 0 {
          visit(m)
        }
      }
      stack.removeLast()
      state[n] = 2
    }
    for n in paths.indices where state[n] == 0 { visit(n) }
    return out
  }

  // MARK: IOMMU supplies

  /// Whether a device has a supply: power resources, or a power domain or
  /// supply link.
  static func supplied(_ d: Device) -> Bool {
    if case .acpi(let a) = d.bus, a.powered { return true }
    return links(d).contains { $0.kind == "power-domain" || $0.kind == "supply" }
  }

  /// A master behind a unit: the unit is a device here, and where the
  /// master has a supply (it is in a power domain) so has the unit, a
  /// supply of its own to be on before the master's DMA is. A unit no
  /// device holds (an SMMU the IORT names and the namespace doesn't) has
  /// none the tables say, unless a `leave` record names its base.
  public static func iommuSupply(_ board: Board, index: DriverIndex) -> [Finding] {
    var out: [Finding] = []
    for unit in board.units {
      let behind = board.masters.filter { m in m.streams.contains { $0.unit == unit.name } }
      guard !behind.isEmpty else { continue }
      let holder = unit.device.flatMap { p in board.devices.first { samePathOf(path($0), p) } }
      if let holder {
        for m in behind {
          let masterDevice = m.device.flatMap { p in board.devices.first { samePathOf(path($0), p) } }
          if let masterDevice, supplied(masterDevice), !supplied(holder) {
            out.append(Finding(.iommuSupply, m.name, "powered, behind \(unit.name) (\(path(holder))), which has no supply of its own"))
          }
        }
      } else if !index.leftAlone.contains(where: { l in l.rules.contains { $0 == .iommu(unit.base) } }) {
        out.append(Finding(.iommuSupply, "unit \(unit.name)", "no device holds it, so it has no supply of its own; behind it: "
                           + behind.map { $0.name }.joined(separator: ", ")))
      }
    }
    return out
  }

  // MARK: Interrupts

  /// An interrupt two devices have, as a driver's host is given it: a device
  /// no driver is bound to owns none (a USB controller's core and its xhci
  /// host name one interrupt, and only the host's driver takes it).
  public static func interrupts(_ board: Board, index: DriverIndex) -> [Finding] {
    var owners: [(n: UInt32, paths: [String])] = []
    for d in board.devices {
      guard case .driver = index.match(d) else { continue }
      for n in Set(interruptNumbers(d)).sorted() {
        if let k = owners.firstIndex(where: { $0.n == n }) { owners[k].paths.append(path(d)) } else { owners.append((n, [path(d)])) }
      }
    }
    return owners.filter { $0.paths.count > 1 }.sorted { $0.n < $1.n }.map {
      Finding(.interrupts, "interrupt \($0.n)", "has \($0.paths.count) owners: " + $0.paths.joined(separator: ", "))
    }
  }

  // MARK: Stream ids

  /// A stream id two masters have on one unit.
  public static func streamIDs(_ board: Board) -> [Finding] {
    var out: [Finding] = []
    for u in board.units {
      var mine: [(master: String, first: UInt64, last: UInt64)] = []
      for m in board.masters {
        for s in m.streams where s.unit == u.name {
          mine.append((m.name, UInt64(s.first), UInt64(s.first) + UInt64(s.count)))
        }
      }
      for i in mine.indices {
        for j in mine.indices where j > i && mine[i].master != mine[j].master {
          let first = max(mine[i].first, mine[j].first), last = min(mine[i].last, mine[j].last)
          guard first <= last else { continue }
          out.append(Finding(.streamIDs, "\(u.name)", "stream ids \(first)-\(last) are \(mine[i].master)'s and \(mine[j].master)'s"))
        }
      }
    }
    return out
  }

  // MARK: Register pages

  /// The pages two hosts are granted (D167): each bound device is a host,
  /// granted what devmgr grants it, which PageLedger says.
  public static func pages(_ board: Board, index: DriverIndex) -> [Finding] {
    var grants: [PageGrant] = []
    for d in board.devices {
      guard case .driver = index.match(d) else { continue }
      let host = d.name
      switch d.bus {
      case .acpi(let a):
        for c in PageLedger.claims(a) { grants.append(PageGrant(host: host, base: c.base, size: c.size, exclusive: c.exclusive)) }
      case .dt(let t):
        for c in PageLedger.claims(t) { grants.append(PageGrant(host: host, base: c.base, size: c.size, exclusive: c.exclusive)) }
      case .pci: break
      }
      for f in board.firmware where samePathOf(f.device, path(d)) {
        grants.append(PageGrant(host: host, base: f.base, size: f.size, exclusive: true))
      }
    }
    return PageLedger.shared(grants).map {
      Finding(.pages, "page \(hex($0.first))", "\($0.hosts.joined(separator: " and ")) are both granted it")
    }
  }
}
