// SPDX-License-Identifier: BSD-3-Clause

// The controller as bin/sdhci drives it (Sdhci.swift has its registers):
// set up at 3.3 V, an SD card brought up by its commands, polled, then
// its sectors read and written by ADMA2 through one bounce buffer, a
// request at a time, each ended by the controller's interrupt.

import CroiMMIO
import DriverHost
import IPC
import Node
import Sd
import Sys

/// Why bringing up the controller or the card stopped.
public struct HostError: Error, Sendable {
  public let what: String
  init(_ what: String) { self.what = what }
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

  /// The controller reset, its K1 PHY and pads set as Linux's driver sets
  /// them, 3.3 V on, ADMA2, every status reported but none signalled,
  /// and the card's clock at 400 kHz.
  public func setUp() throws(HostError) {
    guard capabilities & Bits.adma2Support != 0 || k1 else { throw HostError("no ADMA2") }
    try reset(Bits.resetAll)
    if k1 {
      store32(K1.phyControl, load32(K1.phyControl) | K1.phyOn)
      store32(K1.phyPads, load32(K1.phyPads) & ~K1.padsMask | K1.pads)
    }
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
    if k1 { store32(K1.transmitConfig, load32(K1.transmitConfig) | K1.internalTransmitClock) }
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
  public func read(_ index: UInt8, _ argument: UInt32, bytes: Int) throws(HostError) -> [UInt8] {
    store16(Register.blockSize, UInt16(bytes))
    store16(Register.blockCount, 1)
    store16(Register.transferMode, Bits.readDirection)
    try send(index, argument, .short, data: true)
    let ready = poll(1_000_000_000) { self.load16(Register.normalStatus) & (Bits.bufferReadReady | Bits.errorInterrupt) != 0 }
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
    _ = poll(1_000_000_000) { self.load16(Register.normalStatus) & Bits.transferComplete != 0 }
    store16(Register.normalStatus, 0xFFFF)
    return Array(out.prefix(bytes))
  }

  // MARK: The card

  /// What bring-up learnt of the card.
  public struct Card: Sendable {
    public var rca: UInt32
    public var highCapacity: Bool
    public var sectors: UInt64
    public var name: String
    public var highSpeed: Bool
  }

  /// Brings up the SD card in the slot, as the Physical Layer
  /// Specification's initialization goes: idle, the interface condition,
  /// ACMD41 until it is ready, its CID, address and CSD, selected, a 4-bit
  /// bus, then high speed (50 MHz) if it switches, else 25 MHz.
  public func identify() throws(HostError) -> Card {
    try send(0, 0, .none)
    // CMD8: a version 2 card echoes the check pattern; an older one
    // doesn't answer, and takes no high capacity.
    var version2 = false
    if let r = try? send(8, 0x1AA, .short) {
      guard r[0] & 0xFFF == 0x1AA else { throw HostError("CMD8: echo 0x\(String(r[0], radix: 16))") }
      version2 = true
    }
    var ocr: UInt32 = 0
    let deadline = Clock.monotonic() + 1_000_000_000
    repeat {
      do throws(HostError) {
        ocr = try sendApplication(41, version2 ? OCR.request : OCR.request & ~OCR.highCapacity, .ocr)[0]
      } catch {
        throw HostError("no SD card answers (\(error.what))")
      }
      if ocr & OCR.ready == 0 { sleep(until: Clock.monotonic() + 10_000_000) }
    } while ocr & OCR.ready == 0 && Clock.monotonic() < deadline
    guard ocr & OCR.ready != 0 else { throw HostError("the card stays busy") }
    let cid = try send(2, 0, .long)
    let rca = try send(3, 0, .short)[0] >> 16
    guard let csd = CSD(try send(9, rca << 16, .long)) else { throw HostError("a CSD of no known structure") }
    try send(7, rca << 16, .busy)
    try sendApplication(6, 2, .short, rca: rca)
    store8(Register.hostControl, load8(Register.hostControl) | Bits.fourBit)
    try send(16, 512, .short)
    // CMD6, function group 1's function 1: its status's bits 379:376
    // say which function it switched to.
    var highSpeed = false
    if let status = try? read(6, 0x80FF_FFF1, bytes: 64), status[16] & 0xF == 1 {
      store8(Register.hostControl, load8(Register.hostControl) | Bits.highSpeed)
      highSpeed = true
    }
    try setClock(highSpeed ? 50_000_000 : 25_000_000)
    return Card(rca: rca, highCapacity: ocr & OCR.highCapacity != 0, sectors: csd.sectors,
                name: Sdhci.productName(cid), highSpeed: highSpeed)
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
