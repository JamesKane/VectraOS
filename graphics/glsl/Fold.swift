// SPDX-License-Identifier: BSD-3-Clause

// Constant folding: the values of constant expressions (section 4.3.3), in binary32 as the GPU computes them, for
// the const variables, the array sizes and the constants the SPIR-V carries. The built-in functions that need a
// libm (the trigonometric, exponential and logarithmic ones) are not folded; they stay constant expressions, computed
// by the program.

enum Fold {
  static func binary(_ op: BinaryOp, _ a: Expr, _ b: Expr, _ rt: GType, _ prog: Program) -> [Scalar]? {
    guard let x = a.value, let y = b.value else {
      // false && anything, true || anything.
      if op == .and, let x = a.value, !x[0].bool { return [.b(false)] }
      if op == .or, let x = a.value, x[0].bool { return [.b(true)] }
      return nil
    }
    switch op {
    case .and: return [.b(x[0].bool && y[0].bool)]
    case .or: return [.b(x[0].bool || y[0].bool)]
    case .xor: return [.b(x[0].bool != y[0].bool)]
    case .eq: return [.b(equal(x, y))]
    case .ne: return [.b(!equal(x, y))]
    case .lt, .gt, .le, .ge:
      let c: Bool
      if case .i(let p) = x[0], case .i(let q) = y[0] {
        c = op == .lt ? p < q : op == .gt ? p > q : op == .le ? p <= q : p >= q
      } else {
        let p = x[0].float
        let q = y[0].float
        c = op == .lt ? p < q : op == .gt ? p > q : op == .le ? p <= q : p >= q
      }
      return [.b(c)]
    case .mul where a.type.isMatrix || b.type.isMatrix:
      if !a.type.isMatrix || !b.type.isMatrix {
        if a.type.isScalar || b.type.isScalar { break }
      }
      let at = a.type
      let bt = b.type
      let fx = x.map { $0.float }
      let fy = y.map { $0.float }
      if at.isMatrix && bt.isMatrix {
        let n = at.cols
        var r = [Float](repeating: 0, count: n * n)
        for c in 0..<n {
          for row in 0..<n {
            var s: Float = 0
            for k in 0..<n { s += fx[k * n + row] * fy[c * n + k] }
            r[c * n + row] = s
          }
        }
        return r.map { .f($0) }
      }
      if at.isMatrix {
        let n = at.cols
        var r = [Float](repeating: 0, count: n)
        for row in 0..<n {
          var s: Float = 0
          for k in 0..<n { s += fx[k * n + row] * fy[k] }
          r[row] = s
        }
        return r.map { .f($0) }
      }
      let n = bt.cols
      var r = [Float](repeating: 0, count: n)
      for c in 0..<n {
        var s: Float = 0
        for k in 0..<n { s += fx[k] * fy[c * n + k] }
        r[c] = s
      }
      return r.map { .f($0) }
    default: break
    }
    // Component-wise arithmetic, a scalar applied to every component.
    let n = rt.components
    var r: [Scalar] = []
    for i in 0..<n {
      let p = x.count == 1 ? x[0] : x[i]
      let q = y.count == 1 ? y[0] : y[i]
      switch (p, q) {
      case (.i(let u), .i(let v)):
        switch op {
        case .add: r.append(.i(u &+ v))
        case .sub: r.append(.i(u &- v))
        case .mul: r.append(.i(u &* v))
        default:
          if v == 0 { return nil }
          r.append(.i(u == Int32.min && v == -1 ? u : u / v))
        }
      default:
        let u = p.float
        let v = q.float
        switch op {
        case .add: r.append(.f(u + v))
        case .sub: r.append(.f(u - v))
        case .mul: r.append(.f(u * v))
        default: r.append(.f(u / v))
        }
      }
    }
    return r
  }

  static func equal(_ x: [Scalar], _ y: [Scalar]) -> Bool {
    guard x.count == y.count else { return false }
    for (p, q) in zip(x, y) {
      switch (p, q) {
      case (.f(let u), .f(let v)): if !(u == v) { return false }
      default: if p != q { return false }
      }
    }
    return true
  }

  /// The components a constructor of `t` makes of its arguments (section 5.4), each converted to `t`'s basic type.
  static func construct(_ t: GType, _ args: [Expr]) -> [Scalar]? {
    guard args.allSatisfy({ $0.value != nil }) else { return nil }
    let b = t.basic
    if args.count == 1 && args[0].type.isScalar && !t.isScalar {
      let s = args[0].value![0].converted(to: b)
      if t.isMatrix {
        let zero = Scalar.f(0)
        var r: [Scalar] = []
        for c in 0..<t.cols { for row in 0..<t.rows { r.append(c == row ? s : zero) } }
        return r
      }
      return [Scalar](repeating: s, count: t.components)
    }
    if args.count == 1 && args[0].type.isMatrix && t.isMatrix {
      let m = args[0].type.cols
      let v = args[0].value!
      var r: [Scalar] = []
      for c in 0..<t.cols {
        for row in 0..<t.rows {
          if c < m && row < m { r.append(v[c * m + row]) } else { r.append(.f(c == row ? 1 : 0)) }
        }
      }
      return r
    }
    var all: [Scalar] = []
    for a in args { all += a.value! }
    return Array(all[0..<t.components]).map { $0.converted(to: b) }
  }

