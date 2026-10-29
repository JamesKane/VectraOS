// SPDX-License-Identifier: BSD-3-Clause

// bin/dptx (dptx(3)): the CIX Sky1's DisplayPort transmitter (CIXH502F,
// one behind each Linlon-D6 engine), read and watched, its link trained
// at the rate a mode needs, and its stream set for the engine's timing
// (D146): never reset or powered.
//
// - The transmitter is in its engine's power domain, and a register read
//   of an unpowered one stops the machine: devmgr mounts the engine's own
//   platform directory at /dev/engine, and dptx reads none of its
//   registers unless the engine's `power` says on.
// - The probe: the transmitter enabled, firmware's AUX divider, HPD's
//   level, the link firmware trained (rate, lanes, PHY lanes ready), its
//   PHY (devmgr grants the combo PHY its _DSD's dp_phy names, `--bar=N:phy`,
//   whose register clock is turned on first through /dev/scmi), and
//   firmware's stream.
// - Over AUX: the sink's receiver capabilities and sink count (the DPCD),
//   and its EDID through I2C-over-AUX. The board's HDMI comes through a
//   PS185, a DisplayPort-to-HDMI branch: the monitor behind it is its
//   sink count, and its EDID comes through.
// - HPD's level changes and the sink's short pulses come on the
//   interrupt (the others masked): each reads the sink count again, and
//   the EDID when there is a sink. The PS185 drops HPD while its monitor
//   is gone, and the link with it: where the lanes say so (DPCD
//   0x202-0x204), the stream stops and the link trains again at its rate.
// - A link at another rate: the stream stopped, PLL1 set for the rate
//   in the PHY (lib/PHY.swift), the lanes ready, training (lib/DPTX.swift)
//   with the drive levels the sink asks for in the PHY, and the stream's
//   registers set for the link (lib/Stream.swift): for the timing the
//   engine's driver started it with, or firmware's scaled to the new rate.
//
// Its tree: `status`, `edid` (hex, 16 bytes a line; empty without one),
// `ctl` (`train RATE LANES`), and `link` (DisplayLinkIPC), which the
// engine's driver follows and starts streams through.

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

/// Writes `line` to `path`, which must take it.
func command(_ ns: Namespace, _ path: String, _ line: String) -> Bool {
  guard var f = try? ns.open(path) else { return false }
  let bytes = Array((line + "\n").utf8)
  return (try? f.write(offset: 0, bytes)) == UInt32(bytes.count)
}

/// A register window that may be missing.
final class Window: @unchecked Sendable {
  let regs: Registers
  init(_ regs: consuming Registers) { self.regs = regs }
  func load(_ o: Int) -> UInt32 { regs.load32(o) }
  func store(_ o: Int, _ v: UInt32) { regs.store32(o, v) }
}

/// The combo PHY's register clock (`pclk`, its CLKT's) by its window's
/// base: the four PHYs' (sky1-dp-tx 03 §3.1).
func phyClock(base: UInt64) -> UInt32? {
  switch base {
  case 0x0903_0000: 107
  case 0x090A_0000: 111
  case 0x0911_0000: 115
  case 0x0918_0000: 119
  default: nil
  }
}

/// The core's AUX channel, one request at a time, polled (its AUX
/// interrupts stay masked, as the vendor's driver leaves them), and its
/// PHY where devmgr gave it.
@safe final class Core: TrainingCore, @unchecked Sendable {
  let regs: Registers
  /// The PHY's interface window (the core's third range), the combo PHY's
  /// own registers, and the RCSU's video adapter (the fourth).
  let interface: Window?
  let phy: Window?
  let adapter: Window?
  /// Each lane's drive registers as firmware left them (txcc, driver,
  /// margin, post-cursor): swing and pre-emphasis 0 are these, not the
  /// vendor's table (firmware's differ on the Orange Pi 6 Plus).
  var firmwareDrive: [(UInt32, UInt32, UInt32, UInt32)] = []
  var requests = 0, timeouts = 0

