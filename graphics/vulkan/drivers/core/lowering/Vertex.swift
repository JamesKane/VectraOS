// SPDX-License-Identifier: BSD-3-Clause

// Vertex input: each Input variable with a Location becomes a Private variable that the entry function fills, before
// anything else runs, from its attribute's words in the vertex buffer: `vertexBuffer[binding] + index * stride +
// offset`, `index` being VertexIndex (InstanceIndex for a per-instance binding), converted from the attribute's format.

/// What an attribute's format delivers: 0 float, 1 unsigned, 2 signed integer components.
private func numeric(_ f: VertexFormat) -> (kind: Int, components: Int, unorm: Bool) {
  switch f {
  case .r32Float: return (0, 1, false)
  case .rg32Float: return (0, 2, false)
  case .rgb32Float: return (0, 3, false)
  case .rgba32Float: return (0, 4, false)
  case .r32Uint: return (1, 1, false)
  case .rg32Uint: return (1, 2, false)
  case .rgb32Uint: return (1, 3, false)
  case .rgba32Uint: return (1, 4, false)
  case .r32Sint: return (2, 1, false)
  case .rg32Sint: return (2, 2, false)
  case .rgb32Sint: return (2, 3, false)
  case .rgba32Sint: return (2, 4, false)
  case .rgba8Unorm: return (0, 4, true)
  }
}

extension Rewriter {
  /// What the variable's type is: the element (float, int or uint) and the component count.
  func inputShape(_ v: VarInfo) throws(LoweringError) -> (element: UInt32, kind: Int, count: Int) {
    var element = v.leaf
    var count = 1
    switch typeOf(v.leaf) {
    case .vector(let e, let n)?:
      element = e
      count = n
    case .matrix?: throw .unsupported("a matrix vertex input")
    case .array?, .runtimeArray?: throw .unsupported("an array vertex input")
    case .structure?: throw .unsupported("a structure vertex input")
    default: break
    }
    switch typeOf(element) {
    case .float(let w)?:
      guard w == 32 else { throw .unsupported("a vertex input of \(w)-bit type") }
      return (element, 0, count)
    case .int(let w, let signed)?:
      guard w == 32 else { throw .unsupported("a vertex input of \(w)-bit type") }
      return (element, signed ? 2 : 1, count)
    default: throw .unsupported("a vertex input that is not a 32-bit float or integer")
    }
  }

  func checkVertexInput(_ v: VarInfo) throws(LoweringError) {
    let shape = try inputShape(v)
    var attribute: VertexAttribute? = nil
    for a in layout.vertexAttributes where a.location == v.location { attribute = a }
    guard let a = attribute else { throw .invalid("the vertex input at location \(v.location) has no attribute") }
    var binding: VertexBinding? = nil
    for b in layout.vertexBindings where b.binding == a.binding { binding = b }
    guard let b = binding else { throw .invalid("the attribute at location \(v.location) names binding \(a.binding), which the layout doesn't have") }
    guard b.binding < UInt32(RootBlock.maxVertexBuffers) else {
      throw .invalid("vertex binding \(b.binding) is over the \(RootBlock.maxVertexBuffers) the root block holds")
    }
    guard a.offset % 4 == 0, b.stride % 4 == 0 else {
      throw .invalid("the attribute at location \(v.location): an offset or a stride that isn't a multiple of 4")
    }
    let (kind, _, _) = numeric(a.format)
    if (kind == 0) != (shape.kind == 0) {
      throw .invalid("the vertex input at location \(v.location) is \(shape.kind == 0 ? "a float" : "an integer") and its attribute is not")
    }
  }

