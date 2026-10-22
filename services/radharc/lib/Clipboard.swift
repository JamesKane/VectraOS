// SPDX-License-Identifier: BSD-3-Clause

// The clipboard (D112): one entry, the representations of one thing,
// each a MIME type and its bytes, held by Radharc so that it outlives the
// program that wrote it. A new entry replaces the old one whole. Pure:
// Main serves `snarf` and `clip`, and the scene says who may read
// (`Scene.mayRead`).
//
// An entry is written whole on one channel to `clip/new`: each
// representation an ndb(6) line, `type=image/png length=N`, then its N
// bytes; `secret=1` on the first line marks it secret, cleared 30 seconds
// after it is committed. `snarf` is rio's: its writes are text, the
// entry's one representation. Each representation is a file in `clip`,
// named by its type without parameters, `/` written as `.`
// (`text.plain`); `snarf` reads `text.plain`. An entry is at most 16 MiB,
// its text at most 1 MiB.

import NdbFile

public struct ClipRepresentation: Equatable, Sendable {
  /// Its MIME type, as written.
  public let type: String
  /// Its file's name in `clip`.
  public let name: String
  public let bytes: [UInt8]

  public init(type: String, bytes: [UInt8]) throws(ClipRefusal) {
    self.type = type
    name = try Self.name(of: type)
    self.bytes = bytes
  }

  /// `type`'s file name: lower case, its parameters left out, `/` as `.`.
  static func name(of type: String) throws(ClipRefusal) -> String {
    let bare = type.utf8.split(separator: UInt8(ascii: ";"), maxSplits: 1, omittingEmptySubsequences: false)[0]
    let parts = bare.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false)
    func token(_ b: UInt8) -> Bool {
      (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
        || "!#$&^_.+-".utf8.contains(b)
    }
    guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(token) }) else {
      throw ClipRefusal(reason: "type= is a MIME type")
    }
    let lower = bare.map { b -> UInt8 in
      let l = b >= 0x41 && b <= 0x5A ? b + 0x20 : b
      return l == UInt8(ascii: "/") ? UInt8(ascii: ".") : l
    }
    return String(decoding: lower, as: UTF8.self)
  }
}

public struct ClipEntry: Equatable, Sendable {
  public let representations: [ClipRepresentation]
  public let secret: Bool

  public init(_ representations: [ClipRepresentation], secret: Bool = false) {
    self.representations = representations
    self.secret = secret
  }

  /// Its size in bytes, all representations together.
  public var size: Int { representations.reduce(0) { $0 + $1.bytes.count } }
}

/// Why an entry was refused.
public struct ClipRefusal: Error, Equatable {
  public let reason: String
}

/// One channel's writes, collected: `snarf`'s text, or `clip/new`'s
/// entry, its lines checked as they come.
public struct ClipWriter: Sendable {
  /// The longest entry, all its representations together.
  public static let maxEntry = 16 << 20
  /// The longest text.
  public static let maxText = 1 << 20
  /// The longest representation's line.
  public static let maxLine = 1024
  public static let maxRepresentations = 16

  let snarf: Bool
  /// Something was written.
  public private(set) var wrote = false
  var text: [UInt8] = []  // snarf's
  var line: [UInt8] = []
  /// The representation being read, and how many of its bytes are still
  /// to come.
  var reading: (type: String, bytes: [UInt8], left: Int)?
  var done: [ClipRepresentation] = []
  var secret = false
  var total = 0

  /// A writer of `snarf`'s text, or of an entry.
  public init(snarf: Bool) { self.snarf = snarf }

  public mutating func write(_ bytes: [UInt8]) throws(ClipRefusal) {
    wrote = true
    total += bytes.count
    if snarf {
      guard total <= Self.maxText else { throw ClipRefusal(reason: "text longer than 1 MiB") }
      text += bytes
      return
    }
    var i = 0
    while i < bytes.count {
      if var r = reading {
        reading = nil  // r its bytes' only owner: appending copies nothing
        let n = min(r.left, bytes.count - i)
        r.bytes += bytes[i..<(i + n)]
        r.left -= n
        i += n
        if r.left == 0 {
          done.append(try ClipRepresentation(type: r.type, bytes: r.bytes))
          reading = nil
        } else {
          reading = r
        }
        continue
      }
      let b = bytes[i]
      i += 1
      guard b != 0x0A else {
        try begin()
        continue
      }
      line.append(b)
      guard line.count <= Self.maxLine else { throw ClipRefusal(reason: "a line longer than \(Self.maxLine) bytes") }
    }
  }

