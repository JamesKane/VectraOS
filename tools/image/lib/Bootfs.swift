// SPDX-License-Identifier: BSD-3-Clause

// Bootfs images (K8b): Zircon's bootfs format, without a ZBI container
// around it. The loader reads one as \croi\bootfs.img and userboot finds
// programs in it. (croi's tools/mkbootfs.py, in Swift.)
//
// Layout (zircon zbi-format bootfs.h): a 16-byte header (magic, dirsize,
// two reserved words), then directory entries (name_len with the NUL,
// data_len, data_off, the name, padded to 4 bytes), then each file at a
// page-aligned offset from the start of the image, zero padded to a page.

public enum Bootfs {
  public static let magic: UInt32 = 0xA56D_3FF9
  static let page = 4096
  static let maxName = 256

  /// The image holding `files` (name, contents), in order.
  public static func image(_ files: [(name: String, contents: [UInt8])]) throws(FormatError) -> [UInt8] {
    var names: [[UInt8]] = []
    for f in files {
      guard !f.name.isEmpty, !f.name.hasPrefix("/") else {
        throw FormatError("bad name \"\(f.name)\" (want a name not starting with /)")
      }
      let encoded = Array(f.name.utf8) + [0]
      guard encoded.count <= maxName else { throw FormatError("name too long: \(f.name)") }
      guard !names.contains(encoded) else { throw FormatError("duplicate names") }
      names.append(encoded)
    }
    let dirsize = names.reduce(0) { $0 + align(12 + $1.count, 4) }
    var offset = align(16 + dirsize, page)
    var directory: [UInt8] = []
    var data: [UInt8] = []
    for (name, f) in zip(names, files) {
      directory.append32(UInt32(name.count))
      directory.append32(UInt32(f.contents.count))
      directory.append32(UInt32(offset))
      directory += name + [UInt8](repeating: 0, count: align(12 + name.count, 4) - 12 - name.count)
      data += f.contents + [UInt8](repeating: 0, count: align(f.contents.count, page) - f.contents.count)
      offset += align(f.contents.count, page)
    }
    var image: [UInt8] = []
    image.append32(magic)
    image.append32(UInt32(dirsize))
    image.append32(0)
    image.append32(0)
    image += directory
    image += [UInt8](repeating: 0, count: align(image.count, page) - image.count)
    return image + data
  }

  /// The file names in an image; empty if it isn't one.
  public static func names(_ image: [UInt8]) -> [String] {
    guard image.count >= 16, image.u32(0) == magic else { return [] }
    let dirsize = Int(image.u32(4))
    let end = min(image.count, 16 + dirsize)
    var names: [String] = []
    var at = 16
    while at + 12 <= end {
      let length = Int(image.u32(at))
      guard length > 0, at + 12 + length <= end else { break }
      let bytes = image[at + 12..<at + 12 + length].prefix { $0 != 0 }
      names.append(String(decoding: bytes, as: UTF8.self))
      at += align(12 + length, 4)
    }
    return names
  }
}
