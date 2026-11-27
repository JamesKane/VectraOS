// SPDX-License-Identifier: BSD-3-Clause

// What the GLSL tests share: compiling and linking from text, the lowering's layout a GL program implies (the uniform
// block at set 0 binding 0, a combined image sampler at each binding after it, every attribute in vertex buffer 0), the
// compiler and the Valhall backend taking the lowered words, and fake device memory for the IR interpreter.

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif
@testable import GLSL
import ShaderCompiler
import ShaderTestKit
import Testing
import ValhallBackend
import ValhallISA
import VulkanLowering

struct TestFailure: Error, CustomStringConvertible {
  var description: String
  init(_ d: String) { description = d }
}

func compileShader(_ src: String, _ stage: GLSLStage) throws -> GLSLShader {
  switch compile(source: Array(src.utf8), stage: stage) {
  case .success(let s): return s
  case .failure(let e): throw TestFailure("compile failed:\n\(e.log)")
  }
}

/// The compile's log when it fails; nil when it succeeds.
func compileLog(_ src: String, _ stage: GLSLStage) -> String? {
  switch compile(source: Array(src.utf8), stage: stage) {
  case .success: return nil
  case .failure(let e): return e.log
  }
}

func linkProgram(
  _ vs: String, _ fs: String, bindings: [(name: String, location: UInt32)] = [], options: GLSLLinkOptions = GLSLLinkOptions()
) throws -> GLSLProgram {
  let v = try compileShader(vs, .vertex)
  let f = try compileShader(fs, .fragment)
  do {
    return try link(vertex: v, fragment: f, attributeBindings: bindings, options: options)
  } catch {
    throw TestFailure("link failed:\n\(error.log)")
  }
}

func linkLog(_ vs: String, _ fs: String, bindings: [(name: String, location: UInt32)] = []) throws -> String? {
  let v = try compileShader(vs, .vertex)
  let f = try compileShader(fs, .fragment)
  do {
    _ = try link(vertex: v, fragment: f, attributeBindings: bindings)
    return nil
  } catch {
    return error.log
  }
}

/// The bytes a format takes in vertex buffer 0, each attribute's leaves one after another.
func vertexFormat(_ components: Int) -> VertexFormat {
  [VertexFormat.r32Float, .rg32Float, .rgb32Float, .rgba32Float][components - 1]
}

/// GL's float types' component counts: a vector's, or a matrix column's.
func columnComponents(_ glType: UInt32) -> (columns: Int, rows: Int) {
  switch glType {
  case 0x1406: return (1, 1)
  case 0x8B50, 0x8B51, 0x8B52: return (1, Int(glType - 0x8B50) + 2)
  case 0x8B5A, 0x8B5B, 0x8B5C: let n = Int(glType - 0x8B5A) + 2; return (n, n)
  default: return (1, 4)
  }
}

/// The lowering layout of a linked program: set 0 is the uniform block and the samplers; every attribute is in vertex
/// buffer 0, each location's leaf after the last, its offset in `offsets`.
func loweringLayout(_ p: GLSLProgram) -> (layout: LoweringLayout, offsets: [UInt32: UInt32], stride: UInt32) {
  var bindings = [DescriptorBinding(binding: 0, kind: .uniformBuffer)]
  if p.samplerBindings > 1 {
    for b in 1..<p.samplerBindings { bindings.append(DescriptorBinding(binding: UInt32(b), kind: .combinedImageSampler)) }
  }
  var attrs: [VertexAttribute] = []
  var offsets: [UInt32: UInt32] = [:]
  var off: UInt32 = 0
  for a in p.attributes.sorted(by: { $0.location < $1.location }) {
    let (cols, rows) = columnComponents(a.type)
    for c in 0..<cols {
      let loc = a.location + UInt32(c)
      attrs.append(VertexAttribute(location: loc, binding: 0, format: vertexFormat(rows), offset: off))
      offsets[loc] = off
      off += UInt32(4 * rows)
    }
  }
  let stride = max(off, 4)
  return (LoweringLayout(sets: [SetLayout(bindings: bindings)], vertexBindings: [VertexBinding(binding: 0, stride: stride)], vertexAttributes: attrs), offsets, stride)
}

