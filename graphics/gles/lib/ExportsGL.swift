// SPDX-License-Identifier: BSD-3-Clause

// GL's C entry points (gles(3)): each `gles_gl*` the C names in libGLESv2.so call (c/libGLESv2.c), on the current
// context. With no context current a call does nothing, and a query returns 0.

import GPUCore

/// The context GL calls go to: the process's, which eglMakeCurrent sets.
public nonisolated(unsafe) var currentContext: GLContext?

@inline(__always) func gl() -> GLContext? { unsafe currentContext }

/// Writes `text` into a client's buffer of `size` bytes as GL's info calls do: as much as fits, NUL-terminated, and its
/// length without the NUL in `length`.
func copyOut(_ text: String, _ size: GLsizei, _ length: UnsafeMutablePointer<GLsizei>?, _ out: UnsafeMutablePointer<GLchar>?) {
  let bytes = Array(text.utf8)
  guard size > 0, let out = unsafe out else {
    unsafe length?.pointee = 0
    return
  }
  let n = min(bytes.count, Int(size) - 1)
  for i in 0..<n { unsafe out[i] = GLchar(bitPattern: bytes[i]) }
  unsafe out[n] = 0
  unsafe length?.pointee = GLsizei(n)
}

func cString(_ p: UnsafePointer<GLchar>?) -> String? {
  guard let p = unsafe p else { return nil }
  var bytes: [UInt8] = []
  var i = 0
  while unsafe p[i] != 0 {
    bytes.append(UInt8(bitPattern: unsafe p[i]))
    i += 1
  }
  return String(decoding: bytes, as: UTF8.self)
}

/// GetString's strings, made once each: GL gives the client a pointer that stays valid.
nonisolated(unsafe) var stringCache: [GLenum: UnsafeMutablePointer<GLubyte>] = unsafe [:]

// MARK: State

@c(gles_glActiveTexture) public func gles_glActiveTexture(_ texture: GLenum) { gl()?.setActiveTexture(texture) }
@c(gles_glBlendColor) public func gles_glBlendColor(_ r: GLfloat, _ g: GLfloat, _ b: GLfloat, _ a: GLfloat) {
  gl()?.blendColor = (min(max(r, 0), 1), min(max(g, 0), 1), min(max(b, 0), 1), min(max(a, 0), 1))
}
@c(gles_glBlendEquation) public func gles_glBlendEquation(_ mode: GLenum) { gl()?.blendEquationSeparate(mode, mode) }
@c(gles_glBlendEquationSeparate) public func gles_glBlendEquationSeparate(_ rgb: GLenum, _ alpha: GLenum) {
  gl()?.blendEquationSeparate(rgb, alpha)
}
@c(gles_glBlendFunc) public func gles_glBlendFunc(_ s: GLenum, _ d: GLenum) { gl()?.blendFuncSeparate(s, d, s, d) }
@c(gles_glBlendFuncSeparate) public func gles_glBlendFuncSeparate(_ sRGB: GLenum, _ dRGB: GLenum, _ sA: GLenum, _ dA: GLenum) {
  gl()?.blendFuncSeparate(sRGB, dRGB, sA, dA)
}
@c(gles_glClearColor) public func gles_glClearColor(_ r: GLfloat, _ g: GLfloat, _ b: GLfloat, _ a: GLfloat) {
  gl()?.clearColor = (r, g, b, a)
}
@c(gles_glClearDepthf) public func gles_glClearDepthf(_ d: GLfloat) { gl()?.clearDepth = min(max(d, 0), 1) }
@c(gles_glClearStencil) public func gles_glClearStencil(_ s: GLint) { gl()?.clearStencil = s }
@c(gles_glColorMask) public func gles_glColorMask(_ r: GLboolean, _ g: GLboolean, _ b: GLboolean, _ a: GLboolean) {
  gl()?.setColorMask(r.isTrue, g.isTrue, b.isTrue, a.isTrue)
}
@c(gles_glCullFace) public func gles_glCullFace(_ mode: GLenum) { gl()?.setCullFace(mode) }
@c(gles_glDepthFunc) public func gles_glDepthFunc(_ f: GLenum) { gl()?.setDepthFunc(f) }
@c(gles_glDepthMask) public func gles_glDepthMask(_ flag: GLboolean) { gl()?.setDepthMask(flag.isTrue) }
@c(gles_glDepthRangef) public func gles_glDepthRangef(_ n: GLfloat, _ f: GLfloat) {
  gl()?.depthRange = (min(max(n, 0), 1), min(max(f, 0), 1))
}
@c(gles_glDisable) public func gles_glDisable(_ cap: GLenum) { gl()?.setEnabled(cap, false) }
@c(gles_glEnable) public func gles_glEnable(_ cap: GLenum) { gl()?.setEnabled(cap, true) }
@c(gles_glFrontFace) public func gles_glFrontFace(_ mode: GLenum) { gl()?.setFrontFace(mode) }
@c(gles_glHint) public func gles_glHint(_ target: GLenum, _ mode: GLenum) { gl()?.hint(target, mode) }
@c(gles_glLineWidth) public func gles_glLineWidth(_ w: GLfloat) { gl()?.setLineWidth(w) }
@c(gles_glPixelStorei) public func gles_glPixelStorei(_ pname: GLenum, _ param: GLint) { gl()?.pixelStore(pname, param) }
@c(gles_glPolygonOffset) public func gles_glPolygonOffset(_ factor: GLfloat, _ units: GLfloat) {
  gl()?.polygonOffset = (factor, units)
}
@c(gles_glSampleCoverage) public func gles_glSampleCoverage(_ value: GLfloat, _ invert: GLboolean) {
  gl()?.setSampleCoverage(value, invert.isTrue)
}
@c(gles_glScissor) public func gles_glScissor(_ x: GLint, _ y: GLint, _ w: GLsizei, _ h: GLsizei) { gl()?.setScissor(x, y, w, h) }
@c(gles_glStencilFunc) public func gles_glStencilFunc(_ f: GLenum, _ ref: GLint, _ mask: GLuint) {
  gl()?.stencilFunc(GL_FRONT_AND_BACK, f, ref, mask)
}
@c(gles_glStencilFuncSeparate) public func gles_glStencilFuncSeparate(_ face: GLenum, _ f: GLenum, _ ref: GLint, _ mask: GLuint) {
  gl()?.stencilFunc(face, f, ref, mask)
}
@c(gles_glStencilMask) public func gles_glStencilMask(_ mask: GLuint) { gl()?.stencilMask(GL_FRONT_AND_BACK, mask) }
@c(gles_glStencilMaskSeparate) public func gles_glStencilMaskSeparate(_ face: GLenum, _ mask: GLuint) { gl()?.stencilMask(face, mask) }
@c(gles_glStencilOp) public func gles_glStencilOp(_ f: GLenum, _ zf: GLenum, _ zp: GLenum) {
  gl()?.stencilOp(GL_FRONT_AND_BACK, f, zf, zp)
}
@c(gles_glStencilOpSeparate) public func gles_glStencilOpSeparate(_ face: GLenum, _ f: GLenum, _ zf: GLenum, _ zp: GLenum) {
  gl()?.stencilOp(face, f, zf, zp)
}
@c(gles_glViewport) public func gles_glViewport(_ x: GLint, _ y: GLint, _ w: GLsizei, _ h: GLsizei) { gl()?.setViewport(x, y, w, h) }

