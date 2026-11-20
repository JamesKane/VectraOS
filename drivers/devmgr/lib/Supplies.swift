// SPDX-License-Identifier: BSD-3-Clause

// devmgr's side of supply leases (D170, D169): for an ACPI platform device
// with a driver, the register windows it is granted are physical VMOs
// devmgr makes from its own resources, and one supply per provider link
// (an SCMI power domain, a clock, its ACPI power resources, a reset) holds
// them, with the device's BTI. The driver host gets the VMOs where it was
// given resources (DriverHost maps either, and `DeviceHandle.windowName`
// is how a VMO says what range it stands for). Ending a device's supplies
// (`SupplySet.end`) takes the windows and the BTI from the host before any
// provider cuts; the host ends at SUPPLY_ENDING (DriverHost).
//
// The kernel binds a VMO only to a supply made from a resource that covers
// it, so a device with several ranges (its own and its linked ones) has,
// for each link, one kernel supply per distinct range its windows lie in,
// all of them one `SupplyLink` here. The device's interrupts aren't bound:
// the driver makes its interrupt object from the IRQ resource, which devmgr
// still grants as it did. A device with no MMIO range has no supply.
//
// The API for what orders power (D170 §3-§5):
//   Supplies.links(of:)       the links a device has, in the order a power-up
//                             goes: domains, clocks, power resources, resets
//   Findings.supplies(of:)    the links one running host holds supplies for
//   Findings.end(service:)    ends them all, reporting each
// The supplies are made again, from nothing, each time the host starts
// (launcher.extraStartup), so a restart has new ones.

import DeviceTreeBus
import DriverHost
import Sys

/// One provider link of a device: `kind` is `domain` (an SCMI power
/// domain, `raw` its id), `clock` (`raw`: its SCMI id), `power` (the
/// device's ACPI power resources, devmgr's own `_ON`; `raw` 0) or `reset`
/// (`raw`: its index on the controller that provides it); `name` the
/// link's name for the device.
public struct SupplyLink: Equatable, Sendable {
  public var kind: String
  public var name: String
  public var raw: UInt32

  public init(kind: String, name: String, raw: UInt32) {
    self.kind = kind
    self.name = name
    self.raw = raw
  }
}

/// What ending one link's supply did: `ended` if its SUPPLY_ENDED is
/// asserted, and `status` why `supply_end` failed, if it did.
public struct SupplyEnding: Equatable, Sendable {
  public var link: SupplyLink
  public var ended: Bool
  public var status: Status?
}

public enum Supplies {
  /// The links of platform device `d`, in the order to power it up (and the
  /// reverse of the order to cut): its `power-domains` (_DSD), its clocks
  /// (CLKT), its power resources and its resets (RSTL). Empty for a device
  /// with no MMIO range, which has nothing to bind.
  public static func links(of d: Device.ACPIDevice) -> [SupplyLink] {
    var hasMMIO = false
    for r in d.resources { if case .mmio = r { hasMMIO = true } }
    guard hasMMIO else { return [] }
    var out: [SupplyLink] = []
    for id in domains(d.properties) { out.append(SupplyLink(kind: "domain", name: "power-domains", raw: id)) }
    for l in d.links where same(l.kind, "clock") {
      out.append(SupplyLink(kind: "clock", name: l.name, raw: l.cells.first ?? 0))
    }
    if d.powered { out.append(SupplyLink(kind: "power", name: "_PR0", raw: 0)) }
    for l in d.links where same(l.kind, "reset") {
      out.append(SupplyLink(kind: "reset", name: l.name, raw: l.cells.first ?? 0))
    }
    return out
  }

  /// The ids a `power-domains NUMBER...` line of `properties` names (a
  /// word that isn't a decimal number ends the list).
  static func domains(_ properties: String) -> [UInt32] {
    var out: [UInt32] = []
    var word: [UInt8] = []
    var words: [[UInt8]] = []
    func endWord() {
      if !word.isEmpty { words.append(word) }
      word = []
    }
    func endLine() {
      endWord()
      let line = words
      words = []
      if let first = line.first, first.elementsEqual("power-domains".utf8) {
        for w in line.dropFirst() {
          var v: UInt32 = 0
          for c in w {
            guard c >= 0x30, c <= 0x39 else { return }
            v = v &* 10 &+ UInt32(c - 0x30)
          }
          out.append(v)
        }
      }
      words = []
    }
    for c in properties.utf8 {
      if c == 0x0A { endLine() } else if c == 0x20 { endWord() } else { word.append(c) }
    }
    endLine()
    return out
  }

  static func make(resource raw: UInt32) -> Handle? {
    let range = Handle(raw: raw)
    let supply = try? Supply.create(resource: range)
    _ = range.release()
    return supply
  }

  /// Binds object `raw` (which stays the caller's) to `supply`: why not.
  static func bind(_ supply: borrowing Handle, _ raw: UInt32) -> Status? {
    let object = Handle(raw: raw)
    var failure: Status?
    do throws(Status) { try Supply.bind(supply, object) } catch { failure = error }
    _ = object.release()
    return failure
  }

