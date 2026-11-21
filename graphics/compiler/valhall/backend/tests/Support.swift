// SPDX-License-Identifier: BSD-3-Clause

// What the backend's tests share: compile a corpus text, run it on the
// Valhall interpreter, and run the same text on the IR interpreter for the
// reference.

import MaliCore
import ShaderCompiler
import ShaderTestKit
import Testing
import ValhallBackend
import ValhallBridge
import ValhallISA

func compileText(_ text: String, spec: [(id: UInt32, bits: UInt64)] = [], options: BackendOptions = BackendOptions())
  throws -> CompiledShader
{
  try ValhallBackend.compile(try lowered(text, spec: spec), options: options)
}

struct Run {
  var shader: CompiledShader
  var got: [[UInt8]]
  var want: [[UInt8]]
}

/// Compile `text`, run it over the Valhall interpreter and the IR interpreter, with the same buffers, push constants
/// and grid; `bindings` are the binding numbers of set 0, in the order of `inputs`.
func execute(
  _ text: String, inputs: [[UInt8]], push: [UInt32] = [], grid: (Int, Int, Int), spec: [(id: UInt32, bits: UInt64)] = [],
  options: BackendOptions = BackendOptions()
) throws -> Run {
  let ir = try lowered(text, spec: spec)
  let cs = try ValhallBackend.compile(ir, options: options)
  let machine = Machine(ir)
  var pushBytes: [UInt8] = []
  for w in push { pushBytes += bytes([w]) }
  machine.push = pushBytes
  var buffers: [Buffer] = []
  for (n, b) in inputs.enumerated() {
    machine.setBuffer(0, n, b)
    buffers.append(Buffer(set: 0, binding: n, bytes: b))
  }
  try machine.dispatch(groups: grid)
  var want: [[UInt8]] = []
  for n in 0..<inputs.count { want.append(machine.storage[n] ?? inputs[n]) }
  let out = try HostRun.dispatch(cs, buffers: buffers, push: push, grid: (UInt32(grid.0), UInt32(grid.1), UInt32(grid.2)))
  return Run(shader: cs, got: out.map { $0.bytes }, want: want)
}

func zeros(_ words: Int) -> [UInt8] { [UInt8](repeating: 0, count: words * 4) }

/// Units in the last place between two floats (the interpreter's tests' measure).
func ulpDistance(_ a: Float, _ b: Float) -> Int {
  if a.isNaN && b.isNaN { return 0 }
  func key(_ x: Float) -> Int {
    let u = Int(x.bitPattern)
    return u & 0x8000_0000 != 0 ? -(u & 0x7FFF_FFFF) : u
  }
  return abs(key(a) - key(b))
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
