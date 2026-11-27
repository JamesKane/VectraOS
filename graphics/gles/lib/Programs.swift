// SPDX-License-Identifier: BSD-3-Clause

// The shader and program calls (gles(3), "Shaders"), and the uniforms: glUniform* writes the program's block on the
// CPU, as std140 lays it out, and the next draw copies it.

import GPUCore

extension GLContext {
  func shaderObject(_ name: GLuint) -> GLShader? { share.shaderObjects[name] as? GLShader }
  func programObject(_ name: GLuint) -> GLProgram? { share.shaderObjects[name] as? GLProgram }

  /// The shader `name` names; INVALID_VALUE where it names nothing, INVALID_OPERATION where it names a program.
  func shader(_ name: GLuint) -> GLShader? {
    guard let o = share.shaderObjects[name] else {
      fail(.invalidValue)
      return nil
    }
    guard let s = o as? GLShader else {
      fail(.invalidOperation)
      return nil
    }
    return s
  }

  func program(_ name: GLuint) -> GLProgram? {
    guard let o = share.shaderObjects[name] else {
      fail(.invalidValue)
      return nil
    }
    guard let p = o as? GLProgram else {
      fail(.invalidOperation)
      return nil
    }
    return p
  }

  func newShaderName() -> GLuint {
    while share.shaderObjects[share.nextShaderName] != nil || share.nextShaderName == 0 { share.nextShaderName &+= 1 }
    defer { share.nextShaderName &+= 1 }
    return share.nextShaderName
  }

  func createShader(_ type: GLenum) -> GLuint {
    guard type == GL_VERTEX_SHADER || type == GL_FRAGMENT_SHADER else {
      fail(.invalidEnum)
      return 0
    }
    let name = newShaderName()
    share.shaderObjects[name] = GLShader(name: name, type: type)
    return name
  }

  func createProgram() -> GLuint {
    let name = newShaderName()
    share.shaderObjects[name] = GLProgram(name: name)
    return name
  }

  func deleteShader(_ name: GLuint) {
    guard name != 0, let s = shader(name) else { return }
    if s.attachments > 0 { s.deletePending = true } else { share.shaderObjects[name] = nil }
  }

  func deleteProgram(_ name: GLuint) {
    guard name != 0, let p = program(name) else { return }
    if program === p {
      p.deletePending = true
      return
    }
    removeProgram(p)
  }

  func removeProgram(_ p: GLProgram) {
    for s in [p.vertexShader, p.fragmentShader] {
      guard let s else { continue }
      s.attachments -= 1
      if s.deletePending && s.attachments == 0 { share.shaderObjects[s.name] = nil }
    }
    lastPipeline = nil
    for (_, pipeline) in p.pipelines { frame.release(pipeline) }
    p.pipelines = [:]
    share.shaderObjects[p.name] = nil
  }

  func shaderSource(_ name: GLuint, _ count: GLsizei, _ strings: UnsafePointer<UnsafePointer<GLchar>?>?,
                    _ lengths: UnsafePointer<GLint>?) {
    guard count >= 0 else { return fail(.invalidValue) }
    guard let s = shader(name) else { return }
    var source: [UInt8] = []
    guard let strings = unsafe strings else { return }
    for i in 0..<Int(count) {
      guard let p = unsafe strings[i] else { continue }
      let n: Int
      if let lengths = unsafe lengths, unsafe lengths[i] >= 0 { n = Int(unsafe lengths[i]) } else { n = unsafe strlen(p) }
      unsafe source.append(contentsOf: UnsafeRawBufferPointer(start: p, count: n))
    }
    s.source = source
  }

