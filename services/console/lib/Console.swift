// SPDX-License-Identifier: BSD-3-Clause

// The framebuffer console's text (M3j): a grid of cells that UTF-8 text is
// written into, wrapping and scrolling, and a renderer that draws the rows
// that changed into a 32-bit framebuffer with a bitmap font. Scrolling
// redraws from the grid rather than moving pixels: the framebuffer is
// mapped write-combining, which is fast to write and slow to read.

/// The desktop's "Neon Tab" colors (docs/desktop.md §6), as 0xRRGGBB.
public enum Palette {
  public static let background: UInt32 = 0x0A0A12  // bg.0
  public static let phosphor: UInt32 = 0x39FF88  // the terminal default
  public static let ink: UInt32 = 0xD8E1FF
  public static let cyan: UInt32 = 0x00E5FF
  public static let amber: UInt32 = 0xFFB000  // warnings
  public static let magenta: UInt32 = 0xFF2BD6  // errors

  /// By a cell's color index.
  public static let colors: [UInt32] = [phosphor, ink, cyan, amber, magenta]
}

/// Cells of text: a code point and a color index each.
public struct TextGrid: Sendable {
  public let columns: Int
  public let rows: Int
  var cells: [UInt32]
  var colors: [UInt8]
  /// Grid row 0 is storage row `top` (scrolling moves `top`).
  var top = 0
  public private(set) var column = 0
  public private(set) var row = 0
  /// Rows to draw again, by screen row; all of them after a scroll.
  public private(set) var dirty: [Bool]
  public var color: UInt8 = 0
  /// A UTF-8 sequence cut between writes, and what's left of an escape.
  var pending: [UInt8] = []
  var escape = Escape.none

  enum Escape { case none, started, csi }

  public init(columns: Int, rows: Int) {
    precondition(columns > 0 && rows > 0)
    self.columns = columns
    self.rows = rows
    cells = [UInt32](repeating: 0x20, count: columns * rows)
    colors = [UInt8](repeating: 0, count: columns * rows)
    dirty = [Bool](repeating: true, count: rows)
  }

  func index(_ r: Int, _ c: Int) -> Int { ((top + r) % rows) * columns + c }

  /// The code point and color at screen row `r`, column `c`.
  public func cell(_ r: Int, _ c: Int) -> (codepoint: UInt32, color: UInt8) {
    let i = index(r, c)
    return (cells[i], colors[i])
  }

  /// Screen row `r` as text, trailing spaces dropped.
  public func text(_ r: Int) -> String {
    var scalars: [UInt32] = []
    for c in 0..<columns { scalars.append(cell(r, c).codepoint) }
    while scalars.last == 0x20 { scalars.removeLast() }
    var utf8: [UInt8] = []
    for s in scalars { encode(s, into: &utf8) }
    return String(decoding: utf8, as: UTF8.self)
  }

  public mutating func clean() {
    for i in 0..<rows { dirty[i] = false }
  }

  /// Writes UTF-8 text: printable characters at the cursor, wrapping at
  /// the right edge; \n, \r, \t and backspace move it; other controls and
  /// ANSI escape sequences (ESC [ ... final) are dropped. Invalid bytes
  /// show as U+FFFD.
  public mutating func write(_ bytes: [UInt8]) {
    for b in bytes { byte(b) }
  }

  mutating func byte(_ b: UInt8) {
    switch escape {
    case .started:
      escape = b == UInt8(ascii: "[") ? .csi : .none
      return
    case .csi:
      if b >= 0x40 && b <= 0x7E { escape = .none }
      return
    case .none:
      break
    }
    if !pending.isEmpty && b & 0xC0 != 0x80 {
      // A sequence cut short: replaced, and this byte read afresh.
      pending = []
      put(0xFFFD)
    }
    if !pending.isEmpty || b >= 0x80 {
      if pending.isEmpty {
        guard b >= 0xC2 && b <= 0xF4 else {
          put(0xFFFD)
          return
        }
        pending = [b]
        return
      }
      pending.append(b)
      let need = pending[0] >= 0xF0 ? 4 : pending[0] >= 0xE0 ? 3 : 2
      guard pending.count == need else { return }
      var v = UInt32(pending[0]) & (need == 2 ? 0x1F : need == 3 ? 0x0F : 0x07)
      for c in pending.dropFirst() { v = v << 6 | UInt32(c & 0x3F) }
      let minimum: UInt32 = need == 2 ? 0x80 : need == 3 ? 0x800 : 0x10000
      pending = []
      put(v < minimum || v > 0x10FFFF || (v >= 0xD800 && v < 0xE000) ? 0xFFFD : v)
      return
    }
    switch b {
    case 0x0A: newline()
    case 0x0D: column = 0
    case 0x09:
      // To the next stop, or the last column (a tab doesn't wrap).
      let stop = min(column + 8 - column % 8, columns - 1)
      while column < stop { put(0x20) }
    case 0x08: if column > 0 { column -= 1 }
    case 0x1B: escape = .started
    case 0x20...0x7E: put(UInt32(b))
    default: break
    }
  }

  mutating func put(_ codepoint: UInt32) {
    if column == columns { newline() }
    let i = index(row, column)
    cells[i] = codepoint
    colors[i] = color
    dirty[row] = true
    column += 1
  }

  mutating func newline() {
    column = 0
    if row + 1 < rows {
      row += 1
      return
    }
    // Scroll: the top row becomes the new bottom one, cleared.
    let bottom = top
    top = (top + 1) % rows
    for c in 0..<columns {
      cells[bottom * columns + c] = 0x20
      colors[bottom * columns + c] = 0
    }
    for i in 0..<rows { dirty[i] = true }
  }
}

