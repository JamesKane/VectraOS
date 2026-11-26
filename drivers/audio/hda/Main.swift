// SPDX-License-Identifier: BSD-3-Clause

// bin/hda (D179, D180): the audio class over an HD Audio controller and
// its codec (Intel High Definition Audio Specification rev. 1.0a): PCI's
// (class 04.03; QEMU's ich9-intel-hda with an hda-duplex codec). It maps
// BAR 0, takes memory the controller reaches through its BTI for the
// CORB, the RIRB, each stream's cyclic buffer and its BDL, resets the
// controller, reads the first codec's widget graph and sets its playback
// and capture paths up, and serves audio(3)'s directory (drivers/audio/lib)
// at `audio` in its tree, which devmgr binds at /dev/audio/<n>. The
// controller's interrupt (MSI-X where there is one, else INTx with a
// 50 ms poll) counts each stream's periods from its position on a thread
// of its own. Its tree: `audio`, and `status` (the controller, the codec,
// its paths and the counts).

import AudioDevice
import DriverHost
import IPC
import Node
import Sys

/// BAR 0.
final class BARWindow: HDAWindow, @unchecked Sendable {
  let regs: Registers
  init(_ regs: consuming Registers) { self.regs = regs }
  func load32(_ offset: Int) -> UInt32 { regs.load32(offset) }
  func store32(_ offset: Int, _ value: UInt32) { regs.store32(offset, value) }
  func load16(_ offset: Int) -> UInt16 { regs.load16(offset) }
  func store16(_ offset: Int, _ value: UInt16) { regs.store16(offset, value) }
  func load8(_ offset: Int) -> UInt8 { regs.load8(offset) }
  func store8(_ offset: Int, _ value: UInt8) { regs.store8(offset, value) }
}

@main struct HDADriver {
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
    var status: () -> String = { "" }
    do throws(Status) {
      // Memory decoding and bus mastering on (a warm boot's devmgr
      // turned bus mastering off, D101).
      let config = try resources.mapConfig()
      config.store16(4, config.load16(4) | 0x6)
      let pci = try PCIInterrupt(resources, config: config)
      let irq = try pci.handle.duplicate()
      let msix = pci.msix
      guard let bti = resources.takeBTI() else { throw Status.notFound }
      let window = BARWindow(try resources.map(bar: 0))
      let memory = PinnedMemory(bti: bti)
      let controller = try HDAController(window, memory: memory)
      let audio: HDAAudio
      do throws(HDAError) {
        audio = try HDAAudio(controller: controller, memory: memory)
      } catch {
        lines.append("the controller or its codec didn't come up: " + error.what)
        lines.append(controller.registersLine)
        throw Status.notFound
      }
      guard audio.paths.output != nil || audio.paths.input != nil else {
        lines.append("the codec has no analog path to a connected pin")
        throw Status.notSupported
      }
      lines.append("codec \(audio.graph.codec), \(msix ? "MSI-X" : "INTx")")

      // The unit's directory and its data file each on a dispatcher of
      // their own, as virtio-snd's are.
      let control = try IPCDispatcher()
      let data = try IPCDispatcher()
      let unit = AudioUnit(audio, control: control, data: data)
      audio.finished = { unit.finished($0) }
      _ = try Thread.spawn { try? control.run() }.release()
      _ = try Thread.spawn { try? data.run() }.release()
      let thread = try InterruptThread(irq, msix: msix) { _, ack in
        audio.serviceInterrupt()
        ack()
      }
      _ = tree.mount("audio", try unit.channel())
      for d in [AudioDirection.output, .input] {
        if let c = audio.capabilities(d) { lines.append(c.line(d)) }
      }
      status = {
        let (i, p) = thread.counts
        return "interrupt \(msix ? "MSI-X" : "INTx")\n" + audio.report + "interrupts \(i) polls \(p)\n"
      }
    } catch {
      lines.append("FAILED: status \(error.rawValue)")
      let failed = lines.joined(separator: "\n") + "\n"
      status = { failed }
    }
    print("hda: " + lines.joined(separator: "; "))

    do throws(Status) {
      let report = status
      tree.text("status", read: { report() })
      guard let export = start.export() else { Process.exit(code: 2) }
      try tree.serve(export)
      try dispatcher.run()
    } catch {
      Process.exit(code: 1)
    }
    _ = consume resources
  }
}
