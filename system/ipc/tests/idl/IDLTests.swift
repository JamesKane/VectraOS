// SPDX-License-Identifier: BSD-3-Clause

import FoundationEssentials
import IDL
import IDLCTests
@testable import Echo
import IPC
import IPCModel
import Testing

// MARK: Generated files stay in step with idlc

/// The repository's root, from this file's path.
let root: String = {
  var parts = #filePath.split(separator: "/", omittingEmptySubsequences: false)
  parts.removeLast(5)  // system/ipc/tests/idl/IDLTests.swift
  return parts.joined(separator: "/")
}()

func read(_ path: String) throws -> String { try String(contentsOfFile: "\(root)/\(path)", encoding: .utf8) }

func echoInterface() throws -> Interface {
  let path = "system/ipc/tests/echo/Echo.swift"
  return try scan([(path, try read(path))])
}

func echoProtocol() throws -> ProtocolModel {
  try #require(try echoInterface().protocols.first?.protocol)
}

@Test func checkedInOutputsMatchIdlc() throws {
  let library = try #require(try echoInterface().libraries.first)
  let echo = try echoProtocol()
  let source = "system/ipc/tests/echo/Echo.swift"
  #expect(cHeader(library, source: source) == (try read("system/ipc/tests/c/generated/test_ipc.h")),
          "regenerate: .build/debug/idlc --c-out system/ipc/tests/c/generated \(source)")
  #expect(markdown(echo, library, source: source) == (try read("system/ipc/tests/docs/Echo.md")))
  #expect(Baseline(echo, library).text == (try read("system/ipc/tests/baselines/todhchai.test.Echo.api")))
  #expect(library.errors.first?.cases.first?.code == 1)
  let interface = try echoInterface()
  let loud = try #require(library.protocols.first { $0.name == "Loud" })
  let composed = try interface.composedMethods(loud, in: library)
  #expect(markdown(loud, library, source: source, composed: composed) == (try read("system/ipc/tests/docs/Loud.md")))
  #expect(Baseline(loud, library, composed: composed).text == (try read("system/ipc/tests/baselines/todhchai.test.Loud.api")))
}

// MARK: C and Swift agree on the bytes

@Test func cEncodesWhatSwiftEncodes() throws {
  var c = [UInt8](repeating: 0, count: 256)
  let n = idl_c_encode_say(&c, UInt32(c.count))
  let say = try #require(try echoProtocol().methods.first { $0.name == "say" })
  let swift = try IPCCodec.encode(
    MessageHeader(txid: 1, kind: .request, ordinal: say.ordinal), inlineSize: say.request.size, Never.self
  ) { (e: inout Encoder) throws(WireError) in
    try e.storeString("hi", at: 0)
    try e.store(UInt32(3), at: 16)
  }
  #expect(Array(c[..<Int(n)]) == swift.bytes)
}

@Test func cEncodesStructsAsSwiftDoes() throws {
  var c = [UInt8](repeating: 0, count: 1024)
  let n = idl_c_encode_reflect(&c, UInt32(c.count))
  let (library, echo) = try #require(try echoInterface().protocols.first)
  _ = library
  let reflect = try #require(echo.methods.first { $0.name == "reflect" })
  // The same Shaped, encoded by the generated Swift coder.
  let sample = TestIPC.Shaped(
    shape: .triangle, at: TestIPC.Point(x: -3, y: 4), label: "tri", tags: ["a", "", "ccc"],
    path: [TestIPC.Point(x: 1, y: 2), TestIPC.Point(x: Int32.min, y: Int32.max)], weight: 513, data: [0, 255, 7],
    flag: true)
  let swift = try IPCCodec.encode(
    MessageHeader(txid: 1, kind: .request, ordinal: reflect.ordinal), inlineSize: reflect.request.size, Never.self
  ) { (e: inout Encoder) throws(WireError) in try TestIPC._encode_Shaped(sample, &e, at: 0) }
  #expect(n > 0 && Array(c[..<Int(n)]) == swift.bytes)
}

