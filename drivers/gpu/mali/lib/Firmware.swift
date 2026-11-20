// SPDX-License-Identifier: BSD-3-Clause

// The CSF firmware image (chinese-wall's panthor 05 §5.2): a 20-byte header
// and entries, of which the memory sections and the build information are
// read. `FirmwareImage.parse` applies every rule of §5.2.1 and §5.2.3 in
// their order and rejects the whole image at the first that fails, naming
// it. It reads and loads nothing: loading is the driver's.

/// Why an image was refused: the rule, by its number in panthor 05.
public enum FirmwareError: Error, Equatable, Sendable, CustomStringConvertible {
  case tooShort(Int)  // 5.2.1 rule 1
  case badMagic(UInt32)  // 5.2.1 rule 2
  case badMajorVersion(UInt8)  // 5.2.1 rule 3
  case imageSizeBeyondFile(imageSize: UInt32, fileSize: Int)  // 5.2.1 rule 4
  case entryPastImage(offset: Int)  // 5.2.1 rule 5, 5.2.2
  case entrySize(offset: Int, size: Int)  // 5.2.2: not a multiple of 4, or under 4
  case unknownRequiredEntry(offset: Int, type: UInt8)  // 5.2.2: unknown, not OPTIONAL
  case sectionTooShort(offset: Int)  // 5.2.3 rule 1
  case dataRangeInverted(offset: Int)  // rule 2
  case vaRangeInverted(offset: Int)  // rule 3
  case dataPastFile(offset: Int)  // rule 4
  case unalignedVA(offset: Int)  // rule 5
  case reservedFlags(offset: Int, flags: UInt32)  // rule 6
  case sharedMissing(offset: Int)  // rule 8
  case dataLargerThanSection(offset: Int)  // rule 9
  case noSharedSection  // 5.2.3 after the entries: none at 0x04000000
  case manySharedSections  // 5.2.3 after the entries: more than one

  public var description: String {
    switch self {
    case .tooShort(let n): return "5.2.1 rule 1: \(n) bytes, under the 20-byte header"
    case .badMagic(let m): return "5.2.1 rule 2: magic 0x" + hexDigits(UInt64(m)) + " is not 0xc3f13a6e"
    case .badMajorVersion(let v): return "5.2.1 rule 3: header major version \(v), not 0"
    case .imageSizeBeyondFile(let s, let f): return "5.2.1 rule 4: image size \(s) is past the file's \(f) bytes"
    case .entryPastImage(let o): return "5.2.1 rule 5: the entry at \(o) runs past the image size"
    case .entrySize(let o, let s): return "5.2.2: the entry at \(o) has size \(s), not a multiple of 4 and at least 4"
    case .unknownRequiredEntry(let o, let t): return "5.2.2: the entry at \(o) is of unknown type \(t) and not optional"
    case .sectionTooShort(let o): return "5.2.3 rule 1: the section at \(o) has under 20 bytes after its header"
    case .dataRangeInverted(let o): return "5.2.3 rule 2: the section at \(o) has DATA_END before DATA_START"
    case .vaRangeInverted(let o): return "5.2.3 rule 3: the section at \(o) has VA_END before VA_START"
    case .dataPastFile(let o): return "5.2.3 rule 4: the section at \(o) has its data past the end of the file"
    case .unalignedVA(let o): return "5.2.3 rule 5: the section at \(o) has a VA not aligned to 4 KiB"
    case .reservedFlags(let o, let f): return "5.2.3 rule 6: the section at \(o) has reserved flags 0x" + hexDigits(UInt64(f))
    case .sharedMissing(let o): return "5.2.3 rule 8: the section at \(o) is at the interface's address and not SHARED"
    case .dataLargerThanSection(let o): return "5.2.3 rule 9: the section at \(o) has more data than address range"
    case .noSharedSection: return "5.2.3: no section at 0x04000000"
    case .manySharedSections: return "5.2.3: more than one section at 0x04000000"
    }
  }
}

func hexDigits(_ v: UInt64) -> String {
  let d = Array("0123456789abcdef".utf8)
  var out: [UInt8] = []
  var started = false
  for i in stride(from: 15, through: 0, by: -1) {
    let nibble = Int(v >> UInt64(4 * i) & 0xF)
    if nibble != 0 { started = true }
    if started || i == 0 { out.append(d[nibble]) }
  }
  return String(decoding: out, as: UTF8.self)
}

