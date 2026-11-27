// SPDX-License-Identifier: BSD-3-Clause

// A stage's entry function and module: the interface variables the program uses, the prologue that reads them, main
// inlined, and the epilogue that publishes what the stage writes.

extension CodeGen {
  /// The functions main reaches, and the global variables they use.
  static func reach(_ prog: Program) -> (functions: [Int], variables: [Int]) {
    guard prog.main >= 0 else { return ([], []) }
    var fs: [Int] = []
    var work = [prog.main]
    while let f = work.popLast() {
      if fs.contains(f) { continue }
      fs.append(f)
      work += prog.functions[f].calls
    }
    var vs: [Int] = []
    for f in fs { for v in prog.functions[f].uses where !vs.contains(v) { vs.append(v) } }
    return (fs, vs)
  }

  /// The leaves of a varying's or attribute's type: a vector or float each (a matrix's columns, an array's elements).
  func leaves(_ t: GType) -> [GType] {
    if t.isArray { return [GType](repeating: t.element, count: t.arraySize).flatMap { leaves($0) } }
    if t.isMatrix { return [GType](repeating: t.column, count: t.cols) }
    return [t]
  }

  mutating func interfaceVariable(_ t: GType, _ storage: UInt32, name: String) -> UInt32 {
    let v = b.variable(b.pointer(storage, ty(t)), storage)
    interface.append(v)
    b.name(v, name)
    return v
  }

  /// The leaves of a value, by constant steps (an array's elements, a matrix's columns).
  mutating func leafValues(_ x: UInt32, _ t: GType) -> [UInt32] {
    if t.isArray || t.isMatrix {
      let n = t.isArray ? t.arraySize : t.cols
      let et = t.isArray ? t.element : t.column
      var r: [UInt32] = []
      for i in 0..<n { r += leafValues(emit(SpvOp.compositeExtract, ty(et), [x, UInt32(i)]), et) }
      return r
    }
    return [x]
  }

  /// A value of `t` from its leaves, in order.
  mutating func fromLeaves(_ ls: inout ArraySlice<UInt32>, _ t: GType) -> UInt32 {
    if t.isArray || t.isMatrix {
      let n = t.isArray ? t.arraySize : t.cols
      let et = t.isArray ? t.element : t.column
      var parts: [UInt32] = []
      for _ in 0..<n { parts.append(fromLeaves(&ls, et)) }
      return emit(SpvOp.compositeConstruct, ty(t), parts)
    }
    return ls.popFirst()!
  }

