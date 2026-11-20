// SPDX-License-Identifier: BSD-3-Clause

// bin/mali (mali(3)): an Arm Mali CSF GPU's driver host, on the CIX Sky1's
// Mali-G720 (CIXH5000). devmgr starts it with its GPU on: its power
// domain, its clocks, its power resource and its reset, in the order the
// Sky1 needs and each through what owns it (its record's `power-up graph`,
// devmgr(8)); a GPU register read before them stops the machine. What is
// left to the driver is, in order (D173 section 2):
//
//   Q-channel clock gating on, in the RCSU (BAR 0);
//   GPU_ID, the features and the present masks (BAR 1), the shader mask
//   reduced by the RCSU's harvest word;
//   a soft reset; COHERENCY_PROTOCOL; the system cache's values; the L2;
//   the MCU's address space with the firmware's sections in it;
//   MCU_CONTROL auto, the global interface's interrupt, the interface's
//   discovery, its first configuration and a ping.
//
// A step that fails stops it there, and the steps after it are not taken.
// Its tree: `status`, each step and what it read.
//
// All of it runs in main, before the tree is served; the job, MMU and GPU
// interrupts are polled at their raw status (Device.swift says why).

import DriverHost
import IPC
import Node
import Sys

@main struct MaliDriver {
  static func main() {
    let start = Clock.monotonic()
    let startup = Startup.current
    var resources = DeviceResources(take: { startup.take($0)?.release() })
    let noncoherent = startup.args.contains { $0.utf8.elementsEqual("--noncoherent".utf8) }
    var status: [String] = []
    var step = Sky1GPU.steps[0]
    // What stays alive: the pinned memory (the GPU reads it), the firmware's
    // state for the scheduler (part 5, 6).
    var memory: PinnedMemory?
    var booted: BootedFirmware?

    // Its firmware, as devmgr gave it (D164): the image read and checked.
    let file = readFirmware()
    var image: FirmwareImage?
    do throws(FirmwareError) {
      if !file.isEmpty { image = try FirmwareImage.parse(file) }
      if let image {
        status.append(image.summary)
      } else {
        status.append(FirmwareImage.missing)
      }
    } catch {
      status.append("firmware \(file.count) bytes refused: \(error)")
    }

    do throws(StepFailed) {
      // Q-channel clock gating.
      guard let rcsu = try? resources.map(bar: 0) else { throw StepFailed(step: step, text: "no RCSU") }
      rcsu.store32(Sky1GPU.control, rcsu.load32(Sky1GPU.control) | Sky1GPU.qChannelClockGate)
      let harvest = rcsu.load32(Sky1GPU.harvest)
      status.append("Q-channel clock gating on, RCSU control \(hexText(rcsu.load32(Sky1GPU.control)))"
        + " harvest \(hexText(harvest))")

      // The probe.
      step = "probe"
      guard let gpu = try? resources.map(bar: 1) else { throw StepFailed(step: step, text: "no GPU registers") }
      let probe = read(gpu)
      guard probe.id.isPlausible else {
        throw StepFailed(step: step, text: "GPU_ID reads \(hexText(probe.id.raw)): no GPU answers")
      }
      status += probe.lines
      status.append("probed")

      // The firmware.
      step = "firmware"
      guard let image else {
        throw StepFailed(step: step, text: file.isEmpty ? "no firmware to load" : "the image was refused")
      }
      guard let bti = resources.takeBTI() else { throw StepFailed(step: step, text: "no BTI") }
      // Write-combining everywhere the GPU reads (D173 section 3).
      let pinned = PinnedMemory(bti: bti, coherent: false)
      memory = pinned
      let window = GPUWindow(gpu)
      booted = try bringUp(window: window, probe: probe, rcsuHarvest: harvest, memory: pinned, noncoherent: noncoherent,
                           file: file, image: image, start: start, status: &status)
      let milliseconds = booted?.milliseconds ?? 0
      status.append("budget name=gpu.mali.boot_ms value=\(milliseconds) unit=ms")
      status.append("firmware booted")
    } catch {
      status.append("FAILED at \(error.step): \(error.text)")
    }
    let text = status.map { $0 + "\n" }.joined()
    print("mali: " + status.joined(separator: "; "))

    do throws(Status) {
      let dispatcher = try IPCDispatcher()
      let tree = NodeTree(dispatcher: dispatcher)
      tree.text("status", read: { text })
      guard let export = startup.export() else { Process.exit(code: 2) }
      try tree.serve(export)
      try dispatcher.run()
    } catch {
      Process.exit(code: 1)
    }
    _ = consume resources
    _ = consume memory
    _ = consume booted
  }
}

/// GPU_ID, the features and the present masks.
func read(_ gpu: borrowing Registers) -> Probe {
  Probe(id: GPUID(gpu.load32(GPURegister.id)), l2Features: gpu.load32(GPURegister.l2Features),
        tilerFeatures: gpu.load32(GPURegister.tilerFeatures), memFeatures: gpu.load32(GPURegister.memFeatures),
        mmuFeatures: gpu.load32(GPURegister.mmuFeatures), asPresent: gpu.load32(GPURegister.asPresent),
        csfID: gpu.load32(GPURegister.csfID), features: read64(gpu, GPURegister.features),
        shaderPresent: read64(gpu, GPURegister.shaderPresent), tilerPresent: read64(gpu, GPURegister.tilerPresent),
        l2Present: read64(gpu, GPURegister.l2Present))
}

/// A 64-bit register, as two 32-bit reads, low first.
func read64(_ gpu: borrowing Registers, _ o: Int) -> UInt64 { UInt64(gpu.load32(o)) | UInt64(gpu.load32(o + 4)) << 32 }

func hexText(_ v: UInt32) -> String {
  let d = Array("0123456789abcdef".utf8)
  var out: [UInt8] = Array("0x".utf8)
  for i in stride(from: 7, through: 0, by: -1) { out.append(d[Int(v >> UInt32(4 * i) & 0xF)]) }
  return String(decoding: out, as: UTF8.self)
}

/// The firmware's image, as devmgr gave it, or no bytes.
func readFirmware() -> [UInt8] {
  guard let ns = try? Namespace(Startup.current), let m = try? ns.memory(FirmwareImage.path, executable: false), m.size >= 4,
    let mapping = try? VMO.map(m.vmo, length: Int(m.size), writable: false)
  else { return [] }
  return mapping.read(at: 0, count: Int(m.size))
}