// MARK: Buffers

@c(gles_glGenBuffers) public func gles_glGenBuffers(_ n: GLsizei, _ out: UnsafeMutablePointer<GLuint>?) {
  guard let c = gl() else { return }
  unsafe c.genNames(n, out) { c.share.buffers.generate() }
}
@c(gles_glDeleteBuffers) public func gles_glDeleteBuffers(_ n: GLsizei, _ names: UnsafePointer<GLuint>?) {
  unsafe gl()?.deleteBuffers(n, names)
}
@c(gles_glBindBuffer) public func gles_glBindBuffer(_ target: GLenum, _ name: GLuint) { gl()?.bindBuffer(target, name) }
@c(gles_glBufferData) public func gles_glBufferData(_ target: GLenum, _ size: GLsizeiptr, _ data: UnsafeRawPointer?, _ usage: GLenum) {
  unsafe gl()?.bufferData(target, size, data, usage)
}
@c(gles_glBufferSubData) public func gles_glBufferSubData(_ target: GLenum, _ offset: GLintptr, _ size: GLsizeiptr,
                                                          _ data: UnsafeRawPointer?) {
  unsafe gl()?.bufferSubData(target, offset, size, data)
}
@c(gles_glIsBuffer) public func gles_glIsBuffer(_ name: GLuint) -> GLboolean { (gl()?.share.buffers[name] != nil).gl }
@c(gles_glGetBufferParameteriv) public func gles_glGetBufferParameteriv(_ target: GLenum, _ pname: GLenum,
                                                                        _ params: UnsafeMutablePointer<GLint>?) {
  if let v = gl()?.bufferParameter(target, pname) { unsafe params?.pointee = v }
}
@c(gles_glMapBufferOES) public func gles_glMapBufferOES(_ target: GLenum, _ access: GLenum) -> UnsafeMutableRawPointer? {
  unsafe gl()?.mapBuffer(target, access)
}
@c(gles_glUnmapBufferOES) public func gles_glUnmapBufferOES(_ target: GLenum) -> GLboolean { (gl()?.unmapBuffer(target) ?? false).gl }
@c(gles_glGetBufferPointervOES) public func gles_glGetBufferPointervOES(_ target: GLenum, _ pname: GLenum,
                                                                        _ params: UnsafeMutablePointer<UnsafeMutableRawPointer?>?) {
  guard let c = gl() else { return }
  guard pname == GL_BUFFER_MAP_POINTER_OES else { return c.fail(.invalidEnum) }
  guard let bound = c.bufferTarget(target) else { return c.fail(.invalidEnum) }
  guard let b = bound else { return c.fail(.invalidOperation) }
  unsafe params?.pointee = b.mapped ? b.bytes : nil
}

// MARK: Vertex attributes and arrays

