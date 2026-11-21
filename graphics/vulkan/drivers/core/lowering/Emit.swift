// SPDX-License-Identifier: BSD-3-Clause

// What the rewrite builds with: new ids, types, constants and variables, and the reads of the root block and the
// set records that every lowered access starts from (RootBlock and SetLayout, Layout.swift).

/// The types and variable of the core's push-constant block: one buffer reference, the root.
struct RootTypes {
  var made = false
  /// `struct { uint64 set[4]; uint64 vertexBuffer[8]; }`, the root block's head, which the root points at.
  var data: UInt32 = 0
  var ptrData: UInt32 = 0
  /// The push-constant block: one reference to `data`.
  var block: UInt32 = 0
  var ptrBlock: UInt32 = 0
  var ptrMember: UInt32 = 0
  var variable: UInt32 = 0
}

/// One of the heap's arrays: `kind` 0 the textures (binding 0), 1 the samplers (binding 1), 2 the storage images
/// (binding 2); `element` the image type (the sampler type for the samplers).
struct HeapVar {
  var kind: Int
  var element: UInt32
  var variable: UInt32
  var elementPointer: UInt32
}

extension Rewriter {
  // MARK: ids, types, constants

  mutating func newId() -> UInt32 {
    let id = nextId
    nextId += 1
    return id
  }

  mutating func setTypeInfo(_ id: UInt32, _ t: TypeInfo) {
    while types.count <= Int(id) { types.append(nil) }
    types[Int(id)] = t
  }

  /// A type or constant declared after the program's.
  mutating func addGlobal(_ inst: RawInst) {
    newGlobals.append(inst)
    if let t = Rewriter.typeInfo(inst), !inst.w.isEmpty { setTypeInfo(inst.w[0], t) }
  }

  static func same(_ w: [UInt32], _ operands: [UInt32]) -> Bool {
    guard w.count == operands.count + 1 else { return false }
    for k in 0..<operands.count where w[k + 1] != operands[k] { return false }
    return true
  }

  /// A type, always new (one that carries decorations).
  mutating func newType(_ op: UInt16, _ operands: [UInt32]) -> UInt32 {
    let id = newId()
    addGlobal(RawInst(op, [id] + operands))
    return id
  }

  /// The program's declaration of the type, or one made.
  mutating func findType(_ op: UInt16, _ operands: [UInt32]) -> UInt32 {
    for g in m.globals where g.op == op && Rewriter.same(g.w, operands) { return g.w[0] }
    for g in newGlobals where g.op == op && Rewriter.same(g.w, operands) { return g.w[0] }
    return newType(op, operands)
  }

  mutating func findConstant(_ type: UInt32, _ value: UInt64) -> UInt32 {
    var wide = false
    if case .int(let width, _)? = typeOf(type), width == 64 { wide = true }
    var rest: [UInt32] = [UInt32(truncatingIfNeeded: value)]
    if wide { rest.append(UInt32(truncatingIfNeeded: value >> 32)) }
    for g in m.globals where g.op == SPV.opConstant && g.w.count == rest.count + 2 && g.w[0] == type {
      var equal = true
      for k in 0..<rest.count where g.w[k + 2] != rest[k] { equal = false }
      if equal { return g.w[1] }
    }
    for g in newGlobals where g.op == SPV.opConstant && g.w.count == rest.count + 2 && g.w[0] == type {
      var equal = true
      for k in 0..<rest.count where g.w[k + 2] != rest[k] { equal = false }
      if equal { return g.w[1] }
    }
    let id = newId()
    addGlobal(RawInst(SPV.opConstant, [type, id] + rest))
    return id
  }

  mutating func uintType() -> UInt32 {
    if tUint == 0 { tUint = findType(SPV.opTypeInt, [32, 0]) }
    return tUint
  }

  mutating func intType() -> UInt32 {
    if tInt == 0 { tInt = findType(SPV.opTypeInt, [32, 1]) }
    return tInt
  }

