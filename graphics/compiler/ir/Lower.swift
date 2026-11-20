// SPDX-License-Identifier: BSD-3-Clause

// SPIR-V to IR: the driver, types and layout, constants, memory and control
// flow. Arithmetic and the GLSL.std.450 instructions are in LowerOps.swift.
//
// What the lowering does:
// - Structs and arrays are flattened to their leaves (scalars, vectors and
//   pointers); loads and stores of an aggregate become one access a leaf.
// - Access chains become `ptradd` with byte offsets: explicit layouts come
//   from Offset and ArrayStride, natural layouts (Function, Private,
//   Workgroup memory with no decoration) follow scalar alignment, with
//   vectors aligned to their size rounded up to a power of two.
// - Builtin variables become `builtin` values; pointers into them are
//   followed symbolically and never exist as IR values.
// - OpPhi stays a phi (one a leaf); OpSelectionMerge and OpLoopMerge
//   become the header block's merge and continue annotations.
// - Function variables are `alloca`s; the mem2reg pass promotes them.
// - Specialization constants take their default (or the value passed in) and
//   are listed in the module's `specializations`.
// - Only functions the entry point calls are lowered, the entry first.

extension IRModule {
  /// Lower a SPIR-V module's entry point (by name; default the first
  /// GLCompute one) and the functions it calls.
  public static func lower(
    _ module: SPIRVModule, entryPoint: String? = nil, specialization: [(id: UInt32, bits: UInt64)] = []
  ) throws(CompileError) -> IRModule {
    var l = Lowerer(m: module, spec: specialization)
    try l.run(entryPoint: entryPoint)
    return l.out
  }
}

struct Sym {
  var builtin: Int
  var component: Int  // -1: the whole value
}

struct PhiFixup {
  var insts: [Int]  // one IR phi a leaf
  var incoming: [(value: UInt32, label: UInt32)]
  var at: SPIRVInstruction
}

struct Lowerer {
  var m: SPIRVModule
  var spec: [(id: UInt32, bits: UInt64)]
  var out = IRModule()
  var irIndex: [Int32] = []
  var queue: [UInt32] = []
  var globalIndex: [Int32] = []

  // The function being lowered.
  var f = Function(name: "", params: [], returns: .void)
  var lv: [[ValueID]] = []
  var sym: [Sym?] = []
  var blockOf: [Int32] = []
  var cur: BlockID = 0
  var phis: [PhiFixup] = []

  init(m: SPIRVModule, spec: [(id: UInt32, bits: UInt64)]) {
    self.m = m
    self.spec = spec
  }

  func fail(_ i: SPIRVInstruction, _ msg: String) -> CompileError {
    if i.result != 0 { return CompileError("\(i.name) %\(i.result): \(msg)") }
    return CompileError("\(i.name): \(msg)")
  }

  // MARK: driver

  mutating func run(entryPoint: String?) throws(CompileError) {
    var entry: SPIRVEntryPoint? = nil
    for e in m.entryPoints where entryPoint == nil || e.name == entryPoint! {
      if entryPoint == nil && e.model != 5 { continue }
      entry = e
      break
    }
    guard let e = entry else {
      if let n = entryPoint { throw CompileError("entry point \(n): not found") }
      if let first = m.entryPoints.first {
        throw CompileError(
          "OpEntryPoint \(first.name): execution model \(Supported.executionModelName(first.model)) is not supported yet (only GLCompute)"
        )
      }
      throw CompileError("module: no entry point")
    }
    guard e.model == 5 else {
      throw CompileError(
        "OpEntryPoint \(e.name): execution model \(Supported.executionModelName(e.model)) is not supported yet (only GLCompute)"
      )
    }
    var size: (UInt32, UInt32, UInt32)? = nil
    for em in m.executionModes where em.function == e.function {
      switch em.mode {
      case 17:
        guard em.operands.count == 3 else { throw CompileError("OpExecutionMode LocalSize: needs three sizes") }
        size = (em.operands[0], em.operands[1], em.operands[2])
      case 38: throw CompileError("OpExecutionMode LocalSizeId: not supported yet")
      case 18, 31: break  // LocalSizeHint, ContractionOff
      default: throw CompileError("OpExecutionMode \(em.mode): not supported for compute")
      }
    }
    guard let s = size else { throw CompileError("OpEntryPoint \(e.name): the compute shader has no LocalSize") }
    guard s.0 > 0 && s.1 > 0 && s.2 > 0 else { throw CompileError("OpExecutionMode LocalSize: a size is zero") }
    out.localSize = (x: s.0, y: s.1, z: s.2)
    out.entryName = e.name
    out.executionModel = e.model
    let none = SPIRVInstruction(op: Op.specConstant, type: 0, result: 0, operands: [])
    for c in m.constants {
      guard let c = c, c.isSpec, let id = c.specId, case .scalar(let sk) = try irType(c.type, none) else { continue }
      var bits: UInt64 = 0
      if case .scalar(let v) = c.kind { bits = v } else if case .bool(let b) = c.kind { bits = b ? 1 : 0 }
      for o in spec where o.id == id { bits = o.bits }
      recordSpec(id, .scalar(sk), bits)
    }
    irIndex = [Int32](repeating: -1, count: Int(m.bound))
    globalIndex = [Int32](repeating: -1, count: Int(m.bound))
    irIndex[Int(e.function)] = 0
    queue = [e.function]
    var next = 0
    while next < queue.count {
      let id = queue[next]
      next += 1
      try lowerFunction(id, name: next == 1 ? e.name : nil)
    }
    out.entry = 0
  }

