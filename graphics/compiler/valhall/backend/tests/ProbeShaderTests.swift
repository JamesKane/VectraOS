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
// The two loads with no wait after them (the q variants add their own).
let probeLoads = """
  SHADD.u64 r0:r1, u0, r60:r61.w0, shift:2
  LOAD.i32.slot0 @r2, [r0^:r1^], offset:0
  SHADD.u64 r0:r1, u1, r60:r61.w0, shift:2
  LOAD.i32.slot1 @r3, [r0^:r1^], offset:0

  """

func probeSuffix(_ r: String) -> String {
  "SHADD.u64 r4:r5, u1, r60^:r61^.w0, shift:2\nSTORE.i32.slot2 @\(r), [r4^:r5^], offset:0\nNOP.wait2\nNOP.end\n"
}

/// Saxpy's listing as the backend's golden test has it (the bound check, the branch, the reconverge). The waits
/// sit on instructions before their readers: a wait in the flow field takes effect after its carrier.
let probeListing = """
  ICMP_OR.u32.m1.lt r0, r60, u2.w1, 0x0
  BRANCH.not.reconverge r0^, offset:11
  SHADD.u64 r0:r1, u0, r60:r61.w0, shift:2
  LOAD.i32.slot0 @r2, [r0^:r1^], offset:0
  SHADD.u64 r0:r1, u1, r60:r61.w0, shift:2
  LOAD.i32.slot1 @r3, [r0^:r1^], offset:0
  NOP.wait0
  FMA.f32.wait1 r0, u2.w0, r2^, 0x0.neg
  FADD.f32 r0, r0^, r3^
  SHADD.u64 r2:r3, u1, r60^:r61^.w0, shift:2
  STORE.i32.slot2 @r0, [r2^:r3^], offset:0
  NOP.wait2
  NOP.reconverge
  NOP.end

  """

