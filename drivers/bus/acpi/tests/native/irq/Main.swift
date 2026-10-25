// SPDX-License-Identifier: BSD-3-Clause

// bin/irq-test: a device's interrupt taken from user mode on a machine
// whose devices only ACPI names, as the boards' are. It finds an SBSA UART
// (ARMH0011, a PL011) that isn't the kernel's console, its registers and
// interrupt from _CRS, and puts it in loopback, so each byte it sends
// raises its receive interrupt. Each must reach a port through a bound
// interrupt object; one raised before the ack waits for it; and the
// interrupt goes on arriving once interrupt_set_affinity moves it to CPU
// 1. The UART is left as it was found. userboot starts it
// (userboot.next=bin/irq-test, the boot-irq test, with QEMU's second
// PL011); it exits 0 if every check passed, 2 if there's no spare UART.

import CroiMMIO
import Sys
import TDACPI

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var checks = 0

func check(_ condition: Bool, _ name: StaticString) {
  checks += 1
  if !condition {
    failures += 1
    print("irq-test: FAILED: \(name)")
  }
}

/// A PL011's registers (Arm's PrimeCell UART, DDI 0183).
enum PL011 {
  static var data: Int { 0x00 }
  static var flags: Int { 0x18 }      // FR
  static var integer: Int { 0x24 }    // IBRD
  static var fraction: Int { 0x28 }   // FBRD
  static var line: Int { 0x2C }       // LCR_H
  static var control: Int { 0x30 }    // CR
  static var mask: Int { 0x38 }       // IMSC
  static var clear: Int { 0x44 }      // ICR
  static var busy: UInt32 { 1 << 3 }
  static var receiveEmpty: UInt32 { 1 << 4 }
  static var receive: UInt32 { 1 << 4 }  // RXIM, RXIC
  /// UARTEN, LBE, TXE, RXE.
  static var loopback: UInt32 { 1 | 1 << 7 | 1 << 8 | 1 << 9 }
}

/// A spare UART: its registers' page, granted to us alone, and its interrupt.
struct Uart: ~Copyable {
  let resource: Handle
  let base: UInt64
  let interrupt: UInt32
  let mode: Interrupt.Mode
}

/// The first present ARMH0011 whose page the root resource grants
/// exclusively: the console's is the kernel's, and refused.
func spareUart(_ ns: inout Namespace, _ host: Host, _ root: borrowing Handle) -> Uart? {
  for d in ns.deviceNodes() {
    let hid = (try? ns.hardwareID(d, host: host)) ?? nil
    let cids = (try? ns.compatibleIDs(d, host: host)) ?? []
    guard hid == bytes("ARMH0011") || cids.contains(bytes("ARMH0011")) else { continue }
    let status = (try? ns.status(d, host: host)) ?? .assumed
    guard status.present, status.enabled, let resources = (try? ns.currentResources(d, host: host)) ?? nil else {
      continue
    }
    var base: UInt64? = nil
    var interrupt: (number: UInt32, flags: UInt8)? = nil
    for r in resources {
      switch r {
      case .memory32Fixed(_, let address, _): base = base ?? UInt64(address)
      case .extendedIRQ(let flags, let numbers, _) where !numbers.isEmpty: interrupt = interrupt ?? (numbers[0], flags)
      default: break
      }
    }
    guard let base, base & 0xFFF == 0, let interrupt else { continue }
    guard let page = try? Resource.create(parent: root, kind: .mmio, base: base, size: 4096, name: "irq-test",
                                          exclusive: true)
    else { continue }
    // _CRS's Extended Interrupt flags: bit 1 edge, bit 2 active low.
    let edge = interrupt.flags & 2 != 0, low = interrupt.flags & 4 != 0
    let mode: Interrupt.Mode = edge ? (low ? .edgeLow : .edgeHigh) : (low ? .levelLow : .levelHigh)
    return Uart(resource: page, base: base, interrupt: interrupt.number, mode: mode)
  }
  return nil
}

