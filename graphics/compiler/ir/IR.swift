// SPDX-License-Identifier: BSD-3-Clause

// The SSA intermediate form every backend of the shader compiler reads.
//
// A module has functions; a function has typed values and instructions in
// arenas, and basic blocks listing instruction ids. Values are scalars,
// small vectors (until the scalarisation pass) and pointers; aggregates do
// not exist: the SPIR-V lowering flattens structs and arrays into their
// leaves and turns aggregate loads and stores into one access a leaf.
//
// Control flow stays structured: a block that heads a selection or a loop
// names its merge block (and a loop its continue block), which is where a
// GPU backend reconverges. Memory is addressed by `ptradd` on a pointer
// that carries its address space; offsets are bytes, from explicit layouts
// (Offset, ArrayStride) where the SPIR-V gives them.

public typealias ValueID = Int
public typealias BlockID = Int

public enum Scalar: Equatable, Sendable {
  case bool, i8, i16, i32, i64, f16, f32, f64

  public var bits: Int {
    switch self {
    case .bool: return 1
    case .i8: return 8
    case .i16, .f16: return 16
    case .i32, .f32: return 32
    case .i64, .f64: return 64
    }
  }
  public var isFloat: Bool { self == .f16 || self == .f32 || self == .f64 }
  public var isInt: Bool { self == .i8 || self == .i16 || self == .i32 || self == .i64 }
  public var name: String {
    switch self {
    case .bool: return "i1"
    case .i8: return "i8"
    case .i16: return "i16"
    case .i32: return "i32"
    case .i64: return "i64"
    case .f16: return "f16"
    case .f32: return "f32"
    case .f64: return "f64"
    }
  }
  var code: UInt64 {
    switch self {
    case .bool: return 1
    case .i8: return 2
    case .i16: return 3
    case .i32: return 4
    case .i64: return 5
    case .f16: return 6
    case .f32: return 7
    case .f64: return 8
    }
  }
  /// An integer scalar of this many bits.
  public static func int(bits: Int) -> Scalar? {
    switch bits {
    case 8: return .i8
    case 16: return .i16
    case 32: return .i32
    case 64: return .i64
    default: return nil
    }
  }
}

/// The address spaces a pointer can point into.
public enum AddrSpace: Equatable, Sendable {
  /// A 64-bit device address (PhysicalStorageBuffer).
  case global
  /// A storage buffer bound by descriptor (set and binding).
  case storage
  /// A uniform buffer bound by descriptor (read only).
  case uniform
  case pushConstant
  /// Memory shared by a workgroup.
  case workgroup
  /// Memory private to an invocation, shared by its functions.
  case private_
  /// An invocation's stack frame (`alloca`).
  case function

  public var name: String {
    switch self {
    case .global: return "global"
    case .storage: return "storage"
    case .uniform: return "uniform"
    case .pushConstant: return "push"
    case .workgroup: return "workgroup"
    case .private_: return "private"
    case .function: return "function"
    }
  }
  /// The integer type of `ptradd`'s byte offset in this space.
  public var offsetType: Scalar { self == .global ? .i64 : .i32 }
  public var pointerBytes: Int { self == .global ? 8 : 4 }
}

public enum IRType: Equatable, Sendable {
  case void
  case scalar(Scalar)
  case vector(Scalar, Int)
  case ptr(AddrSpace)

  public static let bool = IRType.scalar(.bool)
  public static let i32 = IRType.scalar(.i32)
  public static let i64 = IRType.scalar(.i64)
  public static let f32 = IRType.scalar(.f32)

