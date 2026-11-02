// SPDX-License-Identifier: BSD-3-Clause

// The controller as bin/sdhci drives it (Sdhci.swift has its registers):
// set up at 3.3 V, an SD card brought up by its commands, polled, then
// its sectors read and written by ADMA2 through one bounce buffer, a
// request at a time, each ended by the controller's interrupt. Where the
// board can take the card's signalling to 1.8 V (the K1's SD slot: its
// supply and pads, a `Signalling`), a UHS card is switched (CMD11) and
// run at SDR104, its receive clock's delay found by a sweep of CMD19
// (spacemit-k1 03 §3.8), or else at SDR50.

import CroiMMIO
import DriverHost
import IPC
import Node
import Sd
import Sys

/// Why bringing up the controller or the card stopped.
public struct HostError: Error, Sendable {
  public let what: String
  /// Nothing answered the first command that asks: no card of that kind.
  public let absent: Bool
  /// Taking the card to 1.8 V failed: it may answer again at 3.3 V.
  public let switching: Bool
  init(_ what: String, absent: Bool = false, switching: Bool = false) {
    self.what = what
    self.absent = absent
    self.switching = switching
  }
}

/// How a board takes a card's signalling to 1.8 V and back: its supply
/// set to a voltage, in µV, and its pads set for 1.8 V or for 3.3 V;
/// each false if it couldn't be.
public struct Signalling {
  public var supply: (UInt32) -> Bool
  public var pads: (_ at18: Bool) -> Bool
  /// The UHS modes the board's slot allows (its node's `sd-uhs-*`).
  public var speeds: [BusSpeed]

  public init(supply: @escaping (UInt32) -> Bool, pads: @escaping (Bool) -> Bool, speeds: [BusSpeed]) {
    self.supply = supply
    self.pads = pads
    self.speeds = speeds
  }
}

public final class Host: @unchecked Sendable {
  let regs: Registers
  /// The SpacemiT K1's registers past the standard ones are there.
  let k1: Bool
  public let version: UInt8
  public let capabilities: UInt32
  /// The base clock, in Hz.
  public let base: UInt64
  public private(set) var clock: UInt64 = 0
  /// Set before `setUp`: the card may then be taken to 1.8 V.
  public var signalling: Signalling?
  /// The card's signalling at 1.8 V.
  public private(set) var at18 = false
  /// The bus speed mode the card runs.
  public private(set) var speed = BusSpeed.defaultSpeed
  /// The receive delay code the sweep chose, and its window.
  public private(set) var receiveDelay: (code: Int, window: Range<Int>)?
  /// What bring-up passed over: a UHS mode that failed, a supply refused.
  public private(set) var notes: [String] = []

  /// `base`, in Hz, where the capabilities don't give it (the K1's).
  public init(_ regs: consuming Registers, k1: Bool, base: UInt64 = 0) {
    version = UInt8(truncatingIfNeeded: regs.load16(Register.hostVersion))
    capabilities = regs.load32(Register.capabilities)
    self.regs = regs
    self.k1 = k1
    self.base = base != 0 ? base : Sdhci.baseClock(capabilities, version: version)
  }

  func load8(_ r: Int) -> UInt8 { regs.load8(r) }
  func load16(_ r: Int) -> UInt16 { regs.load16(r) }
  func load32(_ r: Int) -> UInt32 { regs.load32(r) }
  func store8(_ r: Int, _ v: UInt8) { regs.store8(r, v) }
  func store16(_ r: Int, _ v: UInt16) { regs.store16(r, v) }
  func store32(_ r: Int, _ v: UInt32) { regs.store32(r, v) }

  /// Waits up to `ns` for `done`; false if it never was.
  func poll(_ ns: Int64, _ done: () -> Bool) -> Bool {
    let deadline = Clock.monotonic() + ns
    while !done() {
      guard Clock.monotonic() < deadline else { return done() }
    }
    return true
  }

