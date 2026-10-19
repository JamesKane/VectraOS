// SPDX-License-Identifier: BSD-3-Clause

// CFF outlines (OpenType 1.9's `CFF ` table; Adobe's Compact Font Format,
// Technical Note #5176, and Type 2 Charstrings, #5177): the INDEX and DICT
// structures, the Top and Private DICTs (CID fonts' FDArray and FDSelect
// too), and a Type 2 charstring interpreter that turns a glyph's program
// into cubic contours. Hints are read and skipped (they only count stems,
// for hintmask's bytes); the font matrix is the usual 1/1000-a-unit, so
// coordinates are font units. `seac`-style accented endchar and CFF2
// (variable fonts) are stubs (text/README.md).

struct CFF: Sendable {
  /// An INDEX: its items' bytes.
  struct Index: Sendable {
    let items: [Bytes]

    /// The INDEX at `offset`, and the offset just past it.
    static func read(_ b: Bytes, _ offset: Int) throws(FontError) -> (Index, Int) {
      let count = Int(try b.u16(offset))
      guard count > 0 else { return (Index(items: []), offset + 2) }
      let offSize = Int(try b.u8(offset + 2))
      guard (1...4).contains(offSize) else { throw .malformed("CFF INDEX's offSize") }
      let offsets = offset + 3
      let data = offsets + (count + 1) * offSize - 1  // offsets count from 1
      var items: [Bytes] = []
      var previous = Int(try b.uint(offsets, size: offSize))
      for i in 1...count {
        let next = Int(try b.uint(offsets + i * offSize, size: offSize))
        guard next >= previous else { throw .malformed("CFF INDEX's offsets go backwards") }
        items.append(try b.slice(data + previous, next - previous, "CFF INDEX item"))
        previous = next
      }
      return (Index(items: items), data + previous)
    }

    var count: Int { items.count }

    /// The subroutine bias (Type 2 Charstrings §4.7).
    var bias: Int { count < 1240 ? 107 : count < 33900 ? 1131 : 32768 }
  }

  /// A DICT's operators and their operands (escaped operators as 1200 + n).
  static func dict(_ b: Bytes) throws(FontError) -> [(op: Int, operands: [Double])] {
    var out: [(op: Int, operands: [Double])] = []
    var operands: [Double] = []
    var i = 0
    while i < b.count {
      let b0 = Int(try b.u8(i))
      switch b0 {
      case 0...21:
        var op = b0
        i += 1
        if b0 == 12 {
          op = 1200 + Int(try b.u8(i))
          i += 1
        }
        out.append((op, operands))
        operands = []
      case 28:
        operands.append(Double(try b.i16(i + 1)))
        i += 3
      case 29:
        operands.append(Double(try b.i32(i + 1)))
        i += 5
      case 30:
        // A real: nibbles, 0-9 digits, a point, exponents, a minus, ended by f.
        var text = ""
        i += 1
        var done = false
        while !done {
          let byte = try b.u8(i)
          i += 1
          for nibble in [byte >> 4, byte & 0xF] {
            switch nibble {
            case 0...9: text += String(nibble)
            case 0xA: text += "."
            case 0xB: text += "e"
            case 0xC: text += "e-"
            case 0xE: text += "-"
            case 0xF: done = true
            default: break
            }
            if done { break }
          }
        }
        operands.append(CFF.parseReal(text))
      case 32...246:
        operands.append(Double(b0 - 139))
        i += 1
      case 247...250:
        operands.append(Double((b0 - 247) * 256 + Int(try b.u8(i + 1)) + 108))
        i += 2
      case 251...254:
        operands.append(Double(-(b0 - 251) * 256 - Int(try b.u8(i + 1)) - 108))
        i += 2
      default:
        throw .malformed("a CFF DICT byte \(b0)")
      }
    }
    return out
  }

