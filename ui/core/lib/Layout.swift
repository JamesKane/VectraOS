// SPDX-License-Identifier: BSD-3-Clause

// The UI Kit's layout (M6i part 2): two passes over a frame's boxes, per
// axis, as in Fleury's UI series. Boxes are built in pre-order (a parent
// before its children), so walking the array backwards visits children
// before their parents.
//
//   1. Standalone sizes: pixels, and text (measured, plus padding).
//   2. Children's sizes: the sum along the box's layout axis, the largest
//      across it, plus padding (post-order).
//   3. Sharing out (pre-order, so a parent's size is final first): its
//      children's percents of its inside; then what's left along its axis
//      goes to its growing children by weight (across it, they stretch);
//      if the children want more than there is, each gives up to (1 -
//      strictness) of its size, in proportion, until they fit.
//   4. Positions (pre-order): each child after the one before it along
//      its parent's axis, inside the padding.
//
// A floating box (one given a position) is placed there and left out of
// its parent's flow: its sums, its sharing, its positions.

enum Layout {
  static func padding(_ s: Style, _ axis: Int) -> (Float, Float) {
    axis == 0 ? (s.padding.left, s.padding.right) : (s.padding.top, s.padding.bottom)
  }

  static func size(_ b: Box, _ axis: Int) -> Size { axis == 0 ? b.size.0 : b.size.1 }

  static func get(_ b: Box, _ axis: Int) -> Float { axis == 0 ? b.computed.0 : b.computed.1 }

  static func set(_ b: inout Box, _ axis: Int, _ v: Float) {
    if axis == 0 { b.computed.0 = v } else { b.computed.1 = v }
  }

  /// A box's children in its flow (floating ones left out), into `out`
  /// (the caller's, reused: M6m, no allocations in layout).
  static func children(_ boxes: [Box], _ i: Int, into out: inout [Int]) {
    out.removeAll(keepingCapacity: true)
    var c = boxes[i].first
    while c >= 0 {
      if boxes[Int(c)].position == nil { out.append(Int(c)) }
      c = boxes[Int(c)].next
    }
  }

  static func inside(_ b: Box, _ axis: Int) -> Float {
    let (a, z) = padding(b.style, axis)
    return max(0, get(b, axis) - a - z)
  }

  static func solve(_ boxes: inout [Box], scratch kids: inout [Int]) {
    guard !boxes.isEmpty else { return }
    for axis in 0..<2 {
      // 1. Standalone.
      for i in 0..<boxes.count {
        let (a, z) = padding(boxes[i].style, axis)
        switch size(boxes[i], axis) {
        case .pixels(let v, _): set(&boxes[i], axis, v)
        case .text: set(&boxes[i], axis, (axis == 0 ? boxes[i].textSize.0 : boxes[i].textSize.1) + a + z)
        default: set(&boxes[i], axis, 0)
        }
      }
      // 2. Children's sizes, from the leaves up.
      for i in stride(from: boxes.count - 1, through: 0, by: -1) {
        guard case .children = size(boxes[i], axis) else { continue }
        children(boxes, i, into: &kids)
        let along = boxes[i].axis.rawValue == axis
        var total: Float = 0
        for k in kids {
          let v = get(boxes[k], axis)
          total = along ? total + v : max(total, v)
        }
        let (a, z) = padding(boxes[i].style, axis)
        set(&boxes[i], axis, total + a + z)
      }
      // 3. Sharing out, from the root down.
      for i in 0..<boxes.count {
        children(boxes, i, into: &kids)
        // Floating children's percents too (they're out of the flow).
        var c = boxes[i].first
        while c >= 0 {
          if case .percent(let f, _) = size(boxes[Int(c)], axis) { set(&boxes[Int(c)], axis, inside(boxes[i], axis) * f) }
          c = boxes[Int(c)].next
        }
        guard !kids.isEmpty else { continue }
        let room = inside(boxes[i], axis)
        let along = boxes[i].axis.rawValue == axis
        if along {
          var used: Float = 0, weights: Float = 0
          for k in kids {
            if case .grow(let w) = size(boxes[k], axis) { weights += max(w, 0) } else { used += get(boxes[k], axis) }
          }
          if weights > 0 {
            let free = max(0, room - used)
            for k in kids {
              if case .grow(let w) = size(boxes[k], axis) { set(&boxes[k], axis, free * max(w, 0) / weights) }
            }
          } else if used > room {
            // Too much: each gives up what its strictness allows, in
            // proportion, until they fit (or can give no more).
            var allowance: Float = 0
            for k in kids { allowance += get(boxes[k], axis) * (1 - strictness(size(boxes[k], axis))) }
            if allowance > 0 {
              let fraction = min(1, (used - room) / allowance)
              for k in kids {
                let v = get(boxes[k], axis)
                set(&boxes[k], axis, v - v * (1 - strictness(size(boxes[k], axis))) * fraction)
              }
            }
          }
        } else {
          for k in kids {
            if case .grow = size(boxes[k], axis) {
              set(&boxes[k], axis, room)
            } else if get(boxes[k], axis) > room {
              let v = get(boxes[k], axis)
              let floor = v * strictness(size(boxes[k], axis))
              set(&boxes[k], axis, max(floor, room))
            }
          }
        }
      }
    }
    // 4. Positions, from the root down (a floating box where it was put).
    boxes[0].rect = Rect(x: 0, y: 0, width: boxes[0].computed.0, height: boxes[0].computed.1)
    for i in 0..<boxes.count {
      if let (fx, fy) = boxes[i].position {
        boxes[i].rect = Rect(x: fx, y: fy, width: boxes[i].computed.0, height: boxes[i].computed.1)
      }
      children(boxes, i, into: &kids)
      guard !kids.isEmpty else { continue }
      let p = boxes[i]
      let alongX = p.axis == .horizontal
      var x = p.rect.x + p.style.padding.left - p.scrollX, y = p.rect.y + p.style.padding.top - p.scrollY
      for k in kids {
        boxes[k].rect = Rect(x: x, y: y, width: boxes[k].computed.0, height: boxes[k].computed.1)
        if alongX { x += boxes[k].computed.0 } else { y += boxes[k].computed.1 }
      }
    }
  }

  static func strictness(_ s: Size) -> Float {
    switch s {
    case .pixels(_, let k), .text(let k), .percent(_, let k), .children(let k): min(max(k, 0), 1)
    case .grow: 0
    }
  }
}