  public var name: String {
    switch self {
    case .void: return "void"
    case .scalar(let s): return s.name
    case .vector(let s, let n): return "<\(n) x \(s.name)>"
    case .ptr(let a): return "ptr<\(a.name)>"
    }
  }
  public var isVector: Bool {
    if case .vector = self { return true }
    return false
  }
  public var isPointer: Bool {
    if case .ptr = self { return true }
    return false
  }
  /// The element type: a vector's scalar, otherwise the type itself.
  public var element: IRType {
    if case .vector(let s, _) = self { return .scalar(s) }
    return self
  }
  public var scalarKind: Scalar? {
    switch self {
    case .scalar(let s), .vector(let s, _): return s
    default: return nil
    }
  }
  public var lanes: Int {
    if case .vector(_, let n) = self { return n }
    return 1
  }
  /// The same shape (scalar or vector of this width) with another element.
  public func with(_ s: Scalar) -> IRType {
    if case .vector(_, let n) = self { return .vector(s, n) }
    return .scalar(s)
  }
  /// Total size in bits of a value of this type (a pointer is its space's).
  public var totalBits: Int {
    switch self {
    case .void: return 0
    case .scalar(let s): return s.bits
    case .vector(let s, let n): return s.bits * n
    case .ptr(let a): return a.pointerBytes * 8
    }
  }
  var key: UInt64 {
    switch self {
    case .void: return 0
    case .scalar(let s): return s.code
    case .vector(let s, let n): return s.code | UInt64(n) << 8 | 1 << 16
    case .ptr(let a):
      switch a {
      case .global: return 2 << 16 | 1
      case .storage: return 2 << 16 | 2
      case .uniform: return 2 << 16 | 3
      case .pushConstant: return 2 << 16 | 4
      case .workgroup: return 2 << 16 | 5
      case .private_: return 2 << 16 | 6
      case .function: return 2 << 16 | 7
      }
    }
  }
}

public enum IROp: String {
  // Integer and bitwise; elementwise on vectors. `and`, `or`, `xor`, `not`
  // work on bools too.
  case iadd, isub, imul, udiv, sdiv, urem, srem, ineg
  case and, or, xor, not, shl, lshr, ashr
  case smin, smax, umin, umax
  // Floating point.
  case fadd, fsub, fmul, fdiv, fneg, fabs, fmin, fmax, fma
  case ffloor, fceil, ftrunc, fround, fsqrt, frsq, fexp2, flog2, fsin, fcos
  // `imm` is the predicate (ICmpPred, FCmpPred); the result is bool-shaped.
  case icmp, fcmp
  /// select(cond, a, b); a scalar cond may select between vectors.
  case select
  case zext, sext, trunc, fptosi, fptoui, sitofp, uitofp, fpext, fptrunc, bitcast
  case ptrtoint, inttoptr
  // Vectors: vecbuild(scalars...), extract(v) at `imm`, insert(v, s) at
  // `imm`, shuffle(a, b) with `payload` lanes (index into a ++ b).
  case vecbuild, extract, insert, shuffle
  // Memory: load(ptr), store(ptr, value), ptradd(ptr, bytes), alloca
  // (`imm` size, `imm2` alignment; the result is ptr<function>).
  case load, store, ptradd, alloca
  /// atomic(ptr, operands...): `imm` is an AtomicKind, `imm2` is
  /// scope << 32 | semantics. The result is the old value (none for store).
  case atomic
  /// barrier: `imm` is the execution scope, `imm2` memory scope << 32 | semantics.
  case barrier
  /// membar: `imm2` as barrier's.
  case membar
  /// The invocation's builtin `imm` (IRBuiltin), component `imm2` (-1: all).
  case builtin
  /// arraylen(ptr): a runtime array's length in elements: (size of the
  /// pointee's binding - `imm`) / `imm2`, `imm` the array's byte offset and
  /// `imm2` its stride.
  case arraylen
  /// stageIn: the value of the vertex or fragment stage's input variable `imm` (an index into the module's `inputs`),
  /// component `imm2` (-1: all of it). stageOut(value): the value of output variable `imm`, component `imm2`
  /// (-1: all), at the point the entry function returns; a component the entry never stores is undefined.
  case stageIn, stageOut
  /// call: `imm` is the callee's function index.
  case call
  /// phi(values...) with `blocks` the matching predecessors.
  case phi
  // Terminators. br: blocks [target]. condbr(cond): blocks [then, else].
  // switch(sel): blocks [default, case targets...], `payload` the case values.
  case br, condbr
  case switch_ = "switch"
  case ret, unreachable
  /// A fragment shader's OpKill: the invocation is discarded. No successors.
  case kill
  /// A fragment shader's OpDemoteToHelperInvocation: the invocation stops having effects and keeps running for its
  /// quad's derivatives. It is not a terminator.
  case demote
  /// A texture access (`TexFlags` says which): component `imm2` of the texel as a scalar. Arguments, in order: the
  /// image's element index in its binding and the sampler's (both i32; the binding is in `payload`, `set << 32 | binding`,
  /// the image's then the sampler's, the all-ones word for no sampler), the coordinates (f32 for a sample, i32 for a
  /// fetch), the layer (i32) when the image is arrayed, the offset word (i32) and the level word (i32) when the
  /// flags say so. Not pure: a computed level needs the lanes of its quad, so it must not move across control flow.
  case tex
  /// A subgroup operation of the backend's own making (valhall 13.9: the lanes of one warp), for the loop that makes a
  /// texture handle warp-uniform (12b.2.1), after the passes: `imm` 0 ballot(bool) -> i32 (bit `i` set when lane `i`
  /// is executing the instruction and its operand is true), `imm` 1 broadcast(i32 value, i32 lane) -> i32 (the value
  /// in lane `lane`, zero when that lane is not executing). Not pure: the lanes it sees are control flow's.
  case lane
  /// A storage image access (`ImgFlags`): `imgload` gives component `imm2` of the texel as a scalar of the format's
  /// type, `imgstore` writes the texel's channels, `imgaddr` is the byte address of the texel as a `ptr<global>` (for
  /// atomics). Arguments, in order: the image's element index in its binding (i32), the coordinates (i32 each), the
  /// layer (i32) when the image is arrayed, then for a store the channels' values (the format's type). `payload` is the
  /// image's binding, `set << 32 | binding`. A load outside the image reads zeros and a store outside it writes nothing
  /// (the descriptor's bounds, valhall 12b.10.1). Not pure.
  case imgload, imgstore, imgaddr
  /// descword(index): word `imm` (0 to 7) of the descriptor, in the resource table, of element `index` of the image binding in
  /// `payload` (`set << 32 | binding`), as an i32: the image's size, levels and samples are fields of it (valhall 12b.13.5).
  /// Not pure: it reads memory.
  case descword

