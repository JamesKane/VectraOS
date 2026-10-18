// SPDX-License-Identifier: BSD-3-Clause

// A recording on croi (M3f): croi's kernel rings and a region per traced
// process, read back as one trace. The session starts croi's kernel trace
// (trace_configure, with the tracing or root resource), makes each
// process's region (a VMO with the header written, given to the process
// as processargs' PA_TRACE_REGION: `region(for:)`), and when the recording
// ends writes every region and the kernel's rings out as `.trace` files
// (docs/trace-format.md), compacted to what was written.
//
// Getting them out of the guest: croi has no device to the host before
// virtio, so `export` prints each file in base64 over the debuglog, one
// line a record:
//
//     td-trace NAME OFFSET BASE64     (120 bytes a line)
//     td-trace NAME OFFSET zero COUNT (a run of zeros)
//     td-trace NAME end SIZE
//
// paced to the console (see `perLine`), and `vx trace collect` reassembles
// them from the console. Slow (paced to the console, below), but the
// recordings are small and it needs nothing croi doesn't have. The
// kernel's file is `kernel.trace`: process 0, a ring a CPU, no names.
//
// Thread ids: croi names a thread by its process's internal task id and
// index, which user space can't read yet, so a region's process id is
// 0xF0000 + its number here; records join the kernel's through flow ids.
//
// V2 (D50): every ring is a trace ring, a header then a one ring, read
// through Ring.swift; the regions and the kernel's rings are read through
// mappings (V1 cut vmo_read and vmo_write, D37).

import CroiSyscall
import Ring
import Sys
import TraceFormat

public final class TraceSession {
  /// croi's kernel categories (trace.h).
  public enum Kernel {
    public static var sched: UInt32 { CROI_TRACE_SCHED }
    public static var irq: UInt32 { CROI_TRACE_IRQ }
    public static var vm: UInt32 { CROI_TRACE_VM }
    public static var ipc: UInt32 { CROI_TRACE_IPC }
    public static var futex: UInt32 { CROI_TRACE_FUTEX }
    public static var syscall: UInt32 { CROI_TRACE_SYSCALL }
    /// Samples of what each CPU runs, `sampleHz` a second, with their
    /// stacks.
    public static var sample: UInt32 { CROI_TRACE_SAMPLE }
  }

  static let stringsSize = 64 * 1024
  static let rings = 16
  static let recordsPerRing = 8192

  let resource: UInt32
  let categories: TraceCategory
  public let counterHz: UInt64
  public let start: UInt64
  /// A mapping the session keeps (arrays can't hold a `Mapping`).
  final class Mapped {
    let mapping: Mapping
    init(_ mapping: consuming Mapping) { self.mapping = mapping }
  }

  /// Each CPU's ring, mapped read only.
  var kernelRings: [Mapped] = []
  /// Each region made, its owner's name, and the session's mapping of it.
  var regions: [(name: String, region: Mapped)] = []
  var stopped = false

  /// Starts croi's kernel trace (`kernel`, a mask of `Kernel` categories,
  /// `pagesPerCPU` × 128 records a CPU, oneshot; samples, if asked for,
  /// `sampleHz` a second, 0 for the kernel's default) and a session whose
  /// regions record `categories`. `resource`: the tracing or root resource,
  /// borrowed.
  public init(resource: UInt32, categories: TraceCategory, kernel: UInt32, pagesPerCPU: Int = 256,
              sampleHz: UInt64 = 0) throws(Status) {
    self.resource = resource
    self.categories = categories
    try Self.check(croi_syscall6(CROI_SYS_TRACE_CONFIGURE, UInt64(resource), CROI_TRACE_OP_START, UInt64(kernel),
                                 UInt64(pagesPerCPU), UInt64(CROI_TRACE_ONESHOT), sampleHz))
    var handles = InlineArray<64, UInt32>(repeating: 0)
    let count = unsafe withUnsafeMutablePointer(to: &handles) { p in
      unsafe croi_syscall6(CROI_SYS_TRACE_CONFIGURE, UInt64(resource), CROI_TRACE_OP_RINGS,
                           UInt64(UInt(bitPattern: p)), 64, 0, 0)
    }
    try Self.check(count)
    for i in 0..<Int(count) {
      let vmo = Handle(raw: handles[i])
      kernelRings.append(Mapped(try VMO.map(vmo, length: try VMO.size(vmo), writable: false)))
    }
    guard let first = kernelRings.first else { throw .badState }
    counterHz = first.mapping.load(UInt64.self, at: TraceFormat.ringFrequency)
    start = first.mapping.load(UInt64.self, at: TraceFormat.ringSession)
  }

