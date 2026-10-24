// SPDX-License-Identifier: BSD-3-Clause

// What a platform device's driver needs from ACPI past its _CRS: _DSD's
// device properties (§6.2.5, under the Device Properties UUID: a package
// of name and value pairs), the objects a property names, and the power
// resources that put the device in D0 (§7.2, _PR0), turned on and off.

extension Namespace {
  /// The Device Properties UUID's bytes, as ToUUID gives them.
  public static let devicePropertiesUUID = uuid("daffd814-6eba-4d8c-8a91-bc9bbf4aa301")

  /// _DSD's device properties: each name and its value, in order. None
  /// where the device has no _DSD or none under that UUID.
  public mutating func deviceProperties<H: ACPIHost>(_ device: Int, host: H) throws(ACPIError)
    -> [(name: [UInt8], value: Datum)]
  {
    guard let v = try childValue(device, "_DSD", host: host) else { return [] }
    guard case .package(let p) = v else { throw ACPIError.typeMismatch }
    var out: [(name: [UInt8], value: Datum)] = []
    var i = 0
    while i + 1 < p.elements.count {
      if p.elements[i].bytes == Self.devicePropertiesUUID, case .package(let properties) = p.elements[i + 1] {
        for e in properties.elements {
          guard case .package(let pair) = e, pair.elements.count == 2, let name = pair.elements[0].string else { continue }
          out.append((name, pair.elements[1]))
        }
      }
      i += 2
    }
    return out
  }

  /// The named objects a property's value refers to: the reference, or
  /// each reference in a package, in order (a package may interleave
  /// them with integers, as a mailbox reference's channel; those are
  /// left out).
  public static func referencedNodes(_ value: Datum) -> [Int] {
    switch value {
    case .reference(.node(let n)), .object(let n): return [n]
    case .package(let p): return p.elements.flatMap { referencedNodes($0) }
    default: return []
    }
  }

  /// The power resources _PR0 names for `device`: what puts it in D0.
  public mutating func powerResources<H: ACPIHost>(_ device: Int, host: H) throws(ACPIError) -> [Int] {
    guard let v = try childValue(device, "_PR0", host: host) else { return [] }
    return Self.referencedNodes(v).filter {
      if case .powerResource = nodes[$0].object { return true }
      return false
    }
  }

  /// Turns power resource `resource` on (`on`) or off: its _ON or _OFF,
  /// unless `checkStatus` and its _STA says it already is. Whether the
  /// method ran. (Firmware can leave _STA's bit set with the rest of what
  /// _ON does undone, as the CIX Sky1's GPU supply: an OS's first use runs
  /// _ON whatever _STA says, as Linux's does.)
  public mutating func setPower<H: ACPIHost>(_ resource: Int, on: Bool, checkStatus: Bool = true, host: H)
    throws(ACPIError) -> Bool
  {
    guard case .powerResource = nodes[resource].object else { throw ACPIError.typeMismatch }
    if checkStatus, let s = try childValue(resource, "_STA", host: host)?.integer, (s & 1 != 0) == on { return false }
    guard let method = child(resource, NameSeg.make(on ? "_ON_" : "_OFF")) else { throw ACPIError.notFound }
    _ = try evaluate(method, host: host)
    return true
  }
}
