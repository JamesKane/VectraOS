// SPDX-License-Identifier: BSD-3-Clause

// gpu-test's compiled shaders (gpu-test(8), D174 section 6 step 1): SPIR-V, made on the host and
// committed as arrays (generated/CompilerShaders.swift), is compiled here on the device by the Valhall
// backend (graphics/compiler, built into this program), its FAU block is filled from the layout the
// backend gives, and MaliCore dispatches it. Each result is read back and compared with the CPU's,
// word for word.

import GPUClient
import GPUDevice
import Sys

/// The shaders gpu-test compiles, compiled.
struct CompiledSet {
  var globalID: CompiledShader
  var saxpy: CompiledShader
  var reduce: CompiledShader
  /// The triangle's vertex and fragment shaders (nil when the compiler refused one).
  var triangle: TriangleCheck.Compiled?
}

extension GPUTest {
  /// Where the compiled rig binds its memory: the dispatch block, the data buffers (1 MiB apart), the
  /// thread storage and the workgroup memory.
  static let blockAddress: UInt64 = 0x10_0000
  static let blockCapacity = 16384
  static let dataAddress: UInt64 = 0x100_0000
  static let dataStride: UInt64 = 0x10_0000
  static let threadStorageAddress: UInt64 = 0x1000_0000
  static let workgroupMemoryAddress: UInt64 = 0x2000_0000
  static let guardWords = 4

  /// What the compiled checks found wrong, so one failure doesn't end the run before the rest.
  nonisolated(unsafe) static var compiledFailures: [String] = []

  /// Say a check failed and go on; the run fails after the compiled checks.
  static func softFail(_ what: String) {
    print("gpu-test: FAILED: \(what)")
    compiledFailures.append(what)
  }

  static func micros(_ ns: Int64) -> Int64 { ns / 1000 }

  /// Compile `words` with the backend, timing it; fails the run if the backend refuses.
  static func compile(_ name: String, _ words: [UInt32]) -> (shader: CompiledShader, micros: Int64) {
    let start = Clock.monotonic()
    let compiled: CompiledShader
    do throws(BackendError) { compiled = try ValhallBackend.compile(spirv: words) } catch {
      fail("the compiler refused \(name): \(error)")
    }
    let took = micros(Clock.monotonic() - start)
    print("gpu-test: compiled \(name): \(compiled.instructions.count) instructions, \(compiled.registersUsed) registers,"
      + " \(compiled.spillSlots) spills, workgroup memory \(compiled.shader.workgroupMemoryBytes) bytes, \(took) us")
    return (compiled, took)
  }