  mutating func lowerFunction(_ id: UInt32, name: String?) throws(CompileError) {
    guard Int(id) < m.functionIndex.count, m.functionIndex[Int(id)] >= 0 else {
      throw CompileError("function %\(id): has no body")
    }
    let sf = m.functions[Int(m.functionIndex[Int(id)])]
    var params: [IRType] = []
    let head = SPIRVInstruction(op: Op.function, type: sf.returnType, result: id, operands: [])
    for p in sf.parameters {
      guard !isAggregate(p.type) else { throw fail(head, "a parameter of aggregate type is not supported yet") }
      params.append(try irType(p.type, head))
    }
    var ret = IRType.void
    if case .void? = m.type(sf.returnType) {} else {
      guard !isAggregate(sf.returnType) else { throw fail(head, "an aggregate return type is not supported yet") }
      ret = try irType(sf.returnType, head)
    }
    f = Function(name: name ?? m.name(of: id) ?? "f\(id)", params: params, returns: ret)
    lv = [[ValueID]](repeating: [], count: Int(m.bound))
    sym = [Sym?](repeating: nil, count: Int(m.bound))
    blockOf = [Int32](repeating: -1, count: Int(m.bound))
    phis = []
    for (n, p) in sf.parameters.enumerated() { lv[Int(p.id)] = [f.param(n)] }
    for b in sf.blocks {
      blockOf[Int(b.label)] = Int32(f.addBlock())
    }
    if irIndex[Int(id)] == 0 {
      guard params.isEmpty else { throw fail(head, "the entry point has parameters") }
      // Private variables with initializers are set at the start of the entry.
      cur = 0
      for v in m.variables where v.storage == StorageClass.private_ && v.initializer != 0 {
        guard case .pointer(_, let pointee)? = m.type(v.type) else { continue }
        let p = try variablePointer(v, head)
        let init_ = try leaves(v.initializer, head)
        let a = try sizeAlign(pointee, head).align
        try storeLeaves(pointee, ptr: p, off: 0, values: init_, at: 0, space: .private_, align: 0, volatile: false, head)
        _ = a
      }
    }
    for b in sf.blocks {
      cur = BlockID(blockOf[Int(b.label)])
      for i in b.instructions { try lowerInstruction(i) }
    }
    for p in phis {
      for (leaf, inst) in p.insts.enumerated() {
        var args: [ValueID] = []
        var blocks: [BlockID] = []
        for inc in p.incoming {
          let ls = try leaves(inc.value, p.at)
          guard leaf < ls.count else { throw fail(p.at, "incoming value %\(inc.value) has too few parts") }
          args.append(ls[leaf])
          blocks.append(BlockID(blockOf[Int(inc.label)]))
        }
        f.insts[inst].args = args
        f.insts[inst].blocks = blocks
      }
    }
    // The queue index is the function's slot: lowered in discovery order.
    out.functions.append(f)
  }

  // MARK: emission

  @discardableResult
  mutating func emit(_ op: IROp, _ type: IRType, _ args: [ValueID], imm: Int = 0, imm2: Int = 0) -> ValueID {
    f.append(Inst(op, type, args, imm: imm, imm2: imm2), to: cur)
  }

  mutating func cInt(_ s: Scalar, _ v: Int) -> ValueID { f.constant(s, UInt64(bitPattern: Int64(v))) }

  // MARK: types

  func isAggregate(_ t: UInt32) -> Bool {
    switch m.type(t) {
    case .structure?, .array?, .runtimeArray?: return true
    default: return false
    }
  }

  func addrSpace(_ storage: UInt32, _ i: SPIRVInstruction) throws(CompileError) -> AddrSpace {
    switch storage {
    case StorageClass.function: return .function
    case StorageClass.private_: return .private_
    case StorageClass.workgroup: return .workgroup
    case StorageClass.storageBuffer: return .storage
    case StorageClass.uniform: return .uniform
    case StorageClass.pushConstant: return .pushConstant
    case StorageClass.physicalStorageBuffer: return .global
    default: throw fail(i, "storage class \(StorageClass.name(storage)) pointers are not supported here")
    }
  }

  /// The IR type of a non-aggregate SPIR-V type.
  func irType(_ t: UInt32, _ i: SPIRVInstruction) throws(CompileError) -> IRType {
    guard let ty = m.type(t) else { throw fail(i, "%\(t) is not a type") }
    switch ty {
    case .void: return .void
    case .bool: return .bool
    case .int(let w, _):
      guard let s = Scalar.int(bits: w) else { throw fail(i, "\(w)-bit integers are not supported") }
      return .scalar(s)
    case .float(let w):
      switch w {
      case 16: return .scalar(.f16)
      case 32: return .scalar(.f32)
      case 64: return .scalar(.f64)
      default: throw fail(i, "\(w)-bit floats are not supported")
      }
    case .vector(let e, let n):
      guard case .scalar(let s) = try irType(e, i) else { throw fail(i, "a vector of non-scalars") }
      return .vector(s, n)
    case .pointer(let sc, _): return .ptr(try addrSpace(sc, i))
    case .structure, .array, .runtimeArray: throw fail(i, "an aggregate type has no single IR type")
    case .function: throw fail(i, "a function type has no value")
    }
  }

  func leafCount(_ t: UInt32, _ i: SPIRVInstruction) throws(CompileError) -> Int {
    switch m.type(t) {
    case .structure(let ms)?:
      var n = 0
      for x in ms { n += try leafCount(x, i) }
      return n
    case .array(let e, let len)?:
      return try leafCount(e, i) * Int(try evalInt(len, i))
    case .runtimeArray?: throw fail(i, "a runtime array has no value")
    default: return 1
    }
  }

  func leafTypes(_ t: UInt32, _ i: SPIRVInstruction, into: inout [IRType]) throws(CompileError) {
    switch m.type(t) {
    case .structure(let ms)?:
      for x in ms { try leafTypes(x, i, into: &into) }
    case .array(let e, let len)?:
      let n = Int(try evalInt(len, i))
      for _ in 0..<n { try leafTypes(e, i, into: &into) }
    case .runtimeArray?: throw fail(i, "a runtime array has no value")
    default: into.append(try irType(t, i))
    }
  }

