// SPDX-License-Identifier: BSD-3-Clause

// The transmitter's AUX requests, its reads of the DPCD and the EDID
// against a sink of the test's, and what an EDID says (D146).

import DPTX
import DisplayDevice
import Testing

/// A sink: its DPCD, an EDID behind E-DDC, DEFERs before each answer.
struct FakeSink: AUXChannel {
  var dpcd = [UInt8](repeating: 0, count: 0x300)
  var edid: [UInt8] = []
  var defers = 0
  var pending = 0
  var offset = 0, segment = 0
  var log: [AUXRequest] = []

  mutating func transfer(_ r: AUXRequest) throws(AUXError) -> (AUXReply, [UInt8]) {
    log.append(r)
    if pending > 0 {
      pending -= 1
      return (.deferred, [])
    }
    pending = defers
    switch r.kind {
    case .nativeRead: return (.ack, Array(dpcd[Int(r.address)..<Int(r.address) + r.count]))
    case .nativeWrite: return (.ack, [])
    case .i2cWrite:
      if r.address == EDIDBus.segment, let s = r.data.first { segment = Int(s) }
      if r.address == EDIDBus.slave, let o = r.data.first { offset = segment * 256 + Int(o) }
      return (.ack, [])
    case .i2cRead:
      if !r.mot { segment = 0 }  // the stop resets the segment pointer
      guard r.count > 0 else { return (.ack, []) }
      guard offset + r.count <= edid.count else { return (.nack, []) }
      defer { offset += r.count }
      return (.ack, Array(edid[offset..<offset + r.count]))
    }
  }
}

/// An EDID block: `DEL`, product 0x4127, `U2720Q`, a preferred 3840x2160
/// at 60 Hz (533.28 MHz over 4000x2222), and `extensions` counted.
func edidBlock(extensions: UInt8 = 0) -> [UInt8] {
  var b = [UInt8](repeating: 0, count: 128)
  b[0..<8] = [0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0]
  let id: UInt16 = 4 << 10 | 5 << 5 | 12  // D E L
  b[8] = UInt8(id >> 8)
  b[9] = UInt8(id & 0xFF)
  b[10] = 0x27
  b[11] = 0x41
  // Detailed timing: 53328 x 10 kHz; 3840 + 160 blank; 2160 + 62 blank.
  b[54] = UInt8(53328 & 0xFF)
  b[55] = UInt8(53328 >> 8)
  b[56] = UInt8(3840 & 0xFF)
  b[57] = 160
  b[58] = UInt8(3840 >> 8) << 4
  b[59] = UInt8(2160 & 0xFF)
  b[60] = 62
  b[61] = UInt8(2160 >> 8) << 4
  // Monitor name descriptor.
  b[72 + 3] = 0xFC
  let name = Array("U2720Q\n      ".utf8)
  b[(72 + 5)..<(72 + 18)] = name[0..<13]
  b[126] = extensions
  b[127] = 0 &- b[0..<127].reduce(0, &+)
  return b
}

@Test func anAUXRequestsCommandWord() {
  #expect(AUXRequest.read(dpcd: 0x200, count: 16).command == 0x90F)
  #expect(AUXRequest.i2cRead(0x50, count: 16, mot: true).command == 0x50F)
  #expect(AUXRequest.i2cWrite(0x50, [0], mot: true).command == 0x400)
  // Address only: no data phase.
  #expect(AUXRequest.i2cRead(0x50, count: 0, mot: false).command == 0x1100)
  #expect(AUXReply(code: 0, i2c: true) == .ack)
  #expect(AUXReply(code: 2, i2c: false) == .deferred)
  #expect(AUXReply(code: 4, i2c: true) == .nack)
  #expect(AUXReply(code: 4, i2c: false) == .ack)
}

@Test func theDPCDAndTheEDIDAreReadThroughDefers() throws {
  var sink = FakeSink()
  sink.defers = 2
  sink.dpcd[0..<6] = [0x14, 0x14, 0x84, 0, 0, 0x01]
  sink.dpcd[0x200] = 0x01
  let block = edidBlock(extensions: 1)
  sink.edid = block + [UInt8](repeating: 0x02, count: 128)
  let caps = SinkCapabilities(try sink.readDPCD(0, count: 16))
  #expect(caps.text == "1.4 HBR2 x4, enhanced framing, branch")
  #expect(sinkCount(try sink.readDPCD(0x200, count: 1)[0]) == 1)
  let edid = try sink.readEDID()
  #expect(edid.count == 256)
  #expect(edid[128] == 0x02)
  // Each 16-byte read middle-of-transaction, each block ended by a stop.
  #expect(sink.log.filter { $0.kind == .i2cRead && $0.count == 16 }.allSatisfy { $0.mot })
  #expect(sink.log.filter { $0.kind == .i2cRead && $0.count == 0 }.count >= 2)
}

