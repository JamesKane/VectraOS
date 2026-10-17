// SPDX-License-Identifier: BSD-3-Clause

// bin/edu (M3g; V2 item 7c, D74): the driver host for QEMU's `edu` teaching
// device (QEMU's docs/specs/edu.rst), the first that devmgr starts. It is
// given BAR 0, its configuration space, its interrupt and a BTI as
// resources and nothing else, and proves each: the identification
// register (0x00: major, minor, 0xED), the liveness check (0x04 reads back
// the inverse of what was written), a factorial the device computes (0x08,
// busy while bit 0 of 0x20 is set), the function's ids through its
// configuration space, and that its resource reaches no further than its
// BAR. Then its interrupt, routed by devmgr through ACPI's _PRT: 100 times
// the device raises it (0x60), the driver takes it on its port and lowers
// it (0x64), then acks. Then DMA through its BTI, on the IOMMU that covers
// it: 4 KiB of pinned memory copied into the device's buffer (0x40000 in
// its address space) and back, through the device addresses the pin gave.
// Its tree's `status` says what it found, and FAILED if anything failed.

import DriverHost
import IPC
import Node
import Sys

/// edu's DMA registers (edu.rst): source, destination, count, command.
enum EduDMA {
  static let source = 0x80
  static let destination = 0x88
  static let count = 0x90
  static let command = 0x98
  /// Command bits: start (cleared when done), to RAM (else from it).
  static let start: UInt64 = 1
  static let toRAM: UInt64 = 2
  /// Where the device's own 4 KiB buffer is, in its address space.
  static let buffer: UInt64 = 0x40000
}

@main struct Edu {
  static func main() {
    let start = Startup.current
    var device = DeviceResources(take: { start.take($0)?.release() })

    var findings: [String] = []
    var ok = true
    do throws(Status) {
      let bar = try device.bar(0)
      let regs = try device.map(bar: 0)
      let id = regs.load32(0x00)
      ok = ok && id & 0xFF == 0xED
      findings.append("edu \(id >> 24).\((id >> 16) & 0xFF)")
      regs.store32(0x04, 0x1234_5678)
      let live = regs.load32(0x04) == ~UInt32(0x1234_5678)
      ok = ok && live
      findings.append(live ? "live" : "not live")
      regs.store32(0x08, 10)
      let deadline = Clock.monotonic() + 1_000_000_000
      while regs.load32(0x20) & 1 != 0, Clock.monotonic() < deadline {}
      let factorial = regs.load32(0x08)
      ok = ok && factorial == 3_628_800
      findings.append("10! = \(factorial)")
      let config = try device.mapConfig()
      let vendor = config.load16(0), product = config.load16(2)
      ok = ok && vendor == 0x1234 && product == 0x11E8
      findings.append("config \(vendor == 0x1234 && product == 0x11E8 ? "1234:11e8" : "wrong")")
      findings.append("bars \(device.barIndices.map { "\($0)" }.joined(separator: ","))")
      // Nothing past the BAR: a VMO over the next page is refused.
      let confined: Bool
      do throws(Status) {
        _ = try device.borrowedBAR(0) { (h: borrowing Handle) throws(Status) in
          try VMO.physical(resource: h, address: bar.base + bar.size, size: 4096)
        }
        confined = false
      } catch {
        confined = error == .outOfRange
      }
      ok = ok && confined
      findings.append(confined ? "confined" : "not confined")

      // The interrupt: INTx on (the command register's Interrupt Disable off).
      config.store16(4, config.load16(4) & ~UInt16(0x400))
      let gsi = try device.interruptNumber()
      let irq = try InterruptPort(try device.interrupt())
      var raiseToWake: [Int64] = [], fireToWake: [Int64] = []
      for _ in 0..<100 {
        let t0 = Clock.monotonic()
        regs.store32(0x60, 1)
        let fired = try irq.wait(deadline: Clock.monotonic() + 1_000_000_000)
        let t1 = Clock.monotonic()
        guard regs.load32(0x24) & 1 == 1 else { throw .badState }
        regs.store32(0x64, 1)  // the line goes down; the ack unmasks it
        try irq.ack()
        raiseToWake.append(t1 - t0)
        fireToWake.append(t1 - fired)
      }
      raiseToWake.sort()
      fireToWake.sort()
      let mode = switch device.interruptMode {
      case .levelHigh: "level-high"
      case .levelLow: "level-low"
      case .edgeHigh: "edge-high"
      case .edgeLow: "edge-low"
      case .default, .none: "default"
      }
      findings.append("irq \(gsi) \(mode) 100 taken, raise to wake \(raiseToWake[50] / 1000) us, fire to wake \(fireToWake[50] / 1000) us")

      // DMA: bus mastering on, then 4 KiB to the device and back.
      guard let bti = device.takeBTI() else { throw .notFound }
      config.store16(4, config.load16(4) | 0x4)
      let pinned = PinnedMemory(bti: bti)
      let (pointer, address) = unsafe try pinned.allocate(bytes: 4096)
      let page = unsafe pointer.bindMemory(to: UInt8.self, capacity: 4096)
      for i in 0..<4096 { unsafe page[i] = UInt8(truncatingIfNeeded: i * 7 + 3) }
      func transfer(from source: UInt64, to destination: UInt64, _ command: UInt64) throws(Status) {
        regs.store64(EduDMA.source, source)
        regs.store64(EduDMA.destination, destination)
        regs.store64(EduDMA.count, 4096)
        regs.store64(EduDMA.command, command | EduDMA.start)
        let until = Clock.monotonic() + 1_000_000_000
        while regs.load64(EduDMA.command) & EduDMA.start != 0 {
          guard Clock.monotonic() < until else { throw .timedOut }
        }
      }
      try transfer(from: address, to: EduDMA.buffer, 0)
      for i in 0..<4096 { unsafe page[i] = 0 }
      try transfer(from: EduDMA.buffer, to: address, EduDMA.toRAM)
      var same = true
      for i in 0..<4096 where unsafe page[i] != UInt8(truncatingIfNeeded: i * 7 + 3) { same = false }
      ok = ok && same
      findings.append("dma \(same ? "4096 bytes there and back" : "came back wrong") at \(hex(address))")
      _ = consume pinned
    } catch {
      ok = false
      findings.append("failed: \(error.rawValue)")
    }
    let status = findings.joined(separator: ", ") + (ok ? "" : " FAILED") + "\n"
    print("edu: \(status)", terminator: "")

    do throws(Status) {
      let dispatcher = try IPCDispatcher()
      let tree = NodeTree(dispatcher: dispatcher)
      tree.text("status", read: { status })
      guard let export = start.export() else { Process.exit(code: 2) }
      try tree.serve(export)
      try dispatcher.run()
    } catch {
      Process.exit(code: 1)
    }
  }

  /// `0x` and lower-case hexadecimal.
  static func hex(_ v: UInt64) -> String {
    let digits = Array("0123456789abcdef".utf8)
    var out: [UInt8] = []
    var n = v
    repeat {
      out.insert(digits[Int(n & 0xF)], at: 0)
      n >>= 4
    } while n != 0
    return "0x" + String(decoding: out, as: UTF8.self)
  }
}
