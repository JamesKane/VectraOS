// SPDX-License-Identifier: BSD-3-Clause

// Loading a DSDT or SSDT into the namespace (ACPI 6.5 §5.4, §20): its
// named objects become nodes, method bodies are kept as spans to run
// later, and code outside any method is kept, in order, to run at load
// (A0c). Every opcode in §20.2 is decoded for its extent, so nothing is
// skipped by guesswork: a name in an expression is a method call with as
// many arguments as the namespace (or an External) says.

/// Reads AML bytes, never past `end`.
struct Cursor {
  let bytes: [UInt8]
  var at: Int
  var end: Int

  var atEnd: Bool { at >= end }

  func malformed() -> ACPIError { .malformed(UInt32(truncatingIfNeeded: at)) }

  func peek(_ ahead: Int = 0) throws(ACPIError) -> UInt8 {
    guard at + ahead < end else { throw malformed() }
    return bytes[at + ahead]
  }

  mutating func byte() throws(ACPIError) -> UInt8 {
    let b = try peek()
    at += 1
    return b
  }

  mutating func word() throws(ACPIError) -> UInt16 { UInt16(try byte()) | UInt16(try byte()) << 8 }
  mutating func dword() throws(ACPIError) -> UInt32 { UInt32(try word()) | UInt32(try word()) << 16 }
  mutating func qword() throws(ACPIError) -> UInt64 { UInt64(try dword()) | UInt64(try dword()) << 32 }

  mutating func skip(_ n: Int) throws(ACPIError) {
    guard n >= 0, at + n <= end else { throw malformed() }
    at += n
  }

  /// A PkgLength's raw value (§20.2.4).
  mutating func pkgValue() throws(ACPIError) -> Int {
    let lead = try byte()
    let follow = Int(lead >> 6)
    if follow == 0 { return Int(lead & 0x3F) }
    var value = Int(lead & 0x0F)
    for k in 0..<follow { value |= Int(try byte()) << (4 + 8 * k) }
    return value
  }

  /// A package's end: its PkgLength counts from where the length starts.
  mutating func pkgEnd() throws(ACPIError) -> Int {
    let start = at
    let end = start + (try pkgValue())
    guard end >= at, end <= self.end else { throw malformed() }
    return end
  }

  /// A NameString (§20.2.2).
  mutating func nameString() throws(ACPIError) -> NamePath {
    var path = NamePath()
    if try peek() == 0x5C {
      path.fromRoot = true
      at += 1
    } else {
      while try peek() == 0x5E {
        path.parents += 1
        at += 1
      }
    }
    let lead = try byte()
    let count: Int
    switch lead {
    case 0x00: count = 0
    case 0x2E: count = 2
    case 0x2F: count = Int(try byte())
    default:
      guard NameSeg.isLead(lead) else { throw malformed() }
      at -= 1
      count = 1
    }
    for _ in 0..<count {
      guard at + 4 <= end, NameSeg.isLead(bytes[at]) else { throw malformed() }
      path.segments.append(NameSeg(bytes, at: at))
      at += 4
    }
    return path
  }

  /// Whether a NameString starts here.
  func atName() throws(ACPIError) -> Bool {
    let b = try peek()
    return NameSeg.isLead(b) || b == 0x5C || b == 0x5E || b == 0x2E || b == 0x2F
  }
}

extension ACPIError {
  static func unknown(_ opcode: UInt16, _ at: Int) -> ACPIError {
    .unknownOpcode(opcode, at: UInt32(truncatingIfNeeded: at))
  }
}

/// How deep terms may nest before a table is taken to be malformed.
let maximumDepth = 256

extension Namespace {
  /// Loads a DSDT or SSDT. A table that fails part way leaves what it had
  /// defined (as ACPICA does) and throws.
  public mutating func load(_ table: Table) throws(ACPIError) {
    let index = addTable(table.bytes)
    var c = Cursor(bytes: table.bytes, at: Table.headerSize, end: table.length)
    var loader = Loader(table: index)
    try loader.termList(&c, end: c.end, scope: Self.root, depth: 0, into: &self)
  }
}

