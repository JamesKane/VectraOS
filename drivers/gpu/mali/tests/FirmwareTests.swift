// SPDX-License-Identifier: BSD-3-Clause

// The CSF firmware image's parser: crafted images, one for each rule, and
// the real image where .cache/firmware has it.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Mali
import Testing

/// An image under construction: the header, then entries.
struct Image {
  var bytes: [UInt8] = []
  var imageSize: UInt32? = nil
  var magic: UInt32 = 0xC3F1_3A6E
  var major: UInt8 = 0
  /// Bytes after the entries, which payloads may point at.
  var tail: [UInt8] = []

  static func le(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)] }

  mutating func entry(type: UInt8, optional: Bool = false, size: Int? = nil, _ payload: [UInt8]) {
    let total = size ?? payload.count + 4
    bytes += Image.le(UInt32(type) | UInt32(total) << 8 | (optional ? 1 << 31 : 0))
    bytes += payload
  }

  /// A type 0 entry. Its name is padded to a multiple of 4.
  mutating func section(flags: UInt32, va: UInt32, vaEnd: UInt32, data: UInt32 = 0, dataEnd: UInt32 = 0, name: String = "") {
    var payload = Image.le(flags) + Image.le(va) + Image.le(vaEnd) + Image.le(data) + Image.le(dataEnd)
    payload += Array(name.utf8)
    while payload.count % 4 != 0 { payload.append(0) }
    entry(type: 0, payload)
  }

  /// The interface section every image needs: 32 bytes.
  mutating func shared(flags: UInt32 = 0x4000_0003) {
    section(flags: flags, va: 0x0400_0000, vaEnd: 0x0400_2000, name: "iface")
  }

  func file() -> [UInt8] {
    let size = imageSize ?? UInt32(20 + bytes.count)
    return Image.le(magic) + [3, major, 0, 0] + Image.le(0x1234_5678) + Image.le(0) + Image.le(size) + bytes + tail
  }

  func error() -> FirmwareError? {
    do throws(FirmwareError) {
      _ = try FirmwareImage.parse(file())
      return nil
    } catch { return error }
  }

  func parsed() throws -> FirmwareImage { try FirmwareImage.parse(file()) }
}

func rejected(_ image: Image, _ expected: FirmwareError) {
  #expect(image.error() == expected)
}

/// Where an entry added after `shared()` starts.
let afterShared = 20 + 32

@Test func aSmallImageParses() throws {
  var image = Image()
  image.section(flags: 0x0000_000F, va: 0x0000_0000, vaEnd: 0x0000_2000, data: 0, dataEnd: 0, name: "code")
  image.shared()
  let parsed = try image.parsed()
  #expect(parsed.sections.count == 2)
  #expect(parsed.headerMinor == 3 && parsed.versionHash == 0x1234_5678)
  let code = parsed.sections[0]
  #expect(code.readable && code.writable && code.executable && !code.shared && !code.zero)
  #expect(code.cacheMode == .cached && code.cacheable && code.attrIndex == 1)
  #expect(code.vaStart == 0 && code.vaEnd == 0x2000 && code.size == 0x2000 && code.name == Array("code".utf8))
  let shared = parsed.shared
  #expect(shared.vaStart == 0x0400_0000 && shared.shared && !shared.zero)
  #expect(shared.cacheMode == .none && !shared.cacheable && shared.attrIndex == 0)
  #expect(!shared.executable && shared.writable)
}

@Test func flagsDecode() throws {
  var image = Image()
  image.section(flags: 0x1 | 2 << 3 | 1 << 31, va: 0x1000, vaEnd: 0x2000)  // read-only, uncached-coherent, zero
  image.section(flags: 0x1 | 3 << 3 | 4, va: 0x2000, vaEnd: 0x3000)  // executable, cached-coherent
  image.section(flags: 0x1 | 1 << 3, va: 0x3000, vaEnd: 0x4000)
  image.shared()
  let s = try image.parsed().sections
  #expect(s[0].cacheMode == .uncachedCoherent && !s[0].writable && !s[0].executable && s[0].attrIndex == 0 && s[0].zero)
  #expect(s[1].cacheMode == .cachedCoherent && s[1].executable && !s[1].cacheable && s[1].attrIndex == 0)
  #expect(s[2].cacheMode == .cached && s[2].attrIndex == 1)
}

