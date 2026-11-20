// SPDX-License-Identifier: BSD-3-Clause

// bin/scmi (scmi(3)): the SCMI agent's driver host, the power class.
// Firmware's power domains, clocks and performance levels are the
// platform's, asked for in SCMI messages (lib/SCMI.swift) through shared
// memory: devmgr grants the ranges the agent's _DSD names, its "shmem" and
// "mboxes" (`--bar=INDEX:ROLE` says which BAR each is), and where a board
// rule names one (the CIX Sky1's TF-A), an SMC function and the memory
// its messages pass through (`firmware`). A message goes through the
// first mailbox by its doorbell, or by the SMC call, and is polled until
// the platform frees the channel; power domains go to the SMC's agent
// where there is one, the rest to the mailbox's.
//
// Its tree, which devmgr mounts at /dev/scmi for each platform device
// with clocks or SCMI power domains:
//   ctl      a command a line: `power DOMAIN on|off`, `clock ID on|off`,
//            `clock ID rate HZ`, `clock ID rate` (the status then shows
//            the rate as it is); a write fails if the platform refused
//            (a rate is read back after, and the status shows that)
//            and `cppc ADDRESS VALUE WIDTH`: power(8)'s write of a CPU's
//            desired-performance register (D167), accepted for a register
//            devmgr listed (`--cppc=` arguments) in a page the agent was
//            granted
//   status   each channel's SCMI version and vendor, what was turned on
//            and off, the commands sent, the last failure and the last
//            value written to each CPPC register

import CroiMMIO
import DriverHost
import IPC
import Node
import Sys

/// A shared-memory channel to the platform, and how it is told a message
/// waits: a mailbox's doorbell register, or an SMC function.
final class Transport: @unchecked Sendable {
  let name: String
  let memory: Registers
  let doorbell: Registers?
  let smc: Handle?
  let function: UInt32
  let lock = Lock()
  var token: UInt32 = 0

  init(name: String, memory: consuming Registers, doorbell: consuming Registers?, smc: consuming Handle?,
       function: UInt32 = 0) {
    self.name = name
    self.memory = memory
    self.doorbell = doorbell
    self.smc = smc
    self.function = function
  }

  /// Sends a command and waits for its answer: the words after the
  /// status, which must be success.
  func send(_ proto: ProtocolID, _ message: UInt32, _ payload: [UInt32]) throws(SCMIError) -> [UInt32] {
    try lock.withLock { () throws(SCMIError) -> [UInt32] in
      guard waitFree() else { throw .timedOut }
      token &+= 1
      memory.store32(SharedMemory.flags, 0)
      memory.store32(SharedMemory.length, UInt32(4 + 4 * payload.count))
      memory.store32(SharedMemory.header, header(proto, message: message, token: token))
      for (i, w) in payload.enumerated() { memory.store32(SharedMemory.payload + 4 * i, w) }
      // Busy: the platform sets free once it has answered.
      memory.store32(SharedMemory.status, 0)
      croi_dma_barrier()
      switch doorbell {
      case .some(let d): d.store32(0x80, 1)  // the CIX mailbox's DB_ACK: the doorbell
      case .none:
        switch smc {
        case .some(let s):
          let r: (UInt64, UInt64, UInt64, UInt64)
          do throws(Status) { r = try Resource.smc(s, function: function) } catch { throw .noChannel }
          // SMCCC's NOT_SUPPORTED: no agent behind the function.
          if Int32(truncatingIfNeeded: r.0) == -1 { throw .noChannel }
        case .none: throw .noChannel
        }
      }
      guard waitFree() else { throw .timedOut }
      let status = memory.load32(SharedMemory.status)
      if status & SharedMemory.error != 0 { throw .channelError }
      let length = Int(memory.load32(SharedMemory.length))
      let room = (memory.size - SharedMemory.payload) / 4
      let count = min(max(length - 4, 0) / 4, room)
      var words: [UInt32] = []
      for i in 0..<count { words.append(memory.load32(SharedMemory.payload + 4 * i)) }
      return try result(words)
    }
  }

