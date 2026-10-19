// SPDX-License-Identifier: BSD-3-Clause

// The fs service's mapped files (M3l, Mapped.swift): each mapped inode's
// VMO, filled from the volume when first mapped and kept current as the
// file changes, so its readers copy instead of calling. Writes, resizes,
// unlinks and renames go through the service's sessions, which tell it
// here; all of this runs on the service's dispatcher thread.

import Fs
import IPC
import Node
import Sys
import Taisce

final class MappedEntry {
  let ino: UInt64
  let vmo: Handle
  let mapping: Mapping
  let header: MappedHeader

  init(ino: UInt64, vmo: consuming Handle, mapping: consuming Mapping) {
    header = unsafe MappedHeader(unsafe: mapping.address)
    self.ino = ino
    self.vmo = vmo
    self.mapping = mapping
  }
}

extension FsService {
  /// A read-only handle to `ino`'s mapped data, made on first use.
  func map(_ ino: UInt64) throws(FsIPC.FsError) -> Handle {
    let entry: MappedEntry
    if let e = mapped.first(where: { $0.ino == ino }) {
      entry = e
    } else {
      entry = try fill(ino)
      mapped.append(entry)
    }
    do throws(Status) {
      return try entry.vmo.duplicate([.transfer, .duplicate, .wait, .inspect, .read, .map, .getProperty])
    } catch {
      throw .io
    }
  }

  func fill(_ ino: UInt64) throws(FsIPC.FsError) -> MappedEntry {
    do throws(TaisceError) {
      let inode = try fs.stat(ino)
      guard inode.type != .directory else { throw .isDirectory }
      guard inode.size <= UInt64(MappedFile.largest) else { throw .noSpace }
      let size = Int(inode.size)
      let vmoSize = MappedFile.vmoSize(for: size)
      guard let entry = Self.makeEntry(ino, vmoSize) else { throw .noSpace }
      entry.header.start(size: 0, capacity: UInt64(vmoSize - MappedFile.headerSize))
      var at = 0
      while at < size {
        let piece = try fs.read(ino, offset: UInt64(at), count: Swift.min(size - at, 1 << 20))
        entry.header.write(piece, at: at, size: UInt64(at + piece.count))
        at += piece.count
        if piece.isEmpty { break }
      }
      entry.header.resize(UInt64(size))
      return entry
    } catch {
      throw Self.fsError(error)
    }
  }

  static func makeEntry(_ ino: UInt64, _ vmoSize: Int) -> MappedEntry? {
    do throws(Status) {
      let vmo = try VMO.create(size: vmoSize)
      let mapping = try VMO.map(vmo, length: vmoSize)
      return MappedEntry(ino: ino, vmo: vmo, mapping: mapping)
    } catch {
      return nil
    }
  }

  /// After a write: the mapping copies it, or is replaced if it can't hold it.
  func mappedWrite(_ ino: UInt64, _ bytes: [UInt8], at offset: UInt64) {
    guard let i = mapped.firstIndex(where: { $0.ino == ino }) else { return }
    let e = mapped[i]
    let end = offset + UInt64(bytes.count)
    guard end <= e.header.capacity else { return dropMapping(at: i, flags: MappedFile.replaced) }
    e.header.write(bytes, at: Int(offset), size: Swift.max(e.header.size, end))
  }

  /// After a resize.
  func mappedResize(_ ino: UInt64, _ size: UInt64) {
    guard let i = mapped.firstIndex(where: { $0.ino == ino }) else { return }
    let e = mapped[i]
    guard size <= e.header.capacity else { return dropMapping(at: i, flags: MappedFile.replaced) }
    e.header.resize(size)
  }

  /// After an unlink of `ino`, or with nil after any rename (which may
  /// move any mapped file's path): those mappings are gone.
  func mappedGone(_ ino: UInt64?) {
    var i = mapped.count - 1
    while i >= 0 {
      if ino == nil || mapped[i].ino == ino { dropMapping(at: i, flags: MappedFile.gone) }
      i -= 1
    }
  }

  func dropMapping(at i: Int, flags: UInt32) {
    mapped[i].header.setFlags(flags)
    mapped.remove(at: i)
  }

  public var mappedCount: Int { mapped.count }
}