  /// A vertex or instance index as a uint, loaded from the built-in (declared if the program has none).
  mutating func indexBuiltin(_ builtin: UInt32) -> UInt32 {
    var found = -1
    for (n, b) in builtinVars.enumerated() where b.builtin == builtin { found = n }
    if found < 0 {
      for g in m.globals where g.op == SPV.opVariable && g.w.count >= 3 && g.w[2] == SPV.input && check(g.w[1]) {
        if decoration(g.w[1], SPV.decBuiltIn) == builtin, case .pointer(_, let pointee)? = typeOf(g.w[0]) {
          var signed = false
          if case .int(_, let s)? = typeOf(pointee) { signed = s }
          builtinVars.append((builtin: builtin, variable: g.w[1], signed: signed))
          found = builtinVars.count - 1
        }
      }
    }
    if found < 0 {
      let id = newVariable(pointerType(SPV.input, uintType()), storage: SPV.input)
      decorate(id, SPV.decBuiltIn, [builtin])
      extraInterface.append((id: id, isInput: true))
      builtinVars.append((builtin: builtin, variable: id, signed: false))
      found = builtinVars.count - 1
    }
    let b = builtinVars[found]
    let type = b.signed ? intType() : uintType()
    let value = emit(SPV.opLoad, type, [b.variable], pre: true)
    return b.signed ? emit(SPV.opBitcast, uintType(), [value], pre: true) : value
  }

  /// The entry function's start for a vertex shader: every used input fetched and stored.
  mutating func vertexPrologue() throws(LoweringError) {
    for vi in vars.indices where vars[vi].kind == .vertexInput && vars[vi].used {
      let v = vars[vi]
      let shape = try inputShape(v)
      var attribute: VertexAttribute? = nil
      for a in layout.vertexAttributes where a.location == v.location { attribute = a }
      var binding: VertexBinding? = nil
      for b in layout.vertexBindings where b.binding == attribute?.binding { binding = b }
      guard let a = attribute, let b = binding else { throw .invalid("the vertex input at location \(v.location) has no attribute") }

      // Where it is.
      var index: UInt32
      if b.perInstance {
        if fnInstanceIndex == 0 { fnInstanceIndex = indexBuiltin(SPV.builtInInstanceIndex) }
        index = fnInstanceIndex
      } else {
        if fnVertexIndex == 0 { fnVertexIndex = indexBuiltin(SPV.builtInVertexIndex) }
        index = fnVertexIndex
      }
      var address = vertexBufferAddress(Int(b.binding))
      if b.stride != 0 {
        let wide = emit(SPV.opUConvert, ulongType(), [index], pre: true)
        let scaled = b.stride == 1 ? wide : emit(SPV.opIMul, ulongType(), [wide, ulong(UInt64(b.stride))], pre: true)
        address = emit(SPV.opIAdd, ulongType(), [address, scaled], pre: true)
      }
      address = offset(address, by: UInt64(a.offset), pre: true)

      // Its words.
      let (kind, available, unorm) = numeric(a.format)
      let words = unorm ? 1 : available
      var raw: [UInt32] = []
      for k in 0..<words {
        raw.append(loadWord(at: offset(address, by: UInt64(4 * k), pre: true), pre: true))
      }

      // Its components, as the program's type.
      var components: [UInt32] = []
      let uintT = uintType()
      for k in 0..<shape.count {
        if k < available {
          if unorm {
            var byte = raw[0]
            if k > 0 { byte = emit(SPV.opShiftRightLogical, uintT, [byte, uint(UInt64(8 * k))], pre: true) }
            if k < 3 { byte = emit(SPV.opBitwiseAnd, uintT, [byte, uint(255)], pre: true) }
            let f = emit(SPV.opConvertUToF, floatType(), [byte], pre: true)
            components.append(emit(SPV.opFDiv, floatType(), [f, findConstant(floatType(), UInt64(Float(255).bitPattern))], pre: true))
          } else if shape.kind == 0 {
            components.append(emit(SPV.opBitcast, floatType(), [raw[k]], pre: true))
          } else if shape.kind == 2 {
            components.append(emit(SPV.opBitcast, shape.element, [raw[k]], pre: true))
          } else {
            components.append(raw[k])
          }
        } else {
          // What Vulkan fills a missing component with: 0, and 1 for the fourth.
          let one = k == 3
          if shape.kind == 0 {
            components.append(findConstant(floatType(), one ? UInt64(Float(1).bitPattern) : 0))
          } else {
            components.append(findConstant(shape.element, one ? 1 : 0))
          }
        }
      }
      _ = kind
      let value = shape.count == 1 ? components[0] : emit(SPV.opCompositeConstruct, v.leaf, components, pre: true)
      pre.append(RawInst(SPV.opStore, [v.id, value]))
    }
  }
}
