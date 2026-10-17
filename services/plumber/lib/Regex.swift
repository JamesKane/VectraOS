// SPDX-License-Identifier: BSD-3-Clause

// The router's regular expressions (M6k part k1): Plan 9's
// regexp(6) syntax, compiled to a Pike VM's program (Thompson's
// construction with Pike's captures), so matching is linear in the text:
// literals, `.` (any but a newline), classes `[a-z_]` and `[^...]`, `*`,
// `+`, `?`, alternation `|`, groups `( )` (each capturing: $1...$9),
// anchors `^` and `$`, and `\` before a character for itself. Text is
// Unicode scalars. Tier 0: arrays only.

/// A compiled expression.
public struct Regex: Sendable {
  enum Op: Sendable {
    case char(UInt32)
    case any
    /// Ranges, inclusive; negated or not.
    case set([(UInt32, UInt32)], Bool)
    case split(Int, Int)
    case jump(Int)
    case save(Int)
    case lineStart
    case lineEnd
    case match
  }

  let program: [Op]
  /// Capture groups (not counting the whole match, $0).
  public let groups: Int

  public init?(_ pattern: String) {
    var p = Parser(Array(pattern.unicodeScalars.map { $0.value }))
    guard let node = p.alternation(), p.at == p.text.count else { return nil }
    var c = Compiler()
    c.emit(.save(0))
    c.compile(node)
    c.emit(.save(1))
    c.emit(.match)
    program = c.ops
    groups = p.groups
  }

  /// The whole of `text` matched: each group's text ($0 the whole), nil
  /// for a group that took no part; nil if it doesn't match.
  public func matchWhole(_ text: String) -> [String?]? {
    let t = Array(text.unicodeScalars.map { $0.value })
    guard let slots = run(t, from: 0, anchoredEnd: true) else { return nil }
    return captures(t, slots)
  }

  /// The leftmost match in `text`, as `matchWhole`'s.
  public func search(_ text: String) -> [String?]? {
    let t = Array(text.unicodeScalars.map { $0.value })
    for start in 0...t.count {
      if let slots = run(t, from: start, anchoredEnd: false) { return captures(t, slots) }
    }
    return nil
  }

  func captures(_ t: [UInt32], _ slots: [Int]) -> [String?] {
    (0...groups).map { g in
      let a = slots[2 * g], b = slots[2 * g + 1]
      guard a >= 0, b >= a else { return nil }
      var s = ""
      for v in t[a..<b] { if let u = Unicode.Scalar(v) { s.unicodeScalars.append(u) } }
      return s
    }
  }

  /// Pike's VM from `start`: the first thread (in priority) to match
  /// (at the text's end if `anchoredEnd`) gives its slots.
  func run(_ t: [UInt32], from start: Int, anchoredEnd: Bool) -> [Int]? {
    let n = 2 * (groups + 1)
    var current: [(pc: Int, slots: [Int])] = []
    var matched: [Int]? = nil
    var onList = [Int](repeating: -1, count: program.count)

    func add(_ list: inout [(pc: Int, slots: [Int])], _ pc: Int, _ slots: [Int], _ at: Int, _ generation: Int) {
      if onList[pc] == generation { return }
      onList[pc] = generation
      switch program[pc] {
      case .jump(let x): add(&list, x, slots, at, generation)
      case .split(let x, let y):
        add(&list, x, slots, at, generation)
        add(&list, y, slots, at, generation)
      case .save(let k):
        var s = slots
        s[k] = at
        add(&list, pc + 1, s, at, generation)
      case .lineStart:
        if at == 0 || t[at - 1] == 10 { add(&list, pc + 1, slots, at, generation) }
      case .lineEnd:
        if at == t.count || t[at] == 10 { add(&list, pc + 1, slots, at, generation) }
      default: list.append((pc, slots))
      }
    }

    add(&current, 0, [Int](repeating: -1, count: n), start, start)
    var at = start
    while true {
      var next: [(pc: Int, slots: [Int])] = []
      let c: UInt32? = at < t.count ? t[at] : nil
      for th in current {
        switch program[th.pc] {
        case .match:
          if !anchoredEnd || at == t.count {
            matched = th.slots
            // Lower-priority threads are cut off.
            current = []
          }
        case .char(let x):
          if c == x { add(&next, th.pc + 1, th.slots, at + 1, at + 1) }
        case .any:
          if let c, c != 10 { add(&next, th.pc + 1, th.slots, at + 1, at + 1) }
        case .set(let ranges, let negated):
          if let c {
            var inside = false
            for r in ranges where c >= r.0 && c <= r.1 { inside = true }
            if inside != negated { add(&next, th.pc + 1, th.slots, at + 1, at + 1) }
          }
        default: break
        }
        if current.isEmpty { break }
      }
      if next.isEmpty || at >= t.count { return matched }
      current = next
      at += 1
    }
  }
}

