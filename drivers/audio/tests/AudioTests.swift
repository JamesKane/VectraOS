// SPDX-License-Identifier: BSD-3-Clause

// The audio class (D179, D180) over a model device that records what it
// is handed and finishes periods when a test says: the formats and what a
// device can take, a cycle's counts (playback handed ahead, silence where
// a writer was late, the drain, capture's overruns), the unit's files
// through Node, and virtio-snd's messages.

import AudioDevice
import IPC
import Node
import Sys
import Testing
import VirtioSnd

// MARK: Formats

@Test func formatsAreNamedAsNinefrontNamesThem() {
  #expect(SampleFormat.named("s16") == .s16)
  #expect(SampleFormat.named("f32") == .f32)
  #expect(SampleFormat.named("s17") == nil)
  #expect(PCMFormat.plan9 == PCMFormat(sample: .s16, channels: 2, rate: 44100))
  #expect(PCMFormat.plan9.frameBytes == 4)
  #expect(PCMFormat(sample: .s24, channels: 6, rate: 48000).frameBytes == 24)
  #expect(SampleFormat.u8.silence == 0x80 && SampleFormat.s16.silence == 0)
}

@Test func theNearestFormatADeviceTakes() {
  let caps = PCMCapabilities(samples: [.s32, .s16], rates: [48000, 96000], channels: 1...2)
  #expect(caps.allows(PCMFormat(sample: .s16, channels: 2, rate: 48000)))
  #expect(!caps.allows(.plan9))
  #expect(caps.nearest(.plan9) == PCMFormat(sample: .s16, channels: 2, rate: 48000))
  #expect(caps.nearest(PCMFormat(sample: .f32, channels: 8, rate: 88200))
    == PCMFormat(sample: .s16, channels: 2, rate: 96000))
  let wide = PCMCapabilities(samples: [.s8, .s32], rates: [44100], channels: 2...2)
  #expect(wide.nearest(.plan9)?.sample == .s32)
  #expect(caps.line(.output) == "out formats s32 s16 rates 48000 96000 channels 1-2")
}

@Test func commandLinesSplitIntoWords() {
  #expect(AudioText.lines("speed 48000\n\n format\ts16  2\r\n") == [["speed", "48000"], ["format", "s16", "2"]])
  #expect(AudioText.number("48000") == 48000)
  #expect(AudioText.number("48k") == nil)
  #expect(AudioText.number("") == nil)
}

// MARK: The cycle

@Test func playbackIsHandedLeadPeriodsAhead() {
  var c = Cycle(.output, periods: 4, periodBytes: 100, lead: 2)
  #expect(c.writable() == (0, 400))
  c.wrote(250)
  #expect(c.buffered == 250)
  #expect(c.wantsPeriod)
  #expect(c.hand() == (0, 100))
  #expect(c.hand() == (1, 100))
  #expect(!c.wantsPeriod)
  // Two periods with the device, two free behind the written bytes.
  #expect(c.writable() == (250, 150))
  c.finish()
  #expect(c.writable() == (250, 150))
  c.wrote(150)
  #expect(c.writable() == (0, 100))
  #expect(c.hand() == (2, 100))
  #expect(c.hand() == (3, 100))
  #expect(c.underruns == 0)
}

@Test func aLateWriterIsHeardAsSilenceAndCountedOnceItGoesOn() {
  var c = Cycle(.output, periods: 4, periodBytes: 100, lead: 2)
  c.wrote(150)
  #expect(c.hand() == (0, 100))
  #expect(c.hand() == (1, 50))  // half silence
  c.finish()
  #expect(c.hand() == (2, 0))  // all silence
  #expect(c.underruns == 0)
  // The writer comes back: its bytes start after what was handed.
  #expect(c.writable() == (300, 100))
  c.wrote(100)
  c.finish()
  #expect(c.hand() == (3, 100))
  #expect(c.underruns == 2)
}

@Test func playbackDrainsLeadPeriodsOfSilenceAfterItsLastData() {
  var c = Cycle(.output, periods: 4, periodBytes: 100, lead: 2)
  c.wrote(100)
  _ = c.hand()
  #expect(!c.draining)
  _ = c.hand()
  #expect(!c.draining)
  c.finish()
  _ = c.hand()
  #expect(c.draining && !c.drained)
  c.finish()
  c.finish()
  #expect(c.drained)
  // The drain's silence is no underrun.
  c.stopped()
  #expect(c.underruns == 0)
  #expect(c.buffered == 0)
}