extension Namespace {
  /// For diagnosis and tests until load-time code runs (A0c): loads the
  /// definitions inside every load-time If and Else as if each held, so
  /// what any configuration could define is there to look at. Real loads
  /// evaluate the conditions instead. A second definition (an If and its
  /// Else both defining a name) is noted, and the first stays.
  public mutating func loadAssumingConditions() throws(ACPIError) {
    var done = 0
    while done < loadCode.count {
      let (code, scope) = loadCode[done]
      done += 1
      var c = Cursor(bytes: tables[code.table], at: code.start, end: code.end)
      guard try c.peek() == 0xA0 else { continue }
      let loader = Loader(table: code.table)
      var bodies: [(Int, Int)] = []
      c.at += 1
      let ifEnd = try c.pkgEnd()
      try loader.skipTermArg(&c, scope: scope, depth: 0, ns: self)
      bodies.append((c.at, ifEnd))
      c.at = ifEnd
      if c.at < c.end, try c.peek() == 0xA1 {
        c.at += 1
        let elseEnd = try c.pkgEnd()
        bodies.append((c.at, elseEnd))
      }
      for (start, end) in bodies {
        var body = Cursor(bytes: tables[code.table], at: start, end: end)
        try loader.termList(&body, end: end, scope: scope, depth: 0, into: &self)
      }
    }
  }
}

struct Loader {
  let table: Int
  /// Runs load-time code where it stands (A0c); without it, the code is
  /// kept in `loadCode` (parsing alone).
  var run: Runner? = nil

  init(table: Int, run: Runner? = nil) {
    self.table = table
    self.run = run
  }

  /// Load-time code met: run it, or keep it.
  func loadCode(_ code: Code, scope: Int, into ns: inout Namespace) {
    guard let run else {
      ns.addLoadCode(code, scope: scope)
      return
    }
    do {
      try run(&ns, code, scope)
    } catch {
      ns.note(.codeFailed(error), table: table, offset: code.start)
    }
  }

  /// Terms to `end` in `scope`.
  func termList(_ c: inout Cursor, end: Int, scope: Int, depth: Int, into ns: inout Namespace) throws(ACPIError) {
    guard depth < maximumDepth else { throw ACPIError.tooDeep }
    while c.at < end {
      try term(&c, scope: scope, depth: depth + 1, into: &ns)
    }
    guard c.at == end else { throw c.malformed() }
  }

  /// One term: a definition goes into the namespace; anything else is
  /// code, kept to run at load.
  func term(_ c: inout Cursor, scope: Int, depth: Int, into ns: inout Namespace) throws(ACPIError) {
    let start = c.at
    let op = try c.peek()
    switch op {
    case 0x10: try scopeOp(&c, scope: scope, depth: depth, into: &ns)
    case 0x14: try methodOp(&c, scope: scope, into: &ns)
    case 0x08: try nameOp(&c, scope: scope, depth: depth, into: &ns)
    case 0x06: try aliasOp(&c, scope: scope, into: &ns)
    case 0x15: try externalOp(&c, scope: scope, into: &ns)
    case 0x5B:
      let ext = try c.peek(1)
      switch ext {
      case 0x82, 0x83, 0x84, 0x85: try containerOp(&c, ext, scope: scope, depth: depth, into: &ns)
      case 0x01, 0x02, 0x80, 0x88: try simpleNamedOp(&c, ext, scope: scope, depth: depth, into: &ns)
      case 0x81, 0x86, 0x87: try fieldOp(&c, ext, scope: scope, depth: depth, into: &ns)
      default:
        try skipStatement(&c, scope: scope, depth: depth, ns: ns)
        loadCode(Code(table: table, start: start, end: c.at), scope: scope, into: &ns)
      }
    default:
      // Code outside a method: If blocks, stores, calls. It runs at load.
      try skipStatement(&c, scope: scope, depth: depth, ns: ns)
      loadCode(Code(table: table, start: start, end: c.at), scope: scope, into: &ns)
    }
  }

  // MARK: Definitions

  /// The node a definition names: created under the path's scope, or the
  /// existing one if it's only a placeholder (a scope made by a path, or
  /// an External). Nil for a second real definition, which is noted.
  func define(_ path: NamePath, in scope: Int, at offset: Int, into ns: inout Namespace) -> Int? {
    guard ns.nodes.count < Namespace.maximumNodes else {
      ns.note(.codeFailed(.tooManyObjects), table: table, offset: offset)
      return nil
    }
    guard let parent = ns.parentScope(path, from: scope), let name = path.segments.last else {
      ns.note(.notFound, table: table, offset: offset)
      return nil
    }
    if let existing = ns.child(parent, name) {
      switch ns.nodes[existing].object {
      case .scope where ns.nodes[existing].table >= 0, .external: return existing
      default:
        ns.note(.alreadyDefined, table: table, offset: offset)
        return nil
      }
    }
    return ns.add(name, under: parent, .scope, table: table)
  }

