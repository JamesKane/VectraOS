// SPDX-License-Identifier: BSD-3-Clause

// The pty service on the one ring (D46; todhchai's M6j part 2b, rewritten
// from its sockets): a pty is the parent side of five rings, the
// terminal's keys and screen and its program's descriptors 0 to 2, with
// the line discipline between them and the window's size. Its IPC
// (Factory, Device, Control) is the dispatcher's thread's; its rings are
// threads of their own, one a ring it reads: keys go through the
// discipline to the program (echoes to the screen, events to each
// Control), the program's output and errors through it to the screen.
// The screen has writers on several threads, so they take turns (a ring
// has one writer at a time). A full ring makes its writer wait, as a full
// terminal does.

import IPC
import Sys

/// One pty.
final class Pty: @unchecked Sendable {
  let dispatcher: IPCDispatcher
  /// The discipline, the client's input, what waits for it, the controls.
  let lock = Lock()
  /// The screen's writers take turns.
  let screenLock = Lock()
  var discipline = LineDiscipline()
  var size: PtyIPC.WindowSize
  /// The terminal writes `keys` and reads `screen`.
  let keys: ChildStream
  let screen: ChildStream
  /// The program's stdin, once the client's made, and what was typed
  /// before.
  var input: ChildStream? = nil
  var typed: [UInt8] = []
  var clientMade = false
  /// The controls' servers and what each has yet to hear (its events, a new
  /// size, the hangup); whether one takes ^D (Control.takeEnds).
  var controls: [(id: UInt64, events: [PtyIPC.Event], resized: PtyIPC.WindowSize?, hangup: Bool)] = []
  var endsTaken = false
  var closed = false

  init(dispatcher: IPCDispatcher, keys: ChildStream, screen: ChildStream, size: PtyIPC.WindowSize) {
    self.dispatcher = dispatcher
    self.keys = keys
    self.screen = screen
    self.size = size
  }

  /// A thread running `body` on its own (its handle dropped).
  static func run(_ body: @escaping @Sendable () -> Void) { _ = try? Thread.spawn(body) }

  func start() { Pty.run { self.readKeys() } }

  // MARK: Keys

  func readKeys() {
    while true {
      guard let k = try? keys.read(), !k.isEmpty else {
        close()  // the terminal's gone
        return
      }
      let r = lock.withLock { discipline.input(k) }
      if !r.echo.isEmpty { show(r.echo) }
      give(r.toProgram)
      for e in r.events {
        switch e {
        case .interrupt: send(.interrupt)
        case .quit: send(.quit)
        case .endOfInput:
          if lock.withLock({ endsTaken }) { send(.end) } else { try? lock.withLock { input }?.closeInput() }
        }
      }
    }
  }

  /// Bytes for the program: into its stdin, or kept until it has one.
  func give(_ bytes: [UInt8]) {
    guard !bytes.isEmpty else { return }
    let to = lock.withLock { () -> ChildStream? in
      if input == nil { typed += bytes }
      return input
    }
    try? to?.write(bytes)
  }

  func send(_ e: PtyIPC.Event) {
    lock.withLock {
      for i in controls.indices {
        controls[i].events.append(e)
        dispatcher.wake(controls[i].id)
      }
    }
  }

  // MARK: Output

  func show(_ bytes: [UInt8]) {
    guard !bytes.isEmpty else { return }
    screenLock.withLock { _ = try? screen.write(bytes) }
  }

  /// One of the program's descriptors it writes, through the discipline
  /// to the screen, until its end.
  func readProgram(_ from: ChildStream) {
    while let bytes = try? from.read(), !bytes.isEmpty {
      show(lock.withLock { discipline.output(bytes) })
    }
  }

  // MARK: The device and controls

  /// The client's rings; their child sides to `give`.
  func makeClient(_ give: (consuming StreamParts, consuming StreamParts, consuming StreamParts) -> Void)
    throws(Status)
  {
    var i: StreamParts? = nil, o: StreamParts? = nil, e: StreamParts? = nil
    let input = try ChildStream(fd: 0, childReads: true) { (p: consuming StreamParts) in i = consume p }
    let output = try ChildStream(fd: 1, childReads: false) { (p: consuming StreamParts) in o = consume p }
    let errors = try ChildStream(fd: 2, childReads: false) { (p: consuming StreamParts) in e = consume p }
    guard let ip = i.take(), let op = o.take(), let ep = e.take() else { throw .internal }
    let early = lock.withLock { () -> [UInt8] in
      self.input = input
      defer { typed = [] }
      return typed
    }
    if !early.isEmpty { try? input.write(early) }
    Pty.run { self.readProgram(output) }
    Pty.run { self.readProgram(errors) }
    give(ip, op, ep)
  }

  func setSize(_ s: PtyIPC.WindowSize) {
    lock.withLock {
      guard s != size else { return }
      size = s
      for i in controls.indices {
        controls[i].resized = s
        dispatcher.wake(controls[i].id)
      }
    }
  }

