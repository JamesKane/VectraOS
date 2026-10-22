// SPDX-License-Identifier: BSD-3-Clause

// What notices (notices(4), D117) keeps, without its windows: the board
// of notices apps post and the slips it shows, the `clipboard` service's
// entries parsed as they come, and the clips kept within their limits.
// Pure: Main reads and writes the files.

import NdbFile

/// A notice's lamp: where it stands, in the theme's role for it.
public enum Lamp: String, Sendable, CaseIterable {
  case info, done, warn, fail

  /// It stays until clicked.
  public var stays: Bool { self == .warn || self == .fail }
}

public struct Notice: Equatable, Sendable {
  public let id: Int
  public let app: String
  public let title: String
  public let body: String
  public let lamp: Lamp
  /// When it was posted (monotonic ns).
  public let posted: Int64
  /// It was shown as a slip (not one of a burst).
  public let shown: Bool
}

/// Why a post was refused.
public struct NoticeRefusal: Error, Equatable {
  public let reason: String
}

/// The notices posted and the slips on screen.
public struct NoticeBoard: Sendable {
  /// How long a slip that may go is shown (ns).
  public static let life: Int64 = 6_000_000_000
  public static let maxSlips = 3
  /// The history's length.
  public static let kept = 100
  /// More than this many posts from one app in `burstWindow` aren't shown.
  public static let burst = 10
  public static let burstWindow: Int64 = 10_000_000_000
  public static let maxTitle = 80
  public static let maxBody = 400

  /// The last notices, oldest first.
  public private(set) var history: [Notice] = []
  /// The slips shown, oldest first, with when each was shown.
  public private(set) var slips: [(id: Int, since: Int64)] = []
  /// Slips waiting for room, oldest first.
  public private(set) var waiting: [Int] = []
  var next = 1

  public init() {}

  /// A post's line: `title=`, `body=` and `lamp=`.
  public static func parse(_ line: String) throws(NoticeRefusal) -> (title: String, body: String, lamp: Lamp) {
    var title: String?, body = "", lamp = Lamp.info
    var trimmed = Array(line.utf8)
    while let l = trimmed.last, l == 0x0A || l == 0x0D { trimmed.removeLast() }
    for p in parseLine(trimmed) {
      switch p.attr {
      case "title": title = p.value
      case "body": body = p.value
      case "lamp":
        guard let l = Lamp(rawValue: p.value) else { throw NoticeRefusal(reason: "lamp= is info, done, warn or fail") }
        lamp = l
      default: throw NoticeRefusal(reason: "a notice is title=, body= and lamp=")
      }
    }
    guard let title, !title.isEmpty else { throw NoticeRefusal(reason: "a notice has a title=") }
    guard title.utf8.count <= maxTitle else { throw NoticeRefusal(reason: "title= longer than \(maxTitle) bytes") }
    guard body.utf8.count <= maxBody else { throw NoticeRefusal(reason: "body= longer than \(maxBody) bytes") }
    return (title, body, lamp)
  }

  /// Posts `line` from `app`; the notice. One of a burst is kept, not
  /// shown.
  @discardableResult
  public mutating func post(_ line: String, app: String, now: Int64) throws(NoticeRefusal) -> Notice {
    let p = try Self.parse(line)
    let recent = history.filter { $0.app == app && now - $0.posted < Self.burstWindow }.count
    let n = Notice(id: next, app: app, title: p.title, body: p.body, lamp: p.lamp, posted: now,
                   shown: recent < Self.burst)
    next += 1
    history.append(n)
    if history.count > Self.kept { history.removeFirst(history.count - Self.kept) }
    guard n.shown else { return n }
    if slips.count >= Self.maxSlips, let i = slips.firstIndex(where: { !(notice($0.id)?.lamp.stays ?? false) }) {
      slips.remove(at: i)
    }
    if slips.count < Self.maxSlips { slips.append((n.id, now)) } else { waiting.append(n.id) }
    return n
  }

  public func notice(_ id: Int) -> Notice? { history.last { $0.id == id } }

  /// The slips shown, newest first.
  public var shown: [Notice] { slips.reversed().compactMap { notice($0.id) } }

  /// Dismisses slip `id` (or takes it from those waiting); whether it was
  /// there.
  @discardableResult
  public mutating func dismiss(_ id: Int, now: Int64) -> Bool {
    if let i = slips.firstIndex(where: { $0.id == id }) {
      slips.remove(at: i)
    } else if let i = waiting.firstIndex(of: id) {
      waiting.remove(at: i)
      return true
    } else {
      return false
    }
    fill(now)
    return true
  }

  /// Slips that may go and have been shown their life go; whether any
  /// did.
  @discardableResult
  public mutating func expire(now: Int64) -> Bool {
    let gone = slips.filter { s in !(notice(s.id)?.lamp.stays ?? false) && now - s.since >= Self.life }.map { $0.id }
    guard !gone.isEmpty else { return false }
    slips.removeAll { gone.contains($0.id) }
    fill(now)
    return true
  }

  /// When the next slip goes, if one may.
  public var nextExpiry: Int64? {
    slips.filter { !(notice($0.id)?.lamp.stays ?? false) }.map { $0.since + Self.life }.min()
  }

  mutating func fill(_ now: Int64) {
    while slips.count < Self.maxSlips, !waiting.isEmpty {
      slips.append((waiting.removeFirst(), now))
    }
  }
}

/// An entry the `clipboard` service gave: who wrote it, and its
/// representations in `clip/new`'s form.
public struct FedEntry: Equatable, Sendable {
  public var source: String
  public var origin: String
  /// Its representations' types, in order.
  public var types: [String]
  /// The entry in `clip/new`'s form: what a clip's file holds.
  public var bytes: [UInt8]
}