  /// Writes a CPPC register if it is in this channel's memory or
  /// doorbell pages.
  func store(_ write: CPPCWrite, registers: [CPPCRegister]) -> CPPCWrite.Verdict {
    var windows: [(base: UInt64, size: UInt64)] = [(memory.physical, UInt64(memory.size))]
    switch doorbell {
    case .some(let d): windows.append((d.physical, UInt64(d.size)))
    case .none: break
    }
    let verdict = write.verdict(registers: registers, windows: windows)
    guard case .write(let window, let offset) = verdict else { return verdict }
    if window == 0 {
      Self.put(memory, offset, write)
    } else {
      switch doorbell {
      case .some(let d): Self.put(d, offset, write)
      case .none: break
      }
    }
    return verdict
  }

  static func put(_ r: borrowing Registers, _ offset: Int, _ w: CPPCWrite) {
    switch w.width {
    case 8: r.store8(offset, UInt8(truncatingIfNeeded: w.value))
    case 16: r.store16(offset, UInt16(truncatingIfNeeded: w.value))
    case 64: r.store64(offset, w.value)
    default: r.store32(offset, UInt32(truncatingIfNeeded: w.value))
    }
  }

  /// Polls the channel's free bit for up to 100 ms.
  func waitFree() -> Bool {
    let deadline = Clock.monotonic() + 100_000_000
    while memory.load32(SharedMemory.status) & SharedMemory.free == 0 {
      if Clock.monotonic() > deadline { return false }
      sleep(until: Clock.monotonic() + 20_000)
    }
    return true
  }

  /// The base protocol's version and vendor, as a status line.
  func describe() -> String {
    var line = name + ": "
    do throws(SCMIError) {
      let v = try send(.base, Message.protocolVersion, [])
      line += "SCMI " + (v.first.map { versionText($0) } ?? "?")
      let vendor = try send(.base, Message.discoverVendor, [])
      line += ", vendor " + nameText(vendor[...])
    } catch {
      line += "FAILED: " + error.description
    }
    return line
  }
}

/// What the tree shows, as commands are sent.
final class Findings: @unchecked Sendable {
  let lock = Lock()
  var head: [String] = []
  /// The last state each command set, by its subject.
  var states: [Command] = []
  var sent = 0, failed = 0
  var last = ""
  /// The last value written to each CPPC register, and the writes refused.
  var cppc: [CPPCWrite] = []
  var cppcRefused = 0

  var status: String {
    lock.withLock {
      (head + states.map { $0.description } + cppc.map { $0.description }
        + (cppcRefused > 0 ? ["cppc writes refused \(cppcRefused)"] : []) + ["commands \(sent), failed \(failed)"]
        + (last.isEmpty ? [] : ["last failure: " + last])).map { $0 + "\n" }.joined()
    }
  }

  func record(_ w: CPPCWrite, _ verdict: CPPCWrite.Verdict) {
    lock.withLock {
      guard case .write = verdict else {
        cppcRefused += 1
        last = w.description + ": " + Self.why(verdict)
        return
      }
      cppc.removeAll { $0.address == w.address }
      cppc.append(w)
    }
  }

  static func why(_ v: CPPCWrite.Verdict) -> String {
    switch v {
    case .write: "written"
    case .notListed: "not a desired-performance register devmgr listed"
    case .tooWide: "value too wide"
    case .notGranted: "in no page the agent was granted"
    }
  }

  func record(_ c: Command, _ error: SCMIError?) {
    lock.withLock {
      sent += 1
      if let error {
        failed += 1
        last = c.description + ": " + error.description
        return
      }
      states.removeAll { $0.sameSubject(c) }
      states.append(c)
    }
  }
}

@main struct SCMIAgent {
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
    func bar(_ role: String) -> Int? { roles.first { $0.role.utf8.elementsEqual(role.utf8) }?.index }
    // `--cppc=0xADDRESS/BITS`: the CPUs' desired-performance registers
    // devmgr's `cpus` lists, the only ones ctl's `cppc` writes.
    let cppcRegisters = start.args.compactMap { CPPCRegister(argument: $0) }

