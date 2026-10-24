// SPDX-License-Identifier: BSD-3-Clause

// Names for code addresses (D102, vx trace profile): an ELF's functions
// from its .symtab, and a Symbolizer that finds the ELF an address is in
// the way the node's processes map them: the kernel by its offset from its
// image's start, a program by its offset in the VMO a mapping is of (all
// of bootfs, one of its files, or a pushed build's), read here from the
// same bootfs image. The build keeps its ELFs unstripped, so bootfs holds
// their symbols.

/// An ELF64's loaded segments and functions.
public struct ElfSymbols: Sendable {
  public struct Segment: Sendable {
    public var offset: UInt64
    public var vaddr: UInt64
    public var filesz: UInt64
    public var memsz: UInt64
  }

  public var segments: [Segment] = []
  /// Functions (and assembly's untyped symbols) by address.
  var functions: [(address: UInt64, size: UInt64, name: String)] = []

  public init(_ elf: [UInt8]) throws(FormatError) {
    try elf.checked(0, 64)
    guard elf[0] == 0x7F, elf[1] == 0x45, elf[2] == 0x4C, elf[3] == 0x46, elf[4] == 2, elf[5] == 1 else {
      throw FormatError("not a little-endian ELF64")
    }
    let phoff = Int(elf.u64(0x20)), phentsize = Int(elf.u16(0x36)), phnum = Int(elf.u16(0x38))
    for i in 0..<phnum {
      let at = phoff + i * phentsize
      try elf.checked(at, 56)
      guard elf.u32(at) == 1 else { continue }  // PT_LOAD
      segments.append(Segment(offset: elf.u64(at + 8), vaddr: elf.u64(at + 16), filesz: elf.u64(at + 32),
                              memsz: elf.u64(at + 40)))
    }
    let shoff = Int(elf.u64(0x28)), shentsize = Int(elf.u16(0x3A)), shnum = Int(elf.u16(0x3C))
    guard shoff > 0, shentsize >= 64 else { return }
    for i in 0..<shnum {
      let at = shoff + i * shentsize
      try elf.checked(at, 64)
      guard elf.u32(at + 4) == 2 else { continue }  // SHT_SYMTAB
      let offset = Int(elf.u64(at + 0x18)), size = Int(elf.u64(at + 0x20)), entsize = max(24, Int(elf.u64(at + 0x38)))
      let link = shoff + Int(elf.u32(at + 0x28)) * shentsize
      try elf.checked(link, 64)
      let strings = Int(elf.u64(link + 0x18)), stringsSize = Int(elf.u64(link + 0x20))
      try elf.checked(offset, size)
      try elf.checked(strings, stringsSize)
      for s in stride(from: offset, to: offset + size - 23, by: entsize) {
        let info = elf[s + 4], section = elf.u16(s + 6), value = elf.u64(s + 8)
        let type = info & 15
        guard type == 2 || type == 0, section != 0, value != 0 else { continue }  // STT_FUNC, STT_NOTYPE
        let nameAt = strings + Int(elf.u32(s))
        guard nameAt < strings + stringsSize else { continue }
        let name = elf[nameAt..<strings + stringsSize].prefix { $0 != 0 }
        guard !name.isEmpty else { continue }
        // AArch64's and RISC-V's mapping symbols ($x, $d, $x.<n>): where
        // code or data starts, not names.
        guard !(name.first == 0x24 && name.count >= 2 && (name.count == 2 || name[name.startIndex + 2] == 0x2E)) else { continue }
        functions.append((value, elf.u64(s + 16), String(decoding: name, as: UTF8.self)))
      }
    }
    // A function before an untyped label at the same address.
    functions.sort { $0.address != $1.address ? $0.address < $1.address : $0.size > $1.size }
  }

  /// The lowest address a segment loads at: where the image starts.
  public var base: UInt64 { segments.map(\.vaddr).min() ?? 0 }

