// SPDX-License-Identifier: BSD-3-Clause

/// Writes a message to a channel; its handles move with it.
func send<E: IPCErrorCode>(_ message: IPCMessage, on channel: borrowing Handle, _: E.Type) throws(IPCError<E>) {
  try ipcTransport(E.self) { () throws(Status) in
    try Channel.write(channel, bytes: message.bytes, handles: message.handles)
  }
}

/// Waits for the next message on a channel, until `deadline`.
func receive<E: IPCErrorCode>(on channel: borrowing Handle, deadline: Int64, _: E.Type) throws(IPCError<E>)
  -> IPCMessage
{
  try ipcTransport(E.self) { () throws(Status) in
    while true {
      do throws(Status) {
        let m = try Channel.read(channel)
        return IPCMessage(bytes: m.bytes, handles: m.handles)
      } catch .shouldWait {
        _ = try wait(channel, for: Signals.readable | Signals.peerClosed, deadline: deadline)
      }
    }
  }
}

/// The error an error reply carries: the method's own (positive codes) or
/// the framework's (negative codes, transport status values).
func errorReply<E: IPCErrorCode>(_ reply: IPCMessage, _: E.Type) -> IPCError<E> {
  let code: Int32
  do {
    code = try IPCCodec.decode(reply, inlineSize: errorInlineSize, E.self) { (d: inout Decoder) throws(WireError) in
      let code = try d.load(Int32.self, at: 0)
      try d.checkPadding(at: 4, count: 4)
      return code
    }
  } catch {
    return error
  }
  if code > 0, let remote = E(code: code) { return .remote(remote) }
  if code < 0, let status = Status(rawValue: code) { return .transport(status) }
  return .wire(.invalidValue)
}

/// A channel's id for flow ids: the smaller of its two ends' koids, which
/// both ends see (docs/trace-format.md, "IPC flow ids").
func channelID(_ channel: borrowing Handle) -> UInt64 {
  guard let info = try? channel.info() else { return 0 }
  return min(info.koid, info.relatedKoid)
}

/// The client's end of a protocol: calls, and the events that arrive
/// meanwhile. Generated `<Name>Client` types wrap one.
public struct IPCClientConnection: ~Copyable {
  public let channel: Handle
  let channelID: UInt64
  /// Events read while looking for an epitaph, for `nextEvent`.
  var events: [IPCMessage] = []
  /// How long a call waits for its reply, in nanoseconds; nil waits until
  /// the server answers or goes. A reply that comes after its call gave up
  /// is dropped.
  public var timeout: Int64? = nil
  /// The flow id of the last call that got a reply (docs/trace-format.md).
  public private(set) var lastFlow: UInt64 = 0

  public init(channel: consuming Handle) {
    channelID = IPC.channelID(channel)
    self.channel = channel
  }

  /// The channel, to speak something else on it.
  public consuming func takeChannel() -> Handle { channel }

  /// Sends a one-way request.
  public func send<E: IPCErrorCode>(_ request: IPCMessage, _: E.Type) throws(IPCError<E>) {
    try IPC.send(request, on: channel, E.self)
  }

  /// Calls: sends `request` with channel_call, which gives it a txid and
  /// waits for the reply that echoes it. Events that arrive meanwhile stay
  /// queued for `nextEvent`. An error reply is thrown. Records the call's
  /// write and its reply's read as one flow, named `trace`.
  public mutating func call<E: IPCErrorCode>(_ request: IPCMessage, _: E.Type, trace: TraceName)
    throws(IPCError<E>) -> IPCMessage
  {
    let sent = Trace.now()
    let deadline = timeout.map { Clock.monotonic() + $0 } ?? infiniteDeadline
    let answer: Channel.Message
    do throws(Status) {
      answer = try Channel.call(channel, bytes: request.bytes, handles: request.handles, deadline: deadline)
    } catch .peerClosed {
      throw .transport(closingStatus())
    } catch {
      throw .transport(error)
    }
    let reply = IPCMessage(bytes: answer.bytes, handles: answer.handles)
    let header = try ipcWire(E.self) { () throws(WireError) in try reply.header() }
    let flow = flowID(channel: channelID, txid: header.txid)
    lastFlow = flow
    if Trace.enabled(.ipc) {
      Trace.flow(flow, trace, .ipc, at: sent)
      Trace.flow(flow, trace, .ipc)
    }
    guard header.kind == .reply else {
      reply.closeHandles()
      throw .wire(.unexpectedMessage)
    }
    if header.flags & HeaderFlags.error != 0 { throw errorReply(reply, E.self) }
    if header.flags & HeaderFlags.canceled != 0 { throw .transport(.canceled) }
    return reply
  }

