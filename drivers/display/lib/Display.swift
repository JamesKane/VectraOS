// SPDX-License-Identifier: BSD-3-Clause

// The display class's protocol (D120, after todhchai's): a display's
// driver host serves `Display`, its outputs (a scanout each), images it
// can show (a client's VMO the device reads: 32-bit pixels, 0x00RRGGBB
// little endian), which image each output shows, and the flush of an
// image's damage to the screen. The compositor is its client: Radharc
// composes into an image an output and flushes the damage each frame.
// Version 2: an output's refresh, and `outputsChanged` when a connector
// comes or goes or a mode changes. Version 3 (D146): `present`, which
// shows an image with its damage in one go, so a client drawing into one
// image while another is on the screen never tears.

import IPC
import Node

@IPCLibrary(id: "todhchai.display.device", version: 3)
public enum DisplayDeviceIPC {
  public enum DisplayError: Int32, IPCErrorCode, Sendable {
    case invalid = 1
    case notFound
    case unavailable
  }

  public struct Area: Equatable, Sendable {
    public var x: UInt32
    public var y: UInt32
    public var width: UInt32
    public var height: UInt32
    public init(x: UInt32, y: UInt32, width: UInt32, height: UInt32) {
      self.x = x
      self.y = y
      self.width = width
      self.height = height
    }
  }

  /// An output: its size now, whether it is enabled, and its mode's
  /// refresh (millihertz; 0 if the device doesn't say).
  public struct Output: Equatable, Sendable {
    public var id: UInt32
    public var width: UInt32
    public var height: UInt32
    public var enabled: Bool
    public var refresh: UInt32
    public init(id: UInt32, width: UInt32, height: UInt32, enabled: Bool, refresh: UInt32 = 0) {
      self.id = id
      self.width = width
      self.height = height
      self.enabled = enabled
      self.refresh = refresh
    }
  }

  public protocol Display {
    func outputs() -> [Output]
    /// The output's EDID, if the device has one (empty otherwise).
    func edid(output: UInt32) throws(DisplayError) -> [UInt8]
    /// `vmo` (its first `width` × `height` pixels, rows packed) as an image
    /// the device reads; its id.
    func attach(vmo: consuming Handle, width: UInt32, height: UInt32) throws(DisplayError) -> UInt32
    func detach(image: UInt32)
    /// The output shows the image (0: nothing).
    func show(output: UInt32, image: UInt32) throws(DisplayError)
    /// The image's `damage` goes to the screen, when the call returns.
    func flush(image: UInt32, damage: [Area]) throws(DisplayError)
    /// The output shows the image, with `damage` all its client wrote in
    /// it since it was last on the screen (nothing else changed), from the
    /// frame the call returns in: one latch.
    @since(3) func present(output: UInt32, image: UInt32, damage: [Area]) throws(DisplayError)
    /// A connector came or went, or a mode changed: ask `outputs` again.
    @since(2) @event func outputsChanged()
  }
}
