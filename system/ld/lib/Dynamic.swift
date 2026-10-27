// SPDX-License-Identifier: BSD-3-Clause

// A loaded ELF object's dynamic linking (M5k), from the gABI's "Dynamic
// Linking" (dynamic section, symbol table, hash tables), the GNU hash
// table's format as binutils and lld write it, and the psABIs'
// relocations (x86-64 §4.4, AArch64 ELF ABI §5.7, RISC-V ELF psABI
// "Relocations"). Tier 0 and pure: it reads and writes the object's memory
// through a view, wherever that memory came from, so the hosted tests
// relocate real objects in a buffer, croi's dlopen does it in place, and a
// spawner does it for a program in another process through its own
// mapping of the same pages (D124).
//
// Two addresses, then: `bias`, what the object's address 0 is where it
// runs, which relocations write; and `view`, where address 0's bytes are
// here, which the linker reads and writes through. They are the same for
// dlopen.
//
// What it does: the dynamic section's tags; symbol lookup by the GNU hash
// table or the SysV one; RELA relocations (relative, absolute, GOT and
// PLT entries, every symbol resolved now as BIND_NOW would; copies; and
// static TLS's offsets from the thread pointer, initial-exec's). What it
// refuses: REL relocations, text relocations, IFUNCs, and general- or
// local-dynamic TLS (a module and offset pair, or a descriptor), which
// needs a __tls_get_addr nothing provides: such a library is built with
// -ftls-model=initial-exec.

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

/// What a name resolves to: an ordinary symbol's address where it runs and
/// its bytes here (what a copy relocation copies), or a TLS symbol's
/// offset from the thread pointer.
public struct Definition: Sendable {
  public var address: UInt
  public var view: UInt
  public var size: UInt64
  /// A thread-local symbol's offset from the thread pointer; nil for any
  /// other.
  public var threadOffset: Int?

  public init(address: UInt, view: UInt = 0, size: UInt64 = 0, threadOffset: Int? = nil) {
    self.address = address
    self.view = view
    self.size = size
    self.threadOffset = threadOffset
  }
}

/// A symbol's name and its two hashes, computed once however many objects
/// are searched for it (a set's lookup asks each in turn). The name is
/// read where it is, in a string table or a caller's buffer, not copied:
/// a spawn resolves over a thousand, and copying each into an array was
/// most of binding's time.
public struct SymbolName: Sendable {
  /// Where the name's bytes are in this process, and how many.
  let address: UInt, count: Int
  let gnu: UInt32, sysv: UInt32

  /// The name at `address`: `count` bytes, or up to a NUL if nil. The
  /// bytes must stay readable, and unchanged, while it is used.
  @unsafe init(at address: UInt, count: Int? = nil) {
    var g: UInt32 = 5381, s: UInt32 = 0, n = 0
    while n != count ?? Int.max {
      let c = unsafe Memory.u8(address + UInt(n))
      if count == nil && c == 0 { break }
      g = g &* 33 &+ UInt32(c)
      s = (s << 4) &+ UInt32(c)
      let high = s & 0xF000_0000
      if high != 0 { s ^= high >> 24 }
      s &= ~high
      n += 1
    }
    self.address = address
    self.count = n
    gnu = g
    sysv = s
  }

  /// `body` given the name `bytes`.
  public static func with<R>(_ bytes: [UInt8], _ body: (SymbolName) -> R) -> R {
    bytes.withUnsafeBufferPointer { unsafe body(SymbolName(at: UInt(bitPattern: $0.baseAddress), count: $0.count)) }
  }

  /// The name's bytes, copied.
  public var bytes: [UInt8] { (0..<count).map { unsafe Memory.u8(address + UInt($0)) } }
}

/// The definitions one object's relocation has resolved, by symbol index:
/// a table open-addressed by index, as large as what is asked of it. An
/// array by index was as long as the symbol table, which for libswiftCore
/// is thousands of entries, built and freed on every spawn.
struct Resolved {
  var keys: [UInt32] = []  // index + 1, 0 where empty
  var values: [Definition] = []
  var count = 0

  func slot(_ key: UInt32) -> Int {
    let mask = keys.count - 1
    var i = Int(key &* 0x9E37_79B1) & mask
    while keys[i] != 0 && keys[i] != key { i = (i + 1) & mask }
    return i
  }

