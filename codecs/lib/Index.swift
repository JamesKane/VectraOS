// SPDX-License-Identifier: BSD-3-Clause

// The codecs' records (M4h2; the roadmap's "Decided": codecs are classes
// like drivers). Each codec's directory holds a `codec.manifest`, one
// directive a line, `#` starting a comment:
//
//     codec wav                  # first: its name
//     class audio                # its class (codecs/CLASS): what it decodes to
//     type audio/wav             # a media type it reads
//     extension wav              # a file name extension
//     magic 0 RIFF               # bytes at an offset: text, or 0x and hex
//     magic 8 WAVE               # (every magic line must match)
//
// `BuiltIn.swift` collects them into this module's generated `builtInIndex`,
// which a program built with the codecs matches files against as data:
// by content first (every magic line of one codec, and only one), then by
// the name's extension. Two codecs sharing a type, an extension or the
// same magic is an error. Later, codecs outside the program are fetched on
// demand by the same records, as drivers are to be (NeoVectra's
// drivers-on-demand sketch).

@inline(__always) private func same(_ a: String, _ b: String) -> Bool {
  a.utf8.elementsEqual(b.utf8)
}

@inline(__always) private func sameList(_ a: [String], _ b: [String]) -> Bool {
  guard a.count == b.count else { return false }
  for i in 0..<a.count where !same(a[i], b[i]) { return false }
  return true
}

public struct CodecManifest: Equatable, Sendable {
  public var name: String
  public var codecClass = ""
  public var types: [String] = []
  public var extensions: [String] = []
  public var magic: [Magic] = []
  /// Where it was read, for errors: "file:line".
  public var origin: String

  public struct Magic: Equatable, Sendable {
    public var offset: Int
    public var bytes: [UInt8]
    public init(offset: Int, bytes: [UInt8]) {
      self.offset = offset
      self.bytes = bytes
    }
  }

  public init(name: String, origin: String) {
    self.name = name
    self.origin = origin
  }

  public static func == (a: CodecManifest, b: CodecManifest) -> Bool {
    same(a.name, b.name) && same(a.codecClass, b.codecClass) && sameList(a.types, b.types)
      && sameList(a.extensions, b.extensions) && a.magic == b.magic && same(a.origin, b.origin)
  }

  /// Whether `bytes` (a file's start) has every magic of this codec.
  public func recognizes(_ bytes: [UInt8]) -> Bool {
    !magic.isEmpty && magic.allSatisfy { m in
      m.offset + m.bytes.count <= bytes.count && bytes[m.offset..<(m.offset + m.bytes.count)].elementsEqual(m.bytes)
    }
  }
}

public struct CodecIndexError: Error, Equatable, CustomStringConvertible, Sendable {
  public let description: String
  public init(_ description: String) { self.description = description }
  public static func == (a: CodecIndexError, b: CodecIndexError) -> Bool {
    same(a.description, b.description)
  }
}

public struct CodecIndex: Sendable {
  public var codecs: [CodecManifest] = []

