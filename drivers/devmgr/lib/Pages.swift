// SPDX-License-Identifier: BSD-3-Clause

// The MMIO pages devmgr grants (D167): an MMIO resource grants every 4 KiB
// page it touches, so a page is one host's. The ledger records each range
// granted to a host and whether it was made exclusive, decides before the
// kernel does whether a range would share a page with another host's, and
// lists the pages two hosts have (`status`).

import DeviceTreeBus
import Sys

/// Whether the ranges a device is linked to (`Device.LinkedRange`: SCMI's
/// shared memory and mailboxes, a PHY, a reset controller) are granted
/// exclusively, as its own are. Off, a page several devices are linked to
/// stays shared, and `status` lists it.
public enum GrantPolicy {
  public static let linkedRangesExclusive = true
}

public enum Pages {
  /// The first page and the page after the last that [base, base + size)
  /// touches.
  public static func span(_ base: UInt64, _ size: UInt64) -> (first: UInt64, end: UInt64) {
    let first = base & ~4095
    let last = base &+ size
    let end = last < base ? UInt64.max & ~4095 : (last &+ 4095) & ~4095
    return (first, max(end, first &+ 4096))
  }

  public static func hex(_ v: UInt64) -> String { "0x" + String(v, radix: 16) }
}

/// A range granted to a host.
public struct PageGrant: Equatable, Sendable {
  public var host: String
  public var base: UInt64
  public var size: UInt64
  public var exclusive: Bool
  public init(host: String, base: UInt64, size: UInt64, exclusive: Bool) {
    self.host = host
    self.base = base
    self.size = size
    self.exclusive = exclusive
  }

  // Hosts compare by bytes: String's == pulls Unicode normalization into the link.
  public static func == (a: PageGrant, b: PageGrant) -> Bool {
    same(a.host, b.host) && a.base == b.base && a.size == b.size && a.exclusive == b.exclusive
  }
}

/// Pages two hosts have, or would: [first, end) and the hosts.
public struct SharedPages: Equatable, Sendable {
  public var first: UInt64
  public var end: UInt64
  public var hosts: [String]
  public init(first: UInt64, end: UInt64, hosts: [String]) {
    self.first = first
    self.end = end
    self.hosts = hosts
  }

  public static func == (a: SharedPages, b: SharedPages) -> Bool {
    guard a.first == b.first, a.end == b.end, a.hosts.count == b.hosts.count else { return false }
    for i in a.hosts.indices where !same(a.hosts[i], b.hosts[i]) { return false }
    return true
  }
}

public final class PageLedger: @unchecked Sendable {
  struct State {
    var grants: [PageGrant] = []
    var refusals: [(host: String, why: String)] = []
  }
  let state = Locked(State())

  public init() {}

  /// The first of `grants` another host holds in a page `g` touches, which
  /// `g` may not share (either one exclusive): the page and the host.
  static func conflict(_ g: PageGrant, in grants: [PageGrant]) -> (page: UInt64, host: String)? {
    let a = Pages.span(g.base, g.size)
    for h in grants where !same(h.host, g.host) && (g.exclusive || h.exclusive) {
      let b = Pages.span(h.base, h.size)
      let first = max(a.first, b.first)
      if first < min(a.end, b.end) { return (first, h.host) }
    }
    return nil
  }

  /// Records `ranges` as `host`'s, all or none: nil, or the page that
  /// refused them and the host that has it (kept for `refusal(of:)`).
  /// A range already recorded for `host` is not recorded twice.
  public func claim(host: String, _ ranges: [(base: UInt64, size: UInt64, exclusive: Bool)])
    -> (page: UInt64, host: String)?
  {
    state.withLock { s in
      var fresh: [PageGrant] = []
      for r in ranges {
        let g = PageGrant(host: host, base: r.base, size: r.size, exclusive: r.exclusive)
        if s.grants.contains(g) || fresh.contains(g) { continue }
        if let c = PageLedger.conflict(g, in: s.grants + fresh) {
          s.refusals.removeAll { same($0.host, host) }
          s.refusals.append((host, "page " + Pages.hex(c.page) + " is " + c.host + "'s"))
          return c
        }
        fresh.append(g)
      }
      s.grants += fresh
      s.refusals.removeAll { same($0.host, host) }
      return nil
    }
  }

  /// Forgets `host`'s ranges (its grants failed, or it ended).
  public func release(host: String) {
    state.withLock { s in s.grants.removeAll { same($0.host, host) } }
  }

