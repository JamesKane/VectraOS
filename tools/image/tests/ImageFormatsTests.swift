// SPDX-License-Identifier: BSD-3-Clause

@testable import ImageFormats
import Testing

@Test func bootfsRoundTrips() throws {
  let image = try Bootfs.image([("bin/m2", [1, 2, 3]), ("lib/x.so", [UInt8](repeating: 7, count: 5000))])
  #expect(image.u32(0) == Bootfs.magic)
  // Two entries: 12 + "bin/m2\0" (7) -> 20; 12 + "lib/x.so\0" (9) -> 24.
  #expect(image.u32(4) == 44)
  #expect(image.count == 4096 + 4096 + 8192)  // header page, then each file page aligned
  #expect(image.u32(16 + 8) == 4096)  // first file's offset
  #expect(Array(image[4096..<4099]) == [1, 2, 3])
  #expect(Bootfs.names(image) == ["bin/m2", "lib/x.so"])
  #expect(Bootfs.names([0, 1, 2]) == [])
}

@Test func bootfsKeepsOneCopyOfTheSameContents() throws {
  let program = [UInt8](repeating: 9, count: 5000)
  let image = try Bootfs.image([("bin/ls", program), ("etc/x", [1]), ("bin/cat", program)])
  #expect(image.count == 4096 + 8192 + 4096)  // the program once, then etc/x
  // Each entry's offset: ls at 4096, x after the program, cat at ls's.
  let first = 16, second = first + 20, third = second + 20
  #expect(image.u32(first + 8) == 4096 && image.u32(second + 8) == 4096 + 8192 && image.u32(third + 8) == 4096)
  #expect(image.u32(third + 4) == 5000)
  #expect(Bootfs.names(image) == ["bin/ls", "etc/x", "bin/cat"])
}

@Test func bootfsRefusesBadNames() {
  #expect(throws: FormatError.self) { try Bootfs.image([("/abs", [])]) }
  #expect(throws: FormatError.self) { try Bootfs.image([("a", []), ("a", [])]) }
  #expect(throws: FormatError.self) { try Bootfs.image([(String(repeating: "n", count: 256), [])]) }
}

@Test func baseRelocationBlocksArePaddedPerPage() {
  // Two offsets in page 0 and one in page 1: the second block is padded
  // with an ABSOLUTE entry to stay 32-bit aligned.
  let blocks = baseRelocations([0x10, 0x18, 0x1008])
  #expect(blocks.count == (8 + 4) + (8 + 4))
  #expect(blocks.u32(0) == 0 && blocks.u32(4) == 12)
  #expect(blocks.u16(8) == 0xA010 && blocks.u16(10) == 0xA018)
  #expect(blocks.u32(12) == 0x1000 && blocks.u32(16) == 12)
  #expect(blocks.u16(20) == 0xA008 && blocks.u16(22) == 0)
}

@Test func elfToEfiRefusesWhatItCantConvert() {
  #expect(throws: FormatError("not a little-endian ELF64 file")) { try elfToEfi([UInt8](repeating: 0, count: 64)) }
  var exec = [UInt8](repeating: 0, count: 64)
  exec.replaceSubrange(0..<6, with: [0x7F, 0x45, 0x4C, 0x46, 2, 1])
  exec.put16(16, 2)  // ET_EXEC
  #expect(throws: FormatError("expected ET_DYN (link with -static -pie)")) { try elfToEfi(exec) }
}

@Test func ppmPixels() throws {
  let header = Array("P6\n# QEMU\n2 1\n255\n".utf8)
  let ppm = try PPM(header + [10, 20, 30, 40, 50, 60])
  #expect(ppm.width == 2 && ppm.height == 1)
  #expect(ppm.pixel(1, 0).map { [$0.r, $0.g, $0.b] } == [40, 50, 60])
  #expect(ppm.pixel(2, 0) == nil)
  #expect(throws: FormatError.self) { try PPM(Array("P5\n1 1\n255\n".utf8) + [0]) }
}
