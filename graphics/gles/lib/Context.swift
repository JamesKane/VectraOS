// SPDX-License-Identifier: BSD-3-Clause

// A GL ES 2.0 context (gles(3)): the state the spec's tables list, the objects bound, and the calls that set them.
// Draws are Draw.swift's, textures Textures.swift's, the queries Queries.swift's. Every call that fails records the
// spec's error and changes nothing.

import GPUCore

/// What a context draws into when framebuffer 0 is bound: its EGL surface's current image.
protocol DefaultFramebuffer: AnyObject {
  /// The target to draw into now (a window's current image, a pbuffer's image).
  var target: RenderTarget { get }
  /// Changes whenever `target` does (a swap), so a context knows to look again.
  var serial: UInt64 { get }
}

struct StencilFace: Equatable {
  var function: GLenum = GL_ALWAYS
  var reference: GLint = 0
  var valueMask: GLuint = ~0
  var fail: GLenum = GL_KEEP
  var depthFail: GLenum = GL_KEEP
  var depthPass: GLenum = GL_KEEP
  var writeMask: GLuint = ~0
}

public final class GLContext {
  let frame: Frame
  let share: ShareGroup
  var device: any GPUDevice { frame.device }
  var error: GLErrorCode?
  /// The surface framebuffer 0 draws into, which EGL's MakeCurrent sets.
  var surface: DefaultFramebuffer?
  var viewportInitialized = false

  // Clears.
  var clearColor: (Float, Float, Float, Float) = (0, 0, 0, 0)
  var clearDepth: Float = 1
  var clearStencil: GLint = 0
  // Masks.
  var colorMask: (Bool, Bool, Bool, Bool) = (true, true, true, true)
  var depthMask = true
  // Enables.
  var blend = false
  var cullFace = false
  var depthTest = false
  var dither = true
  var polygonOffsetFill = false
  var sampleAlphaToCoverage = false
  var sampleCoverage = false
  var scissorTest = false
  var stencilTest = false
  // Blending.
  var blendSrcRGB: GLenum = GL_ONE
  var blendDstRGB: GLenum = GL_ZERO
  var blendSrcAlpha: GLenum = GL_ONE
  var blendDstAlpha: GLenum = GL_ZERO
  var blendEquationRGB: GLenum = GL_FUNC_ADD
  var blendEquationAlpha: GLenum = GL_FUNC_ADD
  var blendColor: (Float, Float, Float, Float) = (0, 0, 0, 0)
  // Depth and stencil.
  var depthFunc: GLenum = GL_LESS
  var depthRange: (Float, Float) = (0, 1)
  var stencilFront = StencilFace()
  var stencilBack = StencilFace()
  // Rasterization.
  var cullFaceMode: GLenum = GL_BACK
  var frontFace: GLenum = GL_CCW
  var lineWidth: Float = 1
  var polygonOffset: (factor: Float, units: Float) = (0, 0)
  var viewport: (x: GLint, y: GLint, width: GLsizei, height: GLsizei) = (0, 0, 0, 0)
  var scissor: (x: GLint, y: GLint, width: GLsizei, height: GLsizei) = (0, 0, 0, 0)
  var sampleCoverageValue: Float = 1
  var sampleCoverageInvert = false
  // Pixel storage and hints.
  var unpackAlignment = 4
  var packAlignment = 4
  var generateMipmapHint: GLenum = GL_DONT_CARE
  var derivativeHint: GLenum = GL_DONT_CARE

  // Bindings.
  var arrayBuffer: GLBuffer?
  let defaultVertexArray = GLVertexArray(name: 0)
  var vertexArray: GLVertexArray
  var vertexArrays = NameTable<GLVertexArray>()
  var constantAttributes = [Float](repeating: 0, count: 4 * maxVertexAttribs)
  var program: GLProgram?
  var activeTexture = 0
  static let textureUnits = 8
  var textures2D = [GLTexture?](repeating: nil, count: GLContext.textureUnits)
  var texturesCube = [GLTexture?](repeating: nil, count: GLContext.textureUnits)
  /// The textures named 0: each target's own default texture.
  let default2D = GLTexture(name: 0)
  let defaultCube = GLTexture(name: 0)
  var renderbuffer: GLRenderbuffer?
  var framebuffer: GLFramebuffer?
  var framebuffers = NameTable<GLFramebuffer>()

