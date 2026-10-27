// SPDX-License-Identifier: BSD-3-Clause

// The dynamic linker's core (M5k) on real shared objects: a C object
// compiled for each of croi's machines and linked by ld.lld with the GNU
// hash table, the SysV one or both, loaded into a buffer as dlopen maps
// one, then relocated and looked into. Skips without clang and ld.lld.

import Elf
import Foundation
import Ld
import Testing

/// The tools: the host's clang, the toolchain's ld.lld.
enum Tools {
  static func find(_ name: String) -> String? {
    var dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
    let home = NSHomeDirectory()
    dirs.append("\(home)/.local/share/swiftly/toolchains/6.4.0/usr/bin")
    return dirs.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
  }
  static let clang = find("clang"), lld = find("ld.lld")
  static var present: Bool { clang != nil && lld != nil }

  static func run(_ tool: String, _ args: [String]) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    let err = Pipe()
    p.standardError = err
    try p.run()
    p.waitUntilExit()
    let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    if p.terminationStatus != 0 { throw ToolError(description: "\(tool) failed: \(message)") }
  }
  struct ToolError: Error, CustomStringConvertible { let description: String }
}

/// The test object: data pointing at its own and imported symbols (RELATIVE
/// and absolute relocations), calls and loads through the PLT and GOT, a
/// weak symbol nothing defines, and 200 functions for the hash tables.
let source = """
  extern int imported_data;
  extern int imported_fn(int);
  extern int maybe_absent __attribute__((weak));
  int local_value = 5;
  static int hidden_value = 9;
  void *table[] = { &local_value, &imported_data, (void *)imported_fn, &table[1], &maybe_absent, &hidden_value };
  int call_imported(int x) { return imported_fn(x) + local_value + hidden_value; }
  int *address_of_imported(void) { return &imported_data; }

  """ + (0..<200).map { "int f\($0)(void) { return \($0); }\n" }.joined()

struct Machine: CustomStringConvertible, Sendable {
  let target: String, flags: [String], number: UInt16
  var description: String { target }
}

let machines = [
  Machine(target: "x86_64-unknown-none-elf", flags: [], number: ElfImage.Machine.amd64),
  Machine(target: "aarch64-unknown-none-elf", flags: [], number: ElfImage.Machine.arm64),
  Machine(target: "riscv64-unknown-none-elf", flags: ["-march=rv64gc", "-mabi=lp64"], number: ElfImage.Machine.rv64),
]

/// A shared object built for `machine` with `hash` (gnu, sysv or both),
/// loaded into memory that lives as long as it does.
final class Loaded {
  let elf: ElfImage
  let memory: UnsafeMutableRawPointer
  let object: DynamicObject
  let span: (start: UInt64, size: UInt64)

  init(_ machine: Machine, hash: String) throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ld-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let c = dir.appendingPathComponent("t.c").path, o = dir.appendingPathComponent("t.o").path
    let so = dir.appendingPathComponent("libt.so").path
    try source.write(toFile: c, atomically: true, encoding: .utf8)
    try Tools.run(Tools.clang!, ["--target=\(machine.target)", "-fPIC", "-O1", "-ffreestanding", "-c", c, "-o", o] + machine.flags)
    // Page-aligned segments, as croi's ElfImage takes them (croi_user_library's flags).
    try Tools.run(Tools.lld!, ["-shared", "--hash-style=\(hash)", "-soname", "libt.so", "-zseparate-loadable-segments",
                               "-zmax-page-size=4096", o, "-o", so])
    let bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: so)))
    elf = try ElfImage(parsing: bytes.span.bytes, machine: machine.number)
    span = (elf.base, elf.size)
    let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(span.size), alignment: 4096)
    memory.initializeMemory(as: UInt8.self, repeating: 0, count: Int(span.size))
    let start = span.start
    for i in 0..<elf.segmentCount {
      let s = elf.segments[i]
      bytes.withUnsafeBytes { b in
        (memory + Int(s.vaddr - start)).copyMemory(from: b.baseAddress! + Int(s.offset), byteCount: Int(s.filesz))
      }
    }
    self.memory = memory
    let bias = UInt(bitPattern: memory) - UInt(span.start)
    object = try DynamicObject(bias: bias, dynamic: bias + UInt(elf.dynamic!), machine: machine.number)
  }

  deinit { memory.deallocate() }

  func address(_ name: String) -> UInt? { object.lookup(Array(name.utf8))?.address }
  func word(_ address: UInt) -> UInt { UnsafeRawPointer(bitPattern: address)!.load(as: UInt.self) }
  func contains(_ address: UInt) -> Bool {
    address >= UInt(bitPattern: memory) && address < UInt(bitPattern: memory) + UInt(span.size)
  }
}