/// A section's cache mode (FLAGS[4:3]).
public enum SectionCacheMode: UInt32, Sendable {
  case none = 0
  case cached = 1
  case uncachedCoherent = 2
  case cachedCoherent = 3
}

/// A memory section of the image, accepted: its MCU address range, where its
/// initial contents are in the file, and its flags.
public struct FirmwareSection: Equatable, Sendable {
  public var flags: UInt32
  /// The MCU virtual addresses, [vaStart, vaEnd), 4 KiB aligned.
  public var vaStart: UInt32
  public var vaEnd: UInt32
  /// The file offsets of the initial contents, [dataStart, dataEnd).
  public var dataStart: Int
  public var dataEnd: Int
  /// The name's bytes, up to the first NUL.
  public var name: [UInt8]

  public var readable: Bool { flags & 1 != 0 }
  public var writable: Bool { flags & 2 != 0 }
  public var executable: Bool { flags & 4 != 0 }
  public var cacheMode: SectionCacheMode { SectionCacheMode(rawValue: flags >> 3 & 3)! }
  public var shared: Bool { flags & Self.sharedFlag != 0 }
  /// Zero-fill what the initial contents don't cover.
  public var zero: Bool { flags & Self.zeroFlag != 0 }

  public var size: Int { Int(vaEnd - vaStart) }
  public var dataSize: Int { dataEnd - dataStart }

  /// The page-table mapping (05 §5.3.3): read-only unless WR, no-execute
  /// unless EX; cached mode 1 is AttrIndx 1, inner shareable; the others
  /// (the coherent modes too: this driver maps them non-cacheable on every
  /// system) are AttrIndx 0, outer shareable.
  public var cacheable: Bool { cacheMode == .cached }
  public var attrIndex: Int { cacheable ? 1 : 0 }

  static let sharedFlag: UInt32 = 1 << 30
  static let zeroFlag: UInt32 = 1 << 31
  static let protectedFlag: UInt32 = 1 << 5
  static let allowedFlags: UInt32 = 0x3F | sharedFlag | zeroFlag
}

/// A parsed image.
public struct FirmwareImage: Equatable, Sendable {
  /// Under /lib/firmware: the image for GPU architecture 12.8.
  public static let path = "/lib/firmware/arm/mali/arch12.8/mali_csffw.bin"
  public static let missing = "no firmware"
  /// Where the firmware's shared interface section sits (05 §5.4.1).
  public static let sharedAddress: UInt32 = 0x0400_0000

  public var headerMinor: UInt8
  /// The header's firmware version hash, informational.
  public var versionHash: UInt32
  /// The sections to load, in the file's order; protected and empty ones are left out.
  public var sections: [FirmwareSection]
  /// How many protected-mode sections were skipped.
  public var protectedSkipped: Int
  /// How many empty sections were skipped.
  public var emptySkipped: Int
  /// The firmware's source revision, from its build-info entry, if it has a valid one.
  public var gitSha: String?
  /// The file's size.
  public var fileSize: Int

  /// The shared interface's section.
  public var shared: FirmwareSection {
    for s in sections where s.vaStart == Self.sharedAddress { return s }
    preconditionFailure("parse leaves one")
  }

