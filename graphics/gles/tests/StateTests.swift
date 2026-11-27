// SPDX-License-Identifier: BSD-3-Clause

// The state machine through the C entry points: errors as the spec gives them, queries, clears as a pass's load,
// ReadPixels, and what a frame submits.

import GPUCore
import Testing

@testable import GLES

extension GLTests {
  @Test func errorsAreTheSpecs() {
    let h = Harness()
    gles_glEnable(0x1234)
    #expect(h.error() == GL_INVALID_ENUM)
    #expect(h.error() == GL_NO_ERROR)
    // The first error is kept until it is read.
    gles_glEnable(0x1234)
    gles_glLineWidth(-1)
    #expect(h.error() == GL_INVALID_ENUM)
    #expect(h.error() == GL_NO_ERROR)
    gles_glBindBuffer(GL_TEXTURE_2D, 1)
    #expect(h.error() == GL_INVALID_ENUM)
    gles_glBufferData(GL_ARRAY_BUFFER, 4, nil, GL_STATIC_DRAW)
    #expect(h.error() == GL_INVALID_OPERATION)
    gles_glDrawArrays(0x77, 0, 3)
    #expect(h.error() == GL_INVALID_ENUM)
    gles_glDrawArrays(GL_TRIANGLES, 0, -1)
    #expect(h.error() == GL_INVALID_VALUE)
    gles_glUniform1f(0, 1)
    #expect(h.error() == GL_INVALID_OPERATION)
    gles_glClear(0x8000_0000)
    #expect(h.error() == GL_INVALID_VALUE)
    var t: GLuint = 0
    gles_glGenTextures(1, &t)
    gles_glBindTexture(GL_TEXTURE_2D, t)
    // GL ES 2.0: the internal format is the format.
    gles_glTexImage2D(GL_TEXTURE_2D, 0, GLint(GL_RGBA), 1, 1, 0, GL_RGB, GL_UNSIGNED_BYTE, nil)
    #expect(h.error() == GL_INVALID_OPERATION)
    gles_glTexImage2D(GL_TEXTURE_2D, 0, GLint(GL_RGB), 1, 1, 0, GL_RGB, GL_UNSIGNED_SHORT_4_4_4_4, nil)
    #expect(h.error() == GL_INVALID_OPERATION)
    gles_glTexImage2D(GL_TEXTURE_2D, 0, GLint(GL_RGB), 1, 1, 1, GL_RGB, GL_UNSIGNED_BYTE, nil)
    #expect(h.error() == GL_INVALID_VALUE)
    gles_glBindTexture(GL_TEXTURE_CUBE_MAP, t)
    #expect(h.error() == GL_INVALID_OPERATION)
    gles_glPixelStorei(GL_UNPACK_ALIGNMENT, 3)
    #expect(h.error() == GL_INVALID_VALUE)
    var f: GLuint = 0
    gles_glGenFramebuffers(1, &f)
    gles_glBindFramebuffer(GL_FRAMEBUFFER, f)
    #expect(gles_glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_INCOMPLETE_MISSING_ATTACHMENT)
    gles_glClear(GL_COLOR_BUFFER_BIT)
    #expect(h.error() == GL_INVALID_FRAMEBUFFER_OPERATION)
    #expect(h.error() == GL_NO_ERROR)
  }

  @Test func queriesConvertAsTheSpecSays() {
    let h = Harness()
    var v = [GLint](repeating: 0, count: 4)
    gles_glGetIntegerv(GL_VIEWPORT, &v)
    #expect(v == [0, 0, 64, 64])
    gles_glClearColor(1, 0, 0.5, 1)
    gles_glGetIntegerv(GL_COLOR_CLEAR_VALUE, &v)
    #expect(v[0] == Int32.max && v[1] == 0 && v[3] == Int32.max)
    var f = [GLfloat](repeating: 0, count: 4)
    gles_glGetFloatv(GL_COLOR_CLEAR_VALUE, &f)
    #expect(f == [1, 0, 0.5, 1])
    var b = [GLboolean](repeating: 9, count: 4)
    gles_glGetBooleanv(GL_DEPTH_WRITEMASK, &b)
    #expect(b[0] == 1)
    gles_glGetIntegerv(GL_MAX_VERTEX_ATTRIBS, &v)
    #expect(v[0] == 8)
    gles_glGetIntegerv(GL_RED_BITS, &v)
    #expect(v[0] == 8)
    let ext = String(cString: gles_glGetString(GL_EXTENSIONS)!)
    #expect(ext.contains("GL_OES_mapbuffer") && ext.contains("GL_OES_depth_texture") && ext.contains("GL_OES_element_index_uint"))
    #expect(String(cString: gles_glGetString(GL_VERSION)!).hasPrefix("OpenGL ES 2.0"))
    #expect(gles_glGetString(0x1234) == nil)
    #expect(h.error() == GL_INVALID_ENUM)
    gles_glGetIntegerv(0x1234, &v)
    #expect(h.error() == GL_INVALID_ENUM)
    #expect(gles_glIsEnabled(GL_DITHER) == 1)
  }

