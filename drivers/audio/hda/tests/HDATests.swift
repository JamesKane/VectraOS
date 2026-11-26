// SPDX-License-Identifier: BSD-3-Clause

// HD Audio (D179) against a model controller and codec: the registers
// reached only by aligned words, narrow fields written by read-modify-
// write without clearing the status bits beside them; verbs, stream
// formats and connection lists encoded as the specification has them;
// the controller's reset, its CORB and polled RIRB; the codec's graph
// and its playback and capture paths; and a stream's BDL, its start at
// the first period and its periods counted from its position.

import AudioDevice
import DriverHost
import HDA
import Sys
import Testing

/// Memory the model reads where this process does: bus addresses are
/// addresses.
final class HostMemory: DMAMemory {
  var regions: [UnsafeMutableRawPointer] = []
  func allocate(bytes: Int) throws(Status) -> (pointer: UnsafeMutableRawPointer, bus: UInt64) {
    let p = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 4096)
    p.initializeMemory(as: UInt8.self, repeating: 0, count: bytes)
    regions.append(p)
    return (p, UInt64(UInt(bitPattern: p)))
  }
  deinit { for p in regions { p.deallocate() } }
}

/// A codec: an audio function group (node 1) of a DAC (2), a mixer (3)
/// fed by it, a line-out pin (4) fed by the mixer, an ADC (5) fed by a
/// microphone pin (6), and a headphone pin (7) fed by the mixer too.
final class ModelCodec {
  var sent: [(node: Int, verb: UInt32, payload: UInt32)] = []

  func respond(_ command: UInt32) -> UInt32 {
    let node = Int((command >> 20) & 0x7F)
    let v12 = (command >> 8) & 0xFFF
    let verb: UInt32, payload: UInt32
    if v12 >> 8 == 0xF || v12 >> 8 == 0x7 {
      (verb, payload) = (v12, command & 0xFF)
    } else {
      (verb, payload) = ((command >> 16) & 0xF, command & 0xFFFF)
    }
    sent.append((node, verb, payload))
    switch (verb, node, payload) {
    case (0xF00, 0, 0x00): return 0x10EC_0269
    case (0xF00, 0, 0x04): return 1 << 16 | 1
    case (0xF00, 1, 0x05): return 1
    case (0xF00, 1, 0x04): return 2 << 16 | 6
    case (0xF00, 1, 0x0A): return 1 << 17 | 1 << 18 | 1 << 19 | 1 << 5 | 1 << 6  // 16, 20, 24 bits; 44.1, 48 kHz
    case (0xF00, 1, 0x12): return 1 << 31 | 0x57 << 8 | 0x4A  // the group's output amplifiers
    case (0xF00, 1, 0x0D): return 1 << 31 | 0x1F << 8 | 0x10
    case (0xF00, 2, 0x09): return 0 << 20 | 1 << 2 | 1  // DAC: out amp, stereo
    case (0xF00, 3, 0x09): return 2 << 20 | 1 << 8 | 1 << 1 | 1  // mixer: connections, in amp
    case (0xF00, 4, 0x09): return 4 << 20 | 1 << 8 | 1 << 2 | 1  // pin: connections, out amp
    case (0xF00, 5, 0x09): return 1 << 20 | 1 << 8 | 1 << 1 | 1  // ADC: connections, in amp
    case (0xF00, 6, 0x09): return 4 << 20 | 1  // pin
    case (0xF00, 7, 0x09): return 4 << 20 | 1 << 8 | 1
    case (0xF00, 3, 0x0E), (0xF00, 4, 0x0E), (0xF00, 5, 0x0E), (0xF00, 7, 0x0E): return 1
    case (0xF02, 3, 0): return 2
    case (0xF02, 4, 0), (0xF02, 7, 0): return 3
    case (0xF02, 5, 0): return 6
    case (0xF00, 4, 0x0C), (0xF00, 7, 0x0C): return 1 << 4 | 1 << 16  // output, EAPD
    case (0xF00, 6, 0x0C): return 1 << 5  // input
    case (0xF1C, 4, _): return 0x0101_4010  // a line-out jack
    case (0xF1C, 6, _): return 0x01A1_9020  // a microphone jack
    case (0xF1C, 7, _): return 0x0221_401F  // headphones
    default: return 0
    }
  }
}