  /// Reads an image, or says which rule it breaks.
  public static func parse(_ file: [UInt8]) throws(FirmwareError) -> FirmwareImage {
    guard file.count >= 20 else { throw .tooShort(file.count) }
    let magic = word(file, 0)
    guard magic == 0xC3F1_3A6E else { throw .badMagic(magic) }
    guard file[5] == 0 else { throw .badMajorVersion(file[5]) }
    let imageSize = word(file, 0x10)
    guard Int(imageSize) <= file.count else { throw .imageSizeBeyondFile(imageSize: imageSize, fileSize: file.count) }
    var image = FirmwareImage(
      headerMinor: file[4], versionHash: word(file, 8), sections: [], protectedSkipped: 0, emptySkipped: 0,
      gitSha: nil, fileSize: file.count)
    let end = Int(imageSize)
    var offset = 0x14
    while offset < end {
      guard offset + 4 <= end else { throw .entryPastImage(offset: offset) }
      let header = word(file, offset)
      let type = UInt8(header & 0xFF)
      let size = Int(header >> 8 & 0xFF)
      guard size >= 4, size % 4 == 0 else { throw .entrySize(offset: offset, size: size) }
      guard offset + size <= end else { throw .entryPastImage(offset: offset) }
      let optional = header >> 31 != 0
      switch type {
      case 0:
        try image.addSection(file, at: offset, size: size)
      case 1, 2, 3, 4: break
      case 6: image.addBuildInfo(file, at: offset, size: size)
      default:
        guard optional else { throw .unknownRequiredEntry(offset: offset, type: type) }
      }
      offset += size
    }
    var found = 0
    for s in image.sections where s.vaStart == sharedAddress { found += 1 }
    guard found != 0 else { throw .noSharedSection }
    guard found == 1 else { throw .manySharedSections }
    return image
  }

  mutating func addSection(_ file: [UInt8], at o: Int, size: Int) throws(FirmwareError) {
    guard size - 4 >= 20 else { throw .sectionTooShort(offset: o) }
    let flags = Self.word(file, o + 4)
    let vaStart = Self.word(file, o + 8), vaEnd = Self.word(file, o + 12)
    let dataStart = Int(Self.word(file, o + 16)), dataEnd = Int(Self.word(file, o + 20))
    guard dataEnd >= dataStart else { throw .dataRangeInverted(offset: o) }
    guard vaEnd >= vaStart else { throw .vaRangeInverted(offset: o) }
    guard dataEnd <= file.count else { throw .dataPastFile(offset: o) }
    guard vaStart & 0xFFF == 0, vaEnd & 0xFFF == 0 else { throw .unalignedVA(offset: o) }
    guard flags & ~FirmwareSection.allowedFlags == 0 else { throw .reservedFlags(offset: o, flags: flags) }
    if flags & FirmwareSection.protectedFlag != 0 {
      protectedSkipped += 1
      return
    }
    guard vaStart != Self.sharedAddress || flags & FirmwareSection.sharedFlag != 0 else { throw .sharedMissing(offset: o) }
    guard dataEnd - dataStart <= Int(vaEnd - vaStart) else { throw .dataLargerThanSection(offset: o) }
    if vaEnd == vaStart {
      emptySkipped += 1
      return
    }
    var name: [UInt8] = []
    for i in (o + 24)..<(o + size) {
      if file[i] == 0 { break }
      name.append(file[i])
    }
    sections.append(FirmwareSection(flags: flags, vaStart: vaStart, vaEnd: vaEnd, dataStart: dataStart, dataEnd: dataEnd, name: name))
  }

  /// 5.2.4: every failure leaves the revision unset and goes no further.
  mutating func addBuildInfo(_ file: [UInt8], at o: Int, size: Int) {
    guard gitSha == nil, size >= 12 else { return }
    let start = Int(Self.word(file, o + 4)), length = Int(Self.word(file, o + 8))
    guard length > 9, start + length <= file.count, file[start + length - 1] == 0 else { return }
    let prefix = Array("git_sha: ".utf8)
    for i in 0..<9 where file[start + i] != prefix[i] { return }
    var text: [UInt8] = []
    for i in (start + 9)..<(start + length - 1) { text.append(file[i]) }
    gitSha = String(decoding: text, as: UTF8.self)
  }

  static func word(_ b: [UInt8], _ o: Int) -> UInt32 {
    UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
  }

  /// What the image holds: its size, sections and source revision.
  public var summary: String {
    var line = "firmware \(fileSize) bytes, \(sections.count) sections"
    if let sha = gitSha { line += ", git " + sha }
    return line
  }

  /// The status line for a file's bytes before it is loaded: what was read,
  /// or why it was refused.
  public static func line(_ file: [UInt8]) -> String {
    guard !file.isEmpty else { return missing }
    do throws(FirmwareError) {
      return try parse(file).summary + ", not loaded"
    } catch {
      return "firmware \(file.count) bytes refused: \(error), not loaded"
    }
  }
}
