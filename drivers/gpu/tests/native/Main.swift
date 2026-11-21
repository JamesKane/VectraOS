// SPDX-License-Identifier: BSD-3-Clause

// bin/gpu-test (gpu-test(8), D173): what runs on a command-stream GPU
// through the GPU class's `csf` capset: a user stream the GPU runs, a
// stream that faults ending only its group, the cost of a job that
// does nothing, and a compute shader that writes each invocation's id
// into a buffer. The streams are the user side's own, MaliCore's
// (graphics/mali, chinese-wall's valhall 01 and 02): MOV48 and STORE_STATE
// of the timestamp, then a SYNC_ADD64 into a counter word of the buffer;
// the compute dispatch is MaliCore's recipe over its hand-assembled shader.
// Then the compiler (graphics/compiler, built in) compiles SPIR-V on the device and the same recipe runs
// the result (Compiled.swift).
// The driver wraps each stream in the kernel's ring sequence. This program
// is built with MaliCore's files.
//
// Where no GPU offers `csf`, it says so and exits 0.

import GPUClient
import GPUDevice
import Node
import Sys

@main struct GPUTest {
  static func fail(_ what: String) -> Never {
    print("gpu-test: FAILED: \(what)")
    Process.exit(code: 1)
  }

  /// Where the buffer is bound in the VM: the stream at its start, the timestamp
  /// and the counter in the second page.
  static let base: UInt64 = 0x10_0000
  static let timestampOffset = 4096
  static let counterOffset = 4096 + 64

  static func main() {
    let ns: Namespace
    do throws(NamespaceError) { ns = try Namespace(Startup.current) } catch { fail("no namespace") }
    GPUContext.namespace = ns
    // The compiler needs no GPU: its shaders compile first, so a compile that fails shows where no GPU
    // offers csf too.
    let compiled = compileShaders()
    guard CSFContext.isOffered() else {
      explainSkip(ns)
      print("gpu-test: skipped: no csf GPU")
      Process.exit(code: 0)
    }
    ranAStream()
    aFaultEndedOnlyItsGroup()
    emptyJobs()
    aComputeShaderRan()
    compiledShadersRan(compiled)
    print("gpu-test: passed")
    Process.exit(code: 0)
  }

  /// A context with a VM, a two-page buffer bound at `base`, a group of one queue and a sync.
  struct Rig {
    var context: CSFContext
    var vm: UInt32
    var buffer: CSFBuffer
    var group: UInt32
    var sync: UInt32
  }

  static func rig() -> Rig {
    do throws(CSFClientError) {
      let context = try CSFContext()
      let vm = try context.createVM().id
      let buffer = try context.createBuffer(size: 8192)
      try context.bind(vm: vm, buffer: buffer, size: UInt64(buffer.size), address: base)
      let group = try context.createGroup(vm: vm, ringSizes: [4096])
      let sync = try context.createSync()
      return Rig(context: context, vm: vm, buffer: buffer, group: group, sync: sync)
    } catch {
      fail("context: \(error)")
    }
  }

  /// MOV48 r0 timestamp's address; STORE_STATE the timestamp there; MOV48 r2
  /// the counter's address and r4 1; wait for the store; SYNC_ADD64 r4 into
  /// the counter.
  static func stream() -> [UInt64] {
    [
      CSInstruction.mov48(0, base + UInt64(timestampOffset)),
      CSInstruction.storeState(address: 0, state: .timestamp),
      CSInstruction.mov48(2, base + UInt64(counterOffset)),
      CSInstruction.mov48(4, 1),
      CSInstruction.wait(mask: 0x00FF),
      CSInstruction.syncAdd64(address: 2, value: 4, errorPropagate: true),
    ]
  }