  /// Pipelines made, and the memory ReadPixels reads back into.
  var pipelinesMade = 0
  /// A draw's texture and sampler slots and the images it reads, kept to be used again.
  var drawSlots: [(UInt32, UInt32)] = []
  var drawReads: [UInt64] = []
  /// The last draw's pipeline and what it was found by.
  var lastPipeline: (program: GLProgram, link: UInt64, serial: UInt64, layout: VertexLayout, topology: PrimitiveTopology,
                     target: RenderTarget, pipeline: GPUPipeline)?
  var readback: GPUMemory?
  /// Bumps whenever a pipeline's fixed state may have changed.
  var pipelineSerial: UInt64 = 1
  /// Bumps when any image an attachment could name is made again (a re-specified texture or renderbuffer), or an attachment
  /// changes: the target is looked at again.
  var attachmentSerial: UInt64 = 1
  var targetCache: (RenderTarget, framebuffer: GLuint, serial: UInt64, surface: UInt64)?
  var targetIDs: UInt64 = 0

  /// A context of the device's frame, sharing `share`'s objects.
  init(frame: Frame, share: ShareGroup?) {
    self.frame = frame
    self.share = share ?? ShareGroup()
    vertexArray = defaultVertexArray
    default2D.target = GL_TEXTURE_2D
    defaultCube.target = GL_TEXTURE_CUBE_MAP
    for i in 0..<maxVertexAttribs { constantAttributes[4 * i + 3] = 1 }
  }

  /// Records `e` unless an error is already waiting for glGetError.
  func fail(_ e: GLErrorCode) {
    if error == nil { error = e }
  }

  func takeError() -> GLenum {
    defer { error = nil }
    return error?.rawValue ?? GL_NO_ERROR
  }

  /// A device failure, as GL can say it: out of memory.
  func fail(_ e: GPUError) {
    say("the device: \(e)")
    fail(.outOfMemory)
  }

  /// Made current on `surface`: a context's first sets its viewport and scissor to the surface's size.
  func madeCurrent(_ surface: DefaultFramebuffer?) {
    self.surface = surface
    targetCache = nil
    if !viewportInitialized, let s = surface {
      let t = s.target
      viewport = (0, 0, t.width, t.height)
      scissor = (0, 0, t.width, t.height)
      viewportInitialized = true
    }
  }

  // MARK: Enables

  func setEnabled(_ cap: GLenum, _ on: Bool) {
    switch cap {
    case GL_BLEND: blend = on
    case GL_CULL_FACE: cullFace = on
    case GL_DEPTH_TEST: depthTest = on
    case GL_DITHER: dither = on
    case GL_POLYGON_OFFSET_FILL: polygonOffsetFill = on
    case GL_SAMPLE_ALPHA_TO_COVERAGE: sampleAlphaToCoverage = on
    case GL_SAMPLE_COVERAGE: sampleCoverage = on
    case GL_SCISSOR_TEST: scissorTest = on
    case GL_STENCIL_TEST: stencilTest = on
    default:
      fail(.invalidEnum)
      return
    }
    pipelineSerial &+= 1
  }

  func isEnabled(_ cap: GLenum) -> Bool? {
    switch cap {
    case GL_BLEND: blend
    case GL_CULL_FACE: cullFace
    case GL_DEPTH_TEST: depthTest
    case GL_DITHER: dither
    case GL_POLYGON_OFFSET_FILL: polygonOffsetFill
    case GL_SAMPLE_ALPHA_TO_COVERAGE: sampleAlphaToCoverage
    case GL_SAMPLE_COVERAGE: sampleCoverage
    case GL_SCISSOR_TEST: scissorTest
    case GL_STENCIL_TEST: stencilTest
    default: nil
    }
  }

  // MARK: Fixed state

  static func isBlendFactor(_ f: GLenum, destination: Bool) -> Bool {
    switch f {
    case GL_ZERO, GL_ONE, GL_SRC_COLOR, GL_ONE_MINUS_SRC_COLOR, GL_DST_COLOR, GL_ONE_MINUS_DST_COLOR, GL_SRC_ALPHA,
      GL_ONE_MINUS_SRC_ALPHA, GL_DST_ALPHA, GL_ONE_MINUS_DST_ALPHA, GL_CONSTANT_COLOR, GL_ONE_MINUS_CONSTANT_COLOR,
      GL_CONSTANT_ALPHA, GL_ONE_MINUS_CONSTANT_ALPHA:
      true
    // GL ES 2.0 takes SRC_ALPHA_SATURATE as a source and a destination factor alike.
    case GL_SRC_ALPHA_SATURATE: true
    default: false
    }
  }

  func blendFuncSeparate(_ sRGB: GLenum, _ dRGB: GLenum, _ sA: GLenum, _ dA: GLenum) {
    guard Self.isBlendFactor(sRGB, destination: false), Self.isBlendFactor(dRGB, destination: true),
      Self.isBlendFactor(sA, destination: false), Self.isBlendFactor(dA, destination: true)
    else { return fail(.invalidEnum) }
    blendSrcRGB = sRGB
    blendDstRGB = dRGB
    blendSrcAlpha = sA
    blendDstAlpha = dA
    pipelineSerial &+= 1
  }

