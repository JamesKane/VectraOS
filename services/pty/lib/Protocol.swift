// SPDX-License-Identifier: BSD-3-Clause

// The pty service's protocol (todhchai's M6j part 2b, decided 2026-10-12:
// Fuchsia's model, a pty pair served over IPC; rewritten for the one ring,
// D46). A terminal opens a pty (`Factory`, /svc/pty/pty) and gets its side:
// two descriptors (its keys, which it writes, and the screen, which it
// reads) and `Device`, to set the window's size and make the client end.
// The client end is a program's descriptors 0 to 2, each the child side
// of a ring the pty is the other side of (Sys's StreamParts: a starter
// puts them in a Startup as they are, CROI_PA_STDIO), and `Control`, the
// pty's termios for the program: its mode, the window's size, and the
// events a terminal's keys make (an interrupt for the controller: croi has
// no signals, so a shell kills its foreground job itself).
//
// The end of input (^D on an empty line) is the controller's to act on
// once it says so (`takeEnds`: an event, as a ring's end can't be taken
// back, and a shell's own input goes on after its job's ends); otherwise
// it is the end of the program's stdin.
//
// The line discipline is the service's (LineDiscipline.swift).

import IPC
import Sys

@IPCLibrary(id: "todhchai.pty", version: 1)
public enum PtyIPC {
  public enum PtyError: Int32, IPCErrorCode, Sendable {
    case invalid = 1
    case unavailable
  }

  public struct WindowSize: Equatable, Sendable {
    public var columns: UInt32
    public var rows: UInt32
    public init(columns: UInt32, rows: UInt32) {
      self.columns = columns
      self.rows = rows
    }
  }

  /// termios's flags the discipline knows (TerminalMode's).
  public struct Mode: Equatable, Sendable {
    public var canonical: Bool
    public var echo: Bool
    public var signals: Bool
    public var outputCRLF: Bool
    public init(canonical: Bool, echo: Bool, signals: Bool, outputCRLF: Bool) {
      self.canonical = canonical
      self.echo = echo
      self.signals = signals
      self.outputCRLF = outputCRLF
    }
  }

  /// What a key made, for the program's controller.
  public enum Event: UInt8, Sendable {
    case interrupt = 1
    case quit
    /// ^D on an empty line.
    case end
  }

  /// One descriptor's child side (StreamParts): its ring's VMO, the
  /// child's doorbell and the pty's, and the channel whose closing ends
  /// it. Which way it goes is its place's.
  public struct Descriptor: ~Copyable {
    public var vmo: Handle
    public var childBell: Handle
    public var parentBell: Handle
    public var channel: Handle
    public init(vmo: consuming Handle, childBell: consuming Handle, parentBell: consuming Handle,
                channel: consuming Handle)
    {
      self.vmo = vmo
      self.childBell = childBell
      self.parentBell = parentBell
      self.channel = channel
    }
  }

  /// A pty, opened: the terminal's keys (it writes them) and screen (it
  /// reads it), and its `Device`.
  public struct Opened: ~Copyable {
    public var keys: Descriptor
    public var screen: Descriptor
    public var device: Handle
    public init(keys: consuming Descriptor, screen: consuming Descriptor, device: consuming Handle) {
      self.keys = keys
      self.screen = screen
      self.device = device
    }
  }

  /// The client end: a program's descriptors 0 (it reads), 1 and 2 (it
  /// writes), and `Control`.
  public struct Client: ~Copyable {
    public var input: Descriptor
    public var output: Descriptor
    public var errors: Descriptor
    public var control: Handle
    public init(input: consuming Descriptor, output: consuming Descriptor, errors: consuming Descriptor,
                control: consuming Handle)
    {
      self.input = input
      self.output = output
      self.errors = errors
      self.control = control
    }
  }

  public protocol Factory {
    func open(size: WindowSize) throws(PtyError) -> Opened
  }

  /// The terminal's side.
  public protocol Device {
    func setWindowSize(_ size: WindowSize)
    /// The client end (once: a ring has one writer, so a shell on it
    /// relays for its children).
    func client() throws(PtyError) -> Client
  }

  /// The program's side.
  public protocol Control {
    func mode() -> Mode
    func setMode(_ mode: Mode)
    func windowSize() -> WindowSize
    /// Whether the controller takes ^D as an `end` event (a shell, whose
    /// own input goes on), or the pty ends the program's stdin (the
    /// default).
    func takeEnds(_ yes: Bool)
    @event func event(_ event: Event)
    @event func resized(_ size: WindowSize)
  }
}

extension PtyIPC.Descriptor {
  /// As Sys's StreamParts, going the way `childReads` says.
  public consuming func parts(childReads: Bool) -> StreamParts {
    StreamParts(vmo: vmo, childBell: childBell, parentBell: parentBell, channel: channel, childReads: childReads)
  }
}

extension StreamParts {
  /// As the protocol's Descriptor.
  public consuming func descriptor() -> PtyIPC.Descriptor {
    take { (vmo: consuming Handle, child: consuming Handle, parent: consuming Handle, channel: consuming Handle) in
      PtyIPC.Descriptor(vmo: vmo, childBell: child, parentBell: parent, channel: channel)
    }
  }
}

// The ends taken out (a field of another module's ~Copyable struct can't be
// consumed alone).
extension PtyIPC.Opened {
  public consuming func take<R: ~Copyable, E: Error>(
    _ body: (consuming PtyIPC.Descriptor, consuming PtyIPC.Descriptor, consuming Handle) throws(E) -> R
  ) throws(E) -> R {
    try body(keys, screen, device)
  }
}

extension PtyIPC.Client {
  public consuming func take<R: ~Copyable, E: Error>(
    _ body: (consuming PtyIPC.Descriptor, consuming PtyIPC.Descriptor, consuming PtyIPC.Descriptor, consuming Handle)
      throws(E) -> R
  ) throws(E) -> R {
    try body(input, output, errors, control)
  }
}