/// Swift's and C's decoders accept exactly the same messages: Shaped
/// replies with bytes changed or cut, seeded so a failure repeats.
@Test func swiftAndCAgreeOnHostileReplies() throws {
  let (_, echo) = try #require(try echoInterface().protocols.first)
  let reflect = try #require(echo.methods.first { $0.name == "reflect" })
  let sample = TestIPC.Shaped(
    shape: .square, at: TestIPC.Point(x: 1, y: -1), label: "l", tags: ["xy", "z"],
    path: [TestIPC.Point(x: 5, y: 6)], weight: 7, data: [1, 2, 3, 4, 5, 6, 7, 8, 9], flag: false)
  let reply = try IPCCodec.encode(
    MessageHeader(txid: 1, kind: .reply, ordinal: reflect.ordinal), inlineSize: reflect.reply.size, Never.self
  ) { (e: inout Encoder) throws(WireError) in try TestIPC._encode_Shaped(sample, &e, at: 0) }

  func swiftAccepts(_ bytes: [UInt8]) -> Bool {
    (try? IPCCodec.decode(IPCMessage(bytes: bytes, handles: []), inlineSize: reflect.reply.size, Never.self) {
      (d: inout Decoder) throws(WireError) -> TestIPC.Shaped in try TestIPC._decode_Shaped(&d, at: 0)
    }) != nil
  }
  #expect(swiftAccepts(reply.bytes) && idl_c_decode_reflect_reply(reply.bytes, UInt32(reply.bytes.count)) == 0)

  var state: UInt64 = 0x9E37_79B9_7F4A_7C15
  func next() -> Int {
    state ^= state << 13
    state ^= state >> 7
    state ^= state << 17
    return Int(truncatingIfNeeded: state >> 1)
  }
  var accepted = 0
  for round in 0..<20_000 {
    var bytes = reply.bytes
    for _ in 0...(next() % 3) {
      let i = 16 + next() % (bytes.count - 16)
      bytes[i] = [0, 1, 0xff, 0x80, UInt8(truncatingIfNeeded: next())][next() % 5]
    }
    if next() % 8 == 0 { bytes.removeLast(8 * (1 + next() % 3)) }
    let swift = swiftAccepts(bytes)
    let c = idl_c_decode_reflect_reply(bytes, UInt32(bytes.count)) == 0
    #expect(swift == c, "round \(round): Swift \(swift ? "accepts" : "rejects"), C \(c ? "accepts" : "rejects") \(bytes)")
    if swift != c { break }
    if swift { accepted += 1 }
  }
  // Some mutations are harmless (a label's byte, a coordinate): both see them.
  #expect(accepted > 100)
}

@Test func cDecodesWhatSwiftEncodes() throws {
  let say = try #require(try echoProtocol().methods.first { $0.name == "say" })
  let reply = try IPCCodec.encode(
    MessageHeader(txid: 1, kind: .reply, ordinal: say.ordinal), inlineSize: say.reply.size, Never.self
  ) { (e: inout Encoder) throws(WireError) in try e.storeString("hihihi", at: 0) }
  var text = [CChar](repeating: 0, count: 64)
  #expect(idl_c_decode_say_reply(reply.bytes, UInt32(reply.bytes.count), &text, 64) == 0)
  #expect(String(decoding: text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) == "hihihi")

  // Hostile replies: padding, an overlong string count, invalid UTF-8.
  for (offset, value) in [(16 + 16 + 6, UInt8(1)), (16, 0x40), (16 + 16, 0xff)] {
    var bad = reply.bytes
    bad[offset] = value
    #expect(idl_c_decode_say_reply(bad, UInt32(bad.count), &text, 64) != 0, "byte \(offset) = \(value)")
  }
}