  // MARK: layout

  static func alignUp(_ x: Int, _ a: Int) -> Int { (x + a - 1) / a * a }

  func sizeAlign(_ t: UInt32, _ i: SPIRVInstruction) throws(CompileError) -> (size: Int, align: Int) {
    guard let ty = m.type(t) else { throw fail(i, "%\(t) is not a type") }
    switch ty {
    case .bool: return (4, 4)
    case .int(let w, _): return (w / 8, w / 8)
    case .float(let w): return (w / 8, w / 8)
    case .vector(let e, let n):
      let (s, _) = try sizeAlign(e, i)
      let a = n == 3 ? 4 * s : n * s
      return (n * s, a)
    case .pointer(let sc, _):
      let sp = try addrSpace(sc, i)
      return (sp.pointerBytes, sp.pointerBytes)
    case .structure:
      let l = try structLayout(t, i)
      return (l.size, l.align)
    case .array(let e, let len):
      let (_, a) = try sizeAlign(e, i)
      return (try arrayStride(t, e, i) * Int(try evalInt(len, i)), a)
    case .runtimeArray(let e):
      let (_, a) = try sizeAlign(e, i)
      return (0, a)
    default: throw fail(i, "a type with no size")
    }
  }

  func arrayStride(_ array: UInt32, _ elem: UInt32, _ i: SPIRVInstruction) throws(CompileError) -> Int {
    if let s = m.decoration(array, Decor.arrayStride)?.first { return Int(s) }
    let (s, a) = try sizeAlign(elem, i)
    return Lowerer.alignUp(s, a)
  }

  func structLayout(_ t: UInt32, _ i: SPIRVInstruction) throws(CompileError) -> (offsets: [Int], size: Int, align: Int)
  {
    guard case .structure(let ms)? = m.type(t) else { throw fail(i, "%\(t) is not a struct") }
    var offsets: [Int] = []
    var off = 0
    var maxAlign = 1
    for (k, mt) in ms.enumerated() {
      let (s, a) = try sizeAlign(mt, i)
      if let o = m.memberDecoration(t, k, Decor.offset)?.first {
        off = Int(o)
      } else {
        off = Lowerer.alignUp(off, a)
      }
      offsets.append(off)
      off += s
      if a > maxAlign { maxAlign = a }
    }
    return (offsets, Lowerer.alignUp(off, maxAlign), maxAlign)
  }

  // MARK: constants

  /// A scalar integer or bool constant's value, with specialization.
  func evalInt(_ id: UInt32, _ i: SPIRVInstruction) throws(CompileError) -> UInt64 {
    guard let c = m.constant(id) else { throw fail(i, "%\(id) is not a constant") }
    if let s = c.specId, c.isSpec {
      for o in spec where o.id == s { return o.bits }
    }
    switch c.kind {
    case .bool(let b): return b ? 1 : 0
    case .scalar(let v): return v
    case .null: return 0
    case .specOp(let op, let o): return try evalSpecOp(op, o, c.type, i)
    case .composite: throw fail(i, "constant %\(id) is a composite, not a scalar")
    }
  }

  func intInfo(_ t: UInt32) -> (bits: Int, signed: Bool)? {
    switch m.type(t) {
    case .int(let w, let s)?: return (w, s)
    case .bool?: return (1, false)
    default: return nil
    }
  }

  func evalSpecOp(_ op: UInt16, _ o: [UInt32], _ type: UInt32, _ i: SPIRVInstruction) throws(CompileError) -> UInt64 {
    guard let (bits, _) = intInfo(type) else {
      throw fail(i, "OpSpecConstantOp \(OpTable.name(op)) on a non-integer type is not supported yet")
    }
    func mask(_ v: UInt64, _ w: Int) -> UInt64 { w >= 64 ? v : v & ((1 << UInt64(w)) - 1) }
    func sext(_ v: UInt64, _ w: Int) -> Int64 {
      w >= 64 ? Int64(bitPattern: v) : Int64(bitPattern: v << UInt64(64 - w)) >> Int64(64 - w)
    }
    func operandBits(_ k: Int) throws(CompileError) -> (UInt64, Int) {
      guard k < o.count else { throw fail(i, "OpSpecConstantOp: too few operands") }
      guard let ci = m.constant(o[k]), let info = intInfo(ci.type) else {
        throw fail(i, "OpSpecConstantOp operand %\(o[k]) is not an integer or bool constant")
      }
      return (try evalInt(o[k], i), info.bits)
    }
    switch op {
    case Op.sNegate: let (a, _) = try operandBits(0); return mask(0 &- a, bits)
    case Op.not: let (a, _) = try operandBits(0); return mask(~a, bits)
    case Op.logicalNot: let (a, _) = try operandBits(0); return a == 0 ? 1 : 0
    case Op.sConvert: let (a, w) = try operandBits(0); return mask(UInt64(bitPattern: sext(a, w)), bits)
    case Op.uConvert: let (a, _) = try operandBits(0); return mask(a, bits)
    case Op.select:
      let (c, _) = try operandBits(0)
      return try operandBits(c != 0 ? 1 : 2).0
    default: break
    }
    let (a, wa) = try operandBits(0)
    let (b, _) = try operandBits(1)
    switch op {
    case Op.iAdd: return mask(a &+ b, bits)
    case Op.iSub: return mask(a &- b, bits)
    case Op.iMul: return mask(a &* b, bits)
    case Op.uDiv where b != 0: return a / b
    case Op.uMod where b != 0: return a % b
    case Op.sDiv where b != 0: return mask(UInt64(bitPattern: sext(a, wa) / sext(b, wa)), bits)
    case Op.sRem where b != 0: return mask(UInt64(bitPattern: sext(a, wa) % sext(b, wa)), bits)
    case Op.shiftLeftLogical: return mask(a << b, bits)
    case Op.shiftRightLogical: return mask(a >> b, bits)
    case Op.shiftRightArithmetic: return mask(UInt64(bitPattern: sext(a, wa) >> Int64(b)), bits)
    case Op.bitwiseOr, Op.logicalOr: return a | b
    case Op.bitwiseAnd, Op.logicalAnd: return a & b
    case Op.bitwiseXor: return a ^ b
    case Op.logicalEqual, Op.iEqual: return a == b ? 1 : 0
    case Op.logicalNotEqual, Op.iNotEqual: return a != b ? 1 : 0
    case Op.uLessThan: return a < b ? 1 : 0
    case Op.uLessThanEqual: return a <= b ? 1 : 0
    case Op.uGreaterThan: return a > b ? 1 : 0
    case Op.uGreaterThanEqual: return a >= b ? 1 : 0
    case Op.sLessThan: return sext(a, wa) < sext(b, wa) ? 1 : 0
    case Op.sLessThanEqual: return sext(a, wa) <= sext(b, wa) ? 1 : 0
    case Op.sGreaterThan: return sext(a, wa) > sext(b, wa) ? 1 : 0
    case Op.sGreaterThanEqual: return sext(a, wa) >= sext(b, wa) ? 1 : 0
    default: throw fail(i, "OpSpecConstantOp \(OpTable.name(op)) is not supported yet")
    }
  }