  /// Resets the lines in `bits` and waits for the controller to finish.
  func reset(_ bits: UInt8) throws(HostError) {
    store8(Register.softwareReset, bits)
    guard poll(100_000_000, { self.load8(Register.softwareReset) & bits == 0 }) else {
      throw HostError("the controller stays in reset")
    }
  }

  /// The controller reset, its K1 PHY and pads set (spacemit-k1 03 §3.5),
  /// 3.3 V on, ADMA2, every status reported but none signalled,
  /// and the card's clock at 400 kHz.
  public func setUp() throws(HostError) {
    guard capabilities & Bits.adma2Support != 0 || k1 else { throw HostError("no ADMA2") }
    try reset(Bits.resetAll)
    if k1 {
      store32(K1.phyControl, load32(K1.phyControl) | K1.phyOn)
      store32(K1.phyPads, load32(K1.phyPads) & ~K1.padsMask | K1.pads)
      // The pad's clock generated, and for an SD slot that goes to 1.8 V
      // the card's clock always on, never gated between commands: the
      // card must see it to finish its switch.
      store32(K1.legacyControl, load32(K1.legacyControl) | K1.padClock)
      if signalling != nil { store32(K1.operationExtra, load32(K1.operationExtra) | K1.forceClock) }
    }
    // Signalling at 3.3 V, whatever a warm boot left (its pads' 3.3 V
    // state is the driver's default, already set).
    if let s = signalling, !s.supply(3_300_000) { notes.append("the signalling supply refused 3.3 V") }
    store16(Register.hostControl2, 0)
    store8(Register.powerControl, Bits.power33)
    store8(Register.timeoutControl, 0xE)
    store8(Register.hostControl, load8(Register.hostControl) & ~(Bits.dmaSelect | Bits.fourBit | Bits.highSpeed)
      | Bits.adma2)
    store16(Register.normalStatusEnable, 0x003B)
    store16(Register.errorStatusEnable, 0x03FF)
    store16(Register.normalSignalEnable, 0)
    store16(Register.errorSignalEnable, 0)
    try setClock(400_000)
  }

  /// The card's clock at the fastest at most `hz`.
  public func setClock(_ hz: UInt64) throws(HostError) {
    guard base != 0 else { throw HostError("no base clock") }
    store16(Register.clockControl, 0)
    // The K1 transmits on its internal clock, for the hold time, at
    // SDR50 and below; at SDR104 on the card's.
    if k1 {
      let v = load32(K1.transmitConfig)
      store32(K1.transmitConfig, speed == .sdr104 ? v & ~K1.internalTransmitClock : v | K1.internalTransmitClock)
    }
    let (field, actual) = Sdhci.divider(base: base, target: hz, version: version)
    store16(Register.clockControl, field | Bits.internalClock)
    guard poll(20_000_000, { self.load16(Register.clockControl) & Bits.internalStable != 0 }) else {
      throw HostError("the internal clock never steadies")
    }
    store16(Register.clockControl, field | Bits.internalClock | Bits.cardClock)
    clock = actual
  }

  /// Signals the end of a transfer and every error (after bring-up).
  public func enableInterrupts() {
    store16(Register.normalStatus, 0xFFFF)
    store16(Register.errorStatus, 0xFFFF)
    store16(Register.normalSignalEnable, Bits.transferComplete)
    store16(Register.errorSignalEnable, 0x03FF)
  }

  // MARK: Commands, polled