  /// Run `compiled` over `grid` with `inputs` as the buffers of set 0, binding 0 and up, and the push
  /// constants; each buffer holds its words, then `guardWords` words of poison. Returns each buffer's
  /// words (the guard's too) after the run.
  static func dispatch(
    _ name: String, _ compiled: CompiledShader, grid: Dim3, inputs: [[UInt32]], push: [UInt32]
  ) -> [[UInt32]] {
    let context: CSFContext
    let group: UInt32
    let sync: UInt32
    var data: [CSFBuffer] = []
    let arena: CSFBuffer
    do throws(CSFClientError) {
      context = try CSFContext()
      let info = context.info
      guard let limits = context.limits else { fail("the driver reports no thread limits") }
      let vm = try context.createVM().id
      arena = try context.createBuffer(size: blockCapacity)
      try context.bind(vm: vm, buffer: arena, size: UInt64(arena.size), address: blockAddress)
      for (n, words) in inputs.enumerated() {
        let bytes = (words.count + guardWords) * 4
        let buffer = try context.createBuffer(size: (bytes + 4095) / 4096 * 4096)
        try context.bind(vm: vm, buffer: buffer, size: UInt64(buffer.size), address: dataAddress + UInt64(n) * dataStride)
        data.append(buffer)
      }
      group = try context.createGroup(vm: vm, ringSizes: [4096])
      sync = try context.createSync()
      let limitsForSizing = ComputeLimits(
        maxThreads: limits.maxThreads, maxWorkgroupSize: limits.maxWorkgroupSize,
        threadFeatures: limits.threadFeatures, shaderPresent: info.shaderPresent)
      guard limitsForSizing.isUsable else { fail("\(name): the thread limits are unusable") }
      let sizing = ComputeSizing.of(shader: compiled.shader, grid: grid, limits: limitsForSizing)
      var tls: UInt64 = 0
      var wls: UInt64 = 0
      if compiled.shader.stackBytes != 0 {
        let buffer = try context.createBuffer(size: Int((sizing.tlsBytes + 4095) / 4096 * 4096))
        try context.bind(vm: vm, buffer: buffer, size: UInt64(buffer.size), address: threadStorageAddress)
        tls = threadStorageAddress
        data.append(buffer)
      }
      if compiled.shader.workgroupMemoryBytes != 0 {
        let buffer = try context.createBuffer(size: Int((sizing.wlsBytes + 4095) / 4096 * 4096))
        try context.bind(vm: vm, buffer: buffer, size: UInt64(buffer.size), address: workgroupMemoryAddress)
        wls = workgroupMemoryAddress
        data.append(buffer)
      }
      for (n, words) in inputs.enumerated() {
        var i = 0
        while i < words.count {
          data[n].store(words[i], at: 4 * i)
          i += 1
        }
        for g in 0..<guardWords { data[n].store(poison, at: 4 * (words.count + g)) }
      }

      let registers = CSRegisterMap(workRegisters: Int(info.workRegisters), unpreserved: Int(info.unpreservedRegisters))
      let scoreboards = CSScoreboards(count: Int(info.scoreboards))
      let arch = Int(info.gpuID >> 28)
      let fau = compiled.layout.block(
        address: { _, binding in dataAddress + UInt64(binding) * dataStride },
        size: { _, binding in UInt32(inputs[binding].count * 4) },
        push: push, workgroups: (grid.x, grid.y, grid.z))
      let request = ComputeDispatchRequest(
        shader: compiled.shader, grid: grid, fau: fau, threadStorage: tls, workgroupMemory: wls, limits: limitsForSizing)
      let image: ComputeDispatchImage
      do throws(DispatchError) {
        image = try ComputeDispatch.build(
          at: blockAddress, capacity: blockCapacity, request: request, registers: registers, scoreboards: scoreboards,
          arch: arch)
      } catch {
        fail("\(name): compute dispatch: \(error)")
      }
      put(image, into: arena, at: 0)
      let rig = CSContextRig(context: context, arena: arena, output: data[0], group: group, sync: sync)
      submit(rig, image, value: 1, what: "compiled \(name)")
      guard let state = try? context.groupState(group), state.state == 0 else {
        fail("the group's state isn't clean after compiled \(name)")
      }
    } catch {
      fail("\(name): context: \(error)")
    }
    var out: [[UInt32]] = []
    for (n, words) in inputs.enumerated() {
      var buffer: [UInt32] = []
      var i = 0
      while i < words.count + guardWords {
        buffer.append(data[n].load(UInt32.self, at: 4 * i))
        i += 1
      }
      out.append(buffer)
    }
    return out
  }

  /// The words of `got` that are not `want`'s, and the guard's untouched: how many differ, the first.
  static func compare(_ got: [UInt32], _ want: [UInt32]) -> (wrong: Int, first: String) {
    var wrong = 0
    var first = ""
    var i = 0
    while i < want.count {
      if got[i] != want[i] {
        wrong += 1
        if first.isEmpty { first = "word \(i) reads \(got[i]) (0x\(String(got[i], radix: 16))), not \(want[i]) (0x\(String(want[i], radix: 16)))" }
      }
      i += 1
    }
    for g in 0..<guardWords where got[want.count + g] != poison {
      wrong += 1
      if first.isEmpty { first = "guard word \(g) past the buffer is overwritten" }
    }
    return (wrong, first)
  }

