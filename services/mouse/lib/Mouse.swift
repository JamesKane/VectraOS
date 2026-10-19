// SPDX-License-Identifier: BSD-3-Clause

// What the mouse service does (D83), after 9front's devmouse.c: pointer
// drivers write records to mousein, relative (`m`), absolute (`A`) or
// scaled to the screen (`a`), each with the buttons held; the pointer is
// kept inside the screen, accelerated when mousectl says so (scale), and
// each writer's buttons are its own (inbuttons). A reader of mouse gets
// 49-byte `m` messages: the state whenever it has changed since its last
// read, and every change of the buttons, queued, so a quick click isn't
// lost between reads. Unlike devmouse, each channel opened at mouse reads
// its own copy (no Einuse), the wheel's buttons are momentary (pressed
// and released in each record that has them, as a notch is), and one
// write to mousein may hold several records, a line each.

/// The pointer's state as a reader of mouse sees it.
public struct MouseState: Equatable, Sendable {
  public var x: Int32 = 0, y: Int32 = 0
  /// Plan 9's: 1 left, 2 middle, 4 right; 8 and 16 the wheel up and down,
  /// 32 and 64 left and right.
  public var buttons: Int32 = 0
  /// Milliseconds, the record's or the service's clock.
  public var msec: UInt32 = 0
  /// Counts every change.
  var counter: UInt64 = 0
  public init() {}
}

/// A channel open at mouse: what it has read.
public final class MouseReader: @unchecked Sendable {
  var lastCounter: UInt64
  /// The button changes not yet read; at most 16, then none until a read.
  var queue: [MouseState] = []
  init(counter: UInt64) { lastCounter = counter }
}

/// A channel open at mousein: the buttons it holds.
public final class MouseWriter: @unchecked Sendable {
  var buttons: Int32 = 0
  public init() {}
}

public final class Mouse: @unchecked Sendable {
  static let wheel: Int32 = 8 | 16 | 32 | 64
  static let queueLimit = 16

  /// The screen the pointer stays inside.
  public var width: Int32, height: Int32
  public private(set) var state = MouseState()
  /// The buttons the writers of mousein hold.
  var inButtons: Int32 = 0
  /// mousectl's: devmouse's buttonmap, swap and scrollswap; acceleration
  /// 0 is linear.
  var buttonMap: [Int32] = [0, 1, 2, 3, 4, 5, 6, 7]
  var swapped = false
  var scrollSwap = false
  var acceleration: Int32 = 0
  var maxAcceleration: Int32 = 2
  var readers: [MouseReader] = []

  public init(width: Int32, height: Int32) {
    self.width = max(width, 1)
    self.height = max(height, 1)
    state.x = self.width / 2
    state.y = self.height / 2
  }

  // MARK: mouse

  /// A channel opened at mouse: it reads the changes from now on.
  public func open() -> MouseReader {
    let r = MouseReader(counter: state.counter)
    readers.append(r)
    return r
  }

  public func close(_ reader: MouseReader) { readers.removeAll { $0 === reader } }

  /// The next message for `reader`, nil if nothing has changed since its
  /// last (a read waits).
  public func read(_ reader: MouseReader) -> [UInt8]? {
    var m: MouseState
    if !reader.queue.isEmpty {
      m = reader.queue.removeFirst()
    } else if reader.lastCounter != state.counter {
      m = state
    } else {
      return nil
    }
    reader.lastCounter = m.counter
    return message(m)
  }

  /// `m` and the four fields, each 11 wide and a blank: 49 bytes.
  public func message(_ m: MouseState) -> [UInt8] {
    var b = buttonMap[Int(m.buttons & 7)] | (m.buttons & Self.wheel)
    if scrollSwap {
      if b & 8 != 0 { b ^= 8 | 16 } else if b & 16 != 0 { b ^= 8 | 16 }
    }
    var out: [UInt8] = [UInt8(ascii: "m")]
    for v in [Int64(m.x), Int64(m.y), Int64(b), Int64(m.msec)] { out += Self.field(v) }
    return out
  }

