// SPDX-License-Identifier: BSD-3-Clause

// Descriptors and push constants: the program's buffers become pointers read from the set records, its images and
// samplers become elements of the heap's arrays at the slots the set records hold, and its push-constant block
// becomes a pointer into the root block.

extension Rewriter {
  // MARK: finding the program's variables

  /// The leaf of an image, sampler or sampled image, or an array of them.
  func opaqueLeaf(_ t: UInt32) -> UInt32? {
    switch typeOf(t) {
    case .image?, .sampler?, .sampledImage?: return t
    case .array(let e, _)?:
      if case .array? = typeOf(e) { return nil }
      return opaqueLeaf(e)
    case .runtimeArray(let e)?: return opaqueLeaf(e)
    default: return nil
    }
  }

  mutating func classifyVariables() throws(LoweringError) {
    for inst in m.globals where inst.op == SPV.opVariable {
      guard inst.w.count >= 3, check(inst.w[1]) else { throw .malformed("OpVariable needs a type, an id and a storage class") }
      let id = inst.w[1]
      guard case .pointer(_, let pointee)? = typeOf(inst.w[0]) else { throw .malformed("a variable %\(id) whose type isn't a pointer") }
      var v = VarInfo(id: id, type: inst.w[0], kind: .buffer)
      switch inst.w[2] {
      case SPV.uniform, SPV.storageBuffer: v.kind = .buffer
      case SPV.uniformConstant:
        guard opaqueLeaf(pointee) != nil else { continue }
        v.kind = .opaque
      case SPV.pushConstant: v.kind = .pushConstant
      case SPV.input:
        guard stage == .vertex, let location = decoration(id, SPV.decLocation), !hasDecoration(id, SPV.decBuiltIn) else { continue }
        v.kind = .vertexInput
        v.location = location
      default: continue
      }
      v.leaf = pointee
      if v.kind == .buffer || v.kind == .opaque {
        switch typeOf(pointee) {
        case .array(let e, let length)?:
          if case .array? = typeOf(e) { throw .unsupported("an array of arrays of descriptors") }
          if case .runtimeArray? = typeOf(e) { throw .unsupported("an array of arrays of descriptors") }
          v.arrayed = true
          v.count = constant(length).map { UInt32(truncatingIfNeeded: $0) }
          v.leaf = e
        case .runtimeArray(let e)?:
          v.arrayed = true
          v.leaf = e
        default: break
        }
      }
      varOf[Int(id)] = Int32(vars.count)
      vars.append(v)
    }

    // Which of them a function names where a pointer goes.
    for f in m.functions {
      for inst in f {
        for at in Rewriter.pointerWords(inst) where at < inst.w.count {
          let id = inst.w[at]
          if check(id), varOf[Int(id)] >= 0 { vars[Int(varOf[Int(id)])].used = true }
        }
      }
    }

    // What the used ones need: the layout's entry, and a type the lowering takes.
    for vi in vars.indices where vars[vi].used {
      var v = vars[vi]
      switch v.kind {
      case .buffer:
        guard let set = decoration(v.id, SPV.decDescriptorSet), let binding = decoration(v.id, SPV.decBinding) else {
          throw .invalid("\(describe(v.id)) has no DescriptorSet and Binding")
        }
        v.set = set
        v.binding = binding
        guard case .structure? = typeOf(v.leaf) else { throw .invalid("\(describe(v.id)) is not a block") }
        let legacy = hasDecoration(v.leaf, SPV.decBufferBlock)
        let isUniformClass = isStorage(v.type, SPV.uniform)
        v.descriptor = isUniformClass && !legacy ? .uniformBuffer : .storageBuffer
        try place(&v)
        usedPSB = true
      case .opaque:
        guard let set = decoration(v.id, SPV.decDescriptorSet), let binding = decoration(v.id, SPV.decBinding) else {
          throw .invalid("\(describe(v.id)) has no DescriptorSet and Binding")
        }
        v.set = set
        v.binding = binding
        switch typeOf(v.leaf) {
        case .sampler?: v.descriptor = .sampler
        case .sampledImage(let image)?:
          try checkImage(image)
          v.descriptor = .combinedImageSampler
        case .image(_, _, _, _, _, let usage)?:
          try checkImage(v.leaf)
          v.descriptor = usage == 2 ? .storageImage : .sampledImage
        default: throw .invalid("\(describe(v.id)) is not an image or a sampler")
        }
        try place(&v)
        usedPSB = true
      case .pushConstant:
        guard layout.pushConstantBytes <= RootBlock.maxPushConstantBytes else {
          throw .invalid("the pipeline layout's push constants (\(layout.pushConstantBytes) bytes) are over \(RootBlock.maxPushConstantBytes)")
        }
        usedPSB = true
      case .vertexInput:
        try checkVertexInput(v)
      }
      vars[vi] = v
    }
  }

