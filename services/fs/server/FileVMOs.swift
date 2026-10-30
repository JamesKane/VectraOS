// SPDX-License-Identifier: BSD-3-Clause

// The fs service's file cache (D131): a file's bytes, once read, in a VMO
// of its own at their own offsets, which fs maps and its reads copy from.
// Natively the VMO is a pager VMO (pager(2)): a page that isn't resident
// is asked for on the pager's port, and a thread of its own answers,
// reading the volume through Taisce's lock-free reader (S1f) on a second
// channel to the partition, so a fault on the volume's thread waits only
// for it, never the other way. A first miss in a file brings the 64 KiB
// around it; each miss where the last range ended doubles the range, up
// to an extent's 512 KiB. Clean pages are the kernel's to evict under
// pressure, charged to fs's account. Hosted there is no pager: a file's
// VMO is filled whole when it is made, with room to grow by a quarter,
// and made again when it outgrows that.
//
// Writes land in the VMOs too, behind: a write is copied into the file's
// VMO, the volume notes the size and times it makes (Taisce's
// `wroteBehind`), and its pages are dirty until a commit or an fsync
// writes them back (`writeBack`, which gives the volume the bytes with
// that size and times in one batch) and, once that is durable, makes
// them clean, the kernel's to evict. fs knows which pages it wrote (its
// mapping is the only writable one), so it keeps them itself, hosted as
// natively. A write goes to the volume at once only when the file has no
// VMO, or when the volume might not have a block for every page behind.
//
// A client maps a file (File.map, Mapped.swift) through a REFERENCE child
// of its VMO, read-only, and reads its size from the file's slot in the
// volume's slot table, both kept current under the slot's seqlock. A file
// keeps its VMO and slot while any child is held (until the VMO says it
// has none); an unlink or a rename marks the slots it had gone. Hosted,
// a client gets the VMO itself, read-only, and a file that outgrows it is
// marked replaced.
// Everything here but the pager thread runs on the volume's thread.

import Fs
import IPC
import Node
import Sys
import Taisce

/// One file's VMO, as the volume's thread keeps it.
final class FileVMO {
  let ino: UInt64
  let vmo: Handle
  /// fs's own mapping of all of it, writable.
  var mapping: Mapping
  /// The file's size, as the volume last said.
  var size: UInt64
  /// The pages written behind since the last write back, whole pages in
  /// order, and those written back that wait for a commit to be clean.
  var dirty: [Range<UInt64>] = []
  var cleaning: [Range<UInt64>] = []
  /// When it was last used, on the cache's clock.
  var used: UInt64 = 0
  /// Its slot, once a client maps it; those a rename marked gone, freed
  /// with its children.
  var slot: Int? = nil
  var retired: [Int] = []
  /// A client holds a child of its VMO (hosted: once one has mapped it).
  var handedOut = false
  /// Unlinked while mapped: dropped once no child is held.
  var gone = false

  init(ino: UInt64, vmo: consuming Handle, mapping: consuming Mapping, size: UInt64) {
    self.ino = ino
    self.vmo = vmo
    self.mapping = mapping
    self.size = size
  }

  var capacity: Int { mapping.length }
  var written: Bool { !dirty.isEmpty }

  /// Up to `buffer.count` bytes from `offset`, to the file's end.
  func read(_ offset: UInt64, into buffer: UnsafeMutableRawBufferPointer) -> Int {
    guard offset < size else { return 0 }
    let n = Int(Swift.min(UInt64(buffer.count), size - offset))
    if n > 0 { unsafe buffer.baseAddress!.copyMemory(from: mapping.address + Int(offset), byteCount: n) }
    return n
  }
}

/// The files' VMOs: the last `kept` used, those written since the last
/// commit, and those mapped by clients, by inode in order.
struct FileVMOs {
  var entries: [FileVMO] = []
  var clock: UInt64 = 0
  /// Pages written behind, in every file.
  var dirtyPages = 0
  /// The pager and its thread; nil hosted.
  let pager: PagerThread?
  /// The slot table its clients map; nil if it couldn't be made (nothing
  /// is mapped then).
  let table: SlotTable?

  init(pager: PagerThread?) {
    self.pager = pager
    table = SlotTable()
  }

  static let kept = 4096
  static let page = 4096