// 5.2.1

@Test func ruleHeader1TooShort() {
  #expect(throws: FirmwareError.tooShort(19)) { try FirmwareImage.parse([UInt8](repeating: 0, count: 19)) }
  #expect(throws: FirmwareError.tooShort(0)) { try FirmwareImage.parse([]) }
}

@Test func ruleHeader2Magic() {
  var image = Image()
  image.shared()
  image.magic = 0xC3F1_3A6F
  rejected(image, .badMagic(0xC3F1_3A6F))
}

@Test func ruleHeader3MajorVersion() {
  var image = Image()
  image.shared()
  image.major = 1
  rejected(image, .badMajorVersion(1))
}

@Test func ruleHeader4ImageSizeInTheFile() {
  var image = Image()
  image.shared()
  let count = image.file().count
  image.imageSize = UInt32(count + 1)
  rejected(image, .imageSizeBeyondFile(imageSize: UInt32(count + 1), fileSize: count))
}

@Test func ruleHeader5EntryPastImage() {
  var image = Image()
  image.shared()
  // An entry whose size runs past the image size, and one whose header does.
  var long = image
  long.entry(type: 1, size: 12, [0, 0, 0, 0])
  rejected(long, .entryPastImage(offset: afterShared))
  var cut = image
  cut.bytes += [1, 4]  // half a header, inside the image size
  rejected(cut, .entryPastImage(offset: afterShared))
}

@Test func bytesPastTheImageSizeAreIgnoredByEntries() throws {
  var image = Image()
  image.shared()
  image.tail = [0xFF, 0xFF, 0xFF, 0xFF]  // not an entry, past the image size
  #expect(try image.parsed().sections.count == 1)
}

// 5.2.2

@Test func ruleEntrySizeMultipleOfFour() {
  var image = Image()
  image.shared()
  image.entry(type: 1, size: 6, [0, 0])
  rejected(image, .entrySize(offset: afterShared, size: 6))
}

@Test func ruleEntrySizeAtLeastFour() {
  var image = Image()
  image.shared()
  image.entry(type: 1, size: 0, [0, 0, 0, 0])
  rejected(image, .entrySize(offset: afterShared, size: 0))
}

@Test func unknownEntriesSkipOnlyIfOptional() throws {
  var image = Image()
  image.shared()
  image.entry(type: 9, optional: true, [1, 2, 3, 4])
  image.entry(type: 1, [1, 2, 3, 4])
  image.entry(type: 2, [1, 2, 3, 4])
  image.entry(type: 3, [1, 2, 3, 4])
  image.entry(type: 4, [1, 2, 3, 4])
  #expect(try image.parsed().sections.count == 1)
  var required = image
  required.entry(type: 9, [1, 2, 3, 4])
  rejected(required, .unknownRequiredEntry(offset: afterShared + 5 * 8, type: 9))
  var five = Image()
  five.shared()
  five.entry(type: 5, [])
  rejected(five, .unknownRequiredEntry(offset: afterShared, type: 5))
}

// 5.2.3, in its order

@Test func ruleSection1PayloadHoldsTwentyBytes() {
  var image = Image()
  image.shared()
  image.entry(type: 0, [UInt8](repeating: 0, count: 16))
  rejected(image, .sectionTooShort(offset: afterShared))
}

@Test func ruleSection2DataRange() {
  var image = Image()
  image.shared()
  image.section(flags: 3, va: 0x1000, vaEnd: 0x3000, data: 0x30, dataEnd: 0x20)
  rejected(image, .dataRangeInverted(offset: afterShared))
}

@Test func ruleSection3VARange() {
  var image = Image()
  image.shared()
  image.section(flags: 3, va: 0x3000, vaEnd: 0x1000)
  rejected(image, .vaRangeInverted(offset: afterShared))
}

@Test func ruleSection4DataInTheFile() {
  var image = Image()
  image.shared()
  image.section(flags: 3, va: 0x1000, vaEnd: 0x3000, data: 0, dataEnd: UInt32(image.file().count + 100))
  rejected(image, .dataPastFile(offset: afterShared))
}