  func isStorage(_ pointerType: UInt32, _ storage: UInt32) -> Bool {
    if case .pointer(let sc, _)? = typeOf(pointerType) { return sc == storage }
    return false
  }

  /// Where the layout puts the variable's binding, which must be of the kind its type is.
  func place(_ v: inout VarInfo) throws(LoweringError) {
    guard v.set < UInt32(RootBlock.maxSets) else {
      throw .invalid("set \(v.set) is over the \(RootBlock.maxSets) the root block holds")
    }
    guard Int(v.set) < layout.sets.count, let set = layout.sets[Int(v.set)] else {
      throw .invalid("set \(v.set) (\(describe(v.id))) is not in the pipeline layout")
    }
    guard let (offset, binding) = set.find(v.binding) else {
      throw .invalid("binding \(v.binding) of set \(v.set) (\(describe(v.id))) is not in the pipeline layout")
    }
    guard binding.kind == v.descriptor else {
      throw .invalid("binding \(v.binding) of set \(v.set) is not the kind of descriptor the program declares")
    }
    v.recordOffset = offset
  }

  /// A 2D, single-sampled, non-arrayed colour image: the only kind the heap holds.
  func checkImage(_ t: UInt32) throws(LoweringError) {
    guard case .image(_, let dim, let depth, let arrayed, let multisampled, _)? = typeOf(t) else { return }
    switch dim {
    case 1: break
    case 0: throw .unsupported("a 1D image")
    case 2: throw .unsupported("a 3D image")
    case 3: throw .unsupported("a cube image")
    case 4: throw .unsupported("a rect image")
    case 5: throw .unsupported("a buffer image")
    case 6: throw .unsupported("an input attachment")
    default: throw .unsupported("an image of dimension \(dim)")
    }
    if arrayed { throw .unsupported("an arrayed image") }
    if multisampled { throw .unsupported("a multisampled image") }
    if depth == 1 { throw .unsupported("a depth image") }
  }

  /// The operand words of an instruction where a pointer to a variable can be: where a lowered variable must be
  /// replaced.
  static func pointerWords(_ i: RawInst) -> [Int] {
    switch i.op {
    case SPV.opLoad, SPV.opAccessChain, SPV.opInBoundsAccessChain, SPV.opPtrAccessChain, SPV.opInBoundsPtrAccessChain,
      SPV.opArrayLength, SPV.opCopyObject, SPV.opConvertPtrToU, SPV.opBitcast, SPV.opImageTexelPointer:
      return [2]
    case SPV.opStore: return [0]
    case SPV.opCopyMemory, SPV.opCopyMemorySized: return [0, 1]
    case SPV.opFunctionCall: return i.w.count > 3 ? Array(3..<i.w.count) : []
    case SPV.opSelect: return [3, 4]
    case SPV.opPhi:
      var out: [Int] = []
      var k = 2
      while k < i.w.count {
        out.append(k)
        k += 2
      }
      return out
    case SPV.opExtInst: return i.w.count > 4 ? Array(4..<i.w.count) : []
    case SPV.opAtomicStore: return [0]
    case SPV.opAtomicLoad...SPV.opAtomicXor: return [2]
    default: return []
    }
  }

  // MARK: the module's variables and types

