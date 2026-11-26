// SPDX-License-Identifier: BSD-3-Clause

// bin/audio (D179, D180, D181): the audio service, its push streams. Its
// tree, at /svc/audio:
//   audio    a push stream for each channel opened at it: 16-bit stereo
//            frames at the device's rate, written; a write waits while
//            the stream's queue is full
//   status   the device, the format, the quantum, the counts, each stream
// The service holds no device while nothing plays. At a stream's first
// frames it leases /dev/audio/0's playback stream (its buffer and its
// counter), and on its own thread, with an admitted deadline lent by the
// counter, mixes a quantum (a period) of every stream into the buffer
// for each period the device finishes, `ahead` periods past those the
// device holds. Once nothing has played for a second it gives the lease
// back, and the device stops.

import AudioDevice
import AudioMix
import IPC
import Node
import Sys

/// What the status says, and the work counter writers add to.
final class Service: @unchecked Sendable {
  let graph = Graph()
  let lock = Lock()
  var state = "idle"
  var format = "-"
  var quantum = 0
  var leases = 0
  var cycles: UInt64 = 0
  var late: UInt64 = 0
  var failure = ""
  var admission = "none (no system resource)"
  /// Added to by each write, so an idle mixer wakes (its raw handle).
  var workRaw: UInt32 = 0
  var ready: @Sendable () -> Void = {}

  func set(_ body: () -> Void) { lock.withLock { body() } }

  var status: String {
    lock.withLock {
      var s = "device /dev/audio/0\nstate \(state)\nformat \(format)\nquantum \(quantum)\nahead \(Mixer.ahead)\n"
      s += "leases \(leases) cycles \(cycles) late \(late)\nprofile \(admission)\n"
      if !failure.isEmpty { s += "failed \(failure)\n" }
      let streams = graph.all
      s += "streams \(streams.count) quanta \(graph.quanta) audible \(graph.audible)\n"
      for st in streams {
        s += "stream \(st.id) frames \(st.frames) buffered \(st.buffered) underruns \(st.underruns)"
          + (st.closed ? " closing\n" : "\n")
      }
      return s
    }
  }
}

enum Mixer {
  /// The quantum asked of the device (D179's default), and the periods
  /// written past those the device holds.
  static let quantum = 256
  static let ahead: UInt64 = 2

  /// Waits for a stream with frames, plays while there are any, and does
  /// it again, for good.
  static func run(_ ns: Namespace, _ svc: Service) {
    let work = Handle(raw: svc.workRaw)
    while true {
      while !svc.graph.pending {
        let seen = (try? Counter.read(work)) ?? 0
        if svc.graph.pending { break }
        try? Counter.wait(work, until: seen + 1)
      }
      play(ns, svc, profile: profileRaw.load())
    }
  }

  /// One lease: from the first frames to a second of silence.
  static func play(_ ns: Namespace, _ svc: Service, profile: UInt32) {
    func fail(_ why: String) {
      svc.set {
        svc.state = "idle"
        svc.failure = why
      }
      // Nothing to play to: what was written is dropped, at the rate it
      // would have played, so writers don't wait for good.
      for s in svc.graph.all { s.drop() }
      svc.ready()
      sleep(until: Clock.monotonic() + 1_000_000_000)
    }
    guard ((try? ns.list("/dev/audio")) ?? []).contains(where: { $0.name.utf8.elementsEqual("0".utf8) }) else {
      return fail("no device at /dev/audio/0")
    }
    _ = ns.writeText("/dev/audio/0/ctl", "period \(quantum)\n")
    guard var file = try? ns.open("/dev/audio/0/lease") else { return fail("can't open /dev/audio/0/lease") }
    var lease = AudioLeaseIPC.LeaseClient(channel: file.takeChannel())
    let layout: AudioLeaseIPC.Layout
    let vmo: Handle
    do throws(IPCError<AudioLeaseIPC.LeaseError>) {
      let lent = try lease.lend()
      layout = lent.layout
      vmo = lent.takeBuffer()
    } catch {
      return fail("the device refused the lease")
    }
    let clock: Handle
    do throws(IPCError<AudioLeaseIPC.LeaseError>) {
      clock = try lease.clock().takeCounter()
    } catch {
      return fail("no clock for the lease")
    }
    guard let format = DeviceFormat(sampleIndex: layout.sample, channels: layout.channels) else {
      return fail("the device's format isn't one the graph writes")
    }
    let frames = Int(layout.periodFrames), periods = UInt64(layout.periods), lead = UInt64(layout.lead)
    let periodBytes = frames * format.frameBytes
    let size = (Int(periods) * periodBytes + 4095) & ~4095
    let mapping: Mapping
    do throws(Status) {
      mapping = try VMO.map(vmo, length: size)
    } catch {
      return fail("can't map the lent buffer")
    }
    if profile != 0 {
      let p = Handle(raw: profile)
      try? Profile.lend(p, from: clock)
      _ = p.release()
    }
    let names = ["s16", "s32", "f32"]
    svc.set {
      svc.state = "playing"
      svc.failure = ""
      svc.format = "\(names[format.sample == .s16 ? 0 : format.sample == .s32 ? 1 : 2]) \(format.channels)"
        + " speed \(layout.rate)"
      svc.quantum = frames
      svc.leases += 1
    }

    // Periods 0 to lead-1 are with the device already, silence.
    var written = lead
    var quiet = 0
    let idle = max(1, Int(layout.rate) / frames)
    func fill(upTo end: UInt64) {
      while written < end {
        let slot = Int(written % periods)
        let out = unsafe UnsafeMutableRawBufferPointer(start: mapping.address + slot * periodBytes, count: periodBytes)
        if unsafe svc.graph.render(frames: frames, format: format, into: out) { quiet = 0 } else { quiet += 1 }
        written += 1
      }
      svc.ready()
    }
    fill(upTo: lead + ahead)
    var seen: Int64 = 0
    while true {
      do throws(Status) {
        try Counter.wait(clock, until: seen + 1, deadline: Clock.monotonic() + 1_000_000_000)
      } catch {
        svc.set { svc.failure = "the device stopped taking periods" }
        break
      }
      seen = (try? Counter.read(clock)) ?? (seen + 1)
      let done = UInt64(seen)
      // The device holds done..<done+lead; any of those not written were
      // played as whatever the slot held: the service was late.
      if written < done + lead {
        let missed = done + lead - written
        svc.set { svc.late += missed }
        written = done + lead
      }
      fill(upTo: done + lead + ahead)
      svc.set { svc.cycles += 1 }
      if quiet >= idle && !svc.graph.pending { break }
    }
    svc.set { svc.state = "idle" }
    _ = consume mapping
    _ = consume lease  // the lease ends with its channel
  }
}

