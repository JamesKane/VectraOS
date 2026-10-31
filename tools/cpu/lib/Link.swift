// SPDX-License-Identifier: BSD-3-Clause

// The terminal's connection to a node: bytes each way, over TCP, or any
// pair of closures (the tests join it to the node's side in memory).
// Sealed, it carries Noise IK's transport messages, each framed by its
// length (Noise's Frame), as 9gate's sealed streams do.

import HostSystem
import Noise

public struct TerminalError: Error, CustomStringConvertible, Sendable {
  public let description: String
  public init(_ description: String) { self.description = description }
}

/// Bytes each way: `read` gives what has come, at most `max`, and empty
/// at the end; `close` hangs up, ending a read waiting in another thread.
public struct Link: Sendable {
  public let read: @Sendable (Int) -> [UInt8]
  public let write: @Sendable ([UInt8]) throws(TerminalError) -> Void
  public let close: @Sendable () -> Void

  public init(read: @escaping @Sendable (Int) -> [UInt8], write: @escaping @Sendable ([UInt8]) throws(TerminalError) -> Void,
              close: @escaping @Sendable () -> Void) {
    self.read = read
    self.write = write
    self.close = close
  }

  /// Dials `host` (a name or address) at `port`. With a `timeout`, in
  /// seconds, the dial and each read and write give up after it, a read
  /// as if the node had hung up: for a node that may not be there yet.
  public static func tcp(_ host: String, port: Int, timeout: Double? = nil) throws(TerminalError) -> Link {
    var hints = addrinfo()
    hints.ai_family = AF_UNSPEC
    hints.ai_socktype = streamSocket
    var found: UnsafeMutablePointer<addrinfo>?
    let status = getaddrinfo(host, String(port), &hints, &found)
    guard status == 0, let first = found else {
      throw TerminalError("\(host): \(String(cString: gai_strerror(status)))")
    }
    defer { freeaddrinfo(first) }
    var why = "no address"
    var each: UnsafeMutablePointer<addrinfo>? = first
    while let a = each {
      let fd = openSocket(a.pointee.ai_family, a.pointee.ai_socktype, a.pointee.ai_protocol)
      if fd >= 0 {
        if let timeout {
          // Linux's connect keeps to the send timeout.
          var t = timeval(tv_sec: Int(timeout), tv_usec: .init((timeout - Double(Int(timeout))) * 1_000_000))
          let size = socklen_t(MemoryLayout<timeval>.size)
          setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &t, size)
          setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &t, size)
        }
        if connect(fd, a.pointee.ai_addr, a.pointee.ai_addrlen) == 0 { return descriptor(fd) }
        why = String(cString: strerror(errno))
        HostSystem.close(fd)
      }
      each = a.pointee.ai_next
    }
    throw TerminalError("\(host)!\(port): \(why)")
  }

  /// A connected socket's link; closing shuts it down both ways, which
  /// ends a read waiting on it, then closes it once.
  static func descriptor(_ fd: Int32) -> Link {
    let closed = Once()
    return Link(
      read: { max in
        var buffer = [UInt8](repeating: 0, count: max)
        while true {
          let n = buffer.withUnsafeMutableBytes { HostSystem.read(fd, $0.baseAddress, max) }
          if n < 0, errno == EINTR { continue }
          return n > 0 ? Array(buffer[0..<n]) : []
        }
      },
      write: { (bytes: [UInt8]) throws(TerminalError) in
        var at = 0
        while at < bytes.count {
          let n = bytes[at...].withUnsafeBytes { send(fd, $0.baseAddress, $0.count, sendNoSignal) }
          if n < 0, errno == EINTR { continue }
          guard n > 0 else { throw TerminalError("connection closed") }
          at += n
        }
      },
      close: {
        guard closed.first() else { return }
        shutdown(fd, Int32(SHUT_RDWR))
        HostSystem.close(fd)
      })
  }
}

/// True the first time it is asked.
final class Once: @unchecked Sendable {
  let lock = Lock()
  var done = false

  func first() -> Bool {
    lock.withLock {
      defer { done = true }
      return !done
    }
  }
}

/// A link sealed by a Noise IK session, the terminal its initiator.
public final class SealedLink: @unchecked Sendable {
  let raw: Link
  var deframer = Deframer()
  var send: Session
  var receive: Session
  let readLock = Lock(), writeLock = Lock()
  /// What a transport message held beyond what a read took.
  var pending: [UInt8] = []

  /// Calls the node whose static key is `remote` as `key`, with a fresh
  /// ephemeral key from `random`; the handshake checks the node's key.
  public init(_ raw: Link, key: StaticKey, remote: [UInt8], prologue: [UInt8],
              random: () -> [UInt8] = { SealedLink.random(Noise.keySize) }) throws(TerminalError) {
    self.raw = raw
    var h = Handshake(initiator: key, remote: remote, ephemeral: random(), prologue: prologue)
    do throws(TerminalError) {
      guard let first = h.write() else { throw TerminalError("handshake") }
      try raw.write(Frame.wrap(first))
      var frames = Deframer()
      let reply = try Self.frame(raw, &frames)
      guard h.read(reply) != nil, let session = h.split() else {
        throw TerminalError("handshake failed: not the node's key?")
      }
      deframer = frames
      send = session
      receive = session
    } catch {
      raw.close()
      throw error
    }
  }

  static func frame(_ raw: Link, _ deframer: inout Deframer) throws(TerminalError) -> [UInt8] {
    while true {
      if let m = deframer.next() { return m }
      let more = raw.read(Noise.maxMessage + 2)
      guard !more.isEmpty else { throw TerminalError("the node hung up") }
      deframer.push(more)
    }
  }

  /// Bytes from the system's randomness.
  public static func random(_ count: Int) -> [UInt8] {
    var g = SystemRandomNumberGenerator()
    return (0..<count).map { _ in UInt8.random(in: 0...255, using: &g) }
  }

  /// What comes next, at most `max` bytes; empty at the end.
  public func read(_ max: Int) throws(TerminalError) -> [UInt8] {
    try readLock.withLock { () throws(TerminalError) in try readLocked(max) }
  }

  func readLocked(_ max: Int) throws(TerminalError) -> [UInt8] {
    while pending.isEmpty {
      let frame: [UInt8]
      do throws(TerminalError) { frame = try Self.frame(raw, &deframer) } catch { return [] }
      guard let plain = receive.open(frame) else { throw TerminalError("bad transport message") }
      pending = plain
    }
    let n = min(max, pending.count)
    defer { pending.removeFirst(n) }
    return Array(pending.prefix(n))
  }

  public func write(_ bytes: [UInt8]) throws(TerminalError) {
    try writeLock.withLock { () throws(TerminalError) in try writeLocked(bytes) }
  }

  func writeLocked(_ bytes: [UInt8]) throws(TerminalError) {
    var at = 0
    while at < bytes.count {
      let n = min(bytes.count - at, Noise.maxPayload)
      guard let m = send.seal(Array(bytes[at..<at + n])) else { throw TerminalError("nonces spent") }
      try raw.write(Frame.wrap(m))
      at += n
    }
  }

  public func close() { raw.close() }
}