  /// The pointer types the program's buffers and push constants had become pointers to physical memory, the
  /// variables are gone and the vertex inputs are private variables: done before any function is rewritten.
  mutating func rewriteGlobals() {
    loweredPointerType = [Bool](repeating: false, count: Int(originalBound))
    for k in m.globals.indices {
      let inst = m.globals[k]
      if inst.op == SPV.opTypePointer, inst.w.count >= 3, isBufferStorage(inst.w[1]) {
        m.globals[k].w[1] = SPV.physicalStorageBuffer
        loweredPointerType[Int(inst.w[0])] = true
        usedPSB = true
      } else if inst.op == SPV.opTypeForwardPointer, inst.w.count >= 2, isBufferStorage(inst.w[1]) {
        m.globals[k].w[1] = SPV.physicalStorageBuffer
      }
    }
    // A buffer block of the old kind is a block now.
    for vi in vars.indices where vars[vi].used && vars[vi].kind == .buffer {
      for k in m.annotations.indices {
        let a = m.annotations[k]
        if a.op == SPV.opDecorate, a.w.count == 2, a.w[0] == vars[vi].leaf, a.w[1] == SPV.decBufferBlock {
          m.annotations[k].w[1] = SPV.decBlock
        }
      }
    }
    var kept: [RawInst] = []
    for inst in m.globals {
      if inst.op == SPV.opVariable, inst.w.count >= 2, check(inst.w[1]), varOf[Int(inst.w[1])] >= 0 {
        let v = vars[Int(varOf[Int(inst.w[1])])]
        if v.kind == .vertexInput && v.used, case .pointer(_, let pointee)? = typeOf(v.type) {
          let ptr = pointerType(SPV.private_, pointee)
          newVars.append(RawInst(SPV.opVariable, [ptr, v.id, SPV.private_]))
        }
        continue
      }
      kept.append(inst)
    }
    m.globals = kept
  }

  func isBufferStorage(_ c: UInt32) -> Bool { c == SPV.uniform || c == SPV.storageBuffer || c == SPV.pushConstant }

  /// Whether the pointer type (by its original id) is one of those that were buffers.
  func isLoweredPointer(_ id: UInt32) -> Bool {
    guard check(id) else { return false }
    let t = idType[Int(id)]
    return Int(t) < loweredPointerType.count && loweredPointerType[Int(t)]
  }

  // MARK: reading descriptors

  func elementIndex(_ id: UInt32) -> ElementIndex {
    if let c = constant(id) { return .constant(c) }
    return .dynamic(id)
  }

  /// The 64-bit address of descriptor `index` of the variable's binding, in its set's record.
  mutating func descriptorAddress(_ v: VarInfo, _ index: ElementIndex, pre: Bool) -> UInt32 {
    let base = setAddress(Int(v.set))
    switch index {
    case .constant(let i): return offset(base, by: UInt64(v.recordOffset) + UInt64(descriptorSize) * i, pre: pre)
    case .dynamic(let id):
      var wide = id
      if case .int(let width, _)? = typeOf(idType[Int(id)]), width != 64 {
        wide = emit(SPV.opUConvert, ulongType(), [id], pre: pre)
      }
      let scaled = emit(SPV.opIMul, ulongType(), [wide, ulong(UInt64(descriptorSize))], pre: pre)
      let sum = emit(SPV.opIAdd, ulongType(), [base, scaled], pre: pre)
      return offset(sum, by: UInt64(v.recordOffset), pre: pre)
    }
  }

  /// The pointer a buffer variable or the push-constant block is replaced by, made at the top of the function.
  mutating func variablePointer(_ vi: Int) throws(LoweringError) -> UInt32 {
    for p in fnPointers where p.variable == vi { return p.pointer }
    let v = vars[vi]
    var pointer: UInt32
    switch v.kind {
    case .buffer:
      let desc = descriptorAddress(v, .constant(0), pre: true)
      let address = loadDouble(at: desc, pre: true)
      pointer = emit(SPV.opConvertUToPtr, v.type, [address], pre: true)
      fnDescriptors.append((pointer: pointer, descriptor: desc))
    case .pushConstant:
      let at = offset(rootAddress(), by: UInt64(RootBlock.pushConstantsOffset), pre: true)
      pointer = emit(SPV.opConvertUToPtr, v.type, [at], pre: true)
    default: throw .unsupported("a variable of this kind named where a pointer goes")
    }
    fnPointers.append((variable: vi, pointer: pointer))
    return pointer
  }

  // MARK: a function

  mutating func rewriteFunctions() throws(LoweringError) {
    for fi in m.functions.indices {
      let f = m.functions[fi]
      guard f.count >= 1, f[0].w.count >= 2 else { throw .malformed("OpFunction needs a type and an id") }
      var h = 0
      while h < f.count && f[h].op != SPV.opLabel { h += 1 }
      h = min(h + 1, f.count)
      while h < f.count && f[h].op == SPV.opVariable { h += 1 }
      pre = []
      body = []
      fnRootData = 0
      fnRootAddr = 0
      fnSetAddr = [0, 0, 0, 0]
      fnPointers = []
      fnDescriptors = []
      fnVertexIndex = 0
      fnInstanceIndex = 0
      if f[0].w[1] == entryFunction { try vertexPrologue() }
      var k = h
      while k < f.count {
        try rewriteInstruction(f[k])
        k += 1
      }
      m.functions[fi] = Array(f[0..<h]) + pre + body
    }
  }