@c(gles_glVertexAttribPointer) public func gles_glVertexAttribPointer(_ index: GLuint, _ size: GLint, _ type: GLenum,
                                                                      _ normalized: GLboolean, _ stride: GLsizei,
                                                                      _ pointer: UnsafeRawPointer?) {
  unsafe gl()?.vertexAttribPointer(index, size, type, normalized.isTrue, stride, pointer)
}
@c(gles_glEnableVertexAttribArray) public func gles_glEnableVertexAttribArray(_ index: GLuint) { gl()?.enableAttribute(index, true) }
@c(gles_glDisableVertexAttribArray) public func gles_glDisableVertexAttribArray(_ index: GLuint) { gl()?.enableAttribute(index, false) }
@c(gles_glVertexAttrib1f) public func gles_glVertexAttrib1f(_ i: GLuint, _ x: GLfloat) { gl()?.vertexAttrib(i, x, 0, 0, 1) }
@c(gles_glVertexAttrib2f) public func gles_glVertexAttrib2f(_ i: GLuint, _ x: GLfloat, _ y: GLfloat) { gl()?.vertexAttrib(i, x, y, 0, 1) }
@c(gles_glVertexAttrib3f) public func gles_glVertexAttrib3f(_ i: GLuint, _ x: GLfloat, _ y: GLfloat, _ z: GLfloat) {
  gl()?.vertexAttrib(i, x, y, z, 1)
}
@c(gles_glVertexAttrib4f) public func gles_glVertexAttrib4f(_ i: GLuint, _ x: GLfloat, _ y: GLfloat, _ z: GLfloat, _ w: GLfloat) {
  gl()?.vertexAttrib(i, x, y, z, w)
}
@c(gles_glVertexAttrib1fv) public func gles_glVertexAttrib1fv(_ i: GLuint, _ v: UnsafePointer<GLfloat>?) {
  guard let v = unsafe v else { return }
  unsafe gl()?.vertexAttrib(i, v[0], 0, 0, 1)
}
@c(gles_glVertexAttrib2fv) public func gles_glVertexAttrib2fv(_ i: GLuint, _ v: UnsafePointer<GLfloat>?) {
  guard let v = unsafe v else { return }
  unsafe gl()?.vertexAttrib(i, v[0], v[1], 0, 1)
}
@c(gles_glVertexAttrib3fv) public func gles_glVertexAttrib3fv(_ i: GLuint, _ v: UnsafePointer<GLfloat>?) {
  guard let v = unsafe v else { return }
  unsafe gl()?.vertexAttrib(i, v[0], v[1], v[2], 1)
}
@c(gles_glVertexAttrib4fv) public func gles_glVertexAttrib4fv(_ i: GLuint, _ v: UnsafePointer<GLfloat>?) {
  guard let v = unsafe v else { return }
  unsafe gl()?.vertexAttrib(i, v[0], v[1], v[2], v[3])
}
@c(gles_glGetVertexAttribfv) public func gles_glGetVertexAttribfv(_ i: GLuint, _ pname: GLenum, _ params: UnsafeMutablePointer<GLfloat>?) {
  guard let v = gl()?.vertexAttribState(i, pname), let params = unsafe params else { return }
  for (k, x) in v.enumerated() { unsafe params[k] = x }
}
@c(gles_glGetVertexAttribiv) public func gles_glGetVertexAttribiv(_ i: GLuint, _ pname: GLenum, _ params: UnsafeMutablePointer<GLint>?) {
  guard let v = gl()?.vertexAttribState(i, pname), let params = unsafe params else { return }
  for (k, x) in v.enumerated() { unsafe params[k] = pname == GL_CURRENT_VERTEX_ATTRIB ? GLint(x.rounded()) : GLint(x) }
}
@c(gles_glGetVertexAttribPointerv) public func gles_glGetVertexAttribPointerv(_ i: GLuint, _ pname: GLenum,
                                                                              _ out: UnsafeMutablePointer<UnsafeMutableRawPointer?>?) {
  guard let c = gl() else { return }
  guard i < GLuint(maxVertexAttribs) else { return c.fail(.invalidValue) }
  guard pname == GL_VERTEX_ATTRIB_ARRAY_POINTER else { return c.fail(.invalidEnum) }
  unsafe out?.pointee = UnsafeMutableRawPointer(bitPattern: c.vertexArray.attributes[Int(i)].pointer)
}
@c(gles_glGenVertexArraysOES) public func gles_glGenVertexArraysOES(_ n: GLsizei, _ out: UnsafeMutablePointer<GLuint>?) {
  guard let c = gl() else { return }
  unsafe c.genNames(n, out) { c.vertexArrays.generate() }
}
@c(gles_glDeleteVertexArraysOES) public func gles_glDeleteVertexArraysOES(_ n: GLsizei, _ names: UnsafePointer<GLuint>?) {
  unsafe gl()?.deleteVertexArrays(n, names)
}
@c(gles_glBindVertexArrayOES) public func gles_glBindVertexArrayOES(_ name: GLuint) { gl()?.bindVertexArray(name) }
@c(gles_glIsVertexArrayOES) public func gles_glIsVertexArrayOES(_ name: GLuint) -> GLboolean { (gl()?.vertexArrays[name] != nil).gl }

// MARK: Textures