  /// Sends command `index`, waits for it (and for its busy, an R1b) and
  /// returns its response's words; on an error the command line is reset
  /// and `failure` thrown. `data`: a transfer the caller has set up.
  @discardableResult
  public func send(_ index: UInt8, _ argument: UInt32, _ response: Response, data: Bool = false,
                   timeout: Int64 = 1_000_000_000) throws(HostError) -> [UInt32] {
    let inhibit = Bits.commandInhibit | (response == .busy || data ? Bits.dataInhibit : 0)
    guard poll(timeout, { self.load32(Register.presentState) & inhibit == 0 }) else {
      throw HostError("CMD\(index): the lines stay busy")
    }
    store16(Register.normalStatus, 0xFFFF)
    store16(Register.errorStatus, 0xFFFF)
    store32(Register.argument, argument)
    store16(Register.command, Sdhci.command(index, response, data: data))
    let ended = poll(timeout) { self.load16(Register.normalStatus) & (Bits.commandComplete | Bits.errorInterrupt) != 0 }
    let status = load16(Register.normalStatus)
    guard ended, status & Bits.errorInterrupt == 0 else {
      let error = load16(Register.errorStatus)
      try? reset(Bits.resetCommand | Bits.resetData)
      throw HostError(ended ? "CMD\(index): error 0x\(String(error, radix: 16))" : "CMD\(index): no answer")
    }
    store16(Register.normalStatus, Bits.commandComplete)
    if response == .busy {
      guard poll(timeout, { self.load16(Register.normalStatus) & (Bits.transferComplete | Bits.errorInterrupt) != 0 })
      else { throw HostError("CMD\(index): busy for good") }
      store16(Register.normalStatus, Bits.transferComplete)
    }
    var words = [UInt32](repeating: 0, count: 4)
    for i in 0..<4 { words[i] = load32(Register.response + 4 * i) }
    return words
  }

  /// An application command: CMD55 to the card at `rca`, then `index`.
  @discardableResult
  public func sendApplication(_ index: UInt8, _ argument: UInt32, _ response: Response, rca: UInt32 = 0)
    throws(HostError) -> [UInt32]
  {
    try send(55, rca << 16, .short)
    return try send(index, argument, response)
  }

  /// A command that reads one block of `bytes` (at most 512) through the
  /// buffer data port, as CMD6's status.
  public func read(_ index: UInt8, _ argument: UInt32, bytes: Int, timeout: Int64 = 1_000_000_000)
    throws(HostError) -> [UInt8]
  {
    store16(Register.blockSize, UInt16(bytes))
    store16(Register.blockCount, 1)
    store16(Register.transferMode, Bits.readDirection)
    try send(index, argument, .short, data: true, timeout: timeout)
    let ready = poll(timeout) { self.load16(Register.normalStatus) & (Bits.bufferReadReady | Bits.errorInterrupt) != 0 }
    guard ready, load16(Register.normalStatus) & Bits.errorInterrupt == 0 else {
      try? reset(Bits.resetCommand | Bits.resetData)
      throw HostError("CMD\(index): no data")
    }
    store16(Register.normalStatus, Bits.bufferReadReady)
    var out: [UInt8] = []
    for _ in 0..<(bytes + 3) / 4 {
      let w = load32(0x20)
      for b in 0..<4 { out.append(UInt8(truncatingIfNeeded: w >> UInt32(8 * b))) }
    }
    _ = poll(timeout) { self.load16(Register.normalStatus) & Bits.transferComplete != 0 }
    store16(Register.normalStatus, 0xFFFF)
    return Array(out.prefix(bytes))
  }

  // MARK: The card

  /// What bring-up learnt of the card.
  public struct Card: Sendable {
    /// An eMMC rather than an SD card.
    public var mmc: Bool
    /// The bus's width, 4 or 8.
    public var width: Int
    public var rca: UInt32
    public var highCapacity: Bool
    public var sectors: UInt64
    public var name: String
    public var highSpeed: Bool
    /// Its bus speed mode, as status says it: `high speed`, `SDR104`.
    public var mode: String
  }

  /// Brings up the card in the slot: an SD card, else, where nothing
  /// answers SD's ACMD41, an eMMC. A card that fails
  /// its switch to 1.8 V is brought up again at 3.3 V.
  public func identify() throws(HostError) -> Card {
    do throws(HostError) {
      do throws(HostError) {
        return try identifySD(uhs: signalling != nil)
      } catch let error where error.switching {
        notes.append(error.what)
        try backTo33()
        return try identifySD(uhs: false)
      }
    } catch {
      guard error.absent else { throw error }
      do throws(HostError) {
        return try identifyMMC()
      } catch let mmc {
        guard mmc.absent else { throw mmc }
        throw HostError("no SD card or eMMC answers", absent: true)
      }
    }
  }

