// SPDX-License-Identifier: BSD-3-Clause

// The trace region, hosted: a file under $TODHCHAI_TRACE, mapped shared, so
// `td trace` reads it while the program runs and after it ends.

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
import Ring
import TDTraceCPU
import TraceFormat

extension Trace {
  // Initialized, not zeroed: a zeroed mutex is valid on glibc only.
  nonisolated(unsafe) static let startLock: UnsafeMutablePointer<pthread_mutex_t> = {
    let m = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
    unsafe pthread_mutex_init(m, nil)
    return unsafe m
  }()

  /// Starts recording if $TODHCHAI_TRACE names a directory: categories from
  /// $TODHCHAI_TRACE_CATEGORIES (default all), circular if
  /// $TODHCHAI_TRACE_CIRCULAR is set. Called by the first trace name, so a
  /// program needn't call it. Returns whether recording.
  @discardableResult
  public static func startFromEnvironment() -> Bool {
    unsafe pthread_mutex_lock(startLock)
    defer { unsafe pthread_mutex_unlock(startLock) }
    if unsafe startAttempted { return unsafe region != nil }
    unsafe startAttempted = true
    guard let dir = unsafe getenv("TODHCHAI_TRACE").map({ unsafe String(cString: $0) }), !dir.isEmpty else { return false }
    let categories = unsafe getenv("TODHCHAI_TRACE_CATEGORIES").flatMap { unsafe TraceCategory(names: String(cString: $0)) }
    let circular = unsafe getenv("TODHCHAI_TRACE_CIRCULAR") != nil
    return startLocked(path: "\(dir)/\(getpid()).trace", categories: categories ?? .all, circular: circular)
  }

  /// Starts recording into `path`, replacing any recording in progress
  /// (tests use this). Threads that already wrote keep their old rings, so
  /// a new recording sees only threads that start writing after it, and
  /// names interned before the restart don't resolve in the new one.
  @discardableResult
  public static func start(path: String, categories: TraceCategory = .all, circular: Bool = false,
                           rings: Int = 64, recordsPerRing: Int = 1 << 15) -> Bool {
    unsafe pthread_mutex_lock(startLock)
    defer { unsafe pthread_mutex_unlock(startLock) }
    unsafe startAttempted = true
    unsafe mask = 0
    unsafe region = nil  // the old mapping stays, for any thread still writing to it
    return startLocked(path: path, categories: categories, circular: circular, rings: rings,
                       recordsPerRing: recordsPerRing)
  }

  static func startLocked(path: String, categories: TraceCategory, circular: Bool, rings: Int = 64,
                          recordsPerRing: Int = 1 << 15) -> Bool {
    guard unsafe region == nil else { return true }
    var capacity = 1
    while capacity < recordsPerRing { capacity <<= 1 }  // a power of two
    let stringsSize = 256 << 10
    // A trace ring: its header, then a one ring of `capacity` slots (D50).
    let ringSize = TraceFormat.ringHeaderSize + RingLayout.size(slotSize: TraceFormat.slotSize, count: capacity)!
    let size = TraceFormat.headerSize + stringsSize + rings * ringSize
    let fd = unsafe open(path, O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    guard ftruncate(fd, off_t(size)) == 0 else { return false }
    let p = unsafe mmap(nil, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
    guard let p = unsafe p, unsafe p != MAP_FAILED else { return false }

    let start = td_trace_ticks()
    func put<T: FixedWidthInteger>(_ v: T, _ offset: Int) { unsafe p.storeBytes(of: v.littleEndian, toByteOffset: offset, as: T.self) }
    put(TraceFormat.regionMagic, 0)
    put(TraceFormat.version, 4)
    put(calibrateCounterHz(), TraceFormat.counterHz)
    put(start, TraceFormat.start)
    put(UInt32(truncatingIfNeeded: getpid()), TraceFormat.processID)
    put(UInt32(rings), TraceFormat.ringCount)
    put(UInt64(ringSize), TraceFormat.ringSize)
    put(UInt64(TraceFormat.headerSize), TraceFormat.stringsOffset)
    put(UInt64(stringsSize), TraceFormat.stringsSize)
    put(UInt64(0), TraceFormat.stringsUsed)
    put(UInt64(TraceFormat.headerSize + stringsSize), TraceFormat.ringsOffset)
    put(UInt32(0), TraceFormat.ringsClaimed)
    put(circular ? TraceFormat.flagCircular : 0, TraceFormat.flags)
    put(categories.rawValue, TraceFormat.categories)
    unsafe region = unsafe p
    unsafe mask = categories.rawValue
    return true
  }

  /// The cycle counter's frequency, measured against CLOCK_MONOTONIC over
  /// 10 ms.
  static func calibrateCounterHz() -> UInt64 {
    func ns() -> UInt64 {
      var ts = timespec()
      unsafe clock_gettime(CLOCK_MONOTONIC, &ts)
      return UInt64(ts.tv_sec) * 1_000_000_000 + UInt64(ts.tv_nsec)
    }
    let t0 = td_trace_ticks(), n0 = ns()
    var sleep = timespec(tv_sec: 0, tv_nsec: 10_000_000)
    unsafe nanosleep(&sleep, nil)
    let t1 = td_trace_ticks(), n1 = ns()
    return (t1 &- t0) * 1_000_000_000 / max(n1 &- n0, 1)
  }

}