  mutating func constLeaves(_ id: UInt32, _ i: SPIRVInstruction) throws(CompileError) -> [ValueID] {
    guard let c = m.constant(id) else { throw fail(i, "%\(id) is not a constant") }
    return try constLeaves(c, id, i)
  }

  mutating func constLeaves(_ c: SPIRVConstant, _ id: UInt32, _ i: SPIRVInstruction) throws(CompileError)
    -> [ValueID]
  {
    if c.isSpec, let s = c.specId, case .scalar(let sk) = try irType(c.type, i) {
      var bits: UInt64 = 0
      if case .scalar(let v) = c.kind { bits = v } else if case .bool(let b) = c.kind { bits = b ? 1 : 0 }
      for o in spec where o.id == s { bits = o.bits }
      return [f.constant(sk, bits)]
    }
    switch c.kind {
    case .bool(let b): return [f.constant(.bool, b ? 1 : 0)]
    case .scalar(let v):
      guard case .scalar(let s) = try irType(c.type, i) else { throw fail(i, "a scalar constant of a vector type") }
      return [f.constant(s, v)]
    case .composite(let parts):
      if case .vector(_, _)? = m.type(c.type) {
        var elems: [ValueID] = []
        for p in parts { elems.append(contentsOf: try constLeaves(p, i)) }
        return [f.constVector(elems)]
      }
      var all: [ValueID] = []
      for p in parts { all.append(contentsOf: try constLeaves(p, i)) }
      return all
    case .null:
      return try zeroLeaves(c.type, i)
    case .specOp(let op, let o):
      let v = try evalSpecOp(op, o, c.type, i)
      guard case .scalar(let s) = try irType(c.type, i) else { throw fail(i, "OpSpecConstantOp of a non-scalar") }
      return [f.constant(s, v)]
    }
  }

  mutating func recordSpec(_ id: UInt32, _ type: IRType, _ bits: UInt64) {
    let s = Specialization(id: id, type: type, bits: bits)
    if !out.specializations.contains(s) { out.specializations.append(s) }
  }

  mutating func zeroLeaves(_ t: UInt32, _ i: SPIRVInstruction) throws(CompileError) -> [ValueID] {
    switch m.type(t) {
    case .structure(let ms)?:
      var all: [ValueID] = []
      for x in ms { all.append(contentsOf: try zeroLeaves(x, i)) }
      return all
    case .array(let e, let len)?:
      var all: [ValueID] = []
      for _ in 0..<Int(try evalInt(len, i)) { all.append(contentsOf: try zeroLeaves(e, i)) }
      return all
    case .pointer?: throw fail(i, "a null pointer is not supported")
    default:
      let ty = try irType(t, i)
      return [f.splat(ty, 0)]
    }
  }

  // MARK: operands

  /// The leaves of an id: a lowered value, a constant, or a global variable.
  mutating func leaves(_ id: UInt32, _ i: SPIRVInstruction) throws(CompileError) -> [ValueID] {
    guard id < m.bound else { throw fail(i, "id %\(id) is outside the module's bound") }
    if !lv[Int(id)].isEmpty { return lv[Int(id)] }
    if let c = m.constant(id) {
      let l = try constLeaves(c, id, i)
      lv[Int(id)] = l
      return l
    }
    if m.variableIndex[Int(id)] >= 0 {
      let v = m.variables[Int(m.variableIndex[Int(id)])]
      let p = try variablePointer(v, i)
      if p < 0 { return [] }  // a builtin: followed symbolically
      lv[Int(id)] = [p]
      return [p]
    }
    throw fail(i, "%\(id) is used before it is defined")
  }

  /// One value (a non-aggregate id).
  mutating func val(_ id: UInt32, _ i: SPIRVInstruction) throws(CompileError) -> ValueID {
    let l = try leaves(id, i)
    guard l.count == 1 else { throw fail(i, "operand %\(id) is an aggregate where a value is needed") }
    return l[0]
  }