  public var isTerminator: Bool {
    switch self {
    case .br, .condbr, .switch_, .ret, .unreachable, .kill: return true
    default: return false
    }
  }
  /// No side effects and no dependence on memory: can be dropped when
  /// unused, merged when equal.
  public var isPure: Bool {
    switch self {
    case .load, .store, .alloca, .atomic, .barrier, .membar, .call, .phi, .arraylen, .stageOut,
      .br, .condbr, .switch_, .ret, .unreachable, .kill, .demote, .tex, .lane, .imgload, .imgstore, .imgaddr, .descword:
      return false
    default: return true
    }
  }
  /// Can be dropped when its result is unused.
  public var isRemovable: Bool {
    switch self {
    case .store, .atomic, .barrier, .membar, .call, .stageOut, .br, .condbr, .switch_, .ret, .unreachable, .kill, .demote,
      .imgstore:
      return false
    default: return true
    }
  }
  /// Has a result unless its type is void (call) .
  public var neverHasResult: Bool {
    switch self {
    case .store, .barrier, .membar, .stageOut, .br, .condbr, .switch_, .ret, .unreachable, .kill, .demote, .imgstore: return true
    default: return false
    }
  }
}

public enum ICmpPred {
  public static let eq = 0, ne = 1, ult = 2, ule = 3, ugt = 4, uge = 5, slt = 6, sle = 7, sgt = 8, sge = 9
  public static let names = ["eq", "ne", "ult", "ule", "ugt", "uge", "slt", "sle", "sgt", "sge"]
}

public enum FCmpPred {
  public static let oeq = 0, one = 1, olt = 2, ole = 3, ogt = 4, oge = 5
  public static let ueq = 6, une = 7, ult = 8, ule = 9, ugt = 10, uge = 11, ord = 12, uno = 13
  public static let names = [
    "oeq", "one", "olt", "ole", "ogt", "oge", "ueq", "une", "ult", "ule", "ugt", "uge", "ord", "uno",
  ]
}

public enum AtomicKind {
  public static let load = 0, store = 1, xchg = 2, add = 3, sub = 4, and = 5, or = 6, xor = 7
  public static let smin = 8, smax = 9, umin = 10, umax = 11, cmpxchg = 12
  public static let names = [
    "load", "store", "xchg", "add", "sub", "and", "or", "xor", "smin", "smax", "umin", "umax", "cmpxchg",
  ]
}

