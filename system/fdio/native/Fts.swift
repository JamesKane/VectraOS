// SPDX-License-Identifier: BSD-3-Clause

// <fts.h> under its C names (M6g), over fdio's Walk: fts_open, fts_read,
// fts_set (FTS_SKIP) and fts_close. Each FTSENT is one block: the entry,
// its name after it as BSD lays it out, then its path and its stat. As
// BSD's, an entry is freed at the next fts_read, and a directory's at the
// fts_read after its FTS_DP (or FTS_DNR), which is the same entry: a
// walk holds its open directories, not the tree it has walked (a 100k
// entry walk held ~55 MB until fts_close, D127). Devices are all 1 (one
// fs service a mount).

import VectraOSLibc

public typealias Comparison = @convention(c) (UnsafeMutablePointer<UnsafePointer<FTSENT>?>?,
                                       UnsafeMutablePointer<UnsafePointer<FTSENT>?>?) -> Int32

/// An open walk, and the entries it has given out that are still valid.
final class OpenWalk {
  let walk: Walk
  /// The directories returned as FTS_D whose FTS_DP hasn't come, outermost
  /// first.
  var open: [UnsafeMutablePointer<FTSENT>] = []
  /// The last entry returned, unless it is an open directory: freed by the
  /// next fts_read.
  var previous: UnsafeMutablePointer<FTSENT>?
  /// The directory fts_read returned last (fts_set's FTS_SKIP applies to it).
  var lastDirectory: UnsafeMutablePointer<FTSENT>?

  init(_ walk: Walk) { self.walk = walk }

  deinit {
    if let p = unsafe previous { unsafe free(p) }
    for d in open { unsafe free(d) }
  }
}

/// An FTSENT for `e`, in one block with its name, path and stat, which
/// `free` frees.
func entry(_ e: WalkEntry) -> UnsafeMutablePointer<FTSENT> {
  let name = e.name.utf8, path = e.path.utf8
  let nameOffset = MemoryLayout<FTSENT>.offset(of: \FTSENT.fts_name)!
  let pathOffset = max(MemoryLayout<FTSENT>.size, nameOffset + name.count + 1)
  let statAlign = MemoryLayout<stat>.alignment
  let statOffset = (pathOffset + path.count + 1 + statAlign - 1) & ~(statAlign - 1)
  let raw = unsafe calloc(1, e.status == nil ? pathOffset + path.count + 1 : statOffset + MemoryLayout<stat>.size)!
  let p = unsafe raw.assumingMemoryBound(to: FTSENT.self)
  unsafe copyBytes(e.path, to: raw + pathOffset)
  let pathp = unsafe (raw + pathOffset).assumingMemoryBound(to: CChar.self)
  unsafe p.pointee.fts_path = pathp
  unsafe p.pointee.fts_accpath = pathp
  unsafe p.pointee.fts_pathlen = UInt16(truncatingIfNeeded: path.count)
  unsafe p.pointee.fts_namelen = UInt16(truncatingIfNeeded: name.count)
  unsafe p.pointee.fts_level = Int16(e.level)
  unsafe p.pointee.fts_info = e.info.rawValue
  unsafe p.pointee.fts_errno = e.errno
  unsafe p.pointee.fts_dev = 1
  unsafe p.pointee.fts_ino = e.status?.id ?? 0
  unsafe p.pointee.fts_nlink = e.status.map { $0.isDirectory ? 2 : 1 } ?? 0
  if let s = e.status {
    let st = unsafe (raw + statOffset).assumingMemoryBound(to: stat.self)
    unsafe fill(st, s)
    unsafe p.pointee.fts_statp = st
  }
  let to = unsafe UnsafeMutableRawPointer(p) + nameOffset
  unsafe copyBytes(e.name, to: to)
  unsafe to.storeBytes(of: 0, toByteOffset: name.count, as: UInt8.self)
  return unsafe p
}

/// `s`'s bytes copied to `to` in one go (its UTF8View's iterator takes a
/// call a byte).
func copyBytes(_ s: String, to: UnsafeMutableRawPointer) {
  var s = s
  s.withUTF8 { unsafe UnsafeMutableRawBufferPointer(start: to, count: $0.count).copyMemory(from: UnsafeRawBufferPointer($0)) }
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
      var ea: UnsafePointer<FTSENT>? = unsafe UnsafePointer(entry(a))
      var eb: UnsafePointer<FTSENT>? = unsafe UnsafePointer(entry(b))
      let r = unsafe compar(&ea, &eb)
      unsafe free(UnsafeMutableRawPointer(mutating: ea))
      unsafe free(UnsafeMutableRawPointer(mutating: eb))
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
  if let p = unsafe w.previous {
    unsafe free(p)
    w.previous = nil
  }
  guard let e = w.walk.next() else {
    unsafe fts.pointee.fts_cur = nil
    errno = 0
    return nil
  }
  let p: UnsafeMutablePointer<FTSENT>
  if e.info == .directoryAfter || e.info == .directoryNotRead, let d = unsafe w.open.last,
    unsafe d.pointee.fts_level == Int16(e.level)
  {
    // The directory's own entry again, as BSD returns it.
    w.open.removeLast()
    unsafe d.pointee.fts_info = e.info.rawValue
    unsafe d.pointee.fts_errno = e.errno
    unsafe p = d
    unsafe w.previous = p
  } else {
    unsafe p = entry(e)
    if e.info == .directory {
      w.open.append(unsafe p)
      unsafe w.lastDirectory = p
    } else {
      unsafe w.previous = p
    }
  }
  unsafe fts.pointee.fts_cur = p
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