  init(regs: consuming Registers, interface: Window?, phy: Window?, adapter: Window?) {
    self.regs = regs
    self.interface = interface
    self.phy = phy
    self.adapter = adapter
    if let p = phy {
      for lane in 0..<4 {
        firmwareDrive.append((p.load(ComboPHY.offset(ComboPHY.txccControl, lane: lane)),
                              p.load(ComboPHY.offset(ComboPHY.driverDiag, lane: lane)),
                              p.load(ComboPHY.offset(ComboPHY.margin, lane: lane)),
                              p.load(ComboPHY.offset(ComboPHY.postCursor, lane: lane))))
      }
    }
  }

  var hpd: Bool { regs.load32(DPTXRegisters.hpdInputState) & 1 != 0 }

  func setPattern(_ pattern: UInt32, scrambled: Bool) {
    regs.store32(DPTXRegisters.trainingPattern, pattern)
    regs.store32(DPTXRegisters.disableScrambling, scrambled ? 0 : 1)
  }

  /// Each lane's coefficients held while they change (§3.9): level 0 of
  /// both firmware's, the others the vendor's table.
  func setDrive(swing: UInt8, preEmphasis: UInt8) {
    guard let p = phy, firmwareDrive.count == 4 else { return }
    let d = ComboPHY.drive(swing: swing, preEmphasis: preEmphasis)
    for lane in 0..<4 {
      let f = firmwareDrive[lane]
      let v = swing == 0 && preEmphasis == 0 ? f
        : (ComboPHY.txccControlValue, ComboPHY.driverDiagValue, d.margin, d.postCursor)
      let hold = ComboPHY.offset(ComboPHY.txDiagACYA, lane: lane)
      p.store(hold, p.load(hold) | 1)
      p.store(ComboPHY.offset(ComboPHY.txccControl, lane: lane), v.0)
      p.store(ComboPHY.offset(ComboPHY.driverDiag, lane: lane), v.1)
      p.store(ComboPHY.offset(ComboPHY.margin, lane: lane), v.2)
      p.store(ComboPHY.offset(ComboPHY.postCursor, lane: lane), v.3)
      p.store(hold, p.load(hold) & ~1)
    }
  }

  func wait(microseconds: Int) { sleep(until: Clock.monotonic() + Int64(microseconds) * 1000) }

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

  /// Polls `read` for `want` every 1 µs, `budget` times.
  func poll(_ budget: Int, _ want: () -> Bool) -> Bool {
    for _ in 0..<budget {
      if want() { return true }
      wait(microseconds: 1)
    }
    return want()
  }

  /// The lanes to power state `state` (§3.10.3): asked, acknowledged, the
  /// request cleared.
  func power(_ i: Window, _ state: UInt32) -> Bool {
    i.store(PHYInterface.powerStateRequest, state)
    let ok = poll(200) { i.load(PHYInterface.powerStateAck) & 0x1F == state }
    i.store(PHYInterface.powerStateRequest, 0)
    wait(microseconds: 1)
    return ok
  }

  /// The rate PLL1 runs now, if one bin/dptx knows.
  var phyRate: UInt8? {
    guard let p = phy else { return nil }
    return ComboPHY.rate(clockSelect: p.load(ComboPHY.offset(ComboPHY.pll1ClockSelect)) & 0xFFFF,
                         intDiv: p.load(ComboPHY.offset(ComboPHY.pll1IntDiv)) & 0xFFFF,
                         hsClockDivider: p.load(ComboPHY.offset(ComboPHY.hsClockDivider, lane: 0)) & 0xFFFF)
  }