  mutating func rewriteInstruction(_ inst: RawInst) throws(LoweringError) {
    switch inst.op {
    case SPV.opLoad: try rewriteLoad(inst)
    case SPV.opStore: try rewriteStore(inst)
    case SPV.opAccessChain, SPV.opInBoundsAccessChain, SPV.opPtrAccessChain, SPV.opInBoundsPtrAccessChain:
      try rewriteChain(inst)
    case SPV.opArrayLength: try rewriteArrayLength(inst)
    default:
      var out = inst
      for at in Rewriter.pointerWords(inst) where at < inst.w.count {
        let id = inst.w[at]
        guard check(id) else { continue }
        if varOf[Int(id)] >= 0 {
          out.w[at] = try substitute(Int(varOf[Int(id)]), inst)
        } else if opaqueVar[Int(id)] >= 0 {
          throw .unsupported("a descriptor array's element passed or copied as a whole (\(opName(inst.op)))")
        }
      }
      propagateNonUniform(out)
      body.append(out)
    }
  }

  func opName(_ op: UInt16) -> String { "op \(op)" }

  /// What the instruction's pointer operand `variable` is replaced by.
  mutating func substitute(_ vi: Int, _ inst: RawInst) throws(LoweringError) -> UInt32 {
    let v = vars[vi]
    switch v.kind {
    case .buffer:
      if v.arrayed { throw .unsupported("an array of buffers named as a whole (\(opName(inst.op)))") }
      return try variablePointer(vi)
    case .pushConstant: return try variablePointer(vi)
    case .opaque: throw .unsupported("a descriptor named as a whole (\(opName(inst.op)))")
    case .vertexInput: return v.id
    }
  }

  /// A result of an image operation on a handle that may differ between lanes is NonUniform too.
  mutating func propagateNonUniform(_ inst: RawInst) {
    guard inst.op >= SPV.opSampledImage && inst.op <= SPV.opImage || inst.op == SPV.opImageRead, inst.w.count >= 3 else { return }
    let result = inst.w[1]
    guard check(result) else { return }
    var marked = false
    let handles = inst.op == SPV.opSampledImage ? 2 : 1
    for k in 0..<handles where 2 + k < inst.w.count {
      let id = inst.w[2 + k]
      if check(id) && nonUniform[Int(id)] { marked = true }
    }
    if marked {
      nonUniform[Int(result)] = true
      markNonUniform(result)
      needNonUniform = true
    }
  }

  mutating func rewriteLoad(_ inst: RawInst) throws(LoweringError) {
    let w = inst.w
    guard w.count >= 3 else { throw .malformed("OpLoad needs a type, an id and a pointer") }
    let pointer = w[2]
    if check(pointer) {
      let vi = varOf[Int(pointer)]
      if vi >= 0 && vars[Int(vi)].kind == .opaque {
        guard !vars[Int(vi)].arrayed else { throw .invalid("an array of descriptors is loaded as a whole") }
        try loadHandle(inst, variable: Int(vi), index: .constant(0))
        return
      }
      if opaqueVar[Int(pointer)] >= 0, let index = opaqueIndex[Int(pointer)] {
        try loadHandle(inst, variable: Int(opaqueVar[Int(pointer)]), index: index)
        return
      }
    }
    var out = inst
    let lowered = isLoweredPointer(pointer)
    if check(pointer), varOf[Int(pointer)] >= 0 { out.w[2] = try substitute(Int(varOf[Int(pointer)]), inst) }
    if lowered {
      out.w = Array(w[0..<3]) + Rewriter.aligned(Array(w[3...]), alignment(w[0]))
    }
    body.append(out)
  }

  mutating func rewriteStore(_ inst: RawInst) throws(LoweringError) {
    let w = inst.w
    guard w.count >= 2 else { throw .malformed("OpStore needs a pointer and an object") }
    let pointer = w[0]
    var out = inst
    if check(pointer) {
      if varOf[Int(pointer)] >= 0 {
        let v = vars[Int(varOf[Int(pointer)])]
        if v.kind == .opaque { throw .invalid("a store to a descriptor") }
        out.w[0] = try substitute(Int(varOf[Int(pointer)]), inst)
      }
      if isLoweredPointer(pointer) {
        let type = check(w[1]) ? idType[Int(w[1])] : 0
        out.w = Array(w[0..<2]) + Rewriter.aligned(Array(w[2...]), alignment(type))
      }
    }
    body.append(out)
  }