  /// The line read: the representation it begins.
  mutating func begin() throws(ClipRefusal) {
    var type: String?
    var length: Int?
    for p in parseLine(line) {
      if same(p.attr, "type") {
        guard type == nil else { throw ClipRefusal(reason: "one type= a line") }
        type = p.value
      } else if same(p.attr, "length") {
        guard length == nil, !p.value.isEmpty, p.value.utf8.count <= 9,
          p.value.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 })
        else { throw ClipRefusal(reason: "length= is a number") }
        length = p.value.utf8.reduce(0) { $0 * 10 + Int($1 - 0x30) }
      } else if same(p.attr, "secret") {
        guard done.isEmpty, same(p.value, "1") else { throw ClipRefusal(reason: "secret=1, on the first line") }
        secret = true
      } else {
        throw ClipRefusal(reason: "a line is type=, length= and secret=")
      }
    }
    line = []
    guard let type, let length else { throw ClipRefusal(reason: "a line has type= and length=") }
    guard done.count < Self.maxRepresentations else { throw ClipRefusal(reason: "more than 16 representations") }
    let name = try ClipRepresentation.name(of: type)
    guard !done.contains(where: { same($0.name, name) }) else { throw ClipRefusal(reason: "one \(name) an entry") }
    guard done.reduce(length, { $0 + $1.bytes.count }) <= Self.maxEntry else {
      throw ClipRefusal(reason: "longer than 16 MiB")
    }
    guard !same(name, "text.plain") || length <= Self.maxText else {
      throw ClipRefusal(reason: "text longer than 1 MiB")
    }
    if length == 0 {
      done.append(try ClipRepresentation(type: type, bytes: []))
    } else {
      reading = (type, [], length)
    }
  }

  /// The entry written, once the channel closes.
  public func finish() throws(ClipRefusal) -> ClipEntry {
    if snarf { return ClipEntry([try ClipRepresentation(type: Clipboard.textType, bytes: text)]) }
    guard reading == nil, line.isEmpty else { throw ClipRefusal(reason: "it ends inside a representation") }
    guard !done.isEmpty else { throw ClipRefusal(reason: "an entry has a representation") }
    return ClipEntry(done, secret: secret)
  }
}

/// The clipboard: the entry committed last, if it is still held.
public struct Clipboard: Sendable {
  /// `snarf`'s type.
  public static let textType = "text/plain;charset=utf-8"
  /// How long a secret entry is held (ns).
  public static let secretLife: Int64 = 30_000_000_000

  public private(set) var entry: ClipEntry?
  /// When it was committed.
  public private(set) var committed: Int64 = 0
  /// Entries committed, ever: a reader's snapshot names the one it read.
  public private(set) var commits = 0

  public init() {}

  public mutating func commit(_ e: ClipEntry, now: Int64) {
    entry = e
    committed = now
    commits += 1
  }

  /// Clears a secret entry held past its life; whether it did.
  @discardableResult
  public mutating func expire(now: Int64) -> Bool {
    guard let e = entry, e.secret, now - committed >= Self.secretLife else { return false }
    entry = nil
    return true
  }

  /// Its representations' names, in the order written.
  public var names: [String] { entry?.representations.map { $0.name } ?? [] }

  public func bytes(named name: String) -> [UInt8]? {
    entry?.representations.first { same($0.name, name) }?.bytes
  }

  /// `snarf`'s text: `text.plain`'s bytes, or none.
  public var text: [UInt8] { bytes(named: "text.plain") ?? [] }
}

/// An entry as the `clipboard` service gives it (D117): the header line
/// `entry source=APP origin=TITLE count=N`, then its representations in
/// `clip/new`'s form.
public struct ClipFeedItem: Sendable {
  /// The clipboard's commit it was.
  public let seq: Int
  public let bytes: [UInt8]
}

/// The `clipboard` service's feed (D117): the last entries committed that
/// weren't secret, for the shell's history. A reader that falls further
/// behind misses the older ones.
public struct ClipFeed: Sendable {
  public static let kept = 8
  public private(set) var items: [ClipFeedItem] = []
  /// Entries given, ever.
  public private(set) var fed = 0

  public init() {}

  /// Keeps commit `seq`'s entry, unless it is secret.
  public mutating func add(_ e: ClipEntry, seq: Int, source: String, origin: String) {
    guard !e.secret else { return }
    items.append(ClipFeedItem(seq: seq, bytes: Self.encode(e, source: source, origin: origin)))
    if items.count > Self.kept { items.removeFirst(items.count - Self.kept) }
    fed += 1
  }

  /// The first entry after commit `seq`.
  public func next(after seq: Int) -> ClipFeedItem? { items.first { $0.seq > seq } }

  /// `e` behind its header line. A value's quotes become `'`, a line's
  /// end a space: neither can end the value in the header.
  public static func encode(_ e: ClipEntry, source: String, origin: String) -> [UInt8] {
    func clean(_ s: String) -> String {
      String(decoding: s.utf8.map { $0 == 0x22 ? 0x27 : ($0 == 0x0A || $0 == 0x0D ? 0x20 : $0) }, as: UTF8.self)
    }
    var out = Array("entry source=\(ndbQuoted(clean(source))) origin=\(ndbQuoted(clean(origin))) count=\(e.representations.count)\n".utf8)
    out += encode(e)
    return out
  }

  /// `e`'s representations in `clip/new`'s form.
  public static func encode(_ e: ClipEntry) -> [UInt8] {
    var out: [UInt8] = []
    for r in e.representations {
      out += Array("type=\(r.type) length=\(r.bytes.count)\n".utf8)
      out += r.bytes
    }
    return out
  }
}
