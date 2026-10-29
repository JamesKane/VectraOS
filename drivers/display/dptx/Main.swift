// SPDX-License-Identifier: BSD-3-Clause

// bin/dptx (dptx(3)): the CIX Sky1's DisplayPort transmitter (CIXH502F,
// one behind each Linlon-D6 engine), read and watched, never reset,
// trained or powered (D146): the link firmware trained stays as it is.
//
// - The transmitter is in its engine's power domain, and a register read
//   of an unpowered one stops the machine: devmgr mounts the engine's own
//   platform directory at /dev/engine, and dptx reads none of its
//   registers unless the engine's `power` says on.
// - The probe: the transmitter enabled, firmware's AUX divider, HPD's
//   level, and the link firmware trained (rate, lanes, PHY lanes ready).
// - Over AUX: the sink's receiver capabilities and sink count (the DPCD),
//   and its EDID through I2C-over-AUX. The board's HDMI comes through a
//   PS185, a DisplayPort-to-HDMI branch: the monitor behind it is its
//   sink count, and its EDID comes through.
// - HPD's level changes and the sink's short pulses come on the
//   interrupt (the others masked): each reads the sink count again, and
//   the EDID when there is a sink, so a monitor plugged into the PS185 or
//   out of it is seen.
//
// Its tree: `status`, `edid` (hex, 16 bytes a line; empty without one),
// and `link` (DisplayLinkIPC), which the engine's driver follows.

import CroiMMIO
import DisplayDevice
import DriverHost
import IPC
import Node
import Sys

struct ProbeStop: Error {
  let text: String
}

func hex(_ v: UInt32, digits: Int = 8) -> String {
  var out: [UInt8] = Array("0x".utf8)
  for i in stride(from: digits - 1, through: 0, by: -1) { out.append(hexDigit(UInt8(v >> UInt32(4 * i) & 0xF))) }
  return String(decoding: out, as: UTF8.self)
}

/// The core's AUX channel, one request at a time, polled (its AUX
/// interrupts stay masked, as the vendor's driver leaves them).
@safe final class Core: AUXChannel, @unchecked Sendable {
  let regs: Registers
  var requests = 0, timeouts = 0

  init(regs: consuming Registers) { self.regs = regs }

  var hpd: Bool { regs.load32(DPTXRegisters.hpdInputState) & 1 != 0 }

  func transfer(_ r: AUXRequest) throws(AUXError) -> (AUXReply, [UInt8]) {
    guard hpd else { throw .noSink }
    let busy = DPTXRegisters.replyInProgress | DPTXRegisters.requestInProgress
    guard regs.load32(DPTXRegisters.auxStatus) & busy == 0 else { throw .busy }
    requests += 1
    regs.store32(DPTXRegisters.auxAddress, r.address)
    for b in r.data { regs.store32(DPTXRegisters.auxWriteFIFO, UInt32(b)) }
    regs.store32(DPTXRegisters.auxCommand, r.command)
    // A reply comes within DisplayPort's 400 µs, or the core times out.
    let deadline = Clock.monotonic() + 10_000_000
    while true {
      let s = regs.load32(DPTXRegisters.auxStatus)
      if s & DPTXRegisters.replyError != 0 {
        timeouts += 1
        throw .timedOut
      }
      if s & DPTXRegisters.replyReceived != 0 { break }
      guard Clock.monotonic() < deadline else {
        timeouts += 1
        throw .timedOut
      }
      sleep(until: Clock.monotonic() + 50_000)
    }
    let reply = AUXReply(code: regs.load32(DPTXRegisters.auxReplyCode), i2c: r.isI2C)
    var bytes: [UInt8] = []
    if r.isRead, reply == .ack {
      let n = Int(regs.load32(DPTXRegisters.auxReplyDataCount) & 0xFF)
      for _ in 0..<min(n, 16) { bytes.append(UInt8(truncatingIfNeeded: regs.load32(DPTXRegisters.auxReplyData))) }
    }
    return (reply, bytes)
  }
}

/// What the sink says now: read at the probe and again at each HPD event.
final class Sink: @unchecked Sendable {
  let lock = Lock()
  var hpd = false
  var capabilities: SinkCapabilities?
  var count = 0
  var edid: [UInt8] = []
  var failure = ""
  var events = 0, pulses = 0, changes = 0
  /// The link's clients: each one's server, and the changes it was told of.
  var clients: [(server: UInt64, told: Int)] = []
  nonisolated(unsafe) static var dispatcher: IPCDispatcher?

