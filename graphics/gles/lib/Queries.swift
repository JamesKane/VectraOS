// SPDX-License-Identifier: BSD-3-Clause

// The queries (gles(3), "Queries"): every pname of GL ES 2.0's state tables 6.2 to 6.19 and the extensions', each
// answered as GL's conversion rules say for Get{Boolean,Integer,Float}v; GetString; the object queries.

import GPUCore

/// A state value before conversion: the conversion to integers differs for colours and depths (mapped from [-1, 1] to
/// the integers' range), for floats (rounded) and for enums and integers (as they are).
enum StateValue {
  case integers([Int64])
  case floats([Float])
  case booleans([Bool])
  /// Colours, depths and the coverage value, which GetIntegerv maps from [-1, 1] onto the integers' range.
  case normalized([Float])

  var asFloats: [Float] {
    switch self {
    case .integers(let v): v.map { Float($0) }
    case .floats(let v), .normalized(let v): v
    case .booleans(let v): v.map { $0 ? 1 : 0 }
    }
  }

  var asIntegers: [Int32] {
    switch self {
    case .integers(let v): v.map { Int32(truncatingIfNeeded: $0) }
    case .floats(let v): v.map { Int32(($0).rounded()) }
    case .booleans(let v): v.map { $0 ? 1 : 0 }
    case .normalized(let v):
      v.map { f in
        let c = Double(min(max(f, -1), 1))
        return Int32(clamping: Int64(((c * 4_294_967_295) - 1) / 2))
      }
    }
  }

  var asBooleans: [Bool] {
    switch self {
    case .integers(let v): v.map { $0 != 0 }
    case .floats(let v), .normalized(let v): v.map { $0 != 0 }
    case .booleans(let v): v
    }
  }
}

extension GLContext {
  /// The extensions the library has with this device.
  var extensions: [String] {
    var e = ["GL_OES_mapbuffer", "GL_OES_element_index_uint", "GL_OES_depth_texture", "GL_OES_depth24", "GL_OES_depth32",
             "GL_OES_rgb8_rgba8", "GL_OES_texture_npot", "GL_OES_vertex_array_object", "GL_EXT_texture_format_BGRA8888",
             "GL_EXT_discard_framebuffer"]
    if storage(forRenderbuffer: GL_DEPTH24_STENCIL8_OES) != nil { e.append("GL_OES_packed_depth_stencil") }
    if device.limits.features.samplerAnisotropy { e.append("GL_EXT_texture_filter_anisotropic") }
    return e
  }

  func string(_ name: GLenum) -> String? {
    switch name {
    case GL_VENDOR: return "VectraOS"
    case GL_RENDERER: return "VectraOS GLES on \(device.name) (\(device.backend))"
    case GL_VERSION: return "OpenGL ES 2.0 VectraOS"
    case GL_SHADING_LANGUAGE_VERSION: return "OpenGL ES GLSL ES 1.00"
    case GL_EXTENSIONS: return extensions.joined(separator: " ")
    default:
      fail(.invalidEnum)
      return nil
    }
  }

  func name(_ o: AnyObject?) -> Int64 {
    switch o {
    case let b as GLBuffer: Int64(b.name)
    case let t as GLTexture: Int64(t.name)
    case let r as GLRenderbuffer: Int64(r.name)
    case let f as GLFramebuffer: Int64(f.name)
    case let p as GLProgram: Int64(p.name)
    case let v as GLVertexArray: Int64(v.name)
    default: 0
    }
  }