  /// Why the channel closed: an epitaph's status if one is queued (keeping
  /// the events before it), or `peerClosed`.
  mutating func closingStatus() -> Status {
    while let m = try? Channel.read(channel) {
      let message = IPCMessage(bytes: m.bytes, handles: m.handles)
      switch try? message.header().kind {
      case .epitaph: return epitaphStatus(message)
      case .event: events.append(message)
      default: message.closeHandles()
      }
    }
    return .peerClosed
  }

  /// The next event: a queued one, or the next to arrive before `deadline`.
  public mutating func nextEvent(deadline: Int64) throws(IPCError<Never>) -> (MessageHeader, IPCMessage) {
    while true {
      let message = events.isEmpty
        ? try receive(on: channel, deadline: deadline, Never.self) : events.removeFirst()
      let header = try ipcWire(Never.self) { () throws(WireError) in try message.header() }
      switch header.kind {
      case .event: return (header, message)
      case .epitaph: throw .transport(epitaphStatus(message))
      case .reply:
        // A reply that came after its call gave up.
        message.closeHandles()
      default:
        message.closeHandles()
        throw .wire(.unexpectedMessage)
      }
    }
  }
}

/// The status an epitaph carries, or `peerClosed` if it is malformed.
func epitaphStatus(_ message: IPCMessage) -> Status {
  guard let status = try? decodeEpitaph(message.bytes.span.bytes) else { return .peerClosed }
  return Status(rawValue: status) ?? .peerClosed
}

/// The server's end of a protocol. Generated `<Name>Server` types wrap one.
public struct IPCServerConnection: ~Copyable {
  public let channel: Handle
  let channelID: UInt64

  public init(channel: consuming Handle) {
    channelID = IPC.channelID(channel)
    self.channel = channel
  }

  /// Records a call's read, on its flow.
  public func received(_ header: MessageHeader, trace: TraceName) {
    guard header.txid != 0, Trace.enabled(.ipc) else { return }
    Trace.flow(flowID(channel: channelID, txid: header.txid), trace, .ipc)
  }

  /// Sends a call's reply, recording its write on the call's flow.
  public func reply(_ message: IPCMessage, to request: MessageHeader, trace: TraceName) throws(IPCError<Never>) {
    if Trace.enabled(.ipc) { Trace.flow(flowID(channel: channelID, txid: request.txid), trace, .ipc) }
    try send(message)
  }

  /// The next request, or `nil` once the client has closed its end; throws
  /// `timedOut` if none comes before `deadline`.
  public func nextRequest(deadline: Int64 = infiniteDeadline) throws(IPCError<Never>) -> (MessageHeader, IPCMessage)? {
    while true {
      let message: IPCMessage
      do throws(IPCError<Never>) {
        message = try receive(on: channel, deadline: deadline, Never.self)
      } catch .transport(.peerClosed) {
        return nil
      }
      let header = try ipcWire(Never.self) { () throws(WireError) in try message.header() }
      switch header.kind {
      case .request:
        return (header, message)
      case .cancel:
        // Requests are served one at a time, so a cancelled one has already
        // been answered: nothing more is owed (docs/wire-format.md).
        continue
      default:
        message.closeHandles()
        throw .wire(.unexpectedMessage)
      }
    }
  }

  /// Checks that a request is a call (`twoWay`) or one-way, as its method is.
  public func expect(_ header: MessageHeader, twoWay: Bool, _ message: IPCMessage) throws(IPCError<Never>) {
    guard (header.txid != 0) == twoWay else {
      message.closeHandles()
      throw .wire(.unexpectedMessage)
    }
  }

  /// Sends a message: a reply or an event.
  public func send(_ message: IPCMessage) throws(IPCError<Never>) {
    try IPC.send(message, on: channel, Never.self)
  }

  /// Answers a call with an error code.
  public func replyError(to request: MessageHeader, code: Int32) throws(IPCError<Never>) {
    let reply = try IPCCodec.encode(
      MessageHeader(txid: request.txid, kind: .reply, flags: HeaderFlags.error, ordinal: request.ordinal),
      inlineSize: errorInlineSize, Never.self
    ) { (e: inout Encoder) throws(WireError) in try e.store(code, at: 0) }
    try send(reply)
  }

  /// Answers a request for a method the server doesn't know: an error reply
  /// for a call, nothing for a one-way request.
  public func unknownMethod(_ header: MessageHeader, _ message: IPCMessage) throws(IPCError<Never>) {
    message.closeHandles()
    if header.txid != 0 { try replyError(to: header, code: Status.notSupported.rawValue) }
  }
}