  /// The index of `ino`'s entry, or where it would go.
  func index(_ ino: UInt64) -> (Int, found: Bool) {
    var lo = 0, hi = entries.count
    while lo < hi {
      let mid = (lo + hi) / 2
      if entries[mid].ino < ino { lo = mid + 1 } else { hi = mid }
    }
    return (lo, lo < entries.count && entries[lo].ino == ino)
  }

  /// A VMO's size for a file of `size` bytes: whole pages, a quarter more
  /// to grow into, never none.
  static func capacity(for size: UInt64) -> Int {
    let n = Int(size) + Int(size) / 4
    return Swift.max(page, (n + page - 1) & ~(page - 1))
  }

  static func pages(_ ranges: [Range<UInt64>]) -> Int {
    ranges.reduce(0) { $0 + Int($1.upperBound - $1.lowerBound) / page }
  }
}

extension FsService {
  /// `ino`'s VMO, made if it has none (`inode`, if the caller has just
  /// read it); nil if it can't be made (read the volume then).
  func fileVMO(_ ino: UInt64, _ inode: Inode? = nil) throws(TaisceError) -> FileVMO? {
    files.clock += 1
    let (i, found) = files.index(ino)
    if found {
      files.entries[i].used = files.clock
      return files.entries[i]
    }
    let node: Inode
    if let inode { node = inode } else { node = try fs.stat(ino) }
    guard node.type != .directory else { throw .isDirectory }
    guard let entry = try makeFileVMO(ino, size: node.size) else { return nil }
    entry.used = files.clock
    files.entries.insert(entry, at: i)
    if files.entries.count > FileVMOs.kept { dropLeastUsed() }
    return entry
  }

  func makeFileVMO(_ ino: UInt64, size: UInt64) throws(TaisceError) -> FileVMO? {
    let capacity = FileVMOs.capacity(for: size)
    if let pager = files.pager {
      do throws(Status) {
        let vmo = try Pager.vmo(pager.pager, port: pager.port, key: ino, size: capacity)
        let mapping = try VMO.map(vmo, length: capacity)
        pager.add(ino, vmo.raw, length: capacity)
        return FileVMO(ino: ino, vmo: vmo, mapping: mapping, size: size)
      } catch {
        return nil
      }
    }
    // Hosted: filled now.
    guard size <= UInt64(MappedFile.largest) else { return nil }
    let entry: FileVMO
    do throws(Status) {
      let vmo = try VMO.create(size: capacity)
      let mapping = try VMO.map(vmo, length: capacity)
      entry = FileVMO(ino: ino, vmo: vmo, mapping: mapping, size: size)
    } catch {
      return nil
    }
    var at: UInt64 = 0
    while at < size {
      let n = Int(Swift.min(size - at, 1 << 20))
      let got = try unsafe fs.read(ino, offset: at, into: UnsafeMutableRawBufferPointer(
        start: entry.mapping.address + Int(at), count: n))
      if got == 0 { break }
      at += UInt64(got)
    }
    return entry
  }

  /// Forgets the entry used least long ago that has nothing to make clean.
  func dropLeastUsed() {
    var oldest = -1
    for (j, e) in files.entries.enumerated() where !e.written && !e.handedOut {
      if oldest < 0 || e.used < files.entries[oldest].used { oldest = j }
    }
    if oldest >= 0 { dropFileVMO(at: oldest) }
  }

  /// Drops entry `i`, its writes behind written back first; false (it
  /// stays) if they can't be.
  @discardableResult
  func dropFileVMO(at i: Int) -> Bool {
    if files.entries[i].written {
      do throws(TaisceError) { try writeBack(files.entries[i]) } catch { return false }
    }
    let e = files.entries.remove(at: i)
    if let s = e.slot { files.table?.slot(s).setFlags(MappedFile.replaced) }
    guard let pager = files.pager else { return true }
    pager.remove(e.ino)
    try? Pager.detach(pager.pager, e.vmo)
    return true
  }

  // MARK: Reads

  /// Up to `buffer.count` bytes of `ino` from `offset` into `buffer`,
  /// through its VMO: how many, fewer at the end of the file.
  func readCached(_ ino: UInt64, offset: UInt64, into buffer: UnsafeMutableRawBufferPointer, _ inode: Inode? = nil)
    throws(TaisceError) -> Int
  {
    guard let e = try fileVMO(ino, inode) else { return try unsafe fs.read(ino, offset: offset, into: buffer) }
    return unsafe e.read(offset, into: buffer)
  }