/// A controller: one input and one output stream descriptor, laid out as
/// the specification lays its registers out. Each register is written at
/// its own width; a word written at once (the Sky1's way) is split into
/// the registers it covers, each written with what the word holds for it.
/// The reset, the CORB and RIRB, and the write-1-to-clear status bits act
/// as a controller's do. It counts the accesses narrower than a word and
/// those that span two registers.
final class ModelHDA: HDAWindow {
  var bytes = [UInt8](repeating: 0, count: 0x400)
  var narrow = 0
  var spanning = 0
  /// Word accesses that covered registers narrower than a word.
  var across = 0
  let codec = ModelCodec()
  var corbRP: UInt16 = 0
  var rirbWP: UInt16 = 0
  var rpReset = false
  /// Responses since RIRBSTS's flag was last cleared: at RINTCNT the
  /// controller takes no more commands until it is (as QEMU's does).
  var counted = 0
  /// When the codec asks for an address: as the specification says, as
  /// QEMU's does (at power-on, not after a reset), or never.
  enum Announce { case afterReset, atPowerOn, never }
  let announce: Announce

  init(announce: Announce = .afterReset) {
    self.announce = announce
    if announce == .atPowerOn { put(0x0E, 2, 1) }
    put(0x00, 2, 0x1100)  // GCAP: 1 output, 1 input stream
    put(0x02, 1, 0)
    put(0x03, 1, 1)
  }

  /// The register at `o` and its width.
  static func register(_ o: Int) -> (start: Int, width: Int) {
    if o >= 0x80 {
      let r = (o - 0x80) % 0x20, base = o - r
      switch r {
      case 0..<2: return (base, 2)  // SDnCTL's low 16 bits
      case 2, 3: return (base + r, 1)  // its stream number byte, and SDnSTS
      case 0x0C..<0x14: return (base + r & ~1, 2)
      default: return (base + r & ~3, 4)
      }
    }
    switch o {
    case 0x00..<0x02, 0x0C..<0x10, 0x48..<0x4C, 0x58..<0x5C: return (o & ~1, 2)
    case 0x02, 0x03, 0x4C, 0x4D, 0x4E, 0x4F, 0x5C, 0x5D, 0x5E, 0x5F: return (o, 1)
    default: return (o & ~3, 4)
    }
  }

  func raw(_ o: Int, _ width: Int) -> UInt32 {
    (0..<width).reduce(UInt32(0)) { $0 | UInt32(bytes[o + $1]) << (8 * UInt32($1)) }
  }

  func put(_ o: Int, _ width: Int, _ v: UInt32) {
    for i in 0..<width { bytes[o + i] = UInt8(truncatingIfNeeded: v >> (8 * UInt32(i))) }
  }

  func get(_ o: Int, _ width: Int) -> UInt32 {
    switch o {
    case 0x4A: return UInt32(rpReset ? 0x8000 : corbRP)
    case 0x58: return UInt32(rirbWP)
    default: return raw(o, width)
    }
  }

