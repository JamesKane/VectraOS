// SPDX-License-Identifier: BSD-3-Clause

// A display engine's link to its monitor (D146): served by the engine's
// transmitter's driver (dptx(3)), followed by the engine's (linlon(3)),
// which says what it hears as the display class's `outputsChanged`.
// Version 2: what the link can carry, and the stream stopped while the
// engine changes its mode and started again for the new one, the link
// trained at another rate where it must be.

import IPC
import Node

@IPCLibrary(id: "vectraos.display.link", version: 2)
public enum DisplayLinkIPC {
  public enum LinkError: Int32, IPCErrorCode, Sendable {
    /// No monitor is there.
    case noSink = 1
    /// No link the sink and the PHY have carries the timing.
    case tooFast
    /// The timing isn't one: syncs out of order, or a zero clock.
    case invalid
    /// No link that would carry it trained.
    case trainingFailed
  }

  /// The sink as the transmitter last read it.
  public struct Sink: Equatable, Sendable {
    /// HPD is high and, behind a branch such as a DisplayPort-to-HDMI
    /// converter, a monitor is counted.
    public var connected: Bool
    /// The DPCD's sink count.
    public var count: UInt32
    public init(connected: Bool, count: UInt32) {
      self.connected = connected
      self.count = count
    }
  }

  /// A stream's timing as the engine sends it (VESA's terms): the pixel
  /// clock in kHz, and in `flags` bit 0 a positive hsync, bit 1 a
  /// positive vsync.
  public struct Timing: Equatable, Sendable {
    public var clock: UInt32
    public var hActive: UInt32
    public var hSyncStart: UInt32
    public var hSyncEnd: UInt32
    public var hTotal: UInt32
    public var vActive: UInt32
    public var vSyncStart: UInt32
    public var vSyncEnd: UInt32
    public var vTotal: UInt32
    public var flags: UInt32
    public init(clock: UInt32, hActive: UInt32, hSyncStart: UInt32, hSyncEnd: UInt32, hTotal: UInt32,
                vActive: UInt32, vSyncStart: UInt32, vSyncEnd: UInt32, vTotal: UInt32, flags: UInt32) {
      self.clock = clock
      self.hActive = hActive
      self.hSyncStart = hSyncStart
      self.hSyncEnd = hSyncEnd
      self.hTotal = hTotal
      self.vActive = vActive
      self.vSyncStart = vSyncStart
      self.vSyncEnd = vSyncEnd
      self.vTotal = vTotal
      self.flags = flags
    }
  }

  public protocol Link {
    func sink() -> Sink
    /// The monitor's EDID (empty without one).
    func edid() -> [UInt8]
    /// HPD changed, or the sink's count or EDID did: ask again.
    @event func sinkChanged()
    /// The fastest pixel clock (kHz) the sink's best link carries at 24
    /// bits a pixel; 0 without a sink.
    @since(2) func capacity() -> UInt32
    /// The stream stopped, while the engine changes its timing.
    @since(2) func stop()
    /// The stream started for `timing`, the link trained first where the
    /// one up doesn't carry it.
    @since(2) func start(timing: Timing) throws(LinkError)
  }
}
