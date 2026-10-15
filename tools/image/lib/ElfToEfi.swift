// SPDX-License-Identifier: BSD-3-Clause

// Converts a static-PIE ELF64 image into a PE32+ EFI application (croi's
// tools/elf2efi.py, in Swift). LLVM can't emit PE/COFF for every arch the
// loader targets (RISC-V has no COFF backend), so the loader is linked as
// an ELF static PIE and converted.
//
// Requirements on the input, all enforced here:
//   - ET_DYN, little-endian ELF64 for x86-64, AArch64 or RISC-V.
//   - Linked at address 0 with page-aligned PT_LOAD segments at or above
//     0x1000, leaving room for the PE headers (VA == RVA).
//   - The only dynamic relocations are R_*_RELATIVE. Each one becomes an
//     IMAGE_REL_BASED_DIR64 base relocation that firmware applies at load.

private let page = 0x1000
private let fileAlign = 0x200
private let peOffset = 0x40
private let coffHeaderSize = 20
private let optionalHeaderSize = 112
private let dataDirectories = 16
private let sectionHeaderSize = 40

private let ptLoad: UInt32 = 1, ptDynamic: UInt32 = 2
private let pfX: UInt32 = 1, pfW: UInt32 = 2
private let dtNull: Int64 = 0, dtRela: Int64 = 7, dtRelasz: Int64 = 8, dtRelaent: Int64 = 9

private let relBasedAbsolute: UInt16 = 0
private let relBasedDir64: UInt16 = 10
private let directoryBaseReloc = 5

private let scnCntCode: UInt32 = 0x0000_0020
private let scnCntInitializedData: UInt32 = 0x0000_0040
private let scnMemDiscardable: UInt32 = 0x0200_0000
private let scnMemExecute: UInt32 = 0x2000_0000
private let scnMemRead: UInt32 = 0x4000_0000
private let scnMemWrite: UInt32 = 0x8000_0000

/// e_machine -> (PE machine, R_*_RELATIVE)
private func machine(_ eMachine: UInt16) -> (pe: UInt16, relative: UInt32)? {
  switch eMachine {
  case 62: (0x8664, 8)  // x86-64
  case 183: (0xAA64, 1027)  // AArch64
  case 243: (0x5064, 3)  // RISC-V (RV64)
  default: nil
  }
}

private struct ProgramHeader {
  var type: UInt32, flags: UInt32, offset: Int, vaddr: Int, filesz: Int, memsz: Int
}

private struct Section {
  var name: String
  var rva: Int
  var virtualSize: Int
  var data: [UInt8]
  var characteristics: UInt32
  var rawOffset = 0
}

/// The PE32+ EFI application for `elf`.
public func elfToEfi(_ elf: [UInt8]) throws(FormatError) -> [UInt8] {
  try elf.checked(0, 64)
  guard elf[0] == 0x7F, elf[1] == 0x45, elf[2] == 0x4C, elf[3] == 0x46, elf[4] == 2, elf[5] == 1 else {
    throw FormatError("not a little-endian ELF64 file")
  }
  guard elf.u16(16) == 3 else { throw FormatError("expected ET_DYN (link with -static -pie)") }
  let eMachine = elf.u16(18)
  guard let (peMachine, rRelative) = machine(eMachine) else { throw FormatError("unsupported e_machine \(eMachine)") }
  let entry = elf.u64(24)
  let phoff = Int(elf.u64(32)), phentsize = Int(elf.u16(54)), phnum = Int(elf.u16(56))
  var phdrs: [ProgramHeader] = []
  for i in 0..<phnum {
    let at = phoff + i * phentsize
    try elf.checked(at, 56)
    phdrs.append(ProgramHeader(type: elf.u32(at), flags: elf.u32(at + 4), offset: Int(elf.u64(at + 8)),
                               vaddr: Int(elf.u64(at + 16)), filesz: Int(elf.u64(at + 32)), memsz: Int(elf.u64(at + 40))))
  }
  let loads = phdrs.filter { $0.type == ptLoad }.sorted { $0.vaddr < $1.vaddr }
  guard !loads.isEmpty else { throw FormatError("no PT_LOAD segments") }

  var image = try buildImage(elf, loads)
  let relocs = baseRelocations(try applyRelocations(&image, phdrs, rRelative))
  var sections = try segmentSections(image, loads)

  var imageSize = image.count
  var hasRelocs = false
  if !relocs.isEmpty {
    sections.append(Section(name: ".reloc", rva: imageSize, virtualSize: relocs.count,
                            data: relocs + [UInt8](repeating: 0, count: align(relocs.count, fileAlign) - relocs.count),
                            characteristics: scnCntInitializedData | scnMemDiscardable | scnMemRead))
    imageSize += align(relocs.count, page)
    hasRelocs = true
  }
  return try writePE(machine: peMachine, entry: entry, imageSize: imageSize, sections: sections, hasRelocs: hasRelocs)
}