  @Test func aClearIsThePassLoad() throws {
    let h = Harness()
    gles_glClearColor(1, 0, 0, 1)
    gles_glClear(GL_COLOR_BUFFER_BIT)
    gles_glFinish()
    let d = h.test
    #expect(d.submitted.count == 1)
    #expect(d.passes.count == 1)
    #expect(d.passes[0].colors[0].load == .clear(1, 0, 0, 1))
    #expect(h.read(10, 20) == [255, 0, 0, 255])
    // A clear of part of it (the scissor) is a clear in the pass.
    gles_glEnable(GL_SCISSOR_TEST)
    gles_glScissor(0, 0, 8, 8)
    gles_glClearColor(0, 1, 0, 1)
    gles_glClear(GL_COLOR_BUFFER_BIT)
    gles_glFinish()
    #expect(d.passes.count == 2)
    #expect(d.passes[1].colors[0].load == .load)
    #expect(h.read(1, 1) == [0, 255, 0, 255])
    #expect(h.read(20, 20) == [255, 0, 0, 255])
    #expect(h.error() == GL_NO_ERROR)
  }

  @Test func readPixelsOfAWindowIsFlipped() {
    let h = Harness(flipped: true)
    gles_glEnable(GL_SCISSOR_TEST)
    gles_glScissor(0, 0, 64, 4)
    gles_glClearColor(0.2, 0.4, 0.6, 1)
    gles_glClear(GL_COLOR_BUFFER_BIT)
    gles_glFinish()
    // GL's bottom rows are the window image's last ones.
    let r = h.read(0, 0)
    #expect(abs(Int(r[0]) - 51) <= 1 && abs(Int(r[1]) - 102) <= 1 && abs(Int(r[2]) - 153) <= 1 && r[3] == 255)
    #expect(h.read(0, 60) == [0, 0, 0, 0])
    let d = h.test
    let bottom = d.contents[h.surface.image.handle]![(63 * 64) * 4]
    #expect(abs(Int(bottom) - 51) <= 1)
  }

