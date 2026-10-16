// SPDX-License-Identifier: BSD-3-Clause

// A loaded ELF object's dynamic linking (M5k), from the gABI's "Dynamic
// Linking" (dynamic section, symbol table, hash tables), the GNU hash
// table's format as binutils and lld write it, and the psABIs'
// relocations (x86-64 §4.4, AArch64 ELF ABI §5.7, RISC-V ELF psABI
// "Relocations"). Tier 0 and pure: it reads and writes the object's memory
// at its load bias, wherever that memory came from, so the hosted tests
// relocate real objects in a buffer as croi's dlopen does in place.
//
// What it does: the dynamic section's tags; symbol lookup by the GNU hash
// table or the SysV one; RELA relocations (relative, absolute, GOT and
// PLT entries; every symbol resolved now, as BIND_NOW would). What it
// refuses: REL relocations, text relocations, TLS (a loaded object's TLS
// is a later step), IFUNCs and copy relocations.

/// Why an object can't be linked.
public enum LinkError: Error, Equatable, Sendable {
  /// A dynamic section without what linking needs, or with what we refuse.
  case badDynamic(String)
  /// A relocation type this machine's table doesn't handle.
  case unsupportedRelocation(UInt32)
  /// A symbol nothing defines (not weak).
  case undefinedSymbol(String)
}

/// A symbol table entry (Elf64_Sym).
public struct Symbol: Equatable, Sendable {
  public var name: UInt32
  public var info: UInt8
  public var other: UInt8
  public var section: UInt16
  public var value: UInt64
  public var size: UInt64

  public var binding: UInt8 { info >> 4 }
  public var type: UInt8 { info & 0xF }
  public var isDefined: Bool { section != 0 }
  public var isWeak: Bool { binding == 2 }
  /// Global or weak, and not hidden or internal.
  public var isExported: Bool { (binding == 1 || binding == 2) && other & 3 != 1 && other & 3 != 2 }
  public static let typeTLS: UInt8 = 6, typeIFunc: UInt8 = 10
}

/// An object in memory, ready to be linked: its dynamic section read.
public struct DynamicObject: Sendable {
  /// What the object's address 0 is in memory (0 for an ET_EXEC).
  public let bias: UInt
  public let machine: UInt16
  var strtab: UInt = 0, strsz = 0
  var symtab: UInt = 0
  var sysvHash: UInt = 0, gnuHash: UInt = 0
  var rela: UInt = 0, relaSize = 0, jmprel: UInt = 0, pltrelSize = 0
  /// DT_INIT and DT_INIT_ARRAY, run in that order once linked; DT_FINI_ARRAY
  /// and DT_FINI, at unload (never, for now).
  public var initFunction: UInt?
  public var initArray: (address: UInt, count: Int) = (0, 0)
  /// DT_NEEDED's names, and DT_SONAME.
  public var needed: [String] = []
  public var soname: String?

  /// Reads the dynamic section at `dynamic` (an address in memory) of an
  /// object for `machine` loaded at `bias`.
  public init(bias: UInt, dynamic: UInt, machine: UInt16) throws(LinkError) {
    self.bias = bias
    self.machine = machine
    var neededOffsets: [UInt64] = []
    var sonameOffset: UInt64?
    var initArraySize = 0
    var at = dynamic
    while true {
      let tag = unsafe Memory.u64(at), value = unsafe Memory.u64(at + 8)
      at += 16
      switch tag {
      case 0: break  // DT_NULL
      case 1: neededOffsets.append(value)
      case 2: pltrelSize = Int(value)
      case 4: sysvHash = bias + UInt(value)
      case 5: strtab = bias + UInt(value)
      case 6: symtab = bias + UInt(value)
      case 7: rela = bias + UInt(value)
      case 8: relaSize = Int(value)
      case 9: guard value == 24 else { throw .badDynamic("RELAENT \(value)") }
      case 10: strsz = Int(value)
      case 11: guard value == 24 else { throw .badDynamic("SYMENT \(value)") }
      case 12: initFunction = bias + UInt(value)
      case 14: sonameOffset = value
      case 17: throw .badDynamic("REL relocations")
      case 20: guard value == 7 else { throw .badDynamic("PLTREL \(value)") }  // DT_RELA
      case 22: throw .badDynamic("text relocations")
      case 23: jmprel = bias + UInt(value)
      case 25: initArray.address = bias + UInt(value)
      case 27: initArraySize = Int(value)
      case 30: if value & 4 != 0 { throw .badDynamic("text relocations") }  // DF_TEXTREL
      case 0x6FFF_FEF5: gnuHash = bias + UInt(value)
      default: continue
      }
      if tag == 0 { break }
    }
    guard strtab != 0, symtab != 0 else { throw .badDynamic("no symbol table") }
    guard gnuHash != 0 || sysvHash != 0 else { throw .badDynamic("no hash table") }
    initArray.count = initArraySize / 8
    needed = neededOffsets.map { string(at: UInt($0)) }
    soname = sonameOffset.map { string(at: UInt($0)) }
  }

