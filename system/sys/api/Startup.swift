// SPDX-License-Identifier: BSD-3-Clause

// What a process starts with: Zircon's processargs, one message. Its
// arguments (its name first), its environment, its handles (each with an
// info word: a HandleType and an argument), and the names table, which a
// PA_NS_DIR handle's argument indexes: its namespace (the launcher's,
// D65). A parent builds one and `Process.start` moves it in; natively it
// is the new process's bootstrap message, and the process reads its own
// as `Startup.current` (the floor's, which LibSys's views share); hosted,
// the program's entry is given it.

public final class Startup: @unchecked Sendable {
  public var args: [String]
  public var environment: [String]
  public var names: [String]
  /// Handles moved in, not yet taken (raw: an Array can't hold a Handle).
  var handles: [(info: UInt32, handle: UInt32)] = []
  /// The process's own, natively: its handles are the floor's table.
  let floor: Bool
  let mutex = Lock()

  public init(args: [String] = [], environment: [String] = [], names: [String] = []) {
    self.args = args
    self.environment = environment
    self.names = names
    floor = false
  }

  init(args: [String], environment: [String], names: [String], floor: Bool) {
    self.args = args
    self.environment = environment
    self.names = names
    self.floor = floor
  }

  deinit {
    for h in handles { Kernel.close(h.handle) }
  }

  /// The calling process's own: natively, what it was started with (one
  /// view of the floor's table); hosted, nothing (a hosted program's entry
  /// is given its own).
  public static var current: Startup { Kernel.currentStartup }

  /// Moves `handle` in, to go with `info`.
  public func add(_ handle: consuming Handle, info: UInt32) {
    let raw = handle.release()
    mutex.withLock { handles.append((info, raw)) }
  }

  /// Moves a raw handle in (the caller's no more).
  public func add(raw: UInt32, info: UInt32) {
    mutex.withLock { handles.append((info, raw)) }
  }

  /// The handle given with `info`, the caller's from then on; nil if there
  /// was none or it was taken.
  public func take(_ info: UInt32) -> Handle? {
    if floor { return Kernel.startupTake(info).map { Handle(raw: $0) } }
    let raw = mutex.withLock { () -> UInt32? in
      guard let i = handles.firstIndex(where: { $0.info == info }) else { return nil }
      return handles.remove(at: i).handle
    }
    return raw.map { Handle(raw: $0) }
  }

  /// The info words of the handles not yet taken, in order.
  public var infos: [UInt32] {
    floor ? Kernel.startupInfos() : mutex.withLock { handles.map { $0.info } }
  }

  /// Every handle not yet taken, the caller's from then on (Process.start's).
  func takeAll() -> [(info: UInt32, handle: UInt32)] {
    if floor {
      var out: [(info: UInt32, handle: UInt32)] = []
      for info in Kernel.startupInfos() { if let h = Kernel.startupTake(info) { out.append((info, h)) } }
      return out
    }
    return mutex.withLock {
      defer { handles = [] }
      return handles
    }
  }

  /// The value of the environment's `name`: its first entry's (compared
  /// as bytes).
  public func value(_ name: String) -> String? {
    let key = Array(name.utf8)
    for e in environment {
      let bytes = Array(e.utf8)
      if bytes.count > key.count, bytes[key.count] == 0x3D, Array(bytes[..<key.count]) == key {
        return String(decoding: bytes[(key.count + 1)...], as: UTF8.self)
      }
    }
    return nil
  }
}

/// A child's exit string, Plan 9's exits (D72): a page given in its
/// Startup (HandleType.vmoStatus), which the child's td_exits writes as it
/// ends, NUL-terminated; the parent reads it once the child has ended.
public struct ExitString: ~Copyable {
  /// Its longest, with its NUL (Plan 9's ERRMAX).
  public static let max = 128
  let page: Handle

  /// A page for the child `startup` starts.
  public init(for startup: Startup) throws(Status) {
    let page = try VMO.create(size: 4096)
    startup.add(try page.duplicate(), info: HandleType.info(HandleType.vmoStatus))
    self.page = page
  }

  /// What the child said: "" if it said nothing (or isn't done).
  public func read() -> String {
    guard let m = try? VMO.map(page, length: 4096, writable: false) else { return "" }
    let bytes = m.read(at: 0, count: Self.max)
    return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
  }
}
