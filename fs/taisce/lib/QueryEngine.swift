// SPDX-License-Identifier: BSD-3-Clause

import TDUnicode

// Running queries (filesystem.md §6). The planner turns indexable terms
// into key ranges over index trees, which give candidates; every candidate
// is then checked against the whole query with its real values. An index
// only ever narrows the search, so a stale or truncated key can't make a
// wrong answer, only a slower one. A query no index can serve fails, unless
// the caller asks for a scan.

/// A live query's change: each carries the journal `seq` that caused it.
public enum QueryUpdate: Equatable, Sendable {
  case added(UInt64, seq: UInt64)
  case removed(UInt64, seq: UInt64)
  case changed(UInt64, seq: UInt64)
}

/// A query kept up to date from the change journal. Store it (its text,
/// results and `seq`) to resume after a restart.
public struct LiveQuery: Equatable, Sendable {
  public var query: Query
  /// Matching nodes, sorted.
  public var results: [UInt64]
  /// The last journal record applied.
  public var seq: UInt64

  public init(query: Query, results: [UInt64], seq: UInt64) {
    self.query = query
    self.results = results
    self.seq = seq
  }
}

extension FileSystem {
  // MARK: Queries

  /// The nodes matching `text`, ordered and limited as it says. Without
  /// `scan`, at least one index must serve it (`.needsIndex` otherwise).
  public mutating func query(_ text: [UInt8], scan: Bool = false) throws(TaisceError) -> [UInt64] {
    try run(Query(text), scan: scan)
  }

  public mutating func run(_ q: Query, scan: Bool = false) throws(TaisceError) -> [UInt64] {
    let candidates: [UInt64]
    if scan {
      candidates = try allNodes()
    } else {
      guard let planned = try plan(q.expr) else { throw .needsIndex }
      candidates = planned
    }
    var out: [UInt64] = []
    for ino in candidates where try matches(ino, q.expr) { out.append(ino) }
    if let order = q.orderBy {
      var keyed: [(key: [UInt8]?, ino: UInt64)] = []
      for ino in out { keyed.append((try values(ino, order).first.map { IndexKey.encode($0, .exact) }, ino)) }
      keyed.sort { a, b in
        switch (a.key, b.key) {
        case (let x?, let y?): return x != y ? (q.descending ? y.lexicographicallyPrecedes(x) : x.lexicographicallyPrecedes(y)) : a.ino < b.ino
        case (nil, nil): return a.ino < b.ino
        case (nil, _): return false  // nodes without the attribute come last
        case (_, nil): return true
        }
      }
      out = keyed.map { $0.ino }
    }
    if let limit = q.limit, out.count > limit { out = Array(out.prefix(limit)) }
    return out
  }

  /// Every node, in order.
  mutating func allNodes() throws(TaisceError) -> [UInt64] {
    var out: [UInt64] = []
    var from = FSKey.make(0, FSKey.inode)
    while true {
      guard let (key, _) = try engine.scan(FSKey.tree, from: from, limit: 1).first else { return out }
      let ino = FSKey.readU64(key, at: 0)
      if key[8] == FSKey.inode { out.append(ino) }
      from = FSKey.make(ino + 1, FSKey.inode)  // the next node's keys
    }
  }

  // MARK: Evaluating

  /// A node's values for an attribute: its names for `name`, its fields
  /// for `size` and `mtime`, else the attribute (none if it hasn't it).
  mutating func values(_ ino: UInt64, _ attribute: [UInt8]) throws(TaisceError) -> [AttributeValue] {
    guard let inode = try engine.get(FSKey.tree, FSKey.make(ino, FSKey.inode)) else { return [] }
    switch attribute {
    case Array("name".utf8):
      let from = FSKey.make(ino, FSKey.name), to = FSKey.make(ino, FSKey.name + 1)
      return try engine.scan(FSKey.tree, from: from, to: to).map { .string(Array($0.key[17...])) }
    case Array("size".utf8): return [.uint64(try Inode.decode(inode).size)]
    case Array("mtime".utf8): return [.time(Int64(bitPattern: try Inode.decode(inode).mtime))]
    default:
      guard attribute.contains(0x3A), let v = try? self.attribute(ino, attribute) else { return [] }
      return [v]
    }
  }