  /// Up to `count` bytes of `ino` from `offset`, through its VMO.
  func readCached(_ ino: UInt64, offset: UInt64, count: Int, _ inode: Inode? = nil) throws(TaisceError) -> [UInt8] {
    guard let e = try fileVMO(ino, inode) else {
      if let inode { return try fs.read(ino, offset: offset, count: count, node: inode) }
      return try fs.read(ino, offset: offset, count: count)
    }
    let n = offset >= e.size ? 0 : Int(Swift.min(UInt64(count), e.size - offset))
    return unsafe [UInt8](unsafeUninitializedCapacity: n) { b, made in
      made = unsafe e.read(offset, into: UnsafeMutableRawBufferPointer(b))
    }
  }

  // MARK: Changes

  /// Writes `bytes` to `ino` at `offset`: behind, into its VMO, when it
  /// has one and the volume has room; else to the volume.
  func writeCached(_ ino: UInt64, offset: UInt64, _ bytes: [UInt8]) throws(TaisceError) {
    let end = offset + UInt64(bytes.count)
    guard !bytes.isEmpty, let e = try roomBehind(ino, offset, end) else {
      try fs.write(ino, offset: offset, bytes, now: FsService.now)
      return cacheWritten(ino, bytes, at: offset)
    }
    try fs.wroteBehind(ino, through: end, now: FsService.now)
    changing(e) {
      unsafe bytes.withUnsafeBytes { b in
        unsafe (e.mapping.address + Int(offset)).copyMemory(from: b.baseAddress!, byteCount: b.count)
      }
      e.size = Swift.max(e.size, end)
    }
    markDirty(e, offset, end)
  }

  /// `ino`'s VMO with room to `end`, if a write may go behind: the volume
  /// must have a block for every page behind, so writing them back can't
  /// run out of space (a commit first, if it would, frees what it can).
  func roomBehind(_ ino: UInt64, _ offset: UInt64, _ end: UInt64) throws(TaisceError) -> FileVMO? {
    let p = UInt64(FileVMOs.page)
    let pages = Int((end + p - 1) / p - offset / p)
    if !roomFor(pages) {
      try? commit()
      guard roomFor(pages) else { return nil }
    }
    // Hosted, a VMO too small is written back and dropped, and made again.
    for _ in 0..<2 {
      guard let e = try fileVMO(ino) else { return nil }
      if grow(e, at: files.index(ino).0, to: end) { return e }
    }
    return nil
  }

  func roomFor(_ pages: Int) -> Bool {
    let space = fs.engine.store.volume.allocator.availableCount + fs.engine.reclaimable
    return UInt64(files.dirtyPages + pages) <= space
  }

  /// `e`'s pages from `offset` to `end` are dirty.
  func markDirty(_ e: FileVMO, _ offset: UInt64, _ end: UInt64) {
    let p = UInt64(FileVMOs.page)
    var new = (offset / p * p)..<((end + p - 1) / p * p)
    let before = FileVMOs.pages(e.dirty)
    var kept: [Range<UInt64>] = []
    for d in e.dirty {
      if d.upperBound < new.lowerBound || d.lowerBound > new.upperBound {
        kept.append(d)
      } else {
        new = Swift.min(d.lowerBound, new.lowerBound)..<Swift.max(d.upperBound, new.upperBound)
      }
    }
    kept.insert(new, at: kept.firstIndex { $0.lowerBound > new.lowerBound } ?? kept.count)
    e.dirty = kept
    files.dirtyPages += FileVMOs.pages(kept) - before
  }

  /// After a write to the volume: the file's VMO, if it has one, gets it.
  func cacheWritten(_ ino: UInt64, _ bytes: [UInt8], at offset: UInt64) {
    let (i, found) = files.index(ino)
    guard found else { return }
    let e = files.entries[i]
    let end = offset + UInt64(bytes.count)
    guard grow(e, at: i, to: end) else { return }
    changing(e) {
      unsafe bytes.withUnsafeBytes { b in
        unsafe (e.mapping.address + Int(offset)).copyMemory(from: b.baseAddress!, byteCount: b.count)
      }
      e.size = Swift.max(e.size, end)
    }
    markDirty(e, offset, end)  // the volume has them: their pages are made clean at the commit
  }

