// SPDX-License-Identifier: BSD-3-Clause

// 9P2000's messages (D78), as Plan 9's fcall(2) and intro(5) give them:
// a size[4], a type[1] and a tag[2], then each type's fields in order,
// little-endian, strings as a count[2] and UTF-8. Decoding is strict,
// because the bytes may come from a hostile peer: the size must be the
// message's, every field must fit, nothing may follow the last, a walk
// has at most 16 names or qids, and strings are UTF-8 without NUL.
// Terror (106) does not exist. `9P2000.vx`'s messages (D151) are types
// from 128 up, a T-message even and its R-message the next: one this
// side doesn't know decodes as `unknown`, which a server answers with an
// Rerror, so a node without an extension still talks to one with it.

/// The message types, by their numbers.
public enum FcallType {
  public static let tversion: UInt8 = 100
  public static let rversion: UInt8 = 101
  public static let tauth: UInt8 = 102
  public static let rauth: UInt8 = 103
  public static let tattach: UInt8 = 104
  public static let rattach: UInt8 = 105
  public static let rerror: UInt8 = 107
  public static let tflush: UInt8 = 108
  public static let rflush: UInt8 = 109
  public static let twalk: UInt8 = 110
  public static let rwalk: UInt8 = 111
  public static let topen: UInt8 = 112
  public static let ropen: UInt8 = 113
  public static let tcreate: UInt8 = 114
  public static let rcreate: UInt8 = 115
  public static let tread: UInt8 = 116
  public static let rread: UInt8 = 117
  public static let twrite: UInt8 = 118
  public static let rwrite: UInt8 = 119
  public static let tclunk: UInt8 = 120
  public static let rclunk: UInt8 = 121
  public static let tremove: UInt8 = 122
  public static let rremove: UInt8 = 123
  public static let tstat: UInt8 = 124
  public static let rstat: UInt8 = 125
  public static let twstat: UInt8 = 126
  public static let rwstat: UInt8 = 127
  /// 9P2000.vx (D151): a rename between directories.
  public static let trename: UInt8 = 128
  public static let rrename: UInt8 = 129
  /// The first of 9P2000.vx's types.
  public static let firstExtension: UInt8 = 128
}

/// 9P2000's constants.
public enum NineP {
  /// The dialect; ours is offered first (D78).
  public static let version = "9P2000"
  public static let extendedVersion = "9P2000.vx"
  /// Names in one walk.
  public static let maxWalk = 16
  /// Tversion's tag.
  public static let noTag: UInt16 = 0xffff
  /// No fid: Tattach's afid without authentication.
  public static let noFid: UInt32 = 0xffff_ffff
  /// What a Twrite or Rread spends on its header, so `msize - ioHeader`
  /// bytes of data fit in one.
  public static let ioHeader: UInt32 = 24
  /// The smallest msize a server takes.
  public static let minMessage: UInt32 = 256
  /// size[4] type[1] tag[2].
  public static let header = 7
}

/// A qid's type, the top byte of a mode.
public enum QidType {
  public static let dir: UInt8 = 0x80
  public static let append: UInt8 = 0x40
  public static let excl: UInt8 = 0x20
  public static let auth: UInt8 = 0x08
  public static let tmp: UInt8 = 0x04
  public static let file: UInt8 = 0x00
}

/// Topen's and Tcreate's modes.
public enum OpenMode {
  public static let read: UInt8 = 0
  public static let write: UInt8 = 1
  public static let rdwr: UInt8 = 2
  public static let exec: UInt8 = 3
  public static let trunc: UInt8 = 0x10
  public static let rclose: UInt8 = 0x40
}

/// A file's identity on its server: its type, version and path.
public struct Qid: Equatable, Sendable {
  public var type: UInt8
  public var version: UInt32
  public var path: UInt64

  public init(type: UInt8 = QidType.file, version: UInt32 = 0, path: UInt64) {
    self.type = type
    self.version = version
    self.path = path
  }

