// SPDX-License-Identifier: BSD-3-Clause

// An HD Audio controller (Intel High Definition Audio Specification
// rev. 1.0a, §3, §4): its reset and the codecs that answer it, the CORB
// and RIRB that carry commands and responses, and its stream descriptors.
//
// Responses are read by polling RIRBWP after each command, with the RIRB
// interrupt left off: on the Sky1 RINTFL can't be cleared (sky1-audio 02
// §2.2.2), and polling serves every controller the same way. A stream
// descriptor plays (or records) a cyclic buffer described by a BDL of one
// entry a period, each raising its interrupt (IOC) when done; its
// position is SDnLPIB. A stream is reset with SRST held 100 µs (02
// §2.2.3). Every address the controller is given is the bus address less
// `dmaOffset`: 0 through a PCI function's BTI, 0x90000000 on the Sky1
// (02 §2.3).

import CroiMMIO
import DriverHost
import Sys

public enum HDAError: Error, Equatable, Sendable {
  case noReset
  case noCodec
  case noResponse(UInt32)
  case noStream
  case streamReset

  /// What failed, for status lines.
  public var what: String {
    switch self {
    case .noReset: "the controller didn't leave reset"
    case .noCodec: "no codec answered"
    case .noResponse(let c): "no response to 0x" + String(c, radix: 16)
    case .noStream: "no memory for a stream"
    case .streamReset: "a stream didn't reset"
    }
  }
}

@safe public final class HDAController: @unchecked Sendable {
  public let regs: HDARegisters
  public let dmaOffset: UInt64
  let memory: DMAMemory
  let lock = Lock()
  public let inputStreams: Int
  public let outputStreams: Int
  public private(set) var codecs: UInt16 = 0
  public private(set) var before: UInt16 = 0
  /// The CORB (256 entries of 4 bytes) and RIRB (256 of 8), and where the
  /// next response is.
  let corb: Region
  let rirb: Region
  var corbWP: UInt16 = 0
  var rirbRP: UInt16 = 0
  public private(set) var commands = 0
  public private(set) var unsolicited = 0
  /// How long a command waits for its response, and how long a poll sleeps.
  public var timeout: Int64 = 50_000_000
  public var pause: (Int64) -> Void = { sleep(until: Clock.monotonic() + $0) }

  /// `wordOnly` and `dmaOffset` are the Sky1's (sky1-audio 02 §2.2.1,
  /// §2.3); a PCI controller takes neither.
  public init(_ window: HDAWindow, memory: DMAMemory, wordOnly: Bool = false, dmaOffset: UInt64 = 0) throws(Status) {
    regs = HDARegisters(window, wordOnly: wordOnly)
    self.memory = memory
    self.dmaOffset = dmaOffset
    let gcap = regs.load16(Reg.gcap)
    inputStreams = Int((gcap >> 8) & 0xF)
    outputStreams = Int((gcap >> 12) & 0xF)
    corb = try Region(memory, bytes: 1024)
    rirb = try Region(memory, bytes: 2048)
  }

  func bus(_ address: UInt64) -> UInt64 { address &- dmaOffset }

  func wait(_ done: () -> Bool, for ns: Int64) -> Bool {
    let deadline = Clock.monotonic() + ns
    while !done() {
      guard Clock.monotonic() < deadline else { return done() }
      pause(20_000)
    }
    return true
  }

  // MARK: Reset and the command rings