  func compileShader(_ name: GLuint) {
    guard let s = shader(name) else { return }
    s.binary = nil
    guard let frontEnd = unsafe shaderFrontEnd else {
      s.compileStatus = false
      s.log = "no GLSL ES front end: give shaders as SPIR-V (glShaderBinary, GL_SHADER_BINARY_FORMAT_SPIR_V)"
      return
    }
    let (compiled, log) = frontEnd.compile(source: s.source, fragment: s.isFragment)
    s.compiled = compiled
    s.compileStatus = compiled != nil
    s.log = log
  }

  func shaderBinary(_ n: GLsizei, _ shaders: UnsafePointer<GLuint>?, _ format: GLenum, _ binary: UnsafeRawPointer?,
                    _ length: GLsizei) {
    guard n >= 0, length >= 0 else { return fail(.invalidValue) }
    guard format == GL_SHADER_BINARY_FORMAT_SPIR_V else { return fail(.invalidEnum) }
    guard let shaders = unsafe shaders, let binary = unsafe binary, length % 4 == 0 else { return fail(.invalidValue) }
    let words = unsafe [UInt32](UnsafeBufferPointer(start: binary.assumingMemoryBound(to: UInt32.self), count: Int(length) / 4))
    guard SpirvModule(words) != nil else { return fail(.invalidValue) }
    for i in 0..<Int(n) {
      guard let s = shader(unsafe shaders[i]) else { return }
      s.binary = words
      s.compiled = nil
      s.compileStatus = true
      s.log = ""
    }
  }

  func attachShader(_ programName: GLuint, _ shaderName: GLuint) {
    guard let p = program(programName), let s = shader(shaderName) else { return }
    if s.isFragment {
      guard p.fragmentShader == nil else { return fail(.invalidOperation) }
      p.fragmentShader = s
    } else {
      guard p.vertexShader == nil else { return fail(.invalidOperation) }
      p.vertexShader = s
    }
    s.attachments += 1
  }

  func detachShader(_ programName: GLuint, _ shaderName: GLuint) {
    guard let p = program(programName), let s = shader(shaderName) else { return }
    if p.vertexShader === s { p.vertexShader = nil } else if p.fragmentShader === s { p.fragmentShader = nil } else {
      return fail(.invalidOperation)
    }
    s.attachments -= 1
    if s.deletePending && s.attachments == 0 { share.shaderObjects[s.name] = nil }
  }

  func bindAttribLocation(_ programName: GLuint, _ index: GLuint, _ name: String) {
    guard index < GLuint(maxVertexAttribs) else { return fail(.invalidValue) }
    guard let p = program(programName) else { return }
    guard !name.hasPrefix("gl_") else { return fail(.invalidOperation) }
    p.bindings.removeAll { $0.name == name }
    p.bindings.append((name, index))
  }

  func linkProgram(_ name: GLuint) {
    guard let p = program(name) else { return }
    lastPipeline = nil
    if program === p {
      // The program in use is re-linked: what the open list recorded keeps its pipelines.
      for (_, pipeline) in p.pipelines { frame.release(pipeline) }
      p.pipelines = [:]
    }
    p.link()
    if p.linkStatus { pipelineSerial &+= 1 }
  }

  func useProgram(_ name: GLuint) {
    var p: GLProgram? = nil
    if name != 0 {
      guard let found = program(name) else { return }
      guard found.linkStatus else { return fail(.invalidOperation) }
      p = found
    }
    if let old = program, old !== p, old.deletePending { removeProgram(old) }
    program = p
  }

  func validateProgram(_ name: GLuint) {
    guard let p = program(name) else { return }
    p.validateStatus = p.linkStatus
    // Two samplers of different kinds on one unit can't draw.
    var kinds: [Int: Bool] = [:]
    for (n, cube) in p.samplerIsCube.enumerated() {
      let u = p.unit(n)
      if let k = kinds[u], k != cube {
        p.validateStatus = false
        p.log = "samplers of different types read texture unit \(u)"
      }
      kinds[u] = cube
    }
  }

  // MARK: Uniforms