/// The `clipboard` service's stream, parsed as it is read.
public struct ClipFeedParser: Sendable {
  var line: [UInt8] = []
  var current: FedEntry?
  /// Representations still to come in the current entry, and bytes of
  /// the one being read.
  var count = 0
  var left = 0
  /// The stream broke its form.
  public private(set) var broken = false

  public init() {}

  /// The entries `bytes` completes.
  public mutating func feed(_ bytes: [UInt8]) -> [FedEntry] {
    var out: [FedEntry] = []
    var i = 0
    while i < bytes.count, !broken {
      if left > 0 {
        let n = min(left, bytes.count - i)
        current?.bytes += bytes[i..<(i + n)]
        left -= n
        i += n
        if left == 0 { finish(&out) }
        continue
      }
      let b = bytes[i]
      i += 1
      guard b == 0x0A else {
        line.append(b)
        if line.count > 4096 { broken = true }
        continue
      }
      let pairs = parseLine(line)
      if current == nil {
        guard pairs.first?.attr == "entry" else {
          broken = true
          break
        }
        var e = FedEntry(source: "", origin: "", types: [], bytes: [])
        for p in pairs {
          switch p.attr {
          case "source": e.source = p.value
          case "origin": e.origin = p.value
          case "count": count = Int(p.value) ?? 0
          default: break
          }
        }
        guard count > 0 else {
          broken = true
          break
        }
        current = e
      } else {
        guard let type = pairs.first(where: { $0.attr == "type" })?.value,
          let length = pairs.first(where: { $0.attr == "length" }).flatMap({ Int($0.value) })
        else {
          broken = true
          break
        }
        current?.types.append(type)
        current?.bytes += line + [0x0A]
        left = length
        if left == 0 { finish(&out) }
      }
      line = []
    }
    return out
  }

  mutating func finish(_ out: inout [FedEntry]) {
    count -= 1
    if count == 0, let e = current {
      out.append(e)
      current = nil
    }
  }

  /// The text of an entry in `clip/new`'s form (or the start of one), its
  /// `text/plain` representation's bytes, if it has one.
  public static func text(_ entry: [UInt8]) -> [UInt8]? {
    var i = 0
    while i < entry.count {
      guard let nl = entry[i...].firstIndex(of: 0x0A) else { return nil }
      let pairs = parseLine(Array(entry[i..<nl]))
      guard let type = pairs.first(where: { $0.attr == "type" })?.value,
        let length = pairs.first(where: { $0.attr == "length" }).flatMap({ Int($0.value) })
      else { return nil }
      let start = nl + 1, end = min(entry.count, start + length)
      if type.hasPrefix("text/plain") { return Array(entry[start..<end]) }
      i = start + length
    }
    return nil
  }
}

/// A clip: an entry kept in the history.
public struct Clip: Equatable, Sendable {
  /// Its file's name in /data/Clips.
  public var number: Int
  public var source: String
  public var origin: String
  /// Seconds since the epoch, UTC.
  public var time: Int64
  public var types: [String]
  public var size: Int
  /// Its text's first line, or its types.
  public var preview: String

  public init(number: Int, source: String, origin: String, time: Int64, types: [String], size: Int, preview: String) {
    self.number = number
    self.source = source
    self.origin = origin
    self.time = time
    self.types = types
    self.size = size
    self.preview = preview
  }

  /// What the drawer shows for an entry: its text's first line, cut to 60
  /// characters, or its types.
  public static func preview(text: [UInt8]?, types: [String]) -> String {
    guard let text else { return types.joined(separator: ", ") }
    let first = text.split(separator: 0x0A, maxSplits: 1, omittingEmptySubsequences: true).first.map(Array.init) ?? []
    let s = String(decoding: first, as: UTF8.self)
    return s.count > 60 ? String(s.prefix(59)) + "…" : s
  }
}

/// The clips kept, within their limits.
public struct ClipShelf: Sendable {
  public var maxCount = 50
  public var maxDays = 30
  public var maxMiB = 64
  /// Oldest first.
  public private(set) var clips: [Clip] = []

  public init() {}

  /// The next clip's number.
  public var nextNumber: Int { (clips.map { $0.number }.max() ?? 0) + 1 }

  /// Takes the clips found at start, ordered by number.
  public mutating func load(_ found: [Clip]) {
    clips = found.sorted { $0.number < $1.number }
  }

  /// Adds `clip`; the numbers of those it pushed out.
  public mutating func add(_ clip: Clip, now: Int64) -> [Int] {
    clips.append(clip)
    return prune(now: now)
  }

  /// Removes the clips past the limits, oldest first; their numbers.
  public mutating func prune(now: Int64) -> [Int] {
    var gone: [Int] = []
    let oldest = now - Int64(maxDays) * 86_400
    while let c = clips.first, clips.count > maxCount || c.time < oldest || total > maxMiB << 20 {
      gone.append(c.number)
      clips.removeFirst()
    }
    return gone
  }

  public mutating func remove(_ number: Int) -> Bool {
    guard let i = clips.firstIndex(where: { $0.number == number }) else { return false }
    clips.remove(at: i)
    return true
  }

  public mutating func removeAll() -> [Int] {
    defer { clips = [] }
    return clips.map { $0.number }
  }

  public var total: Int { clips.reduce(0) { $0 + $1.size } }

  public func clip(_ number: Int) -> Clip? { clips.first { $0.number == number } }
}
