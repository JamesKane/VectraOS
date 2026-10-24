// SPDX-License-Identifier: BSD-3-Clause

// A USB mouse's reports as its report descriptor lays them out (Device
// Class Definition for HID 1.11, §6.2.2), as Linux's hid-core and
// FreeBSD's hms read them: the boot protocol is a request a device may
// ignore (a Corsair 1b1c:1bac keeps 16-bit X and Y after it), and the
// descriptor says what it sends. Only what a pointer needs is kept: the
// buttons, relative X and Y, and the wheel, each a bit offset and size
// in the report, and the report's ID, if reports carry one. The boot
// report is the layout of a descriptor that says nothing.

/// Where a mouse's fields sit in its reports.
public struct MouseLayout: Equatable, Sendable {
  /// A field: its first bit in the report (after any ID byte), its bits,
  /// and whether it is signed (its logical minimum below 0).
  public struct Field: Equatable, Sendable {
    public var offset: Int
    public var size: Int
    public var signed: Bool
    public init(offset: Int, size: Int, signed: Bool) {
      self.offset = offset
      self.size = size
      self.signed = signed
    }
  }

  /// The ID byte reports begin with, nil if they have none.
  public var reportID: UInt8?
  /// Buttons 1-3 (left, right, middle): each one's bit, if there.
  public var buttons: [Int?]
  public var x: Field
  public var y: Field
  public var wheel: Field?

  public init(reportID: UInt8?, buttons: [Int?], x: Field, y: Field, wheel: Field?) {
    self.reportID = reportID
    self.buttons = buttons
    self.x = x
    self.y = y
    self.wheel = wheel
  }

  /// HID's boot mouse (appendix B.2): buttons, then dx, dy and a wheel
  /// most have, a signed byte each.
  public static let boot = MouseLayout(reportID: nil, buttons: [0, 1, 2], x: Field(offset: 8, size: 8, signed: true),
                                       y: Field(offset: 16, size: 8, signed: true),
                                       wheel: Field(offset: 24, size: 8, signed: true))

  /// The layout `descriptor` gives the report holding relative X and Y
  /// (Generic Desktop 0x30 and 0x31), its buttons and wheel taken from
  /// the same report; nil if it has none.
  public static func parse(_ descriptor: [UInt8]) -> MouseLayout? {
    struct Globals {
      var page: UInt32 = 0, logicalMin: Int64 = 0, size = 0, count = 0, reportID: UInt8 = 0
    }
    var g = Globals()
    var stack: [Globals] = []
    var usages: [UInt32] = [], usageMin: UInt32?, usageMax: UInt32?
    var offsets: [(id: UInt8, bits: Int)] = []
    var sawID = false
    // What each report holds, by its ID (0 without IDs).
    var found: [(id: UInt8, x: Field?, y: Field?, wheel: Field?, buttons: [Int?])] = []

    var i = 0
    while i < descriptor.count {
      let prefix = descriptor[i]
      if prefix == 0xFE {  // a long item: skipped
        guard i + 1 < descriptor.count else { break }
        i += 3 + Int(descriptor[i + 1])
        continue
      }
      let size = [0, 1, 2, 4][Int(prefix & 3)]
      guard i + size < descriptor.count else { break }
      var u: UInt32 = 0
      for k in 0..<size { u |= UInt32(descriptor[i + 1 + k]) << (8 * k) }
      let s: Int64 = size == 0 ? 0 : Int64(u) - (u >> (8 * size - 1) & 1 == 1 ? Int64(1) << (8 * size) : 0)
      let type = prefix >> 2 & 3, tag = prefix >> 4
      i += 1 + size
      switch (type, tag) {
      case (0, 8):  // Input
        var at = 0
        while at < offsets.count && offsets[at].id != g.reportID { at += 1 }
        if at == offsets.count { offsets.append((g.reportID, 0)) }
        let base = offsets[at].bits
        offsets[at].bits += g.size * g.count
        // Not constant (bit 0), and not an array (bit 1 set: a variable).
        if u & 1 == 0 && u & 2 != 0 && g.count > 0 {
          var list = usages
          if list.isEmpty, let lo = usageMin, let hi = usageMax, lo <= hi {
            list = Array(lo...min(hi, lo + UInt32(g.count) - 1))
          }
          var e = 0
          while e < found.count && found[e].id != g.reportID { e += 1 }
          if e == found.count { found.append((g.reportID, nil, nil, nil, [nil, nil, nil])) }
          for k in 0..<g.count where !list.isEmpty {
            let usage = list[min(k, list.count - 1)]
            let page = usage > 0xFFFF ? usage >> 16 : g.page
            let field = Field(offset: base + k * g.size, size: g.size, signed: g.logicalMin < 0)
            let relative = u & 4 != 0
            switch (page, usage & 0xFFFF) {
            case (9, 1...3) where g.size == 1: found[e].buttons[Int(usage & 0xFFFF) - 1] = field.offset
            case (1, 0x30) where relative: found[e].x = found[e].x ?? field
            case (1, 0x31) where relative: found[e].y = found[e].y ?? field
            case (1, 0x38) where relative: found[e].wheel = found[e].wheel ?? field
            default: break
            }
          }
        }
        usages = []
        usageMin = nil
        usageMax = nil
      case (0, _):  // Output, Feature, Collection, End Collection
        usages = []
        usageMin = nil
        usageMax = nil
      case (1, 0): g.page = u
      case (1, 1): g.logicalMin = s
      case (1, 7): g.size = Int(u)
      case (1, 8):
        g.reportID = UInt8(truncatingIfNeeded: u)
        sawID = true
      case (1, 9): g.count = Int(u)
      case (1, 10): stack.append(g)
      case (1, 11): g = stack.popLast() ?? g
      case (2, 0): usages.append(size == 4 ? u : g.page << 16 | u)
      case (2, 1): usageMin = size == 4 ? u : g.page << 16 | u
      case (2, 2): usageMax = size == 4 ? u : g.page << 16 | u
      default: break
      }
    }
    guard let r = found.first(where: { $0.x != nil && $0.y != nil }), let x = r.x, let y = r.y,
      x.size <= 32, y.size <= 32, (r.wheel?.size ?? 0) <= 32
    else { return nil }
    return MouseLayout(reportID: sawID ? r.id : nil, buttons: r.buttons, x: x, y: y, wheel: r.wheel)
  }

