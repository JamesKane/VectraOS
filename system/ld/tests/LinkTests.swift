// SPDX-License-Identifier: BSD-3-Clause

// A program and its libraries linked as one set (D124): a PIE program
// that needs liba and libb, liba that needs libb, each with TLS reached
// by initial-exec, built by ld.lld for each of croi's machines. They are
// loaded into buffers that stand for another process's pages (each
// object's run address differs from where its bytes are), as a spawner
// links a program it starts; then the load order, the TLS layout, the
// scope, and a copy relocation into a fixed-address program are checked.
// Skips without clang and ld.lld.

import Elf
import Foundation
import Ld
import Testing

let libbSource = """
  __thread int b_tls = 7;
  __thread int b_more[4];
  static __thread int b_hidden = 3;
  int b_data[3] = {1, 2, 3};
  int b_value = 42;
  int b_fn(int x) { return x + 1; }
  int *b_tls_address(void) { return &b_tls; }
  int *b_hidden_address(void) { return &b_hidden; }
  int *b_value_address(void) { return &b_value; }
  int *b_data_address(void) { return b_data; }
  """

let libaSource = """
  extern __thread int b_tls;
  extern int b_data[3];
  extern int b_fn(int);
  extern int b_value;
  __thread long a_tls __attribute__((aligned(64))) = 5;
  int a_value = 1;
  int b_value = 99;
  void *a_table[] = { b_data, (void *)b_fn, &b_value };
  int *a_b_tls(void) { return &b_tls; }
  long *a_own_tls(void) { return &a_tls; }
  """

let programSource = """
  extern int a_value;
  extern __thread long a_tls;
  extern int b_data[3];
  __thread int e_tls = 11;
  void *e_table[] = { &a_value, b_data };
  long *e_a_tls(void) { return &a_tls; }
  int *e_own(void) { return &e_tls; }
  void _start(void) {}
  """

/// A fixed-address program that reads libb's data directly: ld.lld gives
/// it a copy.
let copySource = """
  extern int b_data[3];
  int e_first(void) { return b_data[0] + b_data[2]; }
  void _start(void) {}
  """

/// Objects built for a machine, each loaded into a buffer of its own and
/// given a run address elsewhere.
final class Built {
  struct Object {
    let name: String
    let elf: ElfImage
    let memory: UnsafeMutableRawPointer
    let view: UInt, bias: UInt
  }
  let machine: Machine
  var objects: [String: Object] = [:]
  let dir: URL

  /// `bFirst`: the program names libb before liba, so libb loads first.
  init(_ machine: Machine, gd: Bool = false, bFirst: Bool = false) throws {
    self.machine = machine
    dir = FileManager.default.temporaryDirectory.appendingPathComponent("link-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let lib = ["-fPIC"] + (gd ? [] : ["-ftls-model=initial-exec"])
    try build("libb.so", libbSource, cflags: lib, ld: ["-shared", "-soname", "libb.so"])
    try build("liba.so", libaSource, cflags: lib, ld: ["-shared", "-soname", "liba.so", path("libb.so")])
    try build("program", programSource, cflags: ["-fPIE"],
              ld: ["-pie", "--export-dynamic", "--allow-shlib-undefined"]
                + (bFirst ? [path("libb.so"), path("liba.so")] : [path("liba.so"), path("libb.so")]))
    if !gd { try build("fixed", copySource, cflags: ["-fno-pic"], ld: ["-no-pie", path("libb.so")]) }
  }

  deinit {
    for o in objects.values { o.memory.deallocate() }
    try? FileManager.default.removeItem(at: dir)
  }

  func path(_ name: String) -> String { dir.appendingPathComponent(name).path }

  func build(_ name: String, _ source: String, cflags: [String], ld: [String]) throws {
    let c = path(name + ".c"), o = path(name + ".o")
    try source.write(toFile: c, atomically: true, encoding: .utf8)
    try Tools.run(Tools.clang!, ["--target=\(machine.target)", "-O1", "-ffreestanding", "-c", c, "-o", o]
                  + machine.flags + cflags)
    try Tools.run(Tools.lld!, ["--hash-style=gnu", "-zseparate-loadable-segments", "-zmax-page-size=4096",
                               o, "-o", path(name)] + ld)
  }

  /// `name` loaded into a buffer, to run at a base of its own (a PIE's),
  /// or where it was linked.
  func load(_ name: String, runBase: UInt) throws -> Object {
    if let o = objects[name] { return o }
    let bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path(name))))
    let elf = try ElfImage(parsing: bytes.span.bytes, machine: machine.number)
    let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(elf.size), alignment: 4096)
    memory.initializeMemory(as: UInt8.self, repeating: 0, count: Int(elf.size))
    for i in 0..<elf.segmentCount {
      let s = elf.segments[i]
      bytes.withUnsafeBytes { b in
        (memory + Int(s.vaddr - elf.base)).copyMemory(from: b.baseAddress! + Int(s.offset), byteCount: Int(s.filesz))
      }
    }
    let view = UInt(bitPattern: memory) &- UInt(elf.base)
    let bias = elf.base == 0 ? runBase : 0
    let o = Object(name: name, elf: elf, memory: memory, view: view, bias: bias)
    objects[name] = o
    return o
  }

  /// The set: `program`, then what it needs, breadth first.
  func linkSet(_ program: String) throws -> LinkSet {
    var set = LinkSet(machine: machine.number)
    var next: String? = program
    var base: UInt = 0x7f00_0000_0000
    while let name = next {
      let o = try load(name, runBase: base)
      base += 0x1000_0000
      let object = try DynamicObject(bias: o.bias, view: o.view, dynamicAt: UInt(o.elf.dynamic!), machine: machine.number)
      let tls = o.elf.tlsSegment.map {
        LinkSet.TLS(image: o.bias &+ UInt($0.vaddr), fileSize: Int($0.fileSize), size: Int($0.size), align: Int($0.align))
      }
      set.add(name, object, tls: tls)
      next = set.nextNeeded()
    }
    set.layOutTLS()
    return set
  }

  /// The word at run address `address` of `object`, read through its buffer.
  func word(_ object: String, _ address: UInt) -> UInt {
    let o = objects[object]!
    return UnsafeRawPointer(bitPattern: address &- o.bias &+ o.view)!.load(as: UInt.self)
  }
}

