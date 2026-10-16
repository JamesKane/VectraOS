// SPDX-License-Identifier: BSD-3-Clause

// The AML interpreter (ACPI 6.5 §19, §20): it runs AML straight from the
// table's bytes, as the loader decodes it, with no tree in between.
// Conversions and stores follow §19.3.5.4-.8; each operator its §19.6
// entry. Field units are read and written through their regions
// (Regions.swift).

/// What a statement leaves the code around it to do.
enum Flow {
  case next
  case breakLoop
  case continueLoop
  case returned(Datum)
}

/// A method call's state.
struct Frame {
  /// This call's serial number (Namespace.frameSerial).
  var serial = 0
  var locals = [Datum](repeating: .uninitialized, count: 8)
  var args = [Datum](repeating: .uninitialized, count: 7)
  /// The scope its names are looked up from (the method's node, or the
  /// scope of load-time code).
  var scope: Int
  /// Nodes its definitions made, which go when it returns; nil for
  /// load-time code, whose definitions stay.
  var temporaries: [Int]?
}

/// Where a SuperName or Target puts a value.
enum Location {
  case none
  case local(Int)
  case arg(Int)
  case node(Int)
  case debug
  case reference(Reference)
}

typealias Runner = (inout Namespace, Code, Int) throws(ACPIError) -> Void

// How deep running code may go. Real firmware is shallow: calling every
// method in the corpus reached 14 levels of expressions, 9 of statements
// and 7 calls; these allow over four times that. They bound the native
// stack a worst case needs (RobustnessTests measures it).
/// Method calls in progress.
let maximumCalls = 32
/// Expressions inside expressions, across calls.
let maximumExpressionDepth = 64
/// Statement lists (If, While bodies) inside each other, across calls.
let maximumStatementNesting = 64

struct Machine<Host: ACPIHost> {
  let host: Host
  var frames: [Frame] = []
  /// Iterations a single While may take before it's abandoned.
  var loopLimit = 1 << 20
  /// How deep expressions are nested now.
  var depth = 0
  /// How deep statement lists are nested now.
  var nesting = 0
  /// How deep field accesses are nested (an index field's index is itself a field).
  var fieldDepth = 0
  /// Statements and expressions run so far, and the budget.
  var steps = 0
  var stepLimit = 1 << 26
  var loopTimeout: UInt64 = 300_000_000
  /// Regions and Names being evaluated now: met again, they depend on themselves.
  var evaluating: [Int] = []

  /// The largest string or buffer the interpreter makes.
  static var maximumObjectBytes: Int { 1 << 24 }

  init(host: Host, loopLimit: Int = 1 << 20) {
    self.host = host
    self.loopLimit = loopLimit
  }

  init(host: Host, _ ns: Namespace) {
    self.host = host
    loopLimit = ns.loopLimit
    stepLimit = ns.stepLimit
    loopTimeout = ns.loopTimeout
  }

  /// A new call frame, with its serial number.
  mutating func push(_ scope: Int, _ temporaries: [Int]?, _ ns: inout Namespace) {
    ns.frameSerial += 1
    frames.append(Frame(serial: ns.frameSerial, scope: scope, temporaries: temporaries))
  }

  /// The frame with this serial number, if its call hasn't returned.
  func frameIndex(_ serial: Int) throws(ACPIError) -> Int {
    var i = frames.count - 1
    while i >= 0 {
      if frames[i].serial == serial { return i }
      i -= 1
    }
    throw ACPIError.uninitialized  // a reference that outlived its call
  }

  mutating func step() throws(ACPIError) {
    steps += 1
    guard steps <= stepLimit else { throw ACPIError.stepLimit }
  }

  /// Follows references to what they finally point at (a few at most:
  /// one that leads back to itself is caught).
  mutating func resolved(_ d: Datum, _ ns: inout Namespace) throws(ACPIError) -> Datum {
    var v = d
    for _ in 0..<32 {
      guard case .reference(let r) = v else { return v }
      v = try read(r, &ns)
    }
    throw ACPIError.recursive
  }

  func checkSize(_ n: Int) throws(ACPIError) {
    guard n <= Self.maximumObjectBytes else { throw ACPIError.tooLarge }
  }

  var frame: Int { frames.count - 1 }

  /// What definitions inside code use to run code of their own (a Device
  /// defined in a method, with load-time code in it).
  var runner: Runner {
    let host = self.host
    return { (ns: inout Namespace, code: Code, scope: Int) throws(ACPIError) in
      var m = Machine(host: host, ns)
      try m.runLoadCode(&ns, code, scope)
    }
  }

  func mask(_ ns: Namespace) -> UInt64 { ns.integerBits == 32 ? 0xFFFF_FFFF : UInt64.max }
  func truth(_ b: Bool, _ ns: Namespace) -> Datum { .integer(b ? mask(ns) : 0) }

  // MARK: Running code

  mutating func runLoadCode(_ ns: inout Namespace, _ code: Code, _ scope: Int) throws(ACPIError) {
    push(scope, nil, &ns)
    defer { frames.removeLast() }
    var c = Cursor(bytes: ns.tables[code.table], at: code.start, end: code.end)
    switch try termList(&c, end: code.end, table: code.table, ns: &ns) {
    case .breakLoop, .continueLoop: throw ACPIError.misplacedBreak
    default: break
    }
  }

  /// Calls a method (or reads any other object) with `args`.
  mutating func call(_ node: Int, _ args: [Datum], _ ns: inout Namespace) throws(ACPIError) -> Datum {
    switch ns.nodes[node].object {
    case .builtinMethod:
      // _OSI (§5.7.2): whether the OS claims the interface named.
      guard let name = args.first else { throw ACPIError.typeMismatch }
      return truth(host.supportsInterface(try stringValue(name, &ns)), ns)
    case .method(_, _, _, let body):
      guard frames.count < maximumCalls else { throw ACPIError.callTooDeep }
      push(node, [], &ns)
      for (i, a) in args.prefix(7).enumerated() { frames[frame].args[i] = a }
      var c = Cursor(bytes: ns.tables[body.table], at: body.start, end: body.end)
      let flow: Flow
      do {
        flow = try termList(&c, end: body.end, table: body.table, ns: &ns)
      } catch {
        leave(&ns)
        throw error
      }
      leave(&ns)
      switch flow {
      case .returned(let v): return v
      case .next: return .uninitialized
      default: throw ACPIError.misplacedBreak
      }
    default:
      return try readNamed(node, &ns)
    }
  }

  /// A method's end: its temporary objects go.
  mutating func leave(_ ns: inout Namespace) {
    for n in (frames[frame].temporaries ?? []).reversed() { ns.unlink(n) }
    frames.removeLast()
  }

  mutating func termList(_ c: inout Cursor, end: Int, table: Int, ns: inout Namespace) throws(ACPIError) -> Flow {
    nesting += 1
    defer { nesting -= 1 }
    guard nesting < maximumStatementNesting else { throw ACPIError.tooDeep }
    while c.at < end {
      let flow = try statement(&c, table: table, ns: &ns)
      if case .next = flow { continue }
      return flow
    }
    return .next
  }

