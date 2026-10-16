// SPDX-License-Identifier: BSD-3-Clause

// A0b: loading AML into the namespace, from AML the tests' encoder builds.

@testable import TDACPI
import Testing

func load(_ amls: [UInt8]...) throws -> Namespace {
  var ns = Namespace()
  for aml in amls { try ns.load(try Table(AML.dsdt(aml))) }
  return ns
}

func text(_ b: [UInt8]) -> String { String(decoding: b, as: UTF8.self) }

@Test func definitionsLandAtTheirPaths() throws {
  let ns = try load(
    AML.scope("\\_SB", AML.device("PCI0", AML.nameObject("_HID", AML.integer(0x080A_D041))
      + AML.device("LPCB", AML.method("_STA", AML.returning(AML.integer(0x0F))))
      + AML.method("SET", args: 2, serialized: true, syncLevel: 3, [0xA3])))
      + AML.nameObject("\\_SB.PCI0.LPCB.ADDR", AML.integer(0x1234))
  )
  let lpcb = try #require(ns.lookup("\\_SB.PCI0.LPCB"))
  #expect(ns.nodes[lpcb].object == .device)
  #expect(text(ns.path(lpcb)) == "\\_SB_.PCI0.LPCB")
  let hid = try #require(ns.lookup("\\_SB.PCI0._HID"))
  #expect(ns.nodes[hid].object == .value(.integer(0x080A_D041)))
  guard case .method(2, true, 3, let body) = ns.nodes[try #require(ns.lookup("\\_SB.PCI0.SET"))].object else {
    Issue.record("SET isn't a method of two serialized arguments at sync level 3")
    return
  }
  #expect(body.end - body.start == 1)
  #expect(ns.nodes[try #require(ns.lookup("\\_SB.PCI0.LPCB.ADDR"))].object == .value(.integer(0x1234)))
  #expect(ns.lookup("\\_SB.PCI0.NONE") == nil && ns.problems.isEmpty)
}

@Test func aSingleSegmentSearchesUpwardAndAPathDoesNot() throws {
  let ns = try load(
    AML.nameObject("TOP", AML.integer(1))
      + AML.scope("\\_SB", AML.device("DEV", AML.nameObject("IN", AML.integer(2))))
  )
  let dev = try #require(ns.lookup("\\_SB.DEV"))
  var top = NamePath()
  top.segments = [NameSeg.make("TOP")]
  #expect(ns.resolve(top, from: dev) == ns.lookup("\\TOP"))  // found two scopes up
  var dotted = NamePath()
  dotted.segments = [NameSeg.make("DEV"), NameSeg.make("IN")]
  #expect(ns.resolve(dotted, from: ns.lookup("\\_SB")!) == ns.lookup("\\_SB.DEV.IN"))
  #expect(ns.resolve(dotted, from: dev) == nil)  // a path doesn't search
  var up = NamePath()
  up.parents = 1
  up.segments = [NameSeg.make("DEV")]
  #expect(ns.resolve(up, from: ns.lookup("\\_SB.DEV.IN")!) == nil)  // ^DEV from DEV.IN is \_SB.DEV.DEV
  #expect(ns.resolve(up, from: dev) == dev)
}

@Test func codeOutsideMethodsIsKeptWithItsExtent() throws {
  // A call to a two-argument method defined in another table (declared by
  // External), then a store: the call's extent takes both arguments.
  let call = AML.name("\\_SB.FN") + AML.integer(5) + AML.integer(6)
  let store = [0x70] + AML.integer(7) + AML.name("\\_SB.X")
  let first = [0x15] + AML.name("\\_SB.FN") + [8, 2] + call + store
  let ns = try load(first, AML.scope("\\_SB", AML.method("FN", args: 2, [0xA3]) + AML.nameObject("X", AML.integer(0))))
  #expect(ns.loadCode.count == 2)
  let callCode = ns.loadCode[0].code
  #expect(callCode.end - callCode.start == call.count)
  #expect(ns.loadCode[1].code.end - ns.loadCode[1].code.start == store.count)
  // The External was a placeholder; the second table's method replaced it.
  guard case .method(2, false, 0, _) = ns.nodes[try #require(ns.lookup("\\_SB.FN"))].object else {
    Issue.record("the External wasn't replaced")
    return
  }
  #expect(ns.problems.isEmpty)
}