  static func ranAStream() {
    let r = rig()
    let words = stream()
    r.buffer.write(words: words, at: 0)
    r.buffer.store(UInt64(0), at: timestampOffset)
    r.buffer.store(UInt64(0), at: counterOffset)
    let job = GPUCSFIPC.Job(queue: 0, stream: base, size: UInt32(words.count * 8), flush: 0)
    do throws(CSFClientError) { try r.context.submit(group: r.group, jobs: [job], signals: [(r.sync, 1)]) } catch {
      fail("submit: \(error)")
    }
    guard r.context.wait(sync: r.sync, value: 1, timeoutNanoseconds: 10_000_000_000) else {
      fail("the GPU didn't raise the counter within 10 seconds")
    }
    let timestamp = r.buffer.load(UInt64.self, at: timestampOffset)
    let counter = r.buffer.load(UInt64.self, at: counterOffset)
    guard timestamp != 0 else { fail("the stream's timestamp reads 0") }
    guard counter == 1 else { fail("the stream's counter word reads \(counter), not 1") }
    guard let state = try? r.context.groupState(r.group), state.state == 0 else { fail("the group's state isn't clean") }
    print("gpu-test: ok: the GPU ran a command stream (timestamp \(timestamp))")
  }

  /// A CALL to an address nothing maps: the MMU faults, the group ends, its
  /// context is lost; another context's stream still runs.
  static func aFaultEndedOnlyItsGroup() {
    let r = rig()
    let unmapped: UInt64 = 0x7000_0000
    let words: [UInt64] = [
      CSInstruction.mov48(0, unmapped),
      CSInstruction.mov32(2, 64),
      CSInstruction.call(address: 0, size: 2),
      0,
    ]
    r.buffer.write(words: words, at: 0)
    let job = GPUCSFIPC.Job(queue: 0, stream: base, size: UInt32(words.count * 8), flush: 0)
    do throws(CSFClientError) { try r.context.submit(group: r.group, jobs: [job], signals: [(r.sync, 1)]) } catch {
      fail("faulting submit: \(error)")
    }
    // The counter rises when the group ends, with an error.
    guard r.context.wait(sync: r.sync, value: 1, timeoutNanoseconds: 10_000_000_000) else {
      fail("a faulting stream's counter didn't rise within 10 seconds")
    }
    guard let state = try? r.context.groupState(r.group), state.state & 2 != 0, state.fatalQueues & 1 != 0 else {
      fail("a faulting stream left no fatal fault in its group's state")
    }
    do throws(CSFClientError) {
      try r.context.submit(group: r.group, jobs: [job])
      fail("a lost context took a job")
    } catch {
      guard error == .lost else { fail("a lost context's submit says \(error), not lost") }
    }
    print("gpu-test: the fault: group state \(state.state), fatal queues \(state.fatalQueues)")

    // A fresh context's stream.
    let again = rig()
    let good = stream()
    again.buffer.write(words: good, at: 0)
    again.buffer.store(UInt64(0), at: counterOffset)
    let ok = GPUCSFIPC.Job(queue: 0, stream: base, size: UInt32(good.count * 8), flush: 0)
    do throws(CSFClientError) { try again.context.submit(group: again.group, jobs: [ok], signals: [(again.sync, 1)]) } catch {
      fail("submit after a fault: \(error)")
    }
    guard again.context.wait(sync: again.sync, value: 1, timeoutNanoseconds: 10_000_000_000),
      again.buffer.load(UInt64.self, at: counterOffset) == 1
    else { fail("a fresh context's stream didn't run after a fault") }
    print("gpu-test: ok: a faulting stream ended only its group")
  }

  /// Submit to the counter's raise, for a job with no stream: the median of 100.
  static func emptyJobs() {
    let r = rig()
    let empty = GPUCSFIPC.Job(queue: 0, stream: 0, size: 0, flush: 0)
    var times: [Int64] = []
    for i in 1...100 {
      let start = Clock.monotonic()
      do throws(CSFClientError) { try r.context.submit(group: r.group, jobs: [empty], signals: [(r.sync, UInt64(i))]) } catch {
        fail("empty job: \(error)")
      }
      guard r.context.wait(sync: r.sync, value: UInt64(i), timeoutNanoseconds: 10_000_000_000) else {
        fail("an empty job's counter didn't rise within 10 seconds")
      }
      times.append(Clock.monotonic() - start)
    }
    times.sort()
    let median = (times[49] + times[50]) / 2
    print("budget name=gpu.mali.empty_job_us value=\(median / 1000) unit=us")
  }