  /// The uniform location `location` of the program in use; nil (and INVALID_OPERATION) where it isn't one.
  func uniformTarget(_ location: GLint) -> (GLProgram, UniformLocation, ActiveUniform)? {
    guard let p = program, p.linkStatus else {
      fail(.invalidOperation)
      return nil
    }
    if location == -1 { return nil }
    guard location >= 0, Int(location) < p.locations.count else {
      fail(.invalidOperation)
      return nil
    }
    let l = p.locations[Int(location)]
    return (p, l, p.interface.uniforms[l.uniform])
  }

  /// glUniform{1234}{if}v: `count` values of `components` floats (or ints) from `values`, from the location on.
  func uniform(_ location: GLint, count: GLsizei, components: Int, integers: Bool, _ values: UnsafeRawPointer?) {
    // The common case: one float or int value of the type the location has.
    if count == 1, let p = program, p.linkStatus, location >= 0, Int(location) < p.locationInfo.count, let values = unsafe values,
      let block = unsafe p.block
    {
      let li = p.locationInfo[Int(location)]
      if li.kind == (integers ? 1 : 0), li.components == components, li.offset + 4 * components <= p.blockBytes {
        unsafe (block + li.offset).copyMemory(from: values, byteCount: 4 * components)
        p.blockDirty = true
        return
      }
    }
    guard count >= 0 else { return fail(.invalidValue) }
    guard let (p, l, u) = uniformTarget(location), let values = unsafe values else { return }
    if let first = u.samplerBinding {
      _ = first
      guard integers, components == 1 else { return fail(.invalidOperation) }
      guard count <= 1 || u.arraySize > 1 else { return fail(.invalidOperation) }
      for i in 0..<min(Int(count), u.arraySize - l.element) {
        let unit = unsafe values.load(fromByteOffset: 4 * i, as: Int32.self)
        guard unit >= 0, unit < Int32(GLContext.textureUnits) else { return fail(.invalidValue) }
        if let n = samplerIndex(p, u, element: l.element + i) { p.samplerUnits[n] = unit }
      }
      return
    }
    let isMatrix = u.type == GL_FLOAT_MAT2 || u.type == GL_FLOAT_MAT3 || u.type == GL_FLOAT_MAT4
    guard !isMatrix, componentCount(u.type) == components else { return fail(.invalidOperation) }
    let isBool = u.type == GL_BOOL || u.type == GL_BOOL_VEC2 || u.type == GL_BOOL_VEC3 || u.type == GL_BOOL_VEC4
    let isInt = u.type == GL_INT || u.type == GL_INT_VEC2 || u.type == GL_INT_VEC3 || u.type == GL_INT_VEC4
    if !isBool && isInt != integers { return fail(.invalidOperation) }
    guard count <= 1 || u.arraySize > 1 else { return fail(.invalidOperation) }
    guard let block = unsafe p.block else { return }
    for i in 0..<min(Int(count), u.arraySize - l.element) {
      let at = u.offset + (l.element + i) * u.arrayStride
      guard at + 4 * components <= p.blockBytes else { break }
      for c in 0..<components {
        let src = 4 * (i * components + c)
        if isBool {
          let on = integers ? unsafe values.load(fromByteOffset: src, as: Int32.self) != 0 : unsafe values.load(fromByteOffset: src, as: Float.self) != 0
          unsafe block.storeBytes(of: on ? UInt32(1) : 0, toByteOffset: at + 4 * c, as: UInt32.self)
        } else {
          unsafe block.storeBytes(of: values.load(fromByteOffset: src, as: UInt32.self), toByteOffset: at + 4 * c, as: UInt32.self)
        }
      }
    }
    p.blockDirty = true
  }

  /// The index in `samplerBindings` of element `element` of sampler uniform `u`.
  func samplerIndex(_ p: GLProgram, _ u: ActiveUniform, element: Int) -> Int? {
    guard let b = u.samplerBinding else { return nil }
    return p.samplerBindings.firstIndex(of: b + UInt32(element))
  }

