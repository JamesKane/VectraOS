// SPDX-License-Identifier: BSD-3-Clause

import ShaderCompiler
import ShaderTestKit
import Testing

/// The error a parse or a lowering gives, or fails the test.
func refusal(_ text: String, lower: Bool = false) -> String {
  do {
    let m = try SPIRVModule.parse(words: try assemble(text))
    if lower { _ = try IRModule.lower(m) }
  } catch let e as CompileError {
    return e.message
  } catch {
    return "assembler: \(error)"
  }
  return ""
}

@Suite struct ReaderTests {
  @Test func theCorpusParses() throws {
    for (name, text) in [
      ("fill", Corpus.fill), ("saxpy", Corpus.saxpy), ("reduce", Corpus.reduce), ("loopsum", Corpus.loopsum),
      ("vec", Corpus.vec), ("atomics", Corpus.atomics), ("spec64", Corpus.spec64), ("calls", Corpus.calls),
      ("locals", Corpus.locals),
    ] {
      do {
        let m = try parseOK(text)
        #expect(m.entryPoints.count == 1, "\(name)")
        #expect(m.entryPoints[0].name == "main", "\(name)")
        #expect(m.entryPoints[0].model == 5, "\(name)")
      } catch {
        Issue.record("\(name): \(error)")
      }
    }
  }

  @Test func theModuleKeepsWhatLoweringNeeds() throws {
    let m = try parseOK(Corpus.saxpy)
    #expect(m.functions.count == 1)
    #expect(m.functions[0].blocks.count == 3)
    #expect(m.variables.count == 4)
    #expect(m.executionModes.count == 1 && m.executionModes[0].operands == [64, 1, 1])
    // %xv's binding is data on the module.
    let xv = m.variables.first { $0.storage == StorageClass.storageBuffer }!
    #expect(m.decoration(xv.id, Decor.descriptorSet) == [0])
    #expect(m.decoration(xv.id, Decor.binding) == [0])
    // Specialization constants carry their SpecId.
    let s = try parseOK(Corpus.spec64)
    let specs = s.constants.compactMap { $0 }.filter { $0.isSpec }
    #expect(specs.count == 3)
    #expect(specs.compactMap { $0.specId }.sorted() == [0, 1])
  }

  @Test func bytesAndWordsParseTheSame() throws {
    let w = try assemble(Corpus.fill)
    var b: [UInt8] = []
    for x in w { for k in 0..<4 { b.append(UInt8(truncatingIfNeeded: x >> UInt32(8 * k))) } }
    let a = try SPIRVModule.parse(bytes: b)
    #expect(a.functions.count == 1)
    #expect(a.bound == w[3])
  }

  @Test func theHeaderIsChecked() throws {
    var w = try assemble(Corpus.fill)
    #expect((try? SPIRVModule.parse(words: Array(w[0..<3]))) == nil)
    w[0] = 0x0302_2307
    #expect(refusalOf(w).contains("big-endian"))
    w[0] = 0x1234_5678
    #expect(refusalOf(w).contains("magic"))
    w[0] = 0x0723_0203
    w[1] = 0x0002_0000
    #expect(refusalOf(w).contains("version"))
    var t = try assemble(Corpus.fill)
    t.removeLast()  // OpFunctionEnd
    #expect(refusalOf(t).contains("ends inside function"))
    t = try assemble(Corpus.fill)
    t[t.count - 1] = 5 << 16 | 56  // OpFunctionEnd claiming five words
    #expect(refusalOf(t).contains("truncated"))
  }

  @Test func idsAreDefinedOnce() {
    let m = refusal(
      """
      OpCapability Shader
      OpMemoryModel Logical GLSL450
      %a = OpTypeVoid
      %a = OpTypeBool
      """)
    #expect(m.contains("OpTypeBool %1: id is defined twice"), "\(m)")
  }