  /// Notes that the kernel refused `host`'s range in `page`, which no
  /// recorded host has.
  public func refused(host: String, page: UInt64) {
    state.withLock { s in
      s.refusals.removeAll { same($0.host, host) }
      s.refusals.append((host, "page " + Pages.hex(page) + " is held elsewhere"))
    }
  }

  /// Why `host`'s grants were refused, or nil.
  public func refusal(of host: String) -> String? {
    state.withLock { s in s.refusals.first { same($0.host, host) }?.why }
  }

  public var grants: [PageGrant] { state.withLock { $0.grants } }

  /// The pages in two hosts, from what is granted.
  public var shared: [SharedPages] { PageLedger.shared(grants) }

  public static func shared(_ grants: [PageGrant]) -> [SharedPages] {
    var out: [SharedPages] = []
    for i in grants.indices {
      let a = Pages.span(grants[i].base, grants[i].size)
      for j in grants.indices where j > i && !same(grants[j].host, grants[i].host) {
        let b = Pages.span(grants[j].base, grants[j].size)
        let first = max(a.first, b.first), end = min(a.end, b.end)
        guard first < end else { continue }
        if let k = out.firstIndex(where: { $0.first == first && $0.end == end }) {
          for h in [grants[i].host, grants[j].host] where !out[k].hosts.contains(where: { same($0, h) }) { out[k].hosts.append(h) }
        } else {
          out.append(SharedPages(first: first, end: end, hosts: [grants[i].host, grants[j].host]))
        }
      }
    }
    return out.sorted { $0.first < $1.first }
  }

  /// `status`'s lines for them: `shared 0xFIRST-0xLAST HOST HOST...`.
  public var sharedText: String {
    var out = ""
    for s in shared {
      out += "shared " + Pages.hex(s.first) + "-" + Pages.hex(s.end - 1)
      for h in s.hosts { out += " " + h }
      out += "\n"
    }
    return out
  }
}

extension PageLedger {
  /// The MMIO ranges devmgr grants platform device `d`'s host, as
  /// `platformGrants` makes them: its own, then its linked ones.
  public static func claims(_ d: Device.ACPIDevice) -> [(base: UInt64, size: UInt64, exclusive: Bool)] {
    var out: [(base: UInt64, size: UInt64, exclusive: Bool)] = []
    var index = 0
    for r in d.resources {
      switch r {
      case .mmio(let base, let size):
        guard index < 6 else { continue }
        out.append((base, size, true))
        index += 1
      case .ioport:
        guard index < 6 else { continue }
        index += 1
      case .interrupt: break
      }
    }
    for l in d.linked where index < 6 {
      out.append((l.base, l.size, GrantPolicy.linkedRangesExclusive))
      index += 1
    }
    return out
  }

  /// The same for a devicetree's device: its first six `reg` ranges.
  public static func claims(_ d: TreeDevice) -> [(base: UInt64, size: UInt64, exclusive: Bool)] {
    d.ranges.prefix(6).map { ($0.base, $0.size, true) }
  }
}

/// What a grants function makes its MMIO resources through: it records
/// each range for its host, refuses one that shares a page with another
/// host's, and makes it exclusive where asked (a range inside pages the
/// host already has is a duplicate of that handle, since a resource grants
/// whole pages).
public struct MMIOGrants {
  let ledger: PageLedger?
  let host: String
  var held: [(first: UInt64, end: UInt64, raw: UInt32)] = []

  public init(ledger: PageLedger? = nil, host: String = "") {
    self.ledger = ledger
    self.host = host
  }

  /// A handle for [base, base + size) under `parent`, raw (the caller's).
  /// `exclusive` false is for devmgr's own pages (a function's
  /// configuration space) and, by `GrantPolicy`, linked ranges.
  mutating func make(parent: borrowing Handle, base: UInt64, size: UInt64, name: String, exclusive: Bool)
    throws(Status) -> UInt32
  {
    let (first, end) = Pages.span(base, size)
    if let h = held.first(where: { first >= $0.first && end <= $0.end }) {
      let source = Handle(raw: h.raw)
      let copy: Handle
      do throws(Status) {
        copy = try source.duplicate()
      } catch {
        _ = source.release()
        throw error
      }
      _ = source.release()
      return copy.release()
    }
    if let ledger, ledger.claim(host: host, [(base, size, exclusive)]) != nil { throw .alreadyExists }
    do throws(Status) {
      let raw = try Sys.Resource.create(parent: parent, kind: .mmio, base: base, size: size, name: name,
                                        exclusive: exclusive).release()
      held.append((first, end, raw))
      return raw
    } catch {
      if let ledger {
        ledger.release(host: host)
        if error == .notFound { ledger.refused(host: host, page: first) }
      }
      throw error
    }
  }
}