  static func check(_ r: Int64) throws(Status) {
    if r < 0 { throw Status(result: r) }
  }

  /// A new region for the process `name`: a handle to move into it, with
  /// its processargs info word. The session keeps its own mapping.
  public func region(for name: String) -> (info: UInt32, handle: UInt32)? {
    guard !stopped else { return nil }
    let ringSize = TraceFormat.ringHeaderSize + RingLayout.size(slotSize: TraceFormat.slotSize,
                                                                 count: Self.recordsPerRing)!
    let size = TraceFormat.headerSize + Self.stringsSize + Self.rings * ringSize
    do throws(Status) {
      let vmo = try VMO.create(size: size)
      let m = try VMO.map(vmo, length: size)
      m.store(TraceFormat.regionMagic, at: 0)
      m.store(TraceFormat.version, at: 4)
      m.store(counterHz, at: TraceFormat.counterHz)
      m.store(start, at: TraceFormat.start)
      m.store(UInt32(0xF0000 + regions.count + 1), at: TraceFormat.processID)
      m.store(UInt32(Self.rings), at: TraceFormat.ringCount)
      m.store(UInt64(ringSize), at: TraceFormat.ringSize)
      m.store(UInt64(TraceFormat.headerSize), at: TraceFormat.stringsOffset)
      m.store(UInt64(Self.stringsSize), at: TraceFormat.stringsSize)
      m.store(UInt64(TraceFormat.headerSize + Self.stringsSize), at: TraceFormat.ringsOffset)
      m.store(categories.rawValue, at: TraceFormat.categories)
      regions.append((name, Mapped(m)))
      return (ProcessArgs.info(ProcessArgs.traceRegion), vmo.release())
    } catch {
      return nil
    }
  }

  /// Ends the recording: the kernel's, and the regions' (their categories
  /// cleared, so processes still running stop writing).
  public func stop() {
    guard !stopped else { return }
    stopped = true
    _ = croi_syscall6(CROI_SYS_TRACE_CONFIGURE, UInt64(resource), CROI_TRACE_OP_STOP, 0, 0, 0, 0)
    for r in regions { r.region.mapping.store(UInt64(0), at: TraceFormat.categories) }
  }

  /// The recording of the region given to `name` (its last), as a trace
  /// file; nil if there's none. (Stop first.)
  public func file(of name: String) -> [UInt8]? {
    let wanted = Array(name.utf8)
    guard let r = regions.last(where: { Array($0.name.utf8) == wanted }) else { return nil }
    return regionFile(r.region.mapping)
  }

  /// The kernel's recording, as a trace file. (Stop first.)
  public func kernelTrace() -> [UInt8] { kernelFile() }

  // MARK: Export

  /// Stops, then writes every file through `line` (export's lines, above).
  public func export(_ line: (String) -> Void) {
    stop()
    var files: [(name: String, bytes: [UInt8])] = []
    files.append(("kernel", kernelFile()))
    for (i, r) in regions.enumerated() { files.append(("\(i + 1)-\(r.name)", regionFile(r.region.mapping))) }
    for f in files { emit(f.name, f.bytes, line) }
    // The console drains slower than this paces under load, and croi's
    // power-off waits only 100 ms for it (K10e): until it has caught up.
    Debuglog.waitForConsole(deadline: Clock.monotonic() + Self.drain)
  }

  /// How long the export waits at most at its end for the console.
  static let drain: Int64 = 5_000_000_000