  /// Sets `ino`'s size: what it has behind is written back first, so
  /// that no group holds the new size without the bytes below it.
  func resizeFile(_ ino: UInt64, to size: UInt64, now: UInt64) throws(TaisceError) {
    let (i, found) = files.index(ino)
    if found { try writeBack(files.entries[i]) }
    try fs.truncate(ino, size: size, now: now)
    cacheResized(ino, size)
  }

  // MARK: Writing back

  /// Gives the volume what `e` has behind: its dirty pages, with the size
  /// and times their writes made, in one batch. Natively their pages are
  /// clean once a commit or an fsync makes them durable (`cleaned`).
  func writeBack(_ e: FileVMO) throws(TaisceError) {
    guard e.written else { return }
    let p = UInt64(FileVMOs.page)
    let held = (e.size + p - 1) / p * p  // pages past the end are only cleaned
    var pages: [(offset: UInt64, bytes: [UInt8])] = []
    for r in e.dirty where r.lowerBound < held {
      let n = Int(Swift.min(r.upperBound, held) - r.lowerBound)
      pages.append((r.lowerBound, unsafe Array(UnsafeRawBufferPointer(start: e.mapping.address + Int(r.lowerBound), count: n))))
    }
    do throws(TaisceError) {
      try fs.writeBack(e.ino, pages)
    } catch .notFound {
      // Freed since it was written: its bytes have nowhere to go.
    }
    if let pager = files.pager {
      for r in e.dirty {
        try? Pager.writebackBegin(pager.pager, e.vmo, offset: r.lowerBound, length: Int(r.upperBound - r.lowerBound))
      }
    }
    e.cleaning += e.dirty
    files.dirtyPages -= FileVMOs.pages(e.dirty)
    e.dirty = []
  }

  /// Everything behind given to the volume, before a commit or an fsync:
  /// the first failure, once each file has been tried (those that failed
  /// stay behind, for the next).
  func writeBackAll() -> TaisceError? {
    var failed: TaisceError? = nil
    for e in files.entries where e.written {
      do throws(TaisceError) { try writeBack(e) } catch { failed = failed ?? error }
    }
    return failed
  }

  /// After a commit or an fsync: what was written back is durable, so its
  /// pages are clean, the kernel's to evict.
  func cleaned() {
    for e in files.entries where !e.cleaning.isEmpty {
      if let pager = files.pager {
        for r in e.cleaning {
          try? Pager.writebackEnd(pager.pager, e.vmo, offset: r.lowerBound, length: Int(r.upperBound - r.lowerBound))
        }
      }
      e.cleaning = []
    }
  }

  /// Runs `change` to `e`'s bytes or size under its slot's seqlock, if
  /// a client maps it, and leaves its size there.
  func changing(_ e: FileVMO, _ change: () -> Void) {
    guard let s = e.slot, let table = files.table else { return change() }
    let slot = table.slot(s)
    slot.update {
      change()
      slot.setSize(e.size)
    }
  }

  /// After the file's size changed: the bytes past a shorter end read as
  /// zeros, and a longer one fits.
  func cacheResized(_ ino: UInt64, _ size: UInt64) {
    let (i, found) = files.index(ino)
    guard found else { return }
    let e = files.entries[i]
    if size < e.size {
      // Natively the pages past the new room go with a smaller VMO; the
      // old bytes left inside it, to the old end, become zeros, so that a
      // later write past them shows a hole.
      if files.pager != nil, !resize(e, at: i, to: FileVMOs.capacity(for: size)) { return }
      let zeroTo = Swift.min(e.size, UInt64(e.capacity))
      changing(e) {
        if zeroTo > size {
          unsafe (e.mapping.address + Int(size)).initializeMemory(as: UInt8.self, repeating: 0, count: Int(zeroTo - size))
        }
        e.size = size
      }
      if zeroTo > size { markDirty(e, size, zeroTo) }
      return
    } else if !grow(e, at: i, to: size) {
      return
    }
    changing(e) { e.size = size }
  }

  /// After an unlink: its VMO goes, once no client maps it; its slot
  /// says gone at once.
  func cacheGone(_ ino: UInt64) {
    let (i, found) = files.index(ino)
    guard found else { return }
    let e = files.entries[i]
    guard e.handedOut else {
      dropFileVMO(at: i)
      return
    }
    if let s = e.slot { files.table?.slot(s).setFlags(MappedFile.gone) }
    e.gone = true
  }