  mutating func matches(_ ino: UInt64, _ e: QueryExpr) throws(TaisceError) -> Bool {
    switch e {
    case .and(let parts):
      for p in parts where try !matches(ino, p) { return false }
      return true
    case .or(let parts):
      for p in parts where try matches(ino, p) { return true }
      return false
    case .not(let inner): return try !matches(ino, inner)
    case .term(let t):
      // A node with several values (names) matches if any one does.
      for v in try values(ino, t.attribute) where Self.test(v, t) { return true }
      return false
    }
  }

  /// Whether `v` satisfies `t`. Values and literals of different types
  /// never match (and a missing attribute matched nothing above).
  static func test(_ v: AttributeValue, _ t: QueryTerm) -> Bool {
    switch t.op {
    case .list: return t.values.contains { test(v, QueryTerm(attribute: t.attribute, op: .equal, values: [$0])) }
    case .range(let inclusive):
      guard let lo = compare(v, t.values[0]), let hi = compare(v, t.values[1]) else { return false }
      return lo >= 0 && (inclusive ? hi <= 0 : hi < 0)
    case .equal, .notEqual, .caseless:
      let equal: Bool
      switch (v, t.values[0]) {
      case (.string(let s), .pattern(let p)), (.type(let s), .pattern(let p)):
        equal = glob(s, p, caseless: t.op == .caseless)
      case (.string(let s), .string(let l)), (.type(let s), .string(let l)):
        equal = t.op == .caseless ? Text.caselessKey(s) == Text.caselessKey(l) : s == l
      default:
        guard t.op != .caseless, let c = compare(v, t.values[0]) else { return false }
        equal = c == 0
      }
      return t.op == .notEqual ? !equal : equal
    case .less: return compare(v, t.values[0]).map { $0 < 0 } ?? false
    case .lessOrEqual: return compare(v, t.values[0]).map { $0 <= 0 } ?? false
    case .greater: return compare(v, t.values[0]).map { $0 > 0 } ?? false
    case .greaterOrEqual: return compare(v, t.values[0]).map { $0 >= 0 } ?? false
    }
  }

  /// −1, 0 or 1 comparing a value with a literal, or nil if they don't compare.
  static func compare(_ v: AttributeValue, _ l: QueryLiteral) -> Int? {
    func sign<T: Comparable>(_ a: T, _ b: T) -> Int { a < b ? -1 : a > b ? 1 : 0 }
    switch (v, l) {
    case (.string(let s), .string(let t)), (.type(let s), .string(let t)), (.bytes(let s), .string(let t)):
      return s == t ? 0 : s.lexicographicallyPrecedes(t) ? -1 : 1
    case (.int64(let a), .int(let b)), (.time(let a), .time(let b)), (.time(let a), .int(let b)):
      return sign(a, b)
    case (.uint64(let a), .int(let b)), (.ref(let a), .int(let b)):
      return b < 0 ? 1 : sign(a, UInt64(b))
    case (.int64(let a), .double(let b)), (.time(let a), .double(let b)): return sign(Double(a), b)
    case (.uint64(let a), .double(let b)): return sign(Double(a), b)
    case (.double(let a), .int(let b)): return sign(a, Double(b))
    case (.double(let a), .double(let b)): return a.isNaN || b.isNaN ? nil : sign(a, b)
    case (.bool(let a), .bool(let b)): return a == b ? 0 : a ? 1 : -1
    default: return nil
    }
  }

  /// Wildcard matching over scalars: `?` is one, `*` any run.
  static func glob(_ s: [UInt8], _ p: [PatternPiece], caseless: Bool) -> Bool {
    let prepared: ([UInt8]) -> [UInt32] = { bytes in
      let text = caseless ? (Text.caselessKey(bytes) ?? bytes) : bytes
      return UTF8Text.decode(text) ?? []
    }
    let str = prepared(s)
    // The pattern as scalars, with markers for wildcards.
    var pat: [(scalar: UInt32, kind: UInt8)] = []  // kind 0: literal, 1: ?, 2: *
    for piece in p {
      switch piece {
      case .text(let t): for c in prepared(t) { pat.append((c, 0)) }
      case .one: pat.append((0, 1))
      case .any: pat.append((0, 2))
      }
    }
    // Iterative matching with one backtrack point for the last star.
    var i = 0, j = 0, star = -1, mark = 0
    while i < str.count {
      if j < pat.count, pat[j].kind == 1 || (pat[j].kind == 0 && pat[j].scalar == str[i]) {
        i += 1
        j += 1
      } else if j < pat.count, pat[j].kind == 2 {
        star = j
        mark = i
        j += 1
      } else if star >= 0 {
        j = star + 1
        mark += 1
        i = mark
      } else {
        return false
      }
    }
    while j < pat.count, pat[j].kind == 2 { j += 1 }
    return j == pat.count
  }