@main struct IRQTest {
  static func main() {
    let start = Startup.current
    guard let root = start.take(HandleType.info(HandleType.rootResource)),
      let bootData = start.take(HandleType.info(HandleType.vmoBootData)),
      let address = rsdpAddress(bootData), let raw = readPhysical(root, address, 36), let rsdp = try? RSDP(raw),
      let tables = try? TableSet(rsdp: rsdp, read: { (a: UInt64, n: Int) -> [UInt8]? in readPhysical(root, a, n) }),
      let dsdt = tables.dsdt
    else {
      print("irq-test: FAILED: no root resource, boot data or ACPI tables")
      Process.exit(code: 1)
    }
    var ns = Namespace(integerBits: tables.integerBits)
    let host = Host()
    for table in [dsdt] + tables.ssdts { _ = try? ns.load(table, host: host) }
    _ = ns.initializeDevices(host: host)
    guard let uart = spareUart(&ns, host, root) else {
      print("irq-test: no PL011 but the console's (ARMH0011)")
      Process.exit(code: 2)
    }
    print("irq-test: the PL011 at \(hex(uart.base)), interrupt \(uart.interrupt)")
    run(root, uart)
    print("irq-test: \(checks - failures) of \(checks) checks passed")
    Process.exit(code: failures == 0 ? 0 : 1)
  }

  static func run(_ root: borrowing Handle, _ uart: borrowing Uart) {
    guard let vmo = try? VMO.physical(resource: uart.resource, address: uart.base, size: 4096),
      let registers = try? VMO.map(vmo, length: 4096),
      let irqs = try? Resource.create(parent: root, kind: .irq, base: UInt64(uart.interrupt), size: 1, name: "irq-test"),
      let interrupt = try? Interrupt.create(resource: irqs, number: uart.interrupt, mode: uart.mode),
      let port = try? Port.create(bindToInterrupt: true),
      (try? Interrupt.bind(interrupt, port: port, key: 7)) != nil
    else {
      check(false, "the UART mapped, its interrupt bound to a port")
      return
    }
    // Device memory: each access volatile, whole and in order (croi/mmio.h).
    let at = unsafe UInt64(UInt(bitPattern: registers.address))
    func read(_ offset: Int) -> UInt32 { croi_mmio_read32(at + UInt64(offset)) }
    func write(_ offset: Int, _ value: UInt32) { croi_mmio_write32(at + UInt64(offset), value) }
    /// The next packet within `ns`, or nil.
    func next(within ns: Int64) -> Packet? { try? Port.wait(port, deadline: Clock.monotonic() + ns) }
    /// Sends a byte to itself; the received one is read and its interrupt
    /// cleared once its packet has come.
    func send(_ byte: UInt32) { write(PL011.data, byte) }
    func drain() {
      while read(PL011.flags) & PL011.receiveEmpty == 0 { _ = read(PL011.data) }
      write(PL011.clear, PL011.receive)
    }

    // As found, to put back.
    let found = (control: read(PL011.control), line: read(PL011.line), mask: read(PL011.mask),
                 integer: read(PL011.integer), fraction: read(PL011.fraction))
    write(PL011.control, 0)
    while read(PL011.flags) & PL011.busy != 0 {}
    write(PL011.mask, 0)
    write(PL011.clear, 0x7FF)
    // Any divisor serves a loopback: both ends share the clock.
    if found.integer == 0 { write(PL011.integer, 1) }
    write(PL011.line, 0x60)  // 8 bits, no FIFOs: an interrupt per byte (and LCR_H latches the divisor)
    write(PL011.control, PL011.loopback)
    drain()
    write(PL011.mask, PL011.receive)

    send(0x55)
    let first = next(within: 1_000_000_000)
    check(first?.type == Interrupt.packetType && first?.key == 7, "a byte looped back raises its interrupt at the port")
    drain()
    send(0xAA)
    check(next(within: 50_000_000) == nil, "the next waits for the ack")
    check((try? Interrupt.ack(interrupt)) != nil, "acked")
    check(next(within: 1_000_000_000)?.key == 7, "and arrives once acked")
    drain()
    check((try? Interrupt.setAffinity(interrupt, cpus: 1 << 1)) != nil, "moved to CPU 1")
    check((try? Interrupt.ack(interrupt)) != nil, "acked again")
    send(0x5A)
    check(next(within: 1_000_000_000)?.key == 7, "and arrives there")
    drain()
    _ = try? Interrupt.ack(interrupt)

    write(PL011.mask, 0)
    write(PL011.control, 0)
    write(PL011.integer, found.integer)
    write(PL011.fraction, found.fraction)
    write(PL011.line, found.line)
    write(PL011.clear, 0x7FF)
    write(PL011.mask, found.mask)
    write(PL011.control, found.control)
  }

  static func hex(_ value: UInt64) -> String {
    let digits = Array("0123456789abcdef".utf8)
    var out: [UInt8] = []
    var v = value
    repeat {
      out.append(digits[Int(v & 0xF)])
      v >>= 4
    } while v != 0
    return "0x" + String(decoding: out.reversed(), as: UTF8.self)
  }
}
