// SPDX-License-Identifier: BSD-3-Clause

// One stage of a linked program into SPIR-V: one entry function, every user function inlined into it (GLSL ES has no
// recursion), so each variable is a Function variable the compiler's mem2reg promotes, each sampler argument names its
// binding, and the outputs are written where the compiler takes them (the entry). A matrix is an array of its
// columns (the compiler has no matrix types), its products written out as vector multiplies and fused multiply-adds.
// Every constant expression is a constant; a pure `&&`, `||` or `?:` is a logical operation or a select, not a branch.

/// Where a variable of the program lives in the SPIR-V.
enum Place {
  /// A pointer (and its storage class), with the steps that reach the variable from it (a uniform's member of the
  /// block); `laid` for the uniform block, whose types are std140's (a bool a uint).
  case memory(UInt32, UInt32, laid: Bool, prefix: [Step])
  /// An SSA value (an in parameter the function never writes, an attribute, an adjusted built-in).
  case value(UInt32)
  /// An in parameter that is a sampler, or a structure holding one: the argument it stands for.
  case alias(Ref)
  /// A sampler uniform (or a structure or array of them): its leaves' bindings are by name.
  case sampler(String)
}

enum Step {
  case member(Int)
  /// An index: the value's id, and the constant when it is one.
  case index(UInt32, Int?)
}

struct Ref {
  enum Root {
    case memory(UInt32, UInt32, laid: Bool)
    case value(UInt32)
    case sampler(String)
  }
  var root: Root
  var rootType: GType
  var steps: [Step]
  /// Components of the vector the steps reach.
  var swizzle: [Int]?
  /// The type the steps reach (the vector a swizzle takes from).
  var type: GType
  /// A uniform's name, for its samplers' bindings when it is a structure in the block that holds some.
  var uniform: String? = nil
}

/// What the link decided that a stage's code needs.
struct StageLayout {
  /// The uniform block's members after the driver's words: each uniform's name and its offset.
  var blockMembers: [(name: String, offset: Int)] = []
  var blockBytes = 0
  var driver = false
  var samplerBindings: [String: Int] = [:]
  /// Each varying the fragment stage reads: its first location.
  var varyings: [String: Int] = [:]
  var attributes: [String: Int] = [:]
  var clip: GLSLClipControl = .gl
  var entryPoint = "main"
}

/// A function being inlined: where its returns go.
struct InlineFrame {
  var returnVar: UInt32?
  /// The wrapper loop's merge, when the function returns before its end.
  var exit: UInt32?
  var flag: UInt32?
  var loopBase: Int
}

struct CodeGen {
  var b = Builder()
  let prog: Program
  let layout: StageLayout
  var places: [Int: Place] = [:]
  var code: [UInt32] = []
  var locals: [UInt32] = []
  var interface: [UInt32] = []
  var terminated = false
  var currentLabel: UInt32 = 0
  var loops: [(merge: UInt32, cont: UInt32, returns: Bool)] = []
  var frames: [InlineFrame] = []
  var uniformBlock: UInt32 = 0
  var samplerVars: [Int: UInt32] = [:]
  var laidStructs: [Int: (id: UInt32, size: Int, map: [Int?])] = [:]
  var epilogue: [(from: UInt32, type: GType, outputs: [UInt32])] = []
  var errors: [String] = []
  /// The entry block's first instructions after its variables: the uniforms' loads.
  var prologue: [UInt32] = []
  var uniformValues: [String: UInt32] = [:]

  init(prog: Program, layout: StageLayout) {
    self.prog = prog
    self.layout = layout
  }

  // MARK: emitting

  @discardableResult
  mutating func emit(_ op: UInt16, _ type: UInt32, _ operands: [UInt32], relaxed: Bool = false) -> UInt32 {
    let r = b.id()
    code += Builder.instruction(op, [type, r] + operands)
    if relaxed { b.decorate(r, Decoration.relaxedPrecision) }
    return r
  }

  mutating func emitVoid(_ op: UInt16, _ operands: [UInt32]) { code += Builder.instruction(op, operands) }