  /// PLL1 set for `rate` (§3.8.3, in §3.10.5's bracket), the stream
  /// already stopped: nil if done, else why not.
  func setPHYRate(_ rate: UInt8) -> String? {
    guard let s = ComboPHY.setting(rate: rate) else { return "the PHY has no setting for \(rateName(rate))" }
    guard let p = phy, let i = interface else { return "no PHY" }
    i.store(PHYInterface.dataEnable, 0)
    _ = power(i, PHYInterface.a3)
    i.store(PHYInterface.pllClockEnable, 0)
    guard poll(100, { i.load(PHYInterface.pllClockAck) & 1 == 0 }) else { return "the lanes' PLL clock stayed on" }
    let control = ComboPHY.offset(ComboPHY.pllControl)
    p.store(control, p.load(control) & ~ComboPHY.pll1Run)
    wait(microseconds: 10)
    for w in ComboPHY.rateWrites(s) { p.store(ComboPHY.offset(w.index, lane: w.lane ?? 0), w.value) }
    p.store(control, p.load(control) | ComboPHY.pll1Run)
    wait(microseconds: 10)
    let locked = poll(1000) { p.load(ComboPHY.offset(ComboPHY.commonStatus)) & ComboPHY.pll1Locked != 0 }
    i.store(PHYInterface.pllClockEnable, 1)
    guard poll(100, { i.load(PHYInterface.pllClockAck) & 1 != 0 }) else { return "the lanes' PLL clock didn't come on" }
    _ = power(i, PHYInterface.a2)
    _ = power(i, PHYInterface.a0)
    i.store(PHYInterface.dataEnable, 1)
    return locked ? nil : "PLL1 didn't lock"
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
  var rawCapabilities: [UInt8] = []
  /// The link trained, and how the last went.
  var trainings = 0, trained = 0
  var lastTraining = ""
  /// The timing the engine's driver last started the stream with; nil
  /// while it is firmware's.
  var timing: StreamTiming?
  var started = 0, lastStart = ""
  /// The link's clients: each one's server, and the changes it was told of.
  var clients: [(server: UInt64, told: Int)] = []
  nonisolated(unsafe) static var dispatcher: IPCDispatcher?
  /// The syncs' polarity as sent: as the mode has them, as firmware
  /// sends them (the vendor's driver inverts them).
  static let invertSyncs = false

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
      rawCapabilities = caps
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
    if trainings > 0 { t += "trained \(trainings), up \(trained): \(lastTraining)\n" }
    if started > 0 { t += "started \(started): \(lastStart)\n" }
    return t
  }

  /// The link as the core has it: its rate and lanes.
  func link(_ core: Core) -> (rate: UInt8, lanes: Int) {
    (UInt8(truncatingIfNeeded: core.regs.load32(DPTXRegisters.linkBandwidth)),
     Int(core.regs.load32(DPTXRegisters.laneCount) & 7))
  }

  /// The stream stopped (the core's lock held): what it was, to restore.
  func stopStream(_ core: Core) -> (video: UInt32, secondary: UInt32) {
    let was = (core.regs.load32(DPTXRegisters.videoStreamEnable), core.regs.load32(DPTXRegisters.secondaryStreamEnable))
    core.regs.store32(DPTXRegisters.secondaryStreamEnable, 0)
    core.regs.store32(DPTXRegisters.videoStreamEnable, 0)
    return was
  }

  /// The link brought up at `rate` on `lanes` lanes, the stream stopped
  /// (02 §2.5.2-2.5.6, the core's lock held): the core told the rate and
  /// lanes, the PHY's PLL1 set where its rate differs, its lanes ready,
  /// then training, then the source enabled. Whether it trained.
  func bringUp(_ core: Core, rate: UInt8, lanes: Int) -> Bool {
    var aux = core
    trainings += 1
    let was = link(core)
    let before = (try? aux.laneStatus(lanes: max(was.lanes, 1)))?.text ?? "unread"
    core.regs.store32(DPTXRegisters.laneCount, UInt32(lanes))
    let framing = capabilities?.enhancedFraming ?? false
    core.regs.store32(DPTXRegisters.enhancedFraming, framing ? 1 : 0)
    core.regs.store32(DPTXRegisters.linkBandwidth, UInt32(rate))
    if core.phyRate != rate {
      if let why = core.setPHYRate(rate) {
        lastTraining = "failed at \(rateName(rate)) x\(lanes): \(why)"
        print("dptx: link: " + lastTraining)
        return false
      }
      // Every lane of the port ready (01 §1.6), within 100 ms.
      let deadline = Clock.monotonic() + 100_000_000
      while core.regs.load32(DPTXRegisters.phyStatus) & 0xF != 0xF, Clock.monotonic() < deadline {
        sleep(until: Clock.monotonic() + 1_000_000)
      }
    }
    var ok = false
    do throws(AUXError) {
      let t = try aux.train(rate: rate, lanes: lanes, caps: rawCapabilities, enhancedFraming: framing,
                            downspread: core.regs.load32(DPTXRegisters.downspread) & 1 != 0)
      ok = t.trained
      lastTraining = (t.trained ? "up" : "failed in " + t.stage) + " at \(rateName(rate)) x\(lanes), swing \(t.swing), "
        + "pre-emphasis \(t.preEmphasis), \(t.tries) tries, lanes \(t.status.text) (was \(rateName(was.rate)) "
        + "x\(was.lanes), \(before))"
    } catch {
      _ = try? aux.finish()
      lastTraining = "aux failed at \(rateName(rate)) x\(lanes): \(error.name)"
    }
    if ok { trained += 1 }
    core.regs.store32(DPTXRegisters.softReset, 1)
    core.regs.store32(DPTXRegisters.sourceEnable, 1)
    core.regs.store32(DPTXRegisters.forceScramblerReset, 1)
    print("dptx: link: " + lastTraining)
    return ok
  }

