// SPDX-License-Identifier: BSD-3-Clause

// The provider graph (D154): a device's links (DeviceLink) name the
// devices that provide its clocks, resets, pins, supplies and the rest.
// A provider is a driver that serves a tree. devmgr starts a provider's
// host before its consumers' and mounts the provider's tree in each
// consumer's namespace, at /dev/provider/SERVICE; the consumer's
// /dev/dt/links says which of its links each serves, the specifier's
// cells saying which clock or reset is the consumer's.

import DeviceTreeBus

public enum Links {
  /// The order to start hosts in, given the hosts each one's links name
  /// (`providers[i]`, indices into the same list): each after its
  /// providers, otherwise in the order given. A cycle's hosts start in
  /// the order given, the first of them before its providers.
  public static func order(_ providers: [[Int]]) -> [Int] {
    var started = [Bool](repeating: false, count: providers.count)
    var out: [Int] = []
    while out.count < providers.count {
      let ready = providers.indices.first { i in
        !started[i] && providers[i].allSatisfy { $0 == i || !providers.indices.contains($0) || started[$0] }
      }
      guard let i = ready ?? started.firstIndex(of: false) else { break }
      started[i] = true
      out.append(i)
    }
    return out
  }

  /// A consumer's `links` file: a line a link, `KIND NAME PROVIDER [NODE]
  /// CELLS...` (DeviceLink.summary), the provider named by its host's
  /// service, mounted at /dev/provider/SERVICE, or `-` where none runs.
  /// A loop over static calls, comparing bytes: on arm64 a short String (an
  /// ACPI path) read through a closure came out corrupt (CLAUDE.md).
  public static func text(_ links: [DeviceLink], service: (String) -> String?) -> String {
    var out = ""
    for l in links { out += line(l, service: service) }
    return out
  }

  static func line(_ l: DeviceLink, service: (String) -> String?) -> String {
    let provider = l.provider
    let target = l.target
    var named = l
    named.provider = provider.isEmpty ? "" : service(provider) ?? ""
    // The node, which `summary` gives where it isn't the provider's.
    named.target = sameBytes(target, provider) ? named.provider : target
    return named.summary + "\n"
  }

  static func sameBytes(_ a: String, _ b: String) -> Bool {
    var x: [UInt8] = []
    for c in a.utf8 { x.append(c) }
    var y: [UInt8] = []
    for c in b.utf8 { y.append(c) }
    guard x.count == y.count else { return false }
    var i = 0
    while i < x.count {
      if x[i] != y[i] { return false }
      i += 1
    }
    return true
  }
}