  mutating func ulongType() -> UInt32 {
    if tUlong == 0 { tUlong = findType(SPV.opTypeInt, [64, 0]) }
    usedPSB = true
    return tUlong
  }

  mutating func floatType() -> UInt32 {
    if tFloat == 0 { tFloat = findType(SPV.opTypeFloat, [32]) }
    return tFloat
  }

  mutating func boolType() -> UInt32 {
    if tBool == 0 { tBool = findType(SPV.opTypeBool, []) }
    return tBool
  }

  mutating func uint(_ v: UInt64) -> UInt32 { findConstant(uintType(), v) }
  mutating func ulong(_ v: UInt64) -> UInt32 { findConstant(ulongType(), v) }

  mutating func pointerType(_ storage: UInt32, _ pointee: UInt32) -> UInt32 {
    if storage == SPV.physicalStorageBuffer { usedPSB = true }
    return findType(SPV.opTypePointer, [storage, pointee])
  }

  mutating func newVariable(_ type: UInt32, storage: UInt32) -> UInt32 {
    let id = newId()
    newVars.append(RawInst(SPV.opVariable, [type, id, storage]))
    return id
  }

  mutating func decorate(_ id: UInt32, _ kind: UInt32, _ operands: [UInt32] = []) {
    newAnnotations.append(RawInst(SPV.opDecorate, [id, kind] + operands))
  }

  /// NonUniform on an id, once (the program may have said it already).
  mutating func markNonUniform(_ id: UInt32) {
    if hasDecoration(id, SPV.decNonUniform) { return }
    for a in newAnnotations where a.op == SPV.opDecorate && a.w.count == 2 && a.w[0] == id && a.w[1] == SPV.decNonUniform { return }
    decorate(id, SPV.decNonUniform)
  }

  mutating func decorateMember(_ id: UInt32, _ member: UInt32, _ kind: UInt32, _ operands: [UInt32] = []) {
    newAnnotations.append(RawInst(SPV.opMemberDecorate, [id, member, kind] + operands))
  }

  /// The alignment the loads and stores through a buffer pointer to `t` promise (std430's, the layouts' lower bound).
  func alignment(_ t: UInt32, depth: Int = 0) -> UInt32 {
    guard depth < 16 else { return 4 }
    switch typeOf(t) {
    case .int(let w, _)?, .float(let w)?: return UInt32(max(1, w / 8))
    case .bool?: return 4
    case .vector(let e, let n)?: return alignment(e, depth: depth + 1) * UInt32(n == 3 ? 4 : n)
    case .matrix(let c, _)?: return alignment(c, depth: depth + 1)
    case .array(let e, _)?, .runtimeArray(let e)?: return alignment(e, depth: depth + 1)
    case .structure(let ms)?:
      var a: UInt32 = 1
      for x in ms { a = max(a, alignment(x, depth: depth + 1)) }
      return a
    case .pointer?: return 8
    default: return 4
    }
  }

  // MARK: emitting

  mutating func emit(_ op: UInt16, _ type: UInt32, _ operands: [UInt32], pre: Bool) -> UInt32 {
    let id = newId()
    emitAs(op, type, id, operands, pre: pre)
    return id
  }

  mutating func emitAs(_ op: UInt16, _ type: UInt32, _ id: UInt32, _ operands: [UInt32], pre: Bool) {
    let inst = RawInst(op, [type, id] + operands)
    if pre { self.pre.append(inst) } else { body.append(inst) }
  }

  mutating func loadAligned(_ type: UInt32, _ pointer: UInt32, _ align: UInt32, pre: Bool, result: UInt32 = 0) -> UInt32 {
    let id = result != 0 ? result : newId()
    emitAs(SPV.opLoad, type, id, [pointer, SPV.memoryAccessAligned, align], pre: pre)
    return id
  }

  /// A 32-bit word at the 64-bit address `address`.
  mutating func loadWord(at address: UInt32, pre: Bool) -> UInt32 {
    let p = emit(SPV.opConvertUToPtr, pointerType(SPV.physicalStorageBuffer, uintType()), [address], pre: pre)
    return loadAligned(uintType(), p, 4, pre: pre)
  }