  static let size = 13
}

/// A message's body: one case a type, with that type's fields.
/// Two are equal when their bytes are: a name is its bytes in 9P, so "é"
/// composed and decomposed are two names, where String's == would make
/// them one (and would need Unicode's tables in Embedded Swift).
public enum Fcall: Equatable, Sendable {
  case tversion(msize: UInt32, version: String)
  case rversion(msize: UInt32, version: String)
  case tauth(afid: UInt32, uname: String, aname: String)
  case rauth(aqid: Qid)
  case tattach(fid: UInt32, afid: UInt32, uname: String, aname: String)
  case rattach(qid: Qid)
  case rerror(ename: String)
  case tflush(oldtag: UInt16)
  case rflush
  case twalk(fid: UInt32, newfid: UInt32, names: [String])
  case rwalk(qids: [Qid])
  case topen(fid: UInt32, mode: UInt8)
  case ropen(qid: Qid, iounit: UInt32)
  case tcreate(fid: UInt32, name: String, perm: UInt32, mode: UInt8)
  case rcreate(qid: Qid, iounit: UInt32)
  case tread(fid: UInt32, offset: UInt64, count: UInt32)
  case rread(data: [UInt8])
  case twrite(fid: UInt32, offset: UInt64, data: [UInt8])
  case rwrite(count: UInt32)
  case tclunk(fid: UInt32)
  case rclunk
  case tremove(fid: UInt32)
  case rremove
  case tstat(fid: UInt32)
  /// The stat is a Dir's bytes (Dir.encode), as it travels: Rstat and
  /// Twstat carry a count[2] before them, beyond the Dir's own size[2].
  case rstat(stat: [UInt8])
  case twstat(fid: UInt32, stat: [UInt8])
  case rwstat
  /// 9P2000.vx: `fid`'s file moved into the directory `newdirfid` as
  /// `name`, replacing a file there; within a directory, wstat's name.
  case trename(fid: UInt32, newdirfid: UInt32, name: String)
  case rrename
  /// A 9P2000.vx T-message this side doesn't know: never sent.
  case unknown(type: UInt8)

  /// The type's number.
  public var type: UInt8 {
    switch self {
    case .tversion: FcallType.tversion
    case .rversion: FcallType.rversion
    case .tauth: FcallType.tauth
    case .rauth: FcallType.rauth
    case .tattach: FcallType.tattach
    case .rattach: FcallType.rattach
    case .rerror: FcallType.rerror
    case .tflush: FcallType.tflush
    case .rflush: FcallType.rflush
    case .twalk: FcallType.twalk
    case .rwalk: FcallType.rwalk
    case .topen: FcallType.topen
    case .ropen: FcallType.ropen
    case .tcreate: FcallType.tcreate
    case .rcreate: FcallType.rcreate
    case .tread: FcallType.tread
    case .rread: FcallType.rread
    case .twrite: FcallType.twrite
    case .rwrite: FcallType.rwrite
    case .tclunk: FcallType.tclunk
    case .rclunk: FcallType.rclunk
    case .tremove: FcallType.tremove
    case .rremove: FcallType.rremove
    case .tstat: FcallType.tstat
    case .rstat: FcallType.rstat
    case .twstat: FcallType.twstat
    case .rwstat: FcallType.rwstat
    case .trename: FcallType.trename
    case .rrename: FcallType.rrename
    case .unknown(let type): type
    }
  }

  /// Whether it's a request (a T-message).
  public var isRequest: Bool { type & 1 == 0 }

  public static func == (a: Fcall, b: Fcall) -> Bool {
    Message(tag: 0, a).encode() == Message(tag: 0, b).encode()
  }
}

/// A message: its tag and body.
public struct Message: Equatable, Sendable {
  public var tag: UInt16
  public var fcall: Fcall

  public init(tag: UInt16, _ fcall: Fcall) {
    self.tag = tag
    self.fcall = fcall
  }