  mutating func ext(_ n: UInt32, _ type: UInt32, _ args: [UInt32], relaxed: Bool = false) -> UInt32 {
    emit(SpvOp.extInst, type, [b.glsl, n] + args, relaxed: relaxed)
  }

  mutating func label(_ l: UInt32) {
    code += Builder.instruction(SpvOp.label, [l])
    currentLabel = l
    terminated = false
  }

  mutating func branch(_ to: UInt32) {
    if terminated { return }
    emitVoid(SpvOp.branch, [to])
    terminated = true
  }

  mutating func local(_ t: GType, name: String? = nil) -> UInt32 {
    let p = b.pointer(StorageClass.function, ty(t))
    let r = b.id()
    locals += Builder.instruction(SpvOp.variable, [p, r, StorageClass.function])
    if let n = name, !n.isEmpty { b.name(r, n) }
    return r
  }

  // MARK: types

  mutating func ty(_ t: GType) -> UInt32 {
    if t.isArray { return b.array(ty(t.element), t.arraySize) }
    switch t.basic {
    case .void, .error: return b.void
    case .float, .int, .bool:
      let s = t.basic == .float ? b.float : t.basic == .int ? b.int : b.bool
      if t.cols > 1 { return b.array(b.vector(s, t.rows), t.cols) }
      return b.vector(s, t.rows)
    case .sampler2D: return b.sampledImage(cube: false)
    case .samplerCube: return b.sampledImage(cube: true)
    case .structure:
      if let x = b.cache["s\(t.structID)"] { return x }
      let s = prog.structs[t.structID]
      var ms: [UInt32] = []
      for m in s.members where !m.type.isSampler { ms.append(ty(m.type)) }
      let r = b.structure(ms, key: "s\(t.structID)")
      b.name(r, s.name)
      var k = 0
      for m in s.members where !m.type.isSampler {
        b.memberName(r, k, m.name)
        k += 1
      }
      return r
    }
  }

  func std140(_ t: GType) -> (align: Int, size: Int) { prog.std140(t) }

  /// The block's (std140) type of `t`, and for a structure the laid-out member each member is (nil for a sampler).
  mutating func laidType(_ t: GType) -> UInt32 {
    if t.isArray {
      let e = std140(t.element)
      return b.array(laidType(t.element), t.arraySize, stride: roundUp(e.size, max(e.align, 16)))
    }
    switch t.basic {
    case .bool: return b.vector(b.uint, t.rows)
    case .float, .int:
      if t.isMatrix { return b.array(b.vector(b.float, t.rows), t.cols, stride: 16) }
      return ty(t)
    case .structure: return laidStruct(t.structID).id
    default: return ty(t)
    }
  }

  mutating func laidStruct(_ s: Int) -> (id: UInt32, size: Int, map: [Int?]) {
    if let x = laidStructs[s] { return x }
    var ms: [UInt32] = []
    var map: [Int?] = []
    var offsets: [Int] = []
    var off = 0
    for m in prog.structs[s].members {
      if std140(m.type).size == 0 {
        map.append(nil)
        continue
      }
      let x = std140(m.type)
      off = roundUp(off, x.align)
      offsets.append(off)
      off += x.size
      map.append(ms.count)
      ms.append(laidType(m.type))
    }
    let r = b.structure(ms)
    for (i, o) in offsets.enumerated() { b.memberDecorate(r, i, Decoration.offset, [UInt32(o)]) }
    let x = (id: r, size: std140(GType(basic: .structure, structID: s)).size, map: map)
    laidStructs[s] = x
    return x
  }

  /// A type's laid form differs from its logical one (a load needs converting).
  func needsConversion(_ t: GType) -> Bool { t.basic == .bool || t.isMatrix || t.isArray || t.isStruct }

  // MARK: constants

