// SPDX-License-Identifier: BSD-3-Clause

// The storyboard's icons as data (M6i part 5): the `<symbol>`s of
// docs/design/shell-storyboard.html's icon sheet, read as the SVG subset
// they use, and written as UICore's `IconData` (ui/core/lib/generated/
// Icons.swift): each icon's elements in paint order, each a path in the
// 32-unit view box (transforms applied; arcs and ellipses as cubics; y
// down) with its fill, a horizontal gradient's far end, and its stroke.
//
// Paints are roles, as the sheet's CSS has them: the edge colour
// (`--ic`), the emblem (`--em`, else the edge colour) and the background
// (`--bg0`), each with the percent of it mixed over the background
// (`color-mix(in srgb, var(--ic) 40%, var(--bg0))`). A polygon or an
// ellipse is stroked in the edge colour unless it says otherwise (the
// sheet's `symbol polygon, symbol ellipse { stroke: var(--ic) }`), and a
// stroke is 1 pixel at any size (`vector-effect: non-scaling-stroke`), so
// it is UICore that sets its width. The supported subset: polygon,
// ellipse, path (M L H V C A Z, absolute and relative), g with translate,
// matrix transforms, linear gradients across the element's box.

import Foundation
import XMLReader

public struct IconGenError: Error, CustomStringConvertible {
  public let description: String
  init(_ d: String) { description = d }
}

/// A paint: a role mixed at a percent over the background (0: none).
public struct Paint: Equatable, Sendable {
  public enum Role: String, Sendable { case none, edge, emblem, background }
  public var role: Role
  public var percent: Int
  static let none = Paint(role: .none, percent: 0)
}

public struct Element: Equatable, Sendable {
  public var fill: Paint
  /// A horizontal gradient's right end (the fill's own, if none).
  public var fillTo: Paint
  public var stroke: Paint
  /// Opcodes and points: 0 move (x y), 1 line (x y), 2 cubic (x1 y1 x2 y2
  /// x y), 3 close.
  public var path: [Double]
}

public struct Icon: Equatable, Sendable {
  public var name: String
  public var elements: [Element]
}

/// An affine map: x' = a x + c y + e, y' = b x + d y + f.
struct Affine {
  var a = 1.0, b = 0.0, c = 0.0, d = 1.0, e = 0.0, f = 0.0
  func apply(_ x: Double, _ y: Double) -> (Double, Double) { (a * x + c * y + e, b * x + d * y + f) }
  func then(_ o: Affine) -> Affine {
    // o after self.
    Affine(a: o.a * a + o.c * b, b: o.b * a + o.d * b, c: o.a * c + o.c * d, d: o.b * c + o.d * d,
           e: o.a * e + o.c * f + o.e, f: o.b * e + o.d * f + o.f)
  }
}

/// The numbers in a list ("1 .5 0 -1", "9.5,6.5", "-2.4-1").
func numbers(_ s: Substring) throws -> [Double] {
  var out: [Double] = []
  var i = s.startIndex
  while i < s.endIndex {
    let ch = s[i]
    if ch == " " || ch == "," || ch == "\n" || ch == "\t" {
      i = s.index(after: i)
      continue
    }
    var j = i
    if s[j] == "-" || s[j] == "+" { j = s.index(after: j) }
    var dot = false
    while j < s.endIndex, s[j].isNumber || (s[j] == "." && !dot) {
      if s[j] == "." { dot = true }
      j = s.index(after: j)
    }
    if j < s.endIndex, s[j] == "e" || s[j] == "E" {
      j = s.index(after: j)
      if j < s.endIndex, s[j] == "-" || s[j] == "+" { j = s.index(after: j) }
      while j < s.endIndex, s[j].isNumber { j = s.index(after: j) }
    }
    guard j > i, let v = Double(s[i..<j]) else { throw IconGenError("bad number in \"\(s)\"") }
    out.append(v)
    i = j
  }
  return out
}

func transform(_ s: String?) throws -> Affine {
  guard let s, !s.isEmpty else { return Affine() }
  var t = Affine()
  var rest = s[...]
  while let open = rest.firstIndex(of: "(") {
    let name = rest[..<open].trimmingCharacters(in: .whitespaces)
    guard let close = rest[open...].firstIndex(of: ")") else { throw IconGenError("bad transform \(s)") }
    let v = try numbers(rest[rest.index(after: open)..<close])
    let m: Affine
    switch name {
    case "matrix" where v.count == 6: m = Affine(a: v[0], b: v[1], c: v[2], d: v[3], e: v[4], f: v[5])
    case "translate" where v.count >= 1: m = Affine(e: v[0], f: v.count > 1 ? v[1] : 0)
    default: throw IconGenError("unsupported transform \(s)")
    }
    t = m.then(t)  // the leftmost applies last
    rest = rest[rest.index(after: close)...]
  }
  return t
}