@Test func ruleSection4IsAgainstTheFileNotTheImageSize() throws {
  var image = Image()
  image.shared()
  let base = UInt32(20 + image.bytes.count + 24)  // where the tail starts
  image.section(flags: 3, va: 0x1000, vaEnd: 0x3000, data: base, dataEnd: base + 64)
  image.tail = [UInt8](repeating: 7, count: 64)
  let s = try image.parsed().sections[1]
  #expect(s.dataStart == Int(base) && s.dataSize == 64)
}

@Test func ruleSection5Alignment() {
  var low = Image()
  low.shared()
  low.section(flags: 3, va: 0x1800, vaEnd: 0x3000)
  rejected(low, .unalignedVA(offset: afterShared))
  var high = Image()
  high.shared()
  high.section(flags: 3, va: 0x1000, vaEnd: 0x2FFF)
  rejected(high, .unalignedVA(offset: afterShared))
}

@Test func ruleSection6ReservedFlags() {
  for bit: UInt32 in [6, 7, 15, 29] {
    var image = Image()
    image.shared()
    image.section(flags: 3 | 1 << bit, va: 0x1000, vaEnd: 0x3000)
    rejected(image, .reservedFlags(offset: afterShared, flags: 3 | 1 << bit))
  }
}

@Test func ruleSection7ProtectedSectionsAreSkipped() throws {
  var image = Image()
  image.shared()
  image.tail = [UInt8](repeating: 0, count: 0x2000)
  image.section(flags: 3 | 1 << 5, va: 0x1000, vaEnd: 0x3000)
  // Skipped before rules 8 and 9, which this one would fail.
  image.section(flags: 3 | 1 << 5, va: 0x0400_0000, vaEnd: 0x0400_1000, data: 0, dataEnd: 0x1100)
  let parsed = try image.parsed()
  #expect(parsed.sections.count == 1 && parsed.protectedSkipped == 2)
}

@Test func ruleSection8TheInterfaceIsShared() {
  var image = Image()
  image.shared(flags: 3)
  rejected(image, .sharedMissing(offset: 20))
}

@Test func ruleSection9DataFitsTheRange() {
  var image = Image()
  image.shared()
  image.tail = [UInt8](repeating: 0, count: 0x2000)
  image.section(flags: 3, va: 0x1000, vaEnd: 0x2000, data: 0x10, dataEnd: 0x1020)
  rejected(image, .dataLargerThanSection(offset: afterShared))
}

@Test func ruleSection10EmptySectionsAreSkipped() throws {
  var image = Image()
  image.shared()
  image.section(flags: 3, va: 0x1000, vaEnd: 0x1000)
  let parsed = try image.parsed()
  #expect(parsed.sections.count == 1 && parsed.emptySkipped == 1)
}

@Test func exactlyOneSectionAtTheInterface() {
  var none = Image()
  none.section(flags: 3, va: 0x1000, vaEnd: 0x2000)
  rejected(none, .noSharedSection)
  rejected(Image(), .noSharedSection)
  var twice = Image()
  twice.shared()
  twice.section(flags: 0x4000_0003, va: 0x0400_0000, vaEnd: 0x0400_1000)
  rejected(twice, .manySharedSections)
  // An empty one at that address isn't loaded, so doesn't count.
  var skipped = Image()
  skipped.shared()
  skipped.section(flags: 0x4000_0003, va: 0x0400_0000, vaEnd: 0x0400_0000)
  #expect(skipped.error() == nil)
}

@Test func theFirstFailingRuleIsTheOneNamed() {
  var image = Image()
  image.shared()
  // Rules 3, 5 and 6 all fail; 3 is first.
  image.section(flags: 3 | 1 << 7, va: 0x3001, vaEnd: 0x1000)
  rejected(image, .vaRangeInverted(offset: afterShared))
  // A bad section late in the image rejects it whole.
  var late = Image()
  late.shared()
  late.section(flags: 3, va: 0x1000, vaEnd: 0x2000)
  late.section(flags: 3, va: 0x1001, vaEnd: 0x2000)
  rejected(late, .unalignedVA(offset: afterShared + 24))
}