  // MARK: Compute (MaliCore, D174)

  /// Where the compute rig binds its buffers: the block of descriptors, shader and stream (two images of
  /// 8 KiB each), and the output.
  static let arenaAddress: UInt64 = 0x10_0000
  static let steadyAddress: UInt64 = 0x10_2000
  static let outputAddress: UInt64 = 0x20_0000
  static let invocations = 64
  static let poison: UInt32 = 0xDEAD_BEEF

  /// Store an image's bytes into the buffer at `offset`.
  static func put(_ image: ComputeDispatchImage, into buffer: CSFBuffer, at offset: Int) {
    var i = 0
    while i < image.memory.count {
      buffer.store(image.memory.load64(at: i), at: offset + i)
      i += 8
    }
  }

  /// 64 invocations of the hand-assembled shader (MaliCore's BringUpShader) write their global ids into
  /// the output buffer, which is read back exactly; then 20 one-workgroup dispatches are timed.
  static func aComputeShaderRan() {
    let context: CSContextRig
    do throws(CSFClientError) {
      let c = try CSFContext()
      let vm = try c.createVM().id
      let arena = try c.createBuffer(size: 16384)
      try c.bind(vm: vm, buffer: arena, size: UInt64(arena.size), address: arenaAddress)
      let output = try c.createBuffer(size: 4096)
      try c.bind(vm: vm, buffer: output, size: UInt64(output.size), address: outputAddress)
      let group = try c.createGroup(vm: vm, ringSizes: [4096])
      let sync = try c.createSync()
      context = CSContextRig(context: c, arena: arena, output: output, group: group, sync: sync)
    } catch {
      fail("compute context: \(error)")
    }
    let info = context.context.info
    let registers = CSRegisterMap(workRegisters: Int(info.workRegisters), unpreserved: Int(info.unpreservedRegisters))
    let scoreboards = CSScoreboards(count: Int(info.scoreboards))
    let arch = Int(info.gpuID >> 28)
    // The thread limits the sizing reads: THREAD_MAX_THREADS, THREAD_MAX_WORKGROUP_SIZE and THREAD_FEATURES.
    guard let reported = context.context.limits else { fail("the driver reports no thread limits") }
    let limits = ComputeLimits(maxThreads: reported.maxThreads, maxWorkgroupSize: reported.maxWorkgroupSize,
                               threadFeatures: reported.threadFeatures, shaderPresent: info.shaderPresent)
    guard limits.isUsable else {
      fail("the thread limits are unusable: threads \(reported.maxThreads), workgroup \(reported.maxWorkgroupSize),"
        + " THREAD_FEATURES \(reported.threadFeatures)")
    }
    print("gpu-test: ok: thread limits: \(limits.maxThreadsPerCore) threads a core, workgroups of \(limits.maxThreadsPerWorkgroup),"
      + " \(limits.registersPerCore) registers and \(limits.tasksPerCore) tasks a core, \(limits.coreCount) cores")

    // The check: 4 workgroups of 16, the queue set up and the compute resource requested.
    let first = ComputeDispatchRequest(
      shader: BringUpShader.globalIDStore(workgroupSize: Dim3(16)), grid: Dim3(UInt32(invocations / 16)),
      fau: [outputAddress], limits: limits)
    // The timing: one workgroup of 64, the queue as the first run left it.
    let steady = ComputeDispatchRequest(
      shader: BringUpShader.globalIDStore(workgroupSize: Dim3(64)), grid: Dim3(1), fau: [outputAddress], limits: limits,
      requestComputeResource: false, initialiseQueue: false)
    let checkImage: ComputeDispatchImage
    let steadyImage: ComputeDispatchImage
    do throws(DispatchError) {
      checkImage = try ComputeDispatch.build(at: arenaAddress, capacity: 8192, request: first, registers: registers,
                                             scoreboards: scoreboards, arch: arch)
      steadyImage = try ComputeDispatch.build(at: steadyAddress, capacity: 8192, request: steady, registers: registers,
                                              scoreboards: scoreboards, arch: arch)
    } catch {
      fail("compute dispatch: \(error)")
    }
    put(checkImage, into: context.arena, at: 0)
    put(steadyImage, into: context.arena, at: Int(steadyAddress - arenaAddress))
    for i in 0..<(context.output.size / 4) { context.output.store(poison, at: 4 * i) }

    submit(context, checkImage, value: 1, what: "the compute shader")
    var wrong = 0
    var firstWrong = ""
    for i in 0..<invocations {
      let v = context.output.load(UInt32.self, at: 4 * i)
      if v != UInt32(i) {
        wrong += 1
        if firstWrong.isEmpty { firstWrong = "word \(i) reads \(v)" }
      }
    }
    guard wrong == 0 else { fail("the compute shader's buffer is wrong in \(wrong) of \(invocations) words: \(firstWrong)") }
    guard context.output.load(UInt32.self, at: 4 * invocations) == poison else {
      fail("the compute shader wrote past its \(invocations) words")
    }
    guard let state = try? context.context.groupState(context.group), state.state == 0 else {
      fail("the group's state isn't clean after the compute shader")
    }
    print("gpu-test: ok: a compute shader ran (\(invocations) invocations, the buffer exact)")

    var times: [Int64] = []
    for i in 0..<20 {
      let start = Clock.monotonic()
      submit(context, steadyImage, value: UInt64(i + 2), what: "a one-workgroup dispatch")
      times.append(Clock.monotonic() - start)
    }
    times.sort()
    let median = (times[9] + times[10]) / 2
    print("budget name=gpu.mali.compute_dispatch_us value=\(median / 1000) unit=us")
  }