@Test func captureDropsTheOldestPeriodWhenTheReaderFallsABufferBehind() {
  var c = Cycle(.input, periods: 4, periodBytes: 100, lead: 2)
  #expect(c.readable().count == 0)
  for _ in 0..<4 {
    _ = c.hand()
    c.finish()
  }
  #expect(c.readable() == (0, 400))
  c.read(50)
  #expect(c.readable() == (50, 350))
  // Period 4 goes where period 0 is, half of it unread.
  #expect(c.hand() == (0, 100))
  #expect(c.overruns == 1)
  #expect(c.readable() == (100, 300))
  c.finish()
  #expect(c.readable() == (100, 300))
  c.read(300)
  #expect(c.readable() == (0, 100))
}

// MARK: The unit

/// A device that records what it is set up for and handed, and finishes
/// nothing until a test tells the unit so.
final class ModelAudio: AudioHardware, @unchecked Sendable {
  let name = "model"
  let maxBufferBytes = 64 * 1024
  let externalDelay = 16
  let output: PCMCapabilities?
  let input: PCMCapabilities?
  let lock = Lock()
  var prepared: [(AudioDirection, PCMFormat, Int, Int)] = []
  var started: [AudioDirection] = []
  var stopped: [AudioDirection] = []
  var handed: [(AudioDirection, Int)] = []
  var buffers: [UnsafeMutableRawBufferPointer] = []

  init(output: PCMCapabilities? = PCMCapabilities(samples: [.s16, .s32], rates: [44100, 48000], channels: 1...2),
       input: PCMCapabilities? = PCMCapabilities(samples: [.s16, .s32], rates: [44100, 48000], channels: 1...2)) {
    self.output = output
    self.input = input
  }

  func capabilities(_ d: AudioDirection) -> PCMCapabilities? { d == .output ? output : input }

  func prepare(_ d: AudioDirection, _ format: PCMFormat, periodBytes: Int, periods: Int)
    throws(NodeIPC.NodeError) -> AudioBuffer
  {
    // A VMO, so that it can be lent.
    let size = (periodBytes * periods + 4095) & ~4095
    guard let vmo = try? VMO.create(size: size), let mapping = try? VMO.map(vmo, length: size) else { throw .io }
    let b = UnsafeMutableRawBufferPointer(start: mapping.address, count: periodBytes * periods)
    b.initializeMemory(as: UInt8.self, repeating: 0xEE)
    let region = Region(vmo, mapping)
    lock.withLock {
      prepared.append((d, format, periodBytes, periods))
      buffers.append(b)
      regions.append(region)
    }
    return AudioBuffer(b)
  }

  final class Region {
    let vmo: Handle
    let mapping: Mapping
    init(_ vmo: consuming Handle, _ mapping: consuming Mapping) {
      self.vmo = vmo
      self.mapping = mapping
    }
  }
  var regions: [Region] = []
  var lent = 0

  func lend(_ d: AudioDirection) throws(NodeIPC.NodeError) -> Handle {
    guard let r = lock.withLock({ regions.last }), let h = try? r.vmo.duplicate() else { throw .unsupported }
    lock.withLock { lent += 1 }
    return h
  }

  func start(_ d: AudioDirection) throws(NodeIPC.NodeError) { lock.withLock { started.append(d) } }
  func hand(_ d: AudioDirection, slot: Int) { lock.withLock { handed.append((d, slot)) } }
  func stop(_ d: AudioDirection) { lock.withLock { stopped.append(d) } }

  var handedSlots: [Int] { lock.withLock { handed.map { $0.1 } } }
  var lastBuffer: UnsafeMutableRawBufferPointer { lock.withLock { buffers.last! } }
}

final class ServedAudio: @unchecked Sendable {
  let unit: AudioUnit
  let control: IPCDispatcher
  let data: IPCDispatcher

  init(_ hardware: AudioHardware) throws {
    control = try IPCDispatcher()
    data = try IPCDispatcher()
    unit = AudioUnit(hardware, control: control, data: data)
    let c = control, d = data
    _ = try Sys.Thread.spawn { try? c.run() }.release()
    _ = try Sys.Thread.spawn { try? d.run() }.release()
  }

  func open(_ name: String) throws -> NodeIPC.NodeClient {
    var dir = NodeIPC.NodeClient(channel: try unit.channel())
    return try dir.open(name)
  }

  func text(_ name: String) throws -> String {
    var f = try open(name)
    return String(decoding: try f.read(offset: 0, max: 4096), as: UTF8.self)
  }

