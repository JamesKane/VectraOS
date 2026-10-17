// SPDX-License-Identifier: BSD-3-Clause

// The query fuzzer (filesystem.md §9): random queries over a random library
// answered three ways, which must agree:
//   - through the indices (when the planner can),
//   - by a full scan,
//   - by a reference evaluator here, which reads values only through stat,
//     attribute and list, and implements the comparisons itself.
// It's the test for the class of bug where Haiku's `MAIL:to=*` returned 202
// of 17,000 files. Live queries run alongside, kept up to date as the
// library changes, and must equal the reference after every change.

import Taisce
import Testing

struct QueryFuzz: ~Copyable {
  var rng: SplitMix
  var fs: FileSystem<MemoryDevice>
  var now: UInt64 = 10
  var files: [UInt64] = []
  var indexed = 0, scannedOnly = 0

  static let tags = ["Rock", "rock", "ROCK", "Jazz", "jazz fusion", "Folk", "folk-rock", "Blues"]
  static let words = ["alpha", "beta", "Gamma", "delta", "alphabet", "bet"]

  init(seed: UInt64) throws {
    rng = SplitMix(state: seed)
    fs = try FileSystem.format(MemoryDevice(blocks: 32_768), label: [], uuid: Array(1...16), now: 1)
  }

  /// Indices, three directories, and 200 files with attributes.
  mutating func populate() throws {
    try fs.declareIndex(n("user:tag"), .string, collation: .caseFolded)
    try fs.declareIndex(n("user:s"), .string)
    try fs.declareIndex(n("user:n"), .int64)
    try fs.declareIndex(n("user:w"), .double)
    try fs.declareIndex(n("user:t"), .time)
    while try !fs.backfill(budget: 50) {}
    let dirs = [root, try fs.create(root, n("a"), .directory, mode: 0o755, now: 2),
                try fs.create(root, n("b"), .directory, mode: 0o755, now: 2)]
    for i in 0..<200 {
      let name = Self.words[rng.below(Self.words.count)] + "\(i % 17)" + [".mp3", ".txt", ""][rng.below(3)]
      let dir = dirs[rng.below(3)]
      guard let f = try? fs.create(dir, n(name), .file, mode: 0o644, now: 3) else { continue }
      files.append(f)
      try randomize(f)
    }
  }

  mutating func randomize(_ f: UInt64) throws {
    now += 1
    if rng.below(3) == 0 { try fs.write(f, offset: UInt64(rng.below(9000)), [1], now: now) }
    func maybe(_ name: String, _ value: () -> AttributeValue) throws {
      switch rng.below(5) {
      case 0: try fs.removeAttribute(f, n(name), now: now)
      case 1: break
      default: try fs.setAttribute(f, n(name), value(), now: now)
      }
    }
    try maybe("user:tag") { .string(n(Self.tags[rng.below(Self.tags.count)])) }
    try maybe("user:s") { .string(n(Self.words[rng.below(Self.words.count)])) }
    try maybe("user:n") { rng.below(10) == 0 ? .string(n("7")) : .int64(Int64(rng.below(11)) - 5) }  // sometimes the wrong type
    try maybe("user:w") { .double(Double(rng.below(9)) / 2 - 2) }
    try maybe("user:t") { .time(Int64(rng.below(5)) * 86_400_000_000_000) }
    try maybe("user:u") { .uint64(UInt64(rng.below(6))) }  // no index on this one
    try maybe("sys:type") { .type(n(["audio/mpeg", "text/plain"][rng.below(2)])) }
  }

  // MARK: Queries

  mutating func literal(for attribute: String) -> String {
    switch attribute {
    case "user:tag", "user:s", "name", "sys:type":
      if rng.below(4) == 0 {  // a pattern, with or without a literal prefix
        let w = Self.words[rng.below(Self.words.count)]
        return ["\"\(w.prefix(3))*\"", "\"*\(w.suffix(2))*\"", "\"?\(w.dropFirst())*\"", "\"*\""][rng.below(4)]
      }
      let pool = attribute == "user:tag" ? Self.tags : attribute == "sys:type" ? ["audio/mpeg", "text/plain"] : Self.words
      return "\"\(pool[rng.below(pool.count)])\""
    case "user:w": return rng.below(2) == 0 ? "\(Double(rng.below(9)) / 2 - 2)" : "\(rng.below(5) - 2)"
    case "user:t": return "1970-01-0\(1 + rng.below(5))"
    case "size": return ["0", "1", "4KiB", "8191", "9000", "1MB"][rng.below(6)]
    case "mtime": return "\(rng.below(400))"
    default: return "\(rng.below(11) - 5)"
    }
  }