/// The listing as the compiler wrote it before the board showed that waits take effect after their carrier: each
/// wait is on the instruction that reads (`FMA.f32.wait0` reads x, `FADD.f32.wait1` reads y). On the board its
/// results were garbage; the interpreter faults on it (ValhallInterp), and the validator rejects it.
let probeListingOld = """
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

/// The variants the board is expected to get wrong, by the rule the probes found: a wait carried by the reading
/// instruction takes effect after the read.
func probeExpectsFailure(_ name: String) -> Bool {
  name.utf8.starts(with: "q4".utf8) || name.utf8.starts(with: "r-".utf8)
}

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
  ("h-listing-fma-waits-both", probeListing.replacingBytes("NOP.wait0\n", with: "NOP.wait01\n")),
  ("i-listing-fma-into-r4", probeListing.replacingBytes("FMA.f32.wait1 r0, u2.w0, r2^, 0x0.neg", with: "FMA.f32.wait1 r4, u2.w0, r2^, 0x0.neg")
    .replacingBytes("FADD.f32 r0, r0^, r3^", with: "FADD.f32 r4, r4^, r3^")
    .replacingBytes("STORE.i32.slot2 @r0", with: "STORE.i32.slot2 @r4")),
  // Bisecting the listing (g, h and i failed on the board while every piece alone passed):
  // j drops the compare and branch; k keeps the compare but drops the branch; 
  // m stores the compare's result; n stores y (r3), o stores a*x (the FMA alone), p stores x,
  // each within the listing's own shape.
  ("j-listing-no-compare-branch", probeListing.replacingBytes("ICMP_OR.u32.m1.lt r0, r60, u2.w1, 0x0\n", with: "")
    .replacingBytes("BRANCH.not.reconverge r0^, offset:11\n", with: "").replacingBytes("NOP.reconverge\n", with: "")),
  ("k-listing-compare-no-branch", probeListing.replacingBytes("BRANCH.not.reconverge r0^, offset:11\n", with: "")
    .replacingBytes("NOP.reconverge\n", with: "")),
  ("m-compare-result", "ICMP_OR.u32.m1.lt r0, r60, u2.w1, 0x0\n" + probeSuffix("r0")),
  ("n-listing-stores-y", probeListing.replacingBytes("FADD.f32 r0, r0^, r3^", with: "FADD.f32 r0, r3^, 0x0")),
  ("o-listing-stores-ax", probeListing.replacingBytes("FADD.f32 r0, r0^, r3^", with: "FADD.f32 r0, r0^, 0x0")),
  ("p-listing-stores-x", probeListing.replacingBytes("FMA.f32.wait1 r0, u2.w0, r2^, 0x0.neg", with: "FADD.f32.wait1 r0, r2^, 0x0")
    .replacingBytes("FADD.f32 r0, r0^, r3^", with: "FADD.f32 r0, r0^, 0x0")),
  // q: which slot a wait value names (p failed with `FADD.wait0` reading the slot-0 load; n passed with `.wait1`):
  // the loads with no wait, then q1 `NOP.wait0`, q2 `NOP.wait2`, q3 the read itself carrying `.wait2`, q4 `.wait0`,
  // each reading x (slot 0's load).
  ("q1-nop-wait0-then-x", probeLoads + "NOP.wait0\nFADD.f32 r0, r2^, 0x0\nNOP.wait1\n" + probeSuffix("r0")),
  ("q2-nop-wait2-then-x", probeLoads + "NOP.wait2\nFADD.f32 r0, r2^, 0x0\nNOP.wait1\n" + probeSuffix("r0")),
  ("q3-carried-wait2-x", probeLoads + "FADD.f32.wait2 r0, r2^, 0x0\nNOP.wait1\n" + probeSuffix("r0")),
  ("q4-carried-wait0-x", probeLoads + "FADD.f32.wait0 r0, r2^, 0x0\nNOP.wait1\n" + probeSuffix("r0")),
  // q5: a message carrying a wait on its own slot waits for that message (chinese-wall's reading of the board's
  // finding; not yet run on the board): the slot-0 load carries wait0, and the read follows.
  ("q5-load-carries-own-wait-then-x", "SHADD.u64 r0:r1, u0, r60:r61.w0, shift:2\nLOAD.i32.slot0.wait0 @r2, [r0^:r1^], offset:0\nFADD.f32 r0, r2^, 0x0\n" + probeSuffix("r0")),
  // r: the compiler's listing before the finding, whose waits sit on their readers; the board stored garbage.
  ("r-old-listing", probeListingOld),
  // s: hardware measurements, reported and not judged (Probes.swift's probeFRCP and probeWMASK). s1 stores FRCP.f32 of x:
  // the sweep compares it with the correctly rounded reciprocal. s2 is the listing's bound check and branch with the
  // reconverge after the store: the lanes below n run WMASK and store its result, the others skip, so the stored mask says
  // whether WMASK reports the lanes active or the lanes launched.
  ("s1-frcp-x", probePrefix + "FRCP.f32 r0, r2^\n" + probeSuffix("r0")),
  ("s2-wmask-after-branch", """
    ICMP_OR.u32.m1.lt r0, r60, u2.w1, 0x0
    BRANCH.not.reconverge r0^, offset:6
    IADD_IMM.i32 r5, 0x0, #0x1
    WMASK.subgroup16 r4, r5
    SHADD.u64 r2:r3, u1, r60^:r61^.w0, shift:2
    STORE.i32.slot2 @r4, [r2^:r3^], offset:0
    NOP.wait2
    NOP.reconverge
    NOP.end

    """),
  // s3: the same with the lanes at or above n ending at once (the branch goes to the end, with no reconverge).
  ("s3-wmask-after-exit", """
    ICMP_OR.u32.m1.lt r0, r60, u2.w1, 0x0
    BRANCH.not r0^, offset:5
    IADD_IMM.i32 r5, 0x0, #0x1
    WMASK.subgroup16 r4, r5
    SHADD.u64 r2:r3, u1, r60^:r61^.w0, shift:2
    STORE.i32.slot2 @r4, [r2^:r3^], offset:0
    NOP.wait2
    NOP.end

    """),
  // s4: WMASK of a constant in a branch the odd lanes take (x[i] is i & 1): the stored mask is 0xAAAA if WMASK reports the
  // lanes active now, 0xFFFF if the lanes launched.
  ("s4-wmask-odd-lanes", """
    SHADD.u64 r0:r1, u0, r60:r61.w0, shift:2
    LOAD.i32.slot0 @r2, [r0^:r1^], offset:0
    NOP.wait0
    BRANCH.not.reconverge r2^, offset:6
    IADD_IMM.i32 r5, 0x0, #0x1
    WMASK.subgroup16 r4, r5
    SHADD.u64 r2:r3, u1, r60^:r61^.w0, shift:2
    STORE.i32.slot2 @r4, [r2^:r3^], offset:0
    NOP.wait2
    NOP.reconverge
    NOP.end

    """),
  // s5: narrow loads (x[i] is 0xF1F2F383): the register after LOAD.i8 at byte 0 and 3, and LOAD.i16 at byte 0 and 2, stored as
  // a word: 0x00000083 and 0x000000F1, 0x0000F383 and 0x0000F1F2 if they zero extend.
  ("s5a-load-i8-0", "SHADD.u64 r0:r1, u0, r60:r61.w0, shift:2\nLOAD.i8.slot0 @r2, [r0^:r1^], offset:0\nNOP.wait0\n" + probeSuffix("r2")),
  ("s5b-load-i8-3", "SHADD.u64 r0:r1, u0, r60:r61.w0, shift:2\nLOAD.i8.slot0 @r2, [r0^:r1^], offset:3\nNOP.wait0\n" + probeSuffix("r2")),
  ("s5c-load-i16-0", "SHADD.u64 r0:r1, u0, r60:r61.w0, shift:2\nLOAD.i16.slot0 @r2, [r0^:r1^], offset:0\nNOP.wait0\n" + probeSuffix("r2")),
  ("s5d-load-i16-2", "SHADD.u64 r0:r1, u0, r60:r61.w0, shift:2\nLOAD.i16.slot0 @r2, [r0^:r1^], offset:2\nNOP.wait0\n" + probeSuffix("r2")),
  // s6: neighbouring lanes' narrow stores: lane i stores the byte (or half) i + 0x41 at byte i (half i) of y. The words of y
  // are then 0x44434241 ... if concurrent narrow stores to one word are exact.
  ("s6a-store-i8-neighbours", """
    IADD_IMM.i32 r6, r60, #0x41
    SHADD.u64 r4:r5, u1, r60:r61.w0, shift:0
    STORE.i8.slot2 @r6, [r4^:r5^], offset:0
    NOP.wait2
    NOP.end

    """),
  ("s6b-store-i16-neighbours", """
    IADD_IMM.i32 r6, r60, #0x4041
    SHADD.u64 r4:r5, u1, r60:r61.w0, shift:1
    STORE.i16.slot2 @r6, [r4^:r5^], offset:0
    NOP.wait2
    NOP.end

    """),
  // s7: binary16 subnormals under flush mode 0: FADD.v2f16 of x and y, and FMA.v2f16 of x * y + 0 (x[i], y[i] hold two halves).
  ("s7a-fadd-v2f16", probePrefix + "FADD.v2f16 r0, r2, r3\n" + probeSuffix("r0")),
  ("s7b-fma-v2f16", probePrefix + "IADD_IMM.i32 r4, 0x0, #0x0\nFMA.v2f16 r0, r2, r3, r4\n" + probeSuffix("r0")),
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

// `unvalidated` is for a probe that breaks the validator's model on purpose, to test the model on the board
// (q2 and q3 wait on the wrong slot by the spec's reading; q4 and r- carry the wait on the reading instruction, which
// takes effect after the read).
func probeWords(_ text: String, class32: Bool, unvalidated: Bool = false) throws -> [UInt64] {
  let isa = ISATable.shared
  let program = try isa.assemble(program: text)
  let options = ValidatorOptions(arch: 12, stage: .compute, registerClass: class32 ? .class32 : .class64)
  let found = isa.validate(program, options: options)
  if !unvalidated { #expect(found.isEmpty, "\(text)") }
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
      var expectsFailure: Bool
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
    out += "    ProbeShader(name: \"\(name)\", expectsFailure: \(probeExpectsFailure(name)), words: [\n"
    let open = ["q2", "q3", "q4", "r-", "s3"].contains { name.utf8.starts(with: $0.utf8) }
    out += row(try probeWords(text, class32: class32, unvalidated: open)).split(separator: "\n").map { "  " + $0 + "\n" }.joined()
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