/// A path as opcodes, in its own coordinates.
struct PathBuilder {
  var out: [Double] = []
  var x = 0.0, y = 0.0, sx = 0.0, sy = 0.0

  mutating func move(_ px: Double, _ py: Double) {
    out += [0, px, py]
    (x, y, sx, sy) = (px, py, px, py)
  }
  mutating func line(_ px: Double, _ py: Double) {
    out += [1, px, py]
    (x, y) = (px, py)
  }
  mutating func cubic(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ px: Double, _ py: Double) {
    out += [2, x1, y1, x2, y2, px, py]
    (x, y) = (px, py)
  }
  mutating func close() {
    out.append(3)
    (x, y) = (sx, sy)
  }

  /// SVG's endpoint arc (implementation notes F.6.5), as cubics of at most
  /// 90° each.
  mutating func arc(_ rx0: Double, _ ry0: Double, _ angle: Double, _ large: Bool, _ sweep: Bool, _ px: Double,
                    _ py: Double)
  {
    var rx = abs(rx0), ry = abs(ry0)
    if rx == 0 || ry == 0 || (px == x && py == y) {
      line(px, py)
      return
    }
    let phi = angle * .pi / 180, cp = cos(phi), sp = sin(phi)
    let dx = (x - px) / 2, dy = (y - py) / 2
    let x1 = cp * dx + sp * dy, y1 = -sp * dx + cp * dy
    let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
    if lambda > 1 {
      rx *= lambda.squareRoot()
      ry *= lambda.squareRoot()
    }
    let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
    let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
    var k = (max(0, num) / den).squareRoot()
    if large == sweep { k = -k }
    let cx1 = k * rx * y1 / ry, cy1 = -k * ry * x1 / rx
    let cx = cp * cx1 - sp * cy1 + (x + px) / 2, cy = sp * cx1 + cp * cy1 + (y + py) / 2
    func ang(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
      let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
      return a
    }
    let t1 = ang(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
    var dt = ang((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
    if !sweep && dt > 0 { dt -= 2 * .pi }
    if sweep && dt < 0 { dt += 2 * .pi }
    let n = max(1, Int((abs(dt) / (.pi / 2)).rounded(.up) - 1e-9))
    let step = dt / Double(n)
    let kk = 4.0 / 3 * tan(step / 4)
    func point(_ t: Double) -> (Double, Double) {
      (cx + rx * cos(t) * cp - ry * sin(t) * sp, cy + rx * cos(t) * sp + ry * sin(t) * cp)
    }
    func deriv(_ t: Double) -> (Double, Double) {
      (-rx * sin(t) * cp - ry * cos(t) * sp, -rx * sin(t) * sp + ry * cos(t) * cp)
    }
    var t = t1
    for i in 0..<n {
      let t2 = t + step
      let p0 = point(t), p3 = i == n - 1 ? (px, py) : point(t2)
      let d0 = deriv(t), d3 = deriv(t2)
      cubic(p0.0 + kk * d0.0, p0.1 + kk * d0.1, p3.0 - kk * d3.0, p3.1 - kk * d3.1, p3.0, p3.1)
      t = t2
    }
  }

  mutating func parse(_ d: String) throws {
    var i = d.startIndex
    var command: Character = "M"
    func args(_ n: Int) throws -> [Double] {
      // The next n numbers.
      var vals: [Double] = []
      while vals.count < n {
        while i < d.endIndex, d[i] == " " || d[i] == "," { i = d.index(after: i) }
        guard i < d.endIndex else { throw IconGenError("path ends early: \(d)") }
        var j = i
        if d[j] == "-" || d[j] == "+" { j = d.index(after: j) }
        var dot = false
        // An arc's flags are single digits, which may run together.
        let flag = command == "A" || command == "a" ? (vals.count == 3 || vals.count == 4) : false
        if flag {
          j = d.index(after: j)
        } else {
          while j < d.endIndex, d[j].isNumber || (d[j] == "." && !dot) {
            if d[j] == "." { dot = true }
            j = d.index(after: j)
          }
        }
        guard j > i, let v = Double(d[i..<j]) else { throw IconGenError("bad number in path \(d)") }
        vals.append(v)
        i = j
      }
      return vals
    }
    func atNumber() -> Bool {
      while i < d.endIndex, d[i] == " " || d[i] == "," { i = d.index(after: i) }
      guard i < d.endIndex else { return false }
      return d[i].isNumber || d[i] == "-" || d[i] == "+" || d[i] == "."
    }
    var first = true
    while true {
      if atNumber() {
        guard !first else { throw IconGenError("path starts without a command") }
      } else {
        guard i < d.endIndex else { break }
        command = d[i]
        i = d.index(after: i)
      }
      first = false
      let rel = command.isLowercase
      let (ox, oy) = rel ? (x, y) : (0, 0)
      switch command {
      case "M", "m":
        let v = try args(2)
        move(ox + v[0], oy + v[1])
        command = rel ? "l" : "L"  // further pairs are lines
      case "L", "l":
        let v = try args(2)
        line(ox + v[0], oy + v[1])
      case "H", "h":
        let v = try args(1)
        line((rel ? x : 0) + v[0], y)
      case "V", "v":
        let v = try args(1)
        line(x, (rel ? y : 0) + v[0])
      case "C", "c":
        let v = try args(6)
        cubic(ox + v[0], oy + v[1], ox + v[2], oy + v[3], ox + v[4], oy + v[5])
      case "A", "a":
        let v = try args(7)
        arc(v[0], v[1], v[2], v[3] != 0, v[4] != 0, ox + v[5], oy + v[6])
      case "Z", "z":
        close()
      default:
        throw IconGenError("unsupported path command \(command) in \(d)")
      }
    }
  }
}

/// A path's opcodes mapped through `t`.
func mapped(_ path: [Double], _ t: Affine) -> [Double] {
  var out: [Double] = []
  var i = 0
  while i < path.count {
    let op = Int(path[i])
    out.append(path[i])
    let n = op == 0 || op == 1 ? 1 : op == 2 ? 3 : 0
    for k in 0..<n {
      let (x, y) = t.apply(path[i + 1 + 2 * k], path[i + 2 + 2 * k])
      out += [x, y]
    }
    i += 1 + 2 * n
  }
  return out
}

/// The paint a CSS colour value names.
func paint(_ v: String) throws -> Paint {
  let s = v.replacingOccurrences(of: " ", with: "")
  func role(_ r: String) throws -> Paint.Role {
    switch r {
    case "var(--ic)": .edge
    case "var(--em,var(--ic))", "var(--em)": .emblem
    case "var(--bg0)": .background
    default: throw IconGenError("unknown colour \(r)")
    }
  }
  if s == "none" { return .none }
  if s.hasPrefix("color-mix(insrgb,") {
    // color-mix(in srgb, ROLE P%, var(--bg0))
    let inner = s.dropFirst("color-mix(insrgb,".count).dropLast()
    guard let comma = inner.range(of: ",var(--bg0)"), let pct = inner[..<comma.lowerBound].lastIndex(where: { $0 == ")" })
    else { throw IconGenError("unsupported color-mix \(v)") }
    let r = try role(String(inner[...pct]))
    guard let p = Int(inner[inner.index(after: pct)..<comma.lowerBound].dropLast()) else {
      throw IconGenError("bad percent in \(v)")
    }
    return Paint(role: r, percent: p)
  }
  return Paint(role: try role(s), percent: 100)
}

/// An element's style properties.
func style(_ e: XMLElement) -> [String: String] {
  var out: [String: String] = [:]
  for decl in (e.attribute("style") ?? "").split(separator: ";") {
    let kv = decl.split(separator: ":", maxSplits: 1)
    if kv.count == 2 { out[kv[0].trimmingCharacters(in: .whitespaces)] = kv[1].trimmingCharacters(in: .whitespaces) }
  }
  for k in ["fill", "stroke"] where out[k] == nil {
    if let a = e.attribute(k) { out[k] = a }
  }
  return out
}

/// The icon sheet's symbols, read from the storyboard.
public func readIcons(storyboard html: String) throws -> [Icon] {
  guard let start = html.range(of: "<svg class=\"icon-defs\""),
    let end = html.range(of: "</svg>", range: start.upperBound..<html.endIndex)
  else { throw IconGenError("no icon-defs in the storyboard") }
  let svg = try parseXML(String(html[start.lowerBound..<end.upperBound]))
  guard let defs = svg.element("defs") else { throw IconGenError("no defs") }
  // Gradients: their two stops' paints.
  var gradients: [String: (Paint, Paint)] = [:]
  for g in defs.elements("linearGradient") {
    let stops = g.elements("stop")
    guard let id = g.attribute("id"), stops.count == 2, g.attribute("x1") == "0", g.attribute("x2") == "1",
      g.attribute("y1") == "0", g.attribute("y2") == "0",
      let a = style(stops[0])["stop-color"], let b = style(stops[1])["stop-color"]
    else { throw IconGenError("unsupported gradient") }
    gradients[id] = (try paint(a), try paint(b))
  }
  var icons: [Icon] = []
  for symbol in defs.elements("symbol") {
    guard let id = symbol.attribute("id"), id.hasPrefix("i-"), symbol.attribute("viewBox") == "0 0 32 32" else {
      throw IconGenError("unsupported symbol \(symbol.attribute("id") ?? "?")")
    }
    var elements: [Element] = []
    func visit(_ e: XMLElement, _ outer: Affine) throws {
      let t = try transform(e.attribute("transform")).then(outer)
      var b = PathBuilder()
      switch e.name {
      case "g":
        for c in e.children { try visit(c, t) }
        return
      case "polygon":
        let v = try numbers((e.attribute("points") ?? "")[...])
        guard v.count >= 6, v.count % 2 == 0 else { throw IconGenError("bad polygon in \(id)") }
        b.move(v[0], v[1])
        for k in stride(from: 2, to: v.count, by: 2) { b.line(v[k], v[k + 1]) }
        b.close()
      case "ellipse":
        guard let cx = Double(e.attribute("cx") ?? ""), let cy = Double(e.attribute("cy") ?? ""),
          let rx = Double(e.attribute("rx") ?? ""), let ry = Double(e.attribute("ry") ?? "")
        else { throw IconGenError("bad ellipse in \(id)") }
        b.move(cx + rx, cy)
        b.arc(rx, ry, 0, false, true, cx - rx, cy)
        b.arc(rx, ry, 0, false, true, cx + rx, cy)
        b.close()
      case "path":
        try b.parse(e.attribute("d") ?? "")
      default:
        throw IconGenError("unsupported element \(e.name) in \(id)")
      }
      let s = style(e)
      var fill = Paint.none, fillTo = Paint.none
      if let f = s["fill"] {
        if f.hasPrefix("url(#") {
          guard let g = gradients[String(f.dropFirst(5).dropLast())] else { throw IconGenError("no gradient \(f)") }
          (fill, fillTo) = g
        } else {
          fill = try paint(f)
          fillTo = fill
        }
      } else {
        throw IconGenError("\(e.name) in \(id) has no fill (SVG's default is black)")
      }
      let stroke = try s["stroke"].map(paint) ?? (e.name == "polygon" || e.name == "ellipse" ? Paint(role: .edge, percent: 100) : .none)
      elements.append(Element(fill: fill, fillTo: fillTo, stroke: stroke, path: mapped(b.out, t)))
    }
    for c in symbol.children { try visit(c, Affine()) }
    icons.append(Icon(name: String(id.dropFirst(2)), elements: elements))
  }
  return icons
}

/// The icons as UICore's generated table.
public func swiftTable(_ icons: [Icon]) -> String {
  func num(_ v: Double) -> String {
    let r = (v * 10000).rounded() / 10000
    return r == r.rounded() ? String(Int(r)) : String(r)
  }
  func p(_ x: Paint) -> String { "IconPaint(.\(x.role.rawValue), \(x.percent))" }
  var out = """
    // SPDX-License-Identifier: BSD-3-Clause
    // Generated by iconsgen from docs/design/shell-storyboard.html's icon
    // sheet. Do not edit.

    extension IconData {
      public static let all: [IconShape] = [

    """
  for icon in icons {
    out += "    IconShape(name: \"\(icon.name)\", elements: [\n"
    for e in icon.elements {
      out += "      IconElement(fill: \(p(e.fill)), fillTo: \(p(e.fillTo)), stroke: \(p(e.stroke)),\n"
      out += "                  path: [\(e.path.map(num).joined(separator: ", "))]),\n"
    }
    out += "    ]),\n"
  }
  out += "  ]\n}\n"
  return out
}
