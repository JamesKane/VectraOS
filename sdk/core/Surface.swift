// SPDX-License-Identifier: BSD-3-Clause

// Windows' configurations, frames and CPU surfaces (sdk(2)).

/// A window's configuration (`configure`).
public struct Configure: Sendable, Equatable {
  /// The size in logical points.
  public var width: Int32
  public var height: Int32
  /// The size of a buffer that fills the window, in pixels.
  public var pixelWidth: Int32
  public var pixelHeight: Int32
  /// Scale as n/120 (120 is 1×, 180 is 1.5×).
  public var scale: UInt32
  /// Buffers presented for this configuration carry this number.
  public var configSeq: UInt64
  public var focused: Bool
}

/// A frame clock tick (`frame`).
public struct Frame: Sendable, Equatable {
  public var frameSeq: UInt64
  /// The best estimate of when the next frame will reach the glass.
  public var target: Deadline
  /// When the previous frame reached the glass, if known.
  public var presentedAt: Deadline?
  /// The output's refresh interval, if known.
  public var refresh: Duration?
  /// The times are the loop's estimates, not Radharc's answer to a present.
  public var estimated: Bool
}

/// Pixels to draw into: 0x00RRGGBB, sRGB, `stride` bytes a row. Present it
/// with `Loop.present`, which takes it back.
@safe public struct CPUSurface: ~Copyable {
  public let pixels: UnsafeMutableRawBufferPointer
  public let width: Int32
  public let height: Int32
  public let stride: Int
  /// Frames since this buffer was last presented (0: never), for partial redraw.
  public let age: UInt32
  let window: WindowID
  let buffer: Int

  /// Fills the surface with one colour (0x00RRGGBB).
  public func fill(_ xrgb: UInt32) {
    let words = unsafe pixels.bindMemory(to: UInt32.self)
    for i in words.indices { unsafe words[i] = xrgb }
  }
}