  /// The value of state `pname`, or nil (and INVALID_ENUM) for a pname GL ES 2.0 doesn't have.
  func state(_ pname: GLenum) -> StateValue? {
    let maxTexture = Int64(maxTextureSize)
    let target = framebufferStatus().1
    func ints(_ v: Int64...) -> StateValue { .integers(v) }
    switch pname {
    case GL_ACTIVE_TEXTURE: return ints(Int64(GL_TEXTURE0) + Int64(activeTexture))
    case GL_ALIASED_LINE_WIDTH_RANGE:
      return .floats([1, device.limits.features.wideLines ? device.limits.maxLineWidth : 1])
    case GL_ALIASED_POINT_SIZE_RANGE: return .floats([1, 1024])
    case GL_RED_BITS: return ints(Int64(target?.redBits ?? 0))
    case GL_GREEN_BITS: return ints(Int64(target?.greenBits ?? 0))
    case GL_BLUE_BITS: return ints(Int64(target?.blueBits ?? 0))
    case GL_ALPHA_BITS: return ints(Int64(target?.alphaBits ?? 0))
    case GL_DEPTH_BITS: return ints(Int64(target?.depthBits ?? 0))
    case GL_STENCIL_BITS: return ints(Int64(target?.stencilBits ?? 0))
    case GL_ARRAY_BUFFER_BINDING: return ints(name(arrayBuffer))
    case GL_ELEMENT_ARRAY_BUFFER_BINDING: return ints(name(vertexArray.elementBuffer))
    case GL_VERTEX_ARRAY_BINDING_OES: return ints(Int64(vertexArray.name))
    case GL_BLEND: return .booleans([blend])
    case GL_BLEND_COLOR: return .normalized([blendColor.0, blendColor.1, blendColor.2, blendColor.3])
    case GL_BLEND_DST_ALPHA: return ints(Int64(blendDstAlpha))
    case GL_BLEND_DST_RGB: return ints(Int64(blendDstRGB))
    case GL_BLEND_SRC_ALPHA: return ints(Int64(blendSrcAlpha))
    case GL_BLEND_SRC_RGB: return ints(Int64(blendSrcRGB))
    case GL_BLEND_EQUATION_RGB: return ints(Int64(blendEquationRGB))
    case GL_BLEND_EQUATION_ALPHA: return ints(Int64(blendEquationAlpha))
    case GL_COLOR_CLEAR_VALUE: return .normalized([clearColor.0, clearColor.1, clearColor.2, clearColor.3])
    case GL_COLOR_WRITEMASK: return .booleans([colorMask.0, colorMask.1, colorMask.2, colorMask.3])
    case GL_COMPRESSED_TEXTURE_FORMATS: return .integers([])
    case GL_NUM_COMPRESSED_TEXTURE_FORMATS: return ints(0)
    case GL_CULL_FACE: return .booleans([cullFace])
    case GL_CULL_FACE_MODE: return ints(Int64(cullFaceMode))
    case GL_CURRENT_PROGRAM: return ints(name(program))
    case GL_DEPTH_CLEAR_VALUE: return .normalized([clearDepth])
    case GL_DEPTH_FUNC: return ints(Int64(depthFunc))
    case GL_DEPTH_RANGE: return .normalized([depthRange.0, depthRange.1])
    case GL_DEPTH_TEST: return .booleans([depthTest])
    case GL_DEPTH_WRITEMASK: return .booleans([depthMask])
    case GL_DITHER: return .booleans([dither])
    case GL_FRAMEBUFFER_BINDING: return ints(name(framebuffer))
    case GL_FRONT_FACE: return ints(Int64(frontFace))
    case GL_GENERATE_MIPMAP_HINT: return ints(Int64(generateMipmapHint))
    case GL_IMPLEMENTATION_COLOR_READ_FORMAT: return ints(Int64(GL_RGBA))
    case GL_IMPLEMENTATION_COLOR_READ_TYPE: return ints(Int64(GL_UNSIGNED_BYTE))
    case GL_LINE_WIDTH: return .floats([lineWidth])
    case GL_MAX_COMBINED_TEXTURE_IMAGE_UNITS, GL_MAX_TEXTURE_IMAGE_UNITS: return ints(Int64(GLContext.textureUnits))
    case GL_MAX_VERTEX_TEXTURE_IMAGE_UNITS: return ints(0)
    case GL_MAX_CUBE_MAP_TEXTURE_SIZE, GL_MAX_TEXTURE_SIZE, GL_MAX_RENDERBUFFER_SIZE: return ints(maxTexture)
    case GL_MAX_FRAGMENT_UNIFORM_VECTORS, GL_MAX_VERTEX_UNIFORM_VECTORS: return ints(256)
    case GL_MAX_VARYING_VECTORS: return ints(15)
    case GL_MAX_VERTEX_ATTRIBS: return ints(Int64(maxVertexAttribs))
    case GL_MAX_VIEWPORT_DIMS: return ints(maxTexture, maxTexture)
    case GL_NUM_SHADER_BINARY_FORMATS: return ints(1)
    case GL_SHADER_BINARY_FORMATS: return ints(Int64(GL_SHADER_BINARY_FORMAT_SPIR_V))
    case GL_SHADER_COMPILER: return .booleans([unsafe shaderFrontEnd != nil])
    case GL_PACK_ALIGNMENT: return ints(Int64(packAlignment))
    case GL_UNPACK_ALIGNMENT: return ints(Int64(unpackAlignment))
    case GL_POLYGON_OFFSET_FACTOR: return .floats([polygonOffset.factor])
    case GL_POLYGON_OFFSET_UNITS: return .floats([polygonOffset.units])
    case GL_POLYGON_OFFSET_FILL: return .booleans([polygonOffsetFill])
    case GL_RENDERBUFFER_BINDING: return ints(name(renderbuffer))
    case GL_SAMPLE_ALPHA_TO_COVERAGE: return .booleans([sampleAlphaToCoverage])
    case GL_SAMPLE_COVERAGE: return .booleans([sampleCoverage])
    case GL_SAMPLE_COVERAGE_INVERT: return .booleans([sampleCoverageInvert])
    case GL_SAMPLE_COVERAGE_VALUE: return .normalized([sampleCoverageValue])
    case GL_SAMPLE_BUFFERS, GL_SAMPLES: return ints(0)
    case GL_SCISSOR_BOX: return ints(Int64(scissor.x), Int64(scissor.y), Int64(scissor.width), Int64(scissor.height))
    case GL_SCISSOR_TEST: return .booleans([scissorTest])
    case GL_STENCIL_TEST: return .booleans([stencilTest])
    case GL_STENCIL_CLEAR_VALUE: return ints(Int64(clearStencil))
    case GL_STENCIL_FUNC: return ints(Int64(stencilFront.function))
    case GL_STENCIL_REF: return ints(Int64(stencilFront.reference))
    case GL_STENCIL_VALUE_MASK: return ints(Int64(stencilFront.valueMask))
    case GL_STENCIL_WRITEMASK: return ints(Int64(stencilFront.writeMask))
    case GL_STENCIL_FAIL: return ints(Int64(stencilFront.fail))
    case GL_STENCIL_PASS_DEPTH_FAIL: return ints(Int64(stencilFront.depthFail))
    case GL_STENCIL_PASS_DEPTH_PASS: return ints(Int64(stencilFront.depthPass))
    case GL_STENCIL_BACK_FUNC: return ints(Int64(stencilBack.function))
    case GL_STENCIL_BACK_REF: return ints(Int64(stencilBack.reference))
    case GL_STENCIL_BACK_VALUE_MASK: return ints(Int64(stencilBack.valueMask))
    case GL_STENCIL_BACK_WRITEMASK: return ints(Int64(stencilBack.writeMask))
    case GL_STENCIL_BACK_FAIL: return ints(Int64(stencilBack.fail))
    case GL_STENCIL_BACK_PASS_DEPTH_FAIL: return ints(Int64(stencilBack.depthFail))
    case GL_STENCIL_BACK_PASS_DEPTH_PASS: return ints(Int64(stencilBack.depthPass))
    case GL_SUBPIXEL_BITS: return ints(Int64(max(device.limits.viewportSubPixelBits, 4)))
    case GL_TEXTURE_BINDING_2D: return ints(Int64(textures2D[activeTexture]?.name ?? 0))
    case GL_TEXTURE_BINDING_CUBE_MAP: return ints(Int64(texturesCube[activeTexture]?.name ?? 0))
    case GL_VIEWPORT: return ints(Int64(viewport.x), Int64(viewport.y), Int64(viewport.width), Int64(viewport.height))
    case GL_MAX_TEXTURE_MAX_ANISOTROPY_EXT:
      return .floats([device.limits.features.samplerAnisotropy ? device.limits.maxAnisotropy : 1])
    default:
      fail(.invalidEnum)
      return nil
    }
  }