extension LinkSet {
  func member(_ name: String) -> Member { members.first { $0.name == name }! }

  /// A symbol's run address in member `name`.
  func address(_ name: String, in member: String) -> UInt? {
    self.member(member).object.lookup(Array(name.utf8))?.address
  }

}

extension Built {
  /// Every relocation of `name` in `set`: where (its run address), type,
  /// symbol name and addend.
  func relocations(_ set: LinkSet, _ name: String) -> [(at: UInt, type: UInt32, symbol: String, addend: UInt64)] {
    let o = set.member(name).object
    var out: [(UInt, UInt32, String, UInt64)] = []
    var tags: [UInt: UInt] = [:]
    var at = o.view &+ UInt(objects[name]!.elf.dynamic!)
    while true {
      let tag = UnsafeRawPointer(bitPattern: at)!.load(as: UInt.self)
      if tag == 0 { break }
      tags[tag] = UnsafeRawPointer(bitPattern: at + 8)!.load(as: UInt.self)
      at += 16
    }
    for (table, size) in [(7, 8), (23, 2)] as [(UInt, UInt)] {
      guard let t = tags[table], let n = tags[size] else { continue }
      var r = o.view &+ t
      while r < o.view &+ t + n {
        let p = UnsafeRawPointer(bitPattern: r)!
        let info = p.load(fromByteOffset: 8, as: UInt64.self)
        let s = o.symbol(Int(info >> 32))
        out.append((o.bias &+ UInt(p.load(as: UInt64.self)), UInt32(truncatingIfNeeded: info),
                    info >> 32 == 0 ? "" : o.name(of: s), p.load(fromByteOffset: 16, as: UInt64.self)))
        r += 24
      }
    }
    return out
  }
}

/// The machine's TLS offset relocation (TPOFF64, TLS_TPREL64).
func threadOffsetType(_ m: Machine) -> UInt32 {
  switch m.number {
  case ElfImage.Machine.amd64: 18
  case ElfImage.Machine.arm64: 1030
  default: 11
  }
}

func linked(_ machine: Machine, gd: Bool = false) throws -> (Built, LinkSet) {
  let b = try Built(machine, gd: gd)
  return (b, try b.linkSet("program"))
}

@Test(.enabled(if: Tools.present), arguments: machines)
func theSetIsLoadedBreadthFirstEachOnce(machine: Machine) throws {
  let (_, set) = try linked(machine)
  #expect(set.members.map(\.name) == ["program", "liba.so", "libb.so"])
  #expect(set.nextNeeded() == nil)
}

@Test(.enabled(if: Tools.present), arguments: machines)
func eachLibraryIsInitializedAfterThoseItNeeds(machine: Machine) throws {
  let (_, set) = try linked(machine)
  #expect(set.initOrder().map { set.members[$0].name } == ["libb.so", "liba.so", "program"])
  // libb named first: loaded first, but liba needs it, so it still comes first.
  let b = try Built(machine, bFirst: true)
  let first = try b.linkSet("program")
  #expect(first.members.map(\.name) == ["program", "libb.so", "liba.so"])
  #expect(first.initOrder().map { first.members[$0].name } == ["libb.so", "liba.so", "program"])
}

