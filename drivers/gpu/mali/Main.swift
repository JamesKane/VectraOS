// SPDX-License-Identifier: BSD-3-Clause

// bin/mali (mali(3)): an Arm Mali CSF GPU's driver host; for now its first
// probe, on the CIX Sky1's Mali-G720 (CIXH5000). devmgr starts it with
// its GPU on: its power domain, its clocks, its power resource and its
// reset, in the order the Sky1 needs and each through what owns it (its
// record's `power-up graph`, devmgr(8)); a GPU register read before them
// stops the machine. What is left to the driver is the step in the GPU's
// own registers: Q-channel clock gating on, in its RCSU (BAR 0). Then it
// reads GPU_ID, the features and the present masks (BAR 1). A step that
// fails stops it there, and no GPU register is read.
//
// Its tree: `status`, the step and what the probe read.

import DriverHost
import IPC
import Node
import Sys

struct StepFailed: Error {
  let text: String
}

@main struct MaliDriver {
  static func main() {
    let start = Startup.current
    let resources = DeviceResources(take: { start.take($0)?.release() })
    var status: [String] = []
    var step = 0
    // Its firmware, as devmgr gave it (D164): size and first word, not yet
    // loaded into the GPU.
    status.append(firmwareStatus())
    do throws(StepFailed) {
      // Q-channel clock gating.
      guard let rcsu = try? resources.map(bar: 0) else { throw StepFailed(text: "no RCSU") }
      rcsu.store32(Sky1GPU.control, rcsu.load32(Sky1GPU.control) | Sky1GPU.qChannelClockGate)
      status.append("Q-channel clock gating on, RCSU control \(hexText(rcsu.load32(Sky1GPU.control)))"
        + " harvest \(hexText(rcsu.load32(Sky1GPU.harvest)))")
      step += 1

      // The probe.
      guard let gpu = try? resources.map(bar: 1) else { throw StepFailed(text: "no GPU registers") }
      let probe = read(gpu)
      guard probe.id.isPlausible else { throw StepFailed(text: "GPU_ID reads \(hexText(probe.id.raw)): no GPU answers") }
      status += probe.lines
      status.append("probed")
    } catch {
      let at = step < Sky1GPU.steps.count ? Sky1GPU.steps[step] : "probe"
      status.append("FAILED at \(at): \(error.text)")
    }
    let text = status.map { $0 + "\n" }.joined()
    print("mali: " + status.joined(separator: "; "))

    do throws(Status) {
      let dispatcher = try IPCDispatcher()
      let tree = NodeTree(dispatcher: dispatcher)
      tree.text("status", read: { text })
      guard let export = start.export() else { Process.exit(code: 2) }
      try tree.serve(export)
      try dispatcher.run()
    } catch {
      Process.exit(code: 1)
    }
    _ = consume resources
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

/// The firmware's status line: its size and first word, or `no firmware`.
func firmwareStatus() -> String {
  guard let ns = try? Namespace(Startup.current), let m = try? ns.memory(FirmwareImage.path, executable: false), m.size >= 4,
    let mapping = try? VMO.map(m.vmo, length: Int(m.size), writable: false)
  else { return FirmwareImage.missing }
  return FirmwareImage.line(size: Int(m.size), head: mapping.read(at: 0, count: 4))
}