  /// The SD card, as the Physical Layer Specification's initialization
  /// goes: idle, the interface condition, ACMD41 until it is ready
  /// (asking for 1.8 V with `uhs`, and switching if the card says yes),
  /// its CID, address and CSD, selected, a 4-bit bus, then its fastest
  /// bus speed: at 1.8 V, SDR104 or SDR50 as the slot allows, else SDR25;
  /// at 3.3 V, high speed (50 MHz) if it switches, else 25 MHz.
  func identifySD(uhs: Bool) throws(HostError) -> Card {
    speed = .defaultSpeed
    receiveDelay = nil
    try send(0, 0, .none)
    // CMD8: a version 2 card echoes the check pattern; an older one
    // doesn't answer, and takes no high capacity.
    var version2 = false
    if let r = try? send(8, 0x1AA, .short) {
      guard r[0] & 0xFFF == 0x1AA else { throw HostError("CMD8: echo 0x\(String(r[0], radix: 16))") }
      version2 = true
    }
    // S18R only with a version 2 card and a version 3 controller.
    let uhs = uhs && version2 && version >= 2
    var request = version2 ? OCR.request : OCR.request & ~OCR.highCapacity
    if uhs { request |= OCR.switch18 }
    var ocr: UInt32 = 0
    let deadline = Clock.monotonic() + 1_000_000_000
    repeat {
      do throws(HostError) {
        ocr = try sendApplication(41, request, .ocr)[0]
      } catch {
        throw HostError("no SD card answers (\(error.what))", absent: true)
      }
      if ocr & OCR.ready == 0 { sleep(until: Clock.monotonic() + 10_000_000) }
    } while ocr & OCR.ready == 0 && Clock.monotonic() < deadline
    guard ocr & OCR.ready != 0 else { throw HostError("the card stays busy") }
    if uhs, ocr & OCR.switch18 != 0 { try switchTo18(command: true) }
    let cid = try send(2, 0, .long)
    let rca = try send(3, 0, .short)[0] >> 16
    guard let csd = CSD(try send(9, rca << 16, .long)) else { throw HostError("a CSD of no known structure") }
    try send(7, rca << 16, .busy)
    try sendApplication(6, 2, .short, rca: rca)
    store8(Register.hostControl, load8(Register.hostControl) | Bits.fourBit)
    try send(16, 512, .short)
    // CMD6 in mode 0: the bus speeds the card offers, nothing switched.
    // A card a warm boot left at 1.8 V offers UHS's, though it didn't
    // say S18A: its host is switched without CMD11 (spacemit-k1 03 §3.7).
    let offered = (try? read(6, 0x00FF_FFFF, bytes: 64)).flatMap { SwitchStatus($0) }
    if uhs, !at18, let offered, offered.at18 { try switchTo18(command: false) }
    var choices: [BusSpeed] = [.highSpeed]
    if at18, let s = signalling { choices = [.sdr104, .sdr50].filter { s.speeds.contains($0) } + choices }
    for s in choices where offered?.supports(s) ?? (s == .highSpeed) {
      do throws(HostError) {
        try use(s)
        break
      } catch {
        notes.append("\(s.name): \(error.what)")
        speed = .defaultSpeed
        try setClock(25_000_000)
      }
    }
    if speed == .defaultSpeed { try setClock(25_000_000) }
    let mode = speed == .highSpeed && at18 ? "SDR25" : speed.name
    return Card(mmc: false, width: 4, rca: rca, highCapacity: ocr & OCR.highCapacity != 0, sectors: csd.sectors,
                name: Sdhci.productName(cid), highSpeed: speed != .defaultSpeed, mode: mode)
  }