@Test(.enabled(if: Tools.present), arguments: machines)
func theTLSBlocksAreLaidOutAsThePsABISays(machine: Machine) throws {
  let (_, set) = try linked(machine)
  let blocks = set.members.compactMap { m in m.tls.map { (m.threadOffset, $0) } }
  #expect(blocks.count == 3)
  #expect(set.threadArea.align == 64)
  // The program's where the floor puts it today, and ld.lld's local-exec
  // offsets assume.
  let (first, t) = blocks[0]
  if machine.number == ElfImage.Machine.amd64 {
    #expect(first == -((t.size + t.align - 1) & ~(t.align - 1)))
  } else {
    let gap = machine.number == ElfImage.Machine.arm64 ? 16 : 0
    #expect(first == gap + Int((t.image &- UInt(gap)) & UInt(t.align - 1)))
  }
  // Each congruent to its image (the thread pointer at the area's
  // alignment), none overlapping, all in the area.
  for (offset, t) in blocks {
    #expect((UInt(bitPattern: offset) &- t.image) & UInt(t.align - 1) == 0)
    #expect(offset >= -set.threadArea.below && offset + t.size <= max(set.threadArea.above, 0))
  }
  let sorted = blocks.sorted { $0.0 < $1.0 }
  for (a, b) in zip(sorted, sorted.dropFirst()) { #expect(a.0 + a.1.size <= b.0) }
}

@Test(.enabled(if: Tools.present), arguments: machines)
func everyRelocationBindsToTheFirstDefinition(machine: Machine) throws {
  let (b, set) = try linked(machine)
  try set.bind()
  // Run addresses, written through the views.
  let aTable = try #require(set.address("a_table", in: "liba.so"))
  #expect(b.word("liba.so", aTable) == set.address("b_data", in: "libb.so"))
  #expect(b.word("liba.so", aTable + 8) == set.address("b_fn", in: "libb.so"))
  // liba's b_value is found first, for libb's own reference too.
  let interposed = try #require(set.address("b_value", in: "liba.so"))
  #expect(b.word("liba.so", aTable + 16) == interposed)
  let libbGot = b.relocations(set, "libb.so").filter { $0.symbol == "b_value" }
  #expect(!libbGot.isEmpty)
  for r in libbGot { #expect(b.word("libb.so", r.at) == interposed) }
  let eTable = try #require(set.address("e_table", in: "program"))
  #expect(b.word("program", eTable) == set.address("a_value", in: "liba.so"))
  #expect(b.word("program", eTable + 8) == set.address("b_data", in: "libb.so"))
  // Every address lies where its object runs, not in the buffers.
  #expect(b.objects["liba.so"]!.bias != b.objects["liba.so"]!.view)
}

@Test(.enabled(if: Tools.present), arguments: machines)
func initialExecOffsetsPointAtEachBlock(machine: Machine) throws {
  let (b, set) = try linked(machine)
  try set.bind()
  let type = threadOffsetType(machine)
  func tlsValue(_ name: String, in member: String) -> Int {
    Int(set.member(member).object.lookup(Array(name.utf8))!.symbol.value)
  }
  let a = set.member("liba.so").threadOffset, bb = set.member("libb.so").threadOffset
  var seen: Set<String> = []
  for (name, member) in [("liba.so", "liba.so"), ("libb.so", "libb.so"), ("program", "program")] {
    for r in b.relocations(set, name) where r.type == type {
      let slot = Int(bitPattern: b.word(member, r.at))
      switch r.symbol {
      case "b_tls": #expect(slot == bb + tlsValue("b_tls", in: "libb.so"))
      case "a_tls": #expect(slot == a + tlsValue("a_tls", in: "liba.so"))
      case "": #expect(slot == set.member(member).threadOffset + Int(r.addend))  // its own, by addend
      default: Issue.record("TLS relocation against \(r.symbol)")
      }
      seen.insert("\(name):\(r.symbol)")
    }
  }
  // liba reaches libb's, the program liba's, libb its own and hidden one.
  #expect(seen.contains("liba.so:b_tls") && seen.contains("program:a_tls") && seen.contains("libb.so:b_tls"))
}

@Test(.enabled(if: Tools.present), arguments: machines)
func aFixedProgramGetsACopyEveryoneUses(machine: Machine) throws {
  let b = try Built(machine)
  let set = try b.linkSet("fixed")
  #expect(set.members.map(\.name) == ["fixed", "libb.so"])
  #expect(b.relocations(set, "fixed").contains { $0.symbol == "b_data" })
  try set.bind()
  let copy = try #require(set.address("b_data", in: "fixed"))
  #expect(b.objects["fixed"]!.bias == 0 && copy < 0x1000_0000)  // where it was linked
  for i in 0..<3 {
    let w = UnsafeRawPointer(bitPattern: copy &+ UInt(4 * i) &- b.objects["fixed"]!.bias &+ b.objects["fixed"]!.view)!
    #expect(w.load(as: Int32.self) == Int32(i + 1))
  }
  // libb's own reference goes to the copy.
  for r in b.relocations(set, "libb.so") where r.symbol == "b_data" { #expect(b.word("libb.so", r.at) == copy) }
}

@Test(.enabled(if: Tools.present), arguments: machines)
func generalDynamicTLSIsRefusedByName(machine: Machine) throws {
  let (_, set) = try linked(machine, gd: true)
  do {
    try set.bind()
    Issue.record("bound")
  } catch {
    guard case .badDynamic(let what) = error.error else {
      Issue.record("\(error.object): \(error.error)")
      return
    }
    #expect(what.contains("initial-exec"), "\(error.object): \(what)")
  }
}