public enum IRBuiltin {
  public static let numWorkgroups = 0, workgroupId = 1, localInvocationId = 2, globalInvocationId = 3
  public static let localInvocationIndex = 4, subgroupSize = 5, numSubgroups = 6, subgroupId = 7
  public static let subgroupLocalId = 8
  /// Vertex stage: the API vertex and instance indices (i32). Fragment stage: the window position (vec4 f32:
  /// x and y at the pixel centre, z and 1/w the interpolated ones) and the facing (bool, true when front facing).
  public static let vertexIndex = 9, instanceIndex = 10, fragCoord = 11, frontFacing = 12
  /// Driver values the backend reads from the FAU: the viewport's scale and offset (vec3 f32), which a vertex
  /// shader's position is transformed by (valhall 14 section 14.3.3), and the mask of non-perspective varyings (i32).
  public static let viewportScale = 13, viewportOffset = 14, nonPerspectiveMask = 15
  public static let names = [
    "num_workgroups", "workgroup_id", "local_invocation_id", "global_invocation_id", "local_invocation_index",
    "subgroup_size", "num_subgroups", "subgroup_id", "subgroup_local_id", "vertex_index", "instance_index",
    "frag_coord", "front_facing", "viewport_scale", "viewport_offset", "non_perspective_mask",
  ]
  /// The number of components of the builtin (1: a scalar).
  public static func lanes(_ b: Int) -> Int {
    switch b {
    case numWorkgroups, workgroupId, localInvocationId, globalInvocationId, viewportScale, viewportOffset: return 3
    case fragCoord: return 4
    default: return 1
    }
  }
  /// Whether the builtin is a vector (else a scalar).
  public static func isVec3(_ b: Int) -> Bool { lanes(b) > 1 }
  /// The scalar type of the builtin's components.
  public static func scalar(_ b: Int) -> Scalar {
    switch b {
    case fragCoord, viewportScale, viewportOffset: return .f32
    case frontFacing: return .bool
    default: return .i32
    }
  }
}

public enum ValueKind: Equatable {
  /// The result of instruction `n` of the function's arena.
  case inst(Int)
  case param(Int)
  /// A scalar constant: its bits in the low `width` bits.
  case constant(UInt64)
  /// A constant vector of scalar constants.
  case constVec([ValueID])
  case undef
  /// The address of module global `n`.
  case global(Int)
  /// A bound resource (descriptor set, binding).
  case resource(set: Int, binding: Int)
  case pushConstants
}

public struct Value: Equatable {
  public var type: IRType
  public var kind: ValueKind
}

public struct Inst: Equatable {
  public var op: IROp
  /// The result's type (void: none).
  public var type: IRType
  public var args: [ValueID]
  public var result: ValueID = -1
  public var imm: Int = 0
  public var imm2: Int = 0
  public var blocks: [BlockID] = []
  public var payload: [UInt64] = []

  public init(_ op: IROp, _ type: IRType, _ args: [ValueID] = [], imm: Int = 0, imm2: Int = 0,
              blocks: [BlockID] = [], payload: [UInt64] = []) {
    self.op = op
    self.type = type
    self.args = args
    self.imm = imm
    self.imm2 = imm2
    self.blocks = blocks
    self.payload = payload
  }
}

public enum BlockKind { case plain, selection, loop }

public struct Block {
  /// Ids into the function's instruction arena; the last is the terminator.
  public var insts: [Int] = []
  public var kind: BlockKind = .plain
  /// For a selection or loop header: the block where flow reconverges.
  public var merge: BlockID = -1
  /// For a loop header: the continue target.
  public var continueTarget: BlockID = -1
}

public struct Function {
  public var name: String
  public var params: [IRType]
  public var returns: IRType
  public var values: [Value] = []
  public var insts: [Inst] = []
  public var blocks: [Block] = []
  private var constIndex = HashTable()

  public init(name: String, params: [IRType], returns: IRType) {
    self.name = name
    self.params = params
    self.returns = returns
    for (i, t) in params.enumerated() { values.append(Value(type: t, kind: .param(i))) }
  }

  /// The value of parameter `n`.
  public func param(_ n: Int) -> ValueID { n }

  public mutating func addBlock() -> BlockID {
    blocks.append(Block())
    return blocks.count - 1
  }