  func find(_ index: Int) -> Definition? {
    guard !keys.isEmpty else { return nil }
    let i = slot(UInt32(truncatingIfNeeded: index + 1))
    return keys[i] == 0 ? nil : values[i]
  }

  mutating func insert(_ index: Int, _ d: Definition) {
    if (count + 1) * 2 > keys.count {
      let (oldKeys, oldValues) = (keys, values)
      keys = [UInt32](repeating: 0, count: max(64, keys.count * 2))
      values = [Definition](repeating: Definition(address: 0), count: keys.count)
      for j in oldKeys.indices where oldKeys[j] != 0 {
        let i = slot(oldKeys[j])
        keys[i] = oldKeys[j]
        values[i] = oldValues[j]
      }
    }
    let key = UInt32(truncatingIfNeeded: index + 1), i = slot(key)
    if keys[i] == 0 { count += 1 }
    keys[i] = key
    values[i] = d
  }
}

/// An object in memory, ready to be linked: its dynamic section read.
public struct DynamicObject: Sendable {
  /// What the object's address 0 is where it runs (0 for an ET_EXEC).
  public let bias: UInt
  /// Where address 0's bytes are here: the same as `bias` unless the
  /// object runs in another process.
  public let view: UInt
  public let machine: UInt16
  // Tables' addresses here (in the view).
  var strtab: UInt = 0, strsz = 0
  var symtab: UInt = 0
  var sysvHash: UInt = 0, gnuHash: UInt = 0
  var rela: UInt = 0, relaSize = 0, jmprel: UInt = 0, pltrelSize = 0
  /// DT_INIT and DT_INIT_ARRAY, run in that order once linked, where they
  /// run; DT_FINI_ARRAY and DT_FINI, at unload (never, for now).
  public var initFunction: UInt?
  public var initArray: (address: UInt, count: Int) = (0, 0)
  /// DT_NEEDED's names, and DT_SONAME, also as bytes: what a set compares
  /// (String's == normalizes, and on arm64 a short String read through a
  /// closure has come out corrupt; CLAUDE.md's toolchain pitfalls).
  public var needed: [String] = []
  public var soname: String?
  public var neededBytes: [[UInt8]] = []
  public var sonameBytes: [UInt8]?

  /// Reads the dynamic section at `dynamic` (an address in memory) of an
  /// object for `machine` loaded at `bias`, in this process.
  public init(bias: UInt, dynamic: UInt, machine: UInt16) throws(LinkError) {
    try self.init(bias: bias, view: bias, dynamicAt: dynamic &- bias, machine: machine)
  }

  /// Reads the dynamic section, at link-time address `dynamicAt`, of an
  /// object for `machine` that runs at `bias` and is seen here at `view`.
  public init(bias: UInt, view: UInt, dynamicAt: UInt, machine: UInt16) throws(LinkError) {
    self.bias = bias
    self.view = view
    self.machine = machine
    var neededOffsets: [UInt64] = []
    var sonameOffset: UInt64?
    var initArraySize = 0
    var at = view &+ dynamicAt
    while true {
      let tag = unsafe Memory.u64(at), value = unsafe Memory.u64(at + 8)
      at += 16
      switch tag {
      case 0: break  // DT_NULL
      case 1: neededOffsets.append(value)
      case 2: pltrelSize = Int(value)
      case 4: sysvHash = view &+ UInt(value)
      case 5: strtab = view &+ UInt(value)
      case 6: symtab = view &+ UInt(value)
      case 7: rela = view &+ UInt(value)
      case 8: relaSize = Int(value)
      case 9: guard value == 24 else { throw .badDynamic("RELAENT \(value)") }
      case 10: strsz = Int(value)
      case 11: guard value == 24 else { throw .badDynamic("SYMENT \(value)") }
      case 12: initFunction = bias &+ UInt(value)
      case 14: sonameOffset = value
      case 17: throw .badDynamic("REL relocations")
      case 20: guard value == 7 else { throw .badDynamic("PLTREL \(value)") }  // DT_RELA
      case 22: throw .badDynamic("text relocations")
      case 23: jmprel = view &+ UInt(value)
      case 25: initArray.address = bias &+ UInt(value)
      case 27: initArraySize = Int(value)
      case 30: if value & 4 != 0 { throw .badDynamic("text relocations") }  // DF_TEXTREL
      case 0x6FFF_FEF5: gnuHash = view &+ UInt(value)
      default: continue
      }
      if tag == 0 { break }
    }
    guard strtab != 0, symtab != 0 else { throw .badDynamic("no symbol table") }
    guard gnuHash != 0 || sysvHash != 0 else { throw .badDynamic("no hash table") }
    initArray.count = initArraySize / 8
    for o in neededOffsets { neededBytes.append(bytes(at: UInt(o))) }
    if let o = sonameOffset { sonameBytes = bytes(at: UInt(o)) }
    needed = neededOffsets.map { string(at: UInt($0)) }
    soname = sonameOffset.map { string(at: UInt($0)) }
  }