  /// A definition met in code: the loader makes it, and if this is a
  /// method, what it made goes when the method returns. Operands the
  /// loader kept as code (a region's offset and length, a bank value, a
  /// Name's computed value) are evaluated now, in this frame: they may use
  /// its locals and arguments (§19.6.98: evaluated when the operator runs).
  mutating func define(_ c: inout Cursor, table: Int, ns: inout Namespace) throws(ACPIError) {
    let before = ns.nodes.count
    let loader = Loader(table: table, run: runner)
    try loader.term(&c, scope: frames[frame].scope, depth: frames.count, into: &ns)
    for n in before..<ns.nodes.count where ns.nodes[n].parent >= 0 {
      try materialize(n, &ns)
      if frames[frame].temporaries != nil { frames[frame].temporaries!.append(n) }
    }
  }

  /// A deferred operand, evaluated in this frame.
  mutating func now(_ v: Value, _ ns: inout Namespace) throws(ACPIError) -> Value {
    guard case .deferred(let code, _) = v else { return v }
    var c = Cursor(bytes: ns.tables[code.table], at: code.start, end: code.end)
    switch try evaluate(&c, ns: &ns) {
    case .integer(let i): return .integer(i)
    case .string(let s): return .string(s)
    case .buffer(let b): return .buffer(b.bytes)
    default: throw ACPIError.typeMismatch
    }
  }

  mutating func materialize(_ n: Int, _ ns: inout Namespace) throws(ACPIError) {
    let table = ns.nodes[n].table
    switch ns.nodes[n].object {
    case .region(let space, let offset, let length):
      ns.setObject(n, .region(space: space, offset: try now(offset, &ns), length: try now(length, &ns)), table: table)
    case .dataRegion(let signature, let oem, let oemTable):
      ns.setObject(n, .dataRegion(signature: try now(signature, &ns), oemID: try now(oem, &ns),
                                  oemTableID: try now(oemTable, &ns)), table: table)
    case .field(var f):
      if case .bank(let region, let bank, let value) = f.source {
        f.source = .bank(region: region, bank: bank, value: try now(value, &ns))
        ns.setObject(n, .field(f), table: table)
      }
    case .value(.deferred(let code, _)):
      var c = Cursor(bytes: ns.tables[code.table], at: code.start, end: code.end)
      ns.data[n] = try evaluate(&c, ns: &ns)
    default: break
    }
  }

  mutating func statement(_ c: inout Cursor, table: Int, ns: inout Namespace) throws(ACPIError) -> Flow {
    try step()
    let op = try c.peek()
    switch op {
    case 0x10, 0x14, 0x08, 0x06, 0x15:  // Scope, Method, Name, Alias, External
      try define(&c, table: table, ns: &ns)
    case 0xA0:  // If [Else]
      c.at += 1
      let end = try c.pkgEnd()
      let holds = try integerValue(try evaluate(&c, ns: &ns), &ns) != 0
      var flow = Flow.next
      if holds { flow = try termList(&c, end: end, table: table, ns: &ns) }
      c.at = end
      if c.at < c.end, try c.peek() == 0xA1 {
        c.at += 1
        let elseEnd = try c.pkgEnd()
        if !holds { flow = try termList(&c, end: elseEnd, table: table, ns: &ns) }
        c.at = elseEnd
      }
      return flow
    case 0xA1:  // Else without its If: nothing to run
      c.at += 1
      c.at = try c.pkgEnd()
    case 0xA2:  // While
      c.at += 1
      let end = try c.pkgEnd()
      let top = c.at
      var iterations = 0
      let started = host.timer()
      while true {
        c.at = top
        guard try integerValue(try evaluate(&c, ns: &ns), &ns) != 0 else { break }
        iterations += 1
        guard iterations <= loopLimit, host.timer() &- started <= loopTimeout else { throw ACPIError.loopLimit }
        let flow = try termList(&c, end: end, table: table, ns: &ns)
        if case .breakLoop = flow { break }
        if case .returned = flow { return flow }
      }
      c.at = end
    case 0x9F:
      c.at += 1
      return .continueLoop
    case 0xA5:
      c.at += 1
      return .breakLoop
    case 0xA3, 0xCC: c.at += 1  // Noop, BreakPoint
    case 0xA4:
      c.at += 1
      return .returned(try evaluate(&c, ns: &ns))
    case 0x86:  // Notify (object, value)
      c.at += 1
      let target = try superName(&c, ns: &ns)
      let value = try integerValue(try evaluate(&c, ns: &ns), &ns)
      guard case .node(let n) = target else { throw ACPIError.typeMismatch }
      host.notify(n, value)
    case 0x5B:
      switch try c.peek(1) {
      case 0x82, 0x83, 0x84, 0x85, 0x01, 0x02, 0x80, 0x88, 0x81, 0x86, 0x87:
        try define(&c, table: table, ns: &ns)
      case 0x32:  // Fatal (type, code, argument)
        c.at += 2
        let type = try c.byte()
        let code = try c.dword()
        host.fatal(type: type, code: code, argument: try integerValue(try evaluate(&c, ns: &ns), &ns))
      case 0x21:  // Stall (microseconds)
        c.at += 2
        host.stall(microseconds: try integerValue(try evaluate(&c, ns: &ns), &ns))
      case 0x22:  // Sleep (milliseconds)
        c.at += 2
        host.sleep(milliseconds: try integerValue(try evaluate(&c, ns: &ns), &ns))
      case 0x24:  // Signal (event)
        c.at += 2
        let n = try namedTarget(&c, ns: &ns)
        ns.data[n] = .integer((try counter(n, ns)) + 1)
      case 0x26:  // Reset (event)
        c.at += 2
        ns.data[try namedTarget(&c, ns: &ns)] = .integer(0)
      case 0x27:  // Release (mutex)
        c.at += 2
        try release(try namedTarget(&c, ns: &ns), &ns)
      case 0x20, 0x2A:  // Load, Unload: tables from regions, in A0d
        throw ACPIError.unsupported
      default:
        _ = try evaluate(&c, ns: &ns)
      }
    default:
      _ = try evaluate(&c, ns: &ns)  // an expression as a statement
    }
    return .next
  }

  // MARK: Expressions

