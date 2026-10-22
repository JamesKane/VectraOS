// SPDX-License-Identifier: BSD-3-Clause

// The manual as hypertext (guide(4)), without its window: the pages'
// headers read once into a library, AmigaGuide's places (Contents, Index,
// a page) with Retrace's history and Browse's neighbours, and the links in
// a page's text, each a page's name and section, `rc(1)`. A link only
// moves the viewer: nothing it names is run.

import Guide

/// A page of the manual, as its header says.
public struct ManualEntry: Equatable, Sendable {
  public var name: String
  public var section: Int
  public var summary: String
  /// The other names it answers to, and its keys.
  public var names: [String]
  public var keys: [String]
  /// Its file under the manual's directory, `1/rc`.
  public var path: String

  public init(name: String, section: Int, summary: String, names: [String] = [], keys: [String] = [], path: String) {
    self.name = name
    self.section = section
    self.summary = summary
    self.names = names
    self.keys = keys
    self.path = path
  }

  /// `rc(1)`.
  public var title: String { "\(name)(\(section))" }
}

/// Every page's header, by section then name.
public struct ManualLibrary: Sendable {
  public private(set) var entries: [ManualEntry] = []

  /// The pages given, each `(path, bytes)`; a page that doesn't parse is
  /// left out.
  public init(pages: [(path: String, bytes: [UInt8])]) {
    for (path, bytes) in pages {
      guard let page = try? Page(bytes, file: path) else { continue }
      let h = page.header
      entries.append(ManualEntry(name: h.page, section: h.section, summary: h.summary, names: h.names, keys: h.keys,
                                 path: path))
    }
    entries.sort { $0.section != $1.section ? $0.section < $1.section : $0.name < $1.name }
  }

  public var sections: [Int] {
    var out: [Int] = []
    for e in entries where !out.contains(e.section) { out.append(e.section) }
    return out
  }

  public func pages(in section: Int) -> [ManualEntry] { entries.filter { $0.section == section } }

  /// The page named `name` (its own name, else one of its names), in
  /// `section` if given; the lowest section first.
  public func find(_ name: String, section: Int? = nil) -> ManualEntry? {
    let candidates = section.map { s in entries.filter { $0.section == s } } ?? entries
    return candidates.first { $0.name == name } ?? candidates.first { $0.names.contains(name) }
  }

  /// The Index: every page's names and keys, each with its page, sorted.
  public var index: [(word: String, entry: ManualEntry)] {
    var out: [(word: String, entry: ManualEntry)] = []
    for e in entries {
      for w in [e.name] + e.names + e.keys where !out.contains(where: { $0.word == w && $0.entry == e }) {
        out.append((w, e))
      }
    }
    return out.sorted { $0.word != $1.word ? $0.word < $1.word : $0.entry.section < $1.entry.section }
  }

  /// The Index's words beginning `prefix`.
  public func index(prefix: String) -> [(word: String, entry: ManualEntry)] {
    index.filter { $0.word.hasPrefix(prefix) }
  }

  /// Browse's neighbours: the pages before and after `e` in its section.
  public func neighbours(of e: ManualEntry) -> (previous: ManualEntry?, next: ManualEntry?) {
    let section = pages(in: e.section)
    guard let i = section.firstIndex(of: e) else { return (nil, nil) }
    return (i > 0 ? section[i - 1] : nil, i + 1 < section.count ? section[i + 1] : nil)
  }
}

/// Where the viewer is, and how it got there.
public struct ManualViewer: Sendable {
  public enum Place: Equatable, Sendable {
    case contents
    case index
    case page(ManualEntry)
  }

  public private(set) var place: Place = .contents
  /// Retrace's places, the latest last.
  public private(set) var history: [Place] = []

  public init() {}

  /// Goes to `p`; the place left is Retrace's.
  public mutating func go(_ p: Place) {
    guard p != place else { return }
    history.append(place)
    place = p
  }

  /// Back to the place before; false if there was none.
  @discardableResult
  public mutating func retrace() -> Bool {
    guard let p = history.popLast() else { return false }
    place = p
    return true
  }

  /// To the page after (or before) this one in its section; false if
  /// there is none, or the viewer isn't on a page.
  @discardableResult
  public mutating func browse(forward: Bool, in library: ManualLibrary) -> Bool {
    guard case .page(let e) = place else { return false }
    let n = library.neighbours(of: e)
    guard let to = forward ? n.next : n.previous else { return false }
    go(.page(to))
    return true
  }
}

/// A link in rendered text: where it is, and what it names.
public struct ManualLink: Equatable, Sendable {
  public var range: Range<Int>
  public var name: String
  public var section: Int
}

public enum ManualLinks {
  /// `rc(1)` as a name and a section; nil if it isn't one.
  public static func parse(_ text: String) -> (name: String, section: Int)? {
    let b = Array(text.utf8)
    guard let open = b.firstIndex(of: UInt8(ascii: "(")), open > 0, b.count == open + 3, b[open + 2] == UInt8(ascii: ")"),
      b[open + 1] >= UInt8(ascii: "1"), b[open + 1] <= UInt8(ascii: "8"), b[..<open].allSatisfy(nameByte)
    else { return nil }
    return (String(decoding: b[..<open], as: UTF8.self), Int(b[open + 1] - UInt8(ascii: "0")))
  }

  static func nameByte(_ c: UInt8) -> Bool {
    (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) || (c >= 0x30 && c <= 0x39) || c == 0x2D || c == 0x5F
      || c == 0x2E
  }

  /// The links in a line of text: each `name(N)`, N from 1 to 8.
  public static func find(in line: [UInt8]) -> [ManualLink] {
    var out: [ManualLink] = []
    var i = 0
    while i < line.count {
      guard line[i] == UInt8(ascii: "("), i + 2 < line.count, line[i + 1] >= UInt8(ascii: "1"),
        line[i + 1] <= UInt8(ascii: "8"), line[i + 2] == UInt8(ascii: ")")
      else {
        i += 1
        continue
      }
      var start = i
      while start > 0, nameByte(line[start - 1]) { start -= 1 }
      // A name doesn't start or end with a dot (a sentence's end).
      while start < i, line[start] == UInt8(ascii: ".") { start += 1 }
      if start < i, line[i - 1] != UInt8(ascii: ".") {
        out.append(ManualLink(range: start..<(i + 3), name: String(decoding: line[start..<i], as: UTF8.self),
                              section: Int(line[i + 1] - UInt8(ascii: "0"))))
      }
      i += 3
    }
    return out
  }
}