  /// Makes the windows and supplies for one start of a platform device's
  /// host. `grants` are `platformGrants`' handles, which this takes over:
  /// each MMIO BAR's resource becomes a VMO (left a resource if the kernel
  /// refuses one, so the host maps it as it always did) and the grants
  /// come back, with the supplies, which are made for each of `links` from
  /// the resources and have the VMOs and the BTI bound.
  public static func lease(_ grants: [(info: UInt32, handle: UInt32)], links: [SupplyLink], service: String)
    -> (grants: [(info: UInt32, handle: UInt32)], set: SupplySet)
  {
    var out = grants
    // Each distinct range's resource (devmgr's, kept for the supplies) and
    // the VMOs made inside it.
    var groups: [(base: UInt64, size: UInt64, resource: UInt32, vmos: [UInt32])] = []
    var windows = 0
    for i in out.indices {
      var isBAR = false
      for n in 0..<6 where out[i].info == DeviceHandle.bar(n) { isBAR = true }
      guard isBAR else { continue }
      let resource = Handle(raw: out[i].handle)
      guard let info = try? Resource.info(resource), info.kind == ResourceKind.mmio.rawValue, info.size > 0 else {
        _ = resource.release()
        continue
      }
      let aligned = info.base & ~4095
      let length = Int((info.base - aligned + info.size + 4095) & ~4095)
      guard let vmo = try? VMO.physical(resource: resource, address: aligned, size: length),
        (try? vmo.setName(DeviceHandle.windowName(base: info.base, size: info.size))) != nil
      else {
        _ = resource.release()
        continue
      }
      windows += 1
      let raw = vmo.release()
      if let g = groups.firstIndex(where: { $0.base == info.base && $0.size == info.size }) {
        groups[g].vmos.append(raw)
        close(raw: out[i].handle)  // another handle to a range already kept
      } else {
        groups.append((info.base, info.size, out[i].handle, [raw]))
      }
      out[i].handle = raw
      _ = resource.release()
    }
    let set = SupplySet(windows: windows)
    guard !groups.isEmpty, !links.isEmpty else {
      for g in groups { close(raw: g.resource) }
      return (out, set)
    }
    var btis: [UInt32] = []
    for e in out where e.info == DeviceHandle.bti { btis.append(e.handle) }
    for link in links {
      var handles: [UInt32] = []
      for (gi, g) in groups.enumerated() {
        guard let supply = make(resource: g.resource) else {
          print("devmgr: \(service): supply \(link.kind) \(link.name): none")
          continue
        }
        // Firmware's memory (the SMC's shared page) can't be bound.
        for v in g.vmos {
          let failure = bind(supply, v)
          if let failure, failure != .invalidArgs {
            print("devmgr: \(service): supply \(link.kind) \(link.name): bind: \(failure.rawValue)")
          }
        }
        if gi == 0 {
          for b in btis {
            if let failure = bind(supply, b) {
              print("devmgr: \(service): supply \(link.kind) \(link.name): bind BTI: \(failure.rawValue)")
            }
          }
        }
        handles.append(supply.release())
      }
      set.add(link, handles)
    }
    set.keep(resources: groups.map { $0.resource })
    return (out, set)
  }
}

/// The supplies of one start of a host: a `SupplyLink` each, with the
/// kernel supplies behind it. Dropping it closes them without ending
/// them, which leaves what they bound usable (supply(2)).
public final class SupplySet: @unchecked Sendable {
  struct Held {
    var link: SupplyLink
    var handles: [UInt32]
  }
  let lock = Lock()
  var held: [Held] = []
  var resources: [UInt32] = []
  /// How many window VMOs the host was given.
  public let windows: Int

  public init(windows: Int = 0) { self.windows = windows }

  deinit {
    for h in held { for raw in h.handles { close(raw: raw) } }
    for r in resources { close(raw: r) }
  }

  func add(_ link: SupplyLink, _ handles: [UInt32]) { lock.withLock { held.append(Held(link: link, handles: handles)) } }
  func keep(resources raws: [UInt32]) { lock.withLock { resources += raws } }

  /// The links it holds a supply for, in the order they were made.
  public var links: [SupplyLink] { lock.withLock { held.filter { !$0.handles.isEmpty }.map { $0.link } } }

  /// How many links it holds a supply for.
  public var count: Int { lock.withLock { held.filter { !$0.handles.isEmpty }.count } }

  /// Ends every supply: each bound object is signalled and its holder has
  /// `afterNs` nanoseconds from now to let go, then the kernel takes what
  /// is left (supply_end). It returns when all have ended or failed, a
  /// result for each link in the order of `links`. A supply already ended
  /// reports `badState`.
  public func end(afterNs: Int64) -> [SupplyEnding] {
    let deadline = UInt64(max(0, Clock.monotonic() + afterNs))
    let snapshot = lock.withLock { held.filter { !$0.handles.isEmpty } }
    var out: [SupplyEnding] = []
    for h in snapshot {
      var status: Status?
      var ended = true
      for raw in h.handles {
        let supply = Handle(raw: raw)
        do throws(Status) { try Supply.end(supply, deadline: deadline) } catch { status = status ?? error }
        if (try? supply.wait(for: Supply.endedSignal, deadline: 1)) == nil { ended = false }
        _ = supply.release()
      }
      out.append(SupplyEnding(link: h.link, ended: ended, status: status))
    }
    return out
  }
}