  /// A real number's text (digits, a point, an exponent), parsed by hand:
  /// Embedded Swift has no Double(String).
  static func parseReal(_ text: String) -> Double {
    var mantissa = 0.0, scale = 1.0, exponent = 0, negative = false, exponentNegative = false
    var inFraction = false, inExponent = false
    var chars = Array(text.utf8)
    if chars.first == 0x2D {  // -
      negative = true
      chars.removeFirst()
    }
    var i = 0
    while i < chars.count {
      let c = chars[i]
      if c == 0x2E {
        inFraction = true
      } else if c == 0x65 {
        inExponent = true
        if i + 1 < chars.count && chars[i + 1] == 0x2D {
          exponentNegative = true
          i += 1
        }
      } else if c >= 0x30 && c <= 0x39 {
        let d = Double(c - 0x30)
        if inExponent {
          exponent = exponent * 10 + Int(c - 0x30)
        } else if inFraction {
          scale /= 10
          mantissa += d * scale
        } else {
          mantissa = mantissa * 10 + d
        }
      }
      i += 1
    }
    var v = mantissa
    for _ in 0..<exponent { v = exponentNegative ? v / 10 : v * 10 }
    return negative ? -v : v
  }

  /// A Private DICT's subroutines and widths.
  struct Private: Sendable {
    var subrs: Index
    var defaultWidth: Double
    var nominalWidth: Double
  }

  let charStrings: Index
  let globalSubrs: Index
  /// One Private DICT, or (a CID font) one a font DICT, and each glyph's.
  let privates: [Private]
  let fdSelect: [UInt8]

  init(_ b: Bytes, glyphCount: Int) throws(FontError) {
    guard try b.u8(0) == 1 else { throw .malformed("CFF's major version (CFF2 is a stub)") }
    let headerSize = Int(try b.u8(2))
    let (_, afterNames) = try Index.read(b, headerSize)
    let (topDicts, afterTop) = try Index.read(b, afterNames)
    let (_, afterStrings) = try Index.read(b, afterTop)
    (globalSubrs, _) = try Index.read(b, afterStrings)
    guard let topBytes = topDicts.items.first else { throw .malformed("CFF has no Top DICT") }
    let top = try CFF.dict(topBytes)
    func operand(_ op: Int, _ i: Int = 0) -> Double? {
      guard let e = top.last(where: { $0.op == op }), i < e.operands.count else { return nil }
      return e.operands[i]
    }
    guard (operand(1206) ?? 2) == 2 else { throw .malformed("CFF CharstringType isn't 2") }
    guard let charStringsOffset = operand(17) else { throw .malformed("CFF has no CharStrings") }
    (charStrings, _) = try Index.read(b, Int(charStringsOffset))
    guard charStrings.count >= glyphCount else { throw .malformed("CFF has fewer charstrings than glyphs") }

    func readPrivate(_ dictOperands: [(op: Int, operands: [Double])]) throws(FontError) -> Private {
      guard let p = dictOperands.last(where: { $0.op == 18 }), p.operands.count == 2 else {
        return Private(subrs: Index(items: []), defaultWidth: 0, nominalWidth: 0)
      }
      let size = Int(p.operands[0]), offset = Int(p.operands[1])
      let dict = try CFF.dict(try b.slice(offset, size, "CFF Private DICT"))
      func value(_ op: Int) -> Double? { dict.last(where: { $0.op == op })?.operands.first }
      var subrs = Index(items: [])
      if let s = value(19) { (subrs, _) = try Index.read(b, offset + Int(s)) }
      return Private(subrs: subrs, defaultWidth: value(20) ?? 0, nominalWidth: value(21) ?? 0)
    }

    if top.contains(where: { $0.op == 1230 }) {  // ROS: a CID-keyed font
      guard let fdArrayOffset = operand(1236), let fdSelectOffset = operand(1237) else {
        throw .malformed("a CID CFF without FDArray or FDSelect")
      }
      let (fdArray, _) = try Index.read(b, Int(fdArrayOffset))
      var privates: [Private] = []
      for fd in fdArray.items { privates.append(try readPrivate(try CFF.dict(fd))) }
      self.privates = privates
      // FDSelect: format 0 (a byte a glyph) or 3 (ranges).
      let s = Int(fdSelectOffset)
      var select = [UInt8](repeating: 0, count: glyphCount)
      switch try b.u8(s) {
      case 0:
        for g in 0..<glyphCount { select[g] = try b.u8(s + 1 + g) }
      case 3:
        let ranges = Int(try b.u16(s + 1))
        for r in 0..<ranges {
          let first = Int(try b.u16(s + 3 + 3 * r)), fd = try b.u8(s + 5 + 3 * r)
          let next = Int(try b.u16(s + 6 + 3 * r))
          for g in first..<min(next, glyphCount) where g >= 0 { select[g] = fd }
        }
      default:
        throw .malformed("CFF FDSelect's format")
      }
      guard select.allSatisfy({ Int($0) < privates.count }) else { throw .malformed("CFF FDSelect past the FDArray") }
      fdSelect = select
    } else {
      privates = [try readPrivate(top)]
      fdSelect = []
    }
  }