  func blendEquationSeparate(_ rgb: GLenum, _ alpha: GLenum) {
    func ok(_ e: GLenum) -> Bool { e == GL_FUNC_ADD || e == GL_FUNC_SUBTRACT || e == GL_FUNC_REVERSE_SUBTRACT }
    guard ok(rgb), ok(alpha) else { return fail(.invalidEnum) }
    blendEquationRGB = rgb
    blendEquationAlpha = alpha
    pipelineSerial &+= 1
  }

  static func isCompare(_ f: GLenum) -> Bool { f >= GL_NEVER && f <= GL_ALWAYS }

  func setDepthFunc(_ f: GLenum) {
    guard Self.isCompare(f) else { return fail(.invalidEnum) }
    depthFunc = f
    pipelineSerial &+= 1
  }

  func stencilFunc(_ face: GLenum, _ f: GLenum, _ ref: GLint, _ mask: GLuint) {
    guard Self.isCompare(f) else { return fail(.invalidEnum) }
    guard face == GL_FRONT || face == GL_BACK || face == GL_FRONT_AND_BACK else { return fail(.invalidEnum) }
    if face != GL_BACK {
      stencilFront.function = f
      stencilFront.reference = ref
      stencilFront.valueMask = mask
    }
    if face != GL_FRONT {
      stencilBack.function = f
      stencilBack.reference = ref
      stencilBack.valueMask = mask
    }
    pipelineSerial &+= 1
  }

  static func isStencilOp(_ o: GLenum) -> Bool {
    switch o {
    case GL_KEEP, GL_ZERO, GL_REPLACE, GL_INCR, GL_DECR, GL_INVERT, GL_INCR_WRAP, GL_DECR_WRAP: true
    default: false
    }
  }

  func stencilOp(_ face: GLenum, _ fail: GLenum, _ zfail: GLenum, _ zpass: GLenum) {
    guard Self.isStencilOp(fail), Self.isStencilOp(zfail), Self.isStencilOp(zpass) else { return self.fail(.invalidEnum) }
    guard face == GL_FRONT || face == GL_BACK || face == GL_FRONT_AND_BACK else { return self.fail(.invalidEnum) }
    if face != GL_BACK {
      stencilFront.fail = fail
      stencilFront.depthFail = zfail
      stencilFront.depthPass = zpass
    }
    if face != GL_FRONT {
      stencilBack.fail = fail
      stencilBack.depthFail = zfail
      stencilBack.depthPass = zpass
    }
    pipelineSerial &+= 1
  }

  func stencilMask(_ face: GLenum, _ mask: GLuint) {
    guard face == GL_FRONT || face == GL_BACK || face == GL_FRONT_AND_BACK else { return fail(.invalidEnum) }
    if face != GL_BACK { stencilFront.writeMask = mask }
    if face != GL_FRONT { stencilBack.writeMask = mask }
  }

  func setCullFace(_ mode: GLenum) {
    guard mode == GL_FRONT || mode == GL_BACK || mode == GL_FRONT_AND_BACK else { return fail(.invalidEnum) }
    cullFaceMode = mode
    pipelineSerial &+= 1
  }

  func setFrontFace(_ mode: GLenum) {
    guard mode == GL_CW || mode == GL_CCW else { return fail(.invalidEnum) }
    frontFace = mode
    pipelineSerial &+= 1
  }

  func setLineWidth(_ w: Float) {
    guard w > 0 else { return fail(.invalidValue) }
    lineWidth = w
  }

  func setViewport(_ x: GLint, _ y: GLint, _ w: GLsizei, _ h: GLsizei) {
    guard w >= 0, h >= 0 else { return fail(.invalidValue) }
    let maxSize = GLsizei(max(frame.limits.maxImageDimension, 4096))
    viewport = (x, y, min(w, maxSize), min(h, maxSize))
  }

  func setScissor(_ x: GLint, _ y: GLint, _ w: GLsizei, _ h: GLsizei) {
    guard w >= 0, h >= 0 else { return fail(.invalidValue) }
    scissor = (x, y, w, h)
  }

  func setColorMask(_ r: Bool, _ g: Bool, _ b: Bool, _ a: Bool) {
    colorMask = (r, g, b, a)
    pipelineSerial &+= 1
  }

  func setDepthMask(_ on: Bool) {
    depthMask = on
    pipelineSerial &+= 1
  }