  mutating func evaluate(_ c: inout Cursor, ns: inout Namespace) throws(ACPIError) -> Datum {
    depth += 1
    defer { depth -= 1 }
    guard depth < maximumExpressionDepth else { throw ACPIError.tooDeep }
    try step()
    if try c.atName() {
      let path = try c.nameString()
      guard let node = ns.resolve(path, from: frames[frame].scope) else { throw ACPIError.notFound }
      if let n = ns.methodArgs(node) {
        var args: [Datum] = []
        for _ in 0..<n { args.append(try evaluate(&c, ns: &ns)) }
        if case .external = ns.nodes[node].object { throw ACPIError.notFound }  // never defined
        return try call(node, args, &ns)
      }
      return try readNamed(node, &ns)
    }
    if let v = try Loader(table: 0).constant(&c) {
      if case .integer(let i) = v { return .integer(i & mask(ns)) }
      if case .string(let s) = v { return .string(s) }
      return .uninitialized
    }
    let op = try c.byte()
    switch op {
    case 0x60...0x67:
      return frames[frame].locals[Int(op - 0x60)]
    case 0x68...0x6E:
      let a = frames[frame].args[Int(op - 0x68)]
      if case .reference(let r) = a { return try read(r, &ns) }  // ArgX dereferences (§19.3.5.8.1)
      return a
    case 0x11:  // Buffer (size) { bytes }
      let end = try c.pkgEnd()
      let size = try integerValue(try evaluate(&c, ns: &ns), &ns)
      guard size <= 1 << 24, c.at <= end else { throw ACPIError.outOfBounds }
      var bytes = Array(c.bytes[c.at..<end])
      c.at = end
      if bytes.count < Int(size) { bytes += [UInt8](repeating: 0, count: Int(size) - bytes.count) }
      return .buffer(BufferObject(Array(bytes.prefix(Int(size)))))
    case 0x12, 0x13:  // Package, VarPackage
      let end = try c.pkgEnd()
      let count = op == 0x12 ? Int(try c.byte()) : Int(min(try integerValue(try evaluate(&c, ns: &ns), &ns), 1 << 16))
      var elements: [Datum] = []
      while c.at < end {
        if try c.atName() {
          let path = try c.nameString()
          elements.append(nameElement(path, scope: frames[frame].scope, ns))
        } else {
          elements.append(try evaluate(&c, ns: &ns))
        }
      }
      while elements.count < count { elements.append(.uninitialized) }
      return .package(PackageObject(elements))
    case 0x70:  // Store (source, destination)
      let v = try evaluate(&c, ns: &ns)
      try store(v, to: try superName(&c, ns: &ns), &ns)
      return v
    case 0x71:  // RefOf
      return .reference(try reference(to: try superName(&c, ns: &ns)))
    case 0x72, 0x74, 0x77, 0x79, 0x7A, 0x7B, 0x7C, 0x7D, 0x7E, 0x7F, 0x85:
      let a = try integerValue(try evaluate(&c, ns: &ns), &ns)
      let b = try integerValue(try evaluate(&c, ns: &ns), &ns)
      let r: UInt64
      switch op {
      case 0x72: r = a &+ b
      case 0x74: r = a &- b
      case 0x77: r = a &* b
      case 0x79: r = b >= UInt64(ns.integerBits) ? 0 : a << b
      case 0x7A: r = b >= UInt64(ns.integerBits) ? 0 : a >> b
      case 0x7B: r = a & b
      case 0x7C: r = ~(a & b)
      case 0x7D: r = a | b
      case 0x7E: r = ~(a | b)
      case 0x7F: r = a ^ b
      default:
        guard b != 0 else { throw ACPIError.divideByZero }
        r = a % b
      }
      let result = Datum.integer(r & mask(ns))
      try store(result, to: try target(&c, ns: &ns), &ns)
      return result
    case 0x73:  // Concatenate
      let a = try evaluate(&c, ns: &ns)
      let b = try evaluate(&c, ns: &ns)
      let result = try concatenate(a, b, &ns)
      try store(result, to: try target(&c, ns: &ns), &ns)
      return result
    case 0x84:  // ConcatenateResTemplate
      let a = try bufferBytes(try evaluate(&c, ns: &ns), &ns)
      let b = try bufferBytes(try evaluate(&c, ns: &ns), &ns)
      try checkSize(a.count + b.count)
      let result = Datum.buffer(BufferObject(resourceBody(a) + resourceBody(b) + [0x79, 0x00]))
      try store(result, to: try target(&c, ns: &ns), &ns)
      return result
    case 0x75, 0x76:  // Increment, Decrement
      let at = try superName(&c, ns: &ns)
      let v = try integerValue(try read(at, &ns), &ns)
      let result = Datum.integer((op == 0x75 ? v &+ 1 : v &- 1) & mask(ns))
      try store(result, to: at, &ns)
      return result
    case 0x78:  // Divide (dividend, divisor, remainder, quotient)
      let a = try integerValue(try evaluate(&c, ns: &ns), &ns)
      let b = try integerValue(try evaluate(&c, ns: &ns), &ns)
      guard b != 0 else { throw ACPIError.divideByZero }
      try store(.integer(a % b), to: try target(&c, ns: &ns), &ns)
      let q = Datum.integer(a / b)
      try store(q, to: try target(&c, ns: &ns), &ns)
      return q
    case 0x80, 0x81, 0x82:  // Not, FindSetLeftBit, FindSetRightBit
      let v = try integerValue(try evaluate(&c, ns: &ns), &ns)
      let r: UInt64
      switch op {
      case 0x80: r = ~v & mask(ns)
      case 0x81: r = v == 0 ? 0 : UInt64(64 - v.leadingZeroBitCount)
      default: r = v == 0 ? 0 : UInt64(v.trailingZeroBitCount + 1)
      }
      try store(.integer(r), to: try target(&c, ns: &ns), &ns)
      return .integer(r)
    case 0x83:  // DerefOf
      let v = try evaluate(&c, ns: &ns)
      switch v {
      case .reference(let r): return try read(r, &ns)
      case .string(let s):  // a name, from the current scope (§19.6.30)
        guard let n = ns.lookupRelative(s, from: frames[frame].scope) else { throw ACPIError.notFound }
        return try readNamed(n, &ns)
      default: throw ACPIError.typeMismatch
      }
    case 0x87:  // SizeOf
      return .integer(UInt64(try size(of: try read(try superName(&c, ns: &ns), &ns), &ns)))
    case 0x88:  // Index (source, index, destination)
      let source = try evaluate(&c, ns: &ns)
      let i = try integerValue(try evaluate(&c, ns: &ns), &ns)
      let r: Reference
      switch source {
      case .package(let p):
        guard i < UInt64(p.elements.count) else { throw ACPIError.outOfBounds }
        r = .element(p, Int(i))
      case .buffer(let b):
        guard i < UInt64(b.bytes.count) else { throw ACPIError.outOfBounds }
        r = .byte(b, Int(i))
      case .string(let s):
        // A string's character: as a byte of a buffer copy (strings are values).
        guard i < UInt64(s.count) else { throw ACPIError.outOfBounds }
        r = .byte(BufferObject(s), Int(i))
      default: throw ACPIError.typeMismatch
      }
      try store(.reference(r), to: try target(&c, ns: &ns), &ns)
      return .reference(r)
    case 0x89:  // Match
      return try match(&c, &ns)
    case 0x8A, 0x8B, 0x8C, 0x8D, 0x8F:  // CreateDWord/Word/Byte/Bit/QWordField
      let source = try evaluate(&c, ns: &ns)
      let index = try integerValue(try evaluate(&c, ns: &ns), &ns)
      let bits: Int
      switch op {
      case 0x8A: bits = 32
      case 0x8B: bits = 16
      case 0x8C: bits = 8
      case 0x8D: bits = 1
      default: bits = 64
      }
      let offset = op == 0x8D ? index : index &* 8
      try createField(&c, source, bitOffset: offset, bitLength: UInt64(bits), &ns)
      return .uninitialized
    case 0x8E:  // ObjectType
      return .integer(try typeCode(try superName(&c, ns: &ns), &ns))
    case 0x90, 0x91:  // LAnd, LOr
      let a = try integerValue(try evaluate(&c, ns: &ns), &ns) != 0
      let b = try integerValue(try evaluate(&c, ns: &ns), &ns) != 0
      return truth(op == 0x90 ? a && b : a || b, ns)
    case 0x92:  // LNot (and so LNotEqual, LLessEqual, LGreaterEqual)
      return truth(try integerValue(try evaluate(&c, ns: &ns), &ns) == 0, ns)
    case 0x93, 0x94, 0x95:  // LEqual, LGreater, LLess
      let a = try evaluate(&c, ns: &ns)
      let b = try evaluate(&c, ns: &ns)
      let order = try compare(a, b, &ns)
      return truth(op == 0x93 ? order == 0 : op == 0x94 ? order > 0 : order < 0, ns)
    case 0x96:  // ToBuffer
      let result = Datum.buffer(BufferObject(try bufferBytes(try evaluate(&c, ns: &ns), &ns, explicit: true)))
      try store(result, to: try target(&c, ns: &ns), &ns)
      return result
    case 0x97, 0x98:  // ToDecimalString, ToHexString
      let v = try evaluate(&c, ns: &ns)
      let result = Datum.string(try formatted(v, decimal: op == 0x97, &ns))
      try store(result, to: try target(&c, ns: &ns), &ns)
      return result
    case 0x99:  // ToInteger
      let v = try evaluate(&c, ns: &ns)
      let result = Datum.integer(try explicitInteger(v, &ns) & mask(ns))
      try store(result, to: try target(&c, ns: &ns), &ns)
      return result
    case 0x9C:  // ToString (buffer, length)
      let bytes = try bufferBytes(try evaluate(&c, ns: &ns), &ns)
      let length = try integerValue(try evaluate(&c, ns: &ns), &ns)
      var s: [UInt8] = []
      for b in bytes {
        if b == 0 || UInt64(s.count) >= length { break }
        s.append(b)
      }
      let result = Datum.string(s)
      try store(result, to: try target(&c, ns: &ns), &ns)
      return result
    case 0x9D:  // CopyObject (source, destination)
      let v = try evaluate(&c, ns: &ns)
      try copyObject(v, to: try superName(&c, ns: &ns), &ns)
      return v
    case 0x9E:  // Mid (source, index, length)
      let v = try evaluate(&c, ns: &ns)
      let index = try integerValue(try evaluate(&c, ns: &ns), &ns)
      let length = try integerValue(try evaluate(&c, ns: &ns), &ns)
      let bytes: [UInt8]
      let isString: Bool
      switch v {
      case .string(let s): (bytes, isString) = (s, true)
      default: (bytes, isString) = (try bufferBytes(v, &ns), false)
      }
      var part: [UInt8] = []
      if index < UInt64(bytes.count) {
        let start = Int(index)
        part = Array(bytes[start..<(start + Int(min(length, UInt64(bytes.count - start))))])
      }
      let result: Datum = isString ? .string(part) : .buffer(BufferObject(part))
      try store(result, to: try target(&c, ns: &ns), &ns)
      return result
    case 0x5B:
      let ext = try c.byte()
      switch ext {
      case 0x12:  // CondRefOf (source, destination)
        let found = try conditionalReference(&c, &ns)
        let dest = try target(&c, ns: &ns)
        guard let r = found else { return truth(false, ns) }
        try store(.reference(r), to: dest, &ns)
        return truth(true, ns)
      case 0x13:  // CreateField (source, bit index, bits, name)
        let source = try evaluate(&c, ns: &ns)
        let offset = try integerValue(try evaluate(&c, ns: &ns), &ns)
        let bits = try integerValue(try evaluate(&c, ns: &ns), &ns)
        try createField(&c, source, bitOffset: offset, bitLength: bits, &ns)
        return .uninitialized
      case 0x23:  // Acquire (mutex, timeout): True if it timed out
        let n = try namedTarget(&c, ns: &ns)
        _ = try c.word()
        try acquire(n, &ns)
        return truth(false, ns)
      case 0x25:  // Wait (event, timeout): True if it timed out
        let n = try namedTarget(&c, ns: &ns)
        _ = try evaluate(&c, ns: &ns)
        let count = try counter(n, ns)
        guard count > 0 else { return truth(true, ns) }  // nothing else runs to signal it
        ns.data[n] = .integer(count - 1)
        return truth(false, ns)
      case 0x28:  // FromBCD
        var v = try integerValue(try evaluate(&c, ns: &ns), &ns)
        var r: UInt64 = 0, scale: UInt64 = 1
        while v != 0 {
          r &+= (v & 0xF) &* scale
          scale &*= 10
          v >>= 4
        }
        try store(.integer(r & mask(ns)), to: try target(&c, ns: &ns), &ns)
        return .integer(r & mask(ns))
      case 0x29:  // ToBCD
        var v = try integerValue(try evaluate(&c, ns: &ns), &ns)
        var r: UInt64 = 0, shift: UInt64 = 0
        while v != 0 && shift < 64 {
          r |= (v % 10) << shift
          v /= 10
          shift += 4
        }
        try store(.integer(r & mask(ns)), to: try target(&c, ns: &ns), &ns)
        return .integer(r & mask(ns))
      case 0x33:  // Timer
        return .integer(host.timer() & mask(ns))
      case 0x1F:  // LoadTable: in A0d
        throw ACPIError.unsupported
      default:
        throw ACPIError.unknown(0x5B00 | UInt16(ext), c.at - 2)
      }
    default:
      throw ACPIError.unknown(UInt16(op), c.at - 1)
    }
  }

