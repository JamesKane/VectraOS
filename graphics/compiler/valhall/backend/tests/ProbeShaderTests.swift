// SPDX-License-Identifier: BSD-3-Clause

// The variants of saxpy's listing gpu-test (drivers/gpu/tests/native, Probes.swift) dispatches on the
// board, as words (drivers/gpu/tests/native/generated/ProbeShaders.swift). The ISA's assembler reads
// Characters, which the device's Embedded Swift can't link, so the assembling happens here: each variant
// is assembled, validated for the registers the compiled saxpy uses, and encoded; the test regenerates the
// file's text and fails when the committed file differs (`VX_REGENERATE_SHADERS=1 swift test --filter
// ProbeShaderTests` rewrites it), and checks the listing's words are the compiler's own.

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif
import ShaderTestKit
import Testing
import ValhallBackend
import ValhallISA

/// Saxpy's loads of x[i] into r2 and y[i] into r3, then the waits for both.
let probePrefix = """
  SHADD.u64 r0:r1, u0, r60:r61.w0, shift:2
  LOAD.i32.slot0 @r2, [r0^:r1^], offset:0
  SHADD.u64 r0:r1, u1, r60:r61.w0, shift:2
  LOAD.i32.slot1 @r3, [r0^:r1^], offset:0
  NOP.wait01

  """

/// Stores register `r` into y[i], and ends.
func probeSuffix(_ r: String) -> String {
  "SHADD.u64 r4:r5, u1, r60^:r61^.w0, shift:2\nSTORE.i32.slot2 @\(r), [r4^:r5^], offset:0\nNOP.wait2\nNOP.end\n"
}

/// Saxpy's listing as the backend's golden test has it (the bound check, the branch, the reconverge).
let probeListing = """
  ICMP_OR.u32.m1.lt r0, r60, u2.w1, 0x0
  BRANCH.not.reconverge r0^, offset:10
  SHADD.u64 r0:r1, u0, r60:r61.w0, shift:2
  LOAD.i32.slot0 @r2, [r0^:r1^], offset:0
  SHADD.u64 r0:r1, u1, r60:r61.w0, shift:2
  LOAD.i32.slot1 @r3, [r0^:r1^], offset:0
  FMA.f32.wait0 r0, u2.w0, r2^, 0x0.neg
  FADD.f32.wait1 r0, r0^, r3^
  SHADD.u64 r2:r3, u1, r60^:r61^.w0, shift:2
  STORE.i32.slot2 @r0, [r2^:r3^], offset:0
  NOP.wait2
  NOP.reconverge
  NOP.end

  """

let probeVariants: [(name: String, text: String)] = [
  ("a-store-x", probePrefix + probeSuffix("r2")),
  ("b-fadd-a-plus-0", probePrefix + "FADD.f32 r0, u2.w0, 0x0\n" + probeSuffix("r0")),
  ("b2-iadd-imm-a", probePrefix + "IADD_IMM.i32 r0, u2.w0, #0x0\n" + probeSuffix("r0")),
  ("c-fma-neg0", probePrefix + "FMA.f32 r0, u2.w0, r2^, 0x0.neg\n" + probeSuffix("r0")),
  ("c2-fma-neg0-no-last-use", probePrefix + "FMA.f32 r0, u2.w0, r2, 0x0.neg\n" + probeSuffix("r0")),
  ("d-fma-register-zero", probePrefix + "IADD_IMM.i32 r4, 0x0, #0x0\nFMA.f32 r0, u2.w0, r2, r4\n" + probeSuffix("r0")),
  ("d2-fma-plain-0", probePrefix + "FMA.f32 r0, u2.w0, r2, 0x0\n" + probeSuffix("r0")),
  ("d3-fma-a-in-register", probePrefix + "FADD.f32 r4, u2.w0, 0x0\nFMA.f32 r0, r4, r2, 0x0.neg\n" + probeSuffix("r0")),
  ("e-fmul", probePrefix + "FMUL.f32 r0, u2.w0, r2\n" + probeSuffix("r0")),
  ("f-fadd", probePrefix + "FADD.f32 r0, r2, r3\n" + probeSuffix("r0")),
  ("g-listing-assembled", probeListing),
  // The listing's FMA writes r0 while the second LOAD, whose address is r0:r1, may be in flight (the FMA waits
  // slot 0 only): h waits both slots before the FMA, i writes r4 instead.
  ("h-listing-fma-waits-both", probeListing.replacingBytes("FMA.f32.wait0", with: "FMA.f32.wait01")),
  ("i-listing-fma-into-r4", probeListing.replacingBytes("FMA.f32.wait0 r0, u2.w0, r2^, 0x0.neg", with: "FMA.f32.wait0 r4, u2.w0, r2^, 0x0.neg")
    .replacingBytes("FADD.f32.wait1 r0, r0^, r3^", with: "FADD.f32.wait1 r4, r4^, r3^")
    .replacingBytes("STORE.i32.slot2 @r0", with: "STORE.i32.slot2 @r4")),
]