  /// A scalar constant (bits are masked to the type's width).
  public mutating func constant(_ s: Scalar, _ bits: UInt64) -> ValueID {
    let b = s.bits >= 64 ? bits : bits & ((1 << UInt64(s.bits)) - 1)
    let type = IRType.scalar(s)
    let h = hashMix(type.key, b)
    if let v = constIndex.find(h, { values[$0].type == type && values[$0].kind == .constant(b) }) { return v }
    values.append(Value(type: type, kind: .constant(b)))
    constIndex.insert(h, values.count - 1)
    return values.count - 1
  }

  /// A vector constant from scalar constants.
  public mutating func constVector(_ elems: [ValueID]) -> ValueID {
    guard case .scalar(let s) = values[elems[0]].type else { fatalError("constVector of non-scalars") }
    let type = IRType.vector(s, elems.count)
    var h = type.key
    for e in elems { h = hashMix(h, UInt64(e)) }
    if let v = constIndex.find(h, { values[$0].type == type && values[$0].kind == .constVec(elems) }) { return v }
    values.append(Value(type: type, kind: .constVec(elems)))
    constIndex.insert(h, values.count - 1)
    return values.count - 1
  }

  /// A constant of any scalar or vector type with the same bits in every lane.
  public mutating func splat(_ type: IRType, _ bits: UInt64) -> ValueID {
    switch type {
    case .scalar(let s): return constant(s, bits)
    case .vector(let s, let n):
      let c = constant(s, bits)
      return constVector([ValueID](repeating: c, count: n))
    default: fatalError("splat of \(type.name)")
    }
  }

  public mutating func undef(_ type: IRType) -> ValueID {
    let h = hashMix(type.key, 0xdead)
    if let v = constIndex.find(h, { values[$0].type == type && values[$0].kind == .undef }) { return v }
    values.append(Value(type: type, kind: .undef))
    constIndex.insert(h, values.count - 1)
    return values.count - 1
  }

  public mutating func global(_ index: Int, space: AddrSpace) -> ValueID {
    let h = hashMix(0x91, UInt64(index))
    if let v = constIndex.find(h, { values[$0].kind == .global(index) }) { return v }
    values.append(Value(type: .ptr(space), kind: .global(index)))
    constIndex.insert(h, values.count - 1)
    return values.count - 1
  }

  public mutating func resource(set: Int, binding: Int, space: AddrSpace) -> ValueID {
    let h = hashMix(hashMix(0x92, UInt64(set)), UInt64(binding))
    if let v = constIndex.find(h, { values[$0].kind == .resource(set: set, binding: binding) }) { return v }
    values.append(Value(type: .ptr(space), kind: .resource(set: set, binding: binding)))
    constIndex.insert(h, values.count - 1)
    return values.count - 1
  }

  public mutating func pushConstants() -> ValueID {
    let h = hashMix(0x93, 0)
    if let v = constIndex.find(h, { values[$0].kind == .pushConstants }) { return v }
    values.append(Value(type: .ptr(.pushConstant), kind: .pushConstants))
    constIndex.insert(h, values.count - 1)
    return values.count - 1
  }

  /// Add an instruction to the end of a block; returns its result (-1 if none).
  @discardableResult
  public mutating func append(_ inst: Inst, to block: BlockID) -> ValueID {
    let id = makeInst(inst)
    blocks[block].insts.append(id)
    return insts[id].result
  }

  /// Insert an instruction into a block at a position.
  @discardableResult
  public mutating func insert(_ inst: Inst, in block: BlockID, at index: Int) -> ValueID {
    let id = makeInst(inst)
    blocks[block].insts.insert(id, at: index)
    return insts[id].result
  }

  /// Add an instruction to the arena without placing it in a block.
  public mutating func makeInst(_ inst: Inst) -> Int {
    var i = inst
    let id = insts.count
    if !i.op.neverHasResult && i.type != .void {
      values.append(Value(type: i.type, kind: .inst(id)))
      i.result = values.count - 1
    } else {
      i.result = -1
    }
    insts.append(i)
    return id
  }

  /// The type of a value.
  public func type(_ v: ValueID) -> IRType { values[v].type }

  /// The instruction defining a value, if an instruction does.
  public func definition(_ v: ValueID) -> Int? {
    if case .inst(let i) = values[v].kind { return i }
    return nil
  }

  /// A constant's bits, if the value is a scalar constant.
  public func constantBits(_ v: ValueID) -> UInt64? {
    if case .constant(let b) = values[v].kind { return b }
    return nil
  }