let importedData: UInt = 0x1111_0000, importedFn: UInt = 0x2222_0000

func resolveImports(_ name: SymbolName) -> UInt? {
  switch String(decoding: name.bytes, as: UTF8.self) {
  case "imported_data": importedData
  case "imported_fn": importedFn
  default: nil
  }
}

@Test(.enabled(if: Tools.present), arguments: machines)
func relocationsPointWhereTheyShould(machine: Machine) throws {
  let t = try Loaded(machine, hash: "both")
  #expect(t.object.soname == "libt.so")
  try t.object.relocate(resolveImports)
  let table = try #require(t.address("table"))
  let local = try #require(t.address("local_value"))
  #expect(t.word(table) == local)
  #expect(t.word(table + 8) == importedData)
  #expect(t.word(table + 16) == importedFn)
  #expect(t.word(table + 24) == table + 8)
  #expect(t.word(table + 32) == 0)  // weak, nothing defines it
  #expect(t.contains(t.word(table + 40)))  // hidden: relative
  #expect(t.address("hidden_value") == nil)
  #expect(t.address("imported_fn") == nil)  // not defined here
}

@Test(.enabled(if: Tools.present), arguments: machines)
func everyGOTAndPLTEntryIsResolved(machine: Machine) throws {
  // Each relocation against imported_fn or imported_data, wherever the
  // linker put it (a GOT or PLT slot, or the table), holds its address.
  let t = try Loaded(machine, hash: "both")
  try t.object.relocate(resolveImports)
  var checked = 0
  for (tag, size) in [(7, 8), (23, 2)] as [(UInt, UInt)] {  // DT_RELA, DT_RELASZ; DT_JMPREL, DT_PLTRELSZ
    guard let table = dynamicValue(t, tag), let bytes = dynamicValue(t, size) else { continue }
    var at = t.object.bias + table
    while at < t.object.bias + table + bytes {
      let info = UInt64(t.word(at + 8))
      let symbol = t.object.symbol(Int(info >> 32))
      let name = t.object.name(of: symbol)
      let slot = t.word(t.object.bias + t.word(at))
      if name == "imported_fn" {
        #expect(slot == importedFn)
        checked += 1
      } else if name == "imported_data" {
        #expect(slot == importedData)
        checked += 1
      }
      at += 24
    }
  }
  #expect(checked >= 3)
}

/// A dynamic tag's value, read straight from the section.
func dynamicValue(_ t: Loaded, _ tag: UInt) -> UInt? {
  var at = t.object.bias + UInt(t.elf.dynamic!)
  while t.word(at) != 0 {
    if t.word(at) == tag { return t.word(at + 8) }
    at += 16
  }
  return nil
}

@Test(.enabled(if: Tools.present), arguments: machines)
func everyHashTableFindsWhatTheSymbolTableHolds(machine: Machine) throws {
  for hash in ["gnu", "sysv", "both"] {
    let t = try Loaded(machine, hash: hash)
    // By scanning the table: every exported, defined symbol.
    var scanned: [String: UInt] = [:]
    for i in 1..<t.object.symbolCount {
      let s = t.object.symbol(i)
      if s.isDefined && s.isExported { scanned[t.object.name(of: s)] = t.object.bias + UInt(s.value) }
    }
    #expect(scanned.count >= 204, "\(hash)")
    for (name, address) in scanned { #expect(t.address(name) == address, "\(hash) \(name)") }
    for missing in ["f200", "f", "", "imported_fn", "local_valu", "local_value_"] {
      #expect(t.address(missing) == nil, "\(hash) \(missing)")
    }
  }
}

@Test(.enabled(if: Tools.present), arguments: machines)
func anUndefinedSymbolIsAnError(machine: Machine) throws {
  let t = try Loaded(machine, hash: "gnu")
  #expect(throws: LinkError.undefinedSymbol("imported_data")) {
    try t.object.relocate { name in String(decoding: name.bytes, as: UTF8.self) == "imported_fn" ? importedFn : nil }
  }
}

@Test func theParserReportsWhatALinkerNeeds() throws {
  guard Tools.present else { return }
  let t = try Loaded(machines[0], hash: "both")
  #expect(t.elf.kind == .pie && t.elf.dynamic != nil && !t.elf.tls)
  #expect(t.elf.relro != nil)
  #expect(t.span.start == 0 && t.span.size % 4096 == 0)
}