  struct CSContextRig {
    var context: CSFContext
    var arena: CSFBuffer
    var output: CSFBuffer
    var group: UInt32
    var sync: UInt32
  }

  /// One job of the image's stream, signalling `value`; waits for it, and says what the group did if it doesn't come.
  static func submit(_ rig: CSContextRig, _ image: ComputeDispatchImage, value: UInt64, what: String) {
    let job = GPUCSFIPC.Job(queue: 0, stream: image.stream.address, size: UInt32(image.stream.size), flush: 0)
    do throws(CSFClientError) {
      try rig.context.submit(group: rig.group, jobs: [job], signals: [(rig.sync, value)])
    } catch {
      fail("submit of \(what): \(error)")
    }
    guard rig.context.wait(sync: rig.sync, value: value, timeoutNanoseconds: 10_000_000_000) else {
      var why = "no group state"
      if let s = try? rig.context.groupState(rig.group) { why = "group state \(s.state), fatal queues \(s.fatalQueues)" }
      fail("\(what) didn't finish within 10 seconds (\(why))")
    }
  }
}

/// Why no GPU offered `csf`: what /dev holds, and for each display or GPU
/// entry whether its `gpu` node answers and what capsets it gives.
func explainSkip(_ ns: Namespace) {
  let entries = (try? ns.list("/dev")) ?? []
  var names = ""
  for e in entries { names += " " + e.name }
  print("gpu-test: /dev:" + names)
  for e in entries where e.name.utf8.starts(with: "gpu".utf8) || e.name.utf8.starts(with: "display".utf8) {
    let channel: Handle
    do throws(NamespaceError) { channel = try ns.connect("/dev/\(e.name)/gpu") } catch {
      print("gpu-test: /dev/\(e.name)/gpu: no connection (\(error))")
      continue
    }
    var device = GPUDeviceIPC.DeviceClient(channel: channel)
    if let sets = try? device.capsets() {
      var text = ""
      for s in sets { text += " \(s)" }
      print("gpu-test: /dev/\(e.name)/gpu: capsets" + text)
    } else {
      print("gpu-test: /dev/\(e.name)/gpu: capsets failed")
    }
  }
}