  func write(_ name: String, _ text: String) throws {
    var f = try open(name)
    _ = try f.write(offset: 0, Array(text.utf8))
  }

  deinit {
    control.stop()
    data.stop()
  }
}

func lines(_ s: String) -> [String] { s.split(separator: "\n").map(String.init) }

@Test func theDirectoryHasNinefrontsFiles() throws {
  let served = try ServedAudio(ModelAudio())
  let ns = Namespace()
  try ns.mount(try served.unit.channel(), at: "/audio")
  #expect(try ns.list("/audio").map(\.name) == ["ctl", "stat", "volume", "data", "lease"])
  #expect(try served.text("ctl") == "speed 44100\nformat s16 2\nperiod 1024\n")
  #expect(try served.text("volume") == "speed 44100\ndelay \(1024 * 2 + 16)\n")
  let stat = lines(try served.text("stat"))
  #expect(stat[0] == "bufsize  32768 buffered      0 offset          0 time                   0")
  #expect(stat.contains("device model"))
  #expect(stat.contains("out formats s16 s32 rates 44100 48000 channels 1-2"))
  #expect(stat.contains("out stopped runs 0 periods 0 underruns 0"))
  #expect(stat.contains("in stopped runs 0 periods 0 overruns 0"))
}

@Test func ctlSetsTheFormatTheDeviceTakesAndRefusesTheRest() throws {
  let served = try ServedAudio(ModelAudio())
  try served.write("ctl", "speed 48000\nformat s32 1\nperiod 256\n")
  #expect(try served.text("ctl") == "speed 48000\nformat s32 1\nperiod 256\n")
  try served.write("volume", "speed 44100")
  #expect(try served.text("ctl") == "speed 44100\nformat s32 1\nperiod 256\n")
  #expect(fails(.unsupported) { try served.write("ctl", "speed 8000") })
  #expect(fails(.unsupported) { try served.write("ctl", "format f32") })
  #expect(fails(.invalid) { try served.write("ctl", "period 100") })
  #expect(fails(.invalid) { try served.write("ctl", "period 16384") })
  #expect(fails(.invalid) { try served.write("ctl", "louder") })
  #expect(fails(.unsupported) { try served.write("volume", "audio 50") })
  #expect(fails(.denied) { try served.write("stat", "x") })
}

@Test func aDeviceThatCantTakeNinefrontsFormatStartsAtItsNearest() throws {
  let caps = PCMCapabilities(samples: [.s32], rates: [48000], channels: 2...8)
  let served = try ServedAudio(ModelAudio(output: caps, input: nil))
  #expect(try served.text("ctl") == "speed 48000\nformat s32 2\nperiod 1024\n")
  var data = try served.open("data")
  #expect(fails(.unsupported) { try data.read(offset: 0, max: 16) })
}

@Test func aWriteStartsPlaybackAndTheStreamStopsOnceDrained() throws {
  let model = ModelAudio()
  let served = try ServedAudio(model)
  try served.write("ctl", "period 32")  // 128-byte periods
  var data = try served.open("data")
  let bytes = (0..<300).map { UInt8(truncatingIfNeeded: $0) }
  #expect(try data.write(offset: 0, bytes) == 300)
  #expect(model.lock.withLock { model.prepared.count == 1 && model.prepared[0].2 == 128 && model.prepared[0].3 == 8 })
  #expect(model.lock.withLock { model.started } == [.output])
  #expect(model.handedSlots == [0, 1])
  let b = model.lastBuffer
  #expect(Array(b[0..<300]) == bytes)
  #expect(lines(try served.text("stat")).contains("out running runs 1 periods 0 underruns 0"))
  // The device plays: period 2 is handed with 44 bytes and 84 of silence,
  // then two periods of silence, and the stream stops with none held.
  served.unit.finished(.output)
  #expect(model.handedSlots == [0, 1, 2])
  #expect(Array(b[300..<384]) == [UInt8](repeating: 0, count: 84))
  served.unit.finished(.output)
  served.unit.finished(.output)
  served.unit.finished(.output)
  #expect(model.handedSlots == [0, 1, 2, 3, 4])
  #expect(model.lock.withLock { model.stopped }.isEmpty)
  served.unit.finished(.output)
  #expect(model.lock.withLock { model.stopped } == [.output])
  let stat = lines(try served.text("stat"))
  #expect(stat.contains("out stopped runs 1 periods 5 underruns 0"))
  #expect(stat[0].hasPrefix("bufsize   1024 buffered      0 offset        640"))
  // A second write starts it again where it left off.
  #expect(try data.write(offset: 0, bytes) == 300)
  #expect(model.lock.withLock { model.started } == [.output, .output])
  #expect(model.handedSlots == [0, 1, 2, 3, 4, 5, 6])
}