/// The parse: an expression's tree.
indirect enum ReNode {
  case char(UInt32)
  case any
  case set([(UInt32, UInt32)], Bool)
  case concat([ReNode])
  case alt(ReNode, ReNode)
  case star(ReNode)
  case plus(ReNode)
  case quest(ReNode)
  case group(Int, ReNode)
  case empty
  case lineStart
  case lineEnd
}

struct Parser {
  let text: [UInt32]
  var at = 0
  var groups = 0
  init(_ t: [UInt32]) { text = t }

  var peek: UInt32? { at < text.count ? text[at] : nil }

  mutating func alternation() -> ReNode? {
    guard var left = concatenation() else { return nil }
    while peek == 0x7C {  // |
      at += 1
      guard let right = concatenation() else { return nil }
      left = .alt(left, right)
    }
    return left
  }

  mutating func concatenation() -> ReNode? {
    var parts: [ReNode] = []
    while let c = peek, c != 0x7C, c != 0x29 {  // | )
      guard var atom = atom() else { return nil }
      while let q = peek, q == 0x2A || q == 0x2B || q == 0x3F {  // * + ?
        at += 1
        atom = q == 0x2A ? .star(atom) : q == 0x2B ? .plus(atom) : .quest(atom)
      }
      parts.append(atom)
    }
    return parts.isEmpty ? .empty : parts.count == 1 ? parts[0] : .concat(parts)
  }

  mutating func atom() -> ReNode? {
    guard let c = peek else { return nil }
    at += 1
    switch c {
    case 0x28:  // (
      groups += 1
      let g = groups
      guard let inner = alternation(), peek == 0x29 else { return nil }
      at += 1
      return .group(g, inner)
    case 0x2E: return .any  // .
    case 0x5E: return .lineStart  // ^
    case 0x24: return .lineEnd  // $
    case 0x5B: return set()  // [
    case 0x5C:  // \
      guard let e = peek else { return nil }
      at += 1
      return .char(e == 0x6E ? 10 : e == 0x74 ? 9 : e)
    case 0x2A, 0x2B, 0x3F: return nil  // a repeat with nothing before it
    default: return .char(c)
    }
  }

  mutating func set() -> ReNode? {
    var negated = false
    if peek == 0x5E {
      negated = true
      at += 1
    }
    var ranges: [(UInt32, UInt32)] = []
    var first = true
    while let c = peek, c != 0x5D || first {  // ]
      first = false
      at += 1
      var lo = c
      if lo == 0x5C, let e = peek {
        lo = e == 0x6E ? 10 : e == 0x74 ? 9 : e
        at += 1
      }
      if peek == 0x2D, at + 1 < text.count, text[at + 1] != 0x5D {  // a-z
        at += 1
        var hi = text[at]
        at += 1
        if hi == 0x5C, let e = peek {
          hi = e
          at += 1
        }
        ranges.append((lo, hi))
      } else {
        ranges.append((lo, lo))
      }
    }
    guard peek == 0x5D else { return nil }
    at += 1
    return .set(ranges, negated)
  }
}

struct Compiler {
  var ops: [Regex.Op] = []

  mutating func emit(_ op: Regex.Op) { ops.append(op) }

  mutating func compile(_ n: ReNode) {
    switch n {
    case .char(let c): emit(.char(c))
    case .any: emit(.any)
    case .set(let r, let neg): emit(.set(r, neg))
    case .lineStart: emit(.lineStart)
    case .lineEnd: emit(.lineEnd)
    case .empty: break
    case .concat(let parts): for p in parts { compile(p) }
    case .group(let g, let inner):
      emit(.save(2 * g))
      compile(inner)
      emit(.save(2 * g + 1))
    case .alt(let a, let b):
      let split = ops.count
      emit(.split(split + 1, 0))
      compile(a)
      let jump = ops.count
      emit(.jump(0))
      ops[split] = .split(split + 1, ops.count)
      compile(b)
      ops[jump] = .jump(ops.count)
    case .star(let a):
      let split = ops.count
      emit(.split(split + 1, 0))
      compile(a)
      emit(.jump(split))
      ops[split] = .split(split + 1, ops.count)
    case .plus(let a):
      let start = ops.count
      compile(a)
      emit(.split(start, ops.count + 1))
    case .quest(let a):
      let split = ops.count
      emit(.split(split + 1, 0))
      compile(a)
      ops[split] = .split(split + 1, ops.count)
    }
  }
}