  // MARK: Planning

  /// Candidates from indices, sorted and unique; nil if the expression
  /// can't be served by any.
  mutating func plan(_ e: QueryExpr) throws(TaisceError) -> [UInt64]? {
    switch e {
    case .term(let t): return try candidates(t)
    case .not: return nil
    case .or(let parts):
      var all: [UInt64] = []
      for p in parts {
        guard let c = try plan(p) else { return nil }
        all += c
      }
      return Self.unique(all)
    case .and(let parts):
      // The smallest set any part gives (the rest are checked per node).
      var best: [UInt64]? = nil
      for p in parts {
        if let c = try plan(p), c.count < (best?.count ?? Int.max) { best = c }
      }
      return best
    }
  }

  static func unique(_ xs: [UInt64]) -> [UInt64] {
    var out: [UInt64] = []
    for x in xs.sorted() where out.last != x { out.append(x) }
    return out
  }

  /// The candidates an index gives for one term, or nil if none can.
  mutating func candidates(_ t: QueryTerm) throws(TaisceError) -> [UInt64]? {
    guard let index = indices.first(where: { $0.name == t.attribute }), !index.building else { return nil }
    var ranges: [(from: [UInt8], to: [UInt8]?)] = []  // to: nil, the end
    let high = [UInt8](repeating: 0xFF, count: 17)  // past any inode (and directory) suffix
    func key(_ l: QueryLiteral) -> [UInt8]? { Self.indexKey(l, index) }
    func exact(_ l: QueryLiteral) -> (from: [UInt8], to: [UInt8]?)? {
      guard let k = key(l) else { return nil }
      return (k, k + high)
    }
    switch t.op {
    case .equal:
      if case .pattern(let p) = t.values[0] {
        guard let r = prefixRange(p, index) else { return nil }
        ranges.append(r)
      } else {
        guard let r = exact(t.values[0]) else { return nil }
        ranges.append(r)  // a caseless index gives a superset; the check narrows it
      }
    case .caseless:
      guard index.collation == .caseFolded else { return nil }
      if case .pattern(let p) = t.values[0] {
        guard let r = prefixRange(p, index) else { return nil }
        ranges.append(r)
      } else {
        guard let r = exact(t.values[0]) else { return nil }
        ranges.append(r)
      }
    case .list:
      for v in t.values {
        guard let r = exact(v) else { return nil }
        ranges.append(r)
      }
    case .notEqual: return nil
    case .less, .lessOrEqual, .greater, .greaterOrEqual, .range:
      // Ordered scans need the index's order to be the value's order.
      guard index.collation == .exact || !Self.isString(index.kind) else { return nil }
      guard let k = key(t.values[0]) else { return nil }
      switch t.op {
      case .less, .lessOrEqual: ranges.append(([], k + high))
      case .greater, .greaterOrEqual: ranges.append((k, nil))
      default:
        guard let k2 = key(t.values[1]) else { return nil }
        ranges.append((k, k2 + high))
      }
    }
    var out: [UInt64] = []
    for r in ranges {
      for (k, _) in try engine.scan(index.tree, from: r.from, to: r.to) {
        out.append(FSKey.readU64(k, at: k.count - (index.tree == Self.nameIndex ? 16 : 8)))
      }
    }
    return Self.unique(out)
  }

  static func isString(_ k: AttributeKind) -> Bool { k == .string || k == .type || k == .bytes }