  mutating func variablePointer(_ v: SPIRVVariable, _ i: SPIRVInstruction) throws(CompileError) -> ValueID {
    guard case .pointer(_, let pointee)? = m.type(v.type) else { throw fail(i, "variable %\(v.id) has no pointer type") }
    switch v.storage {
    case StorageClass.workgroup, StorageClass.private_:
      let space = try addrSpace(v.storage, i)
      var gi = Int(globalIndex[Int(v.id)])
      if gi < 0 {
        let (s, a) = try sizeAlign(pointee, i)
        gi = out.globals.count
        out.globals.append(Global(name: m.name(of: v.id) ?? "g\(v.id)", space: space, size: s, align: a))
        globalIndex[Int(v.id)] = Int32(gi)
        if v.initializer != 0 && v.storage == StorageClass.workgroup {
          throw fail(i, "a Workgroup variable with an initializer is not supported")
        }
      }
      return f.global(gi, space: space)
    case StorageClass.storageBuffer, StorageClass.uniform:
      guard let set = m.decoration(v.id, Decor.descriptorSet)?.first, let b = m.decoration(v.id, Decor.binding)?.first
      else { throw fail(i, "variable %\(v.id) has no DescriptorSet and Binding") }
      if case .array? = m.type(pointee) {
        throw fail(i, "arrays of buffers (descriptor indexing) are not supported yet")
      }
      return f.resource(set: Int(set), binding: Int(b), space: v.storage == StorageClass.uniform ? .uniform : .storage)
    case StorageClass.pushConstant:
      return f.pushConstants()
    case StorageClass.input:
      guard let b = m.decoration(v.id, Decor.builtIn)?.first else {
        throw fail(i, "an Input variable without a BuiltIn decoration is not supported in compute")
      }
      guard let ib = Lowerer.irBuiltin(b) else {
        throw fail(i, "builtin \(BuiltInId.name(b)) is not supported in compute shaders")
      }
      sym[Int(v.id)] = Sym(builtin: ib, component: -1)
      return -1
    default:
      throw fail(i, "a module variable in storage class \(StorageClass.name(v.storage)) is not supported")
    }
  }

  static func irBuiltin(_ b: UInt32) -> Int? {
    switch b {
    case BuiltInId.numWorkgroups: return IRBuiltin.numWorkgroups
    case BuiltInId.workgroupId: return IRBuiltin.workgroupId
    case BuiltInId.localInvocationId: return IRBuiltin.localInvocationId
    case BuiltInId.globalInvocationId: return IRBuiltin.globalInvocationId
    case BuiltInId.localInvocationIndex: return IRBuiltin.localInvocationIndex
    case BuiltInId.subgroupSize: return IRBuiltin.subgroupSize
    case BuiltInId.numSubgroups: return IRBuiltin.numSubgroups
    case BuiltInId.subgroupId: return IRBuiltin.subgroupId
    case BuiltInId.subgroupLocalInvocationId: return IRBuiltin.subgroupLocalId
    default: return nil
    }
  }

  /// Check an operand has the type the instruction needs.
  func expect(_ v: ValueID, _ t: IRType, _ id: UInt32, _ i: SPIRVInstruction) throws(CompileError) {
    guard f.type(v) == t else {
      throw fail(i, "operand %\(id) has type \(f.type(v).name), expected \(t.name)")
    }
  }

  // MARK: instructions

