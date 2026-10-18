// SPDX-License-Identifier: BSD-3-Clause

// The build steps CMake runs (ImageFormats does the work):
//
//   vx elf2efi IN.elf OUT.efi                 the loader as a PE32+ EFI application
//   vx mkbootfs OUT.img NAME=FILE...          a bootfs image
//   vx check-pixels FILE.ppm X,Y,R,G,B...     a screendump's pixels

import FoundationEssentials
import Glibc
import ImageFormats

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
func diskCommand(_ args: [String]) -> Bool {
  let usage = "usage: vx disk FILE SIZE [NAME:SIZE|NAME:* ...]"
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
  return true
}
