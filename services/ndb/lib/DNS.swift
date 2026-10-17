// SPDX-License-Identifier: BSD-3-Clause

// /net/dns, as Plan 9's dns(8) serves it: a channel writes `name type`
// and reads the records, one a read, `name type<TAB>value`; `!name type`
// reads them as ndb pairs (`dom=name ip=10.0.2.2`), as cs asks. A name
// with a final dot is rooted (the dot dropped); an address asked for its
// `ptr` is its reverse name. `refresh` drops what is kept. A write fails
// `notFound` when the name doesn't exist or has no such records, `io`
// when no server answered, `invalid` when it isn't a query.

import Net
import Node

public final class DNSService: @unchecked Sendable {
  public let resolver: Resolver
  var file: QueryFile?

  /// Serves `dns` at `path` in `tree`, answered by `resolver`.
  public init(tree: NodeTree, at path: String, resolver: Resolver) {
    self.resolver = resolver
    file = QueryFile(tree: tree, at: path.isEmpty ? "dns" : path + "/dns", maxRequest: 1024,
                     command: { [resolver] text in
                       guard same(text, "refresh") else { return false }
                       resolver.flush()
                       return true
                     }, answer: { [resolver] text in DNSService.answer(resolver, text) })
  }

  /// A query's records, as the file reads them.
  static func answer(_ resolver: Resolver, _ request: String) -> Result<[[UInt8]], NodeError> {
    let bytes = Array(request.utf8)
    guard let space = bytes.firstIndex(of: 0x20) else { return .failure(.invalid) }
    var name = Array(bytes[..<space])
    guard let type = DNSType.parse(String(decoding: bytes[(space + 1)...], as: UTF8.self)) else {
      return .failure(.invalid)
    }
    let pairs = name.first == 0x21  // "!"
    if pairs { name.removeFirst() }
    if name.count > 1, name.last == 0x2E { name.removeLast() }  // rooted
    var text = String(decoding: name, as: UTF8.self)
    if type == DNSType.ptr, let ip = parseIP(text) { text = reverseName(ip) }
    guard !text.isEmpty else { return .failure(.invalid) }
    switch resolver.lookup(text, type) {
    case .success(let records): return .success(records.map { Array((pairs ? $0.pairs : $0.text).utf8) })
    case .failure(.failed): return .failure(.io)
    case .failure: return .failure(.notFound)
    }
  }
}