  /// A write of register `o` (`width` bytes): its effects.
  func write(_ o: Int, _ width: Int, _ v: UInt32) {
    let old = raw(o, width)
    switch o {
    case 0x08:
      put(o, 4, v)
      if v & 1 == 0 && old & 1 != 0 { put(0x0E, 2, 0) }  // into reset: STATESTS cleared
      if v & 1 != 0 && old & 1 == 0 && announce == .afterReset { put(0x0E, 2, raw(0x0E, 2) | 1) }  // codec 0 asks
    case 0x0E: put(o, width, old & ~v)  // write-1-to-clear
    case 0x5D:
      put(o, width, old & ~v)
      if v & 1 != 0 {
        counted = 0
        process(UInt16(raw(0x48, 2) & 0xFF))
      }
    case 0x48:
      put(o, 2, v)
      process(UInt16(v & 0xFF))
    case 0x4A:
      rpReset = v & 0x8000 != 0
      if rpReset { corbRP = 0 }
    case 0x58:
      if v & 0x8000 != 0 { rirbWP = 0 }
    case let sts where sts >= 0x80 && (sts - 0x80) % 0x20 == 3:
      put(o, 1, old & ~v)  // SDnSTS: write-1-to-clear
    default:
      put(o, width, v)
    }
  }

  func load32(_ o: Int) -> UInt32 {
    precondition(o & 3 == 0)
    var v: UInt32 = 0
    var at = o
    while at < o + 4 {
      let r = Self.register(at)
      if r.width < 4 { across += 1 }
      v |= get(r.start, r.width) << (8 * UInt32(r.start - o))
      at = r.start + r.width
    }
    return v
  }

  func store32(_ o: Int, _ v: UInt32) {
    precondition(o & 3 == 0)
    var at = o
    while at < o + 4 {
      let r = Self.register(at)
      if r.width < 4 { across += 1 }
      let shift = 8 * UInt32(r.start - o)
      let mask: UInt32 = r.width == 4 ? 0xFFFF_FFFF : (1 << (8 * UInt32(r.width))) - 1
      write(r.start, r.width, (v >> shift) & mask)
      at = r.start + r.width
    }
  }

  func load16(_ o: Int) -> UInt16 {
    narrow += 1
    let r = Self.register(o)
    if r.width != 2 || r.start != o { spanning += 1 }
    return UInt16(truncatingIfNeeded: get(r.start, r.width) >> (8 * UInt32(o - r.start)))
  }

  func load8(_ o: Int) -> UInt8 {
    narrow += 1
    let r = Self.register(o)
    if r.width != 1 { spanning += 1 }
    return UInt8(truncatingIfNeeded: get(r.start, r.width) >> (8 * UInt32(o - r.start)))
  }

  func store16(_ o: Int, _ v: UInt16) {
    narrow += 1
    let r = Self.register(o)
    if r.width != 2 || r.start != o { spanning += 1 }
    write(o, 2, UInt32(v))
  }

  func store8(_ o: Int, _ v: UInt8) {
    narrow += 1
    if Self.register(o).width != 1 { spanning += 1 }
    write(o, 1, UInt32(v))
  }

  /// A word of registers as they read (SDnCTL's and the like).
  func word(_ o: Int) -> UInt32 { load32(o) }

  func at(_ lower: Int) -> UnsafeMutableRawPointer {
    UnsafeMutableRawPointer(bitPattern: UInt(UInt64(raw(lower, 4)) | UInt64(raw(lower + 4, 4)) << 32))!
  }

  func process(_ wp: UInt16) {
    guard raw(0x4C, 1) & 0x02 != 0 else { return }  // CORB not running
    let limit = Int(raw(0x5A, 2) & 0xFF) == 0 ? 256 : Int(raw(0x5A, 2) & 0xFF)
    while corbRP != wp, counted < limit {
      corbRP = (corbRP + 1) & 0xFF
      let command = at(0x40).load(fromByteOffset: 4 * Int(corbRP), as: UInt32.self)
      guard command >> 28 == 0 else { continue }  // only codec 0 is there
      let response = codec.respond(command)
      rirbWP = (rirbWP + 1) & 0xFF
      counted += 1
      if counted == limit { put(0x5D, 1, raw(0x5D, 1) | 1) }
      at(0x50).storeBytes(of: response, toByteOffset: 8 * Int(rirbWP), as: UInt32.self)
      at(0x50).storeBytes(of: command >> 28, toByteOffset: 8 * Int(rirbWP) + 4, as: UInt32.self)
    }
  }
}