  /// Equal when their bytes are (Fcall's ==).
  public static func == (a: Message, b: Message) -> Bool { a.encode() == b.encode() }

  /// The message's bytes, its size first; nil if a field can't be sent
  /// (a string or stat past 65535 bytes, a walk past 16 elements, or a
  /// message past 4 GiB).
  public func encode() -> [UInt8]? {
    var w = Writer()
    w.bytes = [0, 0, 0, 0]
    w.u8(fcall.type)
    w.u16(tag)
    switch fcall {
    case .tversion(let msize, let version), .rversion(let msize, let version):
      w.u32(msize)
      w.string(version)
    case .tauth(let afid, let uname, let aname):
      w.u32(afid)
      w.string(uname)
      w.string(aname)
    case .rauth(let qid), .rattach(let qid):
      w.qid(qid)
    case .tattach(let fid, let afid, let uname, let aname):
      w.u32(fid)
      w.u32(afid)
      w.string(uname)
      w.string(aname)
    case .rerror(let ename):
      w.string(ename)
    case .tflush(let oldtag):
      w.u16(oldtag)
    case .rflush, .rclunk, .rremove, .rwstat, .rrename:
      break
    case .trename(let fid, let newdirfid, let name):
      w.u32(fid)
      w.u32(newdirfid)
      w.string(name)
    case .unknown:
      return nil
    case .twalk(let fid, let newfid, let names):
      guard names.count <= NineP.maxWalk else { return nil }
      w.u32(fid)
      w.u32(newfid)
      w.u16(UInt16(names.count))
      for n in names { w.string(n) }
    case .rwalk(let qids):
      guard qids.count <= NineP.maxWalk else { return nil }
      w.u16(UInt16(qids.count))
      for q in qids { w.qid(q) }
    case .topen(let fid, let mode):
      w.u32(fid)
      w.u8(mode)
    case .ropen(let qid, let iounit), .rcreate(let qid, let iounit):
      w.qid(qid)
      w.u32(iounit)
    case .tcreate(let fid, let name, let perm, let mode):
      w.u32(fid)
      w.string(name)
      w.u32(perm)
      w.u8(mode)
    case .tread(let fid, let offset, let count):
      w.u32(fid)
      w.u64(offset)
      w.u32(count)
    case .rread(let data):
      w.data(data)
    case .twrite(let fid, let offset, let data):
      w.u32(fid)
      w.u64(offset)
      w.data(data)
    case .rwrite(let count):
      w.u32(count)
    case .tclunk(let fid), .tremove(let fid), .tstat(let fid):
      w.u32(fid)
    case .rstat(let stat):
      w.stat(stat)
    case .twstat(let fid, let stat):
      w.u32(fid)
      w.stat(stat)
    }
    guard w.ok, w.bytes.count <= Int(UInt32.max) else { return nil }
    let size = UInt32(w.bytes.count)
    for i in 0..<4 { w.bytes[i] = UInt8(truncatingIfNeeded: size >> (8 * UInt32(i))) }
    return w.bytes
  }

  /// One message from exactly its bytes, or nil if they aren't one.
  public static func decode(_ bytes: [UInt8]) -> Message? {
    var r = Reader(bytes)
    guard let size = r.u32(), Int(size) == bytes.count, let type = r.u8(), let tag = r.u16() else { return nil }
    guard let fcall = body(type, &r), r.at == bytes.count else {
      // An extension's T-message this side can't read: answered, not fatal.
      guard type >= FcallType.firstExtension, type & 1 == 0 else { return nil }
      return Message(tag: tag, .unknown(type: type))
    }
    return Message(tag: tag, fcall)
  }

  /// The size a stream's next message announces, from its first four
  /// bytes, or nil if fewer than four have come or the size can't be a
  /// message's.
  public static func size(_ prefix: [UInt8]) -> Int? {
    var r = Reader(prefix)
    guard let size = r.u32(), size >= UInt32(NineP.header) else { return nil }
    return Int(size)
  }

