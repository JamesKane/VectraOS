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
// interrupts are polled at their raw status until then (Device.swift says
// why). Then the scheduler (Service.swift) is made over the backend
// (Backend.swift) and served as the GPU class's `csf` capset at the node
// `gpu` (ServiceIPC.swift). The JOB, MMU and GPU interrupts (devmgr grants all
// three of the device's, by index) are unmasked and each served on a thread
// of its own, which pumps the scheduler; a line that can't be had is replaced
// by a poll, said in status. The MCU is halted before the supply ends
// (HostShutdown).

import DriverHost
import GPUDevice
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
    // What the console gets on success: the GPU and the boot, one line; the whole
    // story is the status file (a run that prints it all outpaces the serial
    // console, whose last lines a reboot then cuts off).
    var headline = ""

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
      headline = probe.lines.first ?? ""
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
    let core: MaliCore? = booted.flatMap { b in memory.map { MaliCore(booted: b, memory: $0, noncoherent: noncoherent) } }
    if let booted {
      print("mali: " + headline + " firmware booted in \(booted.milliseconds) ms")
      print("budget name=gpu.mali.boot_ms value=\(booted.milliseconds) unit=ms")
    } else {
      print("mali: " + status.joined(separator: "; "))
    }

    do throws(Status) {
      let dispatcher = try IPCDispatcher()
      let tree = NodeTree(dispatcher: dispatcher)
      var server: CSFServer<MaliDevice>?
      if let core {
        var service = CSFService(backend: MaliDevice(core: core))
        // Realtime and high priority wait for a privilege a context doesn't hold: 0 and 1.
        service.allowedPriorities = 0b0011
        let made = CSFServer(service: service, dispatcher: dispatcher, bufferVMO: { core.bufferVMO($0) },
                              importVMO: { (vmo: consuming Handle, size: UInt64) in core.importBuffer(vmo: vmo, size: size) })
        server = made
        tree.service("gpu") { (channel: consuming Handle) throws(Status) in
          try dispatcher.add(GPUDeviceIPC.DeviceServer(channel: channel, impl: made.deviceSession))
        }
        serveInterrupts(core, made, resources: &resources)
        HostShutdown.shared.add("halt the MCU") {
          print("mali: supply ending: " + core.haltBeforePowerCut(timeout: 300_000_000))
        }
      }
      let served = server
      tree.text("status", read: {
        guard let core, let served else { return text }
        served.lock.lock()
        let more = (core.statusLines() + served.service.heapStatusLines + served.service.submitStatusLines).map { $0 + "\n" }.joined()
        served.lock.unlock()
        return text + more
      })
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

/// The JOB, MMU and GPU interrupts, each on a thread of its own that pumps the
/// scheduler when it fires and at the time the scheduler or the watchdog next
/// wants; a thread that pumps every 2 ms instead if the JOB or MMU line can't be
/// had (the GPU's alone is read when the others pump). Then unmasked: the MCU's
/// events, the address spaces' faults and the GPU block's (faults, reset and cache
/// clean completions).
func serveInterrupts(_ core: MaliCore, _ server: CSFServer<MaliDevice>, resources: inout DeviceResources) {
  let next: @Sendable () -> Int64? = {
    let watchdog = core.nextWatchdog
    guard let wake = server.nextWake else { return watchdog }
    return min(Int64(truncatingIfNeeded: wake), watchdog)
  }
  var threads: [(String, InterruptThread)] = []
  var missing = ""
  // The GPU block's line (index 2, panthor 11 section 11.4): where it can't be had, the faults are read
  // whenever the others' threads pump (their waits end at least every 50 ms), and status says so.
  var gpuMissing = ""
  for (index, name) in [(0, "JOB"), (1, "MMU"), (2, "GPU")] {
    do throws(Status) {
      let irq = try resources.interrupt(index: index)
      threads.append((name, try InterruptThread(irq, msix: false, next: next, serve: { _, ack in
        server.pump()
        ack()
      })))
    } catch {
      if index == 2 {
        gpuMissing = "(status \(error.rawValue))"
      } else {
        missing += (missing.isEmpty ? "" : ", ") + "\(name) (status \(error.rawValue))"
      }
    }
  }
  server.lock.lock()
  core.interruptThreads = threads
  if missing.isEmpty {
    core.served = gpuMissing.isEmpty
      ? "JOB, MMU and GPU interrupts"
      : "JOB and MMU interrupts; the GPU's line is polled with them: no interrupt \(gpuMissing)"
    if gpuMissing.isEmpty { core.gpuMask = GPUInterrupt.enabled }
    core.enableInterrupts()
  } else {
    core.served = "polled every 2 ms: no interrupt for " + missing
  }
  server.lock.unlock()
  if !missing.isEmpty {
    _ = try? Thread.spawn {
      while true {
        sleep(until: Clock.monotonic() + 2_000_000)
        server.pump()
      }
    }.release()
  }
}

/// GPU_ID, the features and the present masks.
func read(_ gpu: borrowing Registers) -> Probe {
  Probe(id: GPUID(gpu.load32(GPURegister.id)), l2Features: gpu.load32(GPURegister.l2Features),
        tilerFeatures: gpu.load32(GPURegister.tilerFeatures), memFeatures: gpu.load32(GPURegister.memFeatures),
        mmuFeatures: gpu.load32(GPURegister.mmuFeatures), asPresent: gpu.load32(GPURegister.asPresent),
        csfID: gpu.load32(GPURegister.csfID), features: read64(gpu, GPURegister.features),
        threadMaxThreads: gpu.load32(GPURegister.threadMaxThreads),
        threadMaxWorkgroupSize: gpu.load32(GPURegister.threadMaxWorkgroupSize),
        threadMaxBarrierSize: gpu.load32(GPURegister.threadMaxBarrierSize),
        threadFeatures: gpu.load32(GPURegister.threadFeatures), textureFeatures0: gpu.load32(GPURegister.textureFeatures0),
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
