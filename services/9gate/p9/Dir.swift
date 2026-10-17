// SPDX-License-Identifier: BSD-3-Clause

// A file's stat, as stat(5) gives it: size[2] type[2] dev[4] qid[13]
// mode[4] atime[4] mtime[4] length[8] name[s] uid[s] gid[s] muid[s].
// Owners are strings (D78). Rstat and Twstat carry one; a directory's
// Rread carries whole ones, back to back. Twstat's "don't touch" is all
// ones in a number and empty in a string (`Dir.unchanged`).

/// A stat's mode bits beyond the permissions.
public enum DirMode {
  public static let dir: UInt32 = 0x8000_0000
  public static let append: UInt32 = 0x4000_0000
  public static let excl: UInt32 = 0x2000_0000
  public static let auth: UInt32 = 0x0800_0000
  public static let tmp: UInt32 = 0x0400_0000
}

/// Equal when their bytes are, as Fcall's messages are.
public struct Dir: Equatable, Sendable {
  /// The server's type and device; a file server's own are zero.
  public var type: UInt16 = 0
  public var dev: UInt32 = 0
  public var qid: Qid
  public var mode: UInt32
  public var atime: UInt32 = 0
  public var mtime: UInt32 = 0
  public var length: UInt64 = 0
  public var name: String
  public var uid: String
  public var gid: String
  public var muid: String

  public init(qid: Qid, mode: UInt32, length: UInt64 = 0, name: String, uid: String, gid: String = "",
              muid: String = "", atime: UInt32 = 0, mtime: UInt32 = 0) {
    self.qid = qid
    self.mode = mode
    self.length = length
    self.name = name
    self.uid = uid
    self.gid = gid.isEmpty ? uid : gid
    self.muid = muid.isEmpty ? uid : muid
    self.atime = atime
    self.mtime = mtime
  }

  public static func == (a: Dir, b: Dir) -> Bool { a.encode() == b.encode() }

  /// Twstat's template: every field left as it is.
  public static var unchanged: Dir {
    var d = Dir(qid: Qid(type: 0xff, version: .max, path: .max), mode: .max, name: "", uid: "")
    d.type = .max
    d.dev = .max
    d.atime = .max
    d.mtime = .max
    d.length = .max
    d.gid = ""
    d.muid = ""
    return d
  }

  /// The fixed part: everything but the four strings' bytes.
  static let fixed = 2 + 2 + 4 + Qid.size + 4 + 4 + 4 + 8 + 4 * 2

  /// Its bytes, its size first; nil if a string, or the whole, passes
  /// 65535 bytes.
  public func encode() -> [UInt8]? {
    var w = Writer()
    w.u16(0)
    w.u16(type)
    w.u32(dev)
    w.qid(qid)
    w.u32(mode)
    w.u32(atime)
    w.u32(mtime)
    w.u64(length)
    w.string(name)
    w.string(uid)
    w.string(gid)
    w.string(muid)
    let size = w.bytes.count - 2
    guard w.ok, size <= Int(UInt16.max) else { return nil }
    w.bytes[0] = UInt8(truncatingIfNeeded: size)
    w.bytes[1] = UInt8(truncatingIfNeeded: size >> 8)
    return w.bytes
  }

  /// One stat from exactly its bytes, or nil.
  public static func decode(_ bytes: [UInt8]) -> Dir? {
    var r = Reader(bytes)
    guard let d = next(&r), r.remaining == 0 else { return nil }
    return d
  }

  /// The stats of a directory's read, or nil if they aren't whole ones.
  public static func decodeAll(_ bytes: [UInt8]) -> [Dir]? {
    var r = Reader(bytes)
    var dirs: [Dir] = []
    while r.remaining > 0 {
      guard let d = next(&r) else { return nil }
      dirs.append(d)
    }
    return dirs
  }

  static func next(_ r: inout Reader) -> Dir? {
    guard let size = r.u16(), Int(size) >= fixed - 2, Int(size) <= r.remaining else { return nil }
    let end = r.at + Int(size)
    guard let type = r.u16(), let dev = r.u32(), let qid = r.qid(), let mode = r.u32(), let atime = r.u32(),
          let mtime = r.u32(), let length = r.u64(), let name = r.string(), let uid = r.string(),
          let gid = r.string(), let muid = r.string(), r.at == end
    else { return nil }
    var d = Dir(qid: qid, mode: mode, length: length, name: name, uid: uid, atime: atime, mtime: mtime)
    d.type = type
    d.dev = dev
    d.gid = gid
    d.muid = muid
    return d
  }
}