  /// The card switched to bus speed `s` (CMD6, function group 1: its
  /// status's bits 379:376 say which function it switched to), the
  /// controller's timing and clock with it, and at 100 MHz or more its
  /// receive delay tuned.
  func use(_ s: BusSpeed) throws(HostError) {
    guard let status = SwitchStatus(try read(6, 0x80FF_FFF0 | UInt32(s.rawValue), bytes: 64)),
      status.selected == s.rawValue
    else { throw HostError("CMD6 didn't switch") }
    store8(Register.hostControl, load8(Register.hostControl) | Bits.highSpeed)
    if at18 { store16(Register.hostControl2, load16(Register.hostControl2) & ~Bits.uhsMode | s.uhsMode) }
    speed = s
    try setClock(s.hz)
    if clock >= 100_000_000 { try tune() }
  }

  // MARK: 1.8 V

  /// The card's signalling and the controller's to 1.8 V, as the SD
  /// specification's switch goes: CMD11 (unless the card is there
  /// already), DAT0 low; the clock stopped; the supply to 1.8 V, the
  /// controller's 1.8 V bit, then the pads; 10 ms; the clock again, and
  /// after 1 ms the card lets DAT0 go (the K1's card clock is always on
  /// for it: `setUp`).
  func switchTo18(command: Bool) throws(HostError) {
    guard let s = signalling else { throw HostError("no 1.8 V signalling", switching: true) }
    // The lines' levels (present state's CMD, bit 24, and DAT[3:0],
    // 23:20) at each step, for a switch that fails.
    var seen: [String] = []
    func lines(_ step: String) {
      seen.append("\(step) 0x\(String(load32(Register.presentState) >> 20 & 0x1F, radix: 16))")
    }
    func failed(_ what: String) -> HostError {
      HostError(what + " (CMD and DAT[3:0]: " + seen.joined(separator: ", ") + ")", switching: true)
    }
    if command {
      do throws(HostError) {
        try send(11, 0, .short)
      } catch {
        throw HostError("CMD11: \(error.what)", switching: true)
      }
      sleep(until: Clock.monotonic() + 1_000_000)
      lines("after CMD11")
      guard load32(Register.presentState) & Bits.dat0Level == 0 else { throw failed("CMD11: the card didn't hold DAT0 low") }
    }
    let was = clock
    store16(Register.clockControl, 0)
    guard s.supply(1_800_000) else { throw failed("the signalling supply refused 1.8 V") }
    lines("at 1.8 V")
    store16(Register.hostControl2, load16(Register.hostControl2) | Bits.signalling18)
    guard s.pads(true) else { throw failed("the pads' 1.8 V state was refused") }
    lines("pads at 1.8 V")
    sleep(until: Clock.monotonic() + 10_000_000)
    guard load16(Register.hostControl2) & Bits.signalling18 != 0 else { throw failed("the controller's 1.8 V bit didn't stay") }
    try setClock(was == 0 ? 400_000 : was)
    // The card lets DAT0 go 1 ms after the clock; waited up to 100 ms.
    let start = Clock.monotonic()
    sleep(until: start + 1_000_000)
    lines("1 ms after the clock")
    guard poll(100_000_000, { self.load32(Register.presentState) & Bits.dat0Level != 0 }) else {
      lines("100 ms after")
      throw failed("the card held DAT0 low after its switch to 1.8 V")
    }
    if Clock.monotonic() - start > 2_000_000 {
      notes.append("DAT0 went high \((Clock.monotonic() - start) / 1_000_000) ms after the clock")
    }
    at18 = true
  }

  /// Signalling back at 3.3 V after a switch that failed: supply,
  /// controller and pads, the clock at 400 kHz again.
  func backTo33() throws(HostError) {
    at18 = false
    store16(Register.hostControl2, 0)
    if let s = signalling {
      if !s.supply(3_300_000) { notes.append("the signalling supply refused 3.3 V") }
      if !s.pads(false) { notes.append("the pads' 3.3 V state was refused") }
    }
    sleep(until: Clock.monotonic() + 10_000_000)
    store8(Register.hostControl, load8(Register.hostControl) & ~(Bits.fourBit | Bits.highSpeed))
    try setClock(400_000)
  }