  func bufferParameter(_ target: GLenum, _ pname: GLenum) -> GLint? {
    guard let bound = bufferTarget(target) else {
      fail(.invalidEnum)
      return nil
    }
    guard let b = bound else {
      fail(.invalidOperation)
      return nil
    }
    switch pname {
    case GL_BUFFER_SIZE: return GLint(truncatingIfNeeded: b.size)
    case GL_BUFFER_USAGE: return GLint(bitPattern: b.usage)
    case GL_BUFFER_ACCESS_OES: return GLint(bitPattern: GL_WRITE_ONLY_OES)
    case GL_BUFFER_MAPPED_OES: return b.mapped ? 1 : 0
    default:
      fail(.invalidEnum)
      return nil
    }
  }

  func renderbufferParameter(_ target: GLenum, _ pname: GLenum) -> GLint? {
    guard target == GL_RENDERBUFFER else {
      fail(.invalidEnum)
      return nil
    }
    guard let r = renderbuffer else {
      fail(.invalidOperation)
      return nil
    }
    let alpha: Bool
    if case .color(let a) = r.kind { alpha = a } else { alpha = false }
    let isColor: Bool
    if case .color = r.kind { isColor = true } else { isColor = false }
    let bits = isColor ? colorBits(r.internalFormat, alpha: alpha) : (0, 0, 0, 0)
    switch pname {
    case GL_RENDERBUFFER_WIDTH: return r.width
    case GL_RENDERBUFFER_HEIGHT: return r.height
    case GL_RENDERBUFFER_INTERNAL_FORMAT: return GLint(bitPattern: r.internalFormat)
    case GL_RENDERBUFFER_RED_SIZE: return bits.0
    case GL_RENDERBUFFER_GREEN_SIZE: return bits.1
    case GL_RENDERBUFFER_BLUE_SIZE: return bits.2
    case GL_RENDERBUFFER_ALPHA_SIZE: return bits.3
    case GL_RENDERBUFFER_DEPTH_SIZE:
      switch r.kind {
      case .depth(let f), .depthStencil(let f): return f == .depth16 ? 16 : 24
      default: return 0
      }
    case GL_RENDERBUFFER_STENCIL_SIZE:
      switch r.kind {
      case .stencil, .depthStencil: return 8
      default: return 0
      }
    default:
      fail(.invalidEnum)
      return nil
    }
  }