  /// Manifests, one after another (a codec starts at its `codec` line).
  public init(text: String, file: String) throws(CodecIndexError) {
    var line = 0
    for raw in text.utf8.split(separator: 0x0A, omittingEmptySubsequences: false) {
      line += 1
      let content = raw.split(separator: UInt8(ascii: "#"), maxSplits: 1, omittingEmptySubsequences: false).first
        ?? raw[raw.startIndex..<raw.startIndex]
      let words = content.split(whereSeparator: { $0 == 0x20 || $0 == 0x09 }).map {
        String(decoding: $0, as: UTF8.self)
      }
      guard let directive = words.first else { continue }
      let rest = Array(words.dropFirst())
      func fail(_ what: String) -> CodecIndexError { CodecIndexError("\(file):\(line): \(what)") }
      if same(directive, "codec") {
        guard rest.count == 1 else { throw fail("'codec' takes a name") }
        codecs.append(CodecManifest(name: rest[0], origin: "\(file):\(line)"))
        continue
      }
      guard !codecs.isEmpty else { throw fail("'codec' must come first") }
      let i = codecs.count - 1
      if same(directive, "class") {
        guard rest.count == 1 else { throw fail("'class' takes a class") }
        codecs[i].codecClass = rest[0]
      } else if same(directive, "type") {
        guard rest.count == 1, rest[0].utf8.contains(UInt8(ascii: "/")) else { throw fail("'type' takes a media type") }
        codecs[i].types.append(rest[0])
      } else if same(directive, "extension") {
        guard rest.count == 1, !rest[0].utf8.contains(UInt8(ascii: ".")) else { throw fail("'extension' takes one, no dot") }
        codecs[i].extensions.append(rest[0])
      } else if same(directive, "magic") {
        guard rest.count == 2, let offset = Int(rest[0]), offset >= 0, let bytes = Self.bytes(rest[1]) else {
          throw fail("'magic' takes an offset and bytes (text, or 0x and hex)")
        }
        codecs[i].magic.append(CodecManifest.Magic(offset: offset, bytes: bytes))
      } else {
        throw fail("unknown directive '\(directive)'")
      }
    }
    for c in codecs where c.codecClass.isEmpty { throw CodecIndexError("\(c.origin): codec '\(c.name)' has no class") }
    for c in codecs where c.magic.isEmpty && c.extensions.isEmpty {
      throw CodecIndexError("\(c.origin): codec '\(c.name)' can't be recognized (no magic, no extension)")
    }
  }

  static func bytes(_ word: String) -> [UInt8]? {
    guard word.utf8.starts(with: "0x".utf8) else { return Array(word.utf8) }
    let hex = Array(word.utf8.dropFirst(2))
    guard !hex.isEmpty, hex.count % 2 == 0 else { return nil }
    var out: [UInt8] = []
    for i in stride(from: 0, to: hex.count, by: 2) {
      guard let b = UInt8(String(decoding: hex[i..<(i + 2)], as: UTF8.self), radix: 16) else { return nil }
      out.append(b)
    }
    return out
  }

  /// What two codecs share, as errors.
  public var conflicts: [String] {
    var out: [String] = []
    for (i, a) in codecs.enumerated() {
      for b in codecs[(i + 1)...] {
        let pair = "\(a.origin) and \(b.origin): '\(a.name)' and '\(b.name)'"
        for t in a.types where b.types.contains(where: { same($0, t) }) { out.append("\(pair) both read \(t)") }
        for e in a.extensions where b.extensions.contains(where: { same($0, e) }) { out.append("\(pair) both claim .\(e)") }
        if !a.magic.isEmpty && a.magic == b.magic { out.append("\(pair) have the same magic") }
      }
    }
    return out
  }

  /// The codec for a file: by its first bytes, else by `name`'s extension;
  /// nil if none (or two codecs) recognize it.
  public func match(_ bytes: [UInt8], name: String? = nil) -> CodecManifest? {
    let byContent = codecs.filter { $0.recognizes(bytes) }
    if byContent.count == 1 { return byContent[0] }
    if byContent.count > 1 { return nil }
    guard let name, let dot = name.utf8.lastIndex(of: UInt8(ascii: ".")) else { return nil }
    let ext = String(decoding: name.utf8[name.utf8.index(after: dot)...], as: UTF8.self)
    let byName = codecs.filter { c in c.extensions.contains { same($0, ext) } }
    return byName.count == 1 ? byName[0] : nil
  }

  /// The generated Swift holding `manifests` as `builtInIndex`.
  public static func generatedSource(_ manifests: [(path: String, text: String)]) -> String {
    var out = "// SPDX-License-Identifier: BSD-3-Clause\n\n"
    out += "// Generated by td codecs from every codecs/**/codec.manifest: don't edit.\n\n"
    out += "/// The codecs' records, as `CodecIndex(text:file:)` reads them.\n"
    out += "public let builtInIndex = \"\"\"\n"
    for m in manifests {
      out += "  # \(m.path)\n"
      for line in m.text.utf8.split(separator: 0x0A, omittingEmptySubsequences: false) where !line.isEmpty {
        out += "  " + String(decoding: line, as: UTF8.self) + "\n"
      }
    }
    out += "  \"\"\"\n"
    return out
  }
}