  func pixelStore(_ pname: GLenum, _ value: GLint) {
    guard value == 1 || value == 2 || value == 4 || value == 8 else {
      return fail(pname == GL_PACK_ALIGNMENT || pname == GL_UNPACK_ALIGNMENT ? .invalidValue : .invalidEnum)
    }
    switch pname {
    case GL_PACK_ALIGNMENT: packAlignment = Int(value)
    case GL_UNPACK_ALIGNMENT: unpackAlignment = Int(value)
    default: fail(.invalidEnum)
    }
  }

  func hint(_ target: GLenum, _ mode: GLenum) {
    guard mode == GL_FASTEST || mode == GL_NICEST || mode == GL_DONT_CARE else { return fail(.invalidEnum) }
    switch target {
    case GL_GENERATE_MIPMAP_HINT: generateMipmapHint = mode
    case 0x8B8B: derivativeHint = mode  // GL_FRAGMENT_SHADER_DERIVATIVE_HINT_OES
    default: fail(.invalidEnum)
    }
  }

  func setSampleCoverage(_ value: Float, _ invert: Bool) {
    sampleCoverageValue = min(max(value, 0), 1)
    sampleCoverageInvert = invert
    pipelineSerial &+= 1
  }

  // MARK: Buffers

  func genNames(_ n: GLsizei, _ out: UnsafeMutablePointer<GLuint>?, _ make: () -> GLuint) {
    guard n >= 0 else { return fail(.invalidValue) }
    guard let out = unsafe out else { return }
    for i in 0..<Int(n) { unsafe out[i] = make() }
  }

  func bufferTarget(_ target: GLenum) -> GLBuffer?? {
    switch target {
    case GL_ARRAY_BUFFER: return .some(arrayBuffer)
    case GL_ELEMENT_ARRAY_BUFFER: return .some(vertexArray.elementBuffer)
    default: return nil
    }
  }

  func bindBuffer(_ target: GLenum, _ name: GLuint) {
    guard target == GL_ARRAY_BUFFER || target == GL_ELEMENT_ARRAY_BUFFER else { return fail(.invalidEnum) }
    var b: GLBuffer?
    if name != 0 {
      b = share.buffers[name]
      if b == nil {
        let made = GLBuffer(name: name)
        share.buffers.insert(name, made)
        b = made
      }
    }
    if target == GL_ARRAY_BUFFER { arrayBuffer = b } else { vertexArray.elementBuffer = b }
  }

  func deleteBuffers(_ n: GLsizei, _ names: UnsafePointer<GLuint>?) {
    guard n >= 0 else { return fail(.invalidValue) }
    guard let names = unsafe names else { return }
    for i in 0..<Int(n) {
      let name = unsafe names[i]
      guard name != 0, let b = share.buffers.remove(name) else { continue }
      b.deleted = true
      if arrayBuffer === b { arrayBuffer = nil }
      for va in [defaultVertexArray] + Array(vertexArrays.objects.values) {
        if va.elementBuffer === b { va.elementBuffer = nil }
        for a in va.attributes.indices where va.attributes[a].buffer === b { va.attributes[a].buffer = nil }
      }
      if let m = b.memory { frame.retireBuffer(m, bytes: b.memoryBytes, openUse: b.openUse) }
      b.memory = nil
    }
  }

  func bufferData(_ target: GLenum, _ size: GLsizeiptr, _ data: UnsafeRawPointer?, _ usage: GLenum) {
    guard let bound = bufferTarget(target) else { return fail(.invalidEnum) }
    guard usage == GL_STREAM_DRAW || usage == GL_STATIC_DRAW || usage == GL_DYNAMIC_DRAW else { return fail(.invalidEnum) }
    guard size >= 0 else { return fail(.invalidValue) }
    guard let b = bound else { return fail(.invalidOperation) }
    if b.mapped { b.mapped = false }
    if b.size != size, let m = b.memory {
      frame.retireBuffer(m, bytes: b.memoryBytes, openUse: b.openUse)
      b.memory = nil
    }
    unsafe b.respecify(size, data, usage: usage)
  }

  func bufferSubData(_ target: GLenum, _ offset: GLintptr, _ size: GLsizeiptr, _ data: UnsafeRawPointer?) {
    guard let bound = bufferTarget(target) else { return fail(.invalidEnum) }
    guard offset >= 0, size >= 0 else { return fail(.invalidValue) }
    guard let b = bound else { return fail(.invalidOperation) }
    guard offset + size <= b.size else { return fail(.invalidValue) }
    guard !b.mapped else { return fail(.invalidOperation) }
    guard size > 0, let data = unsafe data, let bytes = unsafe b.bytes else { return }
    unsafe (bytes + offset).copyMemory(from: data, byteCount: size)
    b.markDirty(offset, offset + size)
  }

