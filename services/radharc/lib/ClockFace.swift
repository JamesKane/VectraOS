// SPDX-License-Identifier: BSD-3-Clause

// The clock Radharc draws for a window (D114, Window's `showClock`): the
// time in an area of its content, right-aligned and centred in the
// theme's `deskbar.clock` style, so that the window (Deskbar's) never
// wakes for it. A face is drawn for a time and an area's size on the
// frame drawer's thread, the next minute's ahead of it, and swapped in
// at the minute; without the theme's faces the scene draws the time in
// its own 8x16 glyphs.

import UICore

public enum ClockText {
  /// `HH:MM`, or `h:MM AM` without `hours24`, for a minute of the day.
  public static func text(minuteOfDay: Int64, hours24: Bool) -> String {
    let h = (minuteOfDay / 60) % 24, m = minuteOfDay % 60
    let mm = (m < 10 ? "0" : "") + "\(m)"
    if hours24 { return (h < 10 ? "0" : "") + "\(h):" + mm }
    return "\(h % 12 == 0 ? 12 : h % 12):" + mm + (h < 12 ? " AM" : " PM")
  }

  /// The minute of the day (UTC) at `realtime` nanoseconds since the epoch.
  public static func minuteOfDay(_ realtime: Int64) -> Int64 { (realtime / 60_000_000_000) % (24 * 60) }
}

/// A clock's time drawn for an area's size, premultiplied.
@safe public final class ClockFace: @unchecked Sendable {
  public let text: String
  public let width: Int
  public let height: Int
  let storage: UnsafeMutablePointer<UInt32>

  public init(_ painter: inout Painter, text: String, width: Int, height: Int) {
    (self.text, self.width, self.height) = (text, max(1, width), max(1, height))
    let style = painter.theme.style("deskbar.clock")
    painter.list = DisplayList()
    let w = painter.measure(text, style)
    painter.text(text, Float(self.width) - w, (Float(self.height) - painter.lineHeight(style)) / 2, style)
    let pixels = matte(&painter, width: self.width, height: self.height)
    unsafe storage = UnsafeMutablePointer<UInt32>.allocate(capacity: pixels.count)
    for i in 0..<pixels.count { unsafe storage[i] = pixels[i] }
  }

  deinit { unsafe storage.deallocate() }

  public var pixels: Pixels {
    var p = unsafe Pixels(unsafe: UnsafeRawPointer(storage), width: width, height: height, stride: width)
    p.alpha = .premultiplied
    return p
  }

  /// Pixel `i` (tests).
  public func pixel(_ i: Int) -> UInt32 { unsafe storage[i] }

  /// Whether it was drawn for this.
  public func fits(text t: String, width w: Int, height h: Int) -> Bool {
    t.utf8.elementsEqual(text.utf8) && w == width && h == height
  }
}