/// UTF-8 for a scalar.
func encode(_ v: UInt32, into out: inout [UInt8]) {
  switch v {
  case 0..<0x80: out.append(UInt8(v))
  case 0x80..<0x800: out += [UInt8(0xC0 | v >> 6), UInt8(0x80 | v & 0x3F)]
  case 0x800..<0x10000: out += [UInt8(0xE0 | v >> 12), UInt8(0x80 | (v >> 6) & 0x3F), UInt8(0x80 | v & 0x3F)]
  default:
    out += [UInt8(0xF0 | v >> 18), UInt8(0x80 | (v >> 12) & 0x3F), UInt8(0x80 | (v >> 6) & 0x3F), UInt8(0x80 | v & 0x3F)]
  }
}

/// How a 32-bit pixel holds its colors (Zircon's zbi_pixel_format_t,
/// as croi's boot data gives it).
public enum PixelFormat: Sendable {
  /// The word 0x00RRGGBB: byte 0 blue (GOP's BGRX).
  case rgbx888
  /// Byte 0 red, 1 green, 2 blue (GOP's RGBX).
  case bgr888x

  public init?(zbi: UInt32) {
    switch zbi {
    case 0x0004_0005: self = .rgbx888
    case 0x0004_000B: self = .bgr888x
    default: return nil
    }
  }

  public func pixel(_ rgb: UInt32) -> UInt32 {
    switch self {
    case .rgbx888: rgb & 0xFF_FFFF
    case .bgr888x: (rgb >> 16 & 0xFF) | (rgb & 0xFF00) | (rgb & 0xFF) << 16
    }
  }
}

/// Draws a grid into a framebuffer: `width` by `height` pixels, `stride`
/// pixels a line, 32 bits each, at `base` (mapped by the caller, who keeps
/// it mapped). The grid's cells start at the top left; what's right of and
/// below them is background.
@safe public final class Renderer: @unchecked Sendable {
  public let font: Font
  public let format: PixelFormat
  let base: UInt
  public let width: Int
  public let height: Int
  public let stride: Int
  var line: [UInt32]
  var cleared = false
  /// Colors as pixels, by index, and the background.
  let pixels: [UInt32]
  let background: UInt32
  /// A missing glyph's stand-in: U+FFFD if the font has it, else '?'
  /// (Spleen has none).
  let replacement: Int

  public init(unsafe base: UnsafeMutableRawPointer, width: Int, height: Int, stride: Int, format: PixelFormat, font: Font) {
    self.base = unsafe UInt(bitPattern: base)
    self.width = width
    self.height = height
    self.stride = stride
    self.format = format
    self.font = font
    line = [UInt32](repeating: 0, count: width)
    pixels = Palette.colors.map { format.pixel($0) }
    background = format.pixel(Palette.background)
    replacement = font.glyph(0xFFFD) ?? font.glyph(0x3F) ?? 0
  }

  /// The grid that fits.
  public func grid() -> TextGrid { TextGrid(columns: max(1, width / font.width), rows: max(1, height / font.height)) }

  /// Draws the grid's dirty rows (all of them the first time, with the
  /// margins), and marks them clean. The rows drawn.
  @discardableResult
  public func render(_ grid: inout TextGrid) -> Int {
    if !cleared {
      clear()
      cleared = true
    }
    var drawn = 0
    for r in 0..<grid.rows where grid.dirty[r] {
      draw(grid, r)
      drawn += 1
    }
    grid.clean()
    return drawn
  }

  func clear() {
    for x in 0..<width { line[x] = background }
    for y in 0..<height { store(y) }
  }

  /// Screen row `r`: each of its pixel lines composed, then written in one
  /// sequential copy (write-combining memory likes long runs).
  func draw(_ grid: TextGrid, _ r: Int) {
    let w = font.width
    let cols = min(grid.columns, width / w)
    var glyphs: [Int] = []
    var fg: [UInt32] = []
    for c in 0..<cols {
      let cell = grid.cell(r, c)
      glyphs.append(font.glyph(cell.codepoint) ?? replacement)
      fg.append(pixels[Int(cell.color) % pixels.count])
    }
    for y in 0..<font.height {
      let py = r * font.height + y
      guard py < height else { break }
      for c in 0..<cols {
        let bits = font.row(glyphs[c], y)
        for x in 0..<w { line[c * w + x] = bits & (0x8000_0000 >> UInt32(x)) != 0 ? fg[c] : background }
      }
      store(py)
    }
  }

  func store(_ y: Int) {
    let at = base + UInt(y * stride * 4)
    unsafe line.withUnsafeBytes { src in
      unsafe UnsafeMutableRawPointer(bitPattern: at)!.copyMemory(from: src.baseAddress!, byteCount: src.count)
    }
  }
}

extension TextGrid {
  /// A grid of another size holding `other`'s text and colors: its rows
  /// from the top, the last `rows` of them if there are more, each cut to
  /// `columns`. The cursor ends below the last.
  public init(columns: Int, rows: Int, from other: TextGrid) {
    self.init(columns: columns, rows: rows)
    var last = other.row
    if other.column == 0 && last > 0 { last -= 1 }
    let first = max(0, last - rows + 2)
    for r in first...last {
      var end = other.columns
      while end > 0 && (other.cell(r, end - 1).codepoint == 0x20 || other.cell(r, end - 1).codepoint == 0) { end -= 1 }
      for c in 0..<min(end, columns) {
        let cell = other.cell(r, c)
        var bytes: [UInt8] = []
        encode(cell.codepoint == 0 ? 0x20 : cell.codepoint, into: &bytes)
        color = cell.color
        write(bytes)
      }
      write([0x0A])
    }
    color = other.color
  }
}