@Test func aWriteWaitsForRoomAsTheDevicePlays() throws {
  let model = ModelAudio()
  let served = try ServedAudio(model)
  try served.write("ctl", "period 32")
  var data = try served.open("data")
  // Eight periods fill the buffer; a ninth waits for the device.
  #expect(try data.write(offset: 0, [UInt8](repeating: 1, count: 1024)) == 1024)
  let unit = served.unit
  _ = try Sys.Thread.spawn {
    sleep(until: Clock.monotonic() + 50_000_000)
    unit.finished(.output)
  }.release()
  let before = Clock.monotonic()
  #expect(try data.write(offset: 0, [UInt8](repeating: 2, count: 128)) == 128)
  #expect(Clock.monotonic() - before >= 40_000_000)
  #expect(Array(model.lastBuffer[0..<128]) == [UInt8](repeating: 2, count: 128))
}

@Test func aReadStartsCaptureAndWaitsForThePeriodTheDeviceFills() throws {
  let model = ModelAudio()
  let served = try ServedAudio(model)
  try served.write("ctl", "period 32")
  var data = try served.open("data")
  let unit = served.unit
  _ = try Sys.Thread.spawn {
    var buffer: UnsafeMutableRawBufferPointer?
    while buffer == nil {
      sleep(until: Clock.monotonic() + 5_000_000)
      buffer = model.lock.withLock { model.buffers.last }
    }
    sleep(until: Clock.monotonic() + 20_000_000)
    for i in 0..<128 { buffer![i] = UInt8(i) }
    unit.finished(.input)
  }.release()
  let got = try data.read(offset: 0, max: 4096)
  #expect(got == (0..<128).map { UInt8($0) })
  #expect(model.lock.withLock { model.started } == [.input])
  #expect(model.handedSlots == [0, 1, 2])
  try served.write("ctl", "stop in")
  #expect(model.lock.withLock { model.stopped } == [.input])
  #expect(lines(try served.text("stat")).contains("in stopped runs 1 periods 1 overruns 0"))
}

@Test func aChangeOfFormatStopsARunningStream() throws {
  let model = ModelAudio()
  let served = try ServedAudio(model)
  var data = try served.open("data")
  _ = try data.write(offset: 0, [UInt8](repeating: 0, count: 4096))
  try served.write("ctl", "speed 48000")
  #expect(model.lock.withLock { model.stopped } == [.output])
  _ = try data.write(offset: 0, [UInt8](repeating: 0, count: 4096))
  #expect(model.lock.withLock { model.prepared.count == 2 && model.prepared[1].1.rate == 48000 })
}

// MARK: The lease (D181)

func leaseClient(_ served: ServedAudio) throws -> AudioLeaseIPC.LeaseClient {
  var f = try served.open("lease")
  return AudioLeaseIPC.LeaseClient(channel: f.takeChannel())
}

@Test func aLeaseLendsTheBufferAndCountsEachPeriod() throws {
  let model = ModelAudio()
  let served = try ServedAudio(model)
  try served.write("ctl", "period 32")
  var lease = try leaseClient(served)
  let lent = try lease.lend()
  #expect(lent.layout == AudioLeaseIPC.Layout(periods: 8, periodFrames: 32, lead: 2, sample: 2, channels: 2, rate: 44100))
  let vmo = lent.takeBuffer()
  let mapping = try VMO.map(vmo, length: 4096)
  // Made silence, and the device's memory itself.
  #expect((0..<1024).allSatisfy { mapping.address.load(fromByteOffset: $0, as: UInt8.self) == 0 })
  mapping.address.storeBytes(of: 0x5A, toByteOffset: 2 * 128, as: UInt8.self)
  #expect(model.lastBuffer[2 * 128] == 0x5A)
  #expect(model.lock.withLock { model.started } == [.output])
  #expect(model.handedSlots == [0, 1])
  let clock = try lease.clock().takeCounter()
  #expect(try Counter.read(clock) == 0)
  // Nothing written through data, yet it runs on, a period counted each.
  for _ in 0..<5 { served.unit.finished(.output) }
  #expect(try Counter.read(clock) == 5)
  #expect(model.handedSlots == [0, 1, 2, 3, 4, 5, 6])
  #expect(model.lock.withLock { model.stopped }.isEmpty)
  #expect(lines(try served.text("stat")).contains("out lent runs 1 periods 5 underruns 0"))
  // The lessee's alone.
  var data = try served.open("data")
  #expect(fails(.denied) { _ = try data.write(offset: 0, [1, 2, 3, 4]) })
  #expect(fails(.denied) { try served.write("ctl", "speed 48000") })
  #expect(fails(.denied) { try served.write("ctl", "stop") })
  var other = try leaseClient(served)
  #expect(throws: (any Error).self) { _ = try other.lend() }
}

