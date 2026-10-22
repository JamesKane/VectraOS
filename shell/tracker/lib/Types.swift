// SPDX-License-Identifier: BSD-3-Clause

// File types (M6j part 3b), as Be's mimeset found them: a file without a
// `sys:type` gets one from its first bytes and its name, once, and keeps
// it. The codecs' index first (their magic, then their extensions: the
// types the system can decode), then a few other well-known signatures,
// then a table of extensions, then valid UTF-8 without NULs as plain
// text, and anything else as bytes. An empty file stays untyped until it
// has something to tell by.

import Codecs

public enum FileTypes {
  /// How many bytes `sniff` looks at.
  public static let headLength = 512

  /// The query file's type (3d: a query is a folder).
  public static let query = "application/x-vnd.todhchai-query"

  static let index = try? CodecIndex(text: builtInIndex, file: "built-in")

  static let magic: [(bytes: [UInt8], type: String)] = [
    (Array("%PDF-".utf8), "application/pdf"),
    ([0x50, 0x4B, 0x03, 0x04], "application/zip"),
    ([0x1F, 0x8B], "application/gzip"),
    ([0x7F, 0x45, 0x4C, 0x46], "application/x-executable"),
    (Array("GIF8".utf8), "image/gif"),
    (Array("OggS".utf8), "audio/ogg"),
    (Array("ID3".utf8), "audio/mpeg"),
    ([0x00, 0x01, 0x00, 0x00], "font/ttf"),
    (Array("OTTO".utf8), "font/otf"),
  ]

  static let extensions: [String: String] = [
    "txt": "text/plain", "md": "text/markdown", "markdown": "text/markdown", "html": "text/html",
    "htm": "text/html", "css": "text/css", "csv": "text/csv", "json": "application/json",
    "xml": "application/xml", "swift": "text/x-swift", "c": "text/x-c", "h": "text/x-c",
    "cpp": "text/x-c++", "rs": "text/x-rust", "zig": "text/x-zig", "odin": "text/x-odin",
    "py": "text/x-python", "sh": "application/x-sh", "rc": "text/x-rc", "pdf": "application/pdf",
    "zip": "application/zip", "gz": "application/gzip", "svg": "image/svg+xml", "gif": "image/gif",
    "mp3": "audio/mpeg", "ogg": "audio/ogg", "ttf": "font/ttf", "otf": "font/otf", "woff2": "font/woff2",
    "query": query,
  ]

  /// The type of a file named `name` beginning with `head`; nil for an
  /// empty one.
  public static func sniff(_ head: [UInt8], name: String) -> String? {
    if let codec = index?.match(head, name: name), let t = codec.types.first { return t }
    if head.isEmpty { return extensionType(name) }
    for m in magic where head.starts(with: m.bytes) { return m.type }
    if let t = extensionType(name) { return t }
    return isText(head) ? "text/plain" : "application/octet-stream"
  }

  /// Whether `type` is in `allowed` (`text/*` matches any `text/...`; empty
  /// `allowed` accepts any type).
  public static func matches(_ type: String, allowed: [String]) -> Bool {
    guard !allowed.isEmpty else { return true }
    let t = type.lowercased()
    for a in allowed {
      let p = a.lowercased()
      if p == "*/*" || p == "*" || p == t { return true }
      if p.hasSuffix("/*") && t.hasPrefix(p.dropLast()) { return true }
    }
    return false
  }

  static func extensionType(_ name: String) -> String? {
    guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
    return extensions[name[name.index(after: dot)...].lowercased()]
  }

  /// UTF-8 without NULs (a sequence cut at the end of `head` allowed).
  static func isText(_ head: [UInt8]) -> Bool {
    var i = 0
    while i < head.count {
      let b = head[i]
      if b == 0 { return false }
      let n = b < 0x80 ? 1 : b >> 5 == 0b110 ? 2 : b >> 4 == 0b1110 ? 3 : b >> 3 == 0b11110 ? 4 : 0
      guard n > 0 else { return false }
      for k in 1..<n where i + k < head.count {
        if head[i + k] >> 6 != 0b10 { return false }
      }
      i += n
    }
    return true
  }
}

/// A Tracker add-on (M6l, Be's): an app whose manifest says `addon LABEL`,
/// in Tracker's Add-ons menu by its label, started with the selected
/// paths (or the folder) as arguments.
public struct AddOn: Equatable, Sendable {
  public var service: String
  public var label: String
  public init(service: String, label: String) {
    self.service = service
    self.label = label
  }

  /// The add-ons in the launcher's `apps` leaf (its fifth field).
  public static func parse(_ text: String) -> [AddOn] {
    text.split(separator: "\n").compactMap { line in
      let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
      guard f.count == 5, !f[4].isEmpty else { return nil }
      return AddOn(service: f[0], label: f[4])
    }
  }

  /// The launcher's `start` line for paths (absolute in the namespace),
  /// each quoted as rc quotes.
  public static func start(_ service: String, _ paths: [String]) -> String {
    (["start", service] + paths.map { "'" + $0.split(separator: "'", omittingEmptySubsequences: false).joined(separator: "''") + "'" })
      .joined(separator: " ")
  }
}

/// Be's Select… (M6l): a name pattern, `*` any run and `?` any one
/// character, matched whole, letters' case aside.
public enum NamePattern {
  public static func matches(_ pattern: String, _ name: String) -> Bool {
    let p = Array(pattern.lowercased()), n = Array(name.lowercased())
    // The classic two-pointer match, backtracking to the last star.
    var i = 0, j = 0, star = -1, mark = 0
    while j < n.count {
      if i < p.count && (p[i] == "?" || p[i] == n[j]) {
        i += 1
        j += 1
      } else if i < p.count && p[i] == "*" {
        star = i
        mark = j
        i += 1
      } else if star >= 0 {
        i = star + 1
        mark += 1
        j = mark
      } else {
        return false
      }
    }
    while i < p.count && p[i] == "*" { i += 1 }
    return i == p.count
  }
}

/// A volume (M6l, Be's desktop shows them): its name, size and free
/// space, from its fs service's status (`volume NAME`, `blocks N free N
/// size N`), and whether it's the boot volume (/data, the desktop's).
public struct VolumeInfo: Equatable, Sendable {
  public var name: String
  public var bytes: UInt64
  public var free: UInt64
  public var boot: Bool
  public init(name: String, bytes: UInt64, free: UInt64, boot: Bool) {
    self.name = name
    self.bytes = bytes
    self.free = free
    self.boot = boot
  }

  /// From an fs service's `status`; nil without a `volume` line.
  public static func parse(fsStatus text: String, boot: Bool) -> VolumeInfo? {
    var name: String?, bytes: UInt64 = 0, free: UInt64 = 0
    for line in text.split(separator: "\n") {
      let w = line.split(separator: " ").map(String.init)
      if w.first == "volume" { name = w.dropFirst().joined(separator: " ") }
      if w.count == 6, w[0] == "blocks", w[2] == "free", w[4] == "size", let n = UInt64(w[1]), let f = UInt64(w[3]),
        let s = UInt64(w[5])
      {
        bytes = n * s
        free = min(f, n) * s
      }
    }
    return name.map { VolumeInfo(name: $0.isEmpty ? "Taisce" : $0, bytes: bytes, free: free, boot: boot) }
  }
}
