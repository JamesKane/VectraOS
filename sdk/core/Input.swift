// SPDX-License-Identifier: BSD-3-Clause

// Input events (sdk(2)): keys by HID usage, the pointer and its buttons,
// and the wheel, as Radharc puts them on a window's ring.

public struct Modifiers: OptionSet, Hashable, Sendable {
  public let rawValue: UInt8
  public init(rawValue: UInt8) { self.rawValue = rawValue }
  public static let shift = Modifiers(rawValue: 1 << 0)
  public static let control = Modifiers(rawValue: 1 << 1)
  public static let alt = Modifiers(rawValue: 1 << 2)
  public static let `super` = Modifiers(rawValue: 1 << 3)
  public static let capsLock = Modifiers(rawValue: 1 << 4)
}

/// A key press or release.
public struct Key: Sendable, Equatable {
  /// The physical key, whatever the layout.
  public var usage: KeyUsage
  /// The modifiers held after it.
  public var modifiers: Modifiers
  /// The character the key gives in the layout, unshifted (0 for none:
  /// a modifier, an arrow, a function key).
  public var character: UInt32
  /// A repeat of a key held down, not a new press.
  public var isRepeat: Bool
  /// When it happened, if the device said.
  public var time: Deadline? = nil
}

public enum PointerButton: Sendable, Equatable {
  case left, right, middle
  case other(UInt32)
}

public struct Pointer: Sendable, Equatable {
  public enum Action: Sendable, Equatable {
    case motion
    case down(PointerButton)
    case up(PointerButton)
  }
  public var action: Action
  /// The position in the window, in logical points.
  public var x: Double
  public var y: Double
  public var modifiers: Modifiers
}

public struct Wheel: Sendable, Equatable {
  /// Scroll distance in logical points (positive: right, down).
  public var dx: Double
  public var dy: Double
  /// Wheel notches.
  public var stepsX: Double
  public var stepsY: Double
  public var modifiers: Modifiers
}
