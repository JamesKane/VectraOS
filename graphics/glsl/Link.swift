// SPDX-License-Identifier: BSD-3-Clause

// The link (the OpenGL ES 2.0 specification's section 2.10.3 and GLSL ES 1.00's 4.3.5, 4.5.3 and 10.6): each stage
// has main and defines what it calls; the varyings the fragment shader reads are the vertex shader's, of the same type
// and invariance, given locations in the order the fragment shader declares them; the uniforms of both stages are one
// block, a name in both the same type and precision; the attributes are at their bound locations, the rest from 0 up.

/// GL's type enum for a type (an array's, its element's).
func glType(_ t: GType) -> UInt32 {
  switch t.basic {
  case .float:
    if t.cols > 1 { return 0x8B5A + UInt32(t.cols - 2) }
    return t.rows == 1 ? 0x1406 : 0x8B50 + UInt32(t.rows - 2)
  case .int: return t.rows == 1 ? 0x1404 : 0x8B53 + UInt32(t.rows - 2)
  case .bool: return t.rows == 1 ? 0x8B56 : 0x8B57 + UInt32(t.rows - 2)
  case .sampler2D: return 0x8B5E
  case .samplerCube: return 0x8B60
  default: return 0
  }
}

/// The program's active uniforms one leaf each, as glGetActiveUniform lists them, from a uniform at `offset`.
func flatten(_ prog: Program, _ name: String, _ t: GType, offset: Int, into out: inout [ActiveUniform]) {
  if t.isStruct {
    var off = offset
    for m in prog.structs[t.structID].members {
      let x = prog.std140(m.type)
      if x.size > 0 { off = roundUp(off, x.align) }
      flatten(prog, name + "." + m.name, m.type, offset: off, into: &out)
      off += x.size
    }
    return
  }
  if t.isArray && t.element.isStruct {
    let e = prog.std140(t.element)
    let stride = roundUp(e.size, max(e.align, 16))
    for i in 0..<t.arraySize { flatten(prog, name + "[\(i)]", t.element, offset: offset + i * stride, into: &out) }
    return
  }
  let e = prog.std140(t.element)
  out.append(
    ActiveUniform(
      name: t.isArray ? name + "[0]" : name, type: glType(t), arraySize: t.isArray ? t.arraySize : 1, binding: t.isSampler ? 0 : -1,
      offset: t.isSampler ? -1 : offset, arrayStride: t.isArray && !t.isSampler ? roundUp(e.size, max(e.align, 16)) : 0,
      matrixStride: t.isMatrix || t.element.isMatrix ? 16 : 0))
}

/// The vec4 slots a uniform takes against gl_Max*UniformVectors (a matrix a column each, an array an element each).
func uniformVectors(_ prog: Program, _ t: GType) -> Int {
  let n = t.isArray ? t.arraySize : 1
  let e = t.element
  if e.isSampler { return 0 }
  if e.isStruct { return n * prog.structs[e.structID].members.reduce(0) { $0 + uniformVectors(prog, $1.type) } }
  return n * (e.isMatrix ? e.cols : 1)
}

/// GL ES 2.0's packing (GLSL ES 1.00 appendix A.7) estimated: the rows of four the varyings fill, a vec3's spare column
/// taking a float and two vec2s sharing a row.
func varyingRows(_ ts: [GType]) -> Int {
  var full = 0
  var threes = 0
  var twos = 0
  var ones = 0
  for t in ts {
    let n = t.isArray ? t.arraySize : 1
    let e = t.element
    let k = n * (e.isMatrix ? e.cols : 1)
    switch e.rows {
    case 4: full += k
    case 3: threes += k
    case 2: twos += k
    default: ones += k
    }
  }
  let spareOnes = max(0, ones - threes)
  return full + threes + (twos + 1) / 2 + (spareOnes + 3) / 4
}