  static func body(_ type: UInt8, _ r: inout Reader) -> Fcall? {
    switch type {
    case FcallType.tversion, FcallType.rversion:
      guard let msize = r.u32(), let version = r.string() else { return nil }
      return type == FcallType.tversion ? .tversion(msize: msize, version: version)
        : .rversion(msize: msize, version: version)
    case FcallType.tauth:
      guard let afid = r.u32(), let uname = r.string(), let aname = r.string() else { return nil }
      return .tauth(afid: afid, uname: uname, aname: aname)
    case FcallType.rauth:
      return r.qid().map { .rauth(aqid: $0) }
    case FcallType.tattach:
      guard let fid = r.u32(), let afid = r.u32(), let uname = r.string(), let aname = r.string() else { return nil }
      return .tattach(fid: fid, afid: afid, uname: uname, aname: aname)
    case FcallType.rattach:
      return r.qid().map { .rattach(qid: $0) }
    case FcallType.rerror:
      return r.string().map { .rerror(ename: $0) }
    case FcallType.tflush:
      return r.u16().map { .tflush(oldtag: $0) }
    case FcallType.rflush: return .rflush
    case FcallType.twalk:
      guard let fid = r.u32(), let newfid = r.u32(), let n = r.u16(), Int(n) <= NineP.maxWalk else { return nil }
      var names: [String] = []
      for _ in 0..<Int(n) {
        guard let name = r.string() else { return nil }
        names.append(name)
      }
      return .twalk(fid: fid, newfid: newfid, names: names)
    case FcallType.rwalk:
      guard let n = r.u16(), Int(n) <= NineP.maxWalk else { return nil }
      var qids: [Qid] = []
      for _ in 0..<Int(n) {
        guard let q = r.qid() else { return nil }
        qids.append(q)
      }
      return .rwalk(qids: qids)
    case FcallType.topen:
      guard let fid = r.u32(), let mode = r.u8() else { return nil }
      return .topen(fid: fid, mode: mode)
    case FcallType.ropen, FcallType.rcreate:
      guard let qid = r.qid(), let iounit = r.u32() else { return nil }
      return type == FcallType.ropen ? .ropen(qid: qid, iounit: iounit) : .rcreate(qid: qid, iounit: iounit)
    case FcallType.tcreate:
      guard let fid = r.u32(), let name = r.string(), let perm = r.u32(), let mode = r.u8() else { return nil }
      return .tcreate(fid: fid, name: name, perm: perm, mode: mode)
    case FcallType.tread:
      guard let fid = r.u32(), let offset = r.u64(), let count = r.u32() else { return nil }
      return .tread(fid: fid, offset: offset, count: count)
    case FcallType.rread:
      return r.data().map { .rread(data: $0) }
    case FcallType.twrite:
      guard let fid = r.u32(), let offset = r.u64(), let data = r.data() else { return nil }
      return .twrite(fid: fid, offset: offset, data: data)
    case FcallType.rwrite:
      return r.u32().map { .rwrite(count: $0) }
    case FcallType.tclunk:
      return r.u32().map { .tclunk(fid: $0) }
    case FcallType.rclunk: return .rclunk
    case FcallType.tremove:
      return r.u32().map { .tremove(fid: $0) }
    case FcallType.rremove: return .rremove
    case FcallType.tstat:
      return r.u32().map { .tstat(fid: $0) }
    case FcallType.rstat:
      return r.stat().map { .rstat(stat: $0) }
    case FcallType.twstat:
      guard let fid = r.u32(), let stat = r.stat() else { return nil }
      return .twstat(fid: fid, stat: stat)
    case FcallType.rwstat: return .rwstat
    case FcallType.trename:
      guard let fid = r.u32(), let newdirfid = r.u32(), let name = r.string() else { return nil }
      return .trename(fid: fid, newdirfid: newdirfid, name: name)
    case FcallType.rrename: return .rrename
    default: return nil
    }
  }
}