  func attachmentParameter(_ target: GLenum, _ attachment: GLenum, _ pname: GLenum) -> GLint? {
    guard target == GL_FRAMEBUFFER else {
      fail(.invalidEnum)
      return nil
    }
    guard let f = framebuffer else {
      fail(.invalidOperation)
      return nil
    }
    let a: FramebufferAttachment
    switch attachment {
    case GL_COLOR_ATTACHMENT0: a = f.color
    case GL_DEPTH_ATTACHMENT: a = f.depth
    case GL_STENCIL_ATTACHMENT: a = f.stencil
    default:
      fail(.invalidEnum)
      return nil
    }
    switch (pname, a) {
    case (GL_FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE, .none): return GLint(GL_NONE)
    case (GL_FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE, .texture): return GLint(GL_TEXTURE)
    case (GL_FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE, .renderbuffer): return GLint(GL_RENDERBUFFER)
    case (GL_FRAMEBUFFER_ATTACHMENT_OBJECT_NAME, .texture(let t, _, _)): return GLint(bitPattern: t.name)
    case (GL_FRAMEBUFFER_ATTACHMENT_OBJECT_NAME, .renderbuffer(let r)): return GLint(bitPattern: r.name)
    case (GL_FRAMEBUFFER_ATTACHMENT_TEXTURE_LEVEL, .texture(_, let level, _)): return GLint(level)
    case (GL_FRAMEBUFFER_ATTACHMENT_TEXTURE_CUBE_MAP_FACE, .texture(let t, _, let face)):
      return t.target == GL_TEXTURE_CUBE_MAP ? GLint(GL_TEXTURE_CUBE_MAP_POSITIVE_X) + GLint(face) : 0
    default:
      fail(a.isNone && pname != GL_FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE ? .invalidEnum : .invalidEnum)
      return nil
    }
  }