  /// Source 0's registers for the link now: for the timing started, or
  /// firmware's stream scaled from the link `from` it was set for (its
  /// transfer unit and secondary window go with the link's rate and lanes,
  /// its data count with the lanes).
  func setStream(_ core: Core, from: (rate: UInt8, lanes: Int)) {
    let to = link(core)
    if let t = timing {
      for w in LinkMath.streamRegisters(t, rate: to.rate, lanes: to.lanes, invertSyncs: Self.invertSyncs) {
        core.regs.store32(w.offset, w.value)
      }
      if let a = core.adapter { a.store(VideoAdapter.pipeline0, a.load(VideoAdapter.pipeline0) & ~VideoAdapter.fieldMask) }
      return
    }
    guard from.lanes > 0, to.lanes > 0, from != to else { return }
    let old = UInt64(LinkMath.symbolClock(from.rate)) * UInt64(from.lanes)
    let new = UInt64(LinkMath.symbolClock(to.rate)) * UInt64(to.lanes)
    let tu = core.regs.load32(DPTXRegisters.transferUnit)
    // Rounded up: a transfer unit short of the stream's data overflows.
    let sixteenths = ((UInt64(tu >> 16 & 0xFF) * 16 + UInt64(tu >> 24 & 0xF)) * old + new - 1) / new
    core.regs.store32(DPTXRegisters.transferUnit, 64)
    core.regs.store32(DPTXRegisters.transferUnit, 64 | UInt32(sixteenths / 16 & 0xFF) << 16 | UInt32(sixteenths % 16) << 24)
    let window = UInt64(core.regs.load32(DPTXRegisters.secondaryDataWindow))
    core.regs.store32(DPTXRegisters.secondaryDataWindow,
                      UInt32(truncatingIfNeeded: window * UInt64(LinkMath.symbolClock(to.rate)) / UInt64(LinkMath.symbolClock(from.rate))))
    let width = core.regs.load32(DPTXRegisters.hResolution)
    core.regs.store32(DPTXRegisters.userDataCount, (width * 3 + UInt32(to.lanes) - 1) / UInt32(to.lanes))
  }

  /// `train RATE LANES` (the core's lock held): the link at that rate,
  /// the stream set for it and started again as it was.
  func train(_ core: Core, rate: UInt8, lanes: Int) -> Bool {
    guard connected else { return false }
    let from = link(core)
    let was = stopStream(core)
    let ok = bringUp(core, rate: rate, lanes: lanes)
    setStream(core, from: from)
    core.regs.store32(DPTXRegisters.videoStreamEnable, was.video)
    core.regs.store32(DPTXRegisters.secondaryStreamEnable, was.secondary)
    return ok
  }

  /// Where a monitor is there and the sink has lost the link (a replug:
  /// HPD low drops it), trains it again at its rate and lanes, the stream
  /// stopped meanwhile and started after (the core's lock held).
  func retrainIfLost(_ core: Core) {
    guard connected else { return }
    var aux = core
    let l = link(core)
    guard l.lanes > 0, let status = try? aux.laneStatus(lanes: l.lanes), !status.trained else { return }
    let was = stopStream(core)
    _ = bringUp(core, rate: l.rate, lanes: l.lanes)
    core.regs.store32(DPTXRegisters.videoStreamEnable, was.video)
    core.regs.store32(DPTXRegisters.secondaryStreamEnable, was.secondary)
  }