  @Test func capabilitiesAreChecked() {
    #expect(refusal("OpCapability Geometry").contains("capability Geometry is not supported"))
    // A 64-bit integer without the capability.
    let m = refusal(
      """
      OpCapability Shader
      OpMemoryModel Logical GLSL450
      %l = OpTypeInt 64 0
      """)
    #expect(m.contains("OpTypeInt %1: 64-bit integers need capability Int64"), "\(m)")
    let h = refusal(
      """
      OpCapability Shader
      OpMemoryModel Logical GLSL450
      %h = OpTypeFloat 16
      """)
    #expect(h.contains("Float16"), "\(h)")
  }

  @Test func unsupportedFeaturesAreNamed() {
    let img = refusal(
      """
      OpCapability Shader
      OpMemoryModel Logical GLSL450
      %f = OpTypeFloat 32
      %i = OpTypeImage %f 2 0 0 0 1 0
      """)
    #expect(img.contains("OpTypeImage"), "\(img)")
    #expect(img.contains("not supported"), "\(img)")
    let mem = refusal(
      """
      OpCapability Shader
      OpMemoryModel 1 2
      """)
    #expect(mem.contains("addressing model 1"), "\(mem)")
    let ext = refusal(
      """
      OpCapability Shader
      %e = OpExtInstImport "OpenCL.std"
      """)
    #expect(ext.contains("OpenCL.std"), "\(ext)")
    let dec = refusal(
      """
      OpCapability Shader
      OpDecorate %x 9999
      %x = OpTypeVoid
      """)
    #expect(dec.contains("decoration #9999"), "\(dec)")
  }

  @Test func blocksAreChecked() {
    let head = """
      OpCapability Shader
      OpMemoryModel Logical GLSL450
      %void = OpTypeVoid
      %fn = OpTypeFunction %void
      %bool = OpTypeBool
      %t = OpConstantTrue %bool
      """
    // A block with no terminator.
    let a = refusal(head + "\n%main = OpFunction %void None %fn\n%l = OpLabel\n%x = OpUndef %bool\nOpFunctionEnd")
    #expect(a.contains("OpFunctionEnd") && a.contains("no terminator"), "\(a)")
    // A selection merge not followed by a conditional branch.
    let b = refusal(
      head + "\n%main = OpFunction %void None %fn\n%l = OpLabel\nOpSelectionMerge %m None\nOpBranch %m\n%m = OpLabel\nOpReturn\nOpFunctionEnd")
    #expect(b.contains("OpSelectionMerge") && b.contains("OpBranchConditional"), "\(b)")
    // A branch to something that is not a block of the function.
    let c = refusal(head + "\n%main = OpFunction %void None %fn\n%l = OpLabel\nOpBranch %nowhere\n%nowhere = OpTypeVoid\nOpFunctionEnd")
    #expect(!c.isEmpty, "\(c)")
    // A phi after another instruction.
    let d = refusal(
      head
        + "\n%main = OpFunction %void None %fn\n%l = OpLabel\n%u = OpUndef %bool\nOpBranch %m\n%m = OpLabel\n%x = OpUndef %bool\n%p = OpPhi %bool %u %l\nOpReturn\nOpFunctionEnd")
    #expect(d.contains("OpPhi after another instruction"), "\(d)")
  }

  @Test func unsupportedNamesAreSurveyed() throws {
    let w = try assemble(
      """
      OpCapability Shader
      OpCapability Geometry
      OpMemoryModel Logical GLSL450
      %f = OpTypeFloat 32
      %i = OpTypeImage %f 2 0 0 0 1 0
      %s = OpTypeSampler
      """)
    let list = SPIRVModule.unsupported(words: w)
    #expect(list == ["capability Geometry", "OpTypeImage", "OpTypeSampler"], "\(list)")
  }
}

func refusalOf(_ w: [UInt32]) -> String {
  do {
    _ = try SPIRVModule.parse(words: w)
  } catch {
    return error.message
  }
  return ""
}