  /// The memory operands with Aligned in them (the literal follows the mask, before the other operands').
  static func aligned(_ operands: [UInt32], _ alignment: UInt32) -> [UInt32] {
    if operands.isEmpty { return [SPV.memoryAccessAligned, alignment] }
    let mask = operands[0]
    if mask & SPV.memoryAccessAligned != 0 { return operands }
    return [mask | SPV.memoryAccessAligned, alignment] + Array(operands[1...])
  }

  mutating func rewriteChain(_ inst: RawInst) throws(LoweringError) {
    let w = inst.w
    guard w.count >= 3 else { throw .malformed("an access chain needs a type, an id and a base") }
    let base = w[2]
    let result = w[1]
    var out = inst
    if check(base) {
      let vi = Int(varOf[Int(base)])
      if varOf[Int(base)] >= 0 {
        let v = vars[vi]
        switch v.kind {
        case .opaque:
          guard inst.op == SPV.opAccessChain || inst.op == SPV.opInBoundsAccessChain else {
            throw .unsupported("a pointer access chain into a descriptor")
          }
          guard v.arrayed, w.count == 4 else { throw .unsupported("an access chain into an image or sampler that isn't one index into an array") }
          guard check(result) else { throw .malformed("an id outside the module's bound") }
          opaqueVar[Int(result)] = Int32(vi)
          let index = elementIndex(w[3])
          opaqueIndex[Int(result)] = index
          return
        case .buffer:
          if v.arrayed {
            guard inst.op == SPV.opAccessChain || inst.op == SPV.opInBoundsAccessChain else {
              throw .unsupported("a pointer access chain into an array of buffers")
            }
            guard w.count >= 4 else { throw .invalid("an array of buffers named as a whole") }
            try elementPointer(inst, v)
            return
          }
          out.w[2] = try variablePointer(vi)
        case .pushConstant:
          out.w[2] = try variablePointer(vi)
        case .vertexInput:
          out.w[0] = privatePointer(w[0])
          fromInput[Int(result)] = true
        }
      } else if opaqueVar[Int(base)] >= 0 {
        throw .unsupported("an access chain into an element of a descriptor array")
      } else if fromInput[Int(base)] {
        out.w[0] = privatePointer(w[0])
        if check(result) { fromInput[Int(result)] = true }
      }
    }
    body.append(out)
  }

  /// The type of a pointer to what `pointerType` points to, in Private.
  mutating func privatePointer(_ pointerType: UInt32) -> UInt32 {
    guard case .pointer(_, let pointee)? = typeOf(pointerType) else { return pointerType }
    return self.pointerType(SPV.private_, pointee)
  }

  /// An access chain into an array of buffers: the element's address read from the set record.
  mutating func elementPointer(_ inst: RawInst, _ v: VarInfo) throws(LoweringError) {
    let w = inst.w
    let desc = descriptorAddress(v, elementIndex(w[3]), pre: false)
    let address = loadDouble(at: desc, pre: false)
    if w.count == 4 {
      emitAs(SPV.opConvertUToPtr, w[0], w[1], [address], pre: false)
      fnDescriptors.append((pointer: w[1], descriptor: desc))
    } else {
      let element = emit(SPV.opConvertUToPtr, pointerType(SPV.physicalStorageBuffer, v.leaf), [address], pre: false)
      fnDescriptors.append((pointer: element, descriptor: desc))
      emitAs(inst.op, w[0], w[1], [element] + Array(w[4...]), pre: false)
    }
  }

  mutating func rewriteArrayLength(_ inst: RawInst) throws(LoweringError) {
    let w = inst.w
    guard w.count == 4 else { throw .malformed("OpArrayLength needs a structure pointer and a member") }
    var pointer = w[2]
    if check(pointer), varOf[Int(pointer)] >= 0 { pointer = try substitute(Int(varOf[Int(pointer)]), inst) }
    var desc: UInt32 = 0
    for d in fnDescriptors where d.pointer == pointer { desc = d.descriptor }
    guard desc != 0 else { throw .unsupported("OpArrayLength of anything but a buffer") }
    guard check(w[2]), case .pointer(_, let block)? = typeOf(idType[Int(w[2])]), case .structure(let members)? = typeOf(block),
      Int(w[3]) < members.count, case .runtimeArray? = typeOf(members[Int(w[3])]),
      let start = memberDecoration(block, w[3], SPV.decOffset), let stride = decoration(members[Int(w[3])], SPV.decArrayStride),
      stride != 0
    else { throw .invalid("OpArrayLength of a member that isn't a runtime array with an Offset and an ArrayStride") }
    let rangeAt = offset(desc, by: 8, pre: false)
    let range = loadDouble(at: rangeAt, pre: false)
    let rest = emit(SPV.opISub, ulongType(), [range, ulong(UInt64(start))], pre: false)
    if stride & (stride - 1) == 0 {
      // A power of two: a shift (the Valhall backend has no integer division).
      let count = emit(SPV.opShiftRightLogical, ulongType(), [rest, ulong(UInt64(stride.trailingZeroBitCount))], pre: false)
      emitAs(SPV.opUConvert, w[0], w[1], [count], pre: false)
    } else {
      let count = emit(SPV.opUDiv, ulongType(), [rest, ulong(UInt64(stride))], pre: false)
      emitAs(SPV.opUConvert, w[0], w[1], [count], pre: false)
    }
  }