  /// The stream started for `t` (the core's lock held): the link kept if
  /// it is up and carries it, else brought up on the first of the links
  /// that do which trains.
  func start(_ core: Core, _ t: StreamTiming) throws(DisplayLinkIPC.LinkError) {
    guard t.isValid else { throw .invalid }
    guard connected, let c = capabilities else { throw .noSink }
    let candidates = LinkMath.candidates(clock: t.clock, maxRate: c.maxRate, maxLanes: min(c.maxLanes, 4))
    guard !candidates.isEmpty else { throw .tooFast }
    started += 1
    _ = stopStream(core)
    var aux = core
    let now = link(core)
    let up = now.lanes > 0 && (try? aux.laneStatus(lanes: now.lanes))?.trained == true
    var ok = up && core.phyRate == now.rate && LinkMath.carries(clock: t.clock, rate: now.rate, lanes: now.lanes)
    if !ok {
      for l in candidates where !ok { ok = bringUp(core, rate: l.rate, lanes: l.lanes) }
    }
    guard ok else {
      lastStart = "\(t.text): no link trained"
      throw .trainingFailed
    }
    timing = t
    setStream(core, from: now)
    // The secondary stream (SDPs, audio) stays off, as firmware leaves it.
    core.regs.store32(DPTXRegisters.videoStreamEnable, 1)
    let l = link(core)
    lastStart = "\(t.text) on \(rateName(l.rate)) x\(l.lanes)"
    print("dptx: stream started: " + lastStart)
  }

  /// The sink's lane status now (the core's lock held).
  func lanesText(_ core: Core) -> String {
    guard connected else { return "" }
    var aux = core
    let lanes = Int(core.regs.load32(DPTXRegisters.laneCount) & 7)
    guard let s = try? aux.laneStatus(lanes: lanes) else { return "lanes: unread\n" }
    return "lanes \(s.text): " + (s.trained ? "trained" : s.clockRecovered ? "not equalised" : "lost") + "\n"
  }
}

/// The PHY's state: its mode, PLL1 and the lanes' drive registers.
func phyText(_ core: Core) -> String {
  guard let p = core.phy else { return "phy: none\n" }
  func r(_ index: Int, _ lane: Int = 0) -> UInt32 { p.load(ComboPHY.offset(index, lane: lane)) & 0xFFFF }
  func lanes(_ index: Int) -> String { (0..<4).map { hex(r(index, $0), digits: 4) }.joined(separator: " ") }
  let map = r(ComboPHY.laneMap), status = r(ComboPHY.commonStatus)
  var t = "phy: lane map \(hex(map, digits: 4))" + (map == ComboPHY.displayPortOnly ? " (displayport only)" : "")
  if let i = core.interface { t += ", interface type \(hex(i.load(PHYInterface.idRevision) >> 16, digits: 2))" }
  t += "; pll1 " + (core.phyRate.map { rateName($0) } ?? "rate unknown") + " (clock select \(hex(r(ComboPHY.pll1ClockSelect), digits: 4)), "
    + "int \(hex(r(ComboPHY.pll1IntDiv), digits: 4)), frac \(hex(r(ComboPHY.pll1FracDivL), digits: 4)), "
    + "threshold \(hex(r(ComboPHY.pll1HighThreshold), digits: 4)), trim \(hex(r(ComboPHY.pll1CurrentTrim), digits: 4)), "
    + "spread \(hex(r(ComboPHY.pll1SSControl2), digits: 4)) \(hex(r(ComboPHY.pll1SSControl3), digits: 4)) "
    + "\(hex(r(ComboPHY.pll1SSControl4), digits: 4)), " + (status & ComboPHY.pll1Locked != 0 ? "locked" : "not locked") + ")\n"
  t += "phy lanes: dividers \(lanes(ComboPHY.hsClockDivider)); txcc \(lanes(ComboPHY.txccControl)); "
    + "driver \(lanes(ComboPHY.driverDiag)); margin \(lanes(ComboPHY.margin)); post-cursor \(lanes(ComboPHY.postCursor))\n"
  return t
}

