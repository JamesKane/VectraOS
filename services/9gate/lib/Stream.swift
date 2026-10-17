// SPDX-License-Identifier: BSD-3-Clause

// What 9gate's 9P travels over: a byte stream, read and written in
// pieces, as a TCP conversation's data file is (ip(4)); 9P's messages
// out of it, each whole by its size; and the same stream sealed by a
// Noise IK session (noise(2)), its messages length-framed. A stream is
// a pair of closures, so a /net conversation, a channel or a test's
// pipe are one type.

import NineP
import Node
import Noise
import Sys

/// Why a connection ended or a call failed.
public enum GateError: Error, Equatable, Sendable {
  /// The stream closed, or failed.
  case closed
  /// The peer sent what isn't 9P (or doesn't decrypt).
  case protocolError(String)
  /// The server answered Rerror.
  case error(String)
}

/// Bytes each way. `read` returns at least one byte, or none at the end;
/// `write` takes all it is given; `close` hangs up, so the peer's reads
/// end (a refused caller's, or a finished export's).
public struct ByteStream: Sendable {
  public let read: @Sendable (Int) throws(GateError) -> [UInt8]
  public let write: @Sendable ([UInt8]) throws(GateError) -> Void
  public let close: @Sendable () -> Void

  public init(read: @escaping @Sendable (Int) throws(GateError) -> [UInt8],
              write: @escaping @Sendable ([UInt8]) throws(GateError) -> Void,
              close: @escaping @Sendable () -> Void) {
    self.read = read
    self.write = write
    self.close = close
  }

  /// A conversation's data file (dial(2)'s `data`), or any file read and
  /// written as a stream: reads on one channel to it and writes on
  /// another, since a read waits for bytes (D84) and a write for room
  /// (D94), each on its own channel. `close` hangs up (a conversation's
  /// ctl takes `hangup`).
  public static func node(read: consuming NodeIPC.NodeClient, write: consuming NodeIPC.NodeClient,
                          close: @escaping @Sendable () -> Void) -> ByteStream {
    let reader = Shared(read), writer = Shared(write)
    return ByteStream(
      read: { (max: Int) throws(GateError) -> [UInt8] in
        do {
          return try reader.call { (c: inout NodeIPC.NodeClient) throws(NodeIPC.NodeClient.Failure) in
            try c.read(offset: 0, max: UInt32(min(max, NodeIPC.maxIO)))
          }
        } catch { throw .closed }
      },
      write: { (bytes: [UInt8]) throws(GateError) -> Void in
        var at = 0
        while at < bytes.count {
          let piece = Array(bytes[at..<at + min(bytes.count - at, NodeIPC.maxIO)])
          let wrote: UInt32
          do {
            wrote = try writer.call { (c: inout NodeIPC.NodeClient) throws(NodeIPC.NodeClient.Failure) in
              try c.write(offset: 0, piece)
            }
          } catch { throw .closed }
          guard wrote > 0 else { throw .closed }
          at += Int(wrote)
        }
      },
      close: close)
  }

  /// One end of a channel, each message a piece of the stream (at most
  /// `Channel.maxBytes`); the end when the peer closes.
  public static func channel(_ end: consuming Handle) -> ByteStream {
    let ch = SharedHandle(end)
    let pending = Locked<[UInt8]>([])
    return ByteStream(
      read: { (max: Int) throws(GateError) -> [UInt8] in
        while true {
          let had = pending.withLock { (p: inout [UInt8]) -> [UInt8] in
            let n = min(max, p.count)
            defer { p.removeFirst(n) }
            return Array(p.prefix(n))
          }
          if !had.isEmpty { return had }
          do throws(Status) {
            let m = try ch.read()
            pending.withLock { $0 += m.bytes }
          } catch {
            guard error == .shouldWait else { return [] }
            do throws(Status) {
              _ = try ch.wait(Signals.readable | Signals.peerClosed)
            } catch { return [] }
          }
        }
      },
      write: { (bytes: [UInt8]) throws(GateError) -> Void in
        var at = 0
        while at < bytes.count {
          let n = min(bytes.count - at, Channel.maxBytes)
          do throws(Status) { try ch.write(Array(bytes[at..<at + n])) } catch { throw .closed }
          at += n
        }
      },
      close: { ch.close() })
  }
}