  /// The controller reset and out of it, the CORB and RIRB running and
  /// unsolicited responses on, and the codecs found: those STATESTS names
  /// before the reset or after it (QEMU's codecs ask for an address at
  /// power-on and not again), or failing both, those of addresses 0 to 7
  /// that answer.
  public func start() throws(HDAError) {
    before = regs.load16(Reg.statests) & 0x7FFF
    // Into reset, the rings stopped first.
    regs.store8(Reg.corbCtl, 0)
    regs.store8(Reg.rirbCtl, 0, clearMask: HDARegisters.rirbStsMask)
    regs.store32(Reg.gctl, regs.load32(Reg.gctl) & ~Reg.crst)
    guard wait({ regs.load32(Reg.gctl) & Reg.crst == 0 }, for: 100_000_000) else { throw .noReset }
    pause(100_000)
    regs.store32(Reg.gctl, regs.load32(Reg.gctl) | Reg.crst)
    guard wait({ regs.load32(Reg.gctl) & Reg.crst != 0 }, for: 100_000_000) else { throw .noReset }
    // Codecs ask for an address within 521 µs (§4.3); give them a
    // millisecond.
    pause(1_000_000)
    let after = regs.load16(Reg.statests) & 0x7FFF
    regs.store16(Reg.statests, after)  // write-1-to-clear

    // The CORB: 256 entries, its read pointer reset.
    let corbAt = bus(corb.bus)
    regs.store32(Reg.corbLower, UInt32(truncatingIfNeeded: corbAt))
    regs.store32(Reg.corbUpper, UInt32(truncatingIfNeeded: corbAt >> 32))
    regs.store8(Reg.corbSize, 2)
    regs.store16(Reg.corbRP, 0x8000)
    _ = wait({ regs.load16(Reg.corbRP) & 0x8000 != 0 }, for: 10_000_000)
    regs.store16(Reg.corbRP, 0)
    _ = wait({ regs.load16(Reg.corbRP) & 0x8000 == 0 }, for: 10_000_000)
    regs.store16(Reg.corbWP, 0)
    corbWP = 0
    // The RIRB: 256 entries, its write pointer reset; DMA on, its
    // interrupt off (polled).
    let rirbAt = bus(rirb.bus)
    regs.store32(Reg.rirbLower, UInt32(truncatingIfNeeded: rirbAt))
    regs.store32(Reg.rirbUpper, UInt32(truncatingIfNeeded: rirbAt >> 32))
    regs.store8(Reg.rirbSize, 2)
    regs.store16(Reg.rirbWP, 0x8000)
    regs.store16(Reg.rintCnt, 0xFF)
    rirbRP = 0
    regs.store8(Reg.corbCtl, 0x02)
    regs.store8(Reg.rirbCtl, 0x02, clearMask: HDARegisters.rirbStsMask)
    regs.store32(Reg.gctl, regs.load32(Reg.gctl) | Reg.unsol)

    codecs = before | after
    if codecs == 0 {
      let wait = timeout
      timeout = 5_000_000
      for c in 0..<8 where (try? send(Verb.command(codec: c, node: 0, verb: Verb.getParameter, payload: Parameter.vendor))) != nil {
        codecs |= 1 << UInt16(c)
      }
      timeout = wait
    }
    guard codecs != 0 else { throw .noCodec }
  }

  /// RIRBSTS's flags cleared: a controller that counts responses toward
  /// RINTCNT takes no more commands once the count is reached until they
  /// are (QEMU's does), though the interrupt is off. The Sky1's can't be
  /// cleared (sky1-audio 02 §2.2.2), and doesn't stop.
  func clearResponseStatus() {
    regs.store8(Reg.rirbSts, 0x05)
  }

  /// Sends `command` and waits for its codec's response.
  public func send(_ command: UInt32) throws(HDAError) -> UInt32 {
    try lock.withLock { () throws(HDAError) -> UInt32 in
      let codec = Int(command >> 28)
      corbWP = (corbWP + 1) & 0xFF
      corb.store32(4 * Int(corbWP), command)
      croi_dma_barrier()
      regs.store16(Reg.corbWP, corbWP)
      commands += 1
      let deadline = Clock.monotonic() + timeout
      while true {
        let wp = regs.load16(Reg.rirbWP) & 0xFF
        while rirbRP != wp {
          rirbRP = (rirbRP + 1) & 0xFF
          croi_dma_barrier()
          let response = rirb.load32(8 * Int(rirbRP))
          let extended = rirb.load32(8 * Int(rirbRP) + 4)
          if extended & 0x10 != 0 {
            unsolicited += 1
          } else if Int(extended & 0xF) == codec {
            clearResponseStatus()
            return response
          }
        }
        guard Clock.monotonic() < deadline else { throw .noResponse(command) }
        pause(10_000)
      }
    }
  }

  // MARK: Streams