/// Little-endian fields into bytes; `ok` turns false when one can't be
/// sent (a count past its field's width).
struct Writer {
  var bytes: [UInt8] = []
  var ok = true

  mutating func u8(_ v: UInt8) { bytes.append(v) }
  mutating func u16(_ v: UInt16) { for i in 0..<2 { bytes.append(UInt8(truncatingIfNeeded: v >> (8 * UInt16(i)))) } }
  mutating func u32(_ v: UInt32) { for i in 0..<4 { bytes.append(UInt8(truncatingIfNeeded: v >> (8 * UInt32(i)))) } }
  mutating func u64(_ v: UInt64) { for i in 0..<8 { bytes.append(UInt8(truncatingIfNeeded: v >> (8 * UInt64(i)))) } }

  mutating func string(_ s: String) {
    let n = s.utf8.count
    guard n <= Int(UInt16.max) else {
      ok = false
      return
    }
    u16(UInt16(n))
    bytes.append(contentsOf: s.utf8)
  }

  mutating func qid(_ q: Qid) {
    u8(q.type)
    u32(q.version)
    u64(q.path)
  }

  mutating func data(_ d: [UInt8]) {
    guard d.count <= Int(UInt32.max) else {
      ok = false
      return
    }
    u32(UInt32(d.count))
    bytes.append(contentsOf: d)
  }

  mutating func stat(_ s: [UInt8]) {
    guard s.count <= Int(UInt16.max) else {
      ok = false
      return
    }
    u16(UInt16(s.count))
    bytes.append(contentsOf: s)
  }
}

/// Little-endian fields out of bytes, each nil if it doesn't fit.
struct Reader {
  let bytes: [UInt8]
  var at = 0

  init(_ bytes: [UInt8], at: Int = 0) {
    self.bytes = bytes
    self.at = at
  }

  var remaining: Int { bytes.count - at }

  mutating func take(_ n: Int) -> Range<Int>? {
    guard n >= 0, n <= remaining else { return nil }
    defer { at += n }
    return at..<at + n
  }

  mutating func u8() -> UInt8? { take(1).map { bytes[$0.lowerBound] } }

  mutating func u16() -> UInt16? {
    guard let r = take(2) else { return nil }
    return UInt16(bytes[r.lowerBound]) | UInt16(bytes[r.lowerBound + 1]) << 8
  }

  mutating func u32() -> UInt32? {
    guard let r = take(4) else { return nil }
    var v: UInt32 = 0
    for i in 0..<4 { v |= UInt32(bytes[r.lowerBound + i]) << (8 * UInt32(i)) }
    return v
  }

  mutating func u64() -> UInt64? {
    guard let r = take(8) else { return nil }
    var v: UInt64 = 0
    for i in 0..<8 { v |= UInt64(bytes[r.lowerBound + i]) << (8 * UInt64(i)) }
    return v
  }

  /// A count[2] and that many bytes of UTF-8, holding no NUL.
  mutating func string() -> String? {
    guard let n = u16(), let r = take(Int(n)) else { return nil }
    let raw = bytes[r]
    guard !raw.contains(0) else { return nil }
    let s = String(decoding: raw, as: UTF8.self)
    // Decoding repairs what isn't UTF-8; repaired text is longer or differs.
    guard s.utf8.count == raw.count, s.utf8.elementsEqual(raw) else { return nil }
    return s
  }

  mutating func qid() -> Qid? {
    guard let type = u8(), let version = u32(), let path = u64() else { return nil }
    return Qid(type: type, version: version, path: path)
  }

  mutating func data() -> [UInt8]? {
    guard let n = u32(), let r = take(Int(n)) else { return nil }
    return Array(bytes[r])
  }

  mutating func stat() -> [UInt8]? {
    guard let n = u16(), let r = take(Int(n)) else { return nil }
    return Array(bytes[r])
  }
}