  func scopeOp(_ c: inout Cursor, scope: Int, depth: Int, into ns: inout Namespace) throws(ACPIError) {
    let offset = c.at
    c.at += 1
    let end = try c.pkgEnd()
    let path = try c.nameString()
    // A Scope opens an existing name (§19.6.122). One that isn't there
    // (yet) gets a placeholder, so what's inside still loads.
    var target = ns.find(path, from: scope)
    if target == nil {
      ns.note(.notFound, table: table, offset: offset)
      target = define(path, in: scope, at: offset, into: &ns)
    }
    guard let node = target.flatMap({ ns.follow($0) }) else {
      c.at = end
      return
    }
    try termList(&c, end: end, scope: node, depth: depth, into: &ns)
  }

  func methodOp(_ c: inout Cursor, scope: Int, into ns: inout Namespace) throws(ACPIError) {
    let offset = c.at
    c.at += 1
    let end = try c.pkgEnd()
    let path = try c.nameString()
    let flags = try c.byte()
    let body = Code(table: table, start: c.at, end: end)
    c.at = end
    guard let node = define(path, in: scope, at: offset, into: &ns) else { return }
    ns.setObject(node, .method(args: Int(flags & 7), serialized: flags & 8 != 0, syncLevel: Int(flags >> 4), body: body),
                 table: table)
  }

  func nameOp(_ c: inout Cursor, scope: Int, depth: Int, into ns: inout Namespace) throws(ACPIError) {
    let offset = c.at
    c.at += 1
    let path = try c.nameString()
    let value = try dataObject(&c, scope: scope, depth: depth, ns: ns)
    guard let node = define(path, in: scope, at: offset, into: &ns) else { return }
    ns.setObject(node, .value(value), table: table)
  }

  func aliasOp(_ c: inout Cursor, scope: Int, into ns: inout Namespace) throws(ACPIError) {
    let offset = c.at
    c.at += 1
    let source = try c.nameString()
    let alias = try c.nameString()
    guard let node = define(alias, in: scope, at: offset, into: &ns) else { return }
    ns.setObject(node, .alias(source, scope: scope), table: table)
  }

  func externalOp(_ c: inout Cursor, scope: Int, into ns: inout Namespace) throws(ACPIError) {
    c.at += 1
    let path = try c.nameString()
    let type = try c.byte()
    let args = Int(try c.byte() & 7)
    // Only a placeholder: a real definition (here or in a later table)
    // replaces it, and one already made stays.
    if ns.find(path, from: scope) != nil { return }
    guard let parent = ns.parentScope(path, from: scope), let name = path.segments.last else { return }
    _ = ns.add(name, under: parent, .external(type: type, args: args), table: table)
  }

  /// Device, Processor, PowerResource, ThermalZone: a node with terms inside.
  func containerOp(_ c: inout Cursor, _ ext: UInt8, scope: Int, depth: Int, into ns: inout Namespace)
    throws(ACPIError)
  {
    let offset = c.at
    c.at += 2
    let end = try c.pkgEnd()
    let path = try c.nameString()
    let object: Object
    switch ext {
    case 0x82: object = .device
    case 0x83:
      object = .processor(id: try c.byte(), blockAddress: try c.dword(), blockLength: try c.byte())
    case 0x84: object = .powerResource(systemLevel: try c.byte(), resourceOrder: try c.word())
    default: object = .thermalZone
    }
    guard let node = define(path, in: scope, at: offset, into: &ns) else {
      c.at = end
      return
    }
    ns.setObject(node, object, table: table)
    try termList(&c, end: end, scope: node, depth: depth, into: &ns)
  }