@Test func cUTF8ValidationMatchesSwift() {
  let cases: [[UInt8]] = [
    [], [0x41], [0xe2, 0x82, 0xac], [0xf0, 0x9f, 0x98, 0x80], [0xc2, 0x80], [0xf4, 0x8f, 0xbf, 0xbf],
    [0xc0, 0x80], [0xc1, 0xbf], [0xe0, 0x80, 0x80], [0xed, 0xa0, 0x80], [0xf4, 0x90, 0x80, 0x80],
    [0xf5, 0x80, 0x80, 0x80], [0xe2, 0x82], [0x80], [0xff], [0xef, 0xbf, 0xbf], [0xee, 0x80, 0x80],
  ]
  for bytes in cases {
    let swift = String(validating: bytes, as: UTF8.self) != nil
    #expect((idl_c_utf8_valid(bytes, UInt32(bytes.count)) != 0) == swift, "\(bytes)")
  }
}

// MARK: Evolution

func baseline(_ body: String, version: Int, types: String = "") throws -> Baseline {
  let source = "@IPCLibrary(id: \"t\", version: \(version))\nenum L {\n\(types)\nprotocol P {\n\(body)\n}\n}"
  let (l, p) = try #require(try scan([("P.swift", source)]).protocols.first)
  return Baseline(p, l)
}

@Test func compatibleChangesPass() throws {
  let old = try baseline("func a(_ x: UInt32) -> String", version: 1)
  let added = try baseline("func a(_ x: UInt32) -> String\n@since(2) func b()", version: 2)
  #expect(compatibility(old: old, new: added).isEmpty)
  let renamedParameter = try baseline("func a(_ y: UInt32) -> String", version: 1)
  #expect(compatibility(old: old, new: renamedParameter).isEmpty)
  #expect(Baseline(text: old.text) == old)
}

@Test func breakingChangesFail() throws {
  let old = try baseline("func a(_ x: UInt32) -> String\nfunc c()", version: 1)
  let cases: [(String, Int, String)] = [
    ("func a(_ x: UInt64) -> String\nfunc c()", 1, "'a' changed"),
    ("func a(_ x: UInt32)\nfunc c()", 1, "'a' changed"),
    ("@oneway func a(_ x: UInt32)\nfunc c()", 1, "'a' changed"),
    ("func a(_ x: UInt32) -> String", 1, "'c' was removed"),
    ("func a(_ x: UInt32) -> String\nfunc c()\nfunc b()", 2, "'b' is new, so it needs @since(2)"),
    ("func a(_ x: UInt32) -> String\nfunc c()\n@since(1) func b()", 1, "the version must go up"),
  ]
  for (body, version, expected) in cases {
    let problems = compatibility(old: old, new: try baseline(body, version: version))
    #expect(problems.contains { $0.contains(expected) }, "\(body): \(problems)")
  }
  let older = try baseline("func a(_ x: UInt32) -> String\nfunc c()", version: 1)
  var lowered = older
  lowered.version = 0
  #expect(compatibility(old: older, new: lowered).contains { $0.contains("went down") })
}

@Test func typesKeepTheirShape() throws {
  let types = "struct S { var a: UInt32\nvar b: [String]? }\nenum K: UInt8 { case x = 1, y }"
  let old = try baseline("func f(_ s: S) -> K", version: 1, types: types)
  #expect(old.text.contains("struct S (UInt32,[String]?)") && old.text.contains("enum K UInt8 (1,2)"))
  #expect(Baseline(text: old.text) == old)
  let renamed = try baseline("func f(_ s: S) -> K", version: 1, types: types.replacing("var a", with: "var z"))
  #expect(compatibility(old: old, new: renamed).isEmpty)
  for changed in [
    types.replacing("[String]?", with: "[String]"),
    types.replacing("case x = 1, y", with: "case x = 1, y, w"),
    types.replacing("UInt8", with: "UInt16"),
  ] {
    let problems = compatibility(old: old, new: try baseline("func f(_ s: S) -> K", version: 1, types: changed))
    #expect(problems.contains { $0.contains("changed") }, "\(changed): \(problems)")
  }
}