  /// After a rename, which may move any mapped file's path: every slot a
  /// client has is gone, and a file mapped again gets a new one.
  func cacheRenamed() {
    guard let table = files.table else { return }
    for e in files.entries {
      guard let s = e.slot else { continue }
      table.slot(s).setFlags(MappedFile.gone)
      e.retired.append(s)
      e.slot = nil
    }
  }

  // MARK: Mapping

  /// `ino`'s data mapped for a client: a REFERENCE child of its VMO,
  /// read-only, the slot table and its slot.
  func mapFile(_ ino: UInt64) throws(FsIPC.FsError) -> FsIPC.FileMap {
    guard let table = files.table else { throw .unsupported }
    let found: FileVMO?
    do throws(TaisceError) { found = try fileVMO(ino) } catch { throw Self.fsError(error) }
    guard let e = found, !e.gone else { throw .noSpace }
    if e.slot == nil {
      guard let s = table.allocate() else { throw .noSpace }
      e.slot = s
      table.slot(s).start(size: e.size)
    }
    let rights: Rights = [.transfer, .duplicate, .wait, .inspect, .read, .map, .getProperty]
    do throws(Status) {
      let data: Handle
      if files.pager != nil {
        data = try VMO.child(e.vmo, options: VMO.referenceChild, offset: 0, size: 0).replace(rights)
        if !e.handedOut {
          // Until the last child goes: its slots are freed then.
          try dispatcher.watch(try e.vmo.duplicate(), signals: VMO.zeroChildren) { [self] _ in
            unmapped(ino)
            return false
          }
        }
      } else {
        data = try e.vmo.duplicate(rights)
      }
      e.handedOut = true
      render()
      return FsIPC.FileMap(data: data, table: try table.vmo.duplicate(rights), slot: UInt32(e.slot!))
    } catch {
      throw .io
    }
  }

  /// No client maps `ino` any more: its slots are free, and an unlinked
  /// file's VMO goes.
  func unmapped(_ ino: UInt64) {
    let (i, found) = files.index(ino)
    guard found else { return }
    let e = files.entries[i]
    if let table = files.table {
      for s in e.retired + (e.slot.map { [$0] } ?? []) { table.release(s) }
    }
    e.retired = []
    e.slot = nil
    e.handedOut = false
    if e.gone { dropFileVMO(at: i) }
    render()
  }

  /// How many files clients map.
  public var mappedFiles: Int { files.entries.reduce(0) { $0 + ($1.handedOut ? 1 : 0) } }

  /// Room in `e` for `end` bytes: natively a larger VMO, hosted a new one
  /// later (the entry dropped now). False if the entry was dropped.
  func grow(_ e: FileVMO, at i: Int, to end: UInt64) -> Bool {
    guard end > UInt64(e.capacity) else { return true }
    guard files.pager != nil else {
      dropFileVMO(at: i)
      return false
    }
    return resize(e, at: i, to: FileVMOs.capacity(for: end))
  }

  /// `e`'s VMO made `capacity` bytes, and mapped again; dropped if that fails.
  func resize(_ e: FileVMO, at i: Int, to capacity: Int) -> Bool {
    guard capacity != e.capacity else { return true }
    do throws(Status) {
      try VMO.setSize(e.vmo, capacity)
      // Pages cut off are neither dirty nor waiting to be clean.
      let cap = UInt64(capacity)
      let before = FileVMOs.pages(e.dirty)
      e.dirty = e.dirty.compactMap { $0.lowerBound < cap ? $0.lowerBound..<Swift.min($0.upperBound, cap) : nil }
      e.cleaning = e.cleaning.compactMap { $0.lowerBound < cap ? $0.lowerBound..<Swift.min($0.upperBound, cap) : nil }
      files.dirtyPages -= before - FileVMOs.pages(e.dirty)
      e.mapping = try VMO.map(e.vmo, length: capacity)
      files.pager?.resized(e.ino, length: capacity)
      return true
    } catch {
      dropFileVMO(at: i)
      return false
    }
  }
}

/// The volume's slot table (Mapped.swift): its clients map it read-only.
final class SlotTable {
  let vmo: Handle
  let mapping: Mapping
  var free: [Int] = []
  var next = 0

  init?() {
    do throws(Status) {
      vmo = try VMO.create(size: MappedFile.slots * MappedFile.slotSize)
      mapping = try VMO.map(vmo, length: MappedFile.slots * MappedFile.slotSize)
    } catch {
      return nil
    }
  }