  /// The stage's module.
  mutating func generate() -> [UInt32] {
    let vertex = prog.stage == .vertex
    let (_, used) = CodeGen.reach(prog)
    let entryLabel = b.id()
    label(entryLabel)
    var outputsToPublish: [(shadow: UInt32, type: GType, outputs: [UInt32])] = []
    var position: UInt32 = 0
    var fragData: (UInt32, UInt32)? = nil

    if vertex {
      position = interfaceVariable(.vec(4), StorageClass.output, name: "gl_Position")
      b.decorate(position, Decoration.builtIn, [0])
    }
    for v in used {
      let x = prog.variables[v]
      switch x.storage {
      case .builtin:
        switch x.builtin {
        case .position:
          places[v] = .memory(position, StorageClass.output, laid: false, prefix: [])
          if x.invariant || prog.invariantAll { b.decorate(position, Decoration.invariant) }
        case .pointSize:
          let o = interfaceVariable(.float, StorageClass.output, name: "gl_PointSize")
          b.decorate(o, Decoration.builtIn, [1])
          places[v] = .memory(o, StorageClass.output, laid: false, prefix: [])
        case .fragCoord:
          let i = interfaceVariable(.vec(4), StorageClass.input, name: "gl_FragCoord")
          b.decorate(i, Decoration.builtIn, [15])
          var fc = emit(SpvOp.load, ty(.vec(4)), [i])
          if layout.clip == .gl {
            // y' = fragCoordYScale * y + fragCoordYOffset.
            let y = emit(SpvOp.compositeExtract, b.float, [fc, 1])
            let y2 = ext(50, b.float, [y, driverWord(1), driverWord(2)])
            fc = emit(SpvOp.compositeInsert, ty(.vec(4)), [y2, fc, 1])
          }
          places[v] = .value(fc)
        case .frontFacing:
          let i = interfaceVariable(.bool, StorageClass.input, name: "gl_FrontFacing")
          b.decorate(i, Decoration.builtIn, [17])
          places[v] = .value(emit(SpvOp.load, b.bool, [i]))
        case .pointCoord:
          let i = interfaceVariable(.vec(2), StorageClass.input, name: "gl_PointCoord")
          b.decorate(i, Decoration.builtIn, [16])
          var pc = emit(SpvOp.load, ty(.vec(2)), [i])
          if layout.clip == .gl {
            // y' = 0.5 + pointCoordYScale * (y - 0.5).
            let half = b.constant(float: 0.5)
            let y = emit(SpvOp.compositeExtract, b.float, [pc, 1])
            let d = emit(SpvOp.fSub, b.float, [y, half])
            let y2 = ext(50, b.float, [d, driverWord(3), half])
            pc = emit(SpvOp.compositeInsert, ty(.vec(2)), [y2, pc, 1])
          }
          places[v] = .value(pc)
        case .fragColor:
          let o = interfaceVariable(.vec(4), StorageClass.output, name: "gl_FragColor")
          b.decorate(o, Decoration.location, [0])
          places[v] = .memory(o, StorageClass.output, laid: false, prefix: [])
        case .fragData:
          let o = interfaceVariable(.vec(4), StorageClass.output, name: "gl_FragData")
          b.decorate(o, Decoration.location, [0])
          let shadow = local(x.type, name: "gl_FragData")
          places[v] = .memory(shadow, StorageClass.function, laid: false, prefix: [])
          fragData = (shadow, o)
        case .depthRange:
          let parts = [driverWord(4), driverWord(5), driverWord(6)]
          places[v] = .value(emit(SpvOp.compositeConstruct, ty(x.type), parts))
        case .none: break
        }
      case .attribute:
        guard let loc = layout.attributes[x.name] else { continue }
        var ls: [UInt32] = []
        for (k, lt) in leaves(x.type).enumerated() {
          let i = interfaceVariable(lt, StorageClass.input, name: leaves(x.type).count > 1 ? "\(x.name).\(k)" : x.name)
          b.decorate(i, Decoration.location, [UInt32(loc + k)])
          ls.append(emit(SpvOp.load, ty(lt), [i]))
        }
        var slice = ls[...]
        places[v] = .value(fromLeaves(&slice, x.type))
      case .varying:
        let loc = layout.varyings[x.name]
        let ls = leaves(x.type)
        if vertex {
          guard let loc = loc else {
            // A varying the fragment shader does not read: a variable of the vertex stage's own.
            places[v] = .memory(local(x.type, name: x.name), StorageClass.function, laid: false, prefix: [])
            continue
          }
          var outs: [UInt32] = []
          for (k, lt) in ls.enumerated() {
            let o = interfaceVariable(lt, StorageClass.output, name: ls.count > 1 ? "\(x.name).\(k)" : x.name)
            b.decorate(o, Decoration.location, [UInt32(loc + k)])
            if x.invariant || prog.invariantAll { b.decorate(o, Decoration.invariant) }
            if x.precision.relaxed { b.decorate(o, Decoration.relaxedPrecision) }
            outs.append(o)
          }
          if ls.count == 1 {
            places[v] = .memory(outs[0], StorageClass.output, laid: false, prefix: [])
          } else {
            let shadow = local(x.type, name: x.name)
            places[v] = .memory(shadow, StorageClass.function, laid: false, prefix: [])
            outputsToPublish.append((shadow, x.type, outs))
          }
        } else {
          guard let loc = loc else { continue }
          var vals: [UInt32] = []
          for (k, lt) in ls.enumerated() {
            let i = interfaceVariable(lt, StorageClass.input, name: ls.count > 1 ? "\(x.name).\(k)" : x.name)
            b.decorate(i, Decoration.location, [UInt32(loc + k)])
            if x.invariant || prog.invariantAll { b.decorate(i, Decoration.invariant) }
            if x.precision.relaxed { b.decorate(i, Decoration.relaxedPrecision) }
            vals.append(emit(SpvOp.load, ty(lt), [i], relaxed: x.precision.relaxed))
          }
          var slice = vals[...]
          places[v] = .value(fromLeaves(&slice, x.type))
        }
      default: break
      }
    }
    // The global variables' initializers (and the const globals the compiler does not fold), in order.
    for g in prog.globals {
      let x = prog.variables[g.variable]
      guard used.contains(g.variable) || x.storage == .constant else { continue }
      if x.storage == .constant {
        if x.value == nil, let e = g.initializer { places[g.variable] = .value(value(e)) }
      } else if x.storage == .global {
        let ptr = local(x.type, name: x.name)
        places[g.variable] = .memory(ptr, StorageClass.function, laid: false, prefix: [])
        if x.precision.relaxed { b.decorate(ptr, Decoration.relaxedPrecision) }
        if let e = g.initializer { emitVoid(SpvOp.store, [ptr, value(e)]) }
      }
    }
    _ = inline(prog.main, [])
    if !terminated {
      for p in outputsToPublish {
        let v = emit(SpvOp.load, ty(p.type), [p.shadow])
        for (o, l) in zip(p.outputs, leafValues(v, p.type)) { emitVoid(SpvOp.store, [o, l]) }
      }
      if let (shadow, o) = fragData {
        let p = emit(SpvOp.accessChain, b.pointer(StorageClass.function, ty(.vec(4))), [shadow, b.constant(int: 0)])
        emitVoid(SpvOp.store, [o, emit(SpvOp.load, ty(.vec(4)), [p])])
      }
      if vertex && layout.clip == .gl {
        // GL's clip space into Vulkan's: z' = (z + w) / 2, y' = positionYScale * y.
        let v4 = ty(.vec(4))
        let p = emit(SpvOp.load, v4, [position])
        let y = emit(SpvOp.compositeExtract, b.float, [p, 1])
        let z = emit(SpvOp.compositeExtract, b.float, [p, 2])
        let w = emit(SpvOp.compositeExtract, b.float, [p, 3])
        let y2 = emit(SpvOp.fMul, b.float, [y, driverWord(0)])
        let z2 = emit(SpvOp.fMul, b.float, [emit(SpvOp.fAdd, b.float, [z, w]), b.constant(float: 0.5)])
        let q = emit(SpvOp.compositeInsert, v4, [y2, p, 1])
        emitVoid(SpvOp.store, [position, emit(SpvOp.compositeInsert, v4, [z2, q, 2])])
      }
      emitVoid(SpvOp.return_, [])
    }
    // The function: its variables in the first block.
    let main = b.id()
    b.name(main, layout.entryPoint)
    let fnType = b.functionType(b.void)
    var fn = Builder.instruction(SpvOp.function, [b.void, main, 0, fnType])
    let first = Builder.instruction(SpvOp.label, [entryLabel]).count
    fn += Array(code[0..<first]) + locals + prologue + Array(code[first...])
    fn += Builder.instruction(SpvOp.functionEnd, [])
    let model: UInt32 = vertex ? 0 : 4
    let entry = Builder.instruction(SpvOp.entryPoint, [model, main] + Builder.string(layout.entryPoint) + interface)
    let modes = vertex ? [] : Builder.instruction(SpvOp.executionMode, [main, 7])
    return b.module(capabilities: [1], entry: entry, modes: modes, function: fn)
  }
}