  /// A package's name element: a reference to what it names if that's
  /// there, else the path as a string, looked up when used.
  func nameElement(_ path: NamePath, scope: Int, _ ns: Namespace) -> Datum {
    if let n = ns.resolve(path, from: scope) { return .reference(.node(n)) }
    return .string(ns.text(path))
  }

  // MARK: Names, locations and references

  /// A SuperName: where a value goes (§20.2.2).
  mutating func superName(_ c: inout Cursor, ns: inout Namespace) throws(ACPIError) -> Location {
    if try c.atName() {
      let path = try c.nameString()
      guard let n = ns.resolve(path, from: frames[frame].scope) else { throw ACPIError.notFound }
      return .node(n)
    }
    let op = try c.peek()
    switch op {
    case 0x60...0x67:
      c.at += 1
      return .local(Int(op - 0x60))
    case 0x68...0x6E:
      c.at += 1
      return .arg(Int(op - 0x68))
    case 0x5B where try c.peek(1) == 0x31:
      c.at += 2
      return .debug
    case 0x83:  // DerefOf as a destination: where its reference points
      c.at += 1
      guard case .reference(let r) = try evaluate(&c, ns: &ns) else { throw ACPIError.typeMismatch }
      return .reference(r)
    default:  // Index, RefOf, a call: a reference
      let v = try evaluate(&c, ns: &ns)
      guard case .reference(let r) = v else { throw ACPIError.typeMismatch }
      return .reference(r)
    }
  }