  // MARK: images and samplers

  /// The heap's array of `kind` (0 textures, 1 samplers, 2 storage images) of `element`, declared once.
  mutating func heapVar(_ kind: Int, _ element: UInt32) -> HeapVar {
    for h in heapVars where h.kind == kind && h.element == element { return h }
    let array = findType(SPV.opTypeRuntimeArray, [element])
    let arrayPointer = findType(SPV.opTypePointer, [SPV.uniformConstant, array])
    let elementPointer = findType(SPV.opTypePointer, [SPV.uniformConstant, element])
    let id = newVariable(arrayPointer, storage: SPV.uniformConstant)
    decorate(id, SPV.decDescriptorSet, [0])
    decorate(id, SPV.decBinding, [UInt32(kind)])
    extraInterface.append((id: id, isInput: false))
    needRuntimeArray = true
    let h = HeapVar(kind: kind, element: element, variable: id, elementPointer: elementPointer)
    heapVars.append(h)
    return h
  }

  /// One element of a heap array: its handle loaded as `result` (a new id for 0).
  mutating func loadFromHeap(_ kind: Int, element: UInt32, slot: UInt32, result: UInt32, dynamic: Bool) -> UInt32 {
    let h = heapVar(kind, element)
    let pointer = emit(SPV.opAccessChain, h.elementPointer, [h.variable, slot], pre: false)
    let id = result != 0 ? result : newId()
    emitAs(SPV.opLoad, element, id, [pointer], pre: false)
    if dynamic {
      needNonUniform = true
      if kind == 2 { needStorageArrayNonUniform = true } else { needSampledArrayNonUniform = true }
      markNonUniform(slot)
      markNonUniform(pointer)
      markNonUniform(id)
      if check(id) { nonUniform[Int(id)] = true }
    }
    return id
  }

  /// OpLoad of an image, a sampler or a combined image sampler: its heap slots read from the set record.
  mutating func loadHandle(_ inst: RawInst, variable vi: Int, index: ElementIndex) throws(LoweringError) {
    let v = vars[vi]
    let result = inst.w[1]
    var dynamic = false
    if case .dynamic = index { dynamic = true }
    let desc = descriptorAddress(v, index, pre: false)
    switch v.descriptor {
    case .sampledImage, .storageImage:
      let slot = loadWord(at: desc, pre: false)
      _ = loadFromHeap(v.descriptor == .storageImage ? 2 : 0, element: v.leaf, slot: slot, result: result, dynamic: dynamic)
    case .sampler:
      let slot = loadWord(at: desc, pre: false)
      _ = loadFromHeap(1, element: v.leaf, slot: slot, result: result, dynamic: dynamic)
    case .combinedImageSampler:
      guard case .sampledImage(let image)? = typeOf(v.leaf) else { throw .invalid("a combined image sampler without an image") }
      let samplerType = findType(SPV.opTypeSampler, [])
      let textureSlot = loadWord(at: desc, pre: false)
      let samplerSlot = loadWord(at: offset(desc, by: 4, pre: false), pre: false)
      let texture = loadFromHeap(0, element: image, slot: textureSlot, result: 0, dynamic: dynamic)
      let sampler = loadFromHeap(1, element: samplerType, slot: samplerSlot, result: 0, dynamic: dynamic)
      emitAs(SPV.opSampledImage, v.leaf, result, [texture, sampler], pre: false)
      if dynamic, check(result) {
        nonUniform[Int(result)] = true
        markNonUniform(result)
      }
    default: throw .invalid("a descriptor that is not an image or a sampler")
    }
  }
}