  static func field(_ v: Int64) -> [UInt8] {
    var digits = Array(String(v).utf8)
    while digits.count < 11 { digits.insert(UInt8(ascii: " "), at: 0) }
    return digits + [UInt8(ascii: " ")]
  }

  /// A write to mouse: `m x y`, moving the pointer there; the buttons stay.
  public func move(_ text: [UInt8], msec: UInt32) -> Bool {
    guard text.first == UInt8(ascii: "m") else { return false }
    let f = Self.fields(Array(text.dropFirst()))
    guard f.count >= 2, let x = Self.number(f[0]), let y = Self.number(f[1]) else { return false }
    track(x: Int64(x), y: Int64(y), buttons: state.buttons & ~Self.wheel, msec: msec)
    return true
  }

  // MARK: mousein

  /// The state, without waiting: a read of mousein.
  public func current() -> [UInt8] { message(state) }

  /// A write to mousein by `writer`: records a line each, `m dx dy b`,
  /// `A x y b` or `a x y b` with an optional msec after; false at the
  /// first it can't read (those before it taken).
  public func mousein(_ data: [UInt8], from writer: MouseWriter, msec now: UInt32) -> Bool {
    for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
      // The kind, then the numbers: `m` may touch the first, as
      // `m%11d` makes it.
      let kind = line[line.startIndex]
      guard kind == UInt8(ascii: "m") || kind == UInt8(ascii: "A") || kind == UInt8(ascii: "a") else { return false }
      let f = Self.fields(Array(line.dropFirst()))
      guard f.count == 3 || f.count == 4, let x = Self.number(f[0]), let y = Self.number(f[1]),
        let b = Self.number(f[2])
      else { return false }
      var msec = now
      if f.count == 4 {
        guard let t = Self.number(f[3]) else { return false }
        if t != 0 { msec = UInt32(truncatingIfNeeded: t) }
      }
      record(kind, Int64(x), Int64(y), b, from: writer, msec: msec)
    }
    return true
  }

  /// A writer's channel closed: the buttons it held are let go.
  public func closed(_ writer: MouseWriter, msec: UInt32) {
    guard writer.buttons != 0 else { return }
    inButtons &= ~writer.buttons
    writer.buttons = 0
    track(x: Int64(state.x), y: Int64(state.y), buttons: 0, msec: msec)
  }

  func record(_ kind: UInt8, _ x: Int64, _ y: Int64, _ buttons: Int32, from writer: MouseWriter, msec: UInt32) {
    let wheel = buttons & Self.wheel
    let held = buttons & ~Self.wheel
    // devmouse's mousein: the bits this writer changed, in the buttons all
    // writers hold.
    let changed = held ^ writer.buttons
    writer.buttons = held
    inButtons = (held & changed) | (inButtons & ~changed)
    let others = state.buttons & ~changed & ~Self.wheel
    var px: Int64, py: Int64
    switch kind {
    case UInt8(ascii: "A"):
      (px, py) = (x, y)
    case UInt8(ascii: "a"):
      // 0 to 2^31 across the screen, rounded (scmousetrack).
      px = ((x & 0x7fff_ffff) * Int64(width) + (1 << 30)) >> 31
      py = ((y & 0x7fff_ffff) * Int64(height) + (1 << 30)) >> 31
    default:
      (px, py) = (Int64(state.x) + scale(x), Int64(state.y) + scale(y))
    }
    track(x: px, y: py, buttons: others, msec: msec)
    // A wheel's notch: pressed, then released.
    if wheel != 0 {
      track(x: Int64(state.x), y: Int64(state.y), buttons: (state.buttons & ~Self.wheel) | wheel, msec: msec)
      track(x: Int64(state.x), y: Int64(state.y), buttons: state.buttons & ~Self.wheel, msec: msec)
    }
  }

  /// devmouse's scale: slow motion as it is, faster motion multiplied.
  func scale(_ d: Int64) -> Int64 {
    guard acceleration != 0 else { return d }
    let sign: Int64 = d < 0 ? -1 : 1
    switch abs(d) {
    case 0...3: return d
    case 4: return sign * Int64(6 + (acceleration >> 2))
    case 5: return sign * Int64(9 + (acceleration >> 1))
    default: return d * Int64(maxAcceleration)
    }
  }

  /// absmousetrack: the pointer at x, y inside the screen, the buttons
  /// with those mousein's writers hold; a change of buttons is queued for
  /// each reader.
  func track(x: Int64, y: Int64, buttons: Int32, msec: UInt32) {
    let last = state.buttons
    state.x = Int32(min(max(x, 0), Int64(width) - 1))
    state.y = Int32(min(max(y, 0), Int64(height) - 1))
    state.buttons = buttons | inButtons
    state.msec = msec
    state.counter += 1
    if state.buttons != last {
      for r in readers where r.queue.count < Self.queueLimit { r.queue.append(state) }
    }
  }

  // MARK: mousectl

  /// A write to mousectl; false if it isn't a message mousectl takes.
  public func control(_ text: [UInt8]) -> Bool {
    let f = Self.fields(text)
    guard let verb = f.first else { return false }
    func named(_ s: String) -> Bool { verb.elementsEqual(s.utf8) }  // bytes: tier 0 has no Unicode tables
    if named("buttonmap") {
      return setButtonMap(f.count > 1 ? f[1] : Array("123".utf8))
    } else if named("swap") {
      guard setButtonMap(Array((swapped ? "123" : "321").utf8)) else { return false }
      swapped.toggle()
    } else if named("scrollswap") {
      scrollSwap.toggle()
    } else if named("accelerated") {
      var n: Int32 = 1
      if f.count > 1 {
        guard let v = Self.number(f[1]), v >= 0, v <= 1000 else { return false }
        n = v
      }
      acceleration = n
      maxAcceleration = n < 3 ? 2 : n
    } else if named("linear") {
      acceleration = 0
    } else if named("reset") {
      _ = setButtonMap(Array("123".utf8))
      swapped = false
      scrollSwap = false
      acceleration = 0
    } else {
      return false
    }
    return true
  }

  /// devmouse's setbuttonmap: the left, middle and right buttons numbered
  /// x, y and z.
  func setButtonMap(_ map: [UInt8]) -> Bool {
    guard map.count == 3 else { return false }
    var bit: [Int32] = [0, 0, 0]
    for (i, c) in map.enumerated() {
      guard c >= UInt8(ascii: "1"), c <= UInt8(ascii: "3"), bit[Int(c - UInt8(ascii: "1"))] == 0 else { return false }
      bit[Int(c - UInt8(ascii: "1"))] = 1 << i
    }
    var m: [Int32] = [0, 0, 0, 0, 0, 0, 0, 0]
    for i in 0..<8 {
      var x: Int32 = 0
      if i & 1 != 0 { x |= bit[0] }
      if i & 2 != 0 { x |= bit[1] }
      if i & 4 != 0 { x |= bit[2] }
      m[Int(x)] = Int32(i)
    }
    buttonMap = m
    return true
  }

  // MARK: text

  /// Fields split at blanks and tabs (a message's trailing newline too).
  static func fields(_ text: [UInt8]) -> [[UInt8]] {
    text.split(whereSeparator: { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }).map { Array($0) }
  }

  /// A decimal number, perhaps signed; nil past Int32.
  static func number(_ s: [UInt8]) -> Int32? {
    var i = 0
    var negative = false
    if i < s.count, s[i] == UInt8(ascii: "-") || s[i] == UInt8(ascii: "+") {
      negative = s[i] == UInt8(ascii: "-")
      i += 1
    }
    guard i < s.count else { return nil }
    var v: Int64 = 0
    while i < s.count {
      guard s[i] >= UInt8(ascii: "0"), s[i] <= UInt8(ascii: "9") else { return nil }
      v = v * 10 + Int64(s[i] - UInt8(ascii: "0"))
      guard v <= Int64(Int32.max) + 1 else { return nil }
      i += 1
    }
    if negative { v = -v }
    guard v >= Int64(Int32.min), v <= Int64(Int32.max) else { return nil }
    return Int32(v)
  }
}
