// SPDX-License-Identifier: BSD-3-Clause

// The build steps CMake runs (ImageFormats does the work):
//
//   vx elf2efi IN.elf OUT.efi                 the loader as a PE32+ EFI application
//   vx mkbootfs OUT.img NAME=FILE...          a bootfs image
//   vx library-note OUT.c LIB.so...           the libraries' build IDs, as a note to link with (D124)
//   vx check-pixels FILE.ppm X,Y,R,G,B...     a screendump's pixels

import HostSystem
import ImageFormats
import Manual
import Taisce
import TaisceHost

func readBytes(_ path: String) -> [UInt8] {
  guard let data = FileManager.default.contents(atPath: path) else { fail("can't read \(path)") }
  return [UInt8](data)
}

func writeBytes(_ bytes: [UInt8], to path: String) {
  guard FileManager.default.createFile(atPath: path, contents: Data(bytes)) else { fail("can't write \(path)") }
}

func elf2efiCommand(_ args: [String]) -> Bool {
  guard args.count == 2 else { fail("usage: vx elf2efi IN.elf OUT.efi") }
  do {
    writeBytes(try elfToEfi(readBytes(args[0])), to: args[1])
  } catch {
    fail("elf2efi: \(args[0]): \(error)")
  }
  return true
}

func libraryNoteCommand(_ args: [String]) -> Bool {
  guard args.count >= 2 else { fail("usage: vx library-note OUT.c LIB.so...") }
  var libraries: [(soname: [UInt8], buildID: [UInt8])] = []
  for path in args.dropFirst() {
    do {
      libraries.append(try sonameAndBuildID(readBytes(path)))
    } catch {
      fail("library-note: \(path): \(error)")
    }
  }
  writeBytes(Array(libraryNoteSource(libraries).utf8), to: args[0])
  return true
}

func mkbootfsCommand(_ args: [String]) -> Bool {
  guard args.count >= 2 else { fail("usage: vx mkbootfs OUT.img NAME=FILE...") }
  var files: [(name: String, contents: [UInt8])] = []
  for spec in args.dropFirst() {
    guard let eq = spec.firstIndex(of: "=") else { fail("mkbootfs: bad entry \(spec) (want name=file)") }
    files.append((String(spec[..<eq]), readBytes(String(spec[spec.index(after: eq)...]))))
  }
  do {
    writeBytes(try Bootfs.image(files), to: args[0])
  } catch {
    fail("mkbootfs: \(error)")
  }
  return true
}

func checkPixelsCommand(_ args: [String]) -> Bool {
  guard args.count >= 2 else { fail("usage: vx check-pixels FILE.ppm X,Y,R,G,B...") }
  let ppm: PPM
  do { ppm = try PPM(readBytes(args[0])) } catch { fail("\(args[0]): \(error)") }
  var failed = false
  for spec in args.dropFirst() {
    let v = spec.split(separator: ",").compactMap { Int($0) }
    guard v.count == 5 else { fail("bad pixel \(spec) (want x,y,r,g,b)") }
    guard let p = ppm.pixel(v[0], v[1]) else {
      say("(\(v[0]),\(v[1])) is outside the \(ppm.width)x\(ppm.height) screen")
      failed = true
      continue
    }
    if [Int(p.r), Int(p.g), Int(p.b)] != Array(v[2...]) {
      say("(\(v[0]),\(v[1])) is (\(p.r), \(p.g), \(p.b)), expected (\(v[2]), \(v[3]), \(v[4]))")
      failed = true
    }
  }
  say("\(ppm.width)x\(ppm.height): \(failed ? "FAILED" : "ok")")
  return !failed
}

/// "64M": 64 MiB (K, M or G, binary), or bytes.
func byteSize(_ text: String) -> UInt64? {
  guard let last = text.last else { return nil }
  let unit: UInt64? = switch last {
  case "K": 1 << 10
  case "M": 1 << 20
  case "G": 1 << 30
  default: nil
  }
  if let unit { return UInt64(text.dropLast()).map { $0 * unit } }
  return UInt64(text)
}