  func setMode(_ m: PtyIPC.Mode) {
    let handed = lock.withLock {
      discipline.setMode(TerminalMode(canonical: m.canonical, echo: m.echo, signals: m.signals,
                                      outputCRLF: m.outputCRLF))
    }
    give(handed)
  }

  var mode: PtyIPC.Mode {
    let m = lock.withLock { discipline.mode }
    return PtyIPC.Mode(canonical: m.canonical, echo: m.echo, signals: m.signals, outputCRLF: m.outputCRLF)
  }

  /// Ends it: each Control hears it hang up, the program's stdin goes (its
  /// read ends), and the terminal's rings with the pty.
  func close() {
    lock.withLock {
      guard !closed else { return }
      closed = true
      for i in controls.indices {
        controls[i].hangup = true
        dispatcher.wake(controls[i].id)
      }
      input?.hangUp()
    }
  }
}

struct DeviceSession: PtyIPC.DeviceHandler {
  let pty: Pty
  func setWindowSize(_ size: PtyIPC.WindowSize) { pty.setSize(size) }

  func client() throws(PtyIPC.PtyError) -> PtyIPC.Client {
    let first = pty.lock.withLock { () -> Bool in
      defer { pty.clientMade = true }
      return !pty.clientMade && !pty.closed
    }
    guard first else { throw .unavailable }
    do throws(Status) {
      let channel = try Channel.create()
      let pty = self.pty
      let session = ControlSession(pty: pty)
      let id = try pty.dispatcher.add(PtyIPC.ControlServer(channel: channel.b, impl: session)) {
        (s: inout PtyIPC.ControlServer<ControlSession>) throws(IPCError<Never>) in
        let (events, resized, hangup) = pty.lock.withLock { () -> ([PtyIPC.Event], PtyIPC.WindowSize?, Bool) in
          guard let i = pty.controls.firstIndex(where: { $0.id == session.id }) else { return ([], nil, false) }
          defer {
            pty.controls[i].events.removeAll()
            pty.controls[i].resized = nil
            pty.controls[i].hangup = false
          }
          return (pty.controls[i].events, pty.controls[i].resized, pty.controls[i].hangup)
        }
        for e in events { try PtyIPC.ControlEventSender.sendEvent(e, on: s.connection) }
        if let resized { try PtyIPC.ControlEventSender.sendResized(resized, on: s.connection) }
        if hangup { try PtyIPC.ControlEventSender.sendHangup(on: s.connection) }
      }
      session.id = id
      pty.lock.withLock { pty.controls.append((id, [], nil, false)) }
      var made: PtyIPC.Client? = nil
      let control = channel.a
      var control2: Handle? = consume control
      try pty.makeClient { (i: consuming StreamParts, o: consuming StreamParts, e: consuming StreamParts) in
        guard let c = control2.take() else { return }
        made = PtyIPC.Client(input: i.descriptor(), output: o.descriptor(), errors: e.descriptor(), control: c)
      }
      guard let client = made.take() else { throw .unavailable }
      return client
    } catch {
      throw .unavailable
    }
  }
}

final class ControlSession: PtyIPC.ControlHandler, @unchecked Sendable {
  let pty: Pty
  /// Its server's id in the dispatcher (set once it's added).
  var id: UInt64 = 0
  init(pty: Pty) { self.pty = pty }
  func mode() -> PtyIPC.Mode { pty.mode }
  func setMode(_ mode: PtyIPC.Mode) { pty.setMode(mode) }
  func windowSize() -> PtyIPC.WindowSize { pty.lock.withLock { pty.size } }
  func takeEnds(_ yes: Bool) { pty.lock.withLock { pty.endsTaken = yes } }
}

struct FactorySession: PtyIPC.FactoryHandler {
  let dispatcher: IPCDispatcher

  func open(size: PtyIPC.WindowSize) throws(PtyIPC.PtyError) -> PtyIPC.Opened {
    do throws(Status) {
      var k: StreamParts? = nil, s: StreamParts? = nil
      let keys = try ChildStream(childReads: false) { (p: consuming StreamParts) in k = consume p }
      let screen = try ChildStream(childReads: true) { (p: consuming StreamParts) in s = consume p }
      guard let kp = k.take(), let sp = s.take() else { throw Status.internal }
      let d = try Channel.create()
      let pty = Pty(dispatcher: dispatcher, keys: keys, screen: screen, size: size)
      pty.start()
      try dispatcher.add(PtyIPC.DeviceServer(channel: d.b, impl: DeviceSession(pty: pty)))
      return PtyIPC.Opened(keys: kp.descriptor(), screen: sp.descriptor(), device: d.a)
    } catch {
      throw .unavailable
    }
  }
}

/// The service: a `Factory` on each channel it's given.
public enum PtyService {
  public static func serve(_ channel: consuming Handle, on dispatcher: IPCDispatcher) throws(Status) {
    try dispatcher.add(PtyIPC.FactoryServer(channel: channel, impl: FactorySession(dispatcher: dispatcher)))
  }
}
