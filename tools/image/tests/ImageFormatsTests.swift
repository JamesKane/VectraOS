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

/// A little-endian ELF64 with one PT_LOAD (file offset 0x1000 at
/// `vaddr`) and a .symtab of `symbols` (name, value, size, type).
func elf(vaddr: UInt64, symbols: [(String, UInt64, UInt64, UInt8)]) -> [UInt8] {
  func le(_ v: UInt64, _ n: Int) -> [UInt8] { (0..<n).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
  var strtab: [UInt8] = [0]
  var symtab = [UInt8](repeating: 0, count: 24)
  for (name, value, size, type) in symbols {
    let at = strtab.count
    strtab += Array(name.utf8) + [0]
    symtab += le(UInt64(at), 4) + [type, 0] + le(1, 2) + le(value, 8) + le(size, 8)
  }
  let symAt = 0x2000, strAt = symAt + symtab.count, shAt = (strAt + strtab.count + 7) & ~7
  var f = [UInt8](repeating: 0, count: 64)
  f[0...5] = [0x7F, 0x45, 0x4C, 0x46, 2, 1]
  f.replaceSubrange(0x20..<0x28, with: le(64, 8))  // e_phoff
  f.replaceSubrange(0x28..<0x30, with: le(UInt64(shAt), 8))
  f.replaceSubrange(0x36..<0x3A, with: le(56, 2) + le(1, 2))
  f.replaceSubrange(0x3A..<0x3E, with: le(64, 2) + le(3, 2))
  f += le(1, 4) + le(5, 4) + le(0x1000, 8) + le(vaddr, 8) + le(vaddr, 8) + le(0x1000, 8) + le(0x1000, 8) + le(0x1000, 8)
  f += [UInt8](repeating: 0, count: symAt - f.count) + symtab + strtab
  f += [UInt8](repeating: 0, count: shAt - f.count)
  f += [UInt8](repeating: 0, count: 64)  // the null section
  f += le(0, 4) + le(2, 4) + le(0, 8) + le(0, 8) + le(UInt64(symAt), 8) + le(UInt64(symtab.count), 8)
    + le(2, 4) + le(0, 4) + le(8, 8) + le(24, 8)
  f += le(0, 4) + le(3, 4) + le(0, 8) + le(0, 8) + le(UInt64(strAt), 8) + le(UInt64(strtab.count), 8)
    + le(0, 4) + le(0, 4) + le(1, 8) + le(0, 8)
  return f
}

/// An ELF's functions by address: sized ones hold what is inside them, an
/// untyped label what follows it; a file offset maps through its segment.
@Test func elfSymbolsNameAddresses() throws {
  let e = try ElfSymbols(elf(vaddr: 0x40_0000, symbols: [("main", 0x40_0010, 0x20, 2), ("helper", 0x40_0100, 0x10, 2),
                                                           ("entry", 0x40_0000, 0, 0)]))
  #expect(e.base == 0x40_0000)
  #expect(e.address(ofFileOffset: 0x1010) == 0x40_0010)
  #expect(e.address(ofFileOffset: 0x10) == nil)
  #expect(e.function(at: 0x40_0018).map { "\($0.name)+\($0.offset)" } == "main+8")
  #expect(e.function(at: 0x40_0104).map { "\($0.name)+\($0.offset)" } == "helper+4")
  #expect(e.function(at: 0x40_0004).map { $0.name } == "entry")
  #expect(e.function(at: 0x40_0050).map { $0.name } == "entry")  // past main: the label before it
  #expect(e.function(at: 0x3F_0000) == nil)
}

/// A Symbolizer finds a program in bootfs by the offset in the image, or
/// in one of its files, and the kernel by its offset from its start; a
/// return address is looked up a byte back.
@Test func symbolizerFindsTheImage() throws {
  let program = elf(vaddr: 0x1000, symbols: [("run", 0x1000, 0x40, 2), ("next", 0x1040, 0x40, 2)])
  let image = try Bootfs.image([("etc/x", Array("x".utf8)), ("bin/net", program)])
  let at = try #require(Bootfs.files(image).first { $0.name == "bin/net" })
  #expect(at.size == program.count && at.offset % 4096 == 0)
  let kernel = elf(vaddr: 0xFFFF_FFFF_8000_0000, symbols: [("kernel_main", 0xFFFF_FFFF_8000_0100, 0x100, 2)])
  let s = Symbolizer(kernel: kernel, bootfs: image, pushed: ["plumber": program])
  #expect(s.symbol(image: "bootfs", offset: UInt64(at.offset) + 0x1010).map { "\($0.function) \($0.image)" } == "run bin/net")
  #expect(s.symbol(image: "bin/net", offset: 0x1048).map { $0.function } == "next")
  #expect(s.symbol(image: "bin/net", offset: 0x1040, returnAddress: true).map { $0.function } == "run")
  #expect(s.symbol(image: "kernel", offset: 0x180).map { "\($0.function) \($0.image)" } == "kernel_main kernel")
  #expect(s.symbol(image: "push:plumber", offset: 0x1000).map { "\($0.function) \($0.image)" } == "run push:plumber")
  #expect(s.symbol(image: "push:other", offset: 0x1000) == nil)
  #expect(s.symbol(image: "etc/x", offset: 0) == nil)
}