  /// A 64-bit word at the 64-bit address `address`.
  mutating func loadDouble(at address: UInt32, pre: Bool) -> UInt32 {
    let p = emit(SPV.opConvertUToPtr, pointerType(SPV.physicalStorageBuffer, ulongType()), [address], pre: pre)
    return loadAligned(ulongType(), p, 8, pre: pre)
  }

  /// `address + bytes`, the address itself for none.
  mutating func offset(_ address: UInt32, by bytes: UInt64, pre: Bool) -> UInt32 {
    if bytes == 0 { return address }
    return emit(SPV.opIAdd, ulongType(), [address, ulong(bytes)], pre: pre)
  }

  // MARK: the root block

  /// The core's push-constant block and its variable, made once.
  mutating func ensureRoot() {
    if root.made { return }
    root.made = true
    let u64 = ulongType()
    let u32 = uintType()
    let arr4 = newType(SPV.opTypeArray, [u64, uint(UInt64(RootBlock.maxSets))])
    let arr8 = newType(SPV.opTypeArray, [u64, uint(UInt64(RootBlock.maxVertexBuffers))])
    decorate(arr4, SPV.decArrayStride, [8])
    decorate(arr8, SPV.decArrayStride, [8])
    root.data = newType(SPV.opTypeStruct, [arr4, arr8])
    decorate(root.data, SPV.decBlock)
    decorateMember(root.data, 0, SPV.decOffset, [UInt32(RootBlock.setsOffset)])
    decorateMember(root.data, 1, SPV.decOffset, [UInt32(RootBlock.vertexBuffersOffset)])
    decorateMember(root.data, 0, SPV.decNonWritable)
    decorateMember(root.data, 1, SPV.decNonWritable)
    root.ptrData = pointerType(SPV.physicalStorageBuffer, root.data)
    root.block = newType(SPV.opTypeStruct, [root.ptrData])
    decorate(root.block, SPV.decBlock)
    decorateMember(root.block, 0, SPV.decOffset, [0])
    root.ptrBlock = pointerType(SPV.pushConstant, root.block)
    root.ptrMember = pointerType(SPV.pushConstant, root.ptrData)
    root.variable = newVariable(root.ptrBlock, storage: SPV.pushConstant)
    extraInterface.append((id: root.variable, isInput: false))
    _ = u32
  }

  /// The root block's head as a pointer, read once at the top of the function.
  mutating func rootData() -> UInt32 {
    if fnRootData != 0 { return fnRootData }
    ensureRoot()
    let chain = emit(SPV.opAccessChain, root.ptrMember, [root.variable, uint(0)], pre: true)
    fnRootData = emit(SPV.opLoad, root.ptrData, [chain], pre: true)
    return fnRootData
  }

  /// The root pointer as a 64-bit address.
  mutating func rootAddress() -> UInt32 {
    if fnRootAddr != 0 { return fnRootAddr }
    let rd = rootData()
    fnRootAddr = emit(SPV.opConvertPtrToU, ulongType(), [rd], pre: true)
    return fnRootAddr
  }

  /// Set `s`'s record address, read once at the top of the function.
  mutating func setAddress(_ s: Int) -> UInt32 {
    if fnSetAddr[s] != 0 { return fnSetAddr[s] }
    let rd = rootData()
    let chain = emit(SPV.opAccessChain, pointerType(SPV.physicalStorageBuffer, ulongType()), [rd, uint(0), uint(UInt64(s))], pre: true)
    fnSetAddr[s] = loadAligned(ulongType(), chain, 8, pre: true)
    return fnSetAddr[s]
  }

  /// Vertex buffer `b`'s address (plus its offset).
  mutating func vertexBufferAddress(_ b: Int) -> UInt32 {
    let rd = rootData()
    let chain = emit(SPV.opAccessChain, pointerType(SPV.physicalStorageBuffer, ulongType()), [rd, uint(1), uint(UInt64(b))], pre: true)
    return loadAligned(ulongType(), chain, 8, pre: true)
  }
}
