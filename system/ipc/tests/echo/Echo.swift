// SPDX-License-Identifier: BSD-3-Clause

// The test library, and a server for it. The macro builds it into the
// Swift tests; idlc reads this file for the C header in system/ipc/tests/c/generated.

import IPC

@IPCLibrary(id: "todhchai.test", version: 3)
public enum TestIPC {
  public enum EchoError: Int32, IPCErrorCode {
    case tooLong = 1
  }

  public enum Shape: UInt8, Sendable {
    case circle = 1, square
    case triangle = 7
  }

  public struct Point: Equatable, Sendable {
    public var x: Int32
    public var y: Int32
  }

  /// One of everything copyable.
  public struct Shaped: Equatable, Sendable {
    public var shape: Shape
    public var at: Point
    public var label: String?
    public var tags: [String]
    public var path: [Point]
    public var weight: UInt16?
    public var data: [UInt8]
    public var flag: Bool
  }

  /// A struct that carries handles, so it moves.
  public struct Carried: ~Copyable {
    public var name: String
    public var handle: Handle
    public var spare: Handle?
    public var inner: Shaped?
  }

  public protocol Echo {
    func say(_ text: String, times: UInt32) throws(EchoError) -> String
    @oneway func note(_ value: UInt64, loud: Bool)
    @event func ticked(_ n: UInt32, label: String)
    func swap(_ handle: consuming Handle) -> Handle
    @since(2) func noted() -> UInt64
    @since(3) func reflect(_ s: Shaped) -> Shaped
    @since(3) func carry(_ c: consuming Carried) -> Carried
    @since(3) func many(_ shapes: [Shaped], nested: [[UInt32]], maybe: [Point]?) -> [Shaped]
    @since(3) func optionals(_ text: String?, bytes: [UInt8]?, point: Point?, handle: consuming Handle?) -> Handle?
  }

  /// Echo, composed, and louder.
  public protocol Loud: Echo {
    func shout(_ text: String) -> String
    @event func shouted(_ text: String)
  }
}

public typealias EchoError = TestIPC.EchoError

public struct EchoImpl: TestIPC.EchoHandler {
  var notes: UInt64 = 0

  public init() {}

  public mutating func say(_ text: String, times: UInt32) throws(EchoError) -> String {
    guard text.utf8.count * Int(times) <= 64 else { throw .tooLong }
    return String(repeating: text, count: Int(times))
  }

  public mutating func note(_ value: UInt64, loud: Bool) { notes += loud ? value * 2 : value }

  public mutating func swap(_ handle: consuming Handle) -> Handle { handle }

  public mutating func noted() -> UInt64 { notes }

  public mutating func reflect(_ s: TestIPC.Shaped) -> TestIPC.Shaped { s }

  /// Renames it and swaps its two handles (the spare, if any, comes back
  /// as the handle).
  public mutating func carry(_ c: consuming TestIPC.Carried) -> TestIPC.Carried {
    let c = c
    guard let spare = c.spare else {
      return TestIPC.Carried(name: c.name + "!", handle: c.handle, spare: nil, inner: c.inner)
    }
    return TestIPC.Carried(name: c.name + "!", handle: spare, spare: c.handle, inner: c.inner)
  }

  /// The shapes, then one per nested list (its sum as the weight) and one
  /// for `maybe` if present (its points as the path).
  public mutating func many(_ shapes: [TestIPC.Shaped], nested: [[UInt32]], maybe: [TestIPC.Point]?) -> [TestIPC.Shaped] {
    var out = shapes
    for list in nested {
      out.append(TestIPC.Shaped(shape: .square, at: TestIPC.Point(x: 0, y: 0), label: nil, tags: [],
                                path: [], weight: UInt16(list.reduce(0, +)), data: [], flag: false))
    }
    if let maybe {
      out.append(TestIPC.Shaped(shape: .triangle, at: TestIPC.Point(x: 1, y: 1), label: "maybe", tags: ["m"],
                                path: maybe, weight: nil, data: [1], flag: true))
    }
    return out
  }

  /// The handle back, if one came and everything else was present.
  public mutating func optionals(_ text: String?, bytes: [UInt8]?, point: TestIPC.Point?, handle: consuming Handle?)
    -> Handle?
  {
    guard text != nil, bytes != nil, point != nil else { return nil }
    return handle
  }
}

/// Echo's methods, and shouting.
public struct LoudImpl: TestIPC.LoudHandler {
  var echo = EchoImpl()

  public init() {}

  /// ASCII only: tier 0 links no Unicode case tables.
  public mutating func shout(_ text: String) -> String {
    String(decoding: text.utf8.map { $0 >= 0x61 && $0 <= 0x7a ? $0 - 0x20 : $0 }, as: UTF8.self)
  }

  public mutating func say(_ text: String, times: UInt32) throws(EchoError) -> String { try echo.say(text, times: times) }
  public mutating func note(_ value: UInt64, loud: Bool) { echo.note(value, loud: loud) }
  public mutating func swap(_ handle: consuming Handle) -> Handle { handle }
  public mutating func noted() -> UInt64 { echo.noted() }
  public mutating func reflect(_ s: TestIPC.Shaped) -> TestIPC.Shaped { s }
  public mutating func carry(_ c: consuming TestIPC.Carried) -> TestIPC.Carried { echo.carry(c) }
  public mutating func many(_ shapes: [TestIPC.Shaped], nested: [[UInt32]], maybe: [TestIPC.Point]?) -> [TestIPC.Shaped] {
    echo.many(shapes, nested: nested, maybe: maybe)
  }
  public mutating func optionals(_ text: String?, bytes: [UInt8]?, point: TestIPC.Point?, handle: consuming Handle?)
    -> Handle?
  {
    echo.optionals(text, bytes: bytes, point: point, handle: handle)
  }
}
