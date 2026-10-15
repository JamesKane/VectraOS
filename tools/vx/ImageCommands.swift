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
