// SPDX-License-Identifier: BSD-3-Clause

// What the lowering's tests share: the committed SPIR-V (made by `vx shaders` from the GLSL beside the tests), the
// compiler taking the lowered words to IR, and fake device memory laid out as the ABI says (RootBlock, SetLayout)
// for the IR interpreter to run the lowered program over.

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif
import ShaderCompiler
import ShaderTestKit
import Testing
import VulkanLowering

func readFile(_ path: String) -> [UInt8]? {
  guard let f = fopen(path, "rb") else { return nil }
  defer { fclose(f) }
  var out: [UInt8] = []
  var chunk = [UInt8](repeating: 0, count: 4096)
  while case let n = fread(&chunk, 1, chunk.count, f), n > 0 { out += chunk[..<n] }
  return out
}

func writeFile(_ path: String, _ bytes: [UInt8]) {
  guard let f = fopen(path, "wb") else { return }
  _ = bytes.withUnsafeBufferPointer { fwrite($0.baseAddress, 1, $0.count, f) }
  fclose(f)
}

/// The shader's SPIR-V, from `shaders/<name>.spv` beside this file.
func shader(_ name: String, file: String = #filePath) throws -> [UInt32] {
  var resolved = file
  if let r = realpath(file, nil) {
    resolved = String(cString: r)
    free(r)
  }
  var parts = resolved.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
  parts.removeLast()
  let path = parts.joined(separator: "/") + "/shaders/" + name + ".spv"
  guard let bytes = readFile(path) else { throw TestFailure("\(path): not found; run vx shaders") }
  return words(bytes)
}

struct TestFailure: Error, CustomStringConvertible {
  var description: String
  init(_ d: String) { description = d }
}

/// `lower` with the words kept for a look when `VK_LOWERING_DUMP` names a directory (each as `<name>.spv`).
func lowered(_ name: String, stage: ShaderStage, layout: LoweringLayout, entry: String = "main") throws -> [UInt32] {
  let out = try lower(spirv: try shader(name), stage: stage, entryPoint: entry, layout: layout)
  if let dir = getenv("VK_LOWERING_DUMP") {
    writeFile(String(cString: dir) + "/" + name + ".lowered.spv", bytes(out))
  }
  return out
}

/// What the compiler makes of the words: parsed, lowered to IR, verified, and the same optimised with vectors kept and
/// scalarised. The IR's variants are all run by the tests that run anything.
func compile(_ words: [UInt32]) throws -> [(String, IRModule)] {
  let m = try SPIRVModule.parse(words: words)
  let base = try IRModule.lower(m)
  try base.verify()
  var vec = base
  try vec.optimize(scalarize: false)
  try vec.verify()
  var sc = base
  try sc.optimize(scalarize: true)
  try sc.verify(scalar: true)
  return [("lowered", base), ("optimized", vec), ("scalarised", sc)]
}

// MARK: fake device memory

/// Memory the interpreter reads as 64-bit addresses: each allocation is one of its storage buffers, and the address
/// of one is the interpreter's tagged pointer to it.
struct FakeMemory {
  var machine: Machine
  var count = 0

  init(_ machine: Machine) { self.machine = machine }

  /// Puts `bytes` in memory and returns their address.
  mutating func place(_ bytes: [UInt8]) -> UInt64 {
    let base = 0x1000 + count
    count += 1
    machine.storage[base] = bytes
    return 1 << 60 | UInt64(base) << 32
  }

  /// The bytes at an address `place` returned.
  func read(_ address: UInt64) -> [UInt8] { machine.storage[Int((address >> 32) & 0x0fff_ffff)] ?? [] }

  /// The root block: the set records' addresses, the vertex buffers' and the push constants.
  mutating func root(sets: [UInt64] = [], vertexBuffers: [UInt64] = [], push: [UInt8] = []) -> UInt64 {
    var b = [UInt8](repeating: 0, count: RootBlock.size)
    for (i, s) in sets.enumerated() { put64(&b, RootBlock.setsOffset + 8 * i, s) }
    for (i, v) in vertexBuffers.enumerated() { put64(&b, RootBlock.vertexBuffersOffset + 8 * i, v) }
    for (i, p) in push.enumerated() { b[RootBlock.pushConstantsOffset + i] = p }
    return place(b)
  }
}

func put32(_ b: inout [UInt8], _ at: Int, _ v: UInt32) {
  for k in 0..<4 { b[at + k] = UInt8(truncatingIfNeeded: v >> UInt32(8 * k)) }
}

func put64(_ b: inout [UInt8], _ at: Int, _ v: UInt64) {
  for k in 0..<8 { b[at + k] = UInt8(truncatingIfNeeded: v >> UInt64(8 * k)) }
}

/// A buffer descriptor: `u64 address, u64 range`.
func bufferDescriptor(_ address: UInt64, range: Int) -> [UInt8] {
  var b = [UInt8](repeating: 0, count: descriptorSize)
  put64(&b, 0, address)
  put64(&b, 8, UInt64(range))
  return b
}

/// A slot descriptor: `u32 slot` (a combined image sampler's two: texture, then sampler).
func slotDescriptor(_ slots: UInt32...) -> [UInt8] {
  var b = [UInt8](repeating: 0, count: descriptorSize)
  for (i, s) in slots.enumerated() { put32(&b, 4 * i, s) }
  return b
}

func le(_ v: UInt64, bytes n: Int) -> [UInt8] { (0..<n).map { UInt8(truncatingIfNeeded: v >> UInt64(8 * $0)) } }

func f32(_ values: Float...) -> [UInt8] { bytes(values) }

/// The SPIR-V words' declarations of one kind: the instructions of opcode `op`, each as its operand words.
func instructions(_ words: [UInt32], op: UInt16) -> [[UInt32]] {
  var out: [[UInt32]] = []
  var pos = 5
  while pos < words.count {
    let count = Int(words[pos] >> 16)
    if UInt16(truncatingIfNeeded: words[pos]) == op { out.append(Array(words[(pos + 1)..<(pos + count)])) }
    pos += max(count, 1)
  }
  return out
}