  func outline(_ glyph: Int) throws(FontError) -> Outline {
    let p = privates[fdSelect.isEmpty ? 0 : Int(fdSelect[glyph])]
    var machine = Charstring(globalSubrs: globalSubrs, localSubrs: p.subrs)
    try machine.run(charStrings.items[glyph], depth: 0)
    machine.closeContour()
    return machine.outline
  }
}

/// The Type 2 charstring interpreter (Technical Note #5177).
struct Charstring {
  /// A square root without libm (tier 0 links none): Newton's method from
  /// a power of two near it, to within a few ulps; 0 for what isn't
  /// positive (CFF leaves a negative's root undefined).
  static func squareRoot(_ v: Double) -> Double {
    guard v > 0, v.isFinite else { return 0 }
    var x = 1.0
    while x * x < v { x *= 2 }
    while x * x > 4 * v { x /= 2 }
    for _ in 0..<8 { x = 0.5 * (x + v / x) }
    return x
  }

  let globalSubrs: CFF.Index
  let localSubrs: CFF.Index
  var stack: [Double] = []
  var x = 0.0, y = 0.0
  var outline = Outline()
  var current: Contour?
  var stems = 0
  /// Whether the width (an extra first operand) has been looked for.
  var widthSeen = false
  var ended = false
  var transient = [Double](repeating: 0, count: 32)

  init(globalSubrs: CFF.Index, localSubrs: CFF.Index) {
    self.globalSubrs = globalSubrs
    self.localSubrs = localSubrs
  }

  mutating func closeContour() {
    if let c = current {
      var c = c
      if case .line(let e) = c.segments.last, e == c.start { c.segments.removeLast() }
      outline.contours.append(c)
    }
    current = nil
  }

  mutating func moveTo(_ dx: Double, _ dy: Double) {
    closeContour()
    x += dx
    y += dy
    current = Contour(start: Point(x, y), segments: [])
  }

  /// A line; one that doesn't move is dropped, as FreeType's CFF decoder
  /// drops it.
  mutating func lineTo(_ dx: Double, _ dy: Double) {
    if dx == 0 && dy == 0 { return }
    if current == nil { current = Contour(start: Point(x, y), segments: []) }
    x += dx
    y += dy
    current!.segments.append(.line(Point(x, y)))
  }

  mutating func curveTo(_ dxa: Double, _ dya: Double, _ dxb: Double, _ dyb: Double, _ dxc: Double, _ dyc: Double) {
    if current == nil { current = Contour(start: Point(x, y), segments: []) }
    let a = Point(x + dxa, y + dya)
    let b = Point(a.x + dxb, a.y + dyb)
    x = b.x + dxc
    y = b.y + dyc
    current!.segments.append(.cubic(a, b, Point(x, y)))
  }

  /// The width, if this stack-clearing operator has one more operand than
  /// it takes (`expected` of them, or an even count if 0... for stems).
  mutating func dropWidth(odd: Bool) {
    if !widthSeen {
      widthSeen = true
      if odd && !stack.isEmpty { stack.removeFirst() }
    }
  }

