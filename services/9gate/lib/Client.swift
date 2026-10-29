// SPDX-License-Identifier: BSD-3-Clause

// A 9P2000 client: Tversion first, then any number of calls at once from
// any threads, each under a tag of its own, their replies handed back by
// a reader thread as they come, in whatever order the server sends them.
// Fids are the client's to number; `fid()` gives a free one.

import NineP
import Sys

public final class NinePClient: @unchecked Sendable {
  let stream: MessageStream
  let lock = Lock()
  /// Calls waiting, by tag.
  var waiting: [(tag: UInt16, call: Call)] = []
  var nextTag: UInt16 = 0
  var freeFids: [UInt32] = []
  var nextFid: UInt32 = 0
  /// Why the connection ended, once it has.
  var ended: GateError?
  /// The dialect agreed: `9P2000.vx` or `9P2000`.
  public let version: String

  /// Agrees the version over `stream` (asking `9P2000.vx`, taking
  /// `9P2000`) and the msize, at most `msize`, then starts the reader.
  public init(_ stream: ByteStream, msize: UInt32 = 65536 + NineP.ioHeader) throws(GateError) {
    let messages = MessageStream(stream, msize: msize)
    try messages.send(Message(tag: NineP.noTag, .tversion(msize: msize, version: NineP.extendedVersion)))
    guard case .rversion(let agreed, let version) = try messages.receive().fcall,
          agreed >= NineP.minMessage, agreed <= msize, let dialect = Version.dialect(version)
    else { throw .protocolError("version refused") }
    messages.msize = agreed
    self.stream = messages
    self.version = dialect
    do throws(Status) {
      _ = try Thread.spawn { [self] in readReplies() }
    } catch { throw .closed }
  }

  /// The most data one read or write carries.
  public var iounit: UInt32 { stream.msize - NineP.ioHeader }

  /// A fid no file holds; give it back with `release` once clunked.
  public func fid() -> UInt32 {
    lock.withLock {
      if let f = freeFids.popLast() { return f }
      defer { nextFid += 1 }
      return nextFid
    }
  }

  public func release(_ fid: UInt32) { lock.withLock { freeFids.append(fid) } }

  /// Sends `request` and waits for its reply: Rerror is `.error`, with
  /// the server's text.
  public func rpc(_ request: Fcall) throws(GateError) -> Fcall {
    let call = Call()
    let tag: UInt16 = try lock.withLock { () throws(GateError) -> UInt16 in
      if let ended { throw ended }
      // A tag no call holds; NOTAG is Tversion's.
      repeat { nextTag = nextTag == NineP.noTag - 1 ? 0 : nextTag + 1 } while waiting.contains { $0.tag == nextTag }
      waiting.append((nextTag, call))
      return nextTag
    }
    do throws(GateError) {
      try stream.send(Message(tag: tag, request))
    } catch {
      lock.withLock { waiting.removeAll { $0.tag == tag } }
      end(error)
      throw error
    }
    let reply = try call.wait()
    if case .rerror(let ename) = reply { throw .error(ename) }
    return reply
  }

  func readReplies() {
    while true {
      let m: Message
      do throws(GateError) { m = try stream.receive() } catch {
        end(error)
        return
      }
      let call = lock.withLock { () -> Call? in
        guard let i = waiting.firstIndex(where: { $0.tag == m.tag }) else { return nil }
        return waiting.remove(at: i).call
      }
      // A reply to no call is the server's mistake; it's dropped.
      call?.deliver(.success(m.fcall))
    }
  }

  /// Ends the connection: every waiting call fails with `why`.
  func end(_ why: GateError) {
    let calls = lock.withLock { () -> [Call] in
      if ended == nil { ended = why }
      defer { waiting = [] }
      return waiting.map { $0.call }
    }
    for c in calls { c.deliver(.failure(why)) }
  }

  // MARK: The calls, by name

  /// Attaches `fid` to the server's tree `aname` as `uname`.
  public func attach(_ fid: UInt32, uname: String, aname: String) throws(GateError) -> Qid {
    guard case .rattach(let qid) = try rpc(.tattach(fid: fid, afid: NineP.noFid, uname: uname, aname: aname))
    else { throw .protocolError("Tattach") }
    return qid
  }

  /// Walks `newfid` from `fid` along `names`: the qids of those walked,
  /// fewer than `names` if one wasn't there (and then `newfid` is unused).
  public func walk(_ fid: UInt32, _ newfid: UInt32, _ names: [String]) throws(GateError) -> [Qid] {
    guard case .rwalk(let qids) = try rpc(.twalk(fid: fid, newfid: newfid, names: names)), qids.count <= names.count
    else { throw .protocolError("Twalk") }
    return qids
  }

  public func open(_ fid: UInt32, mode: UInt8) throws(GateError) -> (qid: Qid, iounit: UInt32) {
    guard case .ropen(let qid, let iounit) = try rpc(.topen(fid: fid, mode: mode)) else { throw .protocolError("Topen") }
    return (qid, iounit)
  }

  public func create(_ fid: UInt32, name: String, perm: UInt32, mode: UInt8) throws(GateError) -> Qid {
    guard case .rcreate(let qid, _) = try rpc(.tcreate(fid: fid, name: name, perm: perm, mode: mode))
    else { throw .protocolError("Tcreate") }
    return qid
  }

  public func read(_ fid: UInt32, offset: UInt64, count: UInt32) throws(GateError) -> [UInt8] {
    guard case .rread(let data) = try rpc(.tread(fid: fid, offset: offset, count: min(count, iounit))),
          data.count <= Int(count)
    else { throw .protocolError("Tread") }
    return data
  }

  public func write(_ fid: UInt32, offset: UInt64, _ data: [UInt8]) throws(GateError) -> UInt32 {
    guard case .rwrite(let n) = try rpc(.twrite(fid: fid, offset: offset, data: data)), n <= UInt32(data.count)
    else { throw .protocolError("Twrite") }
    return n
  }

  /// Clunks `fid` and gives it back.
  public func clunk(_ fid: UInt32) {
    _ = try? rpc(.tclunk(fid: fid))
    release(fid)
  }

  /// Removes `fid`'s file; the fid is clunked and given back either way.
  public func remove(_ fid: UInt32) throws(GateError) {
    defer { release(fid) }
    guard case .rremove = try rpc(.tremove(fid: fid)) else { throw .protocolError("Tremove") }
  }

  public func stat(_ fid: UInt32) throws(GateError) -> Dir {
    guard case .rstat(let stat) = try rpc(.tstat(fid: fid)), let d = Dir.decode(stat) else {
      throw .protocolError("Tstat")
    }
    return d
  }

  public func wstat(_ fid: UInt32, _ dir: Dir) throws(GateError) {
    guard let stat = dir.encode() else { throw .protocolError("stat too large") }
    guard case .rwstat = try rpc(.twstat(fid: fid, stat: stat)) else { throw .protocolError("Twstat") }
  }
}

/// One call's reply, waited for by its caller: the reader hands it over.
/// The lock is held until the reply is in, so `wait` sleeps on the futex
/// under it, and the reader's unlock is the wakeup.
final class Call: @unchecked Sendable {
  let gate = Lock()
  var reply: Result<Fcall, GateError>?

  init() { gate.lock() }

  func deliver(_ r: Result<Fcall, GateError>) {
    reply = r
    gate.unlock()
  }

  func wait() throws(GateError) -> Fcall {
    gate.lock()
    defer { gate.unlock() }
    switch reply! {
    case .success(let f): return f
    case .failure(let e): throw e
    }
  }
}
