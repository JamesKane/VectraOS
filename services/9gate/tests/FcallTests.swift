// SPDX-License-Identifier: BSD-3-Clause

// 9P2000's codec: bytes written by hand from intro(5), every type
// through ours and back, the strictness a hostile peer needs, and
// 9front's fcall(2) as the oracle: what we write, convM2S reads and
// convS2M writes again to the same bytes, and changed bytes we take,
// it takes too (D89's pattern).

import FcallOracle
@testable import NineP
import Testing

func reencoded(_ bytes: [UInt8], stat: Bool = false) -> [UInt8]? {
  var out = [UInt8](repeating: 0, count: bytes.count + 64)
  let n = bytes.withUnsafeBufferPointer { i in
    out.withUnsafeMutableBufferPointer { o in
      stat ? fcall_oracle_reencode_stat(i.baseAddress, UInt32(i.count), o.baseAddress, UInt32(o.count))
        : fcall_oracle_reencode(i.baseAddress, UInt32(i.count), o.baseAddress, UInt32(o.count))
    }
  }
  return n == 0 ? nil : Array(out.prefix(Int(n)))
}

@Test func fcallWritesIntro5sBytes() {
  // size[4] Tversion tag[2] msize[4] version[s]
  #expect(Message(tag: NineP.noTag, .tversion(msize: 8192, version: "9P2000")).encode()
    == [19, 0, 0, 0, 100, 0xff, 0xff, 0x00, 0x20, 0, 0, 6, 0, 0x39, 0x50, 0x32, 0x30, 0x30, 0x30])
  // Twalk tag fid newfid nwname[2] "a" "bc"
  #expect(Message(tag: 1, .twalk(fid: 2, newfid: 3, names: ["a", "bc"])).encode()
    == [24, 0, 0, 0, 110, 1, 0, 2, 0, 0, 0, 3, 0, 0, 0, 2, 0, 1, 0, 0x61, 2, 0, 0x62, 0x63])
  // Rerror's ename; Rclunk is the header alone.
  #expect(Message(tag: 9, .rerror(ename: "no")).encode() == [11, 0, 0, 0, 107, 9, 0, 2, 0, 0x6e, 0x6f])
  #expect(Message(tag: 9, .rclunk).encode() == [7, 0, 0, 0, 121, 9, 0])
}

/// One message of every type, its fields from `rng`.
func everyType(_ rng: inout Seeded) -> [Message] {
  func s() -> String {
    let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789._-é→".unicodeScalars)
    var out = ""
    for _ in 0..<Int.random(in: 0...12, using: &rng) { out.unicodeScalars.append(alphabet.randomElement(using: &rng)!) }
    return out
  }
  func u32() -> UInt32 { UInt32.random(in: 0...UInt32.max, using: &rng) }
  func u64() -> UInt64 { UInt64.random(in: 0...UInt64.max, using: &rng) }
  func u8() -> UInt8 { UInt8.random(in: 0...255, using: &rng) }
  func qid() -> Qid { Qid(type: u8(), version: u32(), path: u64()) }
  func data() -> [UInt8] { rng.bytes(Int.random(in: 0...300, using: &rng)) }
  func stat() -> [UInt8] {
    Dir(qid: qid(), mode: u32(), length: u64(), name: s(), uid: s(), gid: s(), muid: s(), atime: u32(),
        mtime: u32()).encode()!
  }
  let walk = (0..<Int.random(in: 0...16, using: &rng)).map { _ in s() }
  let qids = (0..<Int.random(in: 0...16, using: &rng)).map { _ in qid() }
  let bodies: [Fcall] = [
    .tversion(msize: u32(), version: s()), .rversion(msize: u32(), version: s()),
    .tauth(afid: u32(), uname: s(), aname: s()), .rauth(aqid: qid()),
    .tattach(fid: u32(), afid: u32(), uname: s(), aname: s()), .rattach(qid: qid()),
    .rerror(ename: s()), .tflush(oldtag: UInt16(truncatingIfNeeded: u32())), .rflush,
    .twalk(fid: u32(), newfid: u32(), names: walk), .rwalk(qids: qids),
    .topen(fid: u32(), mode: u8()), .ropen(qid: qid(), iounit: u32()),
    .tcreate(fid: u32(), name: s(), perm: u32(), mode: u8()), .rcreate(qid: qid(), iounit: u32()),
    .tread(fid: u32(), offset: u64(), count: u32()), .rread(data: data()),
    .twrite(fid: u32(), offset: u64(), data: data()), .rwrite(count: u32()),
    .tclunk(fid: u32()), .rclunk, .tremove(fid: u32()), .rremove, .tstat(fid: u32()),
    .rstat(stat: stat()), .twstat(fid: u32(), stat: stat()), .rwstat,
  ]
  return bodies.map { Message(tag: UInt16(truncatingIfNeeded: u32()), $0) }
}