@c(gles_glGenTextures) public func gles_glGenTextures(_ n: GLsizei, _ out: UnsafeMutablePointer<GLuint>?) {
  guard let c = gl() else { return }
  unsafe c.genNames(n, out) { c.share.textures.generate() }
}
@c(gles_glDeleteTextures) public func gles_glDeleteTextures(_ n: GLsizei, _ names: UnsafePointer<GLuint>?) {
  unsafe gl()?.deleteTextures(n, names)
}
@c(gles_glBindTexture) public func gles_glBindTexture(_ target: GLenum, _ name: GLuint) { gl()?.bindTexture(target, name) }
@c(gles_glIsTexture) public func gles_glIsTexture(_ name: GLuint) -> GLboolean {
  guard let t = gl()?.share.textures[name] else { return 0 }
  return (t.target != 0).gl
}
@c(gles_glTexParameterf) public func gles_glTexParameterf(_ target: GLenum, _ pname: GLenum, _ param: GLfloat) {
  gl()?.texParameter(target, pname, int: nil, float: param)
}
@c(gles_glTexParameteri) public func gles_glTexParameteri(_ target: GLenum, _ pname: GLenum, _ param: GLint) {
  gl()?.texParameter(target, pname, int: param, float: nil)
}
@c(gles_glTexParameterfv) public func gles_glTexParameterfv(_ target: GLenum, _ pname: GLenum, _ params: UnsafePointer<GLfloat>?) {
  guard let p = unsafe params else { return }
  unsafe gl()?.texParameter(target, pname, int: nil, float: p.pointee)
}
@c(gles_glTexParameteriv) public func gles_glTexParameteriv(_ target: GLenum, _ pname: GLenum, _ params: UnsafePointer<GLint>?) {
  guard let p = unsafe params else { return }
  unsafe gl()?.texParameter(target, pname, int: p.pointee, float: nil)
}
@c(gles_glGetTexParameterfv) public func gles_glGetTexParameterfv(_ target: GLenum, _ pname: GLenum, _ params: UnsafeMutablePointer<GLfloat>?) {
  if let v = gl()?.texParameterValue(target, pname) { unsafe params?.pointee = v }
}
@c(gles_glGetTexParameteriv) public func gles_glGetTexParameteriv(_ target: GLenum, _ pname: GLenum, _ params: UnsafeMutablePointer<GLint>?) {
  if let v = gl()?.texParameterValue(target, pname) { unsafe params?.pointee = GLint(v) }
}
@c(gles_glTexImage2D) public func gles_glTexImage2D(_ target: GLenum, _ level: GLint, _ internalFormat: GLint, _ width: GLsizei,
                                                    _ height: GLsizei, _ border: GLint, _ format: GLenum, _ type: GLenum,
                                                    _ pixels: UnsafeRawPointer?) {
  unsafe gl()?.texImage2D(target, level, internalFormat, width, height, border, format, type, pixels)
}
@c(gles_glTexSubImage2D) public func gles_glTexSubImage2D(_ target: GLenum, _ level: GLint, _ x: GLint, _ y: GLint, _ width: GLsizei,
                                                          _ height: GLsizei, _ format: GLenum, _ type: GLenum,
                                                          _ pixels: UnsafeRawPointer?) {
  unsafe gl()?.texSubImage2D(target, level, x, y, width, height, format, type, pixels)
}
@c(gles_glCopyTexImage2D) public func gles_glCopyTexImage2D(_ target: GLenum, _ level: GLint, _ internalFormat: GLenum, _ x: GLint,
                                                            _ y: GLint, _ width: GLsizei, _ height: GLsizei, _ border: GLint) {
  gl()?.copyTexImage2D(target, level, internalFormat, x, y, width, height, border)
}
@c(gles_glCopyTexSubImage2D) public func gles_glCopyTexSubImage2D(_ target: GLenum, _ level: GLint, _ xo: GLint, _ yo: GLint,
                                                                  _ x: GLint, _ y: GLint, _ width: GLsizei, _ height: GLsizei) {
  gl()?.copyTexSubImage2D(target, level, xo, yo, x, y, width, height)
}
@c(gles_glCompressedTexImage2D) public func gles_glCompressedTexImage2D(_ target: GLenum, _ level: GLint, _ internalFormat: GLenum,
                                                                        _ width: GLsizei, _ height: GLsizei, _ border: GLint,
                                                                        _ imageSize: GLsizei, _ data: UnsafeRawPointer?) {
  // No compressed formats are listed (GL_NUM_COMPRESSED_TEXTURE_FORMATS is 0).
  gl()?.fail(.invalidEnum)
}
@c(gles_glCompressedTexSubImage2D) public func gles_glCompressedTexSubImage2D(_ target: GLenum, _ level: GLint, _ x: GLint, _ y: GLint,
                                                                              _ width: GLsizei, _ height: GLsizei, _ format: GLenum,
                                                                              _ imageSize: GLsizei, _ data: UnsafeRawPointer?) {
  gl()?.fail(.invalidEnum)
}
@c(gles_glGenerateMipmap) public func gles_glGenerateMipmap(_ target: GLenum) { gl()?.generateMipmap(target) }

// MARK: Renderbuffers and framebuffers