  /// Mutex, Event, OperationRegion, DataTableRegion.
  func simpleNamedOp(_ c: inout Cursor, _ ext: UInt8, scope: Int, depth: Int, into ns: inout Namespace)
    throws(ACPIError)
  {
    let offset = c.at
    c.at += 2
    let path = try c.nameString()
    let object: Object
    switch ext {
    case 0x01: object = .mutex(syncLevel: try c.byte() & 0x0F)
    case 0x02: object = .event
    case 0x80:
      let space = try c.byte()
      object = .region(space: space, offset: try operand(&c, scope: scope, depth: depth, ns: ns),
                       length: try operand(&c, scope: scope, depth: depth, ns: ns))
    default:
      object = .dataRegion(signature: try operand(&c, scope: scope, depth: depth, ns: ns),
                           oemID: try operand(&c, scope: scope, depth: depth, ns: ns),
                           oemTableID: try operand(&c, scope: scope, depth: depth, ns: ns))
    }
    guard let node = define(path, in: scope, at: offset, into: &ns) else { return }
    ns.setObject(node, object, table: table)
  }

  /// A TermArg kept as a value: a constant if it is one, else its code.
  func operand(_ c: inout Cursor, scope: Int, depth: Int, ns: Namespace) throws(ACPIError) -> Value {
    let start = c.at
    if let v = try constant(&c) { return v }
    try skipTermArg(&c, scope: scope, depth: depth, ns: ns)
    return .deferred(Code(table: table, start: start, end: c.at), scope: scope)
  }

  /// Field, IndexField, BankField: a node for each named field.
  func fieldOp(_ c: inout Cursor, _ ext: UInt8, scope: Int, depth: Int, into ns: inout Namespace) throws(ACPIError) {
    c.at += 2
    let end = try c.pkgEnd()
    let source: Field.Source
    switch ext {
    case 0x81: source = .region(try c.nameString())
    case 0x86: source = .index(index: try c.nameString(), data: try c.nameString())
    default:
      let region = try c.nameString()
      let bank = try c.nameString()
      source = .bank(region: region, bank: bank, value: try operand(&c, scope: scope, depth: depth, ns: ns))
    }
    let flags = try c.byte()
    var field = Field(source: source, scope: scope, flags: flags, bitOffset: 0, bitLength: 0, accessAttrib: 0,
                      accessLength: 0)
    var bit: UInt32 = 0
    while c.at < end {
      let offset = c.at
      switch try c.peek() {
      case 0x00:  // ReservedField: bits skipped
        c.at += 1
        bit &+= UInt32(truncatingIfNeeded: try c.pkgValue())
      case 0x01:  // AccessField: AccessType, AccessAttrib
        c.at += 1
        field.flags = field.flags & 0xF0 | (try c.byte() & 0x0F)
        field.accessAttrib = try c.byte()
      case 0x02:  // ConnectField: a NameString or a buffer
        c.at += 1
        if try c.peek() == 0x11 {
          c.at += 1
          c.at = try c.pkgEnd()
        } else {
          _ = try c.nameString()
        }
      case 0x03:  // ExtendedAccessField: AccessType, attrib, length
        c.at += 1
        field.flags = field.flags & 0xF0 | (try c.byte() & 0x0F)
        field.accessAttrib = try c.byte()
        field.accessLength = try c.byte()
      default:  // NamedField: a segment and its width in bits
        guard c.at + 4 <= end, NameSeg.isLead(try c.peek()) else { throw c.malformed() }
        let name = NameSeg(c.bytes, at: c.at)
        c.at += 4
        let bits = UInt32(truncatingIfNeeded: try c.pkgValue())
        field.bitOffset = bit
        field.bitLength = bits
        bit &+= bits
        var path = NamePath()
        path.segments = [name]
        if let node = define(path, in: scope, at: offset, into: &ns) { ns.setObject(node, .field(field), table: table) }
      }
    }
    guard c.at == end else { throw c.malformed() }
  }

  // MARK: Data

  /// A ComputationalData constant (§20.2.3), or nil (leaving the cursor)
  /// if the next term isn't one.
  func constant(_ c: inout Cursor) throws(ACPIError) -> Value? {
    switch try c.peek() {
    case 0x00:
      c.at += 1
      return .integer(0)
    case 0x01:
      c.at += 1
      return .integer(1)
    case 0xFF:
      c.at += 1
      return .integer(UInt64.max)
    case 0x0A:
      c.at += 1
      return .integer(UInt64(try c.byte()))
    case 0x0B:
      c.at += 1
      return .integer(UInt64(try c.word()))
    case 0x0C:
      c.at += 1
      return .integer(UInt64(try c.dword()))
    case 0x0E:
      c.at += 1
      return .integer(try c.qword())
    case 0x0D:
      c.at += 1
      var s: [UInt8] = []
      while true {
        let b = try c.byte()
        if b == 0 { break }
        s.append(b)
      }
      return .string(s)
    case 0x5B where try c.peek(1) == 0x30:  // Revision: the interpreter's
      c.at += 2
      return .integer(1)
    default:
      return nil
    }
  }