  mutating func term() -> String {
    let attrs = ["user:tag", "user:s", "user:n", "user:w", "user:t", "user:u", "sys:type", "name", "size", "mtime"]
    let a = attrs[rng.below(attrs.count)]
    switch rng.below(10) {
    case 0: return "\(a) in \(literal(for: a))\(rng.below(2) == 0 ? "..<" : "...")\(literal(for: a))"
    case 1: return "\(a) in [\(literal(for: a)), \(literal(for: a))]"
    default:
      let op = ["==", "==", "!=", "<", "<=", ">", ">=", "~=", "~="][rng.below(9)]
      return "\(a) \(op) \(literal(for: a))"
    }
  }

  mutating func expr(_ depth: Int) -> String {
    guard depth > 0, rng.below(3) != 0 else { return term() }
    switch rng.below(5) {
    case 0: return "!(\(expr(depth - 1)))"
    case 1, 2: return "(\(expr(depth - 1)) && \(expr(depth - 1)))"
    default: return "(\(expr(depth - 1)) || \(expr(depth - 1)))"
    }
  }

  // MARK: The reference

  /// A node's values, read without the query code.
  mutating func values(_ ino: UInt64, _ a: String) throws -> [AttributeValue] {
    switch a {
    case "name": return names[ino, default: []].map { .string($0) }
    case "size": return [.uint64(try fs.stat(ino).size)]
    case "mtime": return [.time(Int64(try fs.stat(ino).mtime))]
    default: return try fs.attribute(ino, n(a)).map { [$0] } ?? []
    }
  }

  var names: [UInt64: [[UInt8]]] = [:]

  /// Every node and its names, walked from the root.
  mutating func walk() throws -> [UInt64] {
    names = [:]
    var all: [UInt64] = [root]
    var stack = [root]
    while let d = stack.popLast() {
      for (e, _) in try fs.list(d) {
        if names[e.ino] == nil { all.append(e.ino) }
        names[e.ino, default: []].append(e.name)
        if e.type == .directory { stack.append(e.ino) }
      }
    }
    return all.sorted()
  }

  func number(_ v: AttributeValue) -> Double? {
    switch v {
    case .int64(let x), .time(let x): Double(x)
    case .uint64(let x), .ref(let x): Double(x)
    case .double(let x): x
    default: nil
    }
  }
  func number(_ l: QueryLiteral) -> Double? {
    switch l {
    case .int(let x), .time(let x): Double(x)
    case .double(let x): x
    default: nil
    }
  }

  func glob(_ s: [Character], _ p: [Character]) -> Bool {
    guard let first = p.first else { return s.isEmpty }
    if first == "*" { return (0...s.count).contains { glob(Array(s[$0...]), Array(p.dropFirst())) } }
    guard let c = s.first else { return false }
    return (first == "?" || first == c) && glob(Array(s.dropFirst()), Array(p.dropFirst()))
  }

  /// The reference comparison; nil when the types don't compare. Which
  /// pairs compare: numbers with numbers (a time literal only with times,
  /// a reference only with integers), strings with strings, bools with bools.
  func order(_ v: AttributeValue, _ l: QueryLiteral) -> Int? {
    func sign(_ a: Double, _ b: Double) -> Int { a < b ? -1 : a > b ? 1 : 0 }
    switch (v, l) {
    case (.time(let x), .time(let y)): return sign(Double(x), Double(y))
    case (_, .time): return nil
    case (.ref(let x), .int(let y)): return sign(Double(x), Double(y))
    case (.ref, _): return nil
    case (.int64, .int), (.int64, .double), (.uint64, .int), (.uint64, .double), (.double, .int), (.double, .double),
      (.time, .int), (.time, .double):
      return sign(number(v)!, number(l)!)
    case (.string(let s), .string(let t)), (.type(let s), .string(let t)), (.bytes(let s), .string(let t)):
      return s == t ? 0 : s.lexicographicallyPrecedes(t) ? -1 : 1
    case (.bool(let x), .bool(let y)): return x == y ? 0 : x ? 1 : -1
    default: return nil
    }
  }