  /// A Target: a SuperName, or NullName (0) for none.
  mutating func target(_ c: inout Cursor, ns: inout Namespace) throws(ACPIError) -> Location {
    if try c.peek() == 0x00 {
      c.at += 1
      return .none
    }
    return try superName(&c, ns: &ns)
  }

  /// A SuperName that must name a node (a mutex, an event).
  mutating func namedTarget(_ c: inout Cursor, ns: inout Namespace) throws(ACPIError) -> Int {
    switch try superName(&c, ns: &ns) {
    case .node(let n): return n
    case .reference(.node(let n)): return n
    case .arg(let i):
      if case .reference(.node(let n)) = frames[frame].args[i] { return n }
      if case .object(let n) = frames[frame].args[i] { return n }
      throw ACPIError.typeMismatch
    case .local(let i):
      if case .reference(.node(let n)) = frames[frame].locals[i] { return n }
      if case .object(let n) = frames[frame].locals[i] { return n }
      throw ACPIError.typeMismatch
    default: throw ACPIError.typeMismatch
    }
  }

  func reference(to location: Location) throws(ACPIError) -> Reference {
    switch location {
    case .node(let n): return .node(n)
    case .local(let i): return .local(i, frame: frames[frame].serial)
    case .arg(let i):
      if case .reference(let r) = frames[frame].args[i] { return r }
      return .arg(i, frame: frames[frame].serial)
    case .reference(let r): return r
    case .none, .debug: throw ACPIError.typeMismatch
    }
  }

  /// CondRefOf's source: a reference if the object exists, else nil.
  mutating func conditionalReference(_ c: inout Cursor, _ ns: inout Namespace) throws(ACPIError) -> Reference? {
    if try c.atName() {
      let path = try c.nameString()
      guard let n = ns.resolve(path, from: frames[frame].scope) else { return nil }
      if case .external = ns.nodes[n].object { return nil }  // declared, never defined
      return .node(n)
    }
    let at = try superName(&c, ns: &ns)
    if case .local(let i) = at, case .uninitialized = frames[frame].locals[i] { return nil }
    if case .arg(let i) = at, case .uninitialized = frames[frame].args[i] { return nil }
    return try reference(to: at)
  }

  // MARK: Reading

  /// What evaluating a name gives (not a method: those are called).
  mutating func readNamed(_ node: Int, _ ns: inout Namespace) throws(ACPIError) -> Datum {
    switch ns.nodes[node].object {
    case .value: return try value(of: node, &ns)
    case .bufferField:
      guard case .bufferField(let b, let off, let bits)? = ns.data[node] else { throw ACPIError.uninitialized }
      return readBits(b, off, bits, ns)
    case .field: return try readField(node, &ns)
    case .external: throw ACPIError.notFound
    default: return .object(node)
    }
  }

  /// A Name's value: made from its definition the first time it's used,
  /// then kept (and changed by stores).
  mutating func value(of node: Int, _ ns: inout Namespace) throws(ACPIError) -> Datum {
    if let d = ns.data[node] { return d }
    guard case .value(let v) = ns.nodes[node].object else { throw ACPIError.typeMismatch }
    guard !evaluating.contains(node) else { throw ACPIError.recursive }
    evaluating.append(node)
    defer { evaluating.removeLast() }
    let d = try datum(v, &ns)
    ns.data[node] = d
    return d
  }

  /// A load-time Value as a run-time Datum.
  mutating func datum(_ v: Value, _ ns: inout Namespace) throws(ACPIError) -> Datum {
    switch v {
    case .integer(let i): return .integer(i & mask(ns))
    case .string(let s): return .string(s)
    case .buffer(let b): return .buffer(BufferObject(b))
    case .package(let elements):
      var out: [Datum] = []
      for e in elements { out.append(try datum(e, &ns)) }
      return .package(PackageObject(out))
    case .name(let path, let scope): return nameElement(path, scope: scope, ns)
    case .deferred(let code, let scope):
      push(scope, nil, &ns)
      defer { frames.removeLast() }
      var c = Cursor(bytes: ns.tables[code.table], at: code.start, end: code.end)
      return try evaluate(&c, ns: &ns)
    }
  }

  mutating func read(_ location: Location, _ ns: inout Namespace) throws(ACPIError) -> Datum {
    switch location {
    case .local(let i): return frames[frame].locals[i]
    case .arg(let i):
      if case .reference(let r) = frames[frame].args[i] { return try read(r, &ns) }
      return frames[frame].args[i]
    case .node(let n): return try readNamed(n, &ns)
    case .reference(let r): return try read(r, &ns)
    case .none, .debug: throw ACPIError.typeMismatch
    }
  }

  mutating func read(_ r: Reference, _ ns: inout Namespace) throws(ACPIError) -> Datum {
    switch r {
    case .node(let n): return try readNamed(n, &ns)
    case .local(let i, let f): return frames[try frameIndex(f)].locals[i]
    case .arg(let i, let f): return frames[try frameIndex(f)].args[i]
    case .element(let p, let i): return p.elements[i]
    case .byte(let b, let i): return .integer(UInt64(b.bytes[i]))
    }
  }

  func readBits(_ b: BufferObject, _ offset: Int, _ bits: Int, _ ns: Namespace) -> Datum {
    var out = [UInt8](repeating: 0, count: (bits + 7) / 8)
    for k in 0..<bits {
      let at = offset + k
      if at / 8 < b.bytes.count, b.bytes[at / 8] & (1 << UInt8(at % 8)) != 0 { out[k / 8] |= 1 << UInt8(k % 8) }
    }
    if bits <= ns.integerBits {
      var v: UInt64 = 0
      for (i, byte) in out.enumerated() { v |= UInt64(byte) << (8 * UInt64(i)) }
      return .integer(v)
    }
    return .buffer(BufferObject(out))
  }

