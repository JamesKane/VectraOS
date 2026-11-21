// SPDX-License-Identifier: BSD-3-Clause

// The compiler's corpus (graphics/compiler/testkit) compiled for Valhall and
// run on the Valhall interpreter, against the IR interpreter's result.

import ShaderTestKit
import Testing
import ValhallBackend

@Suite struct CorpusTests {
  @Test func everyCorpusShaderCompilesAndValidates() throws {
    let all: [(String, String)] = [
      ("fill", Corpus.fill), ("saxpy", Corpus.saxpy), ("reduce", Corpus.reduce), ("loopsum", Corpus.loopsum),
      ("vec", Corpus.vec), ("math", Corpus.math), ("atomics", Corpus.atomics), ("spec64", Corpus.spec64),
      ("calls", Corpus.calls), ("locals", Corpus.locals),
    ]
    for (name, text) in all {
      let cs = try compileText(text)
      #expect(violations(cs) == [], "\(name)")
      // Every path ends, and the words are the encoded instructions.
      #expect(cs.shader.code.count == cs.instructions.count, "\(name)")
      #expect(cs.instructions.last?.flow == .end || cs.instructions.last?.mnemonic == "BRANCH", "\(name)")
    }
  }

  @Test func fill() throws {
    let r = try execute(Corpus.fill, inputs: [zeros(128)], grid: (2, 1, 1))
    #expect(words(r.got[0]) == (0..<128).map { UInt32($0) * 3 + 1 })
    #expect(r.got == r.want)
    // The buffer's address is in slot 0 of the FAU, as the bring-up shader's is.
    #expect(r.shader.layout.bindings.count == 1 && r.shader.layout.bindings[0].slot == 0)
    #expect(r.shader.shader.preloadMask == 1 << 12)
  }

  @Test func saxpy() throws {
    let x = (0..<128).map { Float($0) * 0.25 }
    let y = (0..<128).map { Float(1000 - $0) }
    let r = try execute(Corpus.saxpy, inputs: [bytes(x), bytes(y)], push: [Float(2.5).bitPattern, 100], grid: (2, 1, 1))
    #expect(floats(r.got[1]) == (0..<128).map { $0 < 100 ? 2.5 * x[$0] + y[$0] : y[$0] })
    #expect(r.got == r.want)
    // The push constants follow the two buffers' slots: words 4 and 5.
    #expect(r.shader.layout.pushWord == 4 && r.shader.layout.pushWords == 2)
  }

  @Test func reduceWithSharedMemoryAndBarriers() throws {
    let input = (0..<256).map { UInt32($0 % 7 + 1) }
    let r = try execute(Corpus.reduce, inputs: [bytes(input), zeros(4)], grid: (4, 1, 1))
    let want = (0..<4).map { g in input[(g * 64)..<(g * 64 + 64)].reduce(0, +) }
    #expect(words(r.got[1]) == want)
    #expect(r.shader.shader.workgroupMemoryBytes == 256)
    #expect(!r.shader.shader.allowsWorkgroupMerging)
  }

  @Test func loopWithABranch() throws {
    func ref(_ g: UInt32) -> UInt32 {
      var acc: UInt32 = 0
      var i: UInt32 = 0
      while i < g {
        if i & 1 == 0 { acc = acc &+ i } else { acc ^= i &* 3 }
        i += 1
      }
      return acc
    }
    let r = try execute(Corpus.loopsum, inputs: [zeros(128)], grid: (2, 1, 1))
    #expect(words(r.got[0]) == (0..<128).map { ref(UInt32($0)) })
  }

  @Test func vectorsAndExtendedInstructions() throws {
    let input: [Float] = (0..<128 * 4).map { Float(($0 * 37) % 23) * 0.25 - 2.0 }
    let r = try execute(Corpus.vec, inputs: [bytes(input), zeros(128 * 4)], grid: (2, 1, 1))
    let got = floats(r.got[1])
    let want = floats(r.want[1])
    for i in 0..<got.count {
      // sqrt is FRCP(FRSQ(x)): two to three ulps (11c.13.13); the rest is exact.
      #expect(ulpDistance(got[i], want[i]) <= (i % 4 == 0 ? 3 : 0), "lane \(i): \(got[i]) != \(want[i])")
    }
  }