/// The PT_LOAD segments laid out in memory order, exactly as firmware will.
private func buildImage(_ elf: [UInt8], _ loads: [ProgramHeader]) throws(FormatError) -> [UInt8] {
  var end = 0
  for p in loads {
    guard p.vaddr % page == 0, p.vaddr >= page else {
      throw FormatError("PT_LOAD at 0x\(String(p.vaddr, radix: 16)) is not page aligned above the headers")
    }
    guard p.vaddr >= end else { throw FormatError("PT_LOAD at 0x\(String(p.vaddr, radix: 16)) overlaps the previous segment") }
    end = p.vaddr + p.memsz
  }
  var image = [UInt8](repeating: 0, count: align(end, page))
  for p in loads where p.filesz > 0 {
    try elf.checked(p.offset, p.filesz)
    image.replaceSubrange(p.vaddr..<p.vaddr + p.filesz, with: elf[p.offset..<p.offset + p.filesz])
  }
  return image
}

/// Resolves RELATIVE relocations for link base 0; returns their offsets.
private func applyRelocations(_ image: inout [UInt8], _ phdrs: [ProgramHeader], _ rRelative: UInt32) throws(FormatError) -> [Int] {
  guard let dynamic = phdrs.first(where: { $0.type == ptDynamic }) else { return [] }
  var tags: [Int64: UInt64] = [:]
  var at = dynamic.vaddr
  while true {
    try image.checked(at, 16)
    let tag = Int64(bitPattern: image.u64(at))
    if tag == dtNull { break }
    tags[tag] = image.u64(at + 8)
    at += 16
  }
  guard let rela = tags[dtRela].map(Int.init) else { return [] }
  let size = Int(tags[dtRelasz] ?? 0), entsize = Int(tags[dtRelaent] ?? 24)
  var offsets: [Int] = []
  for at in stride(from: rela, to: rela + size, by: entsize) {
    try image.checked(at, 24)
    let rOffset = Int(image.u64(at)), rType = UInt32(truncatingIfNeeded: image.u64(at + 8)), rAddend = image.u64(at + 16)
    if rType == 0 { continue }
    guard rType == rRelative else {
      throw FormatError("unsupported dynamic relocation type \(rType) at 0x\(String(rOffset, radix: 16))")
    }
    try image.checked(rOffset, 8)
    image.put64(rOffset, rAddend)
    offsets.append(rOffset)
  }
  return offsets.sorted()
}

/// Offsets as PE base relocation blocks, one per 4 KiB page.
func baseRelocations(_ offsets: [Int]) -> [UInt8] {
  var out: [UInt8] = []
  var i = 0
  while i < offsets.count {
    let pageStart = offsets[i] & ~(page - 1)
    var entries: [UInt16] = []
    while i < offsets.count, offsets[i] & ~(page - 1) == pageStart {
      entries.append(relBasedDir64 << 12 | UInt16(offsets[i] - pageStart))
      i += 1
    }
    if entries.count % 2 == 1 { entries.append(relBasedAbsolute << 12) }  // keep blocks 32-bit aligned
    out.append32(UInt32(pageStart))
    out.append32(UInt32(8 + 2 * entries.count))
    for e in entries { out.append16(e) }
  }
  return out
}