@c(gles_glGenRenderbuffers) public func gles_glGenRenderbuffers(_ n: GLsizei, _ out: UnsafeMutablePointer<GLuint>?) {
  guard let c = gl() else { return }
  unsafe c.genNames(n, out) { c.share.renderbuffers.generate() }
}
@c(gles_glDeleteRenderbuffers) public func gles_glDeleteRenderbuffers(_ n: GLsizei, _ names: UnsafePointer<GLuint>?) {
  unsafe gl()?.deleteRenderbuffers(n, names)
}
@c(gles_glBindRenderbuffer) public func gles_glBindRenderbuffer(_ target: GLenum, _ name: GLuint) { gl()?.bindRenderbuffer(target, name) }
@c(gles_glIsRenderbuffer) public func gles_glIsRenderbuffer(_ name: GLuint) -> GLboolean { (gl()?.share.renderbuffers[name] != nil).gl }
@c(gles_glRenderbufferStorage) public func gles_glRenderbufferStorage(_ target: GLenum, _ format: GLenum, _ w: GLsizei, _ h: GLsizei) {
  gl()?.renderbufferStorage(target, format, w, h)
}
@c(gles_glGetRenderbufferParameteriv) public func gles_glGetRenderbufferParameteriv(_ target: GLenum, _ pname: GLenum,
                                                                                    _ params: UnsafeMutablePointer<GLint>?) {
  if let v = gl()?.renderbufferParameter(target, pname) { unsafe params?.pointee = v }
}
@c(gles_glGenFramebuffers) public func gles_glGenFramebuffers(_ n: GLsizei, _ out: UnsafeMutablePointer<GLuint>?) {
  guard let c = gl() else { return }
  unsafe c.genNames(n, out) { c.framebuffers.generate() }
}
@c(gles_glDeleteFramebuffers) public func gles_glDeleteFramebuffers(_ n: GLsizei, _ names: UnsafePointer<GLuint>?) {
  unsafe gl()?.deleteFramebuffers(n, names)
}
@c(gles_glBindFramebuffer) public func gles_glBindFramebuffer(_ target: GLenum, _ name: GLuint) { gl()?.bindFramebuffer(target, name) }
@c(gles_glIsFramebuffer) public func gles_glIsFramebuffer(_ name: GLuint) -> GLboolean { (gl()?.framebuffers[name] != nil).gl }
@c(gles_glCheckFramebufferStatus) public func gles_glCheckFramebufferStatus(_ target: GLenum) -> GLenum {
  gl()?.checkFramebufferStatus(target) ?? 0
}
@c(gles_glFramebufferRenderbuffer) public func gles_glFramebufferRenderbuffer(_ target: GLenum, _ attachment: GLenum,
                                                                              _ rbTarget: GLenum, _ name: GLuint) {
  gl()?.framebufferRenderbuffer(target, attachment, rbTarget, name)
}
@c(gles_glFramebufferTexture2D) public func gles_glFramebufferTexture2D(_ target: GLenum, _ attachment: GLenum, _ texTarget: GLenum,
                                                                        _ name: GLuint, _ level: GLint) {
  gl()?.framebufferTexture2D(target, attachment, texTarget, name, level)
}
@c(gles_glGetFramebufferAttachmentParameteriv) public func gles_glGetFramebufferAttachmentParameteriv(
  _ target: GLenum, _ attachment: GLenum, _ pname: GLenum, _ params: UnsafeMutablePointer<GLint>?
) {
  if let v = gl()?.attachmentParameter(target, attachment, pname) { unsafe params?.pointee = v }
}
@c(gles_glDiscardFramebufferEXT) public func gles_glDiscardFramebufferEXT(_ target: GLenum, _ count: GLsizei,
                                                                          _ attachments: UnsafePointer<GLenum>?) {
  guard let c = gl() else { return }
  guard target == GL_FRAMEBUFFER else { return c.fail(.invalidEnum) }
  guard count >= 0 else { return c.fail(.invalidValue) }
  guard let attachments = unsafe attachments else { return }
  var list: [GLenum] = []
  for i in 0..<Int(count) { list.append(unsafe attachments[i]) }
  c.discard(list)
}

// MARK: Shaders and programs

