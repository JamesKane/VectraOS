// SPDX-License-Identifier: BSD-3-Clause

// A program and the libraries it needs, linked as one set (D124, after
// NeoVectra's ADR-0047): the program first, then each DT_NEEDED name
// breadth first, each object once. Every symbol is bound before anything
// runs; a name resolves to its first definition in that order (the
// program's, then each library's in load order), so the program's
// definitions and its copies of libraries' data win. Libraries are
// relocated last loaded first and the program last, so what a copy
// relocation copies is already relocated.
//
// Thread-local storage is static: every object's PT_TLS block has a fixed
// offset from the thread pointer, laid out here as the psABIs lay out the
// initial set, and code reaches it by initial-exec (or local-exec in the
// program) offsets alone.
//   amd64 (variant II): the blocks sit below the thread pointer, the
//     program's nearest, each next one below the last, at its alignment.
//   arm64, rv64 (variant I): above it, after the gap (16 bytes on arm64),
//     the program's first; each block is congruent to its p_vaddr modulo
//     its alignment, as ld.lld's local-exec offsets assume for the
//     program (system/sys/floor's Thread.swift).
// Tier 0 and pure, like Dynamic.swift: the hosted tests link real objects
// in buffers, and a spawner links a program in another process through
// views of its pages.

/// Objects linked as one: a program and its libraries.
public struct LinkSet: Sendable {
  /// A PT_TLS segment's image (where it runs), sizes and alignment.
  public struct TLS: Sendable {
    public var image: UInt, fileSize: Int, size: Int, align: Int

    public init(image: UInt, fileSize: Int, size: Int, align: Int) {
      self.image = image
      self.fileSize = fileSize
      self.size = size
      self.align = max(1, align)
    }
  }

  public struct Member: Sendable {
    /// What it was loaded as: the program's name, or its DT_NEEDED name,
    /// and the same as bytes.
    public let name: String
    public let nameBytes: [UInt8]
    public let object: DynamicObject
    public let tls: TLS?
    /// Where its TLS block starts, from the thread pointer (negative below
    /// it); set by `layOutTLS`.
    public internal(set) var threadOffset = 0
  }

  public let machine: UInt16
  public private(set) var members: [Member] = []
  /// The thread pointer's alignment, and the bytes the blocks take below
  /// and above it.
  public private(set) var threadArea = (align: 16, below: 0, above: 0)

  public init(machine: UInt16) { self.machine = machine }

  /// Adds the next object: the program first, then each name
  /// `nextNeeded` gives, in turn.
  public mutating func add(_ name: String, _ object: DynamicObject, tls: TLS?) {
    members.append(Member(name: name, nameBytes: Array(name.utf8), object: object, tls: tls))
  }

  /// The next DT_NEEDED name no member is loaded as (or has as its
  /// soname), breadth first; nil once every one is loaded.
  public func nextNeeded() -> String? {
    for m in members {
      for n in m.object.neededBytes where index(of: n) == nil { return String(decoding: n, as: UTF8.self) }
    }
    return nil
  }

  /// The member loaded as `name` or with it as its soname. Names are
  /// compared as bytes, in loops: String's == normalizes, which needs
  /// Unicode tables only amd64's Embedded toolchain has, and on arm64 a
  /// short String read through a closure has come out corrupt.
  public func index(of name: [UInt8]) -> Int? {
    for i in members.indices {
      if members[i].nameBytes == name { return i }
      if let s = members[i].object.sonameBytes, s == name { return i }
    }
    return nil
  }

  /// The gap between the thread pointer and the first block, on variant I
  /// machines (arm64's two words; none on rv64 or amd64).
  var gap: Int { machine == 183 ? 16 : 0 }

  /// Gives each member with TLS its offset from the thread pointer, and
  /// sets `threadArea`.
  public mutating func layOutTLS() {
    var align = 16, below = 0, end = gap
    for i in members.indices {
      guard let t = members[i].tls else { continue }
      align = max(align, t.align)
      let a = t.align
      if machine == 62 {
        // Variant II: this block ends where the last began, rounded down
        // to its alignment (the program's, roundup(p_memsz, p_align) below).
        below = (below + t.size + a - 1) & ~(a - 1)
        members[i].threadOffset = -below
      } else {
        // Variant I: the first place at or past the last block's end
        // that is congruent to its image modulo its alignment.
        let start = end + Int((UInt(bitPattern: -end) &+ t.image) & UInt(a - 1))
        members[i].threadOffset = start
        end = start + t.size
      }
    }
    threadArea = (align, below, machine == 62 ? 0 : end)
  }

  /// The first definition of `name` in load order, skipping member
  /// `skipping` (a copy relocation's own object).
  public func lookup(_ name: [UInt8], skipping: Int? = nil) -> Definition? {
    for i in members.indices where i != skipping {
      let o = members[i].object
      guard let (address, s) = o.lookup(name) else { continue }
      if s.type == Symbol.typeTLS {
        guard members[i].tls != nil else { continue }
        return Definition(address: 0, threadOffset: members[i].threadOffset + Int(s.value))
      }
      return Definition(address: address, view: o.view &+ UInt(s.value), size: s.size)
    }
    return nil
  }

  /// Relocates every member against the set: the last loaded first, the
  /// program last. Lay out the TLS first. A failure names the object.
  public func bind() throws(BindError) {
    for i in members.indices.reversed() {
      let m = members[i]
      do throws(LinkError) {
        try m.object.relocate(threadOffset: m.tls == nil ? nil : m.threadOffset) { name, copy in
          lookup(name, skipping: copy ? i : nil)
        }
      } catch {
        throw BindError(object: m.name, error: error)
      }
    }
  }

  /// The order to initialize the members in: each after the libraries it
  /// needs (a depth-first post-order from the program, over DT_NEEDED in
  /// its order), so the program comes last. Load order is breadth first,
  /// which isn't that: a program needing libswiftCore and then
  /// libswift_Concurrency, which needs libswiftCore too, loads Core before
  /// Concurrency, but Concurrency's reverse order would run first. A cycle
  /// is broken where it is met.
  public func initOrder() -> [Int] {
    var order: [Int] = []
    var seen = [Bool](repeating: false, count: members.count)
    // An explicit stack, not recursion: (member, the next needed to visit).
    var stack: [(Int, Int)] = []
    if !members.isEmpty {
      seen[0] = true
      stack.append((0, 0))
    }
    while let (m, next) = stack.last {
      let needed = members[m].object.neededBytes
      if next < needed.count {
        stack[stack.count - 1].1 += 1
        if let i = index(of: needed[next]), !seen[i] {
          seen[i] = true
          stack.append((i, 0))
        }
      } else {
        stack.removeLast()
        order.append(m)
      }
    }
    // Members nothing reached (none, for a set nextNeeded built), last but the program.
    for i in members.indices where !seen[i] { order.insert(i, at: max(order.count - 1, 0)) }
    return order
  }

  /// A failure to bind, and the object's name.
  public struct BindError: Error, Sendable {
    public let object: String
    public let error: LinkError
  }
}