  func mapBuffer(_ target: GLenum, _ access: GLenum) -> UnsafeMutableRawPointer? {
    guard let bound = bufferTarget(target) else {
      fail(.invalidEnum)
      return nil
    }
    guard access == GL_WRITE_ONLY_OES else {
      fail(.invalidEnum)
      return nil
    }
    guard let b = bound, !b.mapped else {
      fail(.invalidOperation)
      return nil
    }
    b.mapped = true
    return unsafe b.bytes
  }

  func unmapBuffer(_ target: GLenum) -> Bool {
    guard let bound = bufferTarget(target) else {
      fail(.invalidEnum)
      return false
    }
    guard let b = bound, b.mapped else {
      fail(.invalidOperation)
      return false
    }
    b.mapped = false
    // What was written through the map isn't known: all of it is.
    b.markDirty(0, b.size)
    return true
  }

  /// The buffer's device copy, up to date for a draw of the open list: written in place where nothing the GPU may read
  /// it, else moved to fresh memory.
  func deviceCopy(_ b: GLBuffer) throws(GPUError) -> GPUMemory? {
    guard b.size > 0, let bytes = unsafe b.bytes else { return nil }
    if b.isDirty {
      let busy = frame.isBusy(b.openUse)
      if b.memory == nil || busy || b.memoryBytes != b.size {
        if let old = b.memory { frame.retireBuffer(old, bytes: b.memoryBytes, openUse: b.openUse) }
        let m = try frame.bufferMemory(b.size)
        unsafe m.pointer!.copyMemory(from: bytes, byteCount: b.size)
        b.memory = m
        b.memoryBytes = b.size
      } else {
        unsafe (b.memory!.pointer! + b.dirtyLow).copyMemory(from: bytes + b.dirtyLow, byteCount: b.dirtyHigh - b.dirtyLow)
      }
      b.dirtyLow = 0
      b.dirtyHigh = 0
    }
    b.openUse = frame.epoch
    return b.memory
  }

  // MARK: Vertex attributes

  func vertexAttribPointer(_ index: GLuint, _ size: GLint, _ type: GLenum, _ normalized: Bool, _ stride: GLsizei,
                           _ pointer: UnsafeRawPointer?) {
    guard index < GLuint(maxVertexAttribs) else { return fail(.invalidValue) }
    guard size >= 1, size <= 4, stride >= 0 else { return fail(.invalidValue) }
    guard attributeComponentBytes(type) != nil else { return fail(.invalidEnum) }
    // OES_vertex_array_object: a client array in a vertex array of its own is an error.
    let address = UInt(bitPattern: unsafe pointer)
    if vertexArray !== defaultVertexArray && arrayBuffer == nil && address != 0 { return fail(.invalidOperation) }
    var a = vertexArray.attributes[Int(index)]
    a.size = Int(size)
    a.type = type
    a.normalized = normalized
    a.stride = stride
    a.buffer = arrayBuffer
    a.pointer = address
    vertexArray.attributes[Int(index)] = a
  }

  func enableAttribute(_ index: GLuint, _ on: Bool) {
    guard index < GLuint(maxVertexAttribs) else { return fail(.invalidValue) }
    vertexArray.attributes[Int(index)].enabled = on
  }

  func vertexAttrib(_ index: GLuint, _ x: Float, _ y: Float, _ z: Float, _ w: Float) {
    guard index < GLuint(maxVertexAttribs) else { return fail(.invalidValue) }
    let i = 4 * Int(index)
    constantAttributes[i] = x
    constantAttributes[i + 1] = y
    constantAttributes[i + 2] = z
    constantAttributes[i + 3] = w
  }

  // MARK: Vertex arrays (OES_vertex_array_object)

  func bindVertexArray(_ name: GLuint) {
    if name == 0 {
      vertexArray = defaultVertexArray
      return
    }
    guard vertexArrays.isName(name) else { return fail(.invalidOperation) }
    if let va = vertexArrays[name] {
      vertexArray = va
    } else {
      let va = GLVertexArray(name: name)
      vertexArrays.insert(name, va)
      vertexArray = va
    }
  }

  func deleteVertexArrays(_ n: GLsizei, _ names: UnsafePointer<GLuint>?) {
    guard n >= 0 else { return fail(.invalidValue) }
    guard let names = unsafe names else { return }
    for i in 0..<Int(n) {
      let name = unsafe names[i]
      guard name != 0, let va = vertexArrays.remove(name) else { continue }
      va.deleted = true
      if vertexArray === va { vertexArray = defaultVertexArray }
    }
  }