// MARK: Composition

/// Libraries in files of their own: `L` (id "t") and `M` (id "m").
func composing(_ l: String, _ m: String) throws(IDLError) -> Interface {
  try scan([("L.swift", "@IPCLibrary(id: \"t\", version: 1)\nenum L {\n\(l)\n}")],
           references: [("M.swift", "@IPCLibrary(id: \"m\", version: 1)\nenum M {\n\(m)\n}")])
}

func composedNames(_ i: Interface, _ name: String) throws -> [String] {
  let l = try #require(i.libraries.first)
  let p = try #require(l.protocols.first { $0.name == name })
  return try i.composedMethods(p, in: l).map { "\($0.origin.id).\($0.method.name)" }
}

@Test func compositionFlattensAcrossLibrariesOnce() throws {
  let i = try composing(
    "protocol A: M.Base { func a() }\nprotocol B: A, M.Base { func b() }",
    "protocol Base { func base()\n@event func happened() }")
  #expect(try composedNames(i, "A") == ["m.Base.base", "m.Base.happened"])
  // Base comes once, through A and directly.
  #expect(try composedNames(i, "B") == ["t.A.a", "m.Base.base", "m.Base.happened"])
  // Composed methods keep the ordinals of the protocol that declares them.
  let base = try #require(i.references.first?.protocols.first)
  let l = try #require(i.libraries.first)
  let a = try #require(l.protocols.first)
  #expect(try i.composedMethods(a, in: l).map(\.method.ordinal) == base.methods.map(\.ordinal))
}

@Test func compositionErrorsSayWhatIsMissingOrClashes() throws {
  func error(_ l: String, _ m: String = "protocol Base { func base() }") -> String {
    do {
      let i = try composing(l, m)
      let lib = try #require(i.libraries.first)
      for p in lib.protocols { _ = try i.composedMethods(p, in: lib) }
      return "none"
    } catch {
      return "\(error)"
    }
  }
  #expect(error("protocol A: N.Base { func a() }")
    == "t.A composes N.Base, which no file given declares (pass its file with --with)")
  #expect(error("protocol A: M.Base { func base() }") == "t.A: 'base' of m.Base clashes with 'base' of t.A")
  #expect(error("protocol A: Nope { func a() }").contains("composes 'Nope', which the library doesn't declare"))
  #expect(error("protocol A: B { func a() }\nprotocol B: A { func b() }").contains("composes itself"))
}

@Test func baselinesRecordCompositionAndItsBreaks() throws {
  func baseline(_ l: String, version: Int = 1) throws -> Baseline {
    let i = try scan([("L.swift", "@IPCLibrary(id: \"t\", version: \(version))\nenum L {\n\(l)\n}")],
                     references: [("M.swift", "@IPCLibrary(id: \"m\", version: 2)\nenum M {\nprotocol Base { func base()\n@since(2) func later() }\n}")])
    let lib = try #require(i.libraries.first)
    let p = try #require(lib.protocols.first)
    return Baseline(p, lib, composed: try i.composedMethods(p, in: lib))
  }
  let old = try baseline("protocol A: M.Base { func a() }")
  #expect(old.text.contains("compose m.Base\n"))
  #expect(old.text.contains("method later call since 2 params () result - throws - from m.Base\n"))
  // The baseline reads back as written.
  #expect(Baseline(text: old.text) == old)
  // Methods that come with a composed protocol follow its versions, not A's.
  #expect(compatibility(old: try #require(Baseline(text: old.text.replacing("method later call since 2 params () result - throws - from m.Base\n", with: ""))), new: old).isEmpty)
  // Composing no longer breaks clients that used its methods.
  let alone = try baseline("protocol A { func a() }")
  #expect(compatibility(old: old, new: alone).contains("it no longer composes m.Base"))
}