  /// The NUL-terminated string at `offset` in the string table.
  func string(at offset: UInt) -> String {
    var bytes: [UInt8] = []
    var p = strtab + offset
    while true {
      let b = unsafe Memory.u8(p)
      if b == 0 { break }
      bytes.append(b)
      p += 1
    }
    return String(decoding: bytes, as: UTF8.self)
  }

  /// Whether the string at `offset` is `name`.
  func string(at offset: UInt32, equals name: [UInt8]) -> Bool {
    let p = strtab + UInt(offset)
    for i in 0..<name.count where unsafe Memory.u8(p + UInt(i)) != name[i] { return false }
    return unsafe Memory.u8(p + UInt(name.count)) == 0
  }

  public func symbol(_ index: Int) -> Symbol {
    let p = symtab + UInt(index) * 24
    return unsafe Symbol(name: Memory.u32(p), info: Memory.u8(p + 4), other: Memory.u8(p + 5),
                         section: Memory.u16(p + 6), value: Memory.u64(p + 8), size: Memory.u64(p + 16))
  }

  public func name(of s: Symbol) -> String { string(at: UInt(s.name)) }

  /// How many entries the symbol table has (the hash tables say).
  public var symbolCount: Int {
    if sysvHash != 0 { return Int(unsafe Memory.u32(sysvHash + 4)) }
    // The GNU table: past the last bucket's chain.
    let buckets = Int(unsafe Memory.u32(gnuHash)), offset = unsafe Memory.u32(gnuHash + 4)
    let bloom = Int(unsafe Memory.u32(gnuHash + 8))
    let bucketAt = gnuHash + 16 + UInt(bloom) * 8
    var last: UInt32 = 0
    for b in 0..<buckets { last = max(last, unsafe Memory.u32(bucketAt + UInt(b) * 4)) }
    guard last >= offset else { return Int(offset) }
    let chain = bucketAt + UInt(buckets) * 4
    while unsafe Memory.u32(chain + UInt(last - offset) * 4) & 1 == 0 { last += 1 }
    return Int(last) + 1
  }

  /// The address of the symbol `name` this object defines and exports.
  public func lookup(_ name: [UInt8]) -> (address: UInt, symbol: Symbol)? {
    guard let i = index(of: name) else { return nil }
    let s = symbol(i)
    return (bias + UInt(s.value), s)
  }

  /// The defined, exported symbol named `name`'s index, by the GNU hash
  /// table if there is one, else the SysV one.
  func index(of name: [UInt8]) -> Int? {
    func matches(_ i: Int) -> Bool {
      let s = symbol(i)
      return s.isDefined && s.isExported && string(at: s.name, equals: name)
    }
    if gnuHash != 0 {
      var h: UInt32 = 5381
      for c in name { h = h &* 33 &+ UInt32(c) }
      let buckets = unsafe Memory.u32(gnuHash), offset = unsafe Memory.u32(gnuHash + 4)
      let bloomSize = unsafe Memory.u32(gnuHash + 8), shift = unsafe Memory.u32(gnuHash + 12)
      guard buckets > 0, bloomSize > 0 else { return nil }
      let word = unsafe Memory.u64(gnuHash + 16 + UInt((h / 64) % bloomSize) * 8)
      let mask = UInt64(1) << (h % 64) | UInt64(1) << ((h >> shift) % 64)
      guard word & mask == mask else { return nil }
      let bucketAt = gnuHash + 16 + UInt(bloomSize) * 8
      var i = unsafe Memory.u32(bucketAt + UInt(h % buckets) * 4)
      guard i >= offset else { return nil }
      let chain = bucketAt + UInt(buckets) * 4
      while true {
        let c = unsafe Memory.u32(chain + UInt(i - offset) * 4)
        if c | 1 == h | 1 && matches(Int(i)) { return Int(i) }
        if c & 1 != 0 { return nil }
        i += 1
      }
    }
    var h: UInt32 = 0
    for c in name {
      h = (h << 4) &+ UInt32(c)
      let g = h & 0xF000_0000
      if g != 0 { h ^= g >> 24 }
      h &= ~g
    }
    let buckets = unsafe Memory.u32(sysvHash)
    guard buckets > 0 else { return nil }
    let chains = sysvHash + 8 + UInt(buckets) * 4
    var i = unsafe Memory.u32(sysvHash + 8 + UInt(h % buckets) * 4)
    while i != 0 {
      if matches(Int(i)) { return Int(i) }
      i = unsafe Memory.u32(chains + UInt(i) * 4)
    }
    return nil
  }