  public func isConstant(_ v: ValueID) -> Bool {
    switch values[v].kind {
    case .constant, .constVec: return true
    default: return false
    }
  }

  /// The block's terminator instruction id.
  public func terminator(_ b: BlockID) -> Int? { blocks[b].insts.last }

  /// A block's successors, in the terminator's order.
  public func successors(_ b: BlockID) -> [BlockID] {
    guard let t = blocks[b].insts.last else { return [] }
    return insts[t].blocks
  }

  /// Every block's predecessors (a block counted once per edge).
  public func predecessors() -> [[BlockID]] {
    var p = [[BlockID]](repeating: [], count: blocks.count)
    for b in 0..<blocks.count {
      for s in successors(b) { p[s].append(b) }
    }
    return p
  }
}

/// A module-level variable: workgroup or private memory.
public struct Global {
  public var name: String
  public var space: AddrSpace
  public var size: Int
  public var align: Int
  public init(name: String, space: AddrSpace, size: Int, align: Int) {
    self.name = name
    self.space = space
    self.size = size
    self.align = align
  }
}

/// A vertex or fragment stage's input or output variable of the entry point: a user variable (`location` 0 or more)
/// or a builtin (`builtin` the SPIR-V BuiltIn number, `location` -1). Its type is a scalar or a vector of one.
public struct StageVariable: Equatable, Sendable {
  public var location: Int
  public var builtin: Int
  public var type: IRType
  /// The interpolation of a fragment input (SPIR-V's Flat, NoPerspective and Centroid decorations).
  public var flat = false
  public var noPerspective = false
  public var centroid = false
  public init(location: Int, builtin: Int, type: IRType, flat: Bool = false, noPerspective: Bool = false, centroid: Bool = false) {
    self.location = location
    self.builtin = builtin
    self.type = type
    self.flat = flat
    self.noPerspective = noPerspective
    self.centroid = centroid
  }
}

/// A specialization constant: its SpecId, type and the value the lowering used.
public struct Specialization: Equatable {
  public var id: UInt32
  public var type: IRType
  public var bits: UInt64
  public init(id: UInt32, type: IRType, bits: UInt64) {
    self.id = id
    self.type = type
    self.bits = bits
  }
}

public struct IRModule {
  public var functions: [Function] = []
  public var globals: [Global] = []
  /// The entry function's index (always 0 from the SPIR-V lowering).
  public var entry = 0
  public var entryName = ""
  /// The SPIR-V execution model (0 Vertex, 4 Fragment, 5 GLCompute).
  public var executionModel: UInt32 = 5
  public var localSize: (x: UInt32, y: UInt32, z: UInt32) = (1, 1, 1)
  public var specializations: [Specialization] = []
  /// The entry point's stage inputs and outputs (vertex and fragment shaders), in the order the entry's variables
  /// were first used.
  public var inputs: [StageVariable] = []
  public var outputs: [StageVariable] = []
  /// Fragment stage: OriginUpperLeft was declared, early fragment tests were asked for.
  public var originUpperLeft = false
  public var earlyFragmentTests = false
  public init() {}
}

/// What a `tex` instruction does, in its `imm` (valhall 12b): the kind of access, the dimensionality, whether the
/// image is arrayed, which of the offset and level words follow, and the kind of the texel.
public enum TexFlags {
  /// 0 a sample with the level computed from the quad's derivatives, 1 a sample at an explicit level (the level word,
  /// or level zero without one), 2 a fetch at integer coordinates, 3 a computed level with a bias (the level word).
  public static let implicit = 0, explicit = 1, fetch = 2, bias = 3
  public static let kindMask = 3
  /// Dimensionality: 0 one coordinate, 1 two, 2 three.
  public static let dimShift = 2
  public static let arrayed = 1 << 4
  public static let hasOffset = 1 << 5
  public static let hasLevel = 1 << 6
  /// The texel's kind: 0 float, 1 unsigned, 2 signed.
  public static let texelShift = 7
  /// The image is a plain image (a fetch with no sampler): the sampler word of the handle is the driver's dummy.
  public static let noSampler = 1 << 9