  @Test func aFrameIsOneSubmission() {
    let h = Harness(depth: .depth32f)
    let p = h.program("flat.vert", "flat.frag")
    #expect(h.linked(p), "\(h.log(p))")
    h.uniforms(p, color: [0, 0, 1, 1])
    h.fullTriangle()
    gles_glEnable(GL_DEPTH_TEST)
    for _ in 0..<3 {
      gles_glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT)
      gles_glDrawArrays(GL_TRIANGLES, 0, 3)
      gles_glDrawArrays(GL_TRIANGLES, 0, 3)
      gles_glFinish()
    }
    let d = h.test
    #expect(d.submitted.count == 3)
    #expect(d.passes.count == 3)
    #expect(d.draws.count == 6)
    #expect(d.passes[2].depthStencil?.depthLoad == .clear)
    #expect(h.gl.pipelinesMade == 1)
    #expect(h.error() == GL_NO_ERROR)
  }

  /// A pass whose draws don't test depth neither loads nor stores it; its clear is the next pass's that does.
  @Test func depthAPassDoesntUseIsntMoved() {
    let h = Harness(depth: .depth32f)
    let p = h.program("flat.vert", "flat.frag")
    h.uniforms(p, color: [0, 0, 1, 1])
    h.fullTriangle()
    var t: GLuint = 0, f: GLuint = 0
    gles_glGenTextures(1, &t)
    gles_glBindTexture(GL_TEXTURE_2D, t)
    gles_glTexImage2D(GL_TEXTURE_2D, 0, GLint(GL_RGBA), 16, 16, 0, GL_RGBA, GL_UNSIGNED_BYTE, nil)
    gles_glGenFramebuffers(1, &f)
    gles_glBindFramebuffer(GL_FRAMEBUFFER, f)
    gles_glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, t, 0)
    gles_glBindFramebuffer(GL_FRAMEBUFFER, 0)
    // Pass 1, 2D: depth cleared, never tested.
    gles_glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT)
    gles_glDrawArrays(GL_TRIANGLES, 0, 3)
    gles_glBindFramebuffer(GL_FRAMEBUFFER, f)
    gles_glDrawArrays(GL_TRIANGLES, 0, 3)
    gles_glBindFramebuffer(GL_FRAMEBUFFER, 0)
    // Pass 3: depth tested, so the first pass's clear is its load.
    gles_glEnable(GL_DEPTH_TEST)
    gles_glDrawArrays(GL_TRIANGLES, 0, 3)
    gles_glFinish()
    let d = h.test
    #expect(d.passes.count == 3)
    #expect(d.passes[0].depthStencil?.depthLoad == .dontCare && d.passes[0].depthStencil?.depthStore == .discard)
    #expect(d.passes[2].depthStencil?.depthLoad == .clear && d.passes[2].depthStencil?.depthStore == .store)
    #expect(d.passes[2].colors[0].load == .load)
  }

  @Test func aPassTakesEveryDraw() {
    let h = Harness()
    let p = h.program("flat.vert", "flat.frag")
    h.uniforms(p, color: [1, 1, 1, 1])
    h.fullTriangle()
    gles_glClear(GL_COLOR_BUFFER_BIT)
    for _ in 0..<40 { gles_glDrawArrays(GL_TRIANGLES, 0, 3) }
    gles_glFinish()
    let d = h.test
    #expect(d.passes.count == 1)
    #expect(d.passes[0].colors[0].load == .clear(0, 0, 0, 0))
    #expect(d.draws.count == 40)
  }

  @Test func pipelinesAreKeptByState() {
    let h = Harness()
    let p = h.program("flat.vert", "flat.frag")
    h.uniforms(p, color: [1, 1, 1, 1])
    h.fullTriangle()
    gles_glDrawArrays(GL_TRIANGLES, 0, 3)
    gles_glEnable(GL_BLEND)
    gles_glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
    gles_glDrawArrays(GL_TRIANGLES, 0, 3)
    gles_glDisable(GL_BLEND)
    gles_glDrawArrays(GL_TRIANGLES, 0, 3)
    gles_glEnable(GL_BLEND)
    gles_glDrawArrays(GL_TRIANGLES, 0, 3)
    // A colour or a viewport is the pass's, not the pipeline's.
    gles_glBlendColor(0.5, 0.5, 0.5, 0.5)
    gles_glViewport(0, 0, 8, 8)
    gles_glDrawArrays(GL_TRIANGLES, 0, 3)
    gles_glFinish()
    #expect(h.gl.pipelinesMade == 2)
    let d = h.test
    let blended = d.pipelines.values.first { $0.attachmentBlends?.first?.enabled == true }
    #expect(blended?.attachmentBlends?.first?.srcColor == .srcAlpha)
    #expect(blended?.attachmentBlends?.first?.dstColor == .oneMinusSrcAlpha)
    // GL's counter-clockwise front, drawn as the framebuffer is: the core's clockwise.
    #expect(blended?.rasterization.frontFace == .clockwise)
    #expect(d.commands.contains { if case .setViewports(_, let v) = $0 { v.first?.width == 8 } else { false } })
    #expect(d.commands.contains { if case .setBlendConstants(let k) = $0 { k.red == 0.5 } else { false } })
  }

  @Test func theRootBlockIsTheLowerings() {
    let h = Harness()
    let p = h.program("flat.vert", "flat.frag")
    h.uniforms(p, color: [0.25, 0.5, 0.75, 1])
    var b: GLuint = 0
    gles_glGenBuffers(1, &b)
    gles_glBindBuffer(GL_ARRAY_BUFFER, b)
    let vertices: [Float] = [0, 0, 0, 1, 1, 0, 0, 1, 0, 1, 0, 1]
    vertices.withUnsafeBytes { gles_glBufferData(GL_ARRAY_BUFFER, $0.count, $0.baseAddress, GL_STATIC_DRAW) }
    gles_glVertexAttribPointer(0, 4, GL_FLOAT, 0, 16, nil)
    gles_glEnableVertexAttribArray(0)
    gles_glDrawArrays(GL_TRIANGLES, 0, 3)
    gles_glFinish()
    let d = h.test
    #expect(d.draws.count == 1)
    let root = d.draws[0].root
    let set = load(root, 0, as: UInt64.self)
    #expect(set == root + 96)
    let vb = load(root, 32, as: UInt64.self)
    #expect(load(vb, 16, as: Float.self) == 1)
    let block = load(set, 0, as: UInt64.self)
    #expect(load(set, 8, as: UInt64.self) == 32)
    // transform at 0, color at 16.
    #expect(load(block, 0, as: Float.self) == 1)
    #expect(load(block, 16, as: Float.self) == 0.25)
    #expect(load(block, 24, as: Float.self) == 0.75)
    // The vertex stage was lowered against a float4 at location 0, 16 bytes apart.
    let program = h.gl.program!
    #expect(program.vertexBytes.count == 1)
    #expect(program.vertexBytes[0].layout == VertexLayout(formats: [3], strides: [16]))
  }

  @Test func clientArraysAreCopied() {
    let h = Harness()
    let p = h.program("shaded.vert", "shaded.frag")
    #expect(h.linked(p), "\(h.log(p))")
    gles_glUseProgram(p)
    let positions: [Float] = [9, 9, 9, 9, -1, -1, 0, 1, 1, -1, 0, 1, 0, 1, 0, 1]
    // Colours as normalized bytes, three of them: converted to floats.
    let colors: [UInt8] = [0, 0, 0, 0, 255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255]
    positions.withUnsafeBytes { pos in
      colors.withUnsafeBytes { col in
        gles_glVertexAttribPointer(0, 4, GL_FLOAT, 0, 0, pos.baseAddress)
        gles_glVertexAttribPointer(1, 3, GL_UNSIGNED_BYTE, 1, 4, col.baseAddress)
        gles_glEnableVertexAttribArray(0)
        gles_glEnableVertexAttribArray(1)
        gles_glDrawArrays(GL_TRIANGLES, 1, 3)
      }
    }
    gles_glFinish()
    let d = h.test
    let root = d.draws[0].root
    // The vertex buffers' addresses are of vertex 0: vertex 1 is the first copied.
    let pos = load(root, 32, as: UInt64.self)
    #expect(load(pos &+ 16, 0, as: Float.self) == -1)
    let col = load(root, 40, as: UInt64.self)
    #expect(load(col &+ 12, 0, as: Float.self) == 1)
    #expect(load(col &+ 24 + 4, 0, as: Float.self) == 1)
    #expect(h.gl.program!.vertexBytes[0].layout == VertexLayout(formats: [3, 2], strides: [16, 12]))
    #expect(h.error() == GL_NO_ERROR)
  }

  @Test func indicesOfBytesAreWidened() {
    let h = Harness()
    let p = h.program("flat.vert", "flat.frag")
    h.uniforms(p, color: [1, 1, 1, 1])
    h.fullTriangle()
    let indices: [UInt8] = [0, 1, 2]
    indices.withUnsafeBytes { gles_glDrawElements(GL_TRIANGLES, 3, GL_UNSIGNED_BYTE, $0.baseAddress) }
    var e: GLuint = 0
    gles_glGenBuffers(1, &e)
    gles_glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, e)
    let shorts: [UInt16] = [2, 1, 0]
    shorts.withUnsafeBytes { gles_glBufferData(GL_ELEMENT_ARRAY_BUFFER, $0.count, $0.baseAddress, GL_STATIC_DRAW) }
    gles_glDrawElements(GL_TRIANGLES, 3, GL_UNSIGNED_SHORT, nil)
    gles_glDrawArrays(GL_LINE_LOOP, 0, 3)
    gles_glFinish()
    let d = h.test
    #expect(d.draws.count == 3)
    #expect(d.draws.allSatisfy { $0.indexed })
    #expect(d.draws[2].count == 4)
    #expect(h.error() == GL_NO_ERROR)
  }

  @Test func mapBufferWritesThrough() {
    let h = Harness()
    let b = h.buffer([0, 0, 0, 0])
    let p = gles_glMapBufferOES(GL_ARRAY_BUFFER, GL_WRITE_ONLY_OES)!
    p.storeBytes(of: Float(7), toByteOffset: 4, as: Float.self)
    #expect(gles_glUnmapBufferOES(GL_ARRAY_BUFFER) == 1)
    #expect(gles_glUnmapBufferOES(GL_ARRAY_BUFFER) == 0)
    #expect(h.error() == GL_INVALID_OPERATION)
    let buffer = h.gl.share.buffers[b]!
    let m = try! h.gl.deviceCopy(buffer)!
    #expect(m.pointer!.load(fromByteOffset: 4, as: Float.self) == 7)
    var size: GLint = 0
    gles_glGetBufferParameteriv(GL_ARRAY_BUFFER, GL_BUFFER_SIZE, &size)
    #expect(size == 16)
  }

  @Test func aBufferTheGPUReadsMoves() {
    let h = Harness()
    let p = h.program("flat.vert", "flat.frag")
    h.uniforms(p, color: [1, 1, 1, 1])
    h.fullTriangle()
    gles_glDrawArrays(GL_TRIANGLES, 0, 3)
    let first = h.gl.arrayBuffer!.memory!
    let replace: [Float] = [5, 5, 5, 5]
    replace.withUnsafeBytes { gles_glBufferSubData(GL_ARRAY_BUFFER, 0, 16, $0.baseAddress) }
    gles_glDrawArrays(GL_TRIANGLES, 0, 3)
    gles_glFinish()
    let second = h.gl.arrayBuffer!.memory!
    // The open list read the first copy: the second draw reads another.
    #expect(first != second)
    #expect(first.pointer!.load(as: Float.self) == -1)
    #expect(second.pointer!.load(as: Float.self) == 5)
  }
}