  mutating func lowerInstruction(_ i: SPIRVInstruction) throws(CompileError) {
    let o = i.operands
    switch i.op {
    case Op.variable:
      guard case .pointer(_, let pointee)? = m.type(i.type) else { throw fail(i, "the type is not a pointer") }
      let (s, a) = try sizeAlign(pointee, i)
      let p = emit(.alloca, .ptr(.function), [], imm: s, imm2: a)
      lv[Int(i.result)] = [p]
      if o.count > 1 {
        let init_ = try leaves(o[1], i)
        try storeLeaves(pointee, ptr: p, off: 0, values: init_, at: 0, space: .function, align: a, volatile: false, i)
      }
    case Op.load:
      let ptrId = o[0]
      if m.variableIndex[Int(ptrId)] >= 0 { _ = try leaves(ptrId, i) }
      if let s = sym[Int(ptrId)] {
        let t = try irType(i.type, i)
        lv[Int(i.result)] = [emit(.builtin, t, [], imm: s.builtin, imm2: s.component)]
        return
      }
      let p = try val(ptrId, i)
      guard case .ptr(let space) = f.type(p) else { throw fail(i, "operand %\(ptrId) is not a pointer") }
      let (align, vol) = try memoryAccess(o, from: 1, i)
      let r = try loadLeaves(i.type, ptr: p, off: 0, space: space, align: align, volatile: vol, i)
      lv[Int(i.result)] = r
    case Op.store:
      let ptrId = o[0]
      if m.variableIndex[Int(ptrId)] >= 0 { _ = try leaves(ptrId, i) }
      guard sym[Int(ptrId)] == nil else { throw fail(i, "a store to a builtin input") }
      let p = try val(ptrId, i)
      guard case .ptr(let space) = f.type(p), case .pointer(_, let pointee)? = m.type(m.idType[Int(ptrId)]) else {
        throw fail(i, "operand %\(ptrId) is not a pointer")
      }
      let (align, vol) = try memoryAccess(o, from: 2, i)
      let vs = try leaves(o[1], i)
      try storeLeaves(pointee, ptr: p, off: 0, values: vs, at: 0, space: space, align: align, volatile: vol, i)
    case Op.accessChain, Op.inBoundsAccessChain:
      try lowerChain(i, element: false)
    case Op.ptrAccessChain, Op.inBoundsPtrAccessChain:
      try lowerChain(i, element: true)
    case Op.arrayLength:
      guard o.count == 2 else { throw fail(i, "needs a struct pointer and a member") }
      let p = try val(o[0], i)
      guard case .pointer(_, let st)? = m.type(m.idType[Int(o[0])]), case .structure(let ms)? = m.type(st),
        Int(o[1]) < ms.count, case .runtimeArray(let el) = m.type(ms[Int(o[1])]) ?? .void
      else { throw fail(i, "operand %\(o[0]) is not a pointer to a struct ending in a runtime array") }
      let l = try structLayout(st, i)
      let stride = try arrayStride(ms[Int(o[1])], el, i)
      lv[Int(i.result)] = [emit(.arraylen, .i32, [p], imm: l.offsets[Int(o[1])], imm2: stride)]
    case Op.functionCall:
      guard o.count >= 1 else { throw fail(i, "needs a callee") }
      let callee = o[0]
      guard Int(callee) < irIndex.count, m.functionIndex[Int(callee)] >= 0 else {
        throw fail(i, "callee %\(callee) is not a function")
      }
      if irIndex[Int(callee)] < 0 {
        irIndex[Int(callee)] = Int32(queue.count)
        queue.append(callee)
      }
      var args: [ValueID] = []
      for a in o[1...] { args.append(try val(a, i)) }
      let rt = try irType(i.type, i)
      let r = f.append(Inst(.call, rt, args, imm: Int(irIndex[Int(callee)])), to: cur)
      if rt != .void { lv[Int(i.result)] = [r] }
    case Op.phi:
      let leafTys = try leafTypesOf(i.type, i)
      var insts: [Int] = []
      var results: [ValueID] = []
      for t in leafTys {
        let id = f.makeInst(Inst(.phi, t, []))
        f.blocks[cur].insts.append(id)
        insts.append(id)
        results.append(f.insts[id].result)
      }
      lv[Int(i.result)] = results
      var inc: [(value: UInt32, label: UInt32)] = []
      var k = 0
      while k + 1 < o.count {
        inc.append((value: o[k], label: o[k + 1]))
        k += 2
      }
      phis.append(PhiFixup(insts: insts, incoming: inc, at: i))
    case Op.selectionMerge:
      f.blocks[cur].kind = .selection
      f.blocks[cur].merge = BlockID(blockOf[Int(o[0])])
    case Op.loopMerge:
      f.blocks[cur].kind = .loop
      f.blocks[cur].merge = BlockID(blockOf[Int(o[0])])
      f.blocks[cur].continueTarget = BlockID(blockOf[Int(o[1])])
    case Op.branch:
      f.append(Inst(.br, .void, [], blocks: [BlockID(blockOf[Int(o[0])])]), to: cur)
    case Op.branchConditional:
      let c = try val(o[0], i)
      try expect(c, .bool, o[0], i)
      f.append(
        Inst(.condbr, .void, [c], blocks: [BlockID(blockOf[Int(o[1])]), BlockID(blockOf[Int(o[2])])]), to: cur)
    case Op.switch_:
      let s = try val(o[0], i)
      guard case .scalar(let sk) = f.type(s), sk.isInt else { throw fail(i, "the selector is not an integer") }
      var blocks = [BlockID(blockOf[Int(o[1])])]
      var cases: [UInt64] = []
      let per = m.switchWords(o[0])
      var k = 2
      while k + per - 1 < o.count {
        var v = UInt64(o[k])
        if per == 3 { v |= UInt64(o[k + 1]) << 32 }
        if sk.bits < 64 { v &= (1 << UInt64(sk.bits)) - 1 }
        cases.append(v)
        blocks.append(BlockID(blockOf[Int(o[k + per - 1])]))
        k += per
      }
      f.append(Inst(.switch_, .void, [s], blocks: blocks, payload: cases), to: cur)
    case Op.return_:
      f.append(Inst(.ret, .void, []), to: cur)
    case Op.returnValue:
      let v = try val(o[0], i)
      f.append(Inst(.ret, .void, [v]), to: cur)
    case Op.unreachable:
      f.append(Inst(.unreachable, .void, []), to: cur)
    case Op.controlBarrier:
      guard o.count == 3 else { throw fail(i, "needs execution scope, memory scope and semantics") }
      let e = Int(try constOperand(o[0], i))
      let ms = Int(try constOperand(o[1], i))
      let sem = Int(try constOperand(o[2], i))
      f.append(Inst(.barrier, .void, [], imm: e, imm2: ms << 32 | sem), to: cur)
    case Op.memoryBarrier:
      guard o.count == 2 else { throw fail(i, "needs a memory scope and semantics") }
      let ms = Int(try constOperand(o[0], i))
      let sem = Int(try constOperand(o[1], i))
      f.append(Inst(.membar, .void, [], imm2: ms << 32 | sem), to: cur)
    case Op.atomicLoad, Op.atomicStore, Op.atomicExchange, Op.atomicCompareExchange, Op.atomicIIncrement,
      Op.atomicIDecrement, Op.atomicIAdd, Op.atomicISub, Op.atomicSMin, Op.atomicUMin, Op.atomicSMax,
      Op.atomicUMax, Op.atomicAnd, Op.atomicOr, Op.atomicXor:
      try lowerAtomic(i)
    default:
      try lowerValueOp(i)
    }
  }

  func constOperand(_ id: UInt32, _ i: SPIRVInstruction) throws(CompileError) -> UInt64 {
    guard m.constant(id) != nil else { throw fail(i, "operand %\(id) must be a constant") }
    return try evalInt(id, i)
  }

  func leafTypesOf(_ t: UInt32, _ i: SPIRVInstruction) throws(CompileError) -> [IRType] {
    var r: [IRType] = []
    try leafTypes(t, i, into: &r)
    return r
  }

  /// A memory access's operands (from `at` in the instruction): alignment and volatility.
  func memoryAccess(_ o: [UInt32], from at: Int, _ i: SPIRVInstruction) throws(CompileError) -> (Int, Bool) {
    guard at < o.count else { return (0, false) }
    let mask = o[at]
    var k = at + 1
    var align = 0
    if mask & 0x2 != 0 {
      guard k < o.count else { throw fail(i, "Aligned needs a value") }
      align = Int(o[k])
      k += 1
    }
    if mask & (0x8 | 0x10) != 0 { throw fail(i, "MakePointerAvailable and MakePointerVisible are not supported yet") }
    return (align, mask & 0x1 != 0)
  }