/// Source 0's stream as the core has it.
func streamText(_ core: Core) -> String {
  func r(_ o: Int) -> UInt32 { core.regs.load32(o) }
  let tu = r(DPTXRegisters.transferUnit)
  var t = "stream: \(r(DPTXRegisters.hResolution))x\(r(DPTXRegisters.vResolution)), total \(r(DPTXRegisters.hTotal))x"
    + "\(r(DPTXRegisters.vTotal)), sync \(r(DPTXRegisters.hSyncWidth))x\(r(DPTXRegisters.vSyncWidth)), start "
    + "\(r(DPTXRegisters.hStart))x\(r(DPTXRegisters.vStart)), polarity \(r(DPTXRegisters.polarity)), user sync "
    + "\(hex(r(DPTXRegisters.userSyncPolarity), digits: 1)), misc \(hex(r(DPTXRegisters.misc0), digits: 2)) "
    + "\(hex(r(DPTXRegisters.misc1), digits: 2)), override \(r(DPTXRegisters.streamOverride)); tu \(hex(tu)) "
    + "(\(tu & 0x7F), \(tu >> 16 & 0xFF) \(tu >> 24 & 0xF)/16), data count \(r(DPTXRegisters.userDataCount)), "
    + "window \(r(DPTXRegisters.secondaryDataWindow)), data control \(hex(r(DPTXRegisters.dataControl), digits: 4)), "
    + "pixels a clock \(r(DPTXRegisters.userPixelCount)), video \(r(DPTXRegisters.videoStreamEnable)), "
    + "secondary \(r(DPTXRegisters.secondaryStreamEnable))"
  if let a = core.adapter { t += ", adapter \(hex(a.load(VideoAdapter.pipeline0)))" }
  return t + "\n"
}

/// The probe: the lines it says, the core and the sink if it is live.
func probe(_ ns: Namespace, _ resources: inout DeviceResources, roles: [(index: Int, role: String)])
  -> (lines: [String], core: Core?, sink: Sink?)
{
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
    // The PHY's registers once their clock is on: a read of a gated one
    // can stop the machine.
    var phy: Window?
    if let b = roles.first(where: { $0.role.utf8.elementsEqual("phy".utf8) })?.index, let info = try? resources.bar(b) {
      if let clock = phyClock(base: info.base), command(ns, "/dev/scmi/ctl", "clock \(clock) on"),
        let p = try? resources.map(bar: b)
      {
        phy = Window(p)
        lines.append("phy at \(hex(UInt32(truncatingIfNeeded: info.base))), its clock \(clock) on")
      } else {
        lines.append("phy at \(hex(UInt32(truncatingIfNeeded: info.base))) left alone: its clock unknown or not turned on")
      }
    }
    var interface: Window?, adapter: Window?
    if let r = try? resources.map(bar: 2) { interface = Window(r) }
    if let r = try? resources.map(bar: 3) { adapter = Window(r) }
    let core = Core(regs: regs, interface: interface, phy: phy, adapter: adapter)
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
      sink.retrainIfLost(core)
    }
    tell(sink)
    print("dptx: hpd " + (sink.hpd ? "high" : "low") + ", sink count \(sink.count)")
  }
}

/// The link's clients told, each by its own server's thread.
func tell(_ sink: Sink) {
  let servers = sink.lock.withLock { sink.clients.map { $0.server } }
  if let d = Sink.dispatcher { for s in servers { d.wake(s) } }
}

/// A rate's code from its name (`rbr`, `hbr`, `hbr2`).
func rateCode(_ name: [UInt8]) -> UInt8? {
  if name == Array("rbr".utf8) { return 0x06 }
  if name == Array("hbr".utf8) { return 0x0A }
  if name == Array("hbr2".utf8) { return 0x14 }
  return nil
}