  /// The K1's receive delay, by its software tuning (spacemit-k1 03 §3.8):
  /// the transmit line at its code, the receive clock through its line
  /// (range 9), then CMD19 at each code from 0 to 254, and the middle of
  /// the longest run that read the tuning block right, read right once
  /// more.
  func tune() throws(HostError) {
    guard k1 else { throw HostError("no tuning but the K1's") }
    let receive = load32(K1.receiveConfig)
    store32(K1.delayConfig, load32(K1.delayConfig) & ~(0xFF << 16 | 0x1FF) | K1.receiveRange)
    store32(K1.delayControl, load32(K1.delayControl) & ~(0xFF << 24) | K1.transmitCode << 24)
    store32(K1.transmitConfig, load32(K1.transmitConfig) | K1.transmitThroughLine)
    store32(K1.delayControl, load32(K1.delayControl) | K1.delayPower)
    sleep(until: Clock.monotonic() + 5_000)
    store32(K1.receiveConfig, load32(K1.receiveConfig) & ~K1.receiveSelectMask | K1.receiveThroughLine)
    var passed: [Bool] = []
    for code in 0..<255 {
      store32(K1.delayControl, load32(K1.delayControl) & ~(0xFF << 16) | UInt32(code) << 16)
      let block = try? read(19, 0, bytes: 64, timeout: 10_000_000)
      passed.append(block.map { Sdhci.isTuningBlock($0) } ?? false)
    }
    guard let d = Sdhci.delay(passed, least: K1.leastWindow) else {
      // The clocks back as they were, for a slower mode.
      store32(K1.receiveConfig, receive)
      store32(K1.transmitConfig, load32(K1.transmitConfig) & ~K1.transmitThroughLine)
      throw HostError("tuning: no \(K1.leastWindow) codes in a row read right (\(passed.filter { $0 }.count) of 255 did)")
    }
    store32(K1.delayControl, load32(K1.delayControl) & ~(0xFF << 16) | UInt32(d.code) << 16)
    guard (try? read(19, 0, bytes: 64, timeout: 10_000_000)).map({ Sdhci.isTuningBlock($0) }) == true else {
      store32(K1.receiveConfig, receive)
      store32(K1.transmitConfig, load32(K1.transmitConfig) & ~K1.transmitThroughLine)
      throw HostError("tuning: code \(d.code) of \(d.window.lowerBound)-\(d.window.upperBound - 1) didn't read right again")
    }
    receiveDelay = d
  }

  /// The eMMC, as JEDEC's eMMC 5.1 brings a device up: idle, CMD1 until it
  /// is ready (offering sector addressing), its CID, the address the host
  /// gives it, its CSD, selected, its EXT_CSD read (its size and speeds),
  /// then CMD6 switches: an 8-bit bus where the host has one, else 4-bit,
  /// and high speed (52 MHz) where the device has it, else 26 MHz. On the
  /// K1 the controller is put in its MMC mode first.
  func identifyMMC() throws(HostError) -> Card {
    if k1 { store32(K1.mmcControl, load32(K1.mmcControl) | K1.cardMode) }
    try send(0, 0, .none)
    var ocr: UInt32 = 0
    let deadline = Clock.monotonic() + 1_000_000_000
    repeat {
      do throws(HostError) {
        ocr = try send(1, OCR.mmcRequest, .ocr)[0]
      } catch {
        throw HostError("no eMMC answers (\(error.what))", absent: true)
      }
      if ocr & OCR.ready == 0 { sleep(until: Clock.monotonic() + 10_000_000) }
    } while ocr & OCR.ready == 0 && Clock.monotonic() < deadline
    guard ocr & OCR.ready != 0 else { throw HostError("the eMMC stays busy") }
    let cid = try send(2, 0, .long)
    let rca: UInt32 = 1
    try send(3, rca << 16, .short)
    guard let csd = CSD(try send(9, rca << 16, .long), mmc: true) else { throw HostError("no CSD") }
    try send(7, rca << 16, .busy)
    let ext = ExtCSD(try read(8, 0, bytes: 512))
    let eight = capabilities & Bits.eightBitSupport != 0
    try switchMMC(ExtCSD.busWidth, eight ? 2 : 1, rca: rca)
    store8(Register.hostControl, load8(Register.hostControl) & ~(Bits.fourBit | Bits.eightBit)
      | (eight ? Bits.eightBit : Bits.fourBit))
    var highSpeed = false
    if ext.highSpeed52, (try? switchMMC(ExtCSD.highSpeedTiming, 1, rca: rca)) != nil {
      store8(Register.hostControl, load8(Register.hostControl) | Bits.highSpeed)
      highSpeed = true
    }
    try setClock(highSpeed ? 52_000_000 : 26_000_000)
    // Above 2 GiB a device is addressed by sector, and EXT_CSD's count is
    // its size; at 2 GiB or below, by byte, its count 0 and its CSD's the
    // size.
    let sectorMode = ocr & OCR.highCapacity != 0
    return Card(mmc: true, width: eight ? 8 : 4, rca: rca, highCapacity: sectorMode,
                sectors: ext.sectors != 0 ? ext.sectors : csd.sectors,
                name: Sdhci.productName(cid, mmc: true), highSpeed: highSpeed,
                mode: highSpeed ? "high speed" : "default speed")
  }