/// A Node client several threads share, one call at a time.
final class Shared: @unchecked Sendable {
  var client: NodeIPC.NodeClient
  let lock = Lock()

  init(_ client: consuming NodeIPC.NodeClient) { self.client = client }

  func call<R: ~Copyable, E: Error>(_ body: (inout NodeIPC.NodeClient) throws(E) -> R) throws(E) -> R {
    lock.lock()
    defer { lock.unlock() }
    return try body(&client)
  }
}

/// A channel end several threads share, until one closes it: then each
/// call fails as at a closed peer. It keeps the raw handle, lent to each
/// call as a Handle released after, not closed.
final class SharedHandle: @unchecked Sendable {
  var raw: UInt32?
  let lock = Lock()

  init(_ handle: consuming Handle) { raw = handle.release() }

  func lent<R>(_ raw: UInt32, _ body: (borrowing Handle) throws(Status) -> R) throws(Status) -> R {
    let h = Handle(raw: raw)
    do throws(Status) {
      let r = try body(h)
      _ = h.release()
      return r
    } catch {
      _ = h.release()
      throw error
    }
  }

  func read() throws(Status) -> Channel.Message {
    try lock.withLock { () throws(Status) -> Channel.Message in
      guard let raw else { throw .peerClosed }
      return try lent(raw) { (h: borrowing Handle) throws(Status) in try Channel.read(h) }
    }
  }

  func write(_ bytes: [UInt8]) throws(Status) {
    try lock.withLock { () throws(Status) in
      guard let raw else { throw .peerClosed }
      try lent(raw) { (h: borrowing Handle) throws(Status) in try Channel.write(h, bytes: bytes) }
    }
  }

  /// Waits outside the lock, so a close can come meanwhile: the wait then
  /// ends as the handle goes.
  func wait(_ signals: UInt32) throws(Status) -> UInt32 {
    guard let raw = lock.withLock({ self.raw }) else { throw .peerClosed }
    return try lent(raw) { (h: borrowing Handle) throws(Status) in try h.wait(for: signals) }
  }

  func close() {
    let r = lock.withLock { () -> UInt32? in
      defer { raw = nil }
      return raw
    }
    if let r { Sys.close(raw: r) }
  }

  deinit { close() }
}

/// 9P's messages out of a stream: each one whole, by its size, at most
/// `msize` bytes.
public final class MessageStream: @unchecked Sendable {
  let stream: ByteStream
  var buffer: [UInt8] = []
  let readLock = Lock(), writeLock = Lock()
  /// The largest message either way; Tversion's msize, once agreed.
  public var msize: UInt32

  public init(_ stream: ByteStream, msize: UInt32) {
    self.stream = stream
    self.msize = msize
  }

  /// The next message's bytes; `closed` at the stream's end.
  public func next() throws(GateError) -> [UInt8] {
    readLock.lock()
    defer { readLock.unlock() }
    while true {
      if buffer.count >= 4 {
        guard let size = Message.size(Array(buffer.prefix(4))), size <= Int(msize) else {
          throw .protocolError("bad message size")
        }
        if buffer.count >= size {
          defer { buffer.removeFirst(size) }
          return Array(buffer.prefix(size))
        }
      }
      let more = try stream.read(max(4096, Int(msize)))
      guard !more.isEmpty else { throw .closed }
      buffer += more
    }
  }

  /// The next message, decoded.
  public func receive() throws(GateError) -> Message {
    let bytes = try next()
    guard let m = Message.decode(bytes) else { throw .protocolError("bad message") }
    return m
  }

  public func send(_ message: Message) throws(GateError) {
    guard let bytes = message.encode(), bytes.count <= Int(msize) else {
      throw .protocolError("message too large")
    }
    writeLock.lock()
    defer { writeLock.unlock() }
    try stream.write(bytes)
  }
}