  /// The time a line is given: croi's debuglog has no flow control, and
  /// drops records when its console dumper falls 512 behind ("dlog: N
  /// records dropped"). The console drains about half a line a millisecond
  /// under KVM (each byte to the UART is an exit; M3f measured ~110 KB/s),
  /// so the export goes slower than that, and a dropped line shows in `vx
  /// trace collect` as a missing piece. Keep recordings small.
  static let perLine: Int64 = 2_500_000

  func emit(_ name: String, _ bytes: [UInt8], _ line: (String) -> Void) {
    var at = 0, lines = 0
    while at < bytes.count {
      // A run of zeros (the header, rings' padding) is one line.
      var zeros = 0
      while at + zeros < bytes.count && bytes[at + zeros] == 0 { zeros += 1 }
      if zeros >= 120 {
        line("td-trace \(name) \(at) zero \(zeros)")
        at += zeros
      } else {
        let n = min(120, bytes.count - at)
        line("td-trace \(name) \(at) \(Self.base64(bytes[at..<(at + n)]))")
        at += n
      }
      lines += 1
      sleep(until: Clock.monotonic() + Self.perLine)
    }
    line("td-trace \(name) end \(bytes.count)")
  }

  /// A process's region, compacted: the strings used, and each claimed ring
  /// with its records in order from the start.
  func regionFile(_ m: borrowing Mapping) -> [UInt8] {
    let header = m.read(at: 0, count: TraceFormat.headerSize)
    let used = min(Int(m.load(UInt64.self, at: TraceFormat.stringsUsed)), Self.stringsSize)
    let strings = m.read(at: Int(m.load(UInt64.self, at: TraceFormat.stringsOffset)), count: used)
    let claimed = min(Int(m.load(UInt32.self, at: TraceFormat.ringsClaimed)),
                      Int(m.load(UInt32.self, at: TraceFormat.ringCount)))
    let ringsAt = Int(m.load(UInt64.self, at: TraceFormat.ringsOffset))
    let ringSize = Int(m.load(UInt64.self, at: TraceFormat.ringSize))
    var rings: [(header: [UInt8], slots: [UInt8])] = []
    for i in 0..<claimed {
      let at = ringsAt + i * ringSize
      rings.append((m.read(at: at, count: TraceFormat.ringHeaderSize),
                    unsafe Self.slots(m.address + at + TraceFormat.ringHeaderSize, size: ringSize - TraceFormat.ringHeaderSize)))
    }
    var file = header
    return Self.assemble(&file, strings: strings, rings: rings)
  }

  /// The kernel's rings as a region: process 0, no strings, a ring a CPU.
  func kernelFile() -> [UInt8] {
    var rings: [(header: [UInt8], slots: [UInt8])] = []
    for r in kernelRings {
      rings.append((r.mapping.read(at: 0, count: TraceFormat.ringHeaderSize),
                    unsafe Self.slots(r.mapping.address + TraceFormat.ringHeaderSize,
                                      size: r.mapping.length - TraceFormat.ringHeaderSize)))
    }
    var file = [UInt8](repeating: 0, count: TraceFormat.headerSize)
    Self.put(&file, TraceFormat.regionMagic, 0)
    Self.put(&file, TraceFormat.version, 4)
    Self.put(&file, counterHz, TraceFormat.counterHz)
    Self.put(&file, start, TraceFormat.start)
    return Self.assemble(&file, strings: [], rings: rings)
  }

  /// The slots a ring at `ring` (`size` bytes) holds, oldest first, read
  /// as any reader reads them.
  @unsafe
  static func slots(_ ring: UnsafeMutableRawPointer, size: Int) -> [UInt8] {
    guard var reader = unsafe NativeRing(attaching: ring, size: size, producer: false, slotSize: TraceFormat.slotSize,
                                         format: TraceFormat.ringFormat, flags: RingLayout.overwrite)
    else { return [] }
    var out: [UInt8] = []
    var slot = InlineArray<5, UInt64>(repeating: 0)
    var dropped: UInt64 = 0
    while unsafe withUnsafeMutableBytes(of: &slot, { unsafe reader.read(to: $0.baseAddress!, dropped: &dropped) }) {
      unsafe withUnsafeBytes(of: &slot) { unsafe out.append(contentsOf: $0) }
    }
    return out
  }

