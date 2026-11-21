// SPDX-License-Identifier: BSD-3-Clause

// What the ALU coverage tests share: GLSL shaders (committed .spv made by `vx shaders`) and assembler text taken through
// the backend, run on the Valhall interpreter, and the byte packing for their buffers. The sweeps that take long run
// only with `VX_SLOW_TESTS` set.

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif
import MaliCore
import ShaderCompiler
import ShaderTestKit
import Testing
import ValhallBackend
import ValhallBridge
import ValhallISA

struct TestFailure: Error, CustomStringConvertible {
  var description: String
  init(_ d: String) { description = d }
}

var slowTests: Bool { getenv("VX_SLOW_TESTS") != nil }

func readFile(_ path: String) -> [UInt8]? {
  guard let f = fopen(path, "rb") else { return nil }
  defer { fclose(f) }
  var out: [UInt8] = []
  var chunk = [UInt8](repeating: 0, count: 4096)
  while case let n = fread(&chunk, 1, chunk.count, f), n > 0 { out += chunk[..<n] }
  return out
}

/// The shader's SPIR-V, from `shaders/<name>.spv` beside this file.
func spirv(_ name: String, file: String = #filePath) throws -> [UInt32] {
  var resolved = file
  if let r = realpath(file, nil) {
    resolved = String(cString: r)
    free(r)
  }
  var parts = resolved.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
  parts.removeLast()
  let path = parts.joined(separator: "/") + "/shaders/" + name + ".spv"
  guard let b = readFile(path) else { throw TestFailure("\(path): not found; run vx shaders") }
  var w: [UInt32] = []
  var k = 0
  while k + 3 < b.count {
    w.append(UInt32(b[k]) | UInt32(b[k + 1]) << 8 | UInt32(b[k + 2]) << 16 | UInt32(b[k + 3]) << 24)
    k += 4
  }
  return w
}

/// Every rule of the ISA validator, for the shader as compiled.
func violations(_ cs: CompiledShader, arch: Int = 12) -> [String] {
  let o = ValidatorOptions(arch: arch, stage: .compute, registerClass: cs.shader.registerClass == .r32 ? .class32 : .class64)
  var out: [String] = []
  for v in ISATable.shared.validate(cs.instructions, options: o) {
    out.append(v.rule + " at " + String(v.instruction) + ": " + v.message)
  }
  return out
}

func compileGLSL(_ name: String, options: BackendOptions = BackendOptions()) throws -> CompiledShader {
  let cs = try ValhallBackend.compile(spirv: try spirv(name), options: options)
  let v = violations(cs)
  if !v.isEmpty { throw TestFailure("\(name): the validator objects: \(v[0])") }
  return cs
}

func compileText(_ text: String, options: BackendOptions = BackendOptions()) throws -> CompiledShader {
  let cs = try ValhallBackend.compile(try lowered(text), options: options)
  let v = violations(cs)
  if !v.isEmpty { throw TestFailure("the validator objects: \(v[0])") }
  return cs
}

func run(
  _ cs: CompiledShader, _ buffers: [[UInt8]], groups: Int = 1, push: [UInt32] = [], wmaskLaunched: Bool = false
) throws -> [[UInt8]] {
  var bs: [Buffer] = []
  for (n, b) in buffers.enumerated() { bs.append(Buffer(set: 0, binding: n, bytes: b)) }
  let out = try HostRun.dispatch(cs, buffers: bs, push: push, grid: (UInt32(groups), 1, 1), wmaskLaunched: wmaskLaunched)
  return out.map { $0.bytes }
}

func pack(_ v: [UInt32]) -> [UInt8] {
  v.flatMap { x in (0..<4).map { UInt8(truncatingIfNeeded: x >> UInt32(8 * $0)) } }
}
func pack16(_ v: [UInt16]) -> [UInt8] {
  v.flatMap { x in [UInt8(truncatingIfNeeded: x), UInt8(truncatingIfNeeded: x >> 8)] }
}
func pack64(_ v: [UInt64]) -> [UInt8] {
  v.flatMap { x in (0..<8).map { UInt8(truncatingIfNeeded: x >> UInt64(8 * $0)) } }
}
func packF(_ v: [Float]) -> [UInt8] { pack(v.map { $0.bitPattern }) }
func unpack(_ b: [UInt8]) -> [UInt32] {
  stride(from: 0, to: b.count - 3, by: 4).map { UInt32(b[$0]) | UInt32(b[$0 + 1]) << 8 | UInt32(b[$0 + 2]) << 16 | UInt32(b[$0 + 3]) << 24 }
}
func unpack16(_ b: [UInt8]) -> [UInt16] {
  stride(from: 0, to: b.count - 1, by: 2).map { UInt16(b[$0]) | UInt16(b[$0 + 1]) << 8 }
}
func unpack64(_ b: [UInt8]) -> [UInt64] {
  stride(from: 0, to: b.count - 7, by: 8).map { k in (0..<8).reduce(UInt64(0)) { $0 | UInt64(b[k + $1]) << UInt64(8 * $1) } }
}
func unpackF(_ b: [UInt8]) -> [Float] { unpack(b).map { Float(bitPattern: $0) } }

/// Units in the last place between two floats.
func ulpDistance(_ a: Float, _ b: Float) -> Int {
  if a.isNaN && b.isNaN { return 0 }
  func key(_ x: Float) -> Int {
    let u = Int(x.bitPattern)
    return u & 0x8000_0000 != 0 ? -(u & 0x7FFF_FFFF) : u
  }
  return abs(key(a) - key(b))
}