  func writeBits(_ b: BufferObject, _ offset: Int, _ bits: Int, _ source: [UInt8]) {
    for k in 0..<bits {
      let at = offset + k
      guard at / 8 < b.bytes.count else { return }
      let set = k / 8 < source.count && source[k / 8] & (1 << UInt8(k % 8)) != 0
      if set { b.bytes[at / 8] |= 1 << UInt8(at % 8) } else { b.bytes[at / 8] &= ~(1 << UInt8(at % 8)) }
    }
  }

  mutating func createField(_ c: inout Cursor, _ source: Datum, bitOffset: UInt64, bitLength: UInt64,
                            _ ns: inout Namespace) throws(ACPIError)
  {
    let path = try c.nameString()
    guard case .buffer(let b) = source else { throw ACPIError.typeMismatch }
    let total = UInt64(b.bytes.count) * 8
    guard bitLength > 0, bitLength <= total, bitOffset <= total - bitLength else { throw ACPIError.outOfBounds }
    let loader = Loader(table: 0)
    let before = ns.nodes.count
    guard let node = loader.define(path, in: frames[frame].scope, at: c.at, into: &ns) else { return }
    ns.setObject(node, .bufferField, table: ns.nodes[node].table)
    ns.data[node] = .bufferField(b, bitOffset: Int(bitOffset), bitLength: Int(bitLength))
    if frames[frame].temporaries != nil, node >= before { frames[frame].temporaries!.append(node) }
  }

  // MARK: Storing (§19.3.5.8)

  mutating func store(_ v: Datum, to location: Location, _ ns: inout Namespace) throws(ACPIError) {
    switch location {
    case .none: return
    case .debug: host.debug(try debugText(v, &ns))
    case .local(let i): frames[frame].locals[i] = copied(v)
    case .arg(let i):
      // An ArgX holding a reference writes through it (§19.3.5.8.1).
      if case .reference(let r) = frames[frame].args[i] { try store(v, through: r, &ns) } else {
        frames[frame].args[i] = copied(v)
      }
    case .node(let n): try storeNamed(v, n, &ns)
    case .reference(let r): try store(v, through: r, &ns)
    }
  }

  mutating func store(_ v: Datum, through r: Reference, _ ns: inout Namespace) throws(ACPIError) {
    switch r {
    case .node(let n): try storeNamed(v, n, &ns)
    case .local(let i, let f): frames[try frameIndex(f)].locals[i] = copied(v)
    case .arg(let i, let f): frames[try frameIndex(f)].args[i] = copied(v)
    case .element(let p, let i): p.elements[i] = copied(v)
    case .byte(let b, let i): b.bytes[i] = UInt8(truncatingIfNeeded: try integerValue(v, &ns))
    }
  }

  /// A store to a named object converts to the type it has (§19.3.5.8.3).
  mutating func storeNamed(_ v: Datum, _ n: Int, _ ns: inout Namespace) throws(ACPIError) {
    switch ns.nodes[n].object {
    case .value:
      switch try value(of: n, &ns) {
      case .integer: ns.data[n] = .integer(try integerValue(v, &ns))
      case .string: ns.data[n] = .string(try stringValue(v, &ns))
      case .buffer(let b):
        // The buffer keeps its length: the source is copied in, the rest
        // cleared, or truncated.
        let source = try bufferBytes(v, &ns)
        var bytes = [UInt8](repeating: 0, count: b.bytes.count)
        for i in 0..<min(source.count, bytes.count) { bytes[i] = source[i] }
        b.bytes = bytes
      default: ns.data[n] = copied(v)
      }
    case .bufferField:
      guard case .bufferField(let b, let off, let bits)? = ns.data[n] else { throw ACPIError.uninitialized }
      writeBits(b, off, bits, try fieldBytes(v, &ns))
    case .field: try writeField(n, try fieldBytes(v, &ns), &ns)
    case .scope where ns.nodes[n].table >= 0:
      ns.setObject(n, .value(.integer(0)), table: ns.nodes[n].table)
      ns.data[n] = copied(v)
    default: throw ACPIError.typeMismatch
    }
  }

  /// CopyObject: no conversion; the destination takes the type (§19.6.17).
  mutating func copyObject(_ v: Datum, to location: Location, _ ns: inout Namespace) throws(ACPIError) {
    switch location {
    case .node(let n), .reference(.node(let n)):
      switch ns.nodes[n].object {
      case .bufferField, .field: try storeNamed(v, n, &ns)  // fields keep their type
      default:
        ns.setObject(n, .value(.integer(0)), table: ns.nodes[n].table)
        ns.data[n] = copied(v)
      }
    case .arg(let i): frames[frame].args[i] = copied(v)
    default: try store(v, to: location, &ns)
    }
  }

  // MARK: Conversions (§19.3.5.7)

  func lengthOfInteger(_ ns: Namespace) -> Int { ns.integerBits / 8 }

  /// An operand as an integer: a string's leading hex digits (no "0x", up
  /// to the integer's width, none at all an error), a buffer's first
  /// bytes, least significant first.
  mutating func integerValue(_ d: Datum, _ ns: inout Namespace) throws(ACPIError) -> UInt64 {
    switch try resolved(d, &ns) {
    case .integer(let v): return v
    case .string(let s):
      guard !s.isEmpty else { throw ACPIError.typeMismatch }
      var v: UInt64 = 0
      for (i, ch) in s.enumerated() {
        guard i < 2 * lengthOfInteger(ns), let digit = hexDigit(ch) else { break }
        v = v << 4 | UInt64(digit)
      }
      return v
    case .buffer(let b):
      guard !b.bytes.isEmpty else { throw ACPIError.typeMismatch }
      var v: UInt64 = 0
      for (i, byte) in b.bytes.prefix(lengthOfInteger(ns)).enumerated() { v |= UInt64(byte) << (8 * UInt64(i)) }
      return v
    case .bufferField(let b, let off, let bits): return try integerValue(readBits(b, off, bits, ns), &ns)
    case .uninitialized: throw ACPIError.uninitialized
    default: throw ACPIError.typeMismatch
    }
  }

  func hexDigit(_ ch: UInt8) -> UInt8? {
    switch ch {
    case 0x30...0x39: ch - 0x30
    case 0x41...0x46: ch - 0x37
    case 0x61...0x66: ch - 0x57
    default: nil
    }
  }

  /// ToInteger (§19.6.139): decimal, or hex after "0x"; a buffer's first
  /// bytes.
  mutating func explicitInteger(_ d: Datum, _ ns: inout Namespace) throws(ACPIError) -> UInt64 {
    guard case .string(let s) = d else { return try integerValue(d, &ns) }
    guard !s.isEmpty else { throw ACPIError.typeMismatch }
    var digits = s[...]
    while digits.first == 0x20 || digits.first == 0x09 { digits = digits.dropFirst() }
    var v: UInt64 = 0
    if digits.count >= 2, digits.first == 0x30, digits.dropFirst().first == 0x78 || digits.dropFirst().first == 0x58 {
      for ch in digits.dropFirst(2) {
        guard let d = hexDigit(ch) else { break }
        v = v &<< 4 | UInt64(d)
      }
    } else {
      for ch in digits {
        guard ch >= 0x30 && ch <= 0x39 else { break }
        v = v &* 10 &+ UInt64(ch - 0x30)
      }
    }
    return v
  }

