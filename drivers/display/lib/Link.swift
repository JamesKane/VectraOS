// SPDX-License-Identifier: BSD-3-Clause

// A display engine's link to its monitor (D146): served by the engine's
// transmitter's driver (dptx(3)), followed by the engine's (linlon(3)),
// which says what it hears as the display class's `outputsChanged`.

import IPC
import Node

@IPCLibrary(id: "vectraos.display.link", version: 1)
public enum DisplayLinkIPC {
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

  public protocol Link {
    func sink() -> Sink
    /// The monitor's EDID (empty without one).
    func edid() -> [UInt8]
    /// HPD changed, or the sink's count or EDID did: ask again.
    @event func sinkChanged()
  }
}