func controller(_ model: ModelHDA, _ memory: HostMemory, wordOnly: Bool = false) throws -> HDAController {
  let c = try HDAController(model, memory: memory, wordOnly: wordOnly)
  c.pause = { _ in }
  return c
}

// MARK: Registers, verbs and formats

@Test func eachRegisterIsWrittenAtItsWidthAndStatusBitsAreLeftAlone() {
  let m = ModelHDA()
  let r = HDARegisters(m)
  m.put(0x5D, 1, 0x01)  // RIRBSTS's RINTFL set
  r.store8(Reg.rirbCtl, 0x02)
  #expect(m.raw(0x5C, 1) == 0x02 && m.raw(0x5D, 1) == 0x01)
  m.put(Reg.sd(1), 4, 0x0400_0002)  // BCIS set, RUN on
  r.setSdCtl(1, r.sdCtl(1) | Reg.ioce)
  #expect(r.sdSts(1) == Reg.bcis)
  r.clearSdSts(1, Reg.bcis)
  #expect(m.raw(Reg.sd(1), 4) == 0x0000_0006)
  r.store16(Reg.corbWP, 7)
  #expect(r.load16(Reg.corbWP) == 7)
  #expect(m.across == 0 && m.spanning == 0)
}

@Test func onlyWordsReachTheSky1sRegisters() {
  let m = ModelHDA()
  let r = HDARegisters(m, wordOnly: true)
  m.put(0x5D, 1, 0x01)
  m.put(0x5E, 1, 0x05)
  r.store8(Reg.rirbCtl, 0x02, clearMask: HDARegisters.rirbStsMask)
  #expect(m.raw(0x5C, 1) == 0x02 && m.raw(0x5D, 1) == 0x01 && m.raw(0x5E, 1) == 0x05)  // RINTFL kept
  m.put(0x0E, 2, 0x0001)
  #expect(r.load16(Reg.statests) == 1)  // from the word at 0x0C
  r.store16(Reg.corbWP, 9)
  #expect(r.load16(Reg.corbWP) == 9)
  #expect(m.narrow == 0)
}

@Test func verbsAndFormatsAreTheSpecificationsWords() {
  #expect(Verb.command(codec: 0, node: 2, verb: Verb.getParameter, payload: Parameter.widgetCaps) == 0x002F_0009)
  #expect(Verb.command(codec: 1, node: 0x14, verb: Verb.setAmp, payload: 0xB04A) == 0x1143_B04A)
  #expect(Verb.command(codec: 0, node: 3, verb: Verb.setFormat, payload: 0x4011) == 0x0032_4011)
  #expect(StreamFormat.word(PCMFormat(sample: .s16, channels: 2, rate: 44100)) == 0x4011)
  #expect(StreamFormat.word(PCMFormat(sample: .s16, channels: 2, rate: 48000)) == 0x0011)
  #expect(StreamFormat.word(PCMFormat(sample: .s24, channels: 2, rate: 96000)) == 0x0831)
  #expect(StreamFormat.word(PCMFormat(sample: .s32, channels: 8, rate: 8000)) == 0x0547)
  #expect(StreamFormat.word(PCMFormat(sample: .s16, channels: 2, rate: 12345)) == nil)
  #expect(StreamFormat.word(PCMFormat(sample: .f32, channels: 2, rate: 48000)) == nil)
  let caps = PCMBits.capabilities(1 << 17 | 1 << 20 | 1 << 5 | 1 << 6, channels: 1...2)
  #expect(caps == PCMCapabilities(samples: [.s16, .s32], rates: [44100, 48000], channels: 1...2))
}

@Test func connectionListsAreReadInEitherFormWithRanges() {
  // Short: 2, then a range to 5, then 7.
  #expect(CodecGraph.connections(length: 3) { _ in 0x02 | 0x85 << 8 | 0x07 << 16 } == [2, 3, 4, 5, 7])
  var asked: [UInt32] = []
  let six = CodecGraph.connections(length: 6) { i in
    asked.append(i)
    return i == 0 ? 0x0D0C_0B0A : 0x0F0E
  }
  #expect(six == [10, 11, 12, 13, 14, 15] && asked == [0, 4])
  // Long: two 16-bit entries a response.
  #expect(CodecGraph.connections(length: 0x82) { _ in 0x0011_0010 } == [16, 17])
}