  public static func make(kind: Int, dims: Int, arrayed a: Bool, offset: Bool, level: Bool, texel: Int, noSampler n: Bool) -> Int {
    kind | (dims - 1) << dimShift | (a ? arrayed : 0) | (offset ? hasOffset : 0) | (level ? hasLevel : 0) | texel << texelShift
      | (n ? noSampler : 0)
  }
  public static func kind(_ imm: Int) -> Int { imm & kindMask }
  /// The coordinates the access takes (1 to 3), without the layer.
  public static func dims(_ imm: Int) -> Int { (imm >> dimShift & 3) + 1 }
  public static func isArrayed(_ imm: Int) -> Bool { imm & arrayed != 0 }
  public static func texel(_ imm: Int) -> Int { imm >> texelShift & 3 }
  /// The arguments of a `tex`: two indices, the coordinates, the layer, the offset word and the level word.
  public static func argumentCount(_ imm: Int) -> Int {
    2 + dims(imm) + (isArrayed(imm) ? 1 : 0) + (imm & hasOffset != 0 ? 1 : 0) + (imm & hasLevel != 0 ? 1 : 0)
  }
}

/// What an `imgload`, `imgstore` or `imgaddr` does, in its `imm`: the dimensionality, whether the image is arrayed, how many
/// channels its format has and what kind of value they are.
public enum ImgFlags {
  /// Dimensionality: 0 one coordinate, 1 two.
  public static let dimsMask = 3
  public static let arrayed = 1 << 2
  /// The channels the format has, minus one (bits 3 and 4).
  public static let channelsShift = 3
  /// The channels' kind (bits 5 and 6): 0 float (and normalised), 1 unsigned, 2 signed.
  public static let kindShift = 5

  public static func make(dims: Int, arrayed a: Bool, channels: Int, kind: Int) -> Int {
    (dims - 1) | (a ? arrayed : 0) | (channels - 1) << channelsShift | kind << kindShift
  }
  public static func dims(_ imm: Int) -> Int { (imm & dimsMask) + 1 }
  public static func isArrayed(_ imm: Int) -> Bool { imm & arrayed != 0 }
  public static func channels(_ imm: Int) -> Int { (imm >> channelsShift & 3) + 1 }
  public static func kind(_ imm: Int) -> Int { imm >> kindShift & 3 }
  /// The arguments before a store's channels: the index, the coordinates and the layer.
  public static func addressCount(_ imm: Int) -> Int { 1 + dims(imm) + (isArrayed(imm) ? 1 : 0) }
}

// MARK: hashing

@inline(__always)
func hashMix(_ h: UInt64, _ x: UInt64) -> UInt64 {
  var v = (h ^ x) &* 0x9e37_79b9_7f4a_7c15
  v ^= v >> 29
  v = v &* 0xbf58_476d_1ce4_e5b9
  v ^= v >> 32
  return v
}

/// An open-addressing table from a hash to the ids that carry it; lookups
/// give the caller a closure to say which candidate matches.
struct HashTable {
  private var ids: [Int32] = [Int32](repeating: -1, count: 64)
  private var hashes: [UInt64] = [UInt64](repeating: 0, count: 64)
  private var count = 0

  init() {}

  func find(_ hash: UInt64, _ matches: (Int) -> Bool) -> Int? {
    let mask = ids.count - 1
    var i = Int(truncatingIfNeeded: hash) & mask
    while ids[i] >= 0 {
      if hashes[i] == hash && matches(Int(ids[i])) { return Int(ids[i]) }
      i = (i + 1) & mask
    }
    return nil
  }

  mutating func insert(_ hash: UInt64, _ id: Int) {
    if (count + 1) * 2 > ids.count { grow() }
    place(hash, id)
    count += 1
  }

  private mutating func place(_ hash: UInt64, _ id: Int) {
    let mask = ids.count - 1
    var i = Int(truncatingIfNeeded: hash) & mask
    while ids[i] >= 0 { i = (i + 1) & mask }
    ids[i] = Int32(id)
    hashes[i] = hash
  }

  private mutating func grow() {
    let oldIds = ids
    let oldHashes = hashes
    ids = [Int32](repeating: -1, count: oldIds.count * 2)
    hashes = [UInt64](repeating: 0, count: oldIds.count * 2)
    for i in 0..<oldIds.count where oldIds[i] >= 0 { place(oldHashes[i], Int(oldIds[i])) }
  }
}