/// vx disk FILE SIZE [NAME:SIZE|NAME:* ...] (vx-disk(1)): a disk image of
/// SIZE bytes, made anew, with a GUID partition table of those
/// partitions, each a Taisce partition on a 1 MiB boundary; `*` the rest.
/// With --encrypt, each volume is encrypted (D153 §3), with a key of its
/// own and one slot, opened by the passphrase on standard input.
func diskCommand(_ arguments: [String]) -> Bool {
  let usage = "usage: vx disk FILE SIZE [NAME:SIZE|NAME:* ...] [--man ROOT] [--encrypt]"
  var args = arguments
  var manual: String?
  if let i = args.firstIndex(of: "--man") {
    guard i + 1 < args.count else { fail(usage) }
    manual = args[i + 1]
    args.removeSubrange(i...(i + 1))
  }
  var passphrase: [UInt8]?
  if let i = args.firstIndex(of: "--encrypt") {
    args.remove(at: i)
    guard let p = ToolSupport.passphrase() else { fail("disk: no passphrase on standard input") }
    passphrase = p
  }
  guard args.count >= 2, let size = byteSize(args[1]), size % UInt64(GPT.sectorSize) == 0 else { fail(usage) }
  var parts: [GPT.Partition] = []
  for spec in args.dropFirst(2) {
    guard let colon = spec.lastIndex(of: ":") else { fail("disk: bad partition \(spec) (want name:size)") }
    let name = String(spec[..<colon]), amount = String(spec[spec.index(after: colon)...])
    if amount == "*" {
      parts.append(GPT.Partition(name: name, sectors: nil))
    } else {
      guard let bytes = byteSize(amount), bytes % UInt64(GPT.sectorSize) == 0, bytes > 0 else {
        fail("disk: bad size in \(spec) (a multiple of \(GPT.sectorSize) bytes)")
      }
      parts.append(GPT.Partition(name: name, sectors: bytes / UInt64(GPT.sectorSize)))
    }
  }
  let writes: [(offset: UInt64, bytes: [UInt8])]
  do throws(GPT.Failure) {
    writes = try GPT.table(parts, sectors: size / UInt64(GPT.sectorSize)) {
      var g = (0..<16).map { _ in UInt8.random(in: 0...255) }
      g[6] = g[6] & 0x0F | 0x40  // version 4
      g[8] = g[8] & 0x3F | 0x80
      return g
    }
  } catch {
    fail("disk: \(error.description)")
  }
  let fd = open(args[0], O_WRONLY | O_CREAT | O_TRUNC, 0o644)
  guard fd >= 0, ftruncate(fd, off_t(size)) == 0 else { fail("disk: can't make \(args[0])") }
  defer { close(fd) }
  for w in writes {
    let n = w.bytes.withUnsafeBytes { pwrite(fd, $0.baseAddress, w.bytes.count, off_t(w.offset)) }
    guard n == w.bytes.count else { fail("disk: can't write \(args[0])") }
  }
  // Each partition a Taisce volume, labelled with its name (D105); the
  // first holds the manual, if asked.
  var first = true
  for p in partitions(args[0]) where p.type == GPT.taisceType {
    do throws(TaisceError) {
      let sealing = passphrase.map { ToolSupport.newKey(passphrase: $0) }
      var fs = try FileSystem.format(SealedDevice(try window(args[0], p), sealing: sealing.map { Sealing($0.key) }),
                                     label: Array(p.name.utf8), uuid: ToolSupport.uuid(), now: ToolSupport.now,
                                     keybag: sealing?.keybag)
      if first, let manual { try putManual(root: manual, in: &fs) }
      try fs.sync()
    } catch {
      fail("disk: can't make a volume on \(p.name): \(error)")
    }
    first = false
  }
  return true
}

