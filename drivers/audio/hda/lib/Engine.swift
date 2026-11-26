// SPDX-License-Identifier: BSD-3-Clause

// The audio class over an HD Audio controller (D179, D180): an
// AudioHardware whose playback is the first output stream descriptor
// driving the codec's output path's DAC, and whose capture is the first
// input descriptor fed by its input path's ADC. Each stream's cyclic
// buffer is memory the controller reaches, one BDL entry a period, and
// the descriptor runs through it on its own once started: handing a
// period to it is nothing, but the first, which sets it running. The
// position is SDnLPIB, read at each interrupt (and each poll, where the
// interrupt is INTx): every period it has moved past since the last read
// is finished, so an interrupt coalesced or lost still counts each one.

import AudioDevice
import DriverHost
import Node
import Sys

@safe public final class HDAAudio: AudioHardware, @unchecked Sendable {
  public let name = "hda"
  public let controller: HDAController
  public let graph: CodecGraph
  public let paths: (output: [Int]?, input: [Int]?)
  public let maxBufferBytes = 256 * 1024
  public let externalDelay = 0
  /// Verbs the codec refused or didn't answer while its paths were set up.
  public private(set) var refused = 0
  public var finished: @Sendable (AudioDirection) -> Void = { _ in }

  struct Stream {
    var sd: Int
    var tag: Int
    var converter: Int
    var buffer: Region
    var bdl: Region
    var periods = 0
    var periodBytes = 0
    var armed = false
    var running = false
    var last = 0
  }

  let memory: DMAMemory
  let lock = Lock()
  var streams: [Stream?]
  public private(set) var periodsDone = [0, 0]
  static var maxPeriods: Int { 64 }

  /// Resets the controller, reads the first codec with an audio function
  /// group, and sets its playback and capture paths up; then the streams'
  /// buffers and BDLs.
  public init(controller: HDAController, memory: DMAMemory) throws(HDAError) {
    self.controller = controller
    self.memory = memory
    try controller.start()
    var found: CodecGraph?
    for c in 0..<15 where controller.codecs & (1 << UInt16(c)) != 0 {
      if let g = CodecGraph.read(codec: c, send: { try? controller.send($0) }) {
        found = g
        break
      }
    }
    guard let graph = found else { throw .noCodec }
    self.graph = graph
    paths = (graph.outputPath(), graph.inputPath())
    var refusals = 0
    for (p, output) in [(paths.output, true), (paths.input, false)] {
      guard let p else { continue }
      for v in graph.setUp(p, output: output) where (try? controller.send(v)) == nil { refusals += 1 }
    }
    refused = refusals
    var made: [Stream?] = [nil, nil]
    for (i, output) in [(0, true), (1, false)] {
      let path = output ? paths.output : paths.input
      let count = output ? controller.outputStreams : controller.inputStreams
      guard let path, count > 0 else { continue }
      do throws(Status) {
        made[i] = Stream(sd: controller.descriptor(output: output, 0), tag: i + 1,
                         converter: output ? path.last! : path.first!,
                         buffer: try Region(memory, bytes: maxBufferBytes), bdl: try Region(memory, bytes: 16 * Self.maxPeriods))
      } catch {
        throw .noStream
      }
    }
    streams = made
  }

  static func index(_ d: AudioDirection) -> Int { d == .output ? 0 : 1 }

  func send(_ node: Int, _ verb: UInt32, _ payload: UInt32) {
    _ = try? controller.send(Verb.command(codec: graph.codec, node: node, verb: verb, payload: payload))
  }

  // MARK: AudioHardware

  public func capabilities(_ d: AudioDirection) -> PCMCapabilities? {
    guard let s = lock.withLock({ streams[Self.index(d)] }), let w = graph.widget(s.converter) else { return nil }
    let c = PCMBits.capabilities(w.pcm, channels: 1...(w.caps.stereo ? 2 : 1))
    return c.samples.isEmpty || c.rates.isEmpty ? nil : c
  }

