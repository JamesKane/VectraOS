// SPDX-License-Identifier: BSD-3-Clause

// The audio class over virtio-snd (D179, D180): an AudioHardware whose
// playback and capture are the device's first output and first input
// streams. Each stream's cyclic buffer is memory the device reaches; a
// period handed to the device is one transfer on queue 2 (playback) or 3
// (capture): the stream's header, the period's bytes of the buffer in
// place, and a status. The device finishes transfers in order, as it
// plays or records them, so its completions are the stream's position.
//
// Control requests (queue 0) are rare and synchronous: the caller writes
// the request, submits it and polls the queue for the answer, never
// waiting on the interrupt thread, which may be the caller. That thread
// (`serviceInterrupt`) ends transfers and events, takes each stream's
// count of periods held down under the lock, and then, with no lock
// held, tells the class (`finished`). A stream is stopped with STOP then
// RELEASE, at which the device gives back what it held; it is set up
// again (SET_PARAMS, PREPARE) at its next start.

import AudioDevice
import DriverHost
import Node
import Sys
import Virtio

@safe public final class VirtioSound<W: Window>: AudioHardware, @unchecked Sendable {
  public let name = "virtio-snd"
  public let features: UInt64
  public let config: Sound.Config
  public private(set) var infos: [Sound.PCMInfo] = []
  /// The streams the class drives: the first output and the first input.
  public private(set) var streams: (output: Sound.PCMInfo?, input: Sound.PCMInfo?) = (nil, nil)
  public let maxBufferBytes = 256 * 1024
  public let externalDelay = 0

  /// What the device's thread calls as each period is done.
  public var finished: @Sendable (AudioDirection) -> Void = { _ in }

  enum State { case released, prepared, running }

  let device: Device<W>
  let notify: W
  let notifyAt: [Int]
  let control: SplitQueue
  let events: SplitQueue
  let transfers: [SplitQueue]
  /// Kept: the rings, buffers and slots live as long as it does.
  let memory: DMAMemory
  let lock = Lock()
  let controlLock = Lock()
  /// The control request's page: the request at 0, the answer at 512.
  let controlAddress: UInt, controlBus: UInt64
  /// The events' buffers: 8 bytes each.
  let eventsAddress: UInt, eventsBus: UInt64
  static var eventCount: Int { 8 }
  /// Each direction's buffer, and its slots: 16 bytes a period, the
  /// transfer's header at 0 and its status at 8.
  let bufferAddress: [UInt], bufferBus: [UInt64]
  let slotsAddress: [UInt], slotsBus: [UInt64]
  static var maxPeriods: Int { 64 }

  var state: [State] = [.released, .released]
  var params: [(format: PCMFormat, periodBytes: Int, periods: Int)?] = [nil, nil]
  var held: [Int] = [0, 0]
  public private(set) var periodsDone: [Int] = [0, 0]
  public private(set) var eventsSeen = 0
  public private(set) var xruns = 0
  public private(set) var controlRequests = 0
  public private(set) var controlFailures: [String] = []

  /// Negotiates, sets up the four queues, posts the event buffers, sets
  /// DRIVER_OK and asks the device for its streams. `notify` is the
  /// notify capability's window; `multiplier` its notify_off_multiplier.
  public init(device: Device<W>, notify: W, multiplier: UInt32, memory: DMAMemory,
              vector: UInt16 = Device<W>.noVector) throws(Status)
  {
    self.device = device
    self.notify = notify
    self.memory = memory
    do throws(VirtioError) {
      features = try device.negotiate(0)
    } catch {
      throw .notSupported
    }
    config = Sound.config(device)
    var queues: [SplitQueue] = []
    var at: [Int] = []
    for q in 0..<4 {
      let size = device.queueSize(most: q == Sound.controlQueue ? 4 : 256, [q])
      guard size >= 4 else { throw .notSupported }
      let made = try device.makeQueue(q, size: size, memory: memory, vector: vector)
      queues.append(made.queue)
      at.append(made.notify * Int(multiplier))
    }
    control = queues[0]
    events = queues[1]
    transfers = [queues[2], queues[3]]
    notifyAt = at
    control.interrupts(false)

    (controlAddress, controlBus) = try Self.region(memory, 4096)
    (eventsAddress, eventsBus) = try Self.region(memory, 8 * Self.eventCount)
    var ba: [UInt] = [], bb: [UInt64] = [], sa: [UInt] = [], sb: [UInt64] = []
    for _ in 0..<2 {
      let b = try Self.region(memory, maxBufferBytes)
      ba.append(b.address)
      bb.append(b.bus)
      let s = try Self.region(memory, 16 * Self.maxPeriods)
      sa.append(s.address)
      sb.append(s.bus)
    }
    bufferAddress = ba
    bufferBus = bb
    slotsAddress = sa
    slotsBus = sb

    device.set(status: device.status | DeviceStatus.driverOK)
    for i in 0..<Self.eventCount { postEvent(i) }
    ring(Sound.eventQueue)

    // Its streams, all at once (QEMU has two: an output and an input).
    var found: [Sound.PCMInfo] = []
    let count = min(Int(config.streams), (512 - 4) / Sound.pcmInfoBytes)
    if count > 0,
      let answer = request(Sound.queryInfo(Sound.pcmInfo, start: 0, count: UInt32(count), size: UInt32(Sound.pcmInfoBytes)),
                           answer: 4 + count * Sound.pcmInfoBytes, what: "PCM_INFO")
    {
      found = Sound.pcmInfos(answer, start: 0, count: count)
    }
    infos = found
    streams = (found.first { $0.direction == .output }, found.first { $0.direction == .input })
  }

