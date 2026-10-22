// SPDX-License-Identifier: BSD-3-Clause

// Hot reload's shared half (hotreload(2), D122): what a hot image and its
// host agree on. The image is a shared object exporting the state type's
// size and hash (@HotState) and `hot_frame(state, frame)`, which the host
// calls once a frame with the state block and a HotFrame, both as raw
// pointers (C's convention); HotFrame's fields are C's, so an image built
// from another version of the source still reads it.

/// A frame's worth of work for the image: the pixels to draw (`pixels`,
/// `stride` pixels a row, 0x00RRGGBB), the frame's number, the time it is
/// aimed at, and the keys pressed since the last frame (USB usages, up to
/// eight).
public struct HotFrame: BitwiseCopyable {
  public var pixels: UInt = 0
  public var width: Int32 = 0
  public var height: Int32 = 0
  public var stride: Int32 = 0
  public var keyCount: Int32 = 0
  public var frame: Int64 = 0
  /// Nanoseconds, monotonic.
  public var target: Int64 = 0
  public var keys: (UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16) = (0, 0, 0, 0, 0, 0, 0, 0)

  public init() {}

  /// Pixel (x, y), drawn.
  public func set(_ x: Int, _ y: Int, _ colour: UInt32) {
    guard x >= 0, y >= 0, x < Int(width), y < Int(height), let p = unsafe UnsafeMutablePointer<UInt32>(bitPattern: pixels)
    else { return }
    unsafe p[y * Int(stride) + x] = colour
  }

  /// The rectangle, filled.
  public func fill(x: Int, y: Int, width w: Int, height h: Int, _ colour: UInt32) {
    guard let p = unsafe UnsafeMutablePointer<UInt32>(bitPattern: pixels) else { return }
    let x0 = max(0, x), y0 = max(0, y), x1 = min(Int(width), x + w), y1 = min(Int(height), y + h)
    guard x0 < x1, y0 < y1 else { return }
    for row in y0..<y1 { for col in x0..<x1 { unsafe p[row * Int(stride) + col] = colour } }
  }
}

/// The program's state type, kept in the state block across reloads: data
/// alone (BitwiseCopyable), with its size and its layout's hash, which the
/// image exports as `hot_state_size` and `hot_state_hash`.
@attached(member, names: named(hotStateSize), named(hotStateHash))
@attached(extension, conformances: BitwiseCopyable)
@attached(peer, names: named(hot_state_size), named(hot_state_hash))
public macro HotState() = #externalMacro(module: "IPCMacros", type: "HotStateMacro")