  mutating func run(_ program: Bytes, depth: Int) throws(FontError) {
    guard depth < 11 else { throw .malformed("charstring subroutines nested too deep") }
    var i = 0
    while i < program.count && !ended {
      let b0 = Int(try program.u8(i))
      i += 1
      switch b0 {
      case 32...246: stack.append(Double(b0 - 139))
      case 247...250:
        stack.append(Double((b0 - 247) * 256 + Int(try program.u8(i)) + 108))
        i += 1
      case 251...254:
        stack.append(Double(-(b0 - 251) * 256 - Int(try program.u8(i)) - 108))
        i += 1
      case 28:
        stack.append(Double(try program.i16(i)))
        i += 2
      case 255:
        stack.append(Double(try program.i32(i)) / 65536)
        i += 4
      case 1, 3, 18, 23:  // hstem, vstem, hstemhm, vstemhm
        dropWidth(odd: stack.count % 2 == 1)
        stems += stack.count / 2
        stack = []
      case 19, 20:  // hintmask, cntrmask: implicit vstems first
        dropWidth(odd: stack.count % 2 == 1)
        stems += stack.count / 2
        stack = []
        i += (stems + 7) / 8
      case 21:  // rmoveto
        dropWidth(odd: stack.count > 2)
        guard stack.count >= 2 else { throw .malformed("rmoveto's operands") }
        moveTo(stack[0], stack[1])
        stack = []
      case 22:  // hmoveto
        dropWidth(odd: stack.count > 1)
        guard stack.count >= 1 else { throw .malformed("hmoveto's operands") }
        moveTo(stack[0], 0)
        stack = []
      case 4:  // vmoveto
        dropWidth(odd: stack.count > 1)
        guard stack.count >= 1 else { throw .malformed("vmoveto's operands") }
        moveTo(0, stack[0])
        stack = []
      case 5:  // rlineto
        var k = 0
        while k + 1 < stack.count {
          lineTo(stack[k], stack[k + 1])
          k += 2
        }
        stack = []
      case 6, 7:  // hlineto, vlineto: alternating
        var horizontal = b0 == 6
        for v in stack {
          if horizontal { lineTo(v, 0) } else { lineTo(0, v) }
          horizontal.toggle()
        }
        stack = []
      case 8:  // rrcurveto
        var k = 0
        while k + 5 < stack.count {
          curveTo(stack[k], stack[k + 1], stack[k + 2], stack[k + 3], stack[k + 4], stack[k + 5])
          k += 6
        }
        stack = []
      case 24:  // rcurveline
        var k = 0
        while k + 7 < stack.count {
          curveTo(stack[k], stack[k + 1], stack[k + 2], stack[k + 3], stack[k + 4], stack[k + 5])
          k += 6
        }
        if k + 1 < stack.count { lineTo(stack[k], stack[k + 1]) }
        stack = []
      case 25:  // rlinecurve
        var k = 0
        while k + 7 < stack.count {
          lineTo(stack[k], stack[k + 1])
          k += 2
        }
        if k + 5 < stack.count { curveTo(stack[k], stack[k + 1], stack[k + 2], stack[k + 3], stack[k + 4], stack[k + 5]) }
        stack = []
      case 26:  // vvcurveto: dx1? {dya dxb dyb dyc}+
        var k = 0
        var dx1 = 0.0
        if stack.count % 4 == 1 {
          dx1 = stack[0]
          k = 1
        }
        while k + 3 < stack.count {
          curveTo(dx1, stack[k], stack[k + 1], stack[k + 2], 0, stack[k + 3])
          dx1 = 0
          k += 4
        }
        stack = []
      case 27:  // hhcurveto: dy1? {dxa dxb dyb dxc}+
        var k = 0
        var dy1 = 0.0
        if stack.count % 4 == 1 {
          dy1 = stack[0]
          k = 1
        }
        while k + 3 < stack.count {
          curveTo(stack[k], dy1, stack[k + 1], stack[k + 2], stack[k + 3], 0)
          dy1 = 0
          k += 4
        }
        stack = []
      case 30, 31:  // vhcurveto, hvcurveto: alternating, a last df optional
        var horizontal = b0 == 31
        var k = 0
        while k + 3 < stack.count {
          let last = stack.count - k == 5 ? stack[k + 4] : 0
          if horizontal {
            curveTo(stack[k], 0, stack[k + 1], stack[k + 2], last, stack[k + 3])
          } else {
            curveTo(0, stack[k], stack[k + 1], stack[k + 2], stack[k + 3], last)
          }
          horizontal.toggle()
          k += 4
        }
        stack = []
      case 10, 29:  // callsubr, callgsubr
        guard let n = stack.popLast() else { throw .malformed("a call with no subroutine") }
        let subrs = b0 == 10 ? localSubrs : globalSubrs
        let index = Int(n) + subrs.bias
        guard index >= 0, index < subrs.count else { throw .malformed("a subroutine past the INDEX") }
        try run(subrs.items[index], depth: depth + 1)
      case 11:  // return
        return
      case 14:  // endchar
        dropWidth(odd: stack.count == 1 || stack.count == 5)
        if stack.count >= 4 { throw .unsupported("CFF's seac (accented endchar)") }
        closeContour()
        ended = true
        stack = []
      case 12:
        let op = Int(try program.u8(i))
        i += 1
        try escape(op)
      default:
        throw .malformed("a charstring operator \(b0)")
      }
    }
  }

