// SPDX-License-Identifier: BSD-3-Clause

// <fts.h> under its C names (M6g), over fdio's Walk: fts_open, fts_read,
// fts_set (FTS_SKIP) and fts_close. Each FTSENT is allocated once, its name
// after it as BSD lays it out, and freed at fts_close; a directory's
// FTS_DP is a second entry. Devices are all 1 (one fs service a mount).

import VectraOSLibc

public typealias Comparison = @convention(c) (UnsafeMutablePointer<UnsafePointer<FTSENT>?>?,
                                       UnsafeMutablePointer<UnsafePointer<FTSENT>?>?) -> Int32

/// An open walk: what fts_read gave out, freed together at fts_close.
final class OpenWalk {
  let walk: Walk
  var entries: [UnsafeMutablePointer<FTSENT>] = []
  var strings: [UnsafeMutablePointer<CChar>] = []
  var stats: [UnsafeMutablePointer<stat>] = []
  /// The directory fts_read returned last (fts_set's FTS_SKIP applies to it).
  var lastDirectory: UnsafeMutablePointer<FTSENT>?

  init(_ walk: Walk) { self.walk = walk }

  deinit {
    for e in entries { unsafe free(e) }
    for s in strings { unsafe free(s) }
    for s in stats { unsafe s.deallocate() }
  }
}

func cString(_ s: String) -> UnsafeMutablePointer<CChar> {
  let bytes = Array(s.utf8)
  let p = unsafe malloc(bytes.count + 1)!.assumingMemoryBound(to: CChar.self)
  for (i, b) in bytes.enumerated() { unsafe p[i] = CChar(bitPattern: b) }
  unsafe p[bytes.count] = 0
  return unsafe p
}

/// An FTSENT for `e` (its strings in `strings`, which the caller frees).
func entry(_ e: WalkEntry, strings: inout [UnsafeMutablePointer<CChar>], stats: inout [UnsafeMutablePointer<stat>])
  -> UnsafeMutablePointer<FTSENT>
{
  let name = Array(e.name.utf8)
  let nameOffset = MemoryLayout<FTSENT>.offset(of: \FTSENT.fts_name)!
  let raw = unsafe calloc(1, max(MemoryLayout<FTSENT>.size, nameOffset + name.count + 1))!
  let p = unsafe raw.assumingMemoryBound(to: FTSENT.self)
  let path = unsafe cString(e.path)
  strings.append(unsafe path)
  unsafe p.pointee.fts_path = path
  unsafe p.pointee.fts_accpath = path
  unsafe p.pointee.fts_pathlen = UInt16(truncatingIfNeeded: e.path.utf8.count)
  unsafe p.pointee.fts_namelen = UInt16(truncatingIfNeeded: name.count)
  unsafe p.pointee.fts_level = Int16(e.level)
  unsafe p.pointee.fts_info = e.info.rawValue
  unsafe p.pointee.fts_errno = e.errno
  unsafe p.pointee.fts_dev = 1
  unsafe p.pointee.fts_ino = e.status?.id ?? 0
  unsafe p.pointee.fts_nlink = e.status.map { $0.isDirectory ? 2 : 1 } ?? 0
  if let s = e.status {
    let st = UnsafeMutablePointer<stat>.allocate(capacity: 1)
    unsafe fill(st, s)
    stats.append(unsafe st)
    unsafe p.pointee.fts_statp = st
  }
  let to = unsafe UnsafeMutableRawPointer(p) + nameOffset
  for (i, b) in name.enumerated() { unsafe to.storeBytes(of: b, toByteOffset: i, as: UInt8.self) }
  unsafe to.storeBytes(of: 0, toByteOffset: name.count, as: UInt8.self)
  return unsafe p
}

@c(fts_open) public func ftsOpen(_ paths: UnsafePointer<UnsafeMutablePointer<CChar>?>?, _ options: Int32,
                                 _ compar: Comparison?) -> UnsafeMutablePointer<FTS>?
{
  guard let paths = unsafe paths else {
    errno = Errno.invalid.code
    return nil
  }
  var roots: [String] = []
  var i = 0
  while let p = unsafe paths[i] {
    roots.append(unsafe String(cString: p))
    i += 1
  }
  var order: ((WalkEntry, WalkEntry) -> Bool)? = nil
  if let compar {
    // compar sees FTSENTs: two temporary ones a comparison.
    order = { a, b in
      var strings: [UnsafeMutablePointer<CChar>] = []
      var stats: [UnsafeMutablePointer<stat>] = []
      var ea: UnsafePointer<FTSENT>? = unsafe UnsafePointer(entry(a, strings: &strings, stats: &stats))
      var eb: UnsafePointer<FTSENT>? = unsafe UnsafePointer(entry(b, strings: &strings, stats: &stats))
      let r = unsafe compar(&ea, &eb)
      unsafe free(UnsafeMutableRawPointer(mutating: ea))
      unsafe free(UnsafeMutableRawPointer(mutating: eb))
      for s in strings { unsafe free(s) }
      for s in stats { unsafe s.deallocate() }
      return r < 0
    }
  }
  let walk = Walk(roots, noStat: options & FTS_NOSTAT != 0, order: order)
  let fts = UnsafeMutablePointer<FTS>.allocate(capacity: 1)
  unsafe fts.initialize(to: FTS(fts_cur: nil, fts_options: options,
                                __td_walk: Unmanaged.passRetained(OpenWalk(walk)).toOpaque()))
  return unsafe fts
}

func openWalk(_ fts: UnsafeMutablePointer<FTS>) -> OpenWalk {
  unsafe Unmanaged<OpenWalk>.fromOpaque(fts.pointee.__td_walk!).takeUnretainedValue()
}

@c(fts_read) public func ftsRead(_ fts: UnsafeMutablePointer<FTS>?) -> UnsafeMutablePointer<FTSENT>? {
  guard let fts = unsafe fts else {
    errno = Errno.invalid.code
    return nil
  }
  let w = openWalk(fts)
  w.lastDirectory = nil
  guard let e = w.walk.next() else {
    errno = 0
    return nil
  }
  let p = unsafe entry(e, strings: &w.strings, stats: &w.stats)
  w.entries.append(unsafe p)
  unsafe fts.pointee.fts_cur = p
  if e.info == .directory { unsafe w.lastDirectory = p }
  return unsafe p
}

@c(fts_set) public func ftsSet(_ fts: UnsafeMutablePointer<FTS>?, _ e: UnsafeMutablePointer<FTSENT>?, _ instruction: Int32) -> Int32 {
  guard let fts = unsafe fts, let e = unsafe e else {
    errno = Errno.invalid.code
    return -1
  }
  let w = openWalk(fts)
  unsafe e.pointee.fts_instr = UInt16(truncatingIfNeeded: instruction)
  if instruction == FTS_SKIP, unsafe w.lastDirectory == e { w.walk.skip() }
  return 0
}

@c(fts_close) public func ftsClose(_ fts: UnsafeMutablePointer<FTS>?) -> Int32 {
  guard let fts = unsafe fts else {
    errno = Errno.invalid.code
    return -1
  }
  unsafe Unmanaged<OpenWalk>.fromOpaque(fts.pointee.__td_walk!).release()
  unsafe fts.deallocate()
  return 0
}