  /// Descriptor index of output stream `n`, or input stream `n`.
  public func descriptor(output: Bool, _ n: Int) -> Int { output ? inputStreams + n : n }

  /// Sets stream descriptor `sd` up for a cyclic buffer at `buffer` of
  /// `periods` periods of `periodBytes`, its BDL at `bdl` (bus addresses),
  /// stream `tag`, `format`: reset first, its interrupt on each period.
  public func setUp(sd: Int, tag: Int, buffer: UInt64, periods: Int, periodBytes: Int, bdl: Region,
                    format: UInt16) throws(HDAError) {
    try reset(sd: sd)
    for i in 0..<periods {
      bdl.store64(16 * i, bus(buffer + UInt64(i * periodBytes)))
      bdl.store32(16 * i + 8, UInt32(periodBytes))
      bdl.store32(16 * i + 12, 1)  // IOC
    }
    croi_dma_barrier()
    let base = Reg.sd(sd)
    regs.store32(base + Reg.sdCBL, UInt32(periods * periodBytes))
    regs.store16(base + Reg.sdLVI, UInt16(periods - 1))
    regs.store16(base + Reg.sdFormat, format)
    let b = bus(bdl.bus)
    regs.store32(base + Reg.sdBDLLower, UInt32(truncatingIfNeeded: b))
    regs.store32(base + Reg.sdBDLUpper, UInt32(truncatingIfNeeded: b >> 32))
    regs.setSdCtl(sd, UInt32(tag & 0xF) << 20 | Reg.ioce)
    regs.clearSdSts(sd, Reg.bcis | Reg.fifoe | Reg.dese)
    regs.store32(Reg.intctl, regs.load32(Reg.intctl) | 1 << UInt32(sd) | Reg.gie)
  }

  public func run(sd: Int) { regs.setSdCtl(sd, regs.sdCtl(sd) | Reg.run) }

  /// Stops stream descriptor `sd` and resets it.
  public func stop(sd: Int) throws(HDAError) {
    regs.setSdCtl(sd, regs.sdCtl(sd) & ~(Reg.run | Reg.ioce))
    _ = wait({ regs.sdCtl(sd) & Reg.run == 0 }, for: 10_000_000)
    regs.store32(Reg.intctl, regs.load32(Reg.intctl) & ~(1 << UInt32(sd)))
    try reset(sd: sd)
  }

  func reset(sd: Int) throws(HDAError) {
    regs.setSdCtl(sd, regs.sdCtl(sd) | Reg.srst)
    guard wait({ regs.sdCtl(sd) & Reg.srst != 0 }, for: 10_000_000) else { throw .streamReset }
    pause(100_000)  // the Sky1's 100 µs (sky1-audio 02 §2.2.3)
    regs.setSdCtl(sd, regs.sdCtl(sd) & ~Reg.srst)
    guard wait({ regs.sdCtl(sd) & Reg.srst == 0 }, for: 10_000_000) else { throw .streamReset }
    regs.clearSdSts(sd, Reg.bcis | Reg.fifoe | Reg.dese)
  }

  /// Stream descriptor `sd`'s position in its buffer, in bytes.
  public func position(sd: Int) -> Int { Int(regs.load32(Reg.sd(sd) + Reg.sdLPIB)) }

  /// The stream descriptors that raised an interrupt, each's status
  /// cleared: their indexes.
  public func serviceInterrupt() -> [Int] {
    let sts = regs.load32(Reg.intsts)
    var out: [Int] = []
    for sd in 0..<(inputStreams + outputStreams) where sts & (1 << UInt32(sd)) != 0 {
      let s = regs.sdSts(sd)
      regs.clearSdSts(sd, s & (Reg.bcis | Reg.fifoe | Reg.dese))
      out.append(sd)
    }
    return out
  }
}

extension HDAController {
  /// The registers a failed bring-up is judged by, for status lines.
  public var registersLine: String {
    "gcap 0x" + String(regs.load16(Reg.gcap), radix: 16) + " gctl 0x" + String(regs.load32(Reg.gctl), radix: 16)
      + " statests 0x" + String(regs.load16(Reg.statests), radix: 16) + " before 0x" + String(before, radix: 16)
  }
}