  /// `f`'s value in `bits` (the report after any ID byte); 0 where the
  /// report is too short for it.
  static func value(_ f: Field, in bits: ArraySlice<UInt8>) -> Int32 {
    guard f.size > 0, f.offset + f.size <= bits.count * 8 else { return 0 }
    var v: UInt64 = 0
    for b in 0..<f.size {
      let at = f.offset + b
      if bits[bits.startIndex + at / 8] & (1 << UInt8(at % 8)) != 0 { v |= 1 << UInt64(b) }
    }
    if f.signed && v >> UInt64(f.size - 1) & 1 == 1 { return Int32(truncatingIfNeeded: Int64(v) - (Int64(1) << f.size)) }
    return Int32(truncatingIfNeeded: v)
  }
}

/// A USB mouse: its reports, laid out as its descriptor says (or as the
/// boot protocol's), as mousein's records.
public struct HIDMouse: Sendable {
  let layout: MouseLayout
  var pointer = PointerReport()
  var buttons: [Bool] = [false, false, false]

  public init(layout: MouseLayout = .boot) { self.layout = layout }

  /// The records for one report (none if nothing changed, or it is
  /// another report's).
  public mutating func take(_ report: [UInt8]) -> [UInt8] {
    var bits = report[...]
    if let id = layout.reportID {
      guard bits.first == id else { return [] }
      bits = bits.dropFirst()
    }
    guard bits.count * 8 >= max(layout.x.offset + layout.x.size, layout.y.offset + layout.y.size) else { return [] }
    let codes: [UInt16] = [PointerReport.buttonLeft, PointerReport.buttonRight, PointerReport.buttonMiddle]
    for n in 0..<3 {
      guard let at = layout.buttons[n] else { continue }
      let down = MouseLayout.value(MouseLayout.Field(offset: at, size: 1, signed: false), in: bits) != 0
      if down != buttons[n] {
        buttons[n] = down
        _ = pointer.take(type: PointerReport.key, code: codes[n], value: down ? 1 : 0)
      }
    }
    let dx = MouseLayout.value(layout.x, in: bits), dy = MouseLayout.value(layout.y, in: bits)
    if dx != 0 { _ = pointer.take(type: PointerReport.rel, code: PointerReport.relX, value: dx) }
    if dy != 0 { _ = pointer.take(type: PointerReport.rel, code: PointerReport.relY, value: dy) }
    if let w = layout.wheel {
      let v = MouseLayout.value(w, in: bits)
      if v != 0 { _ = pointer.take(type: PointerReport.rel, code: PointerReport.relWheel, value: v) }
    }
    return pointer.take(type: PointerReport.syn, code: 0, value: 0)
  }
}