  /// A monitor is there: HPD high, and behind a branch one counted.
  var connected: Bool { hpd && (capabilities.map { !$0.branch || count > 0 } ?? false) }

  /// Reads the DPCD and, where a sink is, the EDID (the core's lock held:
  /// one AUX request at a time).
  func read(_ core: Core) {
    var aux = core
    hpd = core.hpd
    failure = ""
    guard hpd else {
      capabilities = nil
      count = 0
      edid = []
      return
    }
    do throws(AUXError) {
      // A sink just plugged may take up to 500 ms to answer (DisplayPort).
      var caps: [UInt8] = []
      for attempt in 0..<5 {
        do throws(AUXError) {
          caps = try aux.readDPCD(0x000, count: 16)
          break
        } catch {
          if attempt == 4 { throw error }
          sleep(until: Clock.monotonic() + 100_000_000)
        }
      }
      let c = SinkCapabilities(caps)
      capabilities = c
      count = sinkCount(try aux.readDPCD(0x200, count: 1)[0])
      // A branch with no sink behind it has no EDID to give.
      edid = c.branch && count == 0 ? [] : try aux.readEDID()
    } catch {
      failure = error.name
    }
  }

  var text: String {
    guard hpd else { return "hpd low: no sink\n" }
    var t = "hpd high\n"
    if let c = capabilities { t += "dpcd \(c.text), sink count \(count)\n" }
    if !edid.isEmpty {
      t += "edid \(edid.count) bytes" + (EDID(edid).map { ": " + $0.text } ?? ": no valid block 0") + "\n"
    } else if capabilities != nil {
      t += "no edid\n"
    }
    if !failure.isEmpty { t += "aux failed: \(failure)\n" }
    return t
  }
}

/// The probe: the lines it says, the core and the sink if it is live.
func probe(_ ns: Namespace, _ resources: inout DeviceResources) -> (lines: [String], core: Core?, sink: Sink?) {
  var lines: [String] = []
  do throws(ProbeStop) {
    // The engine's power: an unpowered transmitter faults on its first read.
    let power = ns.readText("/dev/engine/power") ?? ""
    guard power.utf8.starts(with: "on".utf8) else {
      throw ProbeStop(text: "off: its engine is unpowered (or unknown), so no register is read")
    }
    lines.append("its engine powered by firmware")
    guard let regs = try? resources.map(bar: 0), regs.size >= DPTXRegisters.windowSize else {
      throw ProbeStop(text: "FAILED: no registers")
    }
    let core = Core(regs: regs)
    let enabled = core.regs.load32(DPTXRegisters.transmitterEnable) & 1 != 0
    let divider = core.regs.load32(DPTXRegisters.auxClockDivider) & 0x1FF
    lines.append("core revision \(hex(core.regs.load32(DPTXRegisters.coreRevision))), transmitter "
      + (enabled ? "enabled" : "disabled") + ", aux divider \(divider)")
    guard enabled, divider >= 10 else { throw ProbeStop(text: "idle: firmware left the transmitter or its AUX off") }
    let rate = UInt8(truncatingIfNeeded: core.regs.load32(DPTXRegisters.linkBandwidth))
    let lanes = core.regs.load32(DPTXRegisters.laneCount)
    lines.append("link \(rateName(rate)) x\(lanes), sources \(hex(core.regs.load32(DPTXRegisters.sourceEnable), digits: 1)), "
      + "phy lanes ready \(hex(core.regs.load32(DPTXRegisters.phyStatus) & 0xF, digits: 1))")
    return (lines, core, Sink())
  } catch {
    lines.append(error.text)
    return (lines, nil, nil)
  }
}

/// HPD's events: each, the sink read again.
func watch(_ interrupt: UInt32, _ core: Core, _ sink: Sink) {
  guard let irq = try? InterruptPort(Handle(raw: interrupt)) else { return }
  while (try? irq.wait()) != nil {
    let cause = core.regs.load32(DPTXRegisters.interruptCause)  // once: clear on read
    try? irq.ack()
    guard cause & (DPTXRegisters.hpdEvent | DPTXRegisters.hpdIRQ) != 0 else { continue }
    sink.lock.withLock {
      if cause & DPTXRegisters.hpdEvent != 0 { sink.events += 1 }
      if cause & DPTXRegisters.hpdIRQ != 0 { sink.pulses += 1 }
      let before = (sink.hpd, sink.count, sink.edid)
      sink.read(core)
      if before.0 != sink.hpd || before.1 != sink.count || before.2 != sink.edid { sink.changes += 1 }
    }
    // Its clients told, each by its own server's thread.
    let servers = sink.lock.withLock { sink.clients.map { $0.server } }
    if let d = Sink.dispatcher { for s in servers { d.wake(s) } }
    print("dptx: hpd " + (sink.hpd ? "high" : "low") + ", sink count \(sink.count)")
  }
}

