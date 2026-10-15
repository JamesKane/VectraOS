// SPDX-License-Identifier: BSD-3-Clause

// Binary PPM (P6) screendumps, as QEMU's `screendump` writes them, for the
// boot tests' pixel checks (croi's tools/check-pixels.py, in Swift).

public struct PPM {
  public var width: Int
  public var height: Int
  /// RGB, 3 bytes a pixel, row by row.
  public var pixels: [UInt8]

  public init(_ data: [UInt8]) throws(FormatError) {
    var fields: [String] = []
    var at = 0
    func isSpace(_ b: UInt8) -> Bool { b == 0x20 || (0x09...0x0D).contains(b) }
    while fields.count < 4 {
      while at < data.count, isSpace(data[at]) { at += 1 }
      guard at < data.count else { throw FormatError("not an 8-bit P6 PPM") }
      if data[at] == UInt8(ascii: "#") {
        while at < data.count, data[at] != 0x0A { at += 1 }
        at += 1
        continue
      }
      var end = at
      while end < data.count, !isSpace(data[end]) { end += 1 }
      fields.append(String(decoding: data[at..<end], as: UTF8.self))
      at = end
    }
    guard fields[0] == "P6", fields[3] == "255", let w = Int(fields[1]), let h = Int(fields[2]) else {
      throw FormatError("not an 8-bit P6 PPM")
    }
    width = w
    height = h
    // One whitespace byte ends the header.
    pixels = at + 1 <= data.count ? Array(data[(at + 1)...]) : []
    guard pixels.count >= w * h * 3 else { throw FormatError("truncated: \(pixels.count) bytes for \(w)x\(h)") }
  }

  /// The pixel at (x, y), or nil off the screen.
  public func pixel(_ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8)? {
    guard (0..<width).contains(x), (0..<height).contains(y) else { return nil }
    let at = (y * width + x) * 3
    return (pixels[at], pixels[at + 1], pixels[at + 2])
  }
}