  /// `header` with the layout rewritten for `strings` and `rings`, each ring
  /// a trace ring holding its slots from the start, in a one ring of a
  /// capacity that fits them all.
  static func assemble(_ header: inout [UInt8], strings: [UInt8], rings: [(header: [UInt8], slots: [UInt8])])
    -> [UInt8]
  {
    var capacity = 1
    for r in rings { while capacity < r.slots.count / TraceFormat.slotSize { capacity <<= 1 } }
    let ringBytes = RingLayout.size(slotSize: TraceFormat.slotSize, count: capacity)!
    let ringSize = TraceFormat.ringHeaderSize + ringBytes
    let stringsSize = (strings.count + 3) & ~3
    put(&header, UInt32(rings.count), TraceFormat.ringCount)
    put(&header, UInt32(rings.count), TraceFormat.ringsClaimed)
    put(&header, UInt64(ringSize), TraceFormat.ringSize)
    put(&header, UInt64(TraceFormat.headerSize), TraceFormat.stringsOffset)
    put(&header, UInt64(stringsSize), TraceFormat.stringsSize)
    put(&header, UInt64(strings.count), TraceFormat.stringsUsed)
    put(&header, UInt64(TraceFormat.headerSize + stringsSize), TraceFormat.ringsOffset)
    var file = header
    file += strings
    file += [UInt8](repeating: 0, count: stringsSize - strings.count)
    let memory = UnsafeMutableRawPointer.allocate(byteCount: ringBytes, alignment: 128)
    defer { unsafe memory.deallocate() }
    for r in rings {
      var h = r.header
      put(&h, UInt32(0), TraceFormat.ringMode)  // read from the start: no wrap
      file += h
      // A fresh ring, written slot by slot (each takes its new sequence).
      unsafe memory.initializeMemory(as: UInt8.self, repeating: 0, count: ringBytes)
      guard unsafe NativeRing.create(memory, size: ringBytes, slotSize: TraceFormat.slotSize, count: capacity,
                                     format: TraceFormat.ringFormat, flags: RingLayout.overwrite),
        var writer = unsafe NativeRing(attaching: memory, size: ringBytes, producer: true,
                                       slotSize: TraceFormat.slotSize, format: TraceFormat.ringFormat,
                                       flags: RingLayout.overwrite)
      else { continue }
      unsafe r.slots.withUnsafeBytes { b in
        for i in 0..<(b.count / TraceFormat.slotSize) {
          unsafe writer.write(from: b.baseAddress! + i * TraceFormat.slotSize)
        }
      }
      unsafe file += [UInt8](UnsafeRawBufferPointer(start: memory, count: ringBytes))
    }
    return file
  }

  // MARK: Bytes

  static func put<T: FixedWidthInteger>(_ bytes: inout [UInt8], _ v: T, _ at: Int) {
    for i in 0..<MemoryLayout<T>.size { bytes[at + i] = UInt8(truncatingIfNeeded: v >> (8 * i)) }
  }

  static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)

  /// RFC 4648 base64, padded.
  static func base64(_ bytes: ArraySlice<UInt8>) -> String {
    var out: [UInt8] = []
    var i = bytes.startIndex
    while i < bytes.endIndex {
      let n = min(3, bytes.endIndex - i)
      var v = UInt32(bytes[i]) << 16
      if n > 1 { v |= UInt32(bytes[i + 1]) << 8 }
      if n > 2 { v |= UInt32(bytes[i + 2]) }
      out.append(alphabet[Int(v >> 18 & 63)])
      out.append(alphabet[Int(v >> 12 & 63)])
      out.append(n > 1 ? alphabet[Int(v >> 6 & 63)] : UInt8(ascii: "="))
      out.append(n > 2 ? alphabet[Int(v & 63)] : UInt8(ascii: "="))
      i += n
    }
    return String(decoding: out, as: UTF8.self)
  }
}