@main struct DPTXDriver {
  static func main() {
    let start = Startup.current
    var resources = DeviceResources(take: { start.take($0)?.release() })
    var probed: (lines: [String], core: Core?, sink: Sink?) = (["FAILED: no namespace"], nil, nil)
    if let ns = try? Namespace(start) { probed = probe(ns, &resources) }
    var lines = probed.lines
    let core = probed.core, sink = probed.sink
    if let core, let sink {
      sink.lock.withLock { sink.read(core) }
      // Only HPD's two interrupts, after the cause firmware left is read away.
      _ = core.regs.load32(DPTXRegisters.interruptCause)
      if let handle = try? resources.interrupt() {
        let raw = handle.release()
        core.regs.store32(DPTXRegisters.interruptMask, DPTXRegisters.hpdOnlyMask)
        _ = try? Thread.spawn { watch(raw, core, sink) }.release()
        lines.append("watching hpd")
      } else {
        lines.append("no interrupt: hpd not watched")
      }
    }
    var said = "dptx: " + lines.joined(separator: "; ")
    if let sink {
      let text = sink.lock.withLock { sink.text }
      said += "; " + text
    }
    print(said)

    do throws(Status) {
      let dispatcher = try IPCDispatcher()
      let tree = NodeTree(dispatcher: dispatcher)
      let status = lines.map { $0 + "\n" }.joined()
      tree.text("status", read: {
        guard let sink, let core else { return status }
        return status + sink.lock.withLock {
          sink.text + "hpd events \(sink.events), pulses \(sink.pulses), changes \(sink.changes); "
            + "aux requests \(core.requests), timeouts \(core.timeouts)\n"
        }
      })
      tree.text("edid", read: {
        guard let sink else { return "" }
        let bytes = sink.lock.withLock { sink.edid }
        var out: [UInt8] = []
        for (i, b) in bytes.enumerated() {
          out.append(hexDigit(b >> 4))
          out.append(hexDigit(b & 0xF))
          if i % 16 == 15 { out.append(0x0A) }
        }
        return String(decoding: out, as: UTF8.self)
      })
      // The link (DisplayLinkIPC): what the sink is, and each change told.
      Sink.dispatcher = dispatcher
      tree.service("link") { (channel: consuming Handle) throws(Status) in
        guard let sink else { throw .notSupported }
        let c = LinkClient()
        let told = sink.lock.withLock { sink.changes }
        c.id = try dispatcher.add(DisplayLinkIPC.LinkServer(channel: channel, impl: LinkSession(sink: sink))) {
          (s: inout DisplayLinkIPC.LinkServer<LinkSession>) throws(IPCError<Never>) in
          let tell = sink.lock.withLock { () -> Bool in
            guard let i = sink.clients.firstIndex(where: { $0.server == c.id }), sink.clients[i].told != sink.changes
            else { return false }
            sink.clients[i].told = sink.changes
            return true
          }
          if tell { try DisplayLinkIPC.LinkEventSender.sendSinkChanged(on: s.connection) }
        }
        sink.lock.withLock { sink.clients.append((c.id, told)) }
      }
      guard let export = start.export() else { Process.exit(code: 2) }
      try tree.serve(export)
      try dispatcher.run()
    } catch {
      Process.exit(code: 1)
    }
    _ = consume resources
  }
}

/// A link client's server id, once added.
final class LinkClient: @unchecked Sendable {
  var id: UInt64 = 0
}

/// One client's view of the link.
final class LinkSession: DisplayLinkIPC.LinkHandler, @unchecked Sendable {
  let state: Sink
  init(sink: Sink) { state = sink }

  func sink() -> DisplayLinkIPC.Sink {
    state.lock.withLock { DisplayLinkIPC.Sink(connected: state.connected, count: UInt32(state.count)) }
  }

  func edid() -> [UInt8] { state.lock.withLock { state.edid } }
}
