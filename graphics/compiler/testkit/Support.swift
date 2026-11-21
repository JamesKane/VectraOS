// SPDX-License-Identifier: BSD-3-Clause

// What the compiler's test targets share (ShaderCompilerTests and
// ValhallBackendTests): the SPIR-V corpus (Corpus.swift), its assembler
// (SpirvAsm.swift), the IR interpreter that is the corpus's reference
// (Interpreter.swift), and the helpers that take a corpus text to IR.

import ShaderCompiler

/// A SPIR-V module from assembler text.
public func parseOK(_ text: String) throws -> SPIRVModule {
  try SPIRVModule.parse(words: try assemble(text))
}

/// A corpus text lowered to IR and verified.
public func lowered(_ text: String, spec: [(id: UInt32, bits: UInt64)] = []) throws -> IRModule {
  let m = try parseOK(text)
  let ir = try IRModule.lower(m, specialization: spec)
  try ir.verify()
  return ir
}

/// The module as lowered, optimized with vectors, and optimized scalarised;
/// each verified.
public func variants(_ text: String, spec: [(id: UInt32, bits: UInt64)] = []) throws -> [(String, IRModule)] {
  let base = try lowered(text, spec: spec)
  var vec = base
  try vec.optimize(scalarize: false)
  try vec.verify()
  var sc = base
  try sc.optimize(scalarize: true)
  try sc.verify(scalar: true)
  return [("lowered", base), ("optimized", vec), ("scalarised", sc)]
}

extension String {
  /// Every occurrence of `a` replaced by `b` (the tests have no Foundation).
  public func replacingOccurrences(of a: String, with b: String) -> String {
    var out = ""
    var rest = self[...]
    while let r = rest.firstRange(of: a) {
      out += rest[rest.startIndex..<r.lowerBound]
      out += b
      rest = rest[r.upperBound...]
    }
    return out + rest
  }
}
