// SPDX-License-Identifier: BSD-3-Clause

// Events (sdk(2)): fixed-size records the loop hands out, from its own
// sources (timers, wakes, posts), its windows (configures, closes, frames,
// keys, the pointer and the wheel) and the plumber's ports it listens on.

/// A window, as an index plus a generation (principle 12). Zero for events
/// that don't belong to one.
public struct WindowID: Hashable, Sendable {
  public var index: UInt32
  public var generation: UInt32
  public static let none = WindowID(index: 0, generation: 0)
}

/// A timer the loop owns.
public struct TimerID: Hashable, Sendable { public var raw: UInt64 }

/// Two words posted to a loop, from any thread.
public struct Message: Hashable, Sendable {
  public var a: UInt64
  public var b: UInt64
  public init(_ a: UInt64, _ b: UInt64 = 0) {
    self.a = a
    self.b = b
  }
}

public struct Event: Sendable {
  public enum Payload: Sendable, Equatable {
    /// A timer's deadline came. `missed` counts repeats skipped because
    /// the loop was late.
    case timer(TimerID, missed: UInt64)
    /// A message posted to the loop.
    case message(Message)
    /// The loop was woken (wakes are coalesced: one event for many).
    case wake
    /// A window's size or focus changed; draw for this `configSeq`.
    case configure(Configure)
    /// The user asked to close a window (its close box), or the
    /// compositor closed it.
    case close
    /// Time to draw a window's next frame.
    case frame(Frame)
    /// A key went down.
    case keyDown(Key)
    case keyUp(Key)
    /// The pointer moved, or a button changed.
    case pointer(Pointer)
    /// The wheel turned.
    case wheel(Wheel)
    /// A window that placed itself (`placeWindow`) moved: its content's
    /// top left on the screen now.
    case moved(x: Int32, y: Int32)
    /// A view the window embedded (`embed`, its id) is gone: its program
    /// closed it, or ended.
    case viewGone(UInt32)
    /// A message the plumber sent to a port the loop listens on
    /// (`Loop.listen`).
    case routed(ListenID, RouteMessage)
    /// The theme in force changed (`Loop.followTheme`): `Loop.theme()` has
    /// the new one.
    case themeChanged
  }

  public var payload: Payload
  public var window: WindowID
  /// When the event was taken, on the monotonic clock.
  public var time: Deadline
  /// The event's place in this loop's sequence, from 1.
  public var seq: UInt64
}

/// The events one `wait` returned. Within a batch, `.frame` events come
/// last, so a frame is drawn for the newest configuration.
public struct Events: RandomAccessCollection, Sendable {
  let items: [Event]
  public var startIndex: Int { items.startIndex }
  public var endIndex: Int { items.endIndex }
  public subscript(i: Int) -> Event { items[i] }
}