@Test func fieldsTakeTheirBitsInOrder() throws {
  // OperationRegion (GNVS, SystemMemory, 0x1000, 0x100); Field (GNVS,
  // ByteAcc, NoLock, Preserve) { Offset (2), A, 8, , 4, B, 4, AccessAs (DWordAcc), C, 32 }
  let region = [0x5B, 0x80] + AML.name("GNVS") + [0x00] + AML.integer(0x1000) + AML.integer(0x100)
  var list: [UInt8] = [0x00, 0x10]  // ReservedField, 16 bits
  list += Array("A___".utf8) + [0x08]
  list += [0x00, 0x04]
  list += Array("B___".utf8) + [0x04]
  list += [0x01, 0x03, 0x00]  // AccessField: DWordAcc
  list += Array("C___".utf8) + [0x20]
  let field = [0x5B, 0x81] + AML.package(AML.name("GNVS") + [0x01] + list)
  let ns = try load(region + field)
  func bits(_ name: StaticString) throws -> (UInt32, UInt32, UInt8) {
    guard case .field(let f) = ns.nodes[try #require(ns.lookup(name))].object else { throw ACPIError.missingTable }
    return (f.bitOffset, f.bitLength, f.flags & 0x0F)
  }
  #expect(try bits("\\A") == (16, 8, 1))
  #expect(try bits("\\B") == (28, 4, 1))
  #expect(try bits("\\C") == (32, 32, 3))
  guard case .region(0, .integer(0x1000), .integer(0x100)) = ns.nodes[try #require(ns.lookup("\\GNVS"))].object else {
    Issue.record("GNVS isn't a SystemMemory region at 0x1000")
    return
  }
}

@Test func aliasesResolveAndASecondDefinitionIsNoted() throws {
  let ns = try load(
    AML.nameObject("ONE", AML.integer(1)) + [0x06] + AML.name("ONE") + AML.name("UNO")
      + AML.nameObject("ONE", AML.integer(9))
  )
  #expect(ns.lookup("\\UNO") == ns.lookup("\\ONE"))
  #expect(ns.nodes[ns.lookup("\\ONE")!].object == .value(.integer(1)))  // the first stays
  #expect(ns.problems.map { $0.kind } == [.alreadyDefined])
}

@Test func packagesKeepTheirElementsAndNames() throws {
  let ns = try load(AML.nameObject("PKG", AML.packageOf([AML.integer(1), AML.string("ab"), AML.name("\\_SB"),
                                                         AML.packageOf([AML.integer(2)])])))
  guard case .value(.package(let e)) = ns.nodes[try #require(ns.lookup("\\PKG"))].object else {
    Issue.record("PKG isn't a package")
    return
  }
  #expect(e.count == 4 && e[0] == .integer(1) && e[1] == .string(Array("ab".utf8)) && e[3] == .package([.integer(2)]))
  guard case .name(let p, _) = e[2] else {
    Issue.record("the third element isn't a name")
    return
  }
  #expect(p.fromRoot && p.segments == [NameSeg.make("_SB")])
}

@Test func malformedAMLThrowsAndNeverTraps() throws {
  let good = AML.scope("\\_SB", AML.device("DEV", AML.nameObject("X", AML.integer(0x1234_5678))))
  // Every truncation of a well-formed table (empty AML is fine).
  for cut in 1..<good.count {
    var ns = Namespace()
    let t = try Table(AML.dsdt(Array(good[..<cut])))
    #expect(throws: (any Error).self) { try ns.load(t) }  // never a trap
  }
  var ns = Namespace()
  #expect(throws: ACPIError.unknownOpcode(0x5BFE, at: 36)) { try ns.load(try Table(AML.dsdt([0x5B, 0xFE]))) }
  // Deep nesting is refused, not recursed into without end.
  var deep: [UInt8] = AML.integer(1)
  for _ in 0..<300 { deep = [0x92] + deep }  // LNot (LNot (... One))
  #expect(throws: ACPIError.tooDeep) { try ns.load(try Table(AML.dsdt([0xA4] + deep))) }
}

/// A corpus machine's tables to load together: its DSDT and SSDTs, and
/// those loaded at run time; QEMU's variants (DSDT.x) each alone.
func corpusLoads(_ machine: String) -> [[String]] {
  let files = Corpus.tableFiles(machine)
  let base = files.filter { ($0 == "DSDT" || $0.hasPrefix("SSDT") || $0.hasPrefix("dynamic-SSDT")) && !$0.contains(".") }
  let variants = files.filter { $0.hasPrefix("DSDT.") }.map { [$0] }
  return (base.isEmpty ? [] : [base]) + variants
}

@Test(.enabled(if: Corpus.isPresent, "no corpus: vx acpi import, vx acpi fetch-qemu"))
func everyCorpusTableLoadsWithNoUnknownOpcode() throws {
  var loaded = 0, nodes = 0
  for machine in Corpus.machines {
    for set in corpusLoads(machine) {
      var ns = Namespace()
      for file in set {
        let table = try Table(try #require(Corpus.bytes(machine, file)))
        do {
          try ns.load(table)
        } catch {
          Issue.record("\(machine)/\(file): \(error)")
        }
        loaded += 1
      }
      nodes += ns.nodes.count
      #expect(ns.problems.isEmpty, "\(machine) \(set): \(ns.problems)")
    }
  }
  // QEMU's tables alone (vx acpi fetch-qemu) load 59 and make 23,081 nodes.
  #expect(loaded >= 59 && nodes > 20000)
}

@Test(.enabled(if: Corpus.isPresent, "no corpus: vx acpi import"))
func everyDeviceLinuxSeesIsDefinedSomewhereInTheTables() throws {
  for machine in Corpus.machines {
    guard let oracle = Corpus.bytes(machine, "linux-devices.tsv") else { continue }
    var ns = Namespace()
    for file in corpusLoads(machine).first ?? [] {
      try ns.load(try Table(try #require(Corpus.bytes(machine, file))))
    }
    // Until load-time code runs (A0c), what it defines is found by taking
    // every load-time condition as true: this checks the parser walks it.
    try ns.loadAssumingConditions()
    var missing: [String] = []
    var checked = 0
    for line in String(decoding: oracle, as: UTF8.self).split(separator: "\n") where !line.hasPrefix("#") {
      let path = String(line.split(separator: "\t", omittingEmptySubsequences: false)[0])
      checked += 1
      if ns.lookup(Array(path.utf8)) == nil { missing.append(path) }
    }
    #expect(missing.isEmpty, "\(machine): \(missing.count) of \(checked) of Linux's devices aren't in our namespace: \(missing.prefix(10))")
  }
}
