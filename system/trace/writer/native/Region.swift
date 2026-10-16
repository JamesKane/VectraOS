// SPDX-License-Identifier: BSD-3-Clause

// The trace region, natively (M3f): a VMO the process was started with
// (processargs' PA_USER1, `ProcessArgs.traceRegion`), made and headed by
// whoever traces it (the launcher's TraceSession), which reads it back
// when the recording ends. This process only maps it and writes rings; the
// header says which categories are on. A thread's ring is found through
// its thread block (libsys's td_trace_thread_ring).

import LibSys
import Sys
import TraceFormat

extension Trace {
  static let startLock = Lock()
  /// The region's mapping, kept for the process's life.
  nonisolated(unsafe) static var mapping: Mapping?

  /// Starts recording if the process was given a region. Called by the
  /// first trace name, so a program needn't call it. Returns whether
  /// recording.
  @discardableResult
  public static func startFromEnvironment() -> Bool {
    startLock.withLock { () -> Bool in
      if unsafe startAttempted { return unsafe region != nil }
      unsafe startAttempted = true
      guard let raw = StartupHandles.take(ProcessArgs.info(ProcessArgs.traceRegion)) else { return false }
      return adopt(Handle(raw: raw))
    }
  }

  /// Records into `region`, a region VMO (the tracing process's own, from
  /// its TraceSession), unless recording already. Returns whether recording.
  @discardableResult
  public static func start(region vmo: consuming Handle) -> Bool {
    startLock.lock()
    defer { startLock.unlock() }
    unsafe startAttempted = true
    if unsafe region != nil { return true }
    return adopt(vmo)
  }

  static func adopt(_ vmo: consuming Handle) -> Bool {
    guard let size = try? VMO.size(vmo), size >= TraceFormat.headerSize,
      let m = try? VMO.map(vmo, length: size)
    else { return false }
    let p = unsafe m.address
    guard unsafe p.load(as: UInt32.self) == TraceFormat.regionMagic else { return false }
    unsafe region = unsafe p
    mapping = .some(m)
    unsafe mask = unsafe p.load(fromByteOffset: TraceFormat.categories, as: UInt64.self)
    return true
  }

  /// Natively, a region comes only from the process's start: false.
  @discardableResult
  public static func start(path: String, categories: TraceCategory = .all, circular: Bool = false,
                           rings: Int = 64, recordsPerRing: Int = 1 << 15) -> Bool {
    false
  }
}