  mutating func constant(_ t: GType, _ v: [Scalar]) -> UInt32 {
    if t.isArray {
      let w = prog.flatCount(t.element)
      var parts: [UInt32] = []
      for i in 0..<t.arraySize { parts.append(constant(t.element, Array(v[(i * w)..<((i + 1) * w)]))) }
      return b.composite(ty(t), parts)
    }
    if t.isStruct {
      var parts: [UInt32] = []
      var off = 0
      for m in prog.structs[t.structID].members {
        let w = prog.flatCount(m.type)
        parts.append(constant(m.type, Array(v[off..<(off + w)])))
        off += w
      }
      return b.composite(ty(t), parts)
    }
    if t.isMatrix {
      var cols: [UInt32] = []
      for c in 0..<t.cols { cols.append(constant(t.column, Array(v[(c * t.rows)..<((c + 1) * t.rows)]))) }
      return b.composite(ty(t), cols)
    }
    func scalar(_ s: Scalar) -> UInt32 {
      switch s.converted(to: t.basic) {
      case .f(let x): return b.constant(float: x)
      case .i(let x): return b.constant(int: x)
      case .b(let x): return b.constant(bool: x)
      }
    }
    if t.rows == 1 { return scalar(v[0]) }
    return b.composite(ty(t), v.prefix(t.rows).map { scalar($0) })
  }

  mutating func splat(_ s: UInt32, _ t: GType) -> UInt32 {
    if t.rows == 1 { return s }
    return emit(SpvOp.compositeConstruct, ty(t), [UInt32](repeating: s, count: t.rows))
  }

  mutating func one(_ t: GType) -> UInt32 {
    constant(t, [Scalar](repeating: t.basic == .float ? .f(1) : .i(1), count: t.components))
  }

  // MARK: places and references

  mutating func ref(_ e: Expr) -> Ref {
    switch e.kind {
    case .variable(let v):
      if e.value == nil || prog.variables[v].storage != .constant {
        return rootRef(v)
      }
    case .field(let base, let i) where e.value == nil:
      var r = ref(base)
      if r.swizzle == nil {
        r.steps.append(.member(i))
        r.type = e.type
        return r
      }
    case .index(let base, let i) where e.value == nil:
      var r = ref(base)
      if r.swizzle == nil {
        let iv = value(i)
        r.steps.append(.index(iv, i.value.map { Int($0[0].int) }))
        r.type = e.type
        return r
      }
      // A swizzle indexed: the component it names.
      if let c = i.value {
        r.swizzle = [r.swizzle![Int(c[0].int)]]
        return r
      }
    case .swizzle(let base, let comps) where e.value == nil:
      var r = ref(base)
      if let s = r.swizzle {
        r.swizzle = comps.map { s[$0] }
      } else {
        r.swizzle = comps
      }
      return r
    default: break
    }
    return Ref(root: .value(value(e)), rootType: e.type, steps: [], swizzle: nil, type: e.type)
  }

  mutating func rootRef(_ v: Int) -> Ref {
    let t = prog.variables[v].type
    let p = place(v)
    switch p {
    case .memory(let ptr, let sc, let laid, let prefix):
      var r = Ref(root: .memory(ptr, sc, laid: laid), rootType: t, steps: prefix, swizzle: nil, type: t)
      if laid { r.uniform = prog.variables[v].name }
      return r
    case .value(let x):
      return Ref(root: .value(x), rootType: t, steps: [], swizzle: nil, type: t)
    case .alias(let r):
      return r
    case .sampler(let name):
      return Ref(root: .sampler(name), rootType: t, steps: [], swizzle: nil, type: t)
    }
  }

  /// The place of a variable, made the first time a global is used (locals and parameters are placed when declared).
  mutating func place(_ v: Int) -> Place {
    if let p = places[v] { return p }
    let x = prog.variables[v]
    var p: Place
    switch x.storage {
    case .uniform:
      if prog.hasSampler(x.type) && std140(x.type).size == 0 {
        p = .sampler(x.name)
      } else if let i = layout.blockMembers.firstIndex(where: { $0.name == x.name }) {
        p = .memory(blockVariable(), StorageClass.uniform, laid: true, prefix: [.member(i + 7)])
      } else {
        errors.append("uniform \(x.name) has no place in the block")
        p = .value(b.undef(ty(x.type)))
      }
    case .constant:
      p = .value(x.value.map { constant(x.type, $0) } ?? b.undef(ty(x.type)))
    case .global, .local, .param:
      p = .memory(local(x.type, name: x.name), StorageClass.function, laid: false, prefix: [])
    default:
      p = .value(b.undef(ty(x.type)))
      errors.append("variable \(x.name) was not placed")
    }
    places[v] = p
    return p
  }