private func segmentSections(_ image: [UInt8], _ loads: [ProgramHeader]) throws(FormatError) -> [Section] {
  var sections: [Section] = []
  for p in loads {
    let name: String, characteristics: UInt32
    if p.flags & pfX != 0 {
      guard p.flags & pfW == 0 else {
        throw FormatError("PT_LOAD at 0x\(String(p.vaddr, radix: 16)) is both writable and executable")
      }
      (name, characteristics) = (".text", scnCntCode | scnMemExecute | scnMemRead)
    } else if p.flags & pfW != 0 {
      (name, characteristics) = (".data", scnCntInitializedData | scnMemRead | scnMemWrite)
    } else {
      (name, characteristics) = (".rdata", scnCntInitializedData | scnMemRead)
    }
    // As Python's slice: the raw data may run past the image's end, and
    // then stops there.
    let raw = p.filesz > 0 ? Array(image[p.vaddr..<min(image.count, p.vaddr + align(p.filesz, fileAlign))]) : []
    sections.append(Section(name: name, rva: p.vaddr, virtualSize: p.memsz, data: raw, characteristics: characteristics))
  }
  return sections
}

private func writePE(machine: UInt16, entry: UInt64, imageSize: Int, sections: [Section], hasRelocs: Bool) throws(FormatError) -> [UInt8] {
  var sections = sections
  let headersSize = align(peOffset + 4 + coffHeaderSize + optionalHeaderSize + 8 * dataDirectories
                          + sectionHeaderSize * sections.count, fileAlign)
  guard headersSize <= sections[0].rva else { throw FormatError("PE headers do not fit below the first segment") }

  var rawOffset = headersSize
  for i in sections.indices {
    sections[i].rawOffset = sections[i].data.isEmpty ? 0 : rawOffset
    rawOffset += sections[i].data.count
  }
  func total(_ flag: UInt32) -> Int {
    sections.filter { $0.characteristics & flag != 0 }.reduce(0) { $0 + align($1.virtualSize, fileAlign) }
  }
  let baseOfCode: Int = sections.first(where: { $0.characteristics & scnCntCode != 0 })?.rva ?? 0

  var out = [UInt8](repeating: 0, count: headersSize)
  out[0] = 0x4D  // "MZ"
  out[1] = 0x5A
  out.put32(0x3C, UInt32(peOffset))
  out.replaceSubrange(peOffset..<peOffset + 4, with: [0x50, 0x45, 0, 0])  // "PE\0\0"
  var at = peOffset + 4
  // COFF header.
  out.put16(at, machine)
  out.put16(at + 2, UInt16(sections.count))
  out.put16(at + 16, UInt16(optionalHeaderSize + 8 * dataDirectories))
  out.put16(at + 18, 0x0002 | 0x0020)  // executable image, large address aware
  at += coffHeaderSize
  // PE32+ optional header.
  out.put16(at, 0x20B)
  out.put32(at + 4, UInt32(total(scnCntCode)))  // SizeOfCode
  out.put32(at + 8, UInt32(total(scnCntInitializedData)))  // SizeOfInitializedData
  out.put32(at + 16, UInt32(truncatingIfNeeded: entry))  // AddressOfEntryPoint
  out.put32(at + 20, UInt32(baseOfCode))
  out.put64(at + 24, 0)  // ImageBase
  out.put32(at + 32, UInt32(page))  // SectionAlignment
  out.put32(at + 36, UInt32(fileAlign))  // FileAlignment
  out.put32(at + 56, UInt32(imageSize))
  out.put32(at + 60, UInt32(headersSize))
  out.put16(at + 68, 10)  // IMAGE_SUBSYSTEM_EFI_APPLICATION
  out.put16(at + 70, 0x0020 | 0x0040 | 0x0100)  // high-entropy VA, dynamic base, NX compatible
  out.put64(at + 72, 0x10000)  // stack reserve
  out.put64(at + 80, 0x10000)  // stack commit
  out.put32(at + 108, UInt32(dataDirectories))
  at += optionalHeaderSize
  if hasRelocs, let reloc = sections.last {
    out.put32(at + 8 * directoryBaseReloc, UInt32(reloc.rva))
    out.put32(at + 8 * directoryBaseReloc + 4, UInt32(reloc.virtualSize))
  }
  at += 8 * dataDirectories
  for s in sections {
    for (i, c) in s.name.utf8.prefix(8).enumerated() { out[at + i] = c }
    out.put32(at + 8, UInt32(s.virtualSize))
    out.put32(at + 12, UInt32(s.rva))
    out.put32(at + 16, UInt32(s.data.count))
    out.put32(at + 20, UInt32(s.rawOffset))
    out.put32(at + 36, s.characteristics)
    at += sectionHeaderSize
  }
  for s in sections { out += s.data }
  return out
}
