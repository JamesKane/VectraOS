// SPDX-License-Identifier: BSD-3-Clause

// Sys: what services use to reach the kernel (docs/milestones/N0.md). The
// kernel's object model and values; the calls go to `Kernel`
// (system/sys/backend), the hosted kernel in SwiftPM, the kernel's
// syscalls natively (M3). V2 moved it to V1's calls: waits bind ONCE on
// the thread's port (D23), sleeps are that port's deadline (D25), the
// calls that take arrays take them here too, with one-item forms (D45).

@_exported import SysABI

/// A handle this process owns. It is `~Copyable`, so exactly one owner
/// holds it, and it closes when dropped. `release()` gives up ownership
/// without closing, to move the handle into a message.
@frozen public struct Handle: ~Copyable {
  public let raw: UInt32

  /// Takes ownership of a raw handle, such as one read from a message.
  public init(raw: UInt32) { self.raw = raw }

  /// Gives up ownership: the handle stays open, and the caller is now
  /// responsible for it (usually by writing it into a message).
  public consuming func release() -> UInt32 {
    let raw = self.raw
    discard self
    return raw
  }

  deinit { Kernel.close(raw) }

  /// Another handle to the same object, with `rights` (at most this one's).
  public func duplicate(_ rights: Rights = .sameRights) throws(Status) -> Handle {
    Handle(raw: try Kernel.duplicate(raw, rights, consume: false))
  }

  /// This handle, with fewer rights; this one is gone either way.
  public consuming func replace(_ rights: Rights) throws(Status) -> Handle {
    let raw = release()
    return Handle(raw: try Kernel.duplicate(raw, rights, consume: true))
  }

  /// object_get_info, HANDLE_BASIC: the object's koid, type and peer.
  public func info() throws(Status) -> HandleInfo { try Kernel.info(raw) }

  /// A job's child job or process, or a process's thread, by its koid
  /// (object_get_child): this handle needs ENUMERATE, and `rights` are a
  /// subset of its own (`sameRights`: all of them). notFound for a koid
  /// that isn't a live child.
  public func child(_ koid: UInt64, rights: Rights = .sameRights) throws(Status) -> Handle {
    Handle(raw: try Kernel.child(raw, koid, rights.rawValue))
  }

  /// Its object's name (PROP_NAME: processes, threads, jobs, VMOs).
  public func name() throws(Status) -> String { try Kernel.name(raw) }

  /// Names its object (at most 31 bytes kept).
  public func setName(_ name: String) throws(Status) { try Kernel.setName(raw, name) }

  /// Waits until the object asserts one of `signals` or `deadline`
  /// (monotonic nanoseconds) passes; the signals observed. A ONCE binding
  /// on the calling thread's port (V1 cut object_wait_one, D23).
  public func wait(for signals: UInt32, deadline: Int64 = infiniteDeadline) throws(Status) -> UInt32 {
    try Kernel.wait(Binding.signals(raw, signals, key: 0), deadline: deadline).observed
  }

  /// Packets to `port` with `key` when the object asserts one of `signals`
  /// (object_bind SIGNALS): once, or with `persistent` at every event that
  /// leaves one asserted, coalesced while unread; with `edge`, not at once
  /// if one already is.
  public func bind(port: borrowing Handle, key: UInt64, signals: UInt32, persistent: Bool = false,
                   edge: Bool = false) throws(Status)
  {
    try Port.bind(port, Binding.signals(raw, signals, key: key, persistent: persistent, edge: edge))
  }
}

/// object_get_info's HANDLE_BASIC record.
public struct HandleInfo: Equatable, Sendable {
  public var koid: UInt64
  public var rights: Rights
  public var type: UInt32
  /// The peer's koid, for channels.
  public var relatedKoid: UInt64

  public init(koid: UInt64, rights: Rights, type: UInt32, relatedKoid: UInt64) {
    self.koid = koid
    self.rights = rights
    self.type = type
    self.relatedKoid = relatedKoid
  }
}

/// A pair of handles a call made (a channel's ends). Take them apart with
/// `let a = ends.a`.
@frozen public struct Ends: ~Copyable {
  public var a: Handle
  public var b: Handle
}

/// Closes a raw handle nothing owns (one read from a message being dropped).
public func close(raw: UInt32) { Kernel.close(raw) }

/// Closes raw handles nothing owns, in one call (handle_close's array, D33).
public func close(raw handles: [UInt32]) {
  unsafe handles.withUnsafeBufferPointer { unsafe Kernel.close(all: $0) }
}

/// Waits until `object` asserts one of `signals` or `deadline` passes.
public func wait(_ object: borrowing Handle, for signals: UInt32, deadline: Int64 = infiniteDeadline)
  throws(Status) -> UInt32
{
  try object.wait(for: signals, deadline: deadline)
}

public enum Clock {
  /// Nanoseconds on the monotonic clock, the time base of every deadline.
  public static func monotonic() -> Int64 { Kernel.now() }

  /// Nanoseconds since the Unix epoch, for timestamps people read. The
  /// monotonic clock natively until the time service's UTC page (D48).
  public static func realtime() -> Int64 { Kernel.realtime() }
}

/// One word of the calling thread's own (M5k): what a runtime keeps per
/// thread before there's ELF TLS, such as libc's pthread record. Natively a
/// slot of the thread's block (its thread pointer); hosted a host thread
/// key; 0 until set.
public enum ThreadSlot {
  public static var value: UInt {
    get { Kernel.threadSlot() }
    set { Kernel.setThreadSlot(newValue) }
  }
}

/// Sleeps until `deadline`: a wait on the thread's port (V1 cut nanosleep,
/// D25).
public func sleep(until deadline: Int64) { Kernel.sleep(deadline) }