@main struct DPTXDriver {
  static func main() {
    let start = Startup.current
    var resources = DeviceResources(take: { start.take($0)?.release() })
    // `--bar=INDEX:ROLE`: which BAR each linked range is.
    var roles: [(index: Int, role: String)] = []
    for a in start.args where a.utf8.starts(with: "--bar=".utf8) {
      let rest = Array(a.utf8.dropFirst(6))
      guard let colon = rest.firstIndex(of: 0x3A), let i = Int(String(decoding: rest[..<colon], as: UTF8.self)) else { continue }
      roles.append((i, String(decoding: rest[(colon + 1)...], as: UTF8.self)))
    }
    var probed: (lines: [String], core: Core?, sink: Sink?) = (["FAILED: no namespace"], nil, nil)
    if let ns = try? Namespace(start) { probed = probe(ns, &resources, roles: roles) }
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
    if let sink, let core {
      let text = sink.lock.withLock { sink.text + phyText(core) + streamText(core) }
      said += "; " + text.utf8.split(separator: 0x0A).map { String(decoding: $0, as: UTF8.self) }.joined(separator: "; ")
    }
    print(said)

    do throws(Status) {
      let dispatcher = try IPCDispatcher()
      let tree = NodeTree(dispatcher: dispatcher)
      let status = lines.map { $0 + "\n" }.joined()
      tree.text("status", read: {
        guard let sink, let core else { return status }
        return status + sink.lock.withLock {
          sink.text + sink.lanesText(core) + phyText(core) + streamText(core) + "hpd events \(sink.events), pulses "
            + "\(sink.pulses), changes \(sink.changes); aux requests \(core.requests), timeouts \(core.timeouts)\n"
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
      // `train RATE LANES`: the link at another rate, the stream kept.
      tree.text("ctl", read: { "" }, write: { (text: String) throws(NodeError) in
        guard let sink, let core else { throw .io }
        for line in text.utf8.split(separator: 0x0A) {
          let w = line.split(separator: 0x20).map { Array($0) }
          guard w.count == 3, w[0] == Array("train".utf8), let rate = rateCode(w[1]),
            let lanes = Int(String(decoding: w[2], as: UTF8.self)), lanes == 1 || lanes == 2 || lanes == 4
          else { throw .invalid }
          let ok = sink.lock.withLock { sink.train(core, rate: rate, lanes: lanes) }
          if !ok { throw .io }
        }
      })
      // The link (DisplayLinkIPC): what the sink is, and each change told.
      Sink.dispatcher = dispatcher
      tree.service("link") { (channel: consuming Handle) throws(Status) in
        guard let sink, let core else { throw .notSupported }
        let c = LinkClient()
        let told = sink.lock.withLock { sink.changes }
        c.id = try dispatcher.add(DisplayLinkIPC.LinkServer(channel: channel, impl: LinkSession(sink: sink, core: core))) {
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
  let core: Core
  init(sink: Sink, core: Core) {
    state = sink
    self.core = core
  }

  func sink() -> DisplayLinkIPC.Sink {
    state.lock.withLock { DisplayLinkIPC.Sink(connected: state.connected, count: UInt32(state.count)) }
  }

  func edid() -> [UInt8] { state.lock.withLock { state.edid } }

  func capacity() -> UInt32 {
    state.lock.withLock {
      guard state.connected, let c = state.capabilities else { return 0 }
      return LinkMath.capacity(maxRate: c.maxRate, maxLanes: c.maxLanes)
    }
  }

  func stop() { state.lock.withLock { _ = state.stopStream(core) } }

  func start(timing: DisplayLinkIPC.Timing) throws(DisplayLinkIPC.LinkError) {
    let t = StreamTiming(clock: timing.clock, hActive: timing.hActive, hSyncStart: timing.hSyncStart,
                         hSyncEnd: timing.hSyncEnd, hTotal: timing.hTotal, vActive: timing.vActive,
                         vSyncStart: timing.vSyncStart, vSyncEnd: timing.vSyncEnd, vTotal: timing.vTotal,
                         hPositive: timing.flags & 1 != 0, vPositive: timing.flags & 2 != 0)
    try state.lock.withLock { () throws(DisplayLinkIPC.LinkError) in try state.start(core, t) }
  }
}