@c(gles_glCreateShader) public func gles_glCreateShader(_ type: GLenum) -> GLuint { gl()?.createShader(type) ?? 0 }
@c(gles_glDeleteShader) public func gles_glDeleteShader(_ name: GLuint) { gl()?.deleteShader(name) }
@c(gles_glShaderSource) public func gles_glShaderSource(_ name: GLuint, _ count: GLsizei,
                                                        _ strings: UnsafePointer<UnsafePointer<GLchar>?>?,
                                                        _ lengths: UnsafePointer<GLint>?) {
  unsafe gl()?.shaderSource(name, count, strings, lengths)
}
@c(gles_glCompileShader) public func gles_glCompileShader(_ name: GLuint) { gl()?.compileShader(name) }
@c(gles_glShaderBinary) public func gles_glShaderBinary(_ n: GLsizei, _ shaders: UnsafePointer<GLuint>?, _ format: GLenum,
                                                        _ binary: UnsafeRawPointer?, _ length: GLsizei) {
  unsafe gl()?.shaderBinary(n, shaders, format, binary, length)
}
@c(gles_glReleaseShaderCompiler) public func gles_glReleaseShaderCompiler() {}
@c(gles_glIsShader) public func gles_glIsShader(_ name: GLuint) -> GLboolean { (gl()?.shaderObject(name) != nil).gl }
@c(gles_glGetShaderiv) public func gles_glGetShaderiv(_ name: GLuint, _ pname: GLenum, _ params: UnsafeMutablePointer<GLint>?) {
  if let v = gl()?.shaderParameter(name, pname) { unsafe params?.pointee = v }
}
@c(gles_glGetShaderInfoLog) public func gles_glGetShaderInfoLog(_ name: GLuint, _ size: GLsizei, _ length: UnsafeMutablePointer<GLsizei>?,
                                                                _ out: UnsafeMutablePointer<GLchar>?) {
  guard let s = gl()?.shader(name) else { return }
  unsafe copyOut(s.log, size, length, out)
}
@c(gles_glGetShaderSource) public func gles_glGetShaderSource(_ name: GLuint, _ size: GLsizei, _ length: UnsafeMutablePointer<GLsizei>?,
                                                              _ out: UnsafeMutablePointer<GLchar>?) {
  guard let s = gl()?.shader(name) else { return }
  unsafe copyOut(String(decoding: s.source, as: UTF8.self), size, length, out)
}
@c(gles_glGetShaderPrecisionFormat) public func gles_glGetShaderPrecisionFormat(_ shaderType: GLenum, _ precision: GLenum,
                                                                                _ range: UnsafeMutablePointer<GLint>?,
                                                                                _ out: UnsafeMutablePointer<GLint>?) {
  guard let c = gl() else { return }
  guard shaderType == GL_VERTEX_SHADER || shaderType == GL_FRAGMENT_SHADER else { return c.fail(.invalidEnum) }
  // Every precision is 32-bit IEEE floats and 32-bit integers.
  switch precision {
  case GL_LOW_FLOAT, GL_MEDIUM_FLOAT, GL_HIGH_FLOAT:
    unsafe range?[0] = 127
    unsafe range?[1] = 127
    unsafe out?.pointee = 23
  case GL_LOW_INT, GL_MEDIUM_INT, GL_HIGH_INT:
    unsafe range?[0] = 31
    unsafe range?[1] = 30
    unsafe out?.pointee = 0
  default: c.fail(.invalidEnum)
  }
}
@c(gles_glCreateProgram) public func gles_glCreateProgram() -> GLuint { gl()?.createProgram() ?? 0 }
@c(gles_glDeleteProgram) public func gles_glDeleteProgram(_ name: GLuint) { gl()?.deleteProgram(name) }
@c(gles_glAttachShader) public func gles_glAttachShader(_ p: GLuint, _ s: GLuint) { gl()?.attachShader(p, s) }
@c(gles_glDetachShader) public func gles_glDetachShader(_ p: GLuint, _ s: GLuint) { gl()?.detachShader(p, s) }
@c(gles_glBindAttribLocation) public func gles_glBindAttribLocation(_ p: GLuint, _ index: GLuint, _ name: UnsafePointer<GLchar>?) {
  guard let n = unsafe cString(name) else { return }
  gl()?.bindAttribLocation(p, index, n)
}
@c(gles_glLinkProgram) public func gles_glLinkProgram(_ p: GLuint) { gl()?.linkProgram(p) }
@c(gles_glUseProgram) public func gles_glUseProgram(_ p: GLuint) { gl()?.useProgram(p) }
@c(gles_glValidateProgram) public func gles_glValidateProgram(_ p: GLuint) { gl()?.validateProgram(p) }
@c(gles_glIsProgram) public func gles_glIsProgram(_ name: GLuint) -> GLboolean { (gl()?.programObject(name) != nil).gl }
@c(gles_glGetProgramiv) public func gles_glGetProgramiv(_ p: GLuint, _ pname: GLenum, _ params: UnsafeMutablePointer<GLint>?) {
  if let v = gl()?.programParameter(p, pname) { unsafe params?.pointee = v }
}
@c(gles_glGetProgramInfoLog) public func gles_glGetProgramInfoLog(_ name: GLuint, _ size: GLsizei, _ length: UnsafeMutablePointer<GLsizei>?,
                                                                  _ out: UnsafeMutablePointer<GLchar>?) {
  guard let p = gl()?.program(name) else { return }
  unsafe copyOut(p.log, size, length, out)
}
@c(gles_glGetAttachedShaders) public func gles_glGetAttachedShaders(_ name: GLuint, _ maxCount: GLsizei,
                                                                    _ count: UnsafeMutablePointer<GLsizei>?,
                                                                    _ shaders: UnsafeMutablePointer<GLuint>?) {
  guard let c = gl() else { return }
  guard maxCount >= 0 else { return c.fail(.invalidValue) }
  guard let p = c.program(name) else { return }
  var n = 0
  for s in [p.vertexShader, p.fragmentShader] {
    guard let s, n < Int(maxCount) else { continue }
    unsafe shaders?[n] = s.name
    n += 1
  }
  unsafe count?.pointee = GLsizei(n)
}
@c(gles_glGetAttribLocation) public func gles_glGetAttribLocation(_ name: GLuint, _ attribute: UnsafePointer<GLchar>?) -> GLint {
  guard let c = gl(), let p = c.program(name) else { return -1 }
  guard p.linkStatus else {
    c.fail(.invalidOperation)
    return -1
  }
  guard let n = unsafe cString(attribute) else { return -1 }
  return p.interface.attributes.first { $0.name == n }.map { GLint($0.location) } ?? -1
}
@c(gles_glGetActiveAttrib) public func gles_glGetActiveAttrib(_ name: GLuint, _ index: GLuint, _ size: GLsizei,
                                                              _ length: UnsafeMutablePointer<GLsizei>?, _ arraySize: UnsafeMutablePointer<GLint>?,
                                                              _ type: UnsafeMutablePointer<GLenum>?, _ out: UnsafeMutablePointer<GLchar>?) {
  guard let c = gl(), let p = c.program(name) else { return }
  guard Int(index) < p.interface.attributes.count else { return c.fail(.invalidValue) }
  let a = p.interface.attributes[Int(index)]
  unsafe copyOut(a.name, size, length, out)
  unsafe arraySize?.pointee = GLint(a.arraySize)
  unsafe type?.pointee = a.type
}
@c(gles_glGetActiveUniform) public func gles_glGetActiveUniform(_ name: GLuint, _ index: GLuint, _ size: GLsizei,
                                                                _ length: UnsafeMutablePointer<GLsizei>?, _ arraySize: UnsafeMutablePointer<GLint>?,
                                                                _ type: UnsafeMutablePointer<GLenum>?, _ out: UnsafeMutablePointer<GLchar>?) {
  guard let c = gl(), let p = c.program(name) else { return }
  guard Int(index) < p.interface.uniforms.count else { return c.fail(.invalidValue) }
  let u = p.interface.uniforms[Int(index)]
  unsafe copyOut(u.name, size, length, out)
  unsafe arraySize?.pointee = GLint(u.arraySize)
  unsafe type?.pointee = u.type
}
@c(gles_glGetUniformLocation) public func gles_glGetUniformLocation(_ name: GLuint, _ uniform: UnsafePointer<GLchar>?) -> GLint {
  guard let c = gl(), let p = c.program(name) else { return -1 }
  guard p.linkStatus else {
    c.fail(.invalidOperation)
    return -1
  }
  guard let n = unsafe cString(uniform) else { return -1 }
  return p.uniformLocation(n)
}
@c(gles_glGetUniformfv) public func gles_glGetUniformfv(_ name: GLuint, _ location: GLint, _ params: UnsafeMutablePointer<GLfloat>?) {
  guard let v = gl()?.getUniform(name, location), let params = unsafe params else { return }
  for (i, x) in v.enumerated() { unsafe params[i] = x }
}
@c(gles_glGetUniformiv) public func gles_glGetUniformiv(_ name: GLuint, _ location: GLint, _ params: UnsafeMutablePointer<GLint>?) {
  guard let v = gl()?.getUniform(name, location), let params = unsafe params else { return }
  for (i, x) in v.enumerated() { unsafe params[i] = GLint(x) }
}