  /// A DataRefObject (§20.2.3): a constant, a buffer, or a package of
  /// them and names. Anything computed is kept as code.
  func dataObject(_ c: inout Cursor, scope: Int, depth: Int, ns: Namespace) throws(ACPIError) -> Value {
    guard depth < maximumDepth else { throw ACPIError.tooDeep }
    let start = c.at
    if let v = try constant(&c) { return v }
    switch try c.peek() {
    case 0x11:  // Buffer: PkgLength, size, then bytes (the rest zero)
      c.at += 1
      let end = try c.pkgEnd()
      guard case .integer(let size)? = try constant(&c) else {
        c.at = end
        return .deferred(Code(table: table, start: start, end: end), scope: scope)
      }
      guard c.at <= end else { throw c.malformed() }  // the size ran past the buffer's own package
      let given = Array(c.bytes[c.at..<end])
      c.at = end
      guard size <= 1 << 24 else { throw c.malformed() }
      let n = Int(size)
      return .buffer(given.count >= n ? Array(given[..<n]) : given + [UInt8](repeating: 0, count: n - given.count))
    case 0x12, 0x13:  // Package, VarPackage
      let variable = try c.byte() == 0x13
      let end = try c.pkgEnd()
      var count: Int
      if variable {
        guard case .integer(let n)? = try constant(&c), n <= 1 << 16 else {
          c.at = end
          return .deferred(Code(table: table, start: start, end: end), scope: scope)
        }
        count = Int(n)
      } else {
        count = Int(try c.byte())
      }
      var elements: [Value] = []
      while c.at < end {
        if try c.atName() {
          elements.append(.name(try c.nameString(), scope: scope))
        } else {
          elements.append(try dataObject(&c, scope: scope, depth: depth + 1, ns: ns))
        }
      }
      guard c.at == end else { throw c.malformed() }
      // Elements past those given are uninitialized (§19.6.101): zero
      // here until A0c has the type for them.
      while elements.count < count { elements.append(.integer(0)) }
      return .package(elements)
    default:
      try skipTermArg(&c, scope: scope, depth: depth, ns: ns)
      return .deferred(Code(table: table, start: start, end: c.at), scope: scope)
    }
  }

  // MARK: Decoding code for its extent