  /// An operand as a buffer: an integer's bytes (4 or 8), a string's
  /// bytes with its null terminator (an empty string for ToBuffer: none).
  mutating func bufferBytes(_ d: Datum, _ ns: inout Namespace, explicit: Bool = false) throws(ACPIError) -> [UInt8] {
    switch try resolved(d, &ns) {
    case .buffer(let b): return b.bytes
    case .integer(let v): return (0..<lengthOfInteger(ns)).map { UInt8(truncatingIfNeeded: v >> (8 * UInt64($0))) }
    case .string(let s): return explicit && s.isEmpty ? [] : s + [0]
    case .bufferField(let b, let off, let bits): return try bufferBytes(readBits(b, off, bits, ns), &ns)
    case .uninitialized: throw ACPIError.uninitialized
    default: throw ACPIError.typeMismatch
    }
  }

  /// What a store to a field writes: an integer's bytes, a buffer's, a
  /// string's characters.
  mutating func fieldBytes(_ d: Datum, _ ns: inout Namespace) throws(ACPIError) -> [UInt8] {
    if case .string(let s) = d { return s }
    return try bufferBytes(d, &ns)
  }

  /// An operand as a string: an integer as 8 or 16 hex digits, a buffer as
  /// two-digit hex numbers separated by spaces.
  mutating func stringValue(_ d: Datum, _ ns: inout Namespace) throws(ACPIError) -> [UInt8] {
    switch try resolved(d, &ns) {
    case .string(let s): return s
    case .integer(let v): return hex(v, digits: 2 * lengthOfInteger(ns))
    case .buffer(let b):
      try checkSize(b.bytes.count * 3)
      var out: [UInt8] = []
      for (i, byte) in b.bytes.enumerated() {
        if i > 0 { out.append(0x20) }
        out += hex(UInt64(byte), digits: 2)
      }
      return out
    case .bufferField(let bf, let off, let bits): return try stringValue(readBits(bf, off, bits, ns), &ns)
    case .uninitialized: throw ACPIError.uninitialized
    default: throw ACPIError.typeMismatch
    }
  }

  func hex(_ v: UInt64, digits: Int) -> [UInt8] {
    let table: [UInt8] = Array("0123456789ABCDEF".utf8)
    return (0..<digits).reversed().map { table[Int((v >> (4 * UInt64($0))) & 0xF)] }
  }

  func decimal(_ v: UInt64) -> [UInt8] {
    var v = v
    var out: [UInt8] = []
    repeat {
      out.append(UInt8(v % 10) + 0x30)
      v /= 10
    } while v != 0
    return out.reversed()
  }

  /// ToDecimalString and ToHexString (§19.6.137-.138): an integer in that
  /// base; a buffer's bytes, each so, separated by commas; a string as is.
  mutating func formatted(_ d: Datum, decimal useDecimal: Bool, _ ns: inout Namespace) throws(ACPIError) -> [UInt8] {
    switch d {
    case .string(let s): return s
    case .integer(let v): return useDecimal ? decimal(v) : hex(v, digits: 2 * lengthOfInteger(ns))
    default:
      var out: [UInt8] = []
      let bytes = try bufferBytes(d, &ns)
      try checkSize(bytes.count * 5)
      for (i, byte) in bytes.enumerated() {
        if i > 0 { out.append(0x2C) }
        out += useDecimal ? decimal(UInt64(byte)) : Array("0x".utf8) + hex(UInt64(byte), digits: 2)
      }
      return out
    }
  }

  /// Concatenate (§19.6.12): the result has the first operand's type.
  mutating func concatenate(_ a: Datum, _ b: Datum, _ ns: inout Namespace) throws(ACPIError) -> Datum {
    let result = try concatenated(a, b, &ns)
    switch result {
    case .string(let s): try checkSize(s.count)
    case .buffer(let x): try checkSize(x.bytes.count)
    default: break
    }
    return result
  }

  mutating func concatenated(_ a: Datum, _ b: Datum, _ ns: inout Namespace) throws(ACPIError) -> Datum {
    switch a {
    case .integer(let v):
      let first = (0..<lengthOfInteger(ns)).map { UInt8(truncatingIfNeeded: v >> (8 * UInt64($0))) }
      let w = try integerValue(b, &ns)
      return .buffer(BufferObject(first + (0..<lengthOfInteger(ns)).map { UInt8(truncatingIfNeeded: w >> (8 * UInt64($0))) }))
    case .string(let s): return .string(s + (try stringValue(b, &ns)))
    case .buffer(let x): return .buffer(BufferObject(x.bytes + (try bufferBytes(b, &ns))))
    default: return .string(try stringValue(a, &ns) + (try stringValue(b, &ns)))
    }
  }

  /// A resource template's descriptors, without its end tag (§6.4.2.9).
  func resourceBody(_ t: [UInt8]) -> [UInt8] {
    t.count >= 2 && t[t.count - 2] == 0x79 ? Array(t.dropLast(2)) : t
  }

  /// LEqual, LGreater, LLess: the second operand as the first's type;
  /// strings and buffers bytewise, then by length (§19.6.69-.72).
  mutating func compare(_ a: Datum, _ b: Datum, _ ns: inout Namespace) throws(ACPIError) -> Int {
    func order(_ x: [UInt8], _ y: [UInt8]) -> Int {
      for (p, q) in zip(x, y) where p != q { return p < q ? -1 : 1 }
      return x.count == y.count ? 0 : x.count < y.count ? -1 : 1
    }
    switch a {
    case .string(let s): return order(s, try stringValue(b, &ns))
    case .buffer(let x): return order(x.bytes, try bufferBytes(b, &ns))
    default:
      let x = try integerValue(a, &ns), y = try integerValue(b, &ns)
      return x == y ? 0 : x < y ? -1 : 1
    }
  }

  /// Match (§19.6.80): the first element from the start index that meets
  /// both conditions; Ones if none.
  mutating func match(_ c: inout Cursor, _ ns: inout Namespace) throws(ACPIError) -> Datum {
    let source = try evaluate(&c, ns: &ns)
    let op1 = try c.byte()
    let v1 = try evaluate(&c, ns: &ns)
    let op2 = try c.byte()
    let v2 = try evaluate(&c, ns: &ns)
    let start = try integerValue(try evaluate(&c, ns: &ns), &ns)
    guard case .package(let p) = source else { throw ACPIError.typeMismatch }
    func meets(_ e: Datum, _ op: UInt8, _ v: Datum, _ ns: inout Namespace) -> Bool {
      if op == 0 { return true }  // MTR
      // The element as the match object's type (§19.6.80); one that won't
      // convert doesn't match.
      guard let order = try? compare(v, e, &ns) else { return false }
      switch op {
      case 1: return order == 0  // MEQ: element == value
      case 2: return order >= 0  // MLE: element <= value
      case 3: return order > 0  // MLT
      case 4: return order <= 0  // MGE
      case 5: return order < 0  // MGT
      default: return false
      }
    }
    var i = Int(min(start, UInt64(p.elements.count)))
    while i < p.elements.count {
      let e = p.elements[i]
      switch e {
      case .integer, .string, .buffer:
        if meets(e, op1, v1, &ns) && meets(e, op2, v2, &ns) { return .integer(UInt64(i)) }
      default: break
      }
      i += 1
    }
    return .integer(mask(ns))
  }