// MARK: Uniforms

func uniformValues<T>(_ values: T...) -> [T] { values }

@c(gles_glUniform1f) public func gles_glUniform1f(_ l: GLint, _ x: GLfloat) {
  var v = x
  unsafe gl()?.uniform(l, count: 1, components: 1, integers: false, &v)
}
@c(gles_glUniform2f) public func gles_glUniform2f(_ l: GLint, _ x: GLfloat, _ y: GLfloat) {
  let v = [x, y]
  unsafe v.withUnsafeBytes { unsafe gl()?.uniform(l, count: 1, components: 2, integers: false, $0.baseAddress) }
}
@c(gles_glUniform3f) public func gles_glUniform3f(_ l: GLint, _ x: GLfloat, _ y: GLfloat, _ z: GLfloat) {
  let v = [x, y, z]
  unsafe v.withUnsafeBytes { unsafe gl()?.uniform(l, count: 1, components: 3, integers: false, $0.baseAddress) }
}
@c(gles_glUniform4f) public func gles_glUniform4f(_ l: GLint, _ x: GLfloat, _ y: GLfloat, _ z: GLfloat, _ w: GLfloat) {
  let v = [x, y, z, w]
  unsafe v.withUnsafeBytes { unsafe gl()?.uniform(l, count: 1, components: 4, integers: false, $0.baseAddress) }
}
@c(gles_glUniform1i) public func gles_glUniform1i(_ l: GLint, _ x: GLint) {
  var v = x
  unsafe gl()?.uniform(l, count: 1, components: 1, integers: true, &v)
}
@c(gles_glUniform2i) public func gles_glUniform2i(_ l: GLint, _ x: GLint, _ y: GLint) {
  let v = [x, y]
  unsafe v.withUnsafeBytes { unsafe gl()?.uniform(l, count: 1, components: 2, integers: true, $0.baseAddress) }
}
@c(gles_glUniform3i) public func gles_glUniform3i(_ l: GLint, _ x: GLint, _ y: GLint, _ z: GLint) {
  let v = [x, y, z]
  unsafe v.withUnsafeBytes { unsafe gl()?.uniform(l, count: 1, components: 3, integers: true, $0.baseAddress) }
}
@c(gles_glUniform4i) public func gles_glUniform4i(_ l: GLint, _ x: GLint, _ y: GLint, _ z: GLint, _ w: GLint) {
  let v = [x, y, z, w]
  unsafe v.withUnsafeBytes { unsafe gl()?.uniform(l, count: 1, components: 4, integers: true, $0.baseAddress) }
}
@c(gles_glUniform1fv) public func gles_glUniform1fv(_ l: GLint, _ n: GLsizei, _ v: UnsafePointer<GLfloat>?) {
  unsafe gl()?.uniform(l, count: n, components: 1, integers: false, v)
}
@c(gles_glUniform2fv) public func gles_glUniform2fv(_ l: GLint, _ n: GLsizei, _ v: UnsafePointer<GLfloat>?) {
  unsafe gl()?.uniform(l, count: n, components: 2, integers: false, v)
}
@c(gles_glUniform3fv) public func gles_glUniform3fv(_ l: GLint, _ n: GLsizei, _ v: UnsafePointer<GLfloat>?) {
  unsafe gl()?.uniform(l, count: n, components: 3, integers: false, v)
}
@c(gles_glUniform4fv) public func gles_glUniform4fv(_ l: GLint, _ n: GLsizei, _ v: UnsafePointer<GLfloat>?) {
  unsafe gl()?.uniform(l, count: n, components: 4, integers: false, v)
}
@c(gles_glUniform1iv) public func gles_glUniform1iv(_ l: GLint, _ n: GLsizei, _ v: UnsafePointer<GLint>?) {
  unsafe gl()?.uniform(l, count: n, components: 1, integers: true, v)
}
@c(gles_glUniform2iv) public func gles_glUniform2iv(_ l: GLint, _ n: GLsizei, _ v: UnsafePointer<GLint>?) {
  unsafe gl()?.uniform(l, count: n, components: 2, integers: true, v)
}
@c(gles_glUniform3iv) public func gles_glUniform3iv(_ l: GLint, _ n: GLsizei, _ v: UnsafePointer<GLint>?) {
  unsafe gl()?.uniform(l, count: n, components: 3, integers: true, v)
}
@c(gles_glUniform4iv) public func gles_glUniform4iv(_ l: GLint, _ n: GLsizei, _ v: UnsafePointer<GLint>?) {
  unsafe gl()?.uniform(l, count: n, components: 4, integers: true, v)
}
@c(gles_glUniformMatrix2fv) public func gles_glUniformMatrix2fv(_ l: GLint, _ n: GLsizei, _ t: GLboolean, _ v: UnsafePointer<GLfloat>?) {
  unsafe gl()?.uniformMatrix(l, count: n, columns: 2, transpose: t.isTrue, v)
}
@c(gles_glUniformMatrix3fv) public func gles_glUniformMatrix3fv(_ l: GLint, _ n: GLsizei, _ t: GLboolean, _ v: UnsafePointer<GLfloat>?) {
  unsafe gl()?.uniformMatrix(l, count: n, columns: 3, transpose: t.isTrue, v)
}
@c(gles_glUniformMatrix4fv) public func gles_glUniformMatrix4fv(_ l: GLint, _ n: GLsizei, _ t: GLboolean, _ v: UnsafePointer<GLfloat>?) {
  unsafe gl()?.uniformMatrix(l, count: n, columns: 4, transpose: t.isTrue, v)
}