  /// CMD6, a write of `value` to EXT_CSD byte `index`, waited out, then
  /// CMD13's status read for a switch the device refused.
  func switchMMC(_ index: Int, _ value: UInt8, rca: UInt32) throws(HostError) {
    try send(6, 3 << 24 | UInt32(index) << 16 | UInt32(value) << 8, .busy)
    let status = try send(13, rca << 16, .short)[0]
    guard status & 1 << 7 == 0 else { throw HostError("CMD6: EXT_CSD[\(index)] = \(value) refused") }
  }
}

/// The card as the block class's disk: requests split into pieces of the
/// bounce buffer, one piece at a time, CMD18 or CMD25 (CMD17 or CMD24 for
/// one sector) by ADMA2 with the controller's CMD12.
public final class SdhciDisk: Disk, @unchecked Sendable {
  public let name: String
  public let sectors: UInt64
  public let sectorSize = 512
  public let readOnly = false
  public let chunk: Int
  public private(set) var requests = 0
  public private(set) var failures = 0
  public private(set) var lastError: UInt16 = 0

  let host: Host
  let card: Host.Card
  /// Kept: the buffer and table live as long as it does.
  let memory: DMAMemory
  let lock = Lock()
  let bufferAddress: UInt, bufferBus: UInt32
  let tableAddress: UInt, tableBus: UInt32
  var under: Piece?
  var waiting: [Piece] = []

  struct Piece {
    var read: Bool
    var sector: UInt64
    var data: SectorBuffer
    var request: Request
  }

  final class Request: @unchecked Sendable {
    var left: Int
    var failure: NodeIPC.NodeError?
    let done: @Sendable (NodeIPC.NodeError?) -> Void
    init(_ left: Int, _ done: @escaping @Sendable (NodeIPC.NodeError?) -> Void) {
      self.left = left
      self.done = done
    }
  }

  public init(_ host: Host, card: Host.Card, memory: DMAMemory, chunk: Int = 128 * 1024) throws(Status) {
    let buffer = try unsafe memory.allocate(bytes: chunk)
    let table = try unsafe memory.allocate(bytes: 4096)
    guard unsafe buffer.bus + UInt64(chunk) <= 1 << 32, unsafe table.bus < 1 << 32 else { throw Status.outOfRange }
    bufferAddress = unsafe UInt(bitPattern: buffer.pointer)
    bufferBus = unsafe UInt32(buffer.bus)
    tableAddress = unsafe UInt(bitPattern: table.pointer)
    tableBus = unsafe UInt32(table.bus)
    self.host = host
    self.card = card
    self.memory = memory
    self.chunk = chunk
    name = card.name
    sectors = card.sectors
  }