@Test func aSinkThatNacksIsAnError() {
  var sink = FakeSink()
  #expect(throws: AUXError.nack) { _ = try sink.readEDID() }
}

@Test func anEDIDNamesItsMonitorAndPreferredMode() throws {
  let e = try #require(EDID(edidBlock()))
  #expect(e.maker == "DEL" && e.name == "U2720Q" && e.product == 0x4127)
  #expect(e.preferred?.width == 3840 && e.preferred?.height == 2160)
  #expect(e.text == "DEL U2720Q, preferred 3840x2160 at 60.000 Hz")
  var bad = edidBlock()
  bad[20] ^= 1
  #expect(EDID(bad) == nil)
}


/// A sink that trains: clock recovery once its lanes are driven at swing
/// 1 (asked for at swing 0), then equalised on the first pattern.
struct TrainingSink: TrainingCore {
  var dpcd = [UInt8](repeating: 0, count: 0x700)
  var patterns: [UInt32] = []
  var drives: [(UInt8, UInt8)] = []
  var waited = 0

  mutating func setPattern(_ pattern: UInt32, scrambled: Bool) { patterns.append(pattern) }
  mutating func setDrive(swing: UInt8, preEmphasis: UInt8) { drives.append((swing, preEmphasis)) }
  mutating func wait(microseconds: Int) { waited += microseconds }

  mutating func transfer(_ r: AUXRequest) throws(AUXError) -> (AUXReply, [UInt8]) {
    switch r.kind {
    case .nativeWrite:
      for (i, b) in r.data.enumerated() { dpcd[Int(r.address) + i] = b }
      if r.address == 0x102 { settle() }
      return (.ack, [])
    case .nativeRead: return (.ack, Array(dpcd[Int(r.address)..<Int(r.address) + r.count]))
    default: return (.nack, [])
    }
  }

  /// The status 0x202-0x207 for the pattern and drive just written.
  mutating func settle() {
    let pattern = dpcd[0x102] & 0xF, swing = dpcd[0x103] & 3
    dpcd[0x202...0x207] = [0, 0, 0, 0, 0x11, 0x11]  // swing 1 asked for, every lane
    guard pattern != 0, swing >= 1 else { return }
    dpcd[0x202] = 0x11
    dpcd[0x203] = 0x11
    if pattern != 1 {
      dpcd[0x202] = 0x77
      dpcd[0x203] = 0x77
      dpcd[0x204] = 1
    }
  }
}

@Test func aLinkTrainsAgainAtItsRate() throws {
  var sink = TrainingSink()
  let caps: [UInt8] = [0x12, 0x14, 0x84, 0x80]  // 1.2, HBR2, x4 enhanced, TPS4
  let t = try sink.train(rate: 0x0A, lanes: 4, caps: caps, enhancedFraming: true, downspread: false)
  #expect(t.trained && t.swing == 1 && t.preEmphasis == 0)
  #expect(t.status.trained)
  // The rate and lanes configured, the sink awake, the pattern ended.
  #expect(sink.dpcd[0x100] == 0x0A && sink.dpcd[0x101] == 0x84 && sink.dpcd[0x600] == 1 && sink.dpcd[0x102] == 0)
  // TPS1, then TPS4 (the sink has it), then none.
  #expect(sink.patterns == [1, 4, 0])
  // Each step's drive levels went to the PHY before the sink: 0 first, then the 1 it asked for.
  #expect(sink.drives.first! == (0, 0) && sink.drives.last! == (1, 0))
  #expect(laneSet(swing: 3, preEmphasis: 0) == 0x07)
}

@Test func aLinkThatNeverRecoversFails() throws {
  // A sink that never recovers its clock, and asks for no more swing.
  struct Deaf: TrainingCore {
    var inner = TrainingSink()
    mutating func setPattern(_ p: UInt32, scrambled: Bool) {}
    mutating func wait(microseconds: Int) {}
    mutating func transfer(_ r: AUXRequest) throws(AUXError) -> (AUXReply, [UInt8]) {
      if r.kind == .nativeRead, r.address == 0x202 { return (.ack, [0, 0, 0, 0, 0, 0]) }
      return try inner.transfer(r)
    }
  }
  var deaf = Deaf()
  let t = try deaf.train(rate: 0x0A, lanes: 4, caps: [0x12, 0x14, 0x84], enhancedFraming: true, downspread: false)
  #expect(!t.trained && t.stage == "clock recovery" && t.tries <= 6)
}