  /// A statement: any term that isn't a definition handled above (§20.2.5).
  func skipStatement(_ c: inout Cursor, scope: Int, depth: Int, ns: Namespace) throws(ACPIError) {
    guard depth < maximumDepth else { throw ACPIError.tooDeep }
    let start = c.at
    let op = try c.peek()
    switch op {
    case 0xA0:  // If, and an Else straight after it
      c.at += 1
      c.at = try c.pkgEnd()
      if c.at < c.end, try c.peek() == 0xA1 {
        c.at += 1
        c.at = try c.pkgEnd()
      }
    case 0xA1, 0xA2:  // Else (alone: malformed but harmless), While
      c.at += 1
      c.at = try c.pkgEnd()
    case 0x10, 0x14:  // Scope and Method inside code: their extent
      c.at += 1
      c.at = try c.pkgEnd()
    case 0x08:  // Name inside code
      c.at += 1
      _ = try c.nameString()
      _ = try dataObject(&c, scope: scope, depth: depth + 1, ns: ns)
    case 0x06:
      c.at += 1
      _ = try c.nameString()
      _ = try c.nameString()
    case 0x15:
      c.at += 1
      _ = try c.nameString()
      try c.skip(2)
    case 0x9F, 0xA3, 0xA5, 0xCC: c.at += 1  // Continue, Noop, Break, BreakPoint
    case 0xA4:  // Return
      c.at += 1
      try skipTermArg(&c, scope: scope, depth: depth + 1, ns: ns)
    case 0x86:  // Notify
      c.at += 1
      try skipSuperName(&c, scope: scope, depth: depth + 1, ns: ns)
      try skipTermArg(&c, scope: scope, depth: depth + 1, ns: ns)
    case 0x5B:
      switch try c.peek(1) {
      case 0x82, 0x83, 0x84, 0x85, 0x81, 0x86, 0x87:  // containers and fields: a package
        c.at += 2
        c.at = try c.pkgEnd()
      case 0x01:
        c.at += 2
        _ = try c.nameString()
        try c.skip(1)
      case 0x02:
        c.at += 2
        _ = try c.nameString()
      case 0x80:
        c.at += 2
        _ = try c.nameString()
        try c.skip(1)
        try skipTermArgs(&c, 2, scope: scope, depth: depth, ns: ns)
      case 0x88:
        c.at += 2
        _ = try c.nameString()
        try skipTermArgs(&c, 3, scope: scope, depth: depth, ns: ns)
      case 0x32:  // Fatal: type, code, argument
        c.at += 2
        try c.skip(5)
        try skipTermArg(&c, scope: scope, depth: depth + 1, ns: ns)
      case 0x20:  // Load: a name, a target
        c.at += 2
        _ = try c.nameString()
        try skipTarget(&c, scope: scope, depth: depth + 1, ns: ns)
      case 0x21, 0x22:  // Stall, Sleep
        c.at += 2
        try skipTermArg(&c, scope: scope, depth: depth + 1, ns: ns)
      case 0x24, 0x26, 0x27, 0x2A:  // Signal, Reset, Release, Unload
        c.at += 2
        try skipSuperName(&c, scope: scope, depth: depth + 1, ns: ns)
      default:
        try skipTermArg(&c, scope: scope, depth: depth, ns: ns)
      }
    default:
      // An expression as a statement (Store, Increment, a call...).
      try skipTermArg(&c, scope: scope, depth: depth, ns: ns)
    }
    guard c.at > start else { throw c.malformed() }
  }

  func skipTermArgs(_ c: inout Cursor, _ n: Int, scope: Int, depth: Int, ns: Namespace) throws(ACPIError) {
    for _ in 0..<n { try skipTermArg(&c, scope: scope, depth: depth + 1, ns: ns) }
  }