  /// A literal as this index keys it, widened to its kind; nil if it can't be.
  static func indexKey(_ l: QueryLiteral, _ index: IndexInfo) -> [UInt8]? {
    switch (index.kind, l) {
    case (.string, .string(let s)), (.type, .string(let s)): return index.key(.string(s))
    case (.bytes, .string(let s)): return index.key(.bytes(s))
    case (.int64, .int(let v)): return index.key(.int64(v))
    case (.time, .time(let v)), (.time, .int(let v)): return index.key(.time(v))
    case (.uint64, .int(let v)), (.ref, .int(let v)): return index.key(.uint64(v < 0 ? 0 : UInt64(v)))
    case (.double, .int(let v)): return index.key(.double(Double(v)))
    case (.double, .double(let v)): return index.key(.double(v))
    case (.int64, .double(let d)), (.time, .double(let d)):
      // The integer at or below: ranges built on it include the answer.
      guard d > -9.2e18, d < 9.2e18 else { return nil }
      var i = Int64(d)
      if Double(i) > d { i -= 1 }
      return index.key(.int64(i))
    case (.uint64, .double(let d)):
      guard d < 1.8e19 else { return nil }
      return index.key(.uint64(d <= 0 ? 0 : UInt64(d)))
    case (.bool, .bool(let b)): return index.key(.bool(b))
    default: return nil
    }
  }

  /// The key range holding every string that starts with the pattern's
  /// literal prefix; nil if it starts with a wildcard.
  func prefixRange(_ p: [PatternPiece], _ index: IndexInfo) -> (from: [UInt8], to: [UInt8]?)? {
    guard Self.isString(index.kind), case .text(let t)? = p.first, !t.isEmpty else { return nil }
    let folded = index.collation == .caseFolded ? (Text.caselessKey(t) ?? t) : t
    // The prefix as the index escapes it, without the terminator.
    var prefix = IndexKey.escaped(folded)
    prefix.removeLast(2)
    // Folding can change a prefix's last character once more follows, so
    // back off one character (scalars start at a non-continuation byte).
    if index.collation == .caseFolded {
      while let last = prefix.last, last & 0xC0 == 0x80 { prefix.removeLast() }
      if !prefix.isEmpty { prefix.removeLast() }
    }
    // Everything after the prefix: the prefix with its last byte raised
    // (or to the end, if every byte is 0xFF).
    var upper = prefix
    while let last = upper.last, last == 0xFF { upper.removeLast() }
    guard !upper.isEmpty else { return (prefix, nil) }
    upper[upper.count - 1] += 1
    return (prefix, upper)
  }

  // MARK: Live queries

  /// Starts a live query: its results now, and its place in the journal.
  public mutating func live(_ text: [UInt8], scan: Bool = false) throws(TaisceError) -> LiveQuery {
    let q = try Query(text)
    var unordered = q
    unordered.orderBy = nil
    unordered.limit = nil
    return LiveQuery(query: q, results: try run(unordered, scan: scan).sorted(), seq: nextSeq - 1)
  }

  /// Brings a live query up to date from the journal: every node a record
  /// since its `seq` names is checked again. Notifications come at
  /// in-memory commit; after a crash the journal may not reach the query's
  /// `seq` (.journalTrimmed): run the query again.
  public mutating func update(_ live: inout LiveQuery) throws(TaisceError) -> [QueryUpdate] {
    guard live.seq < nextSeq else { throw .journalTrimmed }
    let records = try journal(after: live.seq)
    if let first = records.first, first.seq != live.seq + 1 { throw .journalTrimmed }
    var out: [QueryUpdate] = []
    for r in records {
      for ino in r.parent != 0 && r.parent != r.ino ? [r.ino, r.parent] : [r.ino] {
        let matching = try matches(ino, live.query.expr)
        let i = live.results.firstIndex(of: ino)
        switch (i, matching) {
        case (nil, true):
          live.results.insert(ino, at: live.results.firstIndex { $0 > ino } ?? live.results.count)
          out.append(.added(ino, seq: r.seq))
        case (let at?, false):
          live.results.remove(at: at)
          out.append(.removed(ino, seq: r.seq))
        case (_?, true):
          if r.ino == ino { out.append(.changed(ino, seq: r.seq)) }
        default: break
        }
      }
      live.seq = r.seq
    }
    return out
  }
}