/// The stage's SPIR-V lowered, read by the compiler and lowered to IR, verified; optimised with and without vectors.
func lowerAndCompile(_ p: GLSLProgram, _ stage: GLSLStage, run backend: Bool = true) throws -> [(String, IRModule)] {
  let (layout, _, _) = loweringLayout(p)
  let words = stage == .vertex ? p.vertexSPIRV : p.fragmentSPIRV
  let lowered: [UInt32]
  do {
    lowered = try lower(spirv: words, stage: stage == .vertex ? .vertex : .fragment, entryPoint: "main", layout: layout)
  } catch {
    throw TestFailure("lowering \(stage) failed: \(error)")
  }
  let m: SPIRVModule
  do { m = try SPIRVModule.parse(words: lowered) } catch { throw TestFailure("the compiler's reader refused the \(stage) stage: \(error.message)") }
  let base: IRModule
  do { base = try IRModule.lower(m) } catch { throw TestFailure("the compiler's lowering refused the \(stage) stage: \(error.message)") }
  do { try base.verify() } catch { throw TestFailure("\(stage): IR verify: \(error.message)") }
  var vec = base
  var sc = base
  do {
    try vec.optimize(scalarize: false)
    try vec.verify()
    try sc.optimize(scalarize: true)
    try sc.verify(scalar: true)
  } catch { throw TestFailure("\(stage): passes: \(error.message)") }
  if backend {
    do {
      let g = try ValhallBackend.compileGraphics(base)
      let o = ValidatorOptions(arch: 12, stage: stage == .vertex ? .vertex : .fragment, registerClass: .class64)
      let broken = ISATable.shared.validate(g.instructions, options: o)
      if !broken.isEmpty { throw TestFailure("\(stage): the ISA validator: \(broken.map { $0.rule + ": " + $0.message })") }
    } catch let e as TestFailure {
      throw e
    } catch {
      throw TestFailure("the Valhall backend refused the \(stage) stage: \(error)")
    }
  }
  return [("lowered", base), ("optimized", vec), ("scalarised", sc)]
}

// MARK: running on the IR interpreter

func put32(_ b: inout [UInt8], _ at: Int, _ v: UInt32) {
  for k in 0..<4 { b[at + k] = UInt8(truncatingIfNeeded: v >> UInt32(8 * k)) }
}

func put64(_ b: inout [UInt8], _ at: Int, _ v: UInt64) {
  for k in 0..<8 { b[at + k] = UInt8(truncatingIfNeeded: v >> UInt64(8 * k)) }
}

func le(_ v: UInt64, bytes n: Int) -> [UInt8] { (0..<n).map { UInt8(truncatingIfNeeded: v >> UInt64(8 * $0)) } }

/// Memory as the interpreter reads 64-bit addresses: each allocation one of its storage buffers.
struct FakeMemory {
  var machine: Machine
  var count = 0
  init(_ machine: Machine) { self.machine = machine }
  mutating func place(_ bytes: [UInt8]) -> UInt64 {
    let base = 0x1000 + count
    count += 1
    machine.storage[base] = bytes
    return 1 << 60 | UInt64(base) << 32
  }
}

/// A uniform block's bytes, written by name through the program's uniform list.
struct UniformBlock {
  var bytes: [UInt8]
  let program: GLSLProgram

  init(_ p: GLSLProgram, flip: Bool = false, height: Float = 0) {
    program = p
    bytes = [UInt8](repeating: 0, count: max(p.uniformBlockBytes, 32))
    let words: [Float] = flip ? [-1, -1, height, 1, 0, 1, 1] : [1, 1, 0, -1, 0, 1, 1]
    for (i, w) in words.enumerated() { put32(&bytes, p.driverBlockOffset + 4 * i, w.bitPattern) }
  }

  /// Sets uniform `name` (as glGetActiveUniform names it, or an element `a[2]`) to floats, column by column; ints and
  /// bools by `ints`.
  mutating func set(_ name: String, _ v: [Float]) { set(name, words: v.map { $0.bitPattern }) }
  mutating func set(_ name: String, ints v: [Int32]) { set(name, words: v.map { UInt32(bitPattern: $0) }) }

