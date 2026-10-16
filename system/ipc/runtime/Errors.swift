// SPDX-License-Identifier: BSD-3-Clause

/// A method's own error type: an error with a positive `Int32` code, which
/// is what an error reply carries (docs/wire-format.md). An `Int32`-backed
/// enum gets the conformance's members for free.
public protocol IPCErrorCode: Error {
  var code: Int32 { get }
  init?(code: Int32)
}

extension IPCErrorCode where Self: RawRepresentable, RawValue == Int32 {
  public var code: Int32 { rawValue }
  public init?(code: Int32) { self.init(rawValue: code) }
}

extension Never: IPCErrorCode {
  public var code: Int32 { switch self {} }
  public init?(code: Int32) { nil }
}

/// Why a call failed.
public enum IPCError<Remote: IPCErrorCode>: Error {
  /// The method failed with its own error.
  case remote(Remote)
  /// The channel failed (closed, or a bad handle), or the server answered
  /// with a framework error, such as `notSupported` for an unknown method.
  case transport(Status)
  /// The peer broke the protocol: a malformed or unexpected message.
  case wire(WireError)
}

/// Runs `body`, reporting a wire error as an `IPCError`.
@inlinable
public func ipcWire<E: IPCErrorCode, R>(_: E.Type, _ body: () throws(WireError) -> R) throws(IPCError<E>) -> R {
  do {
    return try body()
  } catch {
    throw .wire(error)
  }
}

/// Runs `body`, reporting a transport status as an `IPCError`.
@inlinable
public func ipcTransport<E: IPCErrorCode, R>(_: E.Type, _ body: () throws(Status) -> R) throws(IPCError<E>) -> R {
  do {
    return try body()
  } catch {
    throw .transport(error)
  }
}