// MARK: The controller and the codec

/// Each mode keeps to its accesses: the standard one never a word over
/// narrower registers, the Sky1's never anything narrower than a word.
func keptToItsAccesses(_ m: ModelHDA, wordOnly: Bool) -> Bool {
  wordOnly ? m.narrow == 0 : m.across == 0 && m.spanning == 0
}

@Test(arguments: [false, true])
func theControllerResetsFindsItsCodecAndAnswersCommands(wordOnly: Bool) throws {
  let m = ModelHDA(), memory = HostMemory()
  let c = try controller(m, memory, wordOnly: wordOnly)
  #expect(c.inputStreams == 1 && c.outputStreams == 1)
  try c.start()
  #expect(c.codecs == 1)
  #expect(m.raw(0x0E, 2) == 0)  // STATESTS cleared
  #expect(m.raw(0x4C, 1) == 0x02 && m.raw(0x4E, 1) == 0x02)  // CORB running, 256 entries
  #expect(m.raw(0x5C, 1) == 0x02)  // RIRB DMA on, its interrupt off
  #expect(try c.send(Verb.command(codec: 0, node: 0, verb: Verb.getParameter, payload: Parameter.vendor)) == 0x10EC_0269)
  for _ in 0..<300 {  // the rings wrap
    _ = try c.send(Verb.command(codec: 0, node: 1, verb: Verb.getParameter, payload: Parameter.functionType))
  }
  #expect(try c.send(Verb.command(codec: 0, node: 0, verb: Verb.getParameter, payload: Parameter.vendor)) == 0x10EC_0269)
  c.timeout = 1_000_000
  let absent = Verb.command(codec: 2, node: 0, verb: Verb.getParameter, payload: Parameter.vendor)
  #expect(throws: HDAError.noResponse(absent)) { try c.send(absent) }  // codec 2 isn't there
  #expect(keptToItsAccesses(m, wordOnly: wordOnly))
}

@Test(arguments: [ModelHDA.Announce.atPowerOn, .never])
func aCodecThatDoesntAskAfterTheResetIsStillFound(announce: ModelHDA.Announce) throws {
  let m = ModelHDA(announce: announce), memory = HostMemory()
  let c = try controller(m, memory)
  try c.start()
  #expect(c.codecs == 1)
  #expect(try c.send(Verb.command(codec: 0, node: 0, verb: Verb.getParameter, payload: Parameter.vendor)) == 0x10EC_0269)
}

@Test func theCodecsGraphGivesItsPlaybackAndCapturePaths() throws {
  let m = ModelHDA(), memory = HostMemory()
  let c = try controller(m, memory)
  try c.start()
  let g = try #require(CodecGraph.read(codec: 0) { try? c.send($0) })
  #expect(g.vendor == 0x10EC_0269 && g.afg == 1 && g.widgets.count == 6)
  #expect(g.widget(4)?.connections == [3] && g.widget(3)?.connections == [2])
  // Line out before headphones; the microphone the only input.
  #expect(g.outputPath() == [4, 3, 2])
  #expect(g.inputPath() == [5, 6])
  let verbs = g.setUp([4, 3, 2], output: true)
  func has(_ node: Int, _ verb: UInt32, _ payload: UInt32) -> Bool {
    verbs.contains(Verb.command(codec: 0, node: node, verb: verb, payload: payload))
  }
  #expect(has(1, Verb.setPowerState, 0))
  #expect(has(4, Verb.setPinControl, 0x40) && has(4, Verb.setEAPD, 0x02))
  #expect(has(4, Verb.setAmp, 0xB000 | 0x4A))  // the pin's output, unmuted at 0 dB
  #expect(has(3, Verb.setAmp, 0x7000 | 0x10))  // the mixer's input 0, from the DAC
  #expect(has(2, Verb.setAmp, 0xB000 | 0x4A))  // the DAC's output
  let capture = g.setUp([5, 6], output: false)
  #expect(capture.contains(Verb.command(codec: 0, node: 6, verb: Verb.setPinControl, payload: 0x20)))
  #expect(capture.contains(Verb.command(codec: 0, node: 5, verb: Verb.setAmp, payload: 0x7000 | 0x10)))
}