  /// The address the byte at `offset` in the file loads at.
  public func address(ofFileOffset offset: UInt64) -> UInt64? {
    segments.first { offset >= $0.offset && offset - $0.offset < $0.filesz }.map { $0.vaddr + (offset - $0.offset) }
  }

  /// The function holding `address`, and how far into it; nil outside every
  /// sized one (an untyped label holds what follows it up to the next).
  public func function(at address: UInt64) -> (name: String, offset: UInt64)? {
    var low = 0, high = functions.count
    while low < high {
      let mid = (low + high) / 2
      if functions[mid].address <= address { low = mid + 1 } else { high = mid }
    }
    // The last at or before it; a sized one that ends before it may sit
    // under an earlier one that holds it (nested labels), so look back a little.
    var i = low - 1
    while i >= 0 && i >= low - 8 {
      let f = functions[i]
      if f.size == 0 || address - f.address < f.size { return (f.name, address - f.address) }
      i -= 1
    }
    return nil
  }
}

/// Names a node's code addresses from its kernel ELF and its bootfs image
/// (and pushed builds, by name).
public final class Symbolizer {
  let kernel: ElfSymbols?
  let bootfs: [UInt8]
  let files: [(name: String, offset: Int, size: Int)]
  let pushed: [String: ElfSymbols]
  var parsed: [Int: ElfSymbols?] = [:]

  /// `pushed`: a pushed build's ELF by its program's name (`push:NAME`).
  public init(kernel: [UInt8]?, bootfs: [UInt8]?, pushed: [String: [UInt8]] = [:]) {
    self.kernel = kernel.flatMap { try? ElfSymbols($0) }
    self.bootfs = bootfs ?? []
    files = Bootfs.files(self.bootfs)
    self.pushed = pushed.compactMapValues { try? ElfSymbols($0) }
  }

  /// The function at `offset` in `image`, and the image's name: `kernel`
  /// (an offset from the kernel's start), `bootfs` (an offset in the whole
  /// image), a bootfs file's path (an offset in that file; a name cut to 31
  /// bytes, as the kernel keeps them, stands for the file it starts), or
  /// `push:NAME`. A return address is looked up a byte back, inside its
  /// call. Nil if the image or the function isn't known.
  public func symbol(image: String, offset: UInt64, returnAddress: Bool = false) -> (function: String, image: String)? {
    let at = returnAddress && offset > 0 ? offset - 1 : offset
    if image == "kernel" {
      guard let k = kernel, let f = k.function(at: k.base &+ at) else { return nil }
      return (f.name, "kernel")
    }
    if image.hasPrefix("push:") {
      let name = String(image.dropFirst(5))
      guard let elf = pushed[name], let v = elf.address(ofFileOffset: at), let f = elf.function(at: v) else {
        return nil
      }
      return (f.name, image)
    }
    let file: (name: String, offset: Int, size: Int)?
    let inFile: UInt64
    if image == "bootfs" {
      file = files.first { Int(at) >= $0.offset && Int(at) < $0.offset + $0.size }
      inFile = file.map { at - UInt64($0.offset) } ?? 0
    } else {
      file = files.first { $0.name == image } ?? (image.utf8.count == 31 ? files.first { $0.name.hasPrefix(image) } : nil)
      inFile = at
    }
    guard let file, let elf = elf(file), let v = elf.address(ofFileOffset: inFile), let f = elf.function(at: v) else {
      return nil
    }
    return (f.name, file.name)
  }

  func elf(_ file: (name: String, offset: Int, size: Int)) -> ElfSymbols? {
    if let known = parsed[file.offset] { return known }
    let made = file.offset + file.size <= bootfs.count
      ? try? ElfSymbols(Array(bootfs[file.offset..<file.offset + file.size])) : nil
    parsed[file.offset] = .some(made)  // a file that isn't an ELF, too
    return made
  }
}