  // MARK: Renderbuffers

  func bindRenderbuffer(_ target: GLenum, _ name: GLuint) {
    guard target == GL_RENDERBUFFER else { return fail(.invalidEnum) }
    if name == 0 {
      renderbuffer = nil
      return
    }
    if let r = share.renderbuffers[name] {
      renderbuffer = r
    } else {
      let r = GLRenderbuffer(name: name)
      share.renderbuffers.insert(name, r)
      renderbuffer = r
    }
  }

  func deleteRenderbuffers(_ n: GLsizei, _ names: UnsafePointer<GLuint>?) {
    guard n >= 0 else { return fail(.invalidValue) }
    guard let names = unsafe names else { return }
    for i in 0..<Int(n) {
      let name = unsafe names[i]
      guard name != 0, let r = share.renderbuffers.remove(name) else { continue }
      if renderbuffer === r { renderbuffer = nil }
      if let fb = framebuffer { detach(r, from: fb) }
      r.deleted = true
      if let image = r.image { releaseImage(image) }
      r.image = nil
    }
  }

  /// The device storage for a GL renderbuffer or depth texture format, or nil for one GL ES 2.0 (with the extensions
  /// the library has) doesn't name.
  func storage(forRenderbuffer f: GLenum) -> StorageKind? {
    let limits = frame.limits
    func depthTarget(_ p: PixelFormat) -> Bool { limits.formats(p).depthTarget }
    let depth24: PixelFormat = depthTarget(.depth24stencil8) ? .depth24stencil8 : .depth32f
    switch f {
    case GL_RGBA4, GL_RGB5_A1, GL_RGBA8_OES: return .color(alpha: true)
    case GL_RGB565, GL_RGB8_OES: return .color(alpha: false)
    case GL_DEPTH_COMPONENT16: return .depth(.depth16)
    case GL_DEPTH_COMPONENT24_OES, GL_DEPTH_COMPONENT32_OES: return .depth(depthTarget(.depth32f) ? .depth32f : depth24)
    case GL_STENCIL_INDEX8:
      if depthTarget(.stencil8) { return .stencil(.stencil8) }
      return depthTarget(.depth24stencil8) ? .stencil(.depth24stencil8) : nil
    case GL_DEPTH24_STENCIL8_OES:
      if depthTarget(.depth24stencil8) { return .depthStencil(.depth24stencil8) }
      if depthTarget(.depth32fstencil8) { return .depthStencil(.depth32fstencil8) }
      return nil
    default: return nil
    }
  }

  func renderbufferStorage(_ target: GLenum, _ internalFormat: GLenum, _ width: GLsizei, _ height: GLsizei) {
    guard target == GL_RENDERBUFFER else { return fail(.invalidEnum) }
    guard let kind = storage(forRenderbuffer: internalFormat) else {
      if internalFormat == GL_DEPTH24_STENCIL8_OES || internalFormat == GL_STENCIL_INDEX8 {
        say("a renderbuffer of \(internalFormat): the device has no such depth and stencil target")
        return fail(.outOfMemory)
      }
      return fail(.invalidEnum)
    }
    let maxSize = frame.limits.maxImageDimension
    guard width >= 0, height >= 0, width <= maxSize, height <= maxSize else { return fail(.invalidValue) }
    guard let r = renderbuffer else { return fail(.invalidOperation) }
    if let old = r.image { releaseImage(old) }
    r.image = nil
    r.internalFormat = internalFormat
    r.kind = kind
    r.width = width
    r.height = height
    attachmentSerial &+= 1
    guard width > 0, height > 0 else { return }
    let usage: ImageUsage
    switch kind {
    // Drawn into and sampled (a copy out of it is drawn into a copyable image first): what a device's passes may compress.
    case .color: usage = .renderTarget | .sampled
    default: usage = .depthStencilTarget
    }
    do throws(GPUError) {
      r.image = try device.makeImage(ImageDescriptor(format: kind.pixelFormat, width: width, height: height, usage: usage))
    } catch { fail(error) }
  }

  func releaseImage(_ image: GPUImage) {
    // A pass that draws into it, or reads it, is in the open list: the image goes once that is submitted.
    frame.release(image)
  }

  // MARK: Framebuffers

  func bindFramebuffer(_ target: GLenum, _ name: GLuint) {
    guard target == GL_FRAMEBUFFER else { return fail(.invalidEnum) }
    if name == 0 {
      framebuffer = nil
      return
    }
    if let f = framebuffers[name] {
      framebuffer = f
    } else {
      let f = GLFramebuffer(name: name)
      framebuffers.insert(name, f)
      framebuffer = f
    }
  }