  /// A TermArg (§20.2.5): data, a local or argument, a name (a method
  /// call if it names a method), or an expression opcode.
  func skipTermArg(_ c: inout Cursor, scope: Int, depth: Int, ns: Namespace) throws(ACPIError) {
    guard depth < maximumDepth else { throw ACPIError.tooDeep }
    if try c.atName() {
      let path = try c.nameString()
      if let node = ns.resolve(path, from: scope), let args = ns.methodArgs(node) {
        try skipTermArgs(&c, args, scope: scope, depth: depth, ns: ns)
      }
      return
    }
    if try constant(&c) != nil { return }
    let start = c.at
    let op = try c.byte()
    let d = depth + 1
    switch op {
    case 0x60...0x6E: return  // Local0-7, Arg0-6
    case 0x11, 0x12, 0x13:  // Buffer, Package, VarPackage
      c.at = try c.pkgEnd()
    case 0x70:  // Store
      try skipTermArg(&c, scope: scope, depth: d, ns: ns)
      try skipSuperName(&c, scope: scope, depth: d, ns: ns)
    case 0x71, 0x75, 0x76, 0x87, 0x8E:  // RefOf, Increment, Decrement, SizeOf, ObjectType
      try skipSuperName(&c, scope: scope, depth: d, ns: ns)
    case 0x72, 0x73, 0x74, 0x77, 0x79, 0x7A, 0x7B, 0x7C, 0x7D, 0x7E, 0x7F, 0x84, 0x85, 0x88:
      // Add, Concat, Subtract, Multiply, ShiftLeft/Right, And, NAnd, Or,
      // NOr, Xor, ConcatRes, Mod, Index: two operands and a target
      try skipTermArgs(&c, 2, scope: scope, depth: depth, ns: ns)
      try skipTarget(&c, scope: scope, depth: d, ns: ns)
    case 0x78:  // Divide: two targets
      try skipTermArgs(&c, 2, scope: scope, depth: depth, ns: ns)
      try skipTarget(&c, scope: scope, depth: d, ns: ns)
      try skipTarget(&c, scope: scope, depth: d, ns: ns)
    case 0x80, 0x81, 0x82, 0x96, 0x97, 0x98, 0x99:
      // Not, FindSetLeft/RightBit, ToBuffer, ToDecimal/HexString, ToInteger
      try skipTermArg(&c, scope: scope, depth: d, ns: ns)
      try skipTarget(&c, scope: scope, depth: d, ns: ns)
    case 0x83:  // DerefOf
      try skipTermArg(&c, scope: scope, depth: d, ns: ns)
    case 0x89:  // Match: package, op, operand, op, operand, start
      try skipTermArg(&c, scope: scope, depth: d, ns: ns)
      try c.skip(1)
      try skipTermArg(&c, scope: scope, depth: d, ns: ns)
      try c.skip(1)
      try skipTermArgs(&c, 2, scope: scope, depth: depth, ns: ns)
    case 0x8A, 0x8B, 0x8C, 0x8D, 0x8F:  // CreateD/W/B/Bit/QWordField
      try skipTermArgs(&c, 2, scope: scope, depth: depth, ns: ns)
      _ = try c.nameString()
    case 0x90, 0x91, 0x93, 0x94, 0x95:  // LAnd, LOr, LEqual, LGreater, LLess
      try skipTermArgs(&c, 2, scope: scope, depth: depth, ns: ns)
    case 0x92:  // LNot (and LNotEqual etc. as LNot of them)
      try skipTermArg(&c, scope: scope, depth: d, ns: ns)
    case 0x9C:  // ToString: source, length, target
      try skipTermArgs(&c, 2, scope: scope, depth: depth, ns: ns)
      try skipTarget(&c, scope: scope, depth: d, ns: ns)
    case 0x9D:  // CopyObject: source, simple name
      try skipTermArg(&c, scope: scope, depth: d, ns: ns)
      try skipSuperName(&c, scope: scope, depth: d, ns: ns)
    case 0x9E:  // Mid
      try skipTermArgs(&c, 3, scope: scope, depth: depth, ns: ns)
      try skipTarget(&c, scope: scope, depth: d, ns: ns)
    case 0x5B:
      let ext = try c.byte()
      switch ext {
      case 0x12:  // CondRefOf
        try skipSuperName(&c, scope: scope, depth: d, ns: ns)
        try skipTarget(&c, scope: scope, depth: d, ns: ns)
      case 0x13:  // CreateField
        try skipTermArgs(&c, 3, scope: scope, depth: depth, ns: ns)
        _ = try c.nameString()
      case 0x1F:  // LoadTable
        try skipTermArgs(&c, 6, scope: scope, depth: depth, ns: ns)
      case 0x23:  // Acquire: mutex, timeout
        try skipSuperName(&c, scope: scope, depth: d, ns: ns)
        try c.skip(2)
      case 0x25:  // Wait
        try skipSuperName(&c, scope: scope, depth: d, ns: ns)
        try skipTermArg(&c, scope: scope, depth: d, ns: ns)
      case 0x28, 0x29:  // FromBCD, ToBCD
        try skipTermArg(&c, scope: scope, depth: d, ns: ns)
        try skipTarget(&c, scope: scope, depth: d, ns: ns)
      case 0x30, 0x31, 0x33: return  // Revision, Debug, Timer
      default:
        throw ACPIError.unknown(0x5B00 | UInt16(ext), start)
      }
    default:
      throw ACPIError.unknown(UInt16(op), start)
    }
  }

  /// A SuperName (§20.2.2): a name (not called), a local or argument,
  /// Debug, or a reference-producing expression.
  func skipSuperName(_ c: inout Cursor, scope: Int, depth: Int, ns: Namespace) throws(ACPIError) {
    guard depth < maximumDepth else { throw ACPIError.tooDeep }
    if try c.atName() {
      _ = try c.nameString()
      return
    }
    switch try c.peek() {
    case 0x60...0x6E: c.at += 1
    case 0x5B where try c.peek(1) == 0x31: c.at += 2  // Debug
    default: try skipTermArg(&c, scope: scope, depth: depth, ns: ns)  // RefOf, DerefOf, Index...
    }
  }

  /// A Target: a SuperName, or NullName for none.
  func skipTarget(_ c: inout Cursor, scope: Int, depth: Int, ns: Namespace) throws(ACPIError) {
    if try c.peek() == 0x00 {
      c.at += 1
      return
    }
    try skipSuperName(&c, scope: scope, depth: depth, ns: ns)
  }
}