/// Links a vertex and a fragment shader: their interfaces matched and laid out, and each stage's SPIR-V. A failed link's
/// error has GL's link log.
public func link(
  vertex: GLSLShader, fragment: GLSLShader, attributeBindings: [(name: String, location: UInt32)],
  options: GLSLLinkOptions = GLSLLinkOptions()
) throws(GLSLError) -> GLSLProgram {
  var d = Diagnostics()
  let vp = vertex.program
  let fp = fragment.program
  if vertex.stage != .vertex { d.error("the vertex shader given is a fragment shader") }
  if fragment.stage != .fragment { d.error("the fragment shader given is a vertex shader") }
  if d.errors > 0 { throw GLSLError(log: d.log) }
  for (p, what) in [(vp, "vertex"), (fp, "fragment")] {
    if p.main < 0 { d.error("the \(what) shader has no main function") }
    let (fs, _) = CodeGen.reach(p)
    for f in fs where p.functions[f].body == nil {
      d.error("the \(what) shader calls '\(p.functions[f].name)', which it declares but does not define")
    }
  }
  if d.errors > 0 { throw GLSLError(log: d.log) }
  let (_, vUsed) = CodeGen.reach(vp)
  let (_, fUsed) = CodeGen.reach(fp)
  var vLayout = StageLayout()
  vLayout.clip = options.clipControl
  vLayout.entryPoint = options.entryPoint
  var fLayout = vLayout

  // Varyings: what the fragment shader reads, from the vertex shader.
  var varyings: [LinkedVarying] = []
  var location = 0
  var types: [GType] = []
  for v in fUsed where fp.variables[v].storage == .varying {
    let x = fp.variables[v]
    guard let vi = vp.variables.firstIndex(where: { $0.storage == .varying && $0.name == x.name }) else {
      d.error("varying '\(x.name)' is read by the fragment shader but not declared in the vertex shader")
      continue
    }
    let y = vp.variables[vi]
    if !Program.sameType(y.type, vp, x.type, fp) {
      d.error("varying '\(x.name)' is \(vp.name(y.type)) in the vertex shader and \(fp.name(x.type)) in the fragment shader")
      continue
    }
    if (y.invariant || vp.invariantAll) != (x.invariant || fp.invariantAll) {
      d.error("varying '\(x.name)' is invariant in one shader and not in the other")
    }
    vLayout.varyings[x.name] = location
    fLayout.varyings[x.name] = location
    varyings.append(LinkedVarying(name: x.name, type: glType(x.type), arraySize: x.type.isArray ? x.type.arraySize : 1, location: UInt32(location)))
    location += CodeGen(prog: fp, layout: fLayout).leaves(x.type).count
    types.append(x.type)
  }
  if varyingRows(types) > options.limits.maxVaryingVectors {
    d.error("the varyings need \(varyingRows(types)) vectors; the implementation has \(options.limits.maxVaryingVectors)")
  }
  // gl_FragCoord, gl_FrontFacing and gl_PointCoord count as varyings when read (GLSL ES 1.00 A.7): one vector each.
  for v in fUsed where [.fragCoord, .frontFacing, .pointCoord].contains(fp.variables[v].builtin) { types.append(.vec(4)) }
  if varyingRows(types) > options.limits.maxVaryingVectors {
    d.error("the varyings and the built-in ones read need \(varyingRows(types)) vectors; the implementation has \(options.limits.maxVaryingVectors)")
  }
  for vi in vUsed where vp.variables[vi].builtin == .position && vp.variables[vi].invariant {
    for fi in fUsed where fp.variables[fi].builtin == .fragCoord && !fp.variables[fi].invariant {
      d.warning("gl_Position is invariant but gl_FragCoord is not")
    }
  }

  // Uniforms: one block for both stages, the vertex shader's first.
  var uniforms: [ActiveUniform] = []
  var offset = 32
  var blockMembers: [(name: String, offset: Int)] = []
  var binding = 1
  var samplerBindings: [String: Int] = [:]
  var stageSamplers = [0, 0]
  for (si, p, used) in [(0, vp, vUsed), (1, fp, fUsed)] {
    let other = si == 0 ? fp : vp
    var vectors = 0
    for v in used where p.variables[v].storage == .uniform {
      let x = p.variables[v]
      // A uniform both shaders declare: checked once (by the vertex shader's, or the fragment shader's when only it
      // uses the uniform). The precision qualifiers written must match where both use it (a warning otherwise); a
      // declaration that takes its stage's default precision has none, as in Mesa's link (a highp default in one stage
      // and a mediump default in the other link).
      if let oi = other.variables.firstIndex(where: { $0.storage == .uniform && $0.name == x.name }),
        si == 0 || !vUsed.contains(where: { vp.variables[$0].name == x.name && vp.variables[$0].storage == .uniform })
      {
        let y = other.variables[oi]
        if !Program.sameType(x.type, p, y.type, other) {
          d.error("uniform '\(x.name)' is \(p.name(x.type)) in the \(si == 0 ? "vertex" : "fragment") shader and \(other.name(y.type)) in the other")
          continue
        }
        if Parser.precisionBasic(x.type) != nil && x.declaredPrecision != y.declaredPrecision {
          let bothUse = (si == 0 ? fUsed : vUsed).contains(oi)
          let msg = "uniform '\(x.name)' is declared \(x.declaredPrecision == .none ? "with no precision" : x.declaredPrecision.name) in the \(si == 0 ? "vertex" : "fragment") shader and \(y.declaredPrecision == .none ? "with none" : y.declaredPrecision.name) in the other"
          if bothUse {
            d.error(msg)
            continue
          }
          d.warning(msg)
        }
      }
      vectors += uniformVectors(p, x.type)
      var leaves: [ActiveUniform] = []
      let lay = p.std140(x.type)
      let known = blockMembers.contains { $0.name == x.name } || uniforms.contains { $0.name == x.name || $0.name.hasPrefix(x.name + ".") || $0.name.hasPrefix(x.name + "[") }
      if known {
        for u in uniforms where u.isSampler && (u.name == x.name || u.name.hasPrefix(x.name + ".") || u.name.hasPrefix(x.name + "[")) {
          stageSamplers[si] += u.arraySize
        }
        continue
      }
      var start = -1
      if lay.size > 0 {
        offset = roundUp(offset, lay.align)
        start = offset
        blockMembers.append((name: x.name, offset: offset))
        offset += lay.size
      }
      flatten(p, x.name, x.type, offset: start, into: &leaves)
      for var u in leaves {
        if u.isSampler {
          u.binding = binding
          u.offset = -1
          for i in 0..<u.arraySize {
            let base = u.arraySize > 1 || u.name.hasSuffix("[0]") ? String(u.name.dropLast(3)) + "[\(i)]" : u.name
            samplerBindings[base] = binding + i
          }
          binding += u.arraySize
          stageSamplers[si] += u.arraySize
        }
        uniforms.append(u)
      }
    }
    let limit = si == 0 ? options.limits.maxVertexUniformVectors : options.limits.maxFragmentUniformVectors
    if vectors > limit { d.error("the \(si == 0 ? "vertex" : "fragment") shader's uniforms need \(vectors) vectors; the implementation has \(limit)") }
  }
  if stageSamplers[0] > options.limits.maxVertexTextureImageUnits {
    d.error("the vertex shader uses \(stageSamplers[0]) samplers; the implementation has \(options.limits.maxVertexTextureImageUnits)")
  }
  if stageSamplers[1] > options.limits.maxTextureImageUnits {
    d.error("the fragment shader uses \(stageSamplers[1]) samplers; the implementation has \(options.limits.maxTextureImageUnits)")
  }
  if binding - 1 > options.limits.maxCombinedTextureImageUnits {
    d.error("the program uses \(binding - 1) samplers; the implementation has \(options.limits.maxCombinedTextureImageUnits)")
  }
  let blockBytes = roundUp(offset, 16)
  for l in [0, 1] {
    var lay = l == 0 ? vLayout : fLayout
    lay.blockMembers = blockMembers
    lay.blockBytes = blockBytes
    lay.samplerBindings = samplerBindings
    if l == 0 { vLayout = lay } else { fLayout = lay }
  }

  // Attributes: the bound ones where bound, the rest in the lowest free locations.
  var attributes: [ActiveAttribute] = []
  var taken = [Bool](repeating: false, count: options.limits.maxVertexAttribs)
  var pending: [Int] = []
  for v in vUsed where vp.variables[v].storage == .attribute {
    let x = vp.variables[v]
    let n = x.type.isMatrix ? x.type.cols : 1
    if let bnd = attributeBindings.last(where: { $0.name == x.name }) {
      let l = Int(bnd.location)
      if l + n > taken.count {
        d.error("attribute '\(x.name)' is bound to location \(l), past the implementation's \(taken.count)")
        continue
      }
      for k in l..<(l + n) {
        if taken[k] { d.warning("attribute '\(x.name)' is bound to location \(k), which another active attribute also has") }
        taken[k] = true
      }
      vLayout.attributes[x.name] = l
      attributes.append(ActiveAttribute(name: x.name, type: glType(x.type), arraySize: 1, location: UInt32(l)))
    } else {
      pending.append(v)
    }
  }
  for v in pending {
    let x = vp.variables[v]
    let n = x.type.isMatrix ? x.type.cols : 1
    var l = 0
    while l + n <= taken.count && taken[l..<(l + n)].contains(true) { l += 1 }
    if l + n > taken.count {
      d.error("there are too many attributes: '\(x.name)' has no location (the implementation has \(taken.count))")
      continue
    }
    for k in l..<(l + n) { taken[k] = true }
    vLayout.attributes[x.name] = l
    attributes.append(ActiveAttribute(name: x.name, type: glType(x.type), arraySize: 1, location: UInt32(l)))
  }
  if d.errors > 0 { throw GLSLError(log: d.log) }

  var vg = CodeGen(prog: vp, layout: vLayout)
  let vs = vg.generate()
  var fg = CodeGen(prog: fp, layout: fLayout)
  let fs = fg.generate()
  for e in vg.errors { d.error("vertex shader: \(e)") }
  for e in fg.errors { d.error("fragment shader: \(e)") }
  if d.errors > 0 { throw GLSLError(log: d.log) }
  return GLSLProgram(
    vertexSPIRV: vs, fragmentSPIRV: fs, attributes: attributes, uniforms: uniforms, varyings: varyings,
    uniformBlockBytes: blockBytes, driverBlockOffset: 0, samplerBindings: binding, log: d.log)
}
