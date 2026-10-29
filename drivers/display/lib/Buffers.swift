// SPDX-License-Identifier: BSD-3-Clause

// A client's two images of an output (D146): it draws into the one not
// shown and presents it, so nothing it draws tears. Each frame the image
// drawn gets the frame's damage and what earlier frames put only in the
// other image (buffer age).

/// A rectangle of an output, in pixels.
public struct DisplayRect: Equatable, Sendable {
  public var x: UInt32, y: UInt32, width: UInt32, height: UInt32
  public init(x: UInt32, y: UInt32, width: UInt32, height: UInt32) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }

  public var isEmpty: Bool { width == 0 || height == 0 }

  /// Clipped to a `w` × `h` image.
  public func clipped(_ w: UInt32, _ h: UInt32) -> DisplayRect {
    guard x < w, y < h else { return DisplayRect(x: 0, y: 0, width: 0, height: 0) }
    return DisplayRect(x: x, y: y, width: min(width, w - x), height: min(height, h - y))
  }

  /// The smallest rectangle that holds both.
  public func union(_ o: DisplayRect) -> DisplayRect {
    if isEmpty { return o }
    if o.isEmpty { return self }
    let x0 = min(x, o.x), y0 = min(y, o.y)
    let x1 = max(x + width, o.x + o.width), y1 = max(y + height, o.y + o.height)
    return DisplayRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
  }
}

/// Two images, one shown and one drawn: what each lacks, so that a frame
/// draws into the drawn one its damage and what the last frames put only
/// in the other.
public struct Buffers: Equatable, Sendable {
  public let width: UInt32, height: UInt32
  /// The image shown (0 or 1), nil until the first is.
  public private(set) var front: Int?
  /// What each image lacks.
  public private(set) var stale: [DisplayRect]

  public init(width: UInt32, height: UInt32) {
    self.width = width
    self.height = height
    stale = [DisplayRect(x: 0, y: 0, width: width, height: height),
             DisplayRect(x: 0, y: 0, width: width, height: height)]
  }

  /// The image the next frame draws and shows.
  public var back: Int { front == 0 ? 1 : 0 }

  /// A frame of `damage`: what to draw into `back`, which then lacks
  /// nothing, while the shown one lacks the damage too.
  public mutating func draw(_ damage: DisplayRect) -> DisplayRect {
    let d = damage.clipped(width, height)
    let b = back
    let drawn = stale[b].union(d)
    stale[b] = DisplayRect(x: 0, y: 0, width: 0, height: 0)
    stale[1 - b] = stale[1 - b].union(d)
    return drawn
  }

  /// The back image is shown now.
  public mutating func shown() { front = back }
}