  func uniformMatrix(_ location: GLint, count: GLsizei, columns: Int, transpose: Bool, _ values: UnsafePointer<Float>?) {
    if count == 1, !transpose, let p = program, p.linkStatus, location >= 0, Int(location) < p.locationInfo.count,
      let values = unsafe values, let block = unsafe p.block
    {
      let li = p.locationInfo[Int(location)]
      if li.kind == 3, li.components == columns, li.offset + (columns - 1) * li.matrixStride + 4 * columns <= p.blockBytes {
        for c in 0..<columns {
          unsafe (block + li.offset + c * li.matrixStride).copyMemory(from: UnsafeRawPointer(values + c * columns), byteCount: 4 * columns)
        }
        p.blockDirty = true
        return
      }
    }
    guard count >= 0 else { return fail(.invalidValue) }
    guard let (p, l, u) = uniformTarget(location), let values = unsafe values else { return }
    let type = [GL_FLOAT_MAT2, GL_FLOAT_MAT3, GL_FLOAT_MAT4][columns - 2]
    guard u.type == type else { return fail(.invalidOperation) }
    guard !transpose else { return fail(.invalidValue) }
    guard count <= 1 || u.arraySize > 1 else { return fail(.invalidOperation) }
    guard let block = unsafe p.block else { return }
    for i in 0..<min(Int(count), u.arraySize - l.element) {
      let at = u.offset + (l.element + i) * u.arrayStride
      for c in 0..<columns {
        let column = at + c * u.matrixStride
        guard column + 4 * columns <= p.blockBytes else { break }
        for r in 0..<columns {
          unsafe block.storeBytes(of: values[i * columns * columns + c * columns + r], toByteOffset: column + 4 * r, as: Float.self)
        }
      }
    }
    p.blockDirty = true
  }

  /// glGetUniform{fi}v: the value at `location` of program `name`, as floats.
  func getUniform(_ name: GLuint, _ location: GLint) -> [Float]? {
    guard let p = program(name) else { return nil }
    guard p.linkStatus, location >= 0, Int(location) < p.locations.count else {
      fail(.invalidOperation)
      return nil
    }
    let l = p.locations[Int(location)]
    let u = p.interface.uniforms[l.uniform]
    if u.isSampler {
      guard let n = samplerIndex(p, u, element: l.element) else { return [0] }
      return [Float(p.samplerUnits[n])]
    }
    guard let block = unsafe p.block else { return nil }
    let at = u.offset + l.element * u.arrayStride
    var out: [Float] = []
    let isInt = [GL_INT, GL_INT_VEC2, GL_INT_VEC3, GL_INT_VEC4].contains(u.type)
    let isBool = [GL_BOOL, GL_BOOL_VEC2, GL_BOOL_VEC3, GL_BOOL_VEC4].contains(u.type)
    switch u.type {
    case GL_FLOAT_MAT2, GL_FLOAT_MAT3, GL_FLOAT_MAT4:
      let n = u.type == GL_FLOAT_MAT2 ? 2 : u.type == GL_FLOAT_MAT3 ? 3 : 4
      for c in 0..<n {
        for r in 0..<n { out.append(unsafe block.load(fromByteOffset: at + c * u.matrixStride + 4 * r, as: Float.self)) }
      }
    default:
      for c in 0..<componentCount(u.type) {
        if isInt { out.append(Float(unsafe block.load(fromByteOffset: at + 4 * c, as: Int32.self))) } else if isBool {
          out.append(unsafe block.load(fromByteOffset: at + 4 * c, as: UInt32.self) != 0 ? 1 : 0)
        } else { out.append(unsafe block.load(fromByteOffset: at + 4 * c, as: Float.self)) }
      }
    }
    return out
  }
}

@_silgen_name("strlen") func strlen(_ s: UnsafePointer<CChar>) -> Int