@main struct AudioService {
  static func main() {
    let start = Startup.current
    let ns: Namespace
    do throws(NamespaceError) { ns = try Namespace(start) } catch { Process.fail("no namespace") }
    let dispatcher: IPCDispatcher
    do throws(Status) { dispatcher = try IPCDispatcher() } catch { Process.fail("can't make a dispatcher") }
    let tree = NodeTree(dispatcher: dispatcher)
    let svc = Service()
    do throws(Status) {
      svc.workRaw = try Counter.create().release()
    } catch {
      Process.fail("can't make a counter")
    }
    let workRaw = svc.workRaw
    let graph = svc.graph
    let node = tree.stream("audio", NodeStream(perChannel: {
      let stream = graph.open()
      return NodeStreamChannel(take: { _ in [] }, write: { (data: [UInt8]) throws(NodeError) -> UInt32? in
        guard let n = stream.write(data) else { return nil }
        let work = Handle(raw: workRaw)
        try? Counter.add(work, 1)
        _ = work.release()
        return n
      }, closed: { stream.close() })
    }))
    svc.ready = { tree.ready(node) }
    tree.text("status", read: { svc.status })

    // The mixer, and its deadline: a quantum's work in each quantum (at
    // 44.1 kHz, 256 frames are 5.8 ms), admitted under the system resource.
    let mixer: Handle
    do throws(Status) {
      mixer = try Thread.spawn { Mixer.run(ns, svc) }
    } catch {
      Process.fail("can't start the mixer")
    }
    if let system = start.take(HandleType.info(HandleType.resource(.system))) {
      let period: Int64 = 5_804_988
      if let r = try? Sys.Resource.create(parent: system, kind: .system, base: Profile.systemBase, size: 1, name: "audio"),
        let profile = try? Profile.deadline(resource: r, capacity: 1_000_000, deadline: period, period: period)
      {
        let refusal = (try? Profile.apply(profile, to: mixer)) ?? 0xFFFF
        let admitted = refusal == 0
        svc.set { svc.admission = admitted ? "deadline 1 ms of each 5.8 ms, admitted" : "refused (\(refusal))" }
        if admitted { profileRaw.store(profile.release()) }
      } else {
        svc.set { svc.admission = "none (no profile)" }
      }
    }

    guard let export = start.export() else { Process.fail("no export (its manifest's `export`)") }
    do throws(Status) {
      try tree.serve(export)
      try dispatcher.run()
    } catch {
      Process.fail("can't serve: \(error.rawValue)")
    }
    _ = consume mixer
  }
}

/// The admitted profile's raw handle, once there is one: the mixer lends
/// it from each lease's counter.
let profileRaw = RawCell()

final class RawCell: @unchecked Sendable {
  let lock = Lock()
  var raw: UInt32 = 0
  func load() -> UInt32 { lock.withLock { raw } }
  func store(_ r: UInt32) { lock.withLock { raw = r } }
}