  public func prepare(_ d: AudioDirection, _ format: PCMFormat, periodBytes: Int, periods: Int)
    throws(NodeIPC.NodeError) -> AudioBuffer
  {
    let i = Self.index(d)
    guard var s = lock.withLock({ streams[i] }) else { throw .unsupported }
    guard periods <= Self.maxPeriods, periods * periodBytes <= maxBufferBytes, periodBytes % 128 == 0 else {
      throw .invalid
    }
    guard let word = StreamFormat.word(format) else { throw .unsupported }
    if s.running || s.armed { stop(d) }
    do throws(HDAError) {
      try controller.setUp(sd: s.sd, tag: s.tag, buffer: s.buffer.bus, periods: periods, periodBytes: periodBytes,
                           bdl: s.bdl, format: word)
    } catch {
      throw .io
    }
    send(s.converter, Verb.setFormat, UInt32(word))
    send(s.converter, Verb.setStream, UInt32(s.tag) << 4)
    s.periods = periods
    s.periodBytes = periodBytes
    s.armed = false
    s.running = false
    lock.withLock { streams[i] = s }
    return s.buffer.buffer(periods * periodBytes)
  }

  public func start(_ d: AudioDirection) throws(NodeIPC.NodeError) {
    let i = Self.index(d)
    try lock.withLock { () throws(NodeIPC.NodeError) in
      guard var s = streams[i], s.periods > 0 else { throw .io }
      s.armed = true
      s.last = 0
      streams[i] = s
    }
  }

  /// The first period handed sets the descriptor running; it reads the
  /// buffer by itself after that.
  public func hand(_ d: AudioDirection, slot: Int) {
    let i = Self.index(d)
    lock.withLock {
      guard var s = streams[i], s.armed, !s.running else { return }
      controller.run(sd: s.sd)
      s.running = true
      streams[i] = s
    }
  }

  public func stop(_ d: AudioDirection) {
    let i = Self.index(d)
    guard var s = lock.withLock({ streams[i] }) else { return }
    if s.running || s.armed {
      try? controller.stop(sd: s.sd)
      // The converter's stream and format are kept: the next prepare
      // sets them again.
    }
    s.running = false
    s.armed = false
    lock.withLock { streams[i] = s }
  }

  public func lend(_ d: AudioDirection) throws(NodeIPC.NodeError) -> Handle {
    guard let s = lock.withLock({ streams[Self.index(d)] }), let vmo = memory.vmo(bus: s.buffer.bus) else {
      throw .unsupported
    }
    return vmo
  }

  // MARK: The interrupt

  /// The periods each running stream has moved past since the last look,
  /// told to the class in order, with no lock held.
  public func serviceInterrupt() {
    _ = controller.serviceInterrupt()
    var ended: [(AudioDirection, Int)] = []
    lock.withLock {
      for (i, d) in [(0, AudioDirection.output), (1, .input)] {
        guard var s = streams[i], s.running, s.periodBytes > 0 else { continue }
        let now = (controller.position(sd: s.sd) / s.periodBytes) % s.periods
        let n = (now - s.last + s.periods) % s.periods
        s.last = now
        streams[i] = s
        if n > 0 {
          periodsDone[i] += n
          ended.append((d, n))
        }
      }
    }
    let tell = finished
    for (d, n) in ended {
      for _ in 0..<n { tell(d) }
    }
  }

  /// A path's nodes, built in a loop (short Strings made in closures
  /// have come out corrupt on arm64: CLAUDE.md).
  static func nodes(_ path: [Int]?) -> String {
    guard let path else { return "none" }
    var s = ""
    for n in path {
      if !s.isEmpty { s += " " }
      s += String(n)
    }
    return s
  }

  /// The status's lines about the controller and codec.
  public var report: String {
    var s = "streams in \(controller.inputStreams) out \(controller.outputStreams)\n"
    s += "codecs 0x\(String(controller.codecs, radix: 16)) codec \(graph.codec) vendor 0x\(String(graph.vendor, radix: 16))"
      + " widgets \(graph.widgets.count)\n"
    s += "output path " + Self.nodes(paths.output) + "\ninput path " + Self.nodes(paths.input) + "\n"
    let done = lock.withLock { periodsDone }
    s += "periods out \(done[0]) in \(done[1])\ncommands \(controller.commands) refused \(refused)"
      + " unsolicited \(controller.unsolicited)\n"
    return s
  }
}
