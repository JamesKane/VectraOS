// SPDX-License-Identifier: BSD-3-Clause

// bin/mali (mali(3)): an Arm Mali CSF GPU's driver host; for now its first
// probe, on the CIX Sky1's Mali-G720 (CIXH5000). Before any GPU register
// read it powers the GPU up in the order the Sky1 needs (lib/Mali.swift's
// Sky1GPU), each step through what owns it:
//   1. the GPU's power domain on, through the SCMI agent (/dev/scmi/ctl);
//   2. its clocks on, by the ids its CLKT gives (/dev/acpi/clocks), the same way;
//   3. its power resource's _ON, which devmgr runs (/dev/acpi/power);
//   4. its reset pulsed, in the reset controller its RSTL names (devmgr
//      grants its registers, `--bar=INDEX:reset`);
//   5. Q-channel clock gating on, in its RCSU (BAR 0).
// A step that fails stops it there, and no GPU register is read. Then it
// reads GPU_ID, the features and the present masks (BAR 1).
//
// Its tree: `status`, each step and what the probe read.

import DriverHost
import IPC
import Node
import Sys

struct StepFailed: Error {
  let text: String
}

/// Writes `line` to `path`, which must take it.
func command(_ ns: Namespace, _ path: String, _ line: String) throws(StepFailed) {
  guard var f = try? ns.open(path) else { throw StepFailed(text: "no \(path)") }
  let bytes = Array((line + "\n").utf8)
  guard (try? f.write(offset: 0, bytes)) == UInt32(bytes.count) else { throw StepFailed(text: "\(path) refused '\(line)'") }
}

func lines(_ text: String) -> [[UInt8]] { text.utf8.split(separator: 0x0A).map { Array($0) } }

func words(_ line: [UInt8]) -> [String] { line.split(separator: 0x20).map { String(decoding: $0, as: UTF8.self) } }

@main struct MaliDriver {
  static func main() {
    let start = Startup.current
    let resources = DeviceResources(take: { start.take($0)?.release() })
    var resetBar: Int?
    for a in start.args where a.utf8.starts(with: "--bar=".utf8) && a.utf8.reversed().starts(with: ":reset".utf8.reversed()) {
      let rest = Array(a.utf8.dropFirst(6))
      if let colon = rest.firstIndex(of: 0x3A) { resetBar = Int(String(decoding: rest[..<colon], as: UTF8.self)) }
    }
    var status: [String] = []
    var step = 0
    do throws(StepFailed) {
      guard let ns = try? Namespace(start) else { throw StepFailed(text: "no namespace") }
      // 1. The power domain.
      try command(ns, "/dev/scmi/ctl", "power \(Sky1GPU.powerDomain) on")
      status.append("power domain \(Sky1GPU.powerDomain) on")
      step += 1
      // 2. The clocks, by CLKT's ids.
      let clocks = lines(ns.readText("/dev/acpi/clocks") ?? "").map { words($0) }
      for name in Sky1GPU.clocks {
        guard let c = clocks.first(where: { $0.count == 2 && $0[1].utf8.elementsEqual(name.utf8) }) else {
          throw StepFailed(text: "no clock \(name) in /dev/acpi/clocks")
        }
        try command(ns, "/dev/scmi/ctl", "clock \(c[0]) on")
        status.append("clock \(c[0]) (\(name)) on")
      }
      step += 1
      // 3. The power resource.
      try command(ns, "/dev/acpi/power", "on")
      status.append("power resource on")
      step += 1
      // 4. The reset, pulsed: RSTL's gpu_reset must be the bit we know.
      let resets = lines(ns.readText("/dev/acpi/resets") ?? "").map { words($0) }
      guard resets.contains(where: {
        $0.count == 3 && $0[1].utf8.elementsEqual("\(Sky1GPU.resetIndex)".utf8) && $0[2].utf8.elementsEqual("gpu_reset".utf8)
      }) else {
        throw StepFailed(text: "no gpu_reset \(Sky1GPU.resetIndex) in /dev/acpi/resets")
      }
      guard let resetBar, let rst = try? resources.map(bar: resetBar) else { throw StepFailed(text: "no reset controller") }
      let r = rst.load32(Sky1GPU.resetRegister)
      rst.store32(Sky1GPU.resetRegister, r & ~Sky1GPU.resetBit)
      sleep(until: Clock.monotonic() + 20_000)
      rst.store32(Sky1GPU.resetRegister, r | Sky1GPU.resetBit)
      sleep(until: Clock.monotonic() + 20_000)
      status.append("reset pulsed")
      step += 1
      // 5. Q-channel clock gating.
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