  @Test func everyExtendedInstructionTheLoweringKnows() throws {
    let n = 64
    let x = (0..<n).map { Float($0 + 1) / 6 }
    let r = try execute(Corpus.math, inputs: [bytes(x), zeros(n * 22), zeros(n * 5)], grid: (1, 1, 1))
    let got = floats(r.got[1])
    let want = floats(r.want[1])
    // ulps allowed for each of the 22 results, from valhall 11c.13.13 and the sequences' steps.
    let name = Corpus.mathFloat.map { $0.name }
    for i in 0..<n {
      for k in 0..<22 {
        var allowed = 0
        switch name[k] {
        case "Sqrt": allowed = 3
        case "InverseSqrt": allowed = 2
        case "Exp2", "Exp": allowed = 3 + 2 * Int(max(0, want[i * 22 + k]).squareRoot().squareRoot()) + 2
        case "Pow": allowed = 24
        case "Log2", "Log": allowed = 6
        case "Sin", "Cos": allowed = 0
        case "FMix": allowed = 2
        case "SmoothStep": allowed = 2
        default: allowed = 1
        }
        let g = got[i * 22 + k]
        let w = want[i * 22 + k]
        if name[k] == "Sin" || name[k] == "Cos" {
          // About 2^-15.7 absolute (11c.13.11).
          #expect(abs(g - w) < 5e-5, "\(name[k])(\(x[i])): \(g) != \(w)")
        } else if name[k] == "Log2" || name[k] == "Log" {
          #expect(abs(g - w) < 2e-5 || ulpDistance(g, w) <= allowed, "\(name[k])(\(x[i])): \(g) != \(w)")
        } else {
          #expect(ulpDistance(g, w) <= allowed, "\(name[k])(\(x[i])): \(g) != \(w)")
        }
      }
    }
    #expect(words(r.got[2]) == words(r.want[2]))
  }

  @Test func atomicsAndASwitch() throws {
    let r = try execute(Corpus.atomics, inputs: [zeros(1 + 128), zeros(128)], grid: (2, 1, 1))
    let c = words(r.got[0])
    #expect(c[0] == 128)
    #expect(Array(c[1...]).sorted() == (0..<128).map { UInt32($0) })
    #expect(words(r.got[1]) == (0..<128).map { [10, 20, 30, 30][$0 & 3] })
  }

  @Test func specializationConstantsAndSixtyFourBitIntegers() throws {
    let r = try execute(Corpus.spec64, inputs: [zeros(64)], grid: (1, 1, 1))
    #expect(words(r.got[0]) == (0..<64).map { UInt32($0) * 6 })
    let k9 = try execute(Corpus.spec64, inputs: [zeros(64)], grid: (1, 1, 1), spec: [(id: 0, bits: 9)])
    #expect(words(k9.got[0]) == (0..<64).map { UInt32($0) * 10 })
    let zero = try execute(
      Corpus.spec64, inputs: [[UInt8](repeating: 7, count: 256)], grid: (1, 1, 1), spec: [(id: 1, bits: 1)])
    #expect(words(zero.got[0]) == [UInt32](repeating: 0, count: 64))
  }

  @Test func calls() throws {
    func h(_ a: UInt32, _ b: UInt32) -> UInt32 { a &* b &+ 1 }
    let r = try execute(Corpus.calls, inputs: [zeros(64)], grid: (1, 1, 1))
    #expect(words(r.got[0]) == (0..<64).map { h(h(UInt32($0), 3), UInt32($0)) })
  }

  @Test func localArraysAndStructs() throws {
    func ref(_ i: UInt32) -> UInt32 {
      let arr: [UInt32] = [i, i + 1, i &* 2, 7]
      return arr[Int(i & 3)] &+ arr[Int((i + 1) & 3)] &+ i &+ UInt32(Float(i) * 0.5)
    }
    let r = try execute(Corpus.locals, inputs: [zeros(64)], grid: (1, 1, 1))
    #expect(words(r.got[0]) == (0..<64).map { ref(UInt32($0)) })
    #expect(r.shader.shader.stackBytes > 0)
  }
}