  mutating func blockVariable() -> UInt32 {
    if uniformBlock != 0 { return uniformBlock }
    var ms: [UInt32] = []
    for _ in 0..<7 { ms.append(b.float) }
    var offsets: [Int] = (0..<7).map { $0 * 4 }
    for m in layout.blockMembers {
      guard let v = prog.variables.firstIndex(where: { $0.storage == .uniform && $0.name == m.name }) else {
        // The other stage's uniform: this stage declares a word at its offset (the members after it have theirs).
        ms.append(b.float)
        offsets.append(m.offset)
        continue
      }
      ms.append(laidType(prog.variables[v].type))
      offsets.append(m.offset)
    }
    let st = b.structure(ms)
    b.decorate(st, Decoration.block)
    for (i, o) in offsets.enumerated() { b.memberDecorate(st, i, Decoration.offset, [UInt32(o)]) }
    b.name(st, "Uniforms")
    let v = b.variable(b.pointer(StorageClass.uniform, st), StorageClass.uniform)
    b.decorate(v, Decoration.descriptorSet, [0])
    b.decorate(v, Decoration.binding, [0])
    b.name(v, "uniforms")
    uniformBlock = v
    return v
  }

  /// A driver word of the block (0 positionYScale ... 6 depthRangeDiff).
  mutating func driverWord(_ k: Int) -> UInt32 {
    let p = emit(SpvOp.accessChain, b.pointer(StorageClass.uniform, b.float), [blockVariable(), b.constant(int: Int32(k))])
    return emit(SpvOp.load, b.float, [p])
  }

  // MARK: loads and stores

  /// The access chain's indices from the steps, and the type reached; in the block, a structure's members are the laid
  /// ones.
  mutating func chain(_ r: Ref, laid: Bool) -> [UInt32] {
    var ids: [UInt32] = []
    var t = r.rootType
    var first = true
    for s in r.steps {
      switch s {
      case .member(let i):
        if first && laid {
          ids.append(b.constant(int: Int32(i)))
          first = false
          continue
        }
        let m = prog.structs[t.structID].members[i]
        let idx = laid ? laidStruct(t.structID).map[i]! : logicalIndex(t.structID, i)
        ids.append(b.constant(int: Int32(idx)))
        t = m.type
      case .index(let id, _):
        ids.append(id)
        t = t.isArray ? t.element : t.column
      }
      first = false
    }
    return ids
  }

  /// A structure member's index among the logical struct's (its samplers are left out).
  func logicalIndex(_ s: Int, _ i: Int) -> Int {
    var k = 0
    for m in prog.structs[s].members[..<i] where !m.type.isSampler { k += 1 }
    return k
  }

  mutating func pointerTo(_ r: Ref) -> (ptr: UInt32, laid: Bool, sc: UInt32) {
    guard case .memory(let base, let sc, let laid) = r.root else { fatalError("not memory") }
    let ids = chain(r, laid: laid)
    if ids.isEmpty { return (base, laid, sc) }
    let pt = b.pointer(sc, laid ? laidType(r.type) : ty(r.type))
    return (emit(SpvOp.accessChain, pt, [base] + ids), laid, sc)
  }