@Test(arguments: [false, true])
func aStreamRunsAtItsFirstPeriodAndCountsPeriodsFromItsPosition(wordOnly: Bool) throws {
  let m = ModelHDA(), memory = HostMemory()
  let audio = try HDAAudio(controller: try controller(m, memory, wordOnly: wordOnly), memory: memory)
  #expect(audio.paths.output == [4, 3, 2] && audio.paths.input == [5, 6] && audio.refused == 0)
  #expect(audio.capabilities(.output) == PCMCapabilities(samples: [.s16, .s24], rates: [44100, 48000], channels: 1...2))
  let told = Locked<[AudioDirection]>([])
  audio.finished = { d in told.withLock { $0.append(d) } }
  let buffer = try audio.prepare(.output, .plan9, periodBytes: 1024, periods: 8)
  #expect(buffer.count == 8192)
  // Output descriptor 1 (after the one input): its registers and BDL.
  let sd = Reg.sd(1)
  #expect(m.raw(sd + Reg.sdCBL, 4) == 8192)
  #expect(m.raw(sd + Reg.sdLVI, 2) == 7)
  #expect(m.raw(sd + Reg.sdFormat, 2) == 0x4011)
  #expect((m.raw(sd, 4) >> 20) & 0xF == 1)  // stream tag 1
  let bdl = m.at(sd + Reg.sdBDLLower)
  let base = UInt64(UInt(bitPattern: buffer.bytes.baseAddress!))
  for i in 0..<8 {
    #expect(bdl.load(fromByteOffset: 16 * i, as: UInt64.self) == base + UInt64(1024 * i))
    #expect(bdl.load(fromByteOffset: 16 * i + 8, as: UInt32.self) == 1024)
    #expect(bdl.load(fromByteOffset: 16 * i + 12, as: UInt32.self) == 1)
  }
  #expect(m.codec.sent.contains { $0.node == 2 && $0.verb == Verb.setFormat && $0.payload == 0x4011 })
  #expect(m.codec.sent.contains { $0.node == 2 && $0.verb == Verb.setStream && $0.payload == 0x10 })
  // Not running until the first period is handed.
  try audio.start(.output)
  #expect(m.raw(sd, 4) & Reg.run == 0)
  audio.hand(.output, slot: 0)
  #expect(m.raw(sd, 4) & Reg.run != 0)
  audio.hand(.output, slot: 1)
  // Two and a half periods played, one interrupt: two finished.
  m.put(sd + Reg.sdLPIB, 4, 2560)
  m.put(Reg.intsts, 4, 1 << 1)
  m.put(sd, 4, m.raw(sd, 4) | UInt32(Reg.bcis) << 24)
  audio.serviceInterrupt()
  #expect(told.withLock { $0 } == [.output, .output])
  #expect(m.raw(sd, 4) >> 24 == 0)  // BCIS cleared
  // Round the buffer: from period 2 to period 1 is seven.
  m.put(sd + Reg.sdLPIB, 4, 1100)
  audio.serviceInterrupt()
  #expect(told.withLock { $0.count } == 9)
  audio.stop(.output)
  #expect(m.raw(sd, 4) & (Reg.run | Reg.srst) == 0)
  #expect(keptToItsAccesses(m, wordOnly: wordOnly))
  #expect(throws: (any Error).self) { _ = try audio.prepare(.output, .plan9, periodBytes: 100, periods: 8) }
}