  func deleteFramebuffers(_ n: GLsizei, _ names: UnsafePointer<GLuint>?) {
    guard n >= 0 else { return fail(.invalidValue) }
    guard let names = unsafe names else { return }
    for i in 0..<Int(n) {
      let name = unsafe names[i]
      guard name != 0, let f = framebuffers.remove(name) else { continue }
      if framebuffer === f { framebuffer = nil }
    }
  }

  func detach(_ r: GLRenderbuffer, from f: GLFramebuffer) {
    func same(_ a: FramebufferAttachment) -> Bool {
      if case .renderbuffer(let x) = a { return x === r }
      return false
    }
    if same(f.color) { f.color = .none }
    if same(f.depth) { f.depth = .none }
    if same(f.stencil) { f.stencil = .none }
    attachmentSerial &+= 1
  }

  func detach(_ t: GLTexture, from f: GLFramebuffer) {
    func same(_ a: FramebufferAttachment) -> Bool {
      if case .texture(let x, _, _) = a { return x === t }
      return false
    }
    if same(f.color) { f.color = .none }
    if same(f.depth) { f.depth = .none }
    if same(f.stencil) { f.stencil = .none }
    attachmentSerial &+= 1
  }

  func setAttachment(_ attachment: GLenum, _ value: FramebufferAttachment) {
    guard let f = framebuffer else { return fail(.invalidOperation) }
    switch attachment {
    case GL_COLOR_ATTACHMENT0: f.color = value
    case GL_DEPTH_ATTACHMENT: f.depth = value
    case GL_STENCIL_ATTACHMENT: f.stencil = value
    default: return fail(.invalidEnum)
    }
    attachmentSerial &+= 1
  }

  func framebufferRenderbuffer(_ target: GLenum, _ attachment: GLenum, _ rbTarget: GLenum, _ name: GLuint) {
    guard target == GL_FRAMEBUFFER else { return fail(.invalidEnum) }
    guard name == 0 || rbTarget == GL_RENDERBUFFER else { return fail(.invalidEnum) }
    if name == 0 { return setAttachment(attachment, .none) }
    guard let r = share.renderbuffers[name] else { return fail(.invalidOperation) }
    setAttachment(attachment, .renderbuffer(r))
  }

  func framebufferTexture2D(_ target: GLenum, _ attachment: GLenum, _ texTarget: GLenum, _ name: GLuint, _ level: GLint) {
    guard target == GL_FRAMEBUFFER else { return fail(.invalidEnum) }
    if name == 0 { return setAttachment(attachment, .none) }
    let face: Int
    switch texTarget {
    case GL_TEXTURE_2D: face = 0
    case GL_TEXTURE_CUBE_MAP_POSITIVE_X...GL_TEXTURE_CUBE_MAP_NEGATIVE_Z: face = Int(texTarget - GL_TEXTURE_CUBE_MAP_POSITIVE_X)
    default: return fail(.invalidEnum)
    }
    guard level >= 0, level < 16 else { return fail(.invalidValue) }
    guard let t = share.textures[name] else { return fail(.invalidOperation) }
    let cube = texTarget != GL_TEXTURE_2D
    guard t.target == (cube ? GL_TEXTURE_CUBE_MAP : GL_TEXTURE_2D) else { return fail(.invalidOperation) }
    setAttachment(attachment, .texture(t, level: Int(level), face: face))
  }

  /// An attachment's image view and storage, or nil where it has none.
  func attachmentView(_ a: FramebufferAttachment) -> (view: ImageView, kind: StorageKind, width: Int32, height: Int32,
                                                      internalFormat: GLenum)? {
    switch a {
    case .none: return nil
    case .renderbuffer(let r):
      guard let image = r.image else { return nil }
      return (ImageView(image), r.kind, r.width, r.height, r.internalFormat)
    case .texture(let t, let level, let face):
      guard let image = t.image, let lv = t.level(face: face, level), level < Int(image.mipLevels) else { return nil }
      let e = image.descriptor.mipExtent(UInt32(level))
      guard e.width == lv.width, e.height == lv.height else { return nil }
      let view = ImageView(image, dimension: .d2, baseMip: UInt32(level), mipCount: 1, baseLayer: UInt32(face), layerCount: 1)
      return (view, t.kind, lv.width, lv.height, lv.internalFormat)
    }
  }