  mutating func load(_ r: Ref, relaxed: Bool = false) -> UInt32 {
    var v: UInt32
    if r.type.isSampler, case .memory = r.root { return samplerValue(r) }
    switch r.root {
    case .memory(_, _, let laid) where laid && r.steps.allSatisfy({ if case .index(_, nil) = $0 { return false } else { return true } }):
      v = uniformValue(r)
    case .memory:
      let (p, laid, _) = pointerTo(r)
      v = laid ? loadLaid(p, r.type, relaxed: relaxed) : emit(SpvOp.load, ty(r.type), [p], relaxed: relaxed && r.type.basic == .float)
    case .value(let x):
      v = extractSteps(x, r.rootType, r.steps)
    case .sampler:
      v = samplerValue(r)
    }
    if let s = r.swizzle {
      let st = GType(basic: r.type.basic, rows: s.count)
      if s.count == 1 {
        v = emit(SpvOp.compositeExtract, ty(st), [v, UInt32(s[0])])
      } else {
        v = emit(SpvOp.vectorShuffle, ty(st), [v, v] + s.map { UInt32($0) })
      }
    }
    return v
  }

  /// A part of the uniform block reached by constant steps: loaded once, at the entry's start (where it dominates every
  /// use, and the load's latency is the earliest), and the same value after.
  mutating func uniformValue(_ r: Ref) -> UInt32 {
    var key = ""
    for st in r.steps {
      switch st {
      case .member(let i): key += ".\(i)"
      case .index(_, let c): key += "[\(c!)]"
      }
    }
    if let v = uniformValues[key] { return v }
    let saved = code
    code = prologue
    let (p, _, _) = pointerTo(r)
    let v = loadLaid(p, r.type, relaxed: false)
    prologue = code
    code = saved
    uniformValues[key] = v
    return v
  }

  /// A value's part: constant steps are extracts; a variable index of a vector is a dynamic extract, of anything else a
  /// load from a copy in memory.
  mutating func extractSteps(_ x: UInt32, _ t0: GType, _ steps: [Step]) -> UInt32 {
    var v = x
    var t = t0
    for (k, s) in steps.enumerated() {
      switch s {
      case .member(let i):
        let mt = prog.structs[t.structID].members[i].type
        v = emit(SpvOp.compositeExtract, ty(mt), [v, UInt32(logicalIndex(t.structID, i))])
        t = mt
      case .index(let id, let c):
        let et = t.isArray ? t.element : t.column
        if let c = c {
          v = emit(SpvOp.compositeExtract, ty(et), [v, UInt32(c)])
        } else if t.isVector {
          v = emit(SpvOp.vectorExtractDynamic, ty(et), [v, id])
        } else {
          let tmp = local(t)
          emitVoid(SpvOp.store, [tmp, v])
          let r = Ref(root: .memory(tmp, StorageClass.function, laid: false), rootType: t, steps: Array(steps[k...]), swizzle: nil, type: .void)
          var rr = r
          rr.type = typeAfter(t, Array(steps[k...]))
          return load(rr)
        }
        t = et
      }
    }
    return v
  }

  func typeAfter(_ t0: GType, _ steps: [Step]) -> GType {
    var t = t0
    for s in steps {
      switch s {
      case .member(let i): t = prog.structs[t.structID].members[i].type
      case .index: t = t.isArray ? t.element : t.column
      }
    }
    return t
  }

  /// A load from the uniform block, converted to the logical type (a bool from its word; a matrix, an array or a
  /// structure part by part).
  mutating func loadLaid(_ p: UInt32, _ t: GType, relaxed: Bool) -> UInt32 {
    if !needsConversion(t) { return emit(SpvOp.load, ty(t), [p], relaxed: relaxed && t.basic == .float) }
    if t.basic == .bool && !t.isArray {
      let ut = b.vector(b.uint, t.rows)
      let w = emit(SpvOp.load, ut, [p])
      let zero = t.rows == 1 ? b.constant(uint: 0) : b.composite(ut, [UInt32](repeating: b.constant(uint: 0), count: t.rows))
      return emit(SpvOp.iNotEqual, ty(t), [w, zero])
    }
    var parts: [UInt32] = []
    if t.isArray || t.isMatrix {
      let n = t.isArray ? t.arraySize : t.cols
      let et = t.isArray ? t.element : t.column
      for i in 0..<n {
        let q = emit(SpvOp.accessChain, b.pointer(StorageClass.uniform, laidType(et)), [p, b.constant(int: Int32(i))])
        parts.append(loadLaid(q, et, relaxed: relaxed))
      }
    } else {
      let s = laidStruct(t.structID)
      for (i, m) in prog.structs[t.structID].members.enumerated() {
        guard let li = s.map[i] else { continue }
        let q = emit(SpvOp.accessChain, b.pointer(StorageClass.uniform, laidType(m.type)), [p, b.constant(int: Int32(li))])
        parts.append(loadLaid(q, m.type, relaxed: relaxed))
      }
    }
    return emit(SpvOp.compositeConstruct, ty(t), parts)
  }