/// A stream sealed by a Noise IK session: its handshake first, then each
/// write in transport messages of at most `Noise.maxPayload` bytes, each
/// framed by its length. A failed handshake hangs up.
public enum SealedStream {
  /// The initiator's side, calling the responder whose static key is
  /// `remote`; the responder's key is checked by the handshake itself.
  public static func initiate<Key: NoiseKey>(_ raw: ByteStream, key: Key, remote: [UInt8], ephemeral: [UInt8],
                                             prologue: [UInt8]) throws(GateError) -> ByteStream {
    var h = Handshake(initiator: key, remote: remote, ephemeral: ephemeral, prologue: prologue)
    let frames = Frames(raw)
    do throws(GateError) {
      guard let first = h.write() else { throw .protocolError("handshake") }
      try raw.write(Frame.wrap(first))
      guard h.read(try frames.next()) != nil, let session = h.split() else { throw .protocolError("handshake") }
      return sealed(raw, frames, session)
    } catch {
      raw.close()
      throw error
    }
  }

  /// The responder's side: `accept` judges the caller's static key
  /// before the reply, which only an accepted caller gets.
  public static func respond<Key: NoiseKey>(_ raw: ByteStream, key: Key, ephemeral: [UInt8], prologue: [UInt8],
                                            accept: ([UInt8]) -> Bool) throws(GateError) -> (ByteStream, [UInt8]) {
    var h = Handshake(responder: key, ephemeral: ephemeral, prologue: prologue)
    let frames = Frames(raw)
    do throws(GateError) {
      guard h.read(try frames.next()) != nil, let caller = h.remoteStatic else { throw .protocolError("handshake") }
      // A refused caller gets no reply: the stream hangs up.
      guard accept(caller) else { throw .protocolError("caller refused") }
      guard let reply = h.write() else { throw .protocolError("handshake") }
      try raw.write(Frame.wrap(reply))
      guard let session = h.split() else { throw .protocolError("handshake") }
      return (sealed(raw, frames, session), caller)
    } catch {
      raw.close()
      throw error
    }
  }

  static func sealed(_ raw: ByteStream, _ frames: Frames, _ session: Session) -> ByteStream {
    // Each side uses its own half: sealing the send cipher, opening the
    // receive one, so the two copies never share a nonce.
    let send = Locked(session), receive = Locked(session)
    return ByteStream(
      read: { (max: Int) throws(GateError) -> [UInt8] in
        while true {
          let frame: [UInt8]
          do throws(GateError) { frame = try frames.next() } catch { return [] }  // the end
          guard let plain = receive.withLock({ $0.open(frame) }) else { throw .protocolError("bad transport message") }
          if !plain.isEmpty { return plain }
        }
      },
      write: { (bytes: [UInt8]) throws(GateError) -> Void in
        var at = 0
        while at < bytes.count {
          let n = min(bytes.count - at, Noise.maxPayload)
          let piece = Array(bytes[at..<at + n])
          // Sealed and written under one lock, so messages go in nonce order.
          let failed = send.withLock { (s: inout Session) -> GateError? in
            guard let m = s.seal(piece) else { return .protocolError("nonces spent") }
            do throws(GateError) { try raw.write(Frame.wrap(m)) } catch { return error }
            return nil
          }
          if let failed { throw failed }
          at += n
        }
      },
      close: raw.close)
  }
}

/// Noise messages out of a stream, by their length frames.
final class Frames: @unchecked Sendable {
  let raw: ByteStream
  var deframer = Deframer()
  let lock = Lock()

  init(_ raw: ByteStream) { self.raw = raw }

  func next() throws(GateError) -> [UInt8] {
    lock.lock()
    defer { lock.unlock() }
    while true {
      if let m = deframer.next() { return m }
      let more = try raw.read(Noise.maxMessage + 2)
      guard !more.isEmpty else { throw .closed }
      deframer.push(more)
    }
  }
}