  /// What a relocation type does on this machine. Constants, not an enum:
  /// a program that exports its symbols keeps every function, and an enum's
  /// derived Hashable would bring the hasher's seed with it.
  typealias Kind = UInt8
  static let none: Kind = 0, relative: Kind = 1, absolute: Kind = 2, symbolOnly: Kind = 3

  func kind(_ type: UInt32) -> Kind? {
    switch machine {
    case 62:  // x86-64: NONE, 64, GLOB_DAT, JUMP_SLOT, RELATIVE
      switch type {
      case 0: return Self.none
      case 1: return Self.absolute
      case 6, 7: return Self.symbolOnly
      case 8: return Self.relative
      default: return nil
      }
    case 183:  // AArch64: NONE, ABS64, GLOB_DAT, JUMP_SLOT, RELATIVE
      switch type {
      case 0, 256: return Self.none
      case 257, 1025, 1026: return Self.absolute
      case 1027: return Self.relative
      default: return nil
      }
    case 243:  // RISC-V: NONE, 64, RELATIVE, JUMP_SLOT
      switch type {
      case 0: return Self.none
      case 2: return Self.absolute
      case 3: return Self.relative
      case 5: return Self.symbolOnly
      default: return nil
      }
    default: return nil
    }
  }

  /// Applies every relocation. `resolve` finds a symbol by name in the
  /// global scope (the program, then the objects loaded before, then this
  /// one), or nil; a weak symbol nothing defines is 0.
  public func relocate(_ resolve: ([UInt8]) -> UInt?) throws(LinkError) {
    // A symbol's address, resolved once however many relocations use it.
    var resolved: [UInt?] = []
    func address(_ index: Int) throws(LinkError) -> UInt {
      if index < resolved.count, let a = resolved[index] { return a }
      let s = symbol(index)
      if s.type == Symbol.typeTLS { throw .badDynamic("TLS symbol \(name(of: s))") }
      if s.type == Symbol.typeIFunc { throw .badDynamic("IFUNC \(name(of: s))") }
      var bytes: [UInt8] = []
      var p = strtab + UInt(s.name)
      while unsafe Memory.u8(p) != 0 {
        bytes.append(unsafe Memory.u8(p))
        p += 1
      }
      let a: UInt
      if let found = resolve(bytes) {
        a = found
      } else if s.isDefined && s.binding != 0 {
        a = bias + UInt(s.value)
      } else if s.isWeak {
        a = 0
      } else {
        throw .undefinedSymbol(name(of: s))
      }
      if resolved.count <= index { resolved.append(contentsOf: [UInt?](repeating: nil, count: index + 1 - resolved.count)) }
      resolved[index] = a
      return a
    }
    for (table, size) in [(rela, relaSize), (jmprel, pltrelSize)] where table != 0 {
      var at = table
      while at < table + UInt(size) {
        let offset = unsafe Memory.u64(at), info = unsafe Memory.u64(at + 8)
        let addend = unsafe Memory.u64(at + 16)
        at += 24
        let type = UInt32(truncatingIfNeeded: info), index = Int(info >> 32)
        guard let k = kind(type) else { throw .unsupportedRelocation(type) }
        let target = bias + UInt(offset)
        switch k {
        case Self.relative: unsafe Memory.store(target, UInt64(bias) &+ addend)
        case Self.absolute: unsafe Memory.store(target, UInt64(try address(index)) &+ addend)
        case Self.symbolOnly: unsafe Memory.store(target, UInt64(try address(index)))
        default: continue
        }
      }
    }
  }
}

/// Little-endian loads and stores at addresses in this process.
@unsafe enum Memory {
  static func u8(_ a: UInt) -> UInt8 { unsafe UnsafeRawPointer(bitPattern: a)!.load(as: UInt8.self) }
  static func u16(_ a: UInt) -> UInt16 { unsafe UnsafeRawPointer(bitPattern: a)!.loadUnaligned(as: UInt16.self) }
  static func u32(_ a: UInt) -> UInt32 { unsafe UnsafeRawPointer(bitPattern: a)!.loadUnaligned(as: UInt32.self) }
  static func u64(_ a: UInt) -> UInt64 { unsafe UnsafeRawPointer(bitPattern: a)!.loadUnaligned(as: UInt64.self) }
  static func store(_ a: UInt, _ v: UInt64) {
    unsafe UnsafeMutableRawPointer(bitPattern: a)!.storeBytes(of: v, as: UInt64.self)
  }
}