  mutating func store(_ r: Ref, _ v: UInt32) {
    guard case .memory = r.root else {
      errors.append("a store to a value")
      return
    }
    if let s = r.swizzle {
      if s.count == 1 {
        var rr = r
        rr.swizzle = nil
        rr.steps.append(.index(b.constant(int: Int32(s[0])), s[0]))
        rr.type = r.type.scalar
        let (p, _, _) = pointerTo(rr)
        emitVoid(SpvOp.store, [p, v])
        return
      }
      var whole = r
      whole.swizzle = nil
      let (p, _, _) = pointerTo(whole)
      let old = emit(SpvOp.load, ty(r.type), [p])
      // Each component the old vector's or the new value's (the compiler's shuffle takes two of one type).
      let st = ty(r.type.scalar)
      var parts: [UInt32] = []
      for c in 0..<r.type.rows {
        if let k = s.firstIndex(of: c) {
          parts.append(emit(SpvOp.compositeExtract, st, [v, UInt32(k)]))
        } else {
          parts.append(emit(SpvOp.compositeExtract, st, [old, UInt32(c)]))
        }
      }
      let nv = emit(SpvOp.compositeConstruct, ty(r.type), parts)
      emitVoid(SpvOp.store, [p, nv])
      return
    }
    let (p, _, _) = pointerTo(r)
    emitVoid(SpvOp.store, [p, v])
  }

  // MARK: samplers

  /// The leaf name of a sampler reference (`s`, `a[2]`, `st.tex`), its indices constant.
  func samplerName(_ r: Ref) -> String? {
    var name: String
    var steps = r.steps[...]
    switch r.root {
    case .sampler(let base): name = base
    case .memory:
      // A sampler in a structure in the block: the steps after the block's member.
      guard let u = r.uniform else { return nil }
      name = u
      steps = steps.dropFirst()
    default: return nil
    }
    var t = r.rootType
    for s in steps {
      switch s {
      case .member(let i):
        let m = prog.structs[t.structID].members[i]
        name += "." + m.name
        t = m.type
      case .index(_, let c):
        guard let c = c else { return nil }
        name += "[\(c)]"
        t = t.element
      }
    }
    if t.isArray { name += "[0]" }
    return name
  }

  mutating func samplerVariable(_ binding: Int, cube: Bool) -> UInt32 {
    if let v = samplerVars[binding] { return v }
    let v = b.variable(b.pointer(StorageClass.uniformConstant, b.sampledImage(cube: cube)), StorageClass.uniformConstant)
    b.decorate(v, Decoration.descriptorSet, [0])
    b.decorate(v, Decoration.binding, [UInt32(binding)])
    samplerVars[binding] = v
    return v
  }

  mutating func samplerValue(_ r: Ref) -> UInt32 {
    let cube = r.type.basic == .samplerCube
    guard let n = samplerName(r) else {
      errors.append("a sampler array indexed by a value that is not a constant expression")
      return b.undef(b.sampledImage(cube: cube))
    }
    guard let binding = layout.samplerBindings[n] else {
      errors.append("sampler \(n) has no binding")
      return b.undef(b.sampledImage(cube: cube))
    }
    let v = samplerVariable(binding, cube: cube)
    return emit(SpvOp.load, b.sampledImage(cube: cube), [v])
  }
}

func roundUp(_ x: Int, _ a: Int) -> Int { (x + a - 1) / a * a }