  /// The NUL-terminated string at `offset` in the string table.
  func string(at offset: UInt) -> String {
    String(decoding: bytes(at: offset), as: UTF8.self)
  }

  func bytes(at offset: UInt) -> [UInt8] {
    var bytes: [UInt8] = []
    var p = strtab + offset
    while true {
      let b = unsafe Memory.u8(p)
      if b == 0 { break }
      bytes.append(b)
      p += 1
    }
    return bytes
  }

  /// Whether the string at `offset` is `name`.
  func string(at offset: UInt32, equals name: SymbolName) -> Bool {
    let p = strtab + UInt(offset)
    for i in 0..<UInt(name.count) where unsafe Memory.u8(p + i) != Memory.u8(name.address + i) { return false }
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

  /// The address, where it runs, of the symbol `name` this object defines
  /// and exports.
  public func lookup(_ name: [UInt8]) -> (address: UInt, symbol: Symbol)? { SymbolName.with(name) { lookup($0) } }

  public func lookup(_ name: SymbolName) -> (address: UInt, symbol: Symbol)? {
    guard let i = index(of: name) else { return nil }
    let s = symbol(i)
    return (bias &+ UInt(s.value), s)
  }

  /// The defined, exported symbol named `name`'s index, by the GNU hash
  /// table if there is one, else the SysV one.
  func index(of name: SymbolName) -> Int? {
    func matches(_ i: Int) -> Bool {
      let s = symbol(i)
      return s.isDefined && s.isExported && string(at: s.name, equals: name)
    }
    if gnuHash != 0 {
      let h = name.gnu
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
    let h = name.sysv
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
  static let none: Kind = 0, relative: Kind = 1, absolute: Kind = 2, symbolOnly: Kind = 3, copy: Kind = 4,
    threadOffset: Kind = 5, dynamicTLS: Kind = 6

  func kind(_ type: UInt32) -> Kind? {
    switch machine {
    case 62:  // x86-64: NONE, 64, COPY, GLOB_DAT, JUMP_SLOT, RELATIVE; DTPMOD64, DTPOFF64, TPOFF64
      switch type {
      case 0: return Self.none
      case 1: return Self.absolute
      case 5: return Self.copy
      case 6, 7: return Self.symbolOnly
      case 8: return Self.relative
      case 16, 17: return Self.dynamicTLS
      case 18: return Self.threadOffset
      default: return nil
      }
    case 183:  // AArch64: NONE, ABS64, COPY, GLOB_DAT, JUMP_SLOT, RELATIVE; TLS_DTPMOD64, TLS_DTPREL64, TLS_TPREL64, TLSDESC
      switch type {
      case 0, 256: return Self.none
      case 257, 1025, 1026: return Self.absolute
      case 1024: return Self.copy
      case 1027: return Self.relative
      case 1028, 1029, 1031: return Self.dynamicTLS
      case 1030: return Self.threadOffset
      default: return nil
      }
    case 243:  // RISC-V: NONE, 64, RELATIVE, COPY, JUMP_SLOT; TLS_DTPMOD64, TLS_DTPREL64, TLS_TPREL64
      switch type {
      case 0: return Self.none
      case 2: return Self.absolute
      case 3: return Self.relative
      case 4: return Self.copy
      case 5: return Self.symbolOnly
      case 7, 9: return Self.dynamicTLS
      case 11: return Self.threadOffset
      default: return nil
      }
    default: return nil
    }
  }

  /// Applies every relocation. `resolve` finds a symbol by name in the
  /// global scope (the program, then the objects loaded before, then this
  /// one), or nil; a weak symbol nothing defines is 0. This object has no
  /// TLS of its own (dlopen's case).
  public func relocate(_ resolve: (SymbolName) -> UInt?) throws(LinkError) {
    try relocate(threadOffset: nil) { name, copy in copy ? nil : resolve(name).map { Definition(address: $0) } }
  }

  /// Applies every relocation. `resolve(name, copy)` finds a symbol's
  /// definition in the global scope, or nil; for a copy relocation, in
  /// every object but this one. `threadOffset` is where this object's own
  /// TLS block starts, from the thread pointer, if it has one.
  public func relocate(threadOffset own: Int?, _ resolve: (SymbolName, Bool) -> Definition?) throws(LinkError) {
    // A symbol's definition, resolved once however many relocations use it.
    var resolved = Resolved()
    func definition(_ index: Int) throws(LinkError) -> Definition {
      if let d = resolved.find(index) { return d }
      let s = symbol(index)
      if s.type == Symbol.typeIFunc { throw .badDynamic("IFUNC \(name(of: s))") }
      let d: Definition
      if let found = resolve(unsafe SymbolName(at: strtab + UInt(s.name)), false) {
        d = found
      } else if s.isDefined && s.binding != 0 {
        d = try local(s)
      } else if s.isWeak {
        d = Definition(address: 0)
      } else {
        throw .undefinedSymbol(name(of: s))
      }
      if s.type == Symbol.typeTLS, d.threadOffset == nil, d.address != 0 {
        throw .badDynamic("\(name(of: s)) isn't thread-local where it's defined")
      }
      if s.type != Symbol.typeTLS, s.type != 0, d.threadOffset != nil {
        throw .badDynamic("\(name(of: s)) is thread-local where it's defined")
      }
      resolved.insert(index, d)
      return d
    }
    // A symbol this object defines, found in its own table.
    func local(_ s: Symbol) throws(LinkError) -> Definition {
      guard s.type == Symbol.typeTLS else { return Definition(address: bias &+ UInt(s.value), view: view &+ UInt(s.value), size: s.size) }
      guard let own else { throw .badDynamic("TLS symbol \(name(of: s)), with no TLS block") }
      return Definition(address: 0, threadOffset: own + Int(s.value))
    }
    for (table, size) in [(rela, relaSize), (jmprel, pltrelSize)] where table != 0 {
      var at = table
      while at < table + UInt(size) {
        let offset = unsafe Memory.u64(at), info = unsafe Memory.u64(at + 8)
        let addend = unsafe Memory.u64(at + 16)
        at += 24
        let type = UInt32(truncatingIfNeeded: info), index = Int(info >> 32)
        guard let k = kind(type) else { throw .unsupportedRelocation(type) }
        let target = view &+ UInt(offset)
        switch k {
        case Self.relative: unsafe Memory.store(target, UInt64(bias) &+ addend)
        case Self.absolute: unsafe Memory.store(target, UInt64(try definition(index).address) &+ addend)
        case Self.symbolOnly: unsafe Memory.store(target, UInt64(try definition(index).address))
        case Self.copy:
          let s = symbol(index)
          guard let from = resolve(unsafe SymbolName(at: strtab + UInt(s.name)), true), from.threadOffset == nil else {
            throw .undefinedSymbol(name(of: s))
          }
          guard from.size >= s.size, from.view != 0 else { throw .badDynamic("copy of \(name(of: s)): sizes") }
          unsafe UnsafeMutableRawPointer(bitPattern: target)!.copyMemory(
            from: UnsafeRawPointer(bitPattern: from.view)!, byteCount: Int(s.size))
        case Self.threadOffset:
          // Symbol 0: this object's own block, the addend its variable's offset.
          let start: Int
          if index == 0 {
            guard let own else { throw .badDynamic("TLS relocation, with no TLS block") }
            start = own
          } else {
            let d = try definition(index)
            guard let t = d.threadOffset else {
              throw .badDynamic("\(name(of: symbol(index))) isn't thread-local where it's defined")
            }
            start = t
          }
          unsafe Memory.store(target, UInt64(bitPattern: Int64(start)) &+ addend)
        case Self.dynamicTLS:
          throw .badDynamic("general-dynamic TLS (relocation \(type)): build it with -ftls-model=initial-exec")
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