    let findings = Findings()
    var mailbox: Transport?, firmware: Transport?
    if let shmem = bar("shmem"), let mbox = bar("mboxes"), let memory = mapPaged(resources, bar: shmem),
      let doorbell = mapPaged(resources, bar: mbox)
    {
      mailbox = Transport(name: "mailbox", memory: memory, doorbell: doorbell, smc: nil)
    } else {
      findings.head.append("no mailbox: its _DSD names no shmem and mboxes")
    }
    if let b = bar("firmware"), let memory = mapPaged(resources, bar: b), let smc = resources.takeSMC(),
      let function = try? Resource.info(smc).base
    {
      firmware = Transport(name: "smc " + hex(UInt32(truncatingIfNeeded: function)), memory: memory, doorbell: nil,
                           smc: smc, function: UInt32(truncatingIfNeeded: function))
    }
    for t in [mailbox, firmware].compactMap({ $0 }) { findings.head.append(t.describe()) }
    print("scmi: " + findings.head.joined(separator: "; "))
    let agents = (mailbox: mailbox, firmware: firmware)

    do throws(Status) {
      let dispatcher = try IPCDispatcher()
      let tree = NodeTree(dispatcher: dispatcher)
      tree.text("status", read: { findings.status })
      tree.text("ctl", read: { "" }, write: { (text: String) throws(NodeError) in
        for line in text.utf8.split(separator: 0x0A).map({ String(decoding: $0, as: UTF8.self) }) {
          if let w = CPPCWrite(line) {
            var verdict = CPPCWrite.Verdict.notListed
            for t in [agents.mailbox, agents.firmware].compactMap({ $0 }) {
              verdict = t.store(w, registers: cppcRegisters)
              if case .write = verdict { break }
            }
            findings.record(w, verdict)
            print("scmi: \(w.description): \(Findings.why(verdict))")
            guard case .write = verdict else { throw .invalid }
            continue
          }
          guard let c = Command(line) else { throw .invalid }
          let r = c.request
          // Power domains are TF-A's where it has an agent of its own.
          let t = r.proto == .power ? (agents.firmware ?? agents.mailbox) : agents.mailbox
          var failure: SCMIError?
          var done = c
          if let t {
            do throws(SCMIError) {
              let answer = try t.send(r.proto, r.message, r.payload)
              // A rate asked for: CLOCK_RATE_GET's two words, low first.
              if case .rateGet(let id) = c {
                guard answer.count >= 2 else { throw .short }
                done = .rate(id: id, hertz: answer[1] == 0 ? answer[0] : UInt32.max)
              }
              // A rate as the platform rounded it.
              if case .rate(let id, _) = c {
                let got = try t.send(.clock, Message.clockRateGet, [id])
                guard got.count >= 2 else { throw .short }
                done = .rate(id: id, hertz: got[1] == 0 ? got[0] : UInt32.max)
              }
            } catch {
              failure = error
            }
          } else {
            failure = .noChannel
          }
          findings.record(done, failure)
          print("scmi: \(c.description): \(failure?.description ?? (done == c ? "done" : "done, " + done.description))")
          if failure != nil { throw .io }
        }
      })
      guard let export = start.export() else { Process.exit(code: 2) }
      try tree.serve(export)
      try dispatcher.run()
    } catch {
      Process.exit(code: 1)
    }
    _ = consume resources
  }
}

/// A granted range mapped to its last page's end, so a register in the
/// pages around a mailbox's is reachable.
func mapPaged(_ resources: borrowing DeviceResources, bar index: Int) -> Registers? {
  guard let info = try? resources.bar(index) else { return nil }
  let end = (info.base + info.size + 4095) & ~4095
  return try? resources.map(bar: index, extent: Int(end - info.base))
}

func hex(_ v: UInt32) -> String {
  let digits = Array("0123456789abcdef".utf8)
  var out: [UInt8] = []
  for shift in stride(from: 28, through: 0, by: -4) { out.append(digits[Int(v >> UInt32(shift) & 0xF)]) }
  return String(decoding: out, as: UTF8.self)
}