@Test func fcallAgreesWithNinefront() throws {
  var rng = Seeded(10)
  var types = Set<UInt8>()
  for _ in 0..<40 {
    for m in everyType(&rng) {
      let bytes = try #require(m.encode())
      #expect(Message.decode(bytes) == m)
      #expect(Message.size(Array(bytes.prefix(4))) == bytes.count)
      #expect(reencoded(bytes) == bytes, "\(m)")
      types.insert(m.fcall.type)
    }
  }
  #expect(types.count == 27)  // 100 to 127 but Terror
}

@Test func fcallTakesOnlyWhatNinefrontTakes() throws {
  var rng = Seeded(11)
  var taken = 0, refused = 0
  for _ in 0..<60 {
    for m in everyType(&rng) {
      var bytes = try #require(m.encode())
      // A changed byte past the size, or the size and the end moved
      // together (a field's count grown or shrunk to match).
      if Bool.random(using: &rng), bytes.count > 7 {
        bytes[Int.random(in: 4..<bytes.count, using: &rng)] ^= UInt8.random(in: 1...255, using: &rng)
      } else {
        let cut = Int.random(in: 0...min(8, bytes.count - 7), using: &rng)
        bytes.removeLast(cut)
        bytes.append(contentsOf: rng.bytes(Int.random(in: 0...4, using: &rng)))
        let n = UInt32(bytes.count)
        for i in 0..<4 { bytes[i] = UInt8(truncatingIfNeeded: n >> (8 * UInt32(i))) }
      }
      let ours = Message.decode(bytes)
      let theirs = reencoded(bytes)
      if let ours {
        // Ours reads it as 9front does: 9front writes it back unchanged,
        // and so do we.
        #expect(theirs == bytes, "\(bytes)")
        #expect(ours.encode() == bytes)
        taken += 1
      } else {
        refused += 1
        // Where 9front takes what we don't, it is a string we refuse.
        if theirs == bytes { #expect(holdsBadString(bytes), "\(bytes)") }
      }
    }
  }
  #expect(taken > 100 && refused > 100)
}

/// Whether a message's strings, read laxly, hold a NUL or bad UTF-8:
/// what ours refuses beyond 9front's checks.
func holdsBadString(_ bytes: [UInt8]) -> Bool {
  func bad(_ b: ArraySlice<UInt8>) -> Bool {
    b.contains(0) || !String(decoding: b, as: UTF8.self).utf8.elementsEqual(b)
  }
  var r = Reader(bytes, at: 4)
  guard let type = r.u8(), r.u16() != nil else { return false }
  func string() -> Bool {
    guard let n = r.u16(), let range = r.take(Int(n)) else { return false }
    return bad(bytes[range])
  }
  func stat() -> Bool {
    guard let n = r.u16(), let range = r.take(Int(n)) else { return false }
    var s = Reader(Array(bytes[range]), at: 2 + 2 + 4 + 13 + 4 + 4 + 4 + 8)
    for _ in 0..<4 {
      guard let n = s.u16(), let range = s.take(Int(n)) else { return false }
      if bad(s.bytes[range]) { return true }
    }
    return false
  }
  switch type {
  case FcallType.tversion, FcallType.rversion: _ = r.u32(); return string()
  case FcallType.tauth: _ = r.u32(); return string() || string()
  case FcallType.tattach: _ = r.u64(); return string() || string()
  case FcallType.rerror: return string()
  case FcallType.twalk:
    _ = r.u64()
    guard let n = r.u16() else { return false }
    return (0..<n).contains { _ in string() }
  case FcallType.tcreate: _ = r.u32(); return string()
  case FcallType.rstat: return stat()
  case FcallType.twstat: _ = r.u32(); return stat()
  default: return false
  }
}

@Test func fcallIsStrict() throws {
  let good = try #require(Message(tag: 1, .twalk(fid: 2, newfid: 3, names: ["a"])).encode())
  #expect(Message.decode(good) != nil)
  #expect(Message.decode(Array(good.dropLast())) == nil)  // short
  #expect(Message.decode(good + [0]) == nil)  // a byte past the size
  var big = good
  big[0] += 1
  #expect(Message.decode(big + [0]) == nil)  // a byte past the last field
  #expect(Message.decode([]) == nil)
  #expect(Message.decode([7, 0, 0, 0, 106, 0, 0]) == nil)  // Terror
  #expect(Message.decode([7, 0, 0, 0, 200, 0, 0]) == nil)  // no such type
  #expect(Message.size([6, 0, 0, 0]) == nil)
  // Seventeen names, or qids.
  #expect(Message(tag: 1, .twalk(fid: 1, newfid: 2, names: Array(repeating: "x", count: 17))).encode() == nil)
  #expect(Message(tag: 1, .rwalk(qids: Array(repeating: Qid(path: 1), count: 17))).encode() == nil)
  var walk = try #require(Message(tag: 1, .twalk(fid: 1, newfid: 2, names: Array(repeating: "x", count: 16))).encode())
  #expect(Message.decode(walk) != nil)
  walk[15] = 17
  #expect(Message.decode(walk) == nil)
  // A NUL in a string, and bytes that aren't UTF-8.
  #expect(Message.decode([11, 0, 0, 0, 107, 0, 0, 2, 0, 0x61, 0]) == nil)
  #expect(Message.decode([11, 0, 0, 0, 107, 0, 0, 2, 0, 0xc3, 0x28]) == nil)
  #expect(Message.decode([11, 0, 0, 0, 107, 0, 0, 2, 0, 0xc3, 0xa9]) == Message(tag: 0, .rerror(ename: "é")))
  // A string past 65535 bytes can't be written.
  #expect(Message(tag: 1, .rerror(ename: String(repeating: "x", count: 65536))).encode() == nil)
}

@Test func dirAgreesWithNinefront() throws {
  var rng = Seeded(12)
  var all: [Dir] = []
  for n in 0..<200 {
    var d = Dir(qid: Qid(type: QidType.dir, version: UInt32(n), path: UInt64(n) << 32 | 7), mode: DirMode.dir | 0o755,
                length: UInt64.random(in: 0...UInt64.max, using: &rng), name: "dir\(n)", uid: "glenda",
                gid: n % 2 == 0 ? "" : "sys", muid: "bootes", atime: UInt32(n), mtime: UInt32(n * 2))
    d.type = UInt16(n)
    d.dev = UInt32(n * 3)
    let bytes = try #require(d.encode())
    #expect(Dir.decode(bytes) == d)
    #expect(reencoded(bytes, stat: true) == bytes)
    all.append(d)
  }
  #expect(Dir.decodeAll(all.flatMap { $0.encode()! }) == all)
  #expect(Dir.decodeAll([]) == [])
  let one = try #require(all[0].encode())
  #expect(Dir.decode(Array(one.dropLast())) == nil)
  #expect(Dir.decode(one + [0]) == nil)
  #expect(Dir.decodeAll(one + Array(one.dropLast())) == nil)
  // Twstat's "don't touch" is all ones and empty strings.
  let unchanged = try #require(Dir.unchanged.encode())
  #expect(unchanged.count == Dir.fixed)
  #expect(unchanged[2..<unchanged.count - 8].allSatisfy { $0 == 0xff })
  #expect(Dir.decode(unchanged) == Dir.unchanged)
  #expect(reencoded(unchanged, stat: true) == unchanged)
}

@Test func versionAnswersTheDialect() {
  #expect(Version.dialect("9P2000") == "9P2000")
  #expect(Version.dialect("9P2000.vx") == "9P2000.vx")
  #expect(Version.dialect("9P2000.L") == "9P2000")
  #expect(Version.dialect("9P2000.u") == "9P2000")
  #expect(Version.dialect("9P2000.vxx") == "9P2000")
  #expect(Version.dialect("9P2001") == nil)
  #expect(Version.dialect("9P") == nil)
  #expect(Version.dialect("") == nil)
  let a = Version.answer("9P2000.vx", msize: 1 << 20, ours: 65536)
  #expect(a?.version == "9P2000.vx" && a?.msize == 65536)
  let plain = Version.answer("9P2000.vx", msize: 8192, ours: 65536, extended: false)
  #expect(plain?.version == "9P2000" && plain?.msize == 8192)
  #expect(Version.answer("9P2000.L", msize: 8192, ours: 65536)?.version == "9P2000")
  #expect(Version.answer("SMB", msize: 8192, ours: 65536)?.version == "unknown")
  #expect(Version.answer("9P2000", msize: 100, ours: 65536) == nil)
}
