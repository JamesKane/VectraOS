// SPDX-License-Identifier: BSD-3-Clause

// bin/rge: the net class over a Realtek RTL8126 (the Orange Pi 6 Plus's
// two). It brings the chip up (Chip), keeps its rings (Rings) in memory
// the chip reaches through its BTI, and serves ether(3)'s directory
// (drivers/net/lib) at `ether` in its tree, which devmgr binds at
// /net/etherN: frames written to a conversation's data go out on the
// dispatcher's thread, and the chip's interrupt (MSI-X, else INTx: then a
// lost one costs a 50 ms poll) receives on a thread of its own. Its tree:
// `ether`, and `status`.

import DriverHost
import IPC
import NetClass
import Node
import Sys

/// What the interrupt thread counts, for the status.
final class Counts: @unchecked Sendable {
  let lock = Lock()
  var interrupts = 0
  var polls = 0
  var systemErrors = 0
}

@main struct RgeDriver {
  static func main() {
    let start = Startup.current
    var resources = DeviceResources(take: { start.take($0)?.release() })
    let dispatcher: IPCDispatcher
    do throws(Status) {
      dispatcher = try IPCDispatcher()
    } catch {
      Process.exit(code: 1)
    }
    let tree = NodeTree(dispatcher: dispatcher)
    var lines: [String] = []
    let counts = Counts()
    var status: () -> String = { "" }
    // The fastest speed advertised: read, and set (renegotiating).
    var speed: (get: () -> Int, set: (Int) -> Void)?
    do throws(Status) {
      guard let bti = resources.takeBTI() else { throw Status.notFound }
      let config = try resources.mapConfig()
      // Memory decoding and bus mastering on (command bits 1 and 2): a
      // warm boot's devmgr turned bus mastering off (D101).
      config.store16(4, config.load16(4) | 0x6)
      let irq = try PCIInterrupt(resources, config: config)
      let chip = Chip(try resources.map(bar: 2))
      guard let revision = chip.revisionName else {
        lines.append("an unknown chip revision \(String(chip.revision, radix: 16))")
        throw Status.notSupported
      }
      try chip.initialize()
      let mac = chip.readAddress()
      chip.setAddress(mac)
      let rings = try Rings(chip: chip, memory: PinnedMemory(bti: bti))
      try chip.start(receive: rings.receiveRingBus, transmit: rings.transmitRingBus, maxFrame: Rings.bufferSize)

      let ether = Ether(tree: tree, at: "ether", nic: EtherNIC(mac: mac, mbps: 5000,
        transmit: { rings.transmit($0) },
        ifstats: { "received \(rings.received) transmitted \(rings.transmitted) dropped \(rings.dropped) "
          + "errors \(rings.errors) unsent \(rings.unsent)\n" }))
      ether.setLink(chip.link.up)
      let address = Ether.hex(mac)
      speed = (get: { chip.maxSpeed }, set: { mbps in
        chip.maxSpeed = mbps
        chip.autonegotiate()
        print("rge: \(address) advertising up to \(mbps) Mb/s")
      })
      let interruptKind = irq.msix ? "MSI-X" : "INTx"
      lines.append("\(revision), mac \(address), \(interruptKind), Realtek's code: MAC \(chip.macCode), PHY \(chip.phyCode)"
        + (chip.linkKept == true ? ", link kept" : ""))
      status = {
        let (i, p, e) = counts.lock.withLock { (counts.interrupts, counts.polls, counts.systemErrors) }
        let link = chip.link
        return "chip \(revision)\nmac \(address)\nlink \(link.up ? "up \(link.mbps)" : "down")\n"
          + "code MAC \(chip.macCode), PHY \(chip.phyCode)\n"
          + "interrupt \(interruptKind)\n"
          + "received \(rings.received) transmitted \(rings.transmitted) dropped \(rings.dropped)"
          + " errors \(rings.errors) unsent \(rings.unsent)\ninterrupts \(i) polls \(p) system-errors \(e)\n"
      }

      let port = try Port.create(bindToInterrupt: true)
      try Interrupt.bind(irq.handle, port: port, key: 1)
      let portRaw = port.release()
      _ = try Thread.spawn {
        let port = Handle(raw: portRaw)
        while true {
          let deadline = irq.msix ? infiniteDeadline : Clock.monotonic() + 50_000_000
          let interrupted = (try? Port.wait(port, deadline: deadline)) != nil
          counts.lock.withLock { if interrupted { counts.interrupts += 1 } else { counts.polls += 1 } }
          // The kernel masks the vector while it is delivered: unmasked
          // (the ack) before the chip's mask opens, so nothing the chip
          // sends then is lost; what it latched meanwhile is served again
          // here, not left for an interrupt that may not come.
          try? Interrupt.ack(irq.handle)
          var fired = chip.takeInterrupts()
          repeat {
            if fired & Chip.systemError != 0 { counts.lock.withLock { counts.systemErrors += 1 } }
            if fired & Chip.linkChange != 0 {
              let link = chip.link
              print("rge: \(address) link \(link.up ? "up, \(link.mbps) Mb/s" : "down")")
              ether.setLink(link.up)
            }
            rings.service { ether.receive($0) }
            chip.unmaskInterrupts()
            fired = chip.pendingInterrupts() ? chip.takeInterrupts() : 0
          } while fired != 0
        }
      }.release()
    } catch {
      lines.append("FAILED: status \(error.rawValue)")
      let failed = lines.joined(separator: "\n") + "\n"
      status = { failed }
    }
    let speeds = speed
    print("rge: " + lines.joined(separator: "; "))

    do throws(Status) {
      let report = status
      tree.text("status", read: { report() })
      // `speed <Mb/s>`: the fastest speed advertised (1000, 2500 or 5000),
      // renegotiated at once.
      tree.text("ctl", read: { speeds.map { "speed \($0.get())\n" } ?? "" },
                write: { (text: String) throws(NodeError) in
        let words = text.utf8.split(whereSeparator: { $0 == 0x20 || $0 == 0x0A }).map { String(decoding: $0, as: UTF8.self) }
        guard words.count == 2, words[0].utf8.elementsEqual("speed".utf8), let mbps = Int(words[1]),
          Chip.speeds.contains(mbps), let speeds
        else { throw .invalid }
        speeds.set(mbps)
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