@Test func aLeaseEndsWhenItsChannelCloses() throws {
  let model = ModelAudio()
  let served = try ServedAudio(model)
  do {
    var lease = try leaseClient(served)
    _ = try lease.lend().takeBuffer()
    #expect(model.lock.withLock { model.started } == [.output])
  }
  let deadline = Clock.monotonic() + 2_000_000_000
  while model.lock.withLock({ model.stopped }).isEmpty, Clock.monotonic() < deadline {
    sleep(until: Clock.monotonic() + 5_000_000)
  }
  #expect(model.lock.withLock { model.stopped } == [.output])
  #expect(lines(try served.text("stat")).contains("out stopped runs 1 periods 0 underruns 0"))
  // data plays again, and the next lessee may lend.
  var data = try served.open("data")
  #expect(try data.write(offset: 0, [UInt8](repeating: 0, count: 64)) == 64)
  var again = try leaseClient(served)
  _ = try again.lend().takeBuffer()
  #expect(model.lock.withLock { model.lent } == 2)
}

// MARK: virtio-snd's messages

@Test func virtioSoundMessagesAreTheSpecsLayouts() {
  #expect(Sound.queryInfo(Sound.pcmInfo, start: 0, count: 2, size: 32)
    == [0, 1, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 32, 0, 0, 0])
  #expect(Sound.pcm(Sound.pcmStart, stream: 1) == [4, 1, 0, 0, 1, 0, 0, 0])
  let p = Sound.setParams(stream: 0, bufferBytes: 32768, periodBytes: 4096,
                          format: PCMFormat(sample: .s16, channels: 2, rate: 48000))
  #expect(p == [1, 1, 0, 0, 0, 0, 0, 0, 0, 0x80, 0, 0, 0, 0x10, 0, 0, 0, 0, 0, 0, 2, 5, 7, 0])
  #expect(Sound.setParams(stream: 0, bufferBytes: 1, periodBytes: 1,
                          format: PCMFormat(sample: .s16, channels: 2, rate: 12345)) == nil)
}

@Test func virtioSoundStreamsAreReadFromPCMInfo() {
  var answer: [UInt8] = [0x00, 0x80, 0, 0]
  func info(_ formats: UInt64, _ rates: UInt64, _ direction: UInt8, _ lo: UInt8, _ hi: UInt8) -> [UInt8] {
    var b = [UInt8](repeating: 0, count: 32)
    for i in 0..<8 {
      b[8 + i] = UInt8(truncatingIfNeeded: formats >> (8 * UInt64(i)))
      b[16 + i] = UInt8(truncatingIfNeeded: rates >> (8 * UInt64(i)))
    }
    b[24] = direction
    b[25] = lo
    b[26] = hi
    return b
  }
  answer += info(1 << 5 | 1 << 17 | 1 << 1, 1 << 6 | 1 << 7, 0, 1, 2)
  answer += info(1 << 5, 1 << 7, 1, 1, 1)
  #expect(Sound.status(answer) == Sound.ok)
  let infos = Sound.pcmInfos(answer, start: 0, count: 2)
  #expect(infos.count == 2)
  #expect(infos[0].direction == .output && infos[1].direction == .input && infos[1].id == 1)
  #expect(infos[0].capabilities == PCMCapabilities(samples: [.s16, .s32], rates: [44100, 48000], channels: 1...2))
  #expect(infos[1].capabilities == PCMCapabilities(samples: [.s16], rates: [48000], channels: 1...1))
  #expect(Sound.event([0x01, 0x11, 0, 0, 3, 0, 0, 0]) == (Sound.pcmXrun, 3))
}

/// Whether `body` failed with the server's `code`.
func fails(_ code: NodeIPC.NodeError, _ body: () throws -> Void) -> Bool {
  do {
    try body()
    return false
  } catch let e as IPCError<NodeIPC.NodeError> {
    if case .remote(let r) = e { return r == code }
    return false
  } catch {
    return false
  }
}
