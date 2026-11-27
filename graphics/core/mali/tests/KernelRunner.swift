// SPDX-License-Identifier: BSD-3-Clause

// The transfers' kernels on the host (gpucore(2)): a device whose transfer kernels run, as each is launched, on the
// interpreter (ValhallInterp) over the fake transport's memory, so a test judges the bytes the compiled kernel writes, with
// the texture unit modelled for the blit kernel's reads (`textures`, by the job's index in its dispatch).

import GPUCore
import MaliCore
import MaliFakeTransport
import Testing
import ValhallBackend
import ValhallBridge
import ValhallInterp

@testable import GPUCoreMali

final class KernelRunner {
  let transport: FakeTransport
  /// The texture each job of the next blit kernel reads, by the job's index.
  var textures: [Int: TextureModel] = [:]
  /// The kernels run, in order, with their grids.
  var ran: [(kernel: TransferKernel, grid: MaliCore.Dim3)] = []

  init(_ gpu: MaliDevice, _ t: FakeTransport) {
    transport = t
    gpu.transferKernelRan = { k, root, grid, heap in self.run(k, root: root, grid: grid, heap: heap) }
  }

  func run(_ k: TransferKernel, root: UInt64, grid: MaliCore.Dim3, heap: (address: UInt64, bytes: Int)?) {
    ran.append((k, grid))
    do {
      let spirv = k.spirv
      var words: [UInt32] = []
      var i = 0
      while i < spirv.count {
        words.append(UInt32(spirv[i]) | UInt32(spirv[i + 1]) << 8 | UInt32(spirv[i + 2]) << 16 | UInt32(spirv[i + 3]) << 24)
        i += 4
      }
      let cs = try ValhallBackend.compile(spirv: words, options: BackendOptions(arch: transport.info.arch))
      let mem = GpuMemory()
      for b in transport.bound {
        mem.map(b.address, size: b.buffer.size)
        mem.write(b.address, bytes: Array(UnsafeRawBufferPointer(start: b.buffer.pointer, count: b.buffer.size)))
      }
      // A sparse resource's ranges: its pages, at its own addresses (aliases of their buffers' own mappings).
      for r in transport.ranges {
        mem.map(r.address, size: r.size)
        mem.write(r.address, bytes: Array(UnsafeRawBufferPointer(start: r.buffer.pointer + r.offset, count: r.size)))
      }
      let block = cs.layout.block(
        address: { _, _ in 0 }, size: { _, _ in 0 }, push: [UInt32(truncatingIfNeeded: root), UInt32(truncatingIfNeeded: root >> 32)],
        workgroups: (grid.x, grid.y, grid.z), imageHandle: { _, b in DescriptorHeap.handle(index: b == 1 ? 0 : 2) },
        dummySampler: DescriptorHeap.handle(index: 0))
      var fau: [UInt32] = []
      for w in block {
        fau.append(UInt32(truncatingIfNeeded: w))
        fau.append(UInt32(truncatingIfNeeded: w >> 32))
      }
      var code: [Instr] = []
      for instruction in cs.instructions { code.append(try instruction.interpInstr()) }
      let ws = cs.shader.workgroupSize
      var cfg = DispatchConfig(
        workgroupSize: ValhallInterp.Dim3(ws.x, ws.y, ws.z), grid: ValhallInterp.Dim3(grid.x, grid.y, grid.z), fau: fau,
        sharedBytes: Int(cs.shader.workgroupMemoryBytes), threadLocalBytes: Int(cs.shader.stackBytes))
      cfg.flushDenormals = cs.shader.flushToZeroMode != 0
      if let heap {
        var models: [UInt32: TextureModel] = [:]
        for (j, m) in textures { models[DescriptorHeap.handle(index: 2 + j)] = m }
        var samplers: [UInt32: SamplerModel] = [:]
        for n in 0..<2 {
          var s = SamplerModel()
          s.words = mem.read32(heap.address + UInt64(32 * n), count: 8)
          samplers[DescriptorHeap.handle(index: n)] = s
        }
        let t = models
        let s = samplers
        cfg.textures = { t[$0] }
        cfg.samplers = { s[$0] }
      }
      _ = try runDispatch(Shader(code), cfg, memory: mem)
      for b in transport.bound {
        let bytes = mem.read(b.address, count: b.buffer.size)
        for (n, v) in bytes.enumerated() { b.buffer.pointer.storeBytes(of: v, toByteOffset: n, as: UInt8.self) }
      }
      // What the kernel wrote through a sparse resource lands in the pages bound there.
      for r in transport.ranges {
        let bytes = mem.read(r.address, count: r.size)
        for (n, v) in bytes.enumerated() { r.buffer.pointer.storeBytes(of: v, toByteOffset: r.offset + n, as: UInt8.self) }
      }
    } catch {
      Issue.record("the \(k) kernel failed on the interpreter: \(error)")
    }
  }
}

/// A device whose transfers run on the interpreter, with every resource feature the board has judged.
func kernelDevice() throws -> (MaliDevice, FakeTransport, KernelRunner) {
  let t = FakeTransport()
  let gpu = try MaliDevice(transport: t)
  gpu.probeEnableResources()
  // A job a stream (the tests read each step's), and the timeline's wait at once (the fake GPU never adds to the chain).
  gpu.mergesQueueJobs = false
  gpu.spinsForCompletion = false
  return (gpu, t, KernelRunner(gpu, t))
}

/// The texture model of an image of 8-bit normalized texels (bytes, `channels` a texel, row-major), as the texture unit reads it:
/// each channel a float, the channels it lacks (0, 0, 0, 1).
func unormTexture(_ bytes: [UInt8], width: Int, height: Int, channels: Int = 4, swapRB: Bool = false) -> TextureModel {
  TextureModel(dim: .d2, width: width, height: height, layers: 1, arrayed: true) { _, _, _, x, y, _ in
    var t: [Float] = [0, 0, 0, 1]
    for c in 0..<channels { t[c] = Float(bytes[(y * width + x) * channels + c]) / 255 }
    if swapRB { t.swapAt(0, 2) }
    return t.map { $0.bitPattern }
  }
}