// MARK: Drawing

@c(gles_glClear) public func gles_glClear(_ mask: GLbitfield) { gl()?.clear(mask) }
@c(gles_glDrawArrays) public func gles_glDrawArrays(_ mode: GLenum, _ first: GLint, _ count: GLsizei) {
  gl()?.drawArrays(mode, first, count)
}
@c(gles_glDrawElements) public func gles_glDrawElements(_ mode: GLenum, _ count: GLsizei, _ type: GLenum, _ indices: UnsafeRawPointer?) {
  unsafe gl()?.drawElements(mode, count, type, indices)
}
@c(gles_glReadPixels) public func gles_glReadPixels(_ x: GLint, _ y: GLint, _ w: GLsizei, _ h: GLsizei, _ format: GLenum,
                                                    _ type: GLenum, _ pixels: UnsafeMutableRawPointer?) {
  unsafe gl()?.readPixels(x, y, w, h, format, type, pixels)
}
@c(gles_glFlush) public func gles_glFlush() { gl()?.flush() }
@c(gles_glFinish) public func gles_glFinish() { gl()?.finish() }

// MARK: Queries

@c(gles_glGetError) public func gles_glGetError() -> GLenum { gl()?.takeError() ?? GL_NO_ERROR }
@c(gles_glIsEnabled) public func gles_glIsEnabled(_ cap: GLenum) -> GLboolean {
  guard let c = gl() else { return 0 }
  guard let on = c.isEnabled(cap) else {
    c.fail(.invalidEnum)
    return 0
  }
  return on.gl
}
@c(gles_glGetBooleanv) public func gles_glGetBooleanv(_ pname: GLenum, _ data: UnsafeMutablePointer<GLboolean>?) {
  guard let v = gl()?.state(pname), let data = unsafe data else { return }
  for (i, b) in v.asBooleans.enumerated() { unsafe data[i] = b.gl }
}
@c(gles_glGetIntegerv) public func gles_glGetIntegerv(_ pname: GLenum, _ data: UnsafeMutablePointer<GLint>?) {
  guard let v = gl()?.state(pname), let data = unsafe data else { return }
  for (i, x) in v.asIntegers.enumerated() { unsafe data[i] = x }
}
@c(gles_glGetFloatv) public func gles_glGetFloatv(_ pname: GLenum, _ data: UnsafeMutablePointer<GLfloat>?) {
  guard let v = gl()?.state(pname), let data = unsafe data else { return }
  for (i, x) in v.asFloats.enumerated() { unsafe data[i] = x }
}
@c(gles_glGetString) public func gles_glGetString(_ name: GLenum) -> UnsafePointer<GLubyte>? {
  guard let c = gl() else { return nil }
  if let s = unsafe stringCache[name] { return unsafe UnsafePointer(s) }
  guard let text = c.string(name) else { return nil }
  let bytes = Array(text.utf8)
  let p = UnsafeMutablePointer<GLubyte>.allocate(capacity: bytes.count + 1)
  for (i, b) in bytes.enumerated() { unsafe p[i] = b }
  unsafe p[bytes.count] = 0
  unsafe stringCache[name] = p
  return unsafe UnsafePointer(p)
}
