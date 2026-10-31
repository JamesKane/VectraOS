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
  public static func text(_ links: [DeviceLink], service: (String) -> String?) -> String {
    links.map { l in
      var named = l
      named.provider = l.provider.isEmpty ? "" : service(l.provider) ?? ""
      // The node, which `summary` gives where it isn't the provider's.
      named.target = same(l.target, l.provider) ? named.provider : l.target
      return named.summary + "\n"
    }.joined()
  }
}