  // MARK: memory

  mutating func addr(_ ptr: ValueID, _ off: Int) -> ValueID {
    if off == 0 { return ptr }
    guard case .ptr(let sp) = f.type(ptr) else { fatalError("addr of a non-pointer") }
    let c = cInt(sp.offsetType, off)
    return emit(.ptradd, .ptr(sp), [ptr, c])
  }

  mutating func loadLeaves(
    _ t: UInt32, ptr: ValueID, off: Int, space: AddrSpace, align: Int, volatile: Bool, _ i: SPIRVInstruction
  ) throws(CompileError) -> [ValueID] {
    switch m.type(t) {
    case .structure(let ms)?:
      let l = try structLayout(t, i)
      var all: [ValueID] = []
      for (k, mt) in ms.enumerated() {
        all.append(
          contentsOf: try loadLeaves(mt, ptr: ptr, off: off + l.offsets[k], space: space, align: align, volatile: volatile, i))
      }
      return all
    case .array(let e, let len)?:
      let stride = try arrayStride(t, e, i)
      let n = Int(try evalInt(len, i))
      guard n <= 4096 else { throw fail(i, "loading a whole array of \(n) elements is not supported") }
      var all: [ValueID] = []
      for k in 0..<n {
        all.append(
          contentsOf: try loadLeaves(e, ptr: ptr, off: off + k * stride, space: space, align: align, volatile: volatile, i))
      }
      return all
    case .runtimeArray?: throw fail(i, "a runtime array can't be loaded whole")
    default:
      let ty = try irType(t, i)
      let p = addr(ptr, off)
      let a = align != 0 ? align : try leafAlign(t, i)
      return [emit(.load, ty, [p], imm: a, imm2: volatile ? 1 : 0)]
    }
  }

  /// The alignment a leaf access can rely on: its element's size.
  func leafAlign(_ t: UInt32, _ i: SPIRVInstruction) throws(CompileError) -> Int {
    if case .vector(let e, _)? = m.type(t) { return try sizeAlign(e, i).size }
    return try sizeAlign(t, i).size
  }

  mutating func storeLeaves(
    _ t: UInt32, ptr: ValueID, off: Int, values: [ValueID], at: Int, space: AddrSpace, align: Int, volatile: Bool,
    _ i: SPIRVInstruction
  ) throws(CompileError) {
    var idx = at
    try storeWalk(t, ptr: ptr, off: off, values: values, idx: &idx, align: align, volatile: volatile, i)
  }

  mutating func storeWalk(
    _ t: UInt32, ptr: ValueID, off: Int, values: [ValueID], idx: inout Int, align: Int, volatile: Bool,
    _ i: SPIRVInstruction
  ) throws(CompileError) {
    switch m.type(t) {
    case .structure(let ms)?:
      let l = try structLayout(t, i)
      for (k, mt) in ms.enumerated() {
        try storeWalk(mt, ptr: ptr, off: off + l.offsets[k], values: values, idx: &idx, align: align, volatile: volatile, i)
      }
    case .array(let e, let len)?:
      let stride = try arrayStride(t, e, i)
      let n = Int(try evalInt(len, i))
      guard n <= 4096 else { throw fail(i, "storing a whole array of \(n) elements is not supported") }
      for k in 0..<n {
        try storeWalk(e, ptr: ptr, off: off + k * stride, values: values, idx: &idx, align: align, volatile: volatile, i)
      }
    case .runtimeArray?: throw fail(i, "a runtime array can't be stored whole")
    default:
      guard idx < values.count else { throw fail(i, "the stored value has too few parts") }
      let ty = try irType(t, i)
      guard f.type(values[idx]) == ty else {
        throw fail(i, "the stored value has type \(f.type(values[idx]).name), the pointee is \(ty.name)")
      }
      let p = addr(ptr, off)
      let a = align != 0 ? align : try leafAlign(t, i)
      f.append(Inst(.store, .void, [p, values[idx]], imm: a, imm2: volatile ? 1 : 0), to: cur)
      idx += 1
    }
  }

  /// A value as an integer of the pointer-offset width of `space`.
  mutating func offsetValue(_ v: ValueID, signed: Bool, to s: Scalar) -> ValueID {
    guard case .scalar(let k) = f.type(v) else { return v }
    if k == s { return v }
    if k.bits < s.bits { return emit(signed ? .sext : .zext, .scalar(s), [v]) }
    return emit(.trunc, .scalar(s), [v])
  }