  /// `bytes` of memory the device reaches: its address here and its bus
  /// address.
  static func region(_ memory: DMAMemory, _ bytes: Int) throws(Status) -> (address: UInt, bus: UInt64) {
    let r = try unsafe memory.allocate(bytes: bytes)
    return unsafe (UInt(bitPattern: r.pointer), r.bus)
  }

  static func index(_ d: AudioDirection) -> Int { d == .output ? 0 : 1 }

  func stream(_ d: AudioDirection) -> Sound.PCMInfo? { d == .output ? streams.output : streams.input }

  func ring(_ q: Int) { notify.write(notifyAt[q], width: 2, UInt64(q)) }

  func postEvent(_ i: Int) {
    _ = events.submit([Buffer(address: eventsBus + UInt64(8 * i), length: 8, deviceWrites: true)])
  }

  // MARK: Control

  /// A control request and its answer of `answer` bytes, or nil (and a
  /// line for the status) if the device refused it or didn't answer in
  /// a second.
  func request(_ bytes: [UInt8], answer size: Int, what: String) -> [UInt8]? {
    controlLock.withLock { () -> [UInt8]? in
      let base = unsafe UnsafeMutableRawPointer(bitPattern: controlAddress)!
      bytes.withUnsafeBytes { unsafe base.copyMemory(from: $0.baseAddress!, byteCount: bytes.count) }
      unsafe (base + 512).storeBytes(of: UInt32(0), as: UInt32.self)
      let submitted = lock.withLock { () -> Bool in
        controlRequests += 1
        return control.submit([Buffer(address: controlBus, length: UInt32(bytes.count), deviceWrites: false),
                               Buffer(address: controlBus + 512, length: UInt32(size), deviceWrites: true)]) != nil
      }
      guard submitted else { return failed(what, "no room in the control queue") }
      ring(Sound.controlQueue)
      let deadline = Clock.monotonic() + 1_000_000_000
      var answered = false
      while !answered {
        answered = lock.withLock { !control.completed().isEmpty }
        if answered { break }
        guard Clock.monotonic() < deadline else { return failed(what, "no answer") }
        sleep(until: Clock.monotonic() + 100_000)
      }
      var out = [UInt8](repeating: 0, count: size)
      out.withUnsafeMutableBytes { unsafe $0.baseAddress!.copyMemory(from: base + 512, byteCount: size) }
      let status = Sound.status(out)
      guard status == Sound.ok else { return failed(what, Sound.name(status: status)) }
      return out
    }
  }

  func failed(_ what: String, _ why: String) -> [UInt8]? {
    lock.withLock {
      if controlFailures.count < 8 { controlFailures.append("\(what): \(why)") }
    }
    return nil
  }

  func simple(_ code: UInt32, _ d: AudioDirection, _ what: String) -> Bool {
    guard let s = stream(d) else { return false }
    return request(Sound.pcm(code, stream: s.id), answer: 4, what: what) != nil
  }

  func setUp(_ d: AudioDirection) throws(NodeIPC.NodeError) {
    let i = Self.index(d)
    guard let s = stream(d), let p = lock.withLock({ params[i] }) else { throw .unsupported }
    guard let message = Sound.setParams(stream: s.id, bufferBytes: UInt32(p.periodBytes * p.periods),
                                        periodBytes: UInt32(p.periodBytes), format: p.format)
    else { throw .unsupported }
    guard request(message, answer: 4, what: "SET_PARAMS") != nil else { throw .unsupported }
    guard simple(Sound.pcmPrepare, d, "PREPARE") else { throw .io }
    lock.withLock { state[i] = .prepared }
  }