extension String {
  func replacingBytes(_ a: String, with b: String) -> String {
    let t = Array(utf8), p = Array(a.utf8)
    var out: [UInt8] = []
    var i = 0
    var done = false
    while i < t.count {
      if !done, i + p.count <= t.count, Array(t[i..<i + p.count]) == p {
        out += Array(b.utf8)
        i += p.count
        done = true
      } else {
        out.append(t[i])
        i += 1
      }
    }
    precondition(done, "no \(a)")
    return String(decoding: out, as: UTF8.self)
  }
}

func probeWords(_ text: String, class32: Bool) throws -> [UInt64] {
  let isa = ISATable.shared
  let program = try isa.assemble(program: text)
  let options = ValidatorOptions(arch: 12, stage: .compute, registerClass: class32 ? .class32 : .class64)
  let found = isa.validate(program, options: options)
  #expect(found.isEmpty, "\(text)")
  return try program.map { try isa.encode($0) }
}

func probeShadersSwift(class32: Bool) throws -> String {
  var out = """
    // SPDX-License-Identifier: BSD-3-Clause
    //
    // Generated from the variants in graphics/compiler/valhall/backend/tests/ProbeShaderTests.swift by that
    // test. Do not edit; regenerate (VX_REGENERATE_SHADERS=1 swift test --filter ProbeShaderTests).
    // Variants of saxpy's listing as Valhall words, for gpu-test's probes (Probes.swift).

    struct ProbeShader {
      var name: String
      var words: [UInt64]
    }

    enum ProbeShaders {

    """
  func row(_ words: [UInt64]) -> String {
    var s = ""
    for w in words {
      var h = String(w, radix: 16)
      while h.count < 16 { h = "0" + h }
      s += "    0x\(h),\n"
    }
    return s
  }
  out += "  /// saxpy's listing as the compiler writes it.\n  static let listing: [UInt64] = [\n"
  out += row(try probeWords(probeListing, class32: class32)) + "  ]\n\n"
  // The disassembler reads Strings by Character too, so the device prints these lines for its words.
  out += "  /// The listing's lines, disassembled.\n  static let listingLines: [String] = [\n"
  for i in try ISATable.shared.assemble(program: probeListing) { out += "    \"\(ISATable.shared.disassemble(i))\",\n" }
  out += "  ]\n\n"
  out += "  static let variants: [ProbeShader] = [\n"
  for (name, text) in probeVariants {
    out += "    ProbeShader(name: \"\(name)\", words: [\n"
    out += row(try probeWords(text, class32: class32)).split(separator: "\n").map { "  " + $0 + "\n" }.joined()
    out += "    ]),\n"
  }
  out += "  ]\n}\n"
  return out
}

@Suite struct ProbeShaderTests {
  static let generated = "drivers/gpu/tests/native/generated/ProbeShaders.swift"

  /// The repository's root: this file's place, up to the package.
  static func root() -> String {
    var path = #filePath
    if let r = realpath(path, nil) {
      path = String(cString: r)
      free(r)
    }
    for _ in 0..<6 { path = String(path[..<path.lastIndex(of: "/")!]) }
    return path
  }

  @Test func theCommittedWordsAreTheVariantsAssembled() throws {
    let cs = try compileText(Corpus.saxpy)
    let text = try probeShadersSwift(class32: cs.shader.registerClass == .r32)
    let path = Self.root() + "/" + Self.generated
    if getenv("VX_REGENERATE_SHADERS") != nil {
      guard let f = fopen(path, "wb") else {
        Issue.record("can't write \(path)")
        return
      }
      _ = Array(text.utf8).withUnsafeBufferPointer { fwrite($0.baseAddress, 1, $0.count, f) }
      fclose(f)
    }
    var committed: String?
    if let f = fopen(path, "rb") {
      var bytes: [UInt8] = []
      var chunk = [UInt8](repeating: 0, count: 4096)
      while case let n = fread(&chunk, 1, chunk.count, f), n > 0 { bytes += chunk[..<n] }
      fclose(f)
      committed = String(decoding: bytes, as: UTF8.self)
    }
    #expect(committed == text, "regenerate with VX_REGENERATE_SHADERS=1 swift test --filter ProbeShaderTests")
  }

  @Test func theListingsWordsAreTheCompilersOwn() throws {
    let cs = try compileText(Corpus.saxpy)
    #expect(try probeWords(probeListing, class32: cs.shader.registerClass == .r32) == cs.shader.code)
  }
}