/// The manual's pages at lib/man/SECTION/NAME, and its index at
/// lib/man/index, as bootfs holds them (D86).
func putManual<D: BlockDevice>(root: String, in fs: inout FileSystem<D>) throws(TaisceError) {
  let manual = Manual(root: root)
  let now = ToolSupport.now
  /// The directory `names` below the root, made as needed.
  func directory(_ names: [String]) throws(TaisceError) -> UInt64 {
    var at = FileSystem<D>.root
    for name in names {
      do throws(TaisceError) { at = try fs.lookup(at, Array(name.utf8)) } catch .notFound {
        at = try fs.create(at, Array(name.utf8), .directory, mode: 0o755, now: now)
      }
    }
    return at
  }
  func file(_ names: [String], _ bytes: [UInt8]) throws(TaisceError) {
    let dir = try directory(Array(names.dropLast()))
    let ino = try fs.create(dir, Array(names.last!.utf8), .file, mode: 0o644, now: now)
    if !bytes.isEmpty { try fs.write(ino, offset: 0, bytes, now: now) }
  }
  for page in manual.pages {
    // man/1/ls: lib/man/1/ls.
    let names = page.path.split(separator: "/").dropFirst().map(String.init)
    guard let data = FileManager.default.contents(atPath: "\(root)/\(page.path)") else { throw .io(EIO) }
    try file(["lib", "man"] + names, Array(data))
  }
  try file(["lib", "man", "index"], Array(manual.indexTSV.utf8))
}

/// The image's partitions, from its table.
func partitions(_ path: String) -> [(name: String, type: [UInt8], first: UInt64, last: UInt64)] {
  let fd = open(path, O_RDONLY)
  guard fd >= 0 else { fail("\(path): can't open") }
  defer { close(fd) }
  let read = { (offset: UInt64, count: Int) -> [UInt8]? in
    var b = [UInt8](repeating: 0, count: count)
    let n = b.withUnsafeMutableBytes { pread(fd, $0.baseAddress, count, off_t(offset)) }
    return n == count ? b : nil
  }
  guard let parts = GPT.read(read) else { fail("\(path): no GUID partition table") }
  return parts
}

/// A partition of the image as a device, in Taisce's blocks.
func window(_ path: String, _ p: (name: String, type: [UInt8], first: UInt64, last: UInt64)) throws(TaisceError)
  -> WindowDevice<FileDevice>
{
  let perBlock = UInt64(Layout.blockSize / GPT.sectorSize)
  guard p.first % perBlock == 0 else { throw .outOfRange }
  return try WindowDevice(try FileDevice(path: path), first: p.first / perBlock, count: (p.last + 1 - p.first) / perBlock)
}

/// vx fsck FILE [PARTITION] (vx-disk(1)): mounts the image's Taisce volume
/// (the partition named, or its first) and checks every node and invariant.
func fsckCommand(_ args: [String]) -> Bool {
  guard args.count == 1 || args.count == 2 else { fail("usage: vx fsck FILE [PARTITION]") }
  let parts = partitions(args[0]).filter { args.count == 1 ? $0.type == GPT.taisceType : $0.name == args[1] }
  guard let p = parts.first else { fail("fsck: \(args[0]): no such partition") }
  do throws(TaisceError) {
    // An encrypted volume is opened by the passphrase on standard input.
    var device = SealedDevice(try window(args[0], p))
    if let keybag = try Volume.newestSuperblock(&device).keybag {
      guard let passphrase = ToolSupport.passphrase() else { fail("fsck: no passphrase on standard input") }
      guard let key = keybag.unlock(passphrase) else { fail("fsck: \(args[0]) \(p.name): no slot takes the passphrase") }
      device.sealing = Sealing(key)
    }
    var fs = try FileSystem.mount(device)
    let nodes = try fs.check()
    let a = fs.engine.store.volume.allocator
    say("fsck: \(args[0]) \(p.name): clean at txg \(fs.engine.store.volume.superblock.txg); \(nodes) files and "
      + "directories; \(a.blockCount - a.freeCount) of \(a.blockCount) blocks in use")
    return true
  } catch {
    complain("fsck: \(args[0]) \(p.name): \(error)")
    return false
  }
}