  /// The escaped operators: flex, and arithmetic (rare in fonts).
  mutating func escape(_ op: Int) throws(FontError) {
    let s = stack
    switch op {
    case 35:  // flex: two curves, and a depth
      guard s.count >= 12 else { throw .malformed("flex's operands") }
      curveTo(s[0], s[1], s[2], s[3], s[4], s[5])
      curveTo(s[6], s[7], s[8], s[9], s[10], s[11])
    case 34:  // hflex
      guard s.count >= 7 else { throw .malformed("hflex's operands") }
      curveTo(s[0], 0, s[1], s[2], s[3], 0)
      curveTo(s[4], 0, s[5], -s[2], s[6], 0)
    case 36:  // hflex1
      guard s.count >= 9 else { throw .malformed("hflex1's operands") }
      curveTo(s[0], s[1], s[2], s[3], s[4], 0)
      curveTo(s[5], 0, s[6], s[7], s[8], -(s[1] + s[3] + s[7]))
    case 37:  // flex1: the last coordinate on the longer axis
      guard s.count >= 11 else { throw .malformed("flex1's operands") }
      let dx = s[0] + s[2] + s[4] + s[6] + s[8], dy = s[1] + s[3] + s[5] + s[7] + s[9]
      curveTo(s[0], s[1], s[2], s[3], s[4], s[5])
      if abs(dx) > abs(dy) {
        curveTo(s[6], s[7], s[8], s[9], s[10], -dy)
      } else {
        curveTo(s[6], s[7], s[8], s[9], -dx, s[10])
      }
    default:
      try arithmetic(op)
      return
    }
    stack = []
  }

  mutating func arithmetic(_ op: Int) throws(FontError) {
    func pop() throws(FontError) -> Double {
      guard let v = stack.popLast() else { throw .malformed("a charstring stack underflow") }
      return v
    }
    switch op {
    case 3:  // and
      let b = try pop(), a = try pop()
      stack.append(a != 0 && b != 0 ? 1 : 0)
    case 4:  // or
      let b = try pop(), a = try pop()
      stack.append(a != 0 || b != 0 ? 1 : 0)
    case 5: stack.append(try pop() == 0 ? 1 : 0)  // not
    case 9: stack.append(abs(try pop()))  // abs
    case 10: let b = try pop(), a = try pop(); stack.append(a + b)  // add
    case 11: let b = try pop(), a = try pop(); stack.append(a - b)  // sub
    case 12: let b = try pop(), a = try pop(); stack.append(b == 0 ? 0 : a / b)  // div
    case 14: stack.append(-(try pop()))  // neg
    case 15: let b = try pop(), a = try pop(); stack.append(a == b ? 1 : 0)  // eq
    case 18: _ = try pop()  // drop
    case 20:  // put
      let index = Int(try pop()), v = try pop()
      if index >= 0 && index < transient.count { transient[index] = v }
    case 21:  // get
      let index = Int(try pop())
      stack.append(index >= 0 && index < transient.count ? transient[index] : 0)
    case 22:  // ifelse
      let v2 = try pop(), v1 = try pop(), s2 = try pop(), s1 = try pop()
      stack.append(v1 <= v2 ? s1 : s2)
    case 23: stack.append(0.5)  // random: a fixed value, so outlines are stable
    case 24: let b = try pop(), a = try pop(); stack.append(a * b)  // mul
    case 26: stack.append(Charstring.squareRoot(try pop()))  // sqrt
    case 27: let a = try pop(); stack.append(a); stack.append(a)  // dup
    case 28: let b = try pop(), a = try pop(); stack.append(b); stack.append(a)  // exch
    case 29:  // index
      let n = Int(try pop())
      let at = stack.count - 1 - max(0, n)
      stack.append(at >= 0 ? stack[at] : 0)
    case 30:  // roll
      let j = Int(try pop()), n = Int(try pop())
      guard n > 0, n <= stack.count else { break }
      var top = Array(stack.suffix(n))
      let shift = ((j % n) + n) % n
      top = Array(top.suffix(shift) + top.prefix(n - shift))
      stack = Array(stack.prefix(stack.count - n)) + top
    default:
      throw .malformed("a charstring operator 12 \(op)")
    }
  }
}