  mutating func size(of d: Datum, _ ns: inout Namespace) throws(ACPIError) -> Int {
    switch try resolved(d, &ns) {
    case .buffer(let b): return b.bytes.count
    case .string(let s): return s.count
    case .package(let p): return p.elements.count
    default: throw ACPIError.typeMismatch
    }
  }

  /// ObjectType (§19.6.96, Table 19.36).
  mutating func typeCode(_ location: Location, _ ns: inout Namespace) throws(ACPIError) -> UInt64 {
    func ofNode(_ n: Int, _ ns: inout Namespace) throws(ACPIError) -> UInt64 {
      switch ns.nodes[n].object {
      case .scope: return 0
      case .value: return try value(of: n, &ns).typeCode
      case .field: return 5
      case .device: return 6
      case .event: return 7
      case .method, .builtinMethod: return 8
      case .mutex: return 9
      case .region, .dataRegion: return 10
      case .powerResource: return 11
      case .processor: return 12
      case .thermalZone: return 13
      case .bufferField: return 14
      case .external(let type, _): return UInt64(type)
      case .alias: return 0
      }
    }
    switch location {
    case .node(let n), .reference(.node(let n)): return try ofNode(n, &ns)
    case .debug: return 16
    default:
      let d = try read(location, &ns)
      if case .object(let n) = d { return try ofNode(n, &ns) }
      if case .reference(.node(let n)) = d { return try ofNode(n, &ns) }
      return d.typeCode
    }
  }

  /// A store to Debug, as text (§19.6.26): integers in hex, strings as
  /// they are, buffers as hex bytes.
  mutating func debugText(_ d: Datum, _ ns: inout Namespace) throws(ACPIError) -> [UInt8] {
    switch d {
    case .integer(let v): return Array("0x".utf8) + hex(v, digits: 2 * lengthOfInteger(ns))
    case .string(let s): return s
    case .buffer: return try stringValue(d, &ns)
    case .package(let p): return Array("[Package of ".utf8) + decimal(UInt64(p.elements.count)) + [0x5D]
    case .object(let n): return ns.path(n)
    case .reference(.node(let n)): return Array("[Reference to ".utf8) + ns.path(n) + [0x5D]
    default: return Array("[Object]".utf8)
    }
  }

  // MARK: Mutexes and events

  func counter(_ n: Int, _ ns: Namespace) throws(ACPIError) -> UInt64 {
    guard case .event = ns.nodes[n].object else { throw ACPIError.typeMismatch }
    if case .integer(let v)? = ns.data[n] { return v }
    return 0
  }

  /// Acquire: in sync-level order (§19.6.2, §19.6.87); a mutex already
  /// held is taken again. One thread runs AML here, so it never waits.
  mutating func acquire(_ n: Int, _ ns: inout Namespace) throws(ACPIError) {
    guard case .mutex(let level) = ns.nodes[n].object else { throw ACPIError.typeMismatch }
    if let i = ns.heldMutexes.lastIndex(where: { $0.node == n }) {
      ns.heldMutexes[i].count += 1
      return
    }
    if let top = ns.heldMutexes.last, top.syncLevel > Int(level) { throw ACPIError.mutexOrder }
    ns.heldMutexes.append((n, Int(level), 1))
  }

  mutating func release(_ n: Int, _ ns: inout Namespace) throws(ACPIError) {
    guard let i = ns.heldMutexes.lastIndex(where: { $0.node == n }) else { throw ACPIError.mutexOrder }
    ns.heldMutexes[i].count -= 1
    if ns.heldMutexes[i].count == 0 { ns.heldMutexes.remove(at: i) }
  }
}

extension Namespace {
  /// Loads a DSDT or SSDT and runs its load-time code where it stands, as
  /// ACPI requires (§5.4): an If around definitions decides whether they
  /// exist. Code that fails is noted (`codeFailed`) and loading goes on.
  public mutating func load<H: ACPIHost>(_ table: Table, host: H) throws(ACPIError) {
    let index = addTable(table.bytes)
    var c = Cursor(bytes: table.bytes, at: Table.headerSize, end: table.length)
    let loader = Loader(table: index, run: Machine(host: host, self).runner)
    try loader.termList(&c, end: c.end, scope: Self.root, depth: 0, into: &self)
  }

  /// Evaluates a node: a method is called with `args`; anything else is
  /// read.
  public mutating func evaluate<H: ACPIHost>(_ node: Int, _ args: [Datum] = [], host: H) throws(ACPIError) -> Datum {
    var m = Machine(host: host, self)
    m.push(Self.root, nil, &self)
    return try m.call(node, args, &self)
  }

  /// A path as text, for a name element nothing answers to yet.
  func text(_ path: NamePath) -> [UInt8] {
    var out: [UInt8] = path.fromRoot ? [0x5C] : []
    for _ in 0..<path.parents { out.append(0x5E) }
    for (i, s) in path.segments.enumerated() {
      if i > 0 { out.append(0x2E) }
      out += s.bytes
    }
    return out
  }

  /// A name given as text, from `scope` (DerefOf of a string, §19.6.30).
  func lookupRelative(_ text: [UInt8], from scope: Int) -> Int? {
    var path = NamePath()
    var rest = text[...]
    if rest.first == 0x5C {
      path.fromRoot = true
      rest = rest.dropFirst()
    }
    while rest.first == 0x5E {
      path.parents += 1
      rest = rest.dropFirst()
    }
    if !rest.isEmpty {
      for part in rest.split(separator: 0x2E, omittingEmptySubsequences: false) {
        var b = Array(part)
        guard b.count >= 1 && b.count <= 4 else { return nil }
        while b.count < 4 { b.append(0x5F) }
        path.segments.append(NameSeg(b))
      }
    }
    return resolve(path, from: scope)
  }
}

extension Datum {
  /// The integer, if this is one (for callers and tests).
  public var integer: UInt64? {
    if case .integer(let v) = self { return v }
    return nil
  }
  public var string: [UInt8]? {
    if case .string(let s) = self { return s }
    return nil
  }
  public var bytes: [UInt8]? {
    if case .buffer(let b) = self { return b.bytes }
    return nil
  }
  public var elements: [Datum]? {
    if case .package(let p) = self { return p.elements }
    return nil
  }
}
