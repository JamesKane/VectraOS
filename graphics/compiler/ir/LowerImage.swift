// SPDX-License-Identifier: BSD-3-Clause

// SPIR-V images, samplers and sampled images to IR (D174 section 3, step 3).
//
// An image, a sampler or a sampled image is not a value in a register; the lowering follows it at compile time as an
// `Opaque`: the (set, binding) of the UniformConstant variable it came from and the element index (an i32 value, zero
// for a variable that is not an array). OpLoad of such a variable, OpAccessChain into an array of them, OpSampledImage
// and OpImage only move the record; the access (OpImageSampleImplicitLod, OpImageSampleExplicitLod, OpImageFetch)
// becomes four `tex` instructions, one a component of the texel, which the backend merges into one message.
//
// What is lowered is in LowerTexture.swift (the accesses and the queries of sampled images). What is refused, by name:
// buffer and subpass images, MinLod, a cube image's Grad, a projective depth compare, storage images read as sampled, and an
// image or sampler passed to a function or through a phi. NonUniform changes nothing: the handle is a value a lane computes.

/// An image or a sampler as the lowering follows it: its binding and element.
struct BindingRef {
  var set: Int
  var binding: Int
  /// The element of the binding's array: an i32 value of the function being lowered.
  var index: ValueID
}

struct Opaque {
  var image: BindingRef?
  var sampler: BindingRef?
  /// The OpTypeImage id of the image (for the dimensions and the texel type).
  var imageType: UInt32 = 0
}

extension Lowerer {
  /// The type an opaque value has behind its pointers and arrays: an image, a sampler or a sampled image.
  func opaqueLeaf(_ t: UInt32) -> UInt32? {
    switch m.type(t) {
    case .image?, .sampler?, .sampledImage?: return t
    case .array(let e, _)?: return opaqueLeaf(e)
    case .runtimeArray(let e)?: return opaqueLeaf(e)
    default: return nil
    }
  }

  /// Whether a pointer operand is a UniformConstant variable of an opaque type (or already followed as one).
  func isOpaqueAccess(_ id: UInt32) -> Bool {
    if Int(id) < opaque.count, opaque[Int(id)] != nil { return true }
    guard Int(id) < m.variableIndex.count, m.variableIndex[Int(id)] >= 0 else { return false }
    let v = m.variables[Int(m.variableIndex[Int(id)])]
    guard v.storage == StorageClass.uniformConstant, case .pointer(_, let pointee)? = m.type(v.type) else { return false }
    return opaqueLeaf(pointee) != nil
  }

  /// The record of a pointer operand, made from the variable's decorations the first time.
  mutating func opaquePointer(_ id: UInt32, _ i: SPIRVInstruction) throws(CompileError) -> Opaque {
    if let o = opaque[Int(id)] { return o }
    let v = m.variables[Int(m.variableIndex[Int(id)])]
    guard let set = m.decoration(v.id, Decor.descriptorSet)?.first, let binding = m.decoration(v.id, Decor.binding)?.first else {
      throw fail(i, "variable %\(v.id) has no DescriptorSet and Binding")
    }
    guard case .pointer(_, let pointee)? = m.type(v.type), let leaf = opaqueLeaf(pointee) else { throw fail(i, "not an opaque type") }
    let ref = BindingRef(set: Int(set), binding: Int(binding), index: f.constant(.i32, 0))
    var o = Opaque()
    try classify(leaf, ref, into: &o, i)
    opaque[Int(id)] = o
    return o
  }

  /// Put a binding in the record's image or sampler slot by its type.
  func classify(_ leaf: UInt32, _ ref: BindingRef, into o: inout Opaque, _ i: SPIRVInstruction) throws(CompileError) {
    switch m.type(leaf) {
    case .image?:
      o.image = ref
      o.imageType = leaf
    case .sampler?: o.sampler = ref
    case .sampledImage?:
      throw fail(i, "a combined image sampler is not supported (the heap holds textures and samplers apart)")
    default: throw fail(i, "not an image or a sampler")
    }
  }

  mutating func lowerOpaqueLoad(_ i: SPIRVInstruction) throws(CompileError) {
    let id = i.operands[0]
    if Int(id) < opaque.count, opaque[Int(id)] == nil { _ = try opaquePointer(id, i) }
    guard let o = opaque[Int(id)] else { throw fail(i, "%\(id) is not an image, sampler or array of them") }
    opaque[Int(i.result)] = o
  }

  mutating func lowerOpaqueChain(_ i: SPIRVInstruction) throws(CompileError) {
    let o = i.operands
    let base = try opaquePointer(o[0], i)
    guard o.count == 2 else { throw fail(i, "only one index into an array of images or samplers is supported") }
    let idx = try val(o[1], i)
    guard case .scalar(let s) = f.type(idx), s.isInt else { throw fail(i, "the index is not an integer") }
    var index = idx
    if s != .i32 { index = emit(s.bits < 32 ? .zext : .trunc, .i32, [idx]) }
    var r = base
    if r.image != nil { r.image?.index = index }
    if r.sampler != nil { r.sampler?.index = index }
    opaque[Int(i.result)] = r
  }

  // MARK: the operations

  mutating func lowerImageOp(_ i: SPIRVInstruction) throws(CompileError) {
    let o = i.operands
    switch i.op {
    case Op.sampledImage:
      guard o.count == 2, let image = opaque[Int(o[0])], let sampler = opaque[Int(o[1])], image.image != nil, sampler.sampler != nil
      else { throw fail(i, "needs an image and a sampler") }
      guard case .sampledImage(let it)? = m.type(i.type) else { throw fail(i, "the result is not a sampled image") }
      var r = Opaque()
      r.image = image.image
      r.sampler = sampler.sampler
      r.imageType = it
      opaque[Int(i.result)] = r
    case Op.image:
      guard o.count == 1, var r = opaque[Int(o[0])], r.image != nil else { throw fail(i, "needs a sampled image") }
      r.sampler = nil
      opaque[Int(i.result)] = r
    default:
      try lowerImageAccess(i)
    }
  }

  /// A float as the i32 an s8.8 level word holds: clamped to [-16, 16], times 256, converted (12b.5.5).
  mutating func levelWord(_ lod: ValueID) -> ValueID {
    let hi = f.constant(.f32, UInt64(Float(16).bitPattern))
    let lo = f.constant(.f32, UInt64(Float(-16).bitPattern))
    let scale = f.constant(.f32, UInt64(Float(256).bitPattern))
    let c = emit(.fmin, .f32, [emit(.fmax, .f32, [lod, lo]), hi])
    let n = emit(.fptosi, .i32, [emit(.fmul, .f32, [c, scale])])
    return emit(.and, .i32, [n, f.constant(.i32, 0xFFFF)])
  }
}