  mutating func lowerChain(_ i: SPIRVInstruction, element: Bool) throws(CompileError) {
    let o = i.operands
    guard o.count >= (element ? 2 : 1) else { throw fail(i, "needs a base") }
    let baseId = o[0]
    if m.variableIndex[Int(baseId)] >= 0 { _ = try leaves(baseId, i) }
    guard case .pointer(let storage, let pointee)? = m.type(m.idType[Int(baseId)]) else {
      throw fail(i, "base %\(baseId) is not a pointer")
    }
    if var s = sym[Int(baseId)] {
      // A builtin: only a constant component of a vector.
      guard !element, o.count == 2, m.constant(o[1]) != nil, case .vector(_, let n)? = m.type(pointee) else {
        throw fail(i, "only a constant component of a builtin vector can be addressed")
      }
      let c = Int(try evalInt(o[1], i))
      guard c < n else { throw fail(i, "component \(c) is out of range") }
      s.component = c
      sym[Int(i.result)] = s
      return
    }
    let base = try val(baseId, i)
    guard case .ptr(let space) = f.type(base) else { throw fail(i, "base %\(baseId) is not a pointer") }
    _ = storage
    let ot = space.offsetType
    var cOff = 0
    var dyn: ValueID? = nil
    var cur_ = pointee
    var indexAt = 1

    func addTerm(_ l: inout Lowerer, _ idId: UInt32, stride: Int) throws(CompileError) {
      let iv = try l.val(idId, i)
      guard case .scalar(let k) = l.f.type(iv), k.isInt else { throw l.fail(i, "index %\(idId) is not an integer") }
      if let b = l.f.constantBits(iv) {
        let signed = k.bits >= 64 ? Int64(bitPattern: b) : Int64(bitPattern: b << UInt64(64 - k.bits)) >> Int64(64 - k.bits)
        cOff += Int(signed) * stride
        return
      }
      let conv = l.offsetValue(iv, signed: true, to: ot)
      let term = stride == 1 ? conv : l.emit(.imul, .scalar(ot), [conv, l.cInt(ot, stride)])
      dyn = dyn == nil ? term : l.emit(.iadd, .scalar(ot), [dyn!, term])
    }

    if element {
      var stride = 0
      if let s = m.decoration(m.idType[Int(baseId)], Decor.arrayStride)?.first {
        stride = Int(s)
      } else {
        let (sz, al) = try sizeAlign(pointee, i)
        stride = Lowerer.alignUp(sz, al)
      }
      try addTerm(&self, o[1], stride: stride)
      indexAt = 2
    }
    for k in indexAt..<o.count {
      guard let ty = m.type(cur_) else { throw fail(i, "indexing past a non-composite type") }
      switch ty {
      case .structure(let ms):
        guard m.constant(o[k]) != nil else { throw fail(i, "a struct member index must be a constant") }
        let mi = Int(try evalInt(o[k], i))
        guard mi < ms.count else { throw fail(i, "member \(mi) is out of range") }
        cOff += try structLayout(cur_, i).offsets[mi]
        cur_ = ms[mi]
      case .array(let e, _):
        try addTerm(&self, o[k], stride: try arrayStride(cur_, e, i))
        cur_ = e
      case .runtimeArray(let e):
        try addTerm(&self, o[k], stride: try arrayStride(cur_, e, i))
        cur_ = e
      case .vector(let e, _):
        try addTerm(&self, o[k], stride: try sizeAlign(e, i).size)
        cur_ = e
      default: throw fail(i, "can't index into this type")
      }
    }
    var total = dyn
    if cOff != 0 {
      let c = cInt(ot, cOff)
      total = total == nil ? c : emit(.iadd, .scalar(ot), [total!, c])
    }
    let rs = try irType(i.type, i)
    guard rs == .ptr(space) else { throw fail(i, "the result pointer's storage class differs from the base's") }
    if let t = total { lv[Int(i.result)] = [emit(.ptradd, rs, [base, t])] } else { lv[Int(i.result)] = [base] }
  }

  mutating func lowerAtomic(_ i: SPIRVInstruction) throws(CompileError) {
    let o = i.operands
    let ptrId = o[0]
    let p = try val(ptrId, i)
    guard case .ptr(let space) = f.type(p), space == .storage || space == .workgroup || space == .global else {
      throw fail(i, "atomics need a pointer into storage, workgroup or global memory")
    }
    func scopeSem(_ at: Int) throws(CompileError) -> Int {
      guard at + 1 < o.count + 0 else { throw fail(i, "too few operands") }
      let sc = Int(try constOperand(o[at], i))
      let sem = Int(try constOperand(o[at + 1], i))
      return sc << 32 | sem
    }
    switch i.op {
    case Op.atomicLoad:
      let t = try irType(i.type, i)
      lv[Int(i.result)] = [emit(.atomic, t, [p], imm: AtomicKind.load, imm2: try scopeSem(1))]
    case Op.atomicStore:
      let v = try val(o[3], i)
      f.append(Inst(.atomic, .void, [p, v], imm: AtomicKind.store, imm2: try scopeSem(1)), to: cur)
    case Op.atomicCompareExchange:
      guard o.count == 6 else { throw fail(i, "needs 6 operands") }
      let t = try irType(i.type, i)
      let nv = try val(o[4], i)
      let cmp = try val(o[5], i)
      try expect(nv, t, o[4], i)
      try expect(cmp, t, o[5], i)
      lv[Int(i.result)] = [emit(.atomic, t, [p, cmp, nv], imm: AtomicKind.cmpxchg, imm2: try scopeSem(1))]
    default:
      let t = try irType(i.type, i)
      var kind = 0
      var operand: ValueID
      switch i.op {
      case Op.atomicIIncrement, Op.atomicIDecrement:
        kind = i.op == Op.atomicIIncrement ? AtomicKind.add : AtomicKind.sub
        guard case .scalar(let s) = t else { throw fail(i, "the type is not an integer") }
        operand = f.constant(s, 1)
      default:
        guard o.count == 4 else { throw fail(i, "needs 4 operands") }
        operand = try val(o[3], i)
        try expect(operand, t, o[3], i)
        switch i.op {
        case Op.atomicExchange: kind = AtomicKind.xchg
        case Op.atomicIAdd: kind = AtomicKind.add
        case Op.atomicISub: kind = AtomicKind.sub
        case Op.atomicSMin: kind = AtomicKind.smin
        case Op.atomicUMin: kind = AtomicKind.umin
        case Op.atomicSMax: kind = AtomicKind.smax
        case Op.atomicUMax: kind = AtomicKind.umax
        case Op.atomicAnd: kind = AtomicKind.and
        case Op.atomicOr: kind = AtomicKind.or
        default: kind = AtomicKind.xor
        }
      }
      lv[Int(i.result)] = [emit(.atomic, t, [p, operand], imm: kind, imm2: try scopeSem(1))]
    }
  }
}
