// SPDX-License-Identifier: BSD-3-Clause

// What a process starts with: Zircon's processargs, one message. Its
// arguments (its name first), its handles (each with an info word: a
// HandleType and an argument), and the names table, which a PA_NS_DIR
// handle's argument indexes: its namespace (the launcher's, D65). A parent builds one and `Process.start` moves it in; natively it
// is the new process's bootstrap message, and the process reads its own
// as `Startup.current` (the floor's, which LibSys's views share); hosted,
// the program's entry is given it.
//
// It carries no environment: a process's is the tree at its /env, a mount
// like any other (D81). The processargs message's environment list holds
// only the kernel's boot options, which userboot passes to the program it
// starts (Sys's `BootOptions`).

public final class Startup: @unchecked Sendable {
  public var args: [String]
  public var names: [String]
  /// Handles moved in, not yet taken (raw: an Array can't hold a Handle).
  var handles: [(info: UInt32, handle: UInt32)] = []
  /// The process's own, natively: its handles are the floor's table.
  let floor: Bool
  let mutex = Lock()

  public init(args: [String] = [], names: [String] = []) {
    self.args = args
    self.names = names
    floor = false
  }

  init(args: [String], names: [String], floor: Bool) {
    self.args = args
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

/// The framebuffer the boot data names (zbi.h's croi_zbi_swfb_t), read
/// through a mapping of the boot data VMO (a manifest's `bootdata`): the
/// console draws on it and the mouse service keeps its pointer inside it.
public struct BootFramebuffer: Sendable {
  public let base: UInt64
  public let width: Int, height: Int, stride: Int
  /// zbi.h's pixel format.
  public let format: UInt32

  public init?(bootData: borrowing Handle) {
    guard let size = try? VMO.size(bootData), let m = try? VMO.map(bootData, length: size, writable: false) else {
      return nil
    }
    var at = 32  // past the container's header
    while at + 32 <= size {
      let type = m.load(UInt32.self, at: at)
      let length = Int(m.load(UInt32.self, at: at + 4))
      if type == 0x4246_5753, length >= 24, at + 32 + 24 <= size {  // "SWFB"
        let p = at + 32
        base = m.load(UInt64.self, at: p)
        width = Int(m.load(UInt32.self, at: p + 8))
        height = Int(m.load(UInt32.self, at: p + 12))
        stride = Int(m.load(UInt32.self, at: p + 16))
        format = m.load(UInt32.self, at: p + 20)
        return
      }
      at += 32 + ((length + 7) & ~7)
    }
    return nil
  }
}
