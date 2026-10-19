// SPDX-License-Identifier: BSD-3-Clause

// A glyph's outline (M6h): contours of lines, quadratic curves (TrueType's)
// and cubic ones (CFF's), in font units with y up. Each contour starts at
// its move and is closed back to it (a closing segment is left implicit
// when it would be a line to where the contour began).

public struct Point: Equatable, Sendable {
  public var x: Double
  public var y: Double
  public init(_ x: Double, _ y: Double) {
    self.x = x
    self.y = y
  }
}

public enum Segment: Equatable, Sendable {
  case line(Point)
  case quad(Point, Point)
  case cubic(Point, Point, Point)

  public var end: Point {
    switch self {
    case .line(let p): p
    case .quad(_, let p): p
    case .cubic(_, _, let p): p
    }
  }
}

public struct Contour: Equatable, Sendable {
  public var start: Point
  public var segments: [Segment]
  public init(start: Point, segments: [Segment]) {
    self.start = start
    self.segments = segments
  }
}

public struct Outline: Equatable, Sendable {
  public var contours: [Contour]
  public init(contours: [Contour] = []) { self.contours = contours }

  /// The outline moved by `dx`, `dy` and transformed by the matrix
  /// (a b; c d): x' = a x + c y + dx, y' = b x + d y + dy.
  func transformed(a: Double, b: Double, c: Double, d: Double, dx: Double, dy: Double) -> Outline {
    func t(_ p: Point) -> Point { Point(a * p.x + c * p.y + dx, b * p.x + d * p.y + dy) }
    return Outline(contours: contours.map { contour in
      Contour(start: t(contour.start), segments: contour.segments.map { s in
        switch s {
        case .line(let p): .line(t(p))
        case .quad(let c1, let p): .quad(t(c1), t(p))
        case .cubic(let c1, let c2, let p): .cubic(t(c1), t(c2), t(p))
        }
      })
    })
  }

  /// The smallest box holding the outline's points (control points
  /// included): xMin, yMin, xMax, yMax; nil for an empty outline.
  public var controlBox: (xMin: Double, yMin: Double, xMax: Double, yMax: Double)? {
    var box: (Double, Double, Double, Double)?
    func add(_ p: Point) {
      if let b = box {
        box = (min(b.0, p.x), min(b.1, p.y), max(b.2, p.x), max(b.3, p.y))
      } else {
        box = (p.x, p.y, p.x, p.y)
      }
    }
    for c in contours {
      add(c.start)
      for s in c.segments {
        switch s {
        case .line(let p): add(p)
        case .quad(let c1, let p): add(c1); add(p)
        case .cubic(let c1, let c2, let p): add(c1); add(c2); add(p)
        }
      }
    }
    return box
  }
}