  mutating func set(_ name: String, words v: [UInt32]) {
    var base = name
    var element = 0
    if base.hasSuffix("]"), let open = base.lastIndex(of: "[") {
      element = Int(base[base.index(after: open)..<base.index(before: base.endIndex)])!
      base = String(base[..<open])
    }
    guard let u = program.uniforms.first(where: { $0.name == base || $0.name == base + "[0]" }) else {
      Issue.record("no uniform \(name)")
      return
    }
    let (cols, rows) = columnComponents(u.type)
    let isFloatish = [0x1406, 0x8B50, 0x8B51, 0x8B52, 0x8B5A, 0x8B5B, 0x8B5C].contains(u.type)
    let r = isFloatish ? rows : (u.type == 0x1404 || u.type == 0x8B56 ? 1 : Int((u.type - 0x8B53) % 3) + 2)
    var k = 0
    for c in 0..<cols {
      for row in 0..<r where k < v.count {
        put32(&bytes, u.offset + element * u.arrayStride + c * u.matrixStride + 4 * row, v[k])
        k += 1
      }
    }
  }
}

/// A run of one stage on the IR interpreter, the uniform block and the samplers' descriptors in memory as the lowering
/// reads them.
func run(
  _ ir: IRModule, _ p: GLSLProgram, block: UniformBlock, inputs: [Int: [Float]] = [:], vertexBytes: [UInt8] = [],
  vertexIndex: UInt64 = 0, fragCoord: [Float] = [0, 0, 0, 1], texel: ((UInt64, [Float], Int) -> Float)? = nil
) throws -> Machine {
  let machine = Machine(ir)
  machine.vertexIndex = vertexIndex
  var mem = FakeMemory(machine)
  let ubo = mem.place(block.bytes)
  var record = [UInt8](repeating: 0, count: 16 * max(p.samplerBindings, 1))
  put64(&record, 0, ubo)
  put64(&record, 8, UInt64(block.bytes.count))
  // Sampler binding b: texture slot 10 + b, sampler slot 0.
  for b in 1..<max(p.samplerBindings, 1) { put32(&record, 16 * b, UInt32(10 + b)) }
  let set0 = mem.place(record)
  var root = [UInt8](repeating: 0, count: RootBlock.size)
  put64(&root, RootBlock.setsOffset, set0)
  if !vertexBytes.isEmpty { put64(&root, RootBlock.vertexBuffersOffset, mem.place(vertexBytes)) }
  machine.push = le(mem.place(root), bytes: 8)
  for (loc, v) in inputs {
    for (n, x) in ir.inputs.enumerated() where x.location == loc && x.builtin < 0 {
      machine.stageInputs[n] = v.map { UInt64($0.bitPattern) }
    }
  }
  machine.fragCoord = fragCoord.map { UInt64($0.bitPattern) }
  if let t = texel {
    machine.texelModel = { image, _, operands, k in
      let coords = operands.prefix(2).map { Float(bitPattern: UInt32(truncatingIfNeeded: $0)) }
      return UInt64(t(image, coords, k).bitPattern)
    }
  }
  try machine.dispatch(groups: (1, 1, 1))
  return machine
}

/// What a stage wrote to an output: by location (or -1 for the position).
func output(_ m: Machine, _ ir: IRModule, location: Int) -> [Float]? {
  for (n, o) in ir.outputs.enumerated() where (location < 0 ? o.builtin == 0 : o.location == location && o.builtin < 0) {
    return m.stageOutputs[n]?.map { Float(bitPattern: UInt32(truncatingIfNeeded: $0)) }
  }
  return nil
}

func close(_ a: [Float], _ b: [Float], _ tol: Float = 1e-5) -> Bool {
  guard a.count == b.count else { return false }
  for (x, y) in zip(a, b) where !(abs(x - y) <= tol * max(1, abs(y))) { return false }
  return true
}

func readFile(_ path: String) -> [UInt8]? {
  guard let f = fopen(path, "rb") else { return nil }
  defer { fclose(f) }
  var out: [UInt8] = []
  var chunk = [UInt8](repeating: 0, count: 4096)
  while case let n = fread(&chunk, 1, chunk.count, f), n > 0 { out += chunk[..<n] }
  return out
}

/// The repository's root, from this file's path.
func repositoryRoot(file: String = #filePath) -> String {
  var parts = file.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
  parts.removeLast(4)  // graphics/glsl/tests/Support.swift
  return parts.joined(separator: "/")
}

func listDirectory(_ path: String) -> [String] {
  guard let d = opendir(path) else { return [] }
  defer { closedir(d) }
  var names: [String] = []
  while let e = readdir(d) {
    let name = withUnsafeBytes(of: e.pointee.d_name) { raw in String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self) }
    if !name.hasPrefix(".") { names.append(name) }
  }
  return names.sorted()
}