@Test func reasonsNameTheirRule() {
  #expect("\(FirmwareError.badMagic(0x1234))".hasPrefix("5.2.1 rule 2"))
  #expect("\(FirmwareError.dataPastFile(offset: 20))".hasPrefix("5.2.3 rule 4"))
  #expect("\(FirmwareError.reservedFlags(offset: 20, flags: 0x40))".hasSuffix("0x40"))
}

// 5.2.4

/// An image whose build-info entry (12 bytes, after the interface) points at `blob`, its tail.
func buildInfo(_ blob: [UInt8], size: UInt32? = nil, start: UInt32? = nil) -> Image {
  var image = Image()
  image.shared()
  let at = start ?? UInt32(afterShared + 12)
  image.entry(type: 6, Image.le(at) + Image.le(size ?? UInt32(blob.count)))
  image.tail = blob
  return image
}

@Test func buildInfoGivesTheGitSha() throws {
  #expect(try buildInfo(Array("git_sha: abc123".utf8) + [0]).parsed().gitSha == "abc123")
  var plain = Image()
  plain.shared()
  #expect(try plain.parsed().gitSha == nil)
}

@Test func badBuildInfoIsIgnoredNotFatal() throws {
  let good = Array("git_sha: abc123".utf8) + [0]
  #expect(try buildInfo(good, size: 9).parsed().gitSha == nil)  // size <= 9
  #expect(try buildInfo(Array("git_sha: ".utf8) + [0], size: 10).parsed().gitSha == "")
  #expect(try buildInfo(Array("git_shA: abc123".utf8) + [0]).parsed().gitSha == nil)  // prefix
  #expect(try buildInfo(Array("git_sha: abc123".utf8) + [1]).parsed().gitSha == nil)  // not NUL-ended
  #expect(try buildInfo(good, size: 1000).parsed().gitSha == nil)  // past the file
  #expect(try buildInfo(good, start: 100_000).parsed().gitSha == nil)
}

// The status line

@Test func theStatusLine() {
  let good = buildInfo(Array("git_sha: abc123".utf8) + [0]).file()
  #expect(FirmwareImage.line(good) == "firmware \(good.count) bytes, 1 sections, git abc123, not loaded")
  #expect(FirmwareImage.line([]) == FirmwareImage.missing)
  #expect(FirmwareImage.line([1, 2, 3]).hasPrefix("firmware 3 bytes refused: 5.2.1 rule 1"))
  #expect(FirmwareImage.line([1, 2, 3]).hasSuffix("not loaded"))
}

// The real image

enum RealFirmware {
  static let path: String = {
    var parts = #filePath.split(separator: "/", omittingEmptySubsequences: false)
    parts.removeLast(5)  // drivers/gpu/mali/tests/FirmwareTests.swift
    return parts.joined(separator: "/") + "/.cache/firmware/arm/mali/arch12.8/mali_csffw.bin"
  }()

  static var bytes: [UInt8]? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    return [UInt8](data)
  }
}

@Test func theRealImageParses() throws {
  guard let file = RealFirmware.bytes else { return }
  let image = try FirmwareImage.parse(file)
  #expect(image.sections.count >= 3 && image.sections.count < 64 && image.protectedSkipped <= image.sections.count)
  #expect(image.shared.vaStart == 0x0400_0000 && image.shared.shared)
  let sha = try #require(image.gitSha)
  #expect(sha.count >= 8)
  for s in image.sections {
    #expect(s.vaStart & 0xFFF == 0 && s.vaEnd > s.vaStart && s.dataSize <= s.size)
    #expect(s.dataEnd <= file.count)
  }
  #expect(FirmwareImage.line(file).hasSuffix(", git " + sha + ", not loaded"))
}

@Test func theRealImageBrokenIsRefused() {
  guard var file = RealFirmware.bytes else { return }
  file[0] ^= 1
  #expect(throws: FirmwareError.self) { try FirmwareImage.parse(file) }
  file[0] ^= 1
  file.removeLast(file.count - 100)
  #expect(throws: FirmwareError.self) { try FirmwareImage.parse(file) }
}