  /// GL ES 2.0's framebuffer completeness (section 4.4.5) of the bound framebuffer, and its target where complete.
  func framebufferStatus() -> (GLenum, RenderTarget?) {
    guard let f = framebuffer else {
      guard let s = surface else { return (GL_FRAMEBUFFER_UNSUPPORTED, nil) }
      return (GL_FRAMEBUFFER_COMPLETE, s.target)
    }
    var t = RenderTarget()
    var size: (Int32, Int32)? = nil
    var any = false
    func check(_ s: (Int32, Int32)) -> Bool {
      if let size { return size == s }
      size = s
      return true
    }
    if !f.color.isNone {
      guard let c = attachmentView(f.color), case .color(let alpha) = c.kind, c.width > 0, c.height > 0 else {
        return (GL_FRAMEBUFFER_INCOMPLETE_ATTACHMENT, nil)
      }
      guard check((c.width, c.height)) else { return (GL_FRAMEBUFFER_INCOMPLETE_DIMENSIONS, nil) }
      t.color = c.view
      t.colorFormat = c.view.format
      t.colorAlpha = alpha
      (t.redBits, t.greenBits, t.blueBits, t.alphaBits) = colorBits(c.internalFormat, alpha: alpha)
      any = true
    }
    var depthView: ImageView?
    if !f.depth.isNone {
      guard let d = attachmentView(f.depth), d.width > 0 else { return (GL_FRAMEBUFFER_INCOMPLETE_ATTACHMENT, nil) }
      switch d.kind {
      case .depth, .depthStencil: break
      default: return (GL_FRAMEBUFFER_INCOMPLETE_ATTACHMENT, nil)
      }
      guard check((d.width, d.height)) else { return (GL_FRAMEBUFFER_INCOMPLETE_DIMENSIONS, nil) }
      depthView = d.view
      t.hasDepth = true
      if case .texture = f.depth { t.depthSampled = true }
      t.depthBits = d.kind.pixelFormat == .depth16 ? 16 : 24
      if case .depthStencil = d.kind, f.stencil.isNone { t.hasStencil = false }
      any = true
    }
    if !f.stencil.isNone {
      guard let s = attachmentView(f.stencil), s.width > 0 else { return (GL_FRAMEBUFFER_INCOMPLETE_ATTACHMENT, nil) }
      switch s.kind {
      case .stencil, .depthStencil: break
      default: return (GL_FRAMEBUFFER_INCOMPLETE_ATTACHMENT, nil)
      }
      guard check((s.width, s.height)) else { return (GL_FRAMEBUFFER_INCOMPLETE_DIMENSIONS, nil) }
      // The core has one depth and stencil attachment: both must be one image's.
      if let d = depthView, d.image != s.view.image { return (GL_FRAMEBUFFER_UNSUPPORTED, nil) }
      depthView = s.view
      t.hasStencil = true
      if case .texture = f.stencil { t.depthSampled = true }
      t.stencilBits = 8
      any = true
    }
    guard any, let (w, h) = size else { return (GL_FRAMEBUFFER_INCOMPLETE_MISSING_ATTACHMENT, nil) }
    if let d = depthView {
      t.depthStencil = ImageView(d.image, dimension: .d2, baseMip: d.baseMip, mipCount: 1, baseLayer: d.baseLayer, layerCount: 1)
      t.depthStencilFormat = d.image.format
    }
    t.width = w
    t.height = h
    if t.color == nil {
      (t.redBits, t.greenBits, t.blueBits, t.alphaBits) = (0, 0, 0, 0)
      // A pass with no colour attachment draws into a scratch image no one reads (the Mali backend's passes have one).
      if let image = try? frame.scratchColor(width: w, height: h) { t.scratch = ImageView(image) }
    }
    return (GL_FRAMEBUFFER_COMPLETE, t)
  }

  /// The bits GL reports of a colour format (the storage is rgba8 whatever it is).
  func colorBits(_ f: GLenum, alpha: Bool) -> (GLint, GLint, GLint, GLint) {
    switch f {
    case GL_RGBA4: (4, 4, 4, 4)
    case GL_RGB5_A1: (5, 5, 5, 1)
    case GL_RGB565: (5, 6, 5, 0)
    default: (8, 8, 8, alpha ? 8 : 0)
    }
  }

  /// The bound framebuffer's target, or nil (and INVALID_FRAMEBUFFER_OPERATION recorded) where it is incomplete.
  func currentTarget() -> RenderTarget? {
    let name = framebuffer?.name ?? 0
    let surfaceSerial = surface?.serial ?? 0
    if let c = targetCache, c.framebuffer == name, c.serial == attachmentSerial, c.surface == surfaceSerial { return c.0 }
    let (status, target) = framebufferStatus()
    guard status == GL_FRAMEBUFFER_COMPLETE, var target else {
      fail(.invalidFramebufferOperation)
      return nil
    }
    targetIDs &+= 1
    target.id = targetIDs
    targetCache = (target, name, attachmentSerial, surfaceSerial)
    return target
  }
}