  var buffer: UnsafeMutableRawPointer { unsafe UnsafeMutableRawPointer(bitPattern: bufferAddress)! }

  // MARK: Disk

  public func start(_ op: SdOp, sector: UInt64, _ data: SectorBuffer,
                    done: @escaping @Sendable (NodeIPC.NodeError?) -> Void) {
    let count = UInt64(data.count / sectorSize)
    guard data.count % sectorSize == 0, sector <= sectors, count <= sectors - sector, count > 0 else {
      return done(data.count == 0 ? nil : .invalid)
    }
    let pieces = (data.count + chunk - 1) / chunk
    let request = Request(pieces, done)
    var all: [Piece] = []
    for p in 0..<pieces {
      let at = p * chunk
      let n = min(chunk, data.count - at)
      let part = unsafe SectorBuffer(UnsafeMutableRawBufferPointer(rebasing: data.bytes[at..<(at + n)]))
      all.append(Piece(read: op == .read, sector: sector + UInt64(at / sectorSize), data: part, request: request))
    }
    lock.withLock {
      waiting += all
      if under == nil { sendNext() }
    }
  }

  /// A write is on the card when its CMD12's busy ends, before it is
  /// answered: there is no cache to flush.
  public func flush(done: @escaping @Sendable (NodeIPC.NodeError?) -> Void) { done(nil) }

  /// Under the lock: the next piece's data into the buffer (a write), its
  /// table, and its command.
  func sendNext() {
    guard !waiting.isEmpty else { return }
    let piece = waiting.removeFirst()
    let bytes = piece.data.count, blocks = bytes / sectorSize
    if !piece.read { unsafe buffer.copyMemory(from: piece.data.bytes.baseAddress!, byteCount: bytes) }
    let table = Sdhci.adma2(bus: bufferBus, bytes: bytes)
    let entries = unsafe UnsafeMutablePointer<UInt64>(bitPattern: tableAddress)!
    for (i, d) in table.enumerated() { unsafe entries[i] = d }
    croi_dma_barrier()  // the data and table before the controller is told
    under = piece
    host.store32(Register.admaAddress, tableBus)
    host.store32(Register.admaAddress + 4, 0)
    host.store16(Register.blockSize, UInt16(sectorSize))
    host.store16(Register.blockCount, UInt16(blocks))
    host.store16(Register.transferMode, Sdhci.transferMode(read: piece.read, blocks: blocks))
    host.store32(Register.argument, UInt32(truncatingIfNeeded: card.highCapacity ? piece.sector : piece.sector * 512))
    let index: UInt8 = piece.read ? (blocks > 1 ? 18 : 17) : (blocks > 1 ? 25 : 24)
    host.store16(Register.command, Sdhci.command(index, .short, data: true))
  }

  /// Ends the piece under way if the controller says it has: a read's
  /// data copied out, `done` once a request's last piece is over; then
  /// the next. An error resets the command and data lines and fails it.
  public func serviceInterrupt() {
    var ended: Request?
    lock.withLock {
      let status = host.load16(Register.normalStatus)
      let error = host.load16(Register.errorStatus)
      guard status & (Bits.transferComplete | Bits.errorInterrupt) != 0 else { return }
      host.store16(Register.errorStatus, error)
      host.store16(Register.normalStatus, status)
      guard let piece = under else { return }
      under = nil
      requests += 1
      if status & Bits.errorInterrupt != 0 {
        failures += 1
        lastError = error
        try? host.reset(Bits.resetCommand | Bits.resetData)
        if piece.request.failure == nil { piece.request.failure = .io }
      } else if piece.read {
        croi_dma_barrier()  // the controller's writes before they are read
        unsafe piece.data.bytes.baseAddress!.copyMemory(from: buffer, byteCount: piece.data.count)
      }
      piece.request.left -= 1
      if piece.request.left == 0 { ended = piece.request }
      sendNext()
    }
    if let r = ended { r.done(r.failure) }
  }
}