  func test(_ v: AttributeValue, _ t: QueryTerm) -> Bool {
    switch t.op {
    case .list: return t.values.contains { test(v, QueryTerm(attribute: t.attribute, op: .equal, values: [$0])) }
    case .range(let inclusive):
      guard let lo = order(v, t.values[0]), let hi = order(v, t.values[1]) else { return false }
      return lo >= 0 && (inclusive ? hi <= 0 : hi < 0)
    case .equal, .notEqual, .caseless:
      var equal: Bool
      let caseless = t.op == .caseless
      switch (v, t.values[0]) {
      case (.string(let s), .pattern(let p)), (.type(let s), .pattern(let p)):
        var pattern = ""
        for piece in p {
          switch piece {
          case .text(let x): pattern += String(decoding: x, as: UTF8.self)
          case .one: pattern += "?"
          case .any: pattern += "*"
          }
        }
        let str = String(decoding: s, as: UTF8.self)
        equal = glob(Array(caseless ? str.lowercased() : str), Array(caseless ? pattern.lowercased() : pattern))
      case (.string(let s), .string(let l)), (.type(let s), .string(let l)):
        let a = String(decoding: s, as: UTF8.self), b = String(decoding: l, as: UTF8.self)
        equal = caseless ? a.lowercased() == b.lowercased() : a == b
      default:
        if caseless { return false }
        guard let c = order(v, t.values[0]) else { return false }
        equal = c == 0
      }
      return t.op == .notEqual ? !equal : equal
    case .less: return order(v, t.values[0]).map { $0 < 0 } ?? false
    case .lessOrEqual: return order(v, t.values[0]).map { $0 <= 0 } ?? false
    case .greater: return order(v, t.values[0]).map { $0 > 0 } ?? false
    case .greaterOrEqual: return order(v, t.values[0]).map { $0 >= 0 } ?? false
    }
  }

  mutating func reference(_ e: QueryExpr, _ ino: UInt64) throws -> Bool {
    switch e {
    case .and(let ps):
      for p in ps where try !reference(p, ino) { return false }
      return true
    case .or(let ps):
      for p in ps where try reference(p, ino) { return true }
      return false
    case .not(let p): return try !reference(p, ino)
    case .term(let t):
      for v in try values(ino, String(decoding: t.attribute, as: UTF8.self)) where test(v, t) { return true }
      return false
    }
  }

  mutating func check(_ text: String) throws {
    let query = try Query(n(text))
    var expected: [UInt64] = []
    for ino in try walk() where try reference(query.expr, ino) { expected.append(ino) }
    let scanned = try fs.query(n(text), scan: true)
    #expect(scanned.sorted() == expected, "scan: \(text)")
    do {
      let viaIndex = try fs.query(n(text))
      indexed += 1
      #expect(viaIndex.sorted() == expected, "index: \(text)")
      if query.orderBy != nil { #expect(viaIndex == scanned, "order: \(text)") }
    } catch TaisceError.needsIndex {
      scannedOnly += 1
    }
  }
}

@Test(arguments: [UInt64(301), 302, 303])
func indexedQueriesAgreeWithAScanAndTheReference(seed: UInt64) throws {
  var f = try QueryFuzz(seed: seed)
  try f.populate()
  // Live queries, kept up to date across the changes.
  var lives: [(String, LiveQuery)] = []
  for text in [#"user:tag ~= "rock""#, #"user:n > 0 || size > 4KiB"#, #"name == "alpha*" && user:w <= 0"#] {
    lives.append((text, try f.fs.live(n(text))))
  }
  for round in 0..<12 {
    for _ in 0..<40 {
      var text = f.expr(3)
      if f.rng.below(8) == 0 { text += " order by \(["size", "user:n", "name", "user:tag"][f.rng.below(4)])\(f.rng.below(2) == 0 ? " desc" : "")" }
      try f.check(text)
    }
    // Change some of the library; the live queries follow.
    for _ in 0..<20 {
      let file = f.files[f.rng.below(f.files.count)]
      switch f.rng.below(12) {
      case 0:  // a new file, named like the rest
        let name = QueryFuzz.words[f.rng.below(QueryFuzz.words.count)] + "\(f.rng.below(40)).mp3"
        if let made = try? f.fs.create(root, n(name), .file, mode: 0o644, now: f.now) {
          f.files.append(made)
          try f.randomize(made)
        }
      case 1:  // a name removed from the root
        if let e = try f.fs.list(root).first(where: { $0.entry.type == .file })?.entry {
          try f.fs.unlink(root, e.name, now: f.now)
          f.files.removeAll { $0 == e.ino }
        }
      default:
        try f.randomize(file)
      }
    }
    if round == 6 { try f.fs.sync() }
    for i in lives.indices {
      _ = try f.fs.update(&lives[i].1)
      let query = try Query(n(lives[i].0))
      var expected: [UInt64] = []
      for ino in try f.walk() where try f.reference(query.expr, ino) { expected.append(ino) }
      #expect(lives[i].1.results == expected, "live: \(lives[i].0), round \(round)")
    }
  }
  try f.fs.check()
  // The planner must have done real work, not refused everything.
  #expect(f.indexed > 100, "only \(f.indexed) queries went through indices (\(f.scannedOnly) needed scans)")
}