  func vertexAttribState(_ index: GLuint, _ pname: GLenum) -> [Float]? {
    guard index < GLuint(maxVertexAttribs) else {
      fail(.invalidValue)
      return nil
    }
    let a = vertexArray.attributes[Int(index)]
    switch pname {
    case GL_VERTEX_ATTRIB_ARRAY_ENABLED: return [a.enabled ? 1 : 0]
    case GL_VERTEX_ATTRIB_ARRAY_SIZE: return [Float(a.size)]
    case GL_VERTEX_ATTRIB_ARRAY_STRIDE: return [Float(a.stride)]
    case GL_VERTEX_ATTRIB_ARRAY_TYPE: return [Float(a.type)]
    case GL_VERTEX_ATTRIB_ARRAY_NORMALIZED: return [a.normalized ? 1 : 0]
    case GL_VERTEX_ATTRIB_ARRAY_BUFFER_BINDING: return [Float(a.buffer?.name ?? 0)]
    case GL_CURRENT_VERTEX_ATTRIB: return Array(constantAttributes[(4 * Int(index))..<(4 * Int(index) + 4)])
    default:
      fail(.invalidEnum)
      return nil
    }
  }

  func shaderParameter(_ name: GLuint, _ pname: GLenum) -> GLint? {
    guard let s = shader(name) else { return nil }
    switch pname {
    case GL_SHADER_TYPE: return GLint(bitPattern: s.type)
    case GL_DELETE_STATUS: return s.deletePending ? 1 : 0
    case GL_COMPILE_STATUS: return s.compileStatus ? 1 : 0
    case GL_INFO_LOG_LENGTH: return s.log.isEmpty ? 0 : GLint(s.log.utf8.count + 1)
    case GL_SHADER_SOURCE_LENGTH: return s.source.isEmpty ? 0 : GLint(s.source.count + 1)
    default:
      fail(.invalidEnum)
      return nil
    }
  }

  func programParameter(_ name: GLuint, _ pname: GLenum) -> GLint? {
    guard let p = program(name) else { return nil }
    switch pname {
    case GL_DELETE_STATUS: return p.deletePending ? 1 : 0
    case GL_LINK_STATUS: return p.linkStatus ? 1 : 0
    case GL_VALIDATE_STATUS: return p.validateStatus ? 1 : 0
    case GL_INFO_LOG_LENGTH: return p.log.isEmpty ? 0 : GLint(p.log.utf8.count + 1)
    case GL_ATTACHED_SHADERS: return GLint((p.vertexShader != nil ? 1 : 0) + (p.fragmentShader != nil ? 1 : 0))
    case GL_ACTIVE_ATTRIBUTES: return p.linkStatus ? GLint(p.interface.attributes.count) : 0
    case GL_ACTIVE_ATTRIBUTE_MAX_LENGTH:
      return p.linkStatus ? GLint(p.interface.attributes.map { $0.name.utf8.count + 1 }.max() ?? 0) : 0
    case GL_ACTIVE_UNIFORMS: return p.linkStatus ? GLint(p.interface.uniforms.count) : 0
    case GL_ACTIVE_UNIFORM_MAX_LENGTH:
      return p.linkStatus ? GLint(p.interface.uniforms.map { $0.name.utf8.count + 1 }.max() ?? 0) : 0
    default:
      fail(.invalidEnum)
      return nil
    }
  }

  func checkFramebufferStatus(_ target: GLenum) -> GLenum {
    guard target == GL_FRAMEBUFFER else {
      fail(.invalidEnum)
      return 0
    }
    return framebufferStatus().0
  }
}