  /// Compile the three shaders: the bring-up shader (each invocation stores its id), saxpy (floats,
  /// push constants, a branch) and the shared-memory reduction (workgroup memory, barriers, a loop). This
  /// needs no GPU, so it runs first, and reports the slowest compile as the budget (whole milliseconds,
  /// rounded up; each shader's own time is on its line).
  static func compileShaders() -> CompiledSet {
    let ids = compile("globalID", CompilerShaders.globalID)
    let saxpy = compile("saxpy", CompilerShaders.saxpy)
    let reduce = compile("reduce", CompilerShaders.reduce)
    let slowest = max(ids.micros, max(saxpy.micros, reduce.micros))
    print("budget name=compiler.valhall.compile_ms value=\((slowest + 999) / 1000) unit=ms")
    return CompiledSet(globalID: ids.shader, saxpy: saxpy.shader, reduce: reduce.shader, triangle: TriangleCheck.compileShaders())
  }

  /// Dispatch each compiled shader and check its buffers against the CPU's.
  static func compiledShadersRan(_ set: CompiledSet) {
    // Each invocation stores its global invocation id.
    let idOut = dispatch("globalID", set.globalID, grid: Dim3(4), inputs: [[UInt32](repeating: poison, count: 64)], push: [])
    var idWant: [UInt32] = []
    for i in 0..<64 { idWant.append(UInt32(i)) }
    let idCheck = compare(idOut[0], idWant)
    if idCheck.wrong != 0 {
      softFail("compiled globalID is wrong in \(idCheck.wrong) words: \(idCheck.first)")
    } else {
      print("gpu-test: ok: compiled globalID ran (64 invocations, the buffer exact)")
    }

    // y = a * x + y for the first n of 128 elements. The backend multiplies and adds, each rounded; so
    // does the CPU's check.
    let a: Float = 2.5
    let n: UInt32 = 100
    var x: [UInt32] = []
    var y: [UInt32] = []
    var yWant: [UInt32] = []
    for i in 0..<128 {
      let xv = Float(i) * 0.37 + 0.1
      let yv = 1000 - Float(i) * 1.5
      x.append(xv.bitPattern)
      y.append(yv.bitPattern)
      if UInt32(i) < n {
        let product = a * xv
        yWant.append((product + yv).bitPattern)
      } else {
        yWant.append(yv.bitPattern)
      }
    }
    let saxpyOut = dispatch("saxpy", set.saxpy, grid: Dim3(2), inputs: [x, y], push: [a.bitPattern, n])
    let xCheck = compare(saxpyOut[0], x)
    let saxpyCheck = compare(saxpyOut[1], yWant)
    if xCheck.wrong != 0 {
      softFail("compiled saxpy changed its input: \(xCheck.first)")
    } else if saxpyCheck.wrong != 0 {
      softFail("compiled saxpy is wrong in \(saxpyCheck.wrong) words: \(saxpyCheck.first)")
    } else {
      print("gpu-test: ok: compiled saxpy ran (128 invocations, \(n) results bit-exact)")
    }
    // Which instruction is wrong, in variants of saxpy's listing, on this board run.
    let probesWrong = probeSaxpy(set.saxpy)
    print("gpu-test: probes: \(probesWrong) of the variants differ from the CPU's")

    // Each workgroup of 64 sums its 64 inputs in workgroup memory, with barriers.
    var input: [UInt32] = []
    for i in 0..<256 { input.append(UInt32(i % 7 + 1)) }
    var sums: [UInt32] = []
    for g in 0..<4 {
      var s: UInt32 = 0
      for i in 0..<64 { s += input[g * 64 + i] }
      sums.append(s)
    }
    let reduceOut = dispatch(
      "reduce", set.reduce, grid: Dim3(4), inputs: [input, [UInt32](repeating: poison, count: 4)], push: [])
    let inCheck = compare(reduceOut[0], input)
    let reduceCheck = compare(reduceOut[1], sums)
    if inCheck.wrong != 0 {
      softFail("compiled reduce changed its input: \(inCheck.first)")
    } else if reduceCheck.wrong != 0 {
      softFail("compiled reduce is wrong in \(reduceCheck.wrong) sums: \(reduceCheck.first)")
    } else {
      print("gpu-test: ok: compiled reduce ran (4 workgroups of 64, workgroup memory and barriers, the sums exact)")
    }
    if let first = compiledFailures.first {
      fail("\(compiledFailures.count) compiled checks failed, the first: \(first)")
    }
  }
}