  static func builtin(_ f: BuiltinFunction, _ args: [Expr], _ rt: GType) -> [Scalar]? {
    guard args.allSatisfy({ $0.value != nil }) else { return nil }
    let v = args.map { $0.value! }
    let n = rt.components
    func fl(_ k: Int, _ i: Int) -> Float { v[k].count == 1 ? v[k][0].float : v[k][i].float }
    func map1(_ g: (Float) -> Float) -> [Scalar] { (0..<n).map { .f(g(fl(0, $0))) } }
    func map2(_ g: (Float, Float) -> Float) -> [Scalar] { (0..<n).map { .f(g(fl(0, $0), fl(1, $0))) } }
    func map3(_ g: (Float, Float, Float) -> Float) -> [Scalar] { (0..<n).map { .f(g(fl(0, $0), fl(1, $0), fl(2, $0))) } }
    func dot(_ a: [Scalar], _ b: [Scalar]) -> Float {
      var s: Float = 0
      for (x, y) in zip(a, b) { s += x.float * y.float }
      return s
    }
    switch f {
    case .radians: return map1 { $0 * Float(Double.pi / 180) }
    case .degrees: return map1 { $0 * Float(180 / Double.pi) }
    case .sqrt: return map1 { $0.squareRoot() }
    case .inversesqrt: return map1 { 1 / $0.squareRoot() }
    case .abs: return map1 { Swift.abs($0) }
    case .sign: return map1 { $0 > 0 ? 1 : $0 < 0 ? -1 : 0 }
    case .floor: return map1 { $0.rounded(.down) }
    case .ceil: return map1 { $0.rounded(.up) }
    case .fract: return map1 { $0 - $0.rounded(.down) }
    case .mod: return map2 { $0 - $1 * ($0 / $1).rounded(.down) }
    case .min: return map2 { Swift.min($0, $1) }
    case .max: return map2 { Swift.max($0, $1) }
    case .clamp: return map3 { Swift.min(Swift.max($0, $1), $2) }
    case .mix: return map3 { $0 * (1 - $2) + $1 * $2 }
    case .step: return map2 { $1 < $0 ? 0 : 1 }
    case .smoothstep:
      return map3 { e0, e1, x in
        let t = Swift.min(Swift.max((x - e0) / (e1 - e0), 0), 1)
        return t * t * (3 - 2 * t)
      }
    case .length: return [.f(dot(v[0], v[0]).squareRoot())]
    case .distance:
      let d = zip(v[0], v[1]).map { Scalar.f($0.float - $1.float) }
      return [.f(dot(d, d).squareRoot())]
    case .dot: return [.f(dot(v[0], v[1]))]
    case .cross:
      let a = v[0].map { $0.float }
      let b = v[1].map { $0.float }
      return [.f(a[1] * b[2] - a[2] * b[1]), .f(a[2] * b[0] - a[0] * b[2]), .f(a[0] * b[1] - a[1] * b[0])]
    case .normalize:
      let s = 1 / dot(v[0], v[0]).squareRoot()
      return v[0].map { .f($0.float * s) }
    case .faceforward:
      return dot(v[2], v[1]) < 0 ? v[0] : v[0].map { .f(-$0.float) }
    case .reflect:
      let d = dot(v[1], v[0])
      return (0..<n).map { .f(v[0][$0].float - 2 * d * v[1][$0].float) }
    case .refract:
      let eta = v[2][0].float
      let d = dot(v[1], v[0])
      let k = 1 - eta * eta * (1 - d * d)
      if k < 0 { return [Scalar](repeating: .f(0), count: n) }
      return (0..<n).map { .f(eta * v[0][$0].float - (eta * d + k.squareRoot()) * v[1][$0].float) }
    case .matrixCompMult: return map2 { $0 * $1 }
    case .lessThan, .lessThanEqual, .greaterThan, .greaterThanEqual, .equal, .notEqual:
      return (0..<n).map { i in
        let (p, q) = (v[0][i], v[1][i])
        switch f {
        case .equal: return .b(equal([p], [q]))
        case .notEqual: return .b(!equal([p], [q]))
        default: break
        }
        let c: Bool
        if case .i(let x) = p, case .i(let y) = q {
          c = f == .lessThan ? x < y : f == .lessThanEqual ? x <= y : f == .greaterThan ? x > y : x >= y
        } else {
          let (x, y) = (p.float, q.float)
          c = f == .lessThan ? x < y : f == .lessThanEqual ? x <= y : f == .greaterThan ? x > y : x >= y
        }
        return .b(c)
      }
    case .any: return [.b(v[0].contains { $0.bool })]
    case .all: return [.b(v[0].allSatisfy { $0.bool })]
    case .not: return v[0].map { .b(!$0.bool) }
    default: return nil
    }
  }
}