  /// STOP if running, then RELEASE, then the periods it held given back.
  func release(_ d: AudioDirection) {
    let i = Self.index(d)
    let was = lock.withLock { state[i] }
    if was == .running { _ = simple(Sound.pcmStop, d, "STOP") }
    if was != .released { _ = simple(Sound.pcmRelease, d, "RELEASE") }
    lock.withLock { state[i] = .released }
    let deadline = Clock.monotonic() + 1_000_000_000
    while lock.withLock({ held[i] }) > 0, Clock.monotonic() < deadline {
      sleep(until: Clock.monotonic() + 200_000)
    }
  }

  // MARK: AudioHardware

  public func capabilities(_ d: AudioDirection) -> PCMCapabilities? {
    guard let c = stream(d)?.capabilities, !c.samples.isEmpty, !c.rates.isEmpty else { return nil }
    return c
  }

  public func prepare(_ d: AudioDirection, _ format: PCMFormat, periodBytes: Int, periods: Int)
    throws(NodeIPC.NodeError) -> AudioBuffer
  {
    guard periods <= Self.maxPeriods, periods * periodBytes <= maxBufferBytes else { throw .invalid }
    let i = Self.index(d)
    release(d)
    lock.withLock { params[i] = (format, periodBytes, periods) }
    try setUp(d)
    let base = unsafe UnsafeMutableRawPointer(bitPattern: bufferAddress[i])!
    return unsafe AudioBuffer(UnsafeMutableRawBufferPointer(start: base, count: periods * periodBytes))
  }

  public func start(_ d: AudioDirection) throws(NodeIPC.NodeError) {
    let i = Self.index(d)
    if lock.withLock({ state[i] }) == .released { try setUp(d) }
    guard simple(Sound.pcmStart, d, "START") else { throw .io }
    lock.withLock { state[i] = .running }
  }

  public func hand(_ d: AudioDirection, slot: Int) {
    let i = Self.index(d)
    guard let s = stream(d) else { return }
    lock.withLock {
      guard let p = params[i], slot < p.periods else { return }
      let header = unsafe UnsafeMutableRawPointer(bitPattern: slotsAddress[i] + UInt(16 * slot))!
      unsafe header.storeBytes(of: s.id.littleEndian, as: UInt32.self)
      unsafe (header + 8).storeBytes(of: UInt64(0), as: UInt64.self)
      let bus = slotsBus[i] + UInt64(16 * slot)
      let data = bufferBus[i] + UInt64(slot * p.periodBytes)
      guard transfers[i].submit([Buffer(address: bus, length: 4, deviceWrites: false),
                                 Buffer(address: data, length: UInt32(p.periodBytes), deviceWrites: d == .input),
                                 Buffer(address: bus + 8, length: 8, deviceWrites: true)]) != nil
      else { return }
      held[i] += 1
    }
    ring(i == 0 ? Sound.txQueue : Sound.rxQueue)
  }

  public func stop(_ d: AudioDirection) { release(d) }

  // MARK: The interrupt

  /// Ends the transfers and events the device has finished: periods
  /// handed back to the class in order, events counted and posted again.
  public func serviceInterrupt() {
    var ended: [AudioDirection] = []
    var reposted = false
    lock.withLock {
      for (i, d) in [(0, AudioDirection.output), (1, .input)] {
        for c in transfers[i].completed() {
          guard c.address >= slotsBus[i], c.address < slotsBus[i] + UInt64(16 * Self.maxPeriods) else { continue }
          if held[i] > 0 { held[i] -= 1 }
          periodsDone[i] += 1
          ended.append(d)
        }
      }
      for c in events.completed() {
        let slot = Int((c.address &- eventsBus) / 8)
        guard slot >= 0, slot < Self.eventCount else { continue }
        let at = unsafe UnsafeRawPointer(bitPattern: eventsAddress + UInt(8 * slot))!
        let type = UInt32(littleEndian: unsafe at.loadUnaligned(as: UInt32.self))
        eventsSeen += 1
        if type == Sound.pcmXrun { xruns += 1 }
        postEvent(slot)
        reposted = true
      }
    }
    if reposted { ring(Sound.eventQueue) }
    let tell = finished
    for d in ended { tell(d) }
  }

  /// The status's lines about the device.
  public var report: String {
    lock.withLock {
      var s = "jacks \(config.jacks) streams \(config.streams) chmaps \(config.chmaps)\n"
      for info in infos {
        s += "stream \(info.id) \(info.direction.name) formats 0x\(String(info.formats, radix: 16))"
          + " rates 0x\(String(info.rates, radix: 16)) channels \(info.channelsMin)-\(info.channelsMax)\n"
      }
      s += "periods out \(periodsDone[0]) in \(periodsDone[1])\nevents \(eventsSeen) xruns \(xruns)\n"
      s += "control requests \(controlRequests)\n"
      for f in controlFailures { s += "control failed: \(f)\n" }
      return s
    }
  }
}