  func allocate() -> Int? {
    if let s = free.popLast() { return s }
    guard next < MappedFile.slots else { return nil }
    next += 1
    return next - 1
  }

  func release(_ s: Int) { free.append(s) }

  func slot(_ s: Int) -> MappedSlot { unsafe MappedSlot(unsafe: mapping.address, slot: s) }
}

/// The pager's side: a thread that answers the file VMOs' page requests
/// from the volume as its last published state has it.
final class PagerThread: @unchecked Sendable {
  let pager: Handle
  let port: Handle
  /// The files' VMOs as the thread finds them by key, and their reads
  /// ahead: the volume's thread adds and takes them out under the lock,
  /// and closes a VMO's handle only once it is out.
  let lock = Lock()
  var files: [Paged] = []
  var reader: FileReader<VolumeDevice>
  /// Where a range is read before it is supplied: its pages move into the
  /// file's VMO, and the next range's are new.
  let aux: Handle
  let auxMapping: Mapping

  struct Paged {
    let ino: UInt64
    let vmo: UInt32
    var length: Int
    /// Where the last range supplied ended, and how long it was.
    var next: UInt64 = .max
    var window = 0
  }

  static let first = 64 << 10
  static let largest = 512 << 10

  init(reader: consuming FileReader<VolumeDevice>) throws(Status) {
    pager = try Pager.create()
    port = try Port.create()
    aux = try VMO.create(size: Self.largest)
    auxMapping = try VMO.map(aux, length: Self.largest)
    self.reader = reader
    _ = try Thread.spawn { [self] in run() }.release()
  }

  func add(_ ino: UInt64, _ vmo: UInt32, length: Int) {
    lock.withLock { files.append(Paged(ino: ino, vmo: vmo, length: length)) }
  }

  func remove(_ ino: UInt64) {
    lock.withLock { files.removeAll { $0.ino == ino } }
  }

  func resized(_ ino: UInt64, length: Int) {
    lock.withLock {
      for i in files.indices where files[i].ino == ino { files[i].length = length }
    }
  }

  func run() {
    while true {
      guard let packet = try? Port.wait(port) else { return }
      guard let request = Pager.Request(packet), request.command == .read else { continue }
      serve(request)
    }
  }

  /// A read request: the range around it, or on from the last, read and
  /// supplied an aux-full at a time.
  func serve(_ r: Pager.Request) {
    let range = lock.withLock { () -> (vmo: UInt32, start: UInt64, end: UInt64)? in
      guard let i = files.firstIndex(where: { $0.ino == r.key }) else { return nil }
      var f = files[i]
      let onward = r.offset == f.next
      f.window = onward ? Swift.min(f.window * 2, Self.largest) : Self.first
      let start = onward ? r.offset : r.offset & ~UInt64(Self.first - 1)
      let end = Swift.min(Swift.max(start + UInt64(f.window), r.offset + UInt64(r.length)), UInt64(f.length))
      f.next = end
      files[i] = f
      return (f.vmo, start, end)
    }
    guard let range, range.start < range.end else { return }
    var at = range.start
    while at < range.end {
      let n = Int(Swift.min(range.end - at, UInt64(Self.largest)))
      let buffer = unsafe UnsafeMutableRawBufferPointer(start: auxMapping.address, count: n)
      let ino = r.key, from = at
      let read: Result<Int, TaisceError> = reader.withSnapshot { (s: inout FileReader<VolumeDevice>) -> Result<Int, TaisceError> in
        do throws(TaisceError) { return .success(try unsafe s.read(ino, offset: from, into: buffer)) } catch {
          return .failure(error)
        }
      }
      lock.lock()
      defer { lock.unlock() }
      // Still the file's VMO: the volume's thread closes it only once out.
      guard files.contains(where: { $0.ino == r.key && $0.vmo == range.vmo }) else { return }
      let vmo = Handle(raw: range.vmo)
      switch read {
      case .success(let got):
        if got < n { unsafe (auxMapping.address + got).initializeMemory(as: UInt8.self, repeating: 0, count: n - got) }
        try? Pager.supply(pager, vmo, offset: at, length: n, from: aux)
      case .failure(let e):
        let status: Status = if case .corrupt(.checksum) = e { .ioDataIntegrity } else { .io }
        try? Pager.fail(pager, vmo, offset: r.offset, length: r.length, status)
        _ = vmo.release()
        return
      }
      _ = vmo.release()
      at += UInt64(n)
    }
  }
}
