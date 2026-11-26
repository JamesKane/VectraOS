// SPDX-License-Identifier: BSD-3-Clause

// Programs: a binary's interface read as GL names it, std140 offsets, glUniform* into the block and back, the clip
// space made the core's, and the Mali backend (over the fake transport) taking the lowered stages: the real lowering
// and the Valhall compiler.

import GPUCore
import GPUCoreMali
import MaliFakeTransport
import Testing
import VulkanLowering

@testable import GLES

extension GLTests {
  @Test func aBinarysInterfaceIsReflected() throws {
    let i = try reflect(vertex: spirv("uniforms.vert"), fragment: spirv("uniforms.frag"))
    func u(_ name: String) -> ActiveUniform? { i.uniforms.first { $0.name == name } }
    #expect(u("f")?.offset == 0 && u("f")?.type == GL_FLOAT)
    #expect(u("v2")?.offset == 8 && u("v2")?.type == GL_FLOAT_VEC2)
    #expect(u("v3")?.offset == 16 && u("v3")?.type == GL_FLOAT_VEC3)
    #expect(u("i")?.offset == 28 && u("i")?.type == GL_INT)
    #expect(u("b")?.offset == 32 && u("b")?.type == GL_BOOL)
    #expect(u("weights[0]")?.offset == 48 && u("weights[0]")?.arraySize == 3 && u("weights[0]")?.arrayStride == 16)
    #expect(u("m3")?.offset == 96 && u("m3")?.matrixStride == 16 && u("m3")?.type == GL_FLOAT_MAT3)
    #expect(u("m4")?.offset == 144 && u("m4")?.type == GL_FLOAT_MAT4)
    #expect(u("light.position")?.offset == 208 && u("light.power")?.offset == 224)
    #expect(u("iv")?.offset == 240 && u("iv")?.type == GL_INT_VEC4)
    #expect(u("base")?.samplerBinding == 1 && u("detail")?.samplerBinding == 2 && u("base")?.type == GL_SAMPLER_2D)
    #expect(i.uniformBlockBytes == 256)
    #expect(i.attributes == [ActiveAttribute(name: "position", type: GL_FLOAT_VEC4, location: 0)])
  }

  @Test func uniformsWriteTheBlock() {
    let h = Harness()
    let p = h.program("uniforms.vert", "uniforms.frag")
    #expect(h.linked(p), "\(h.log(p))")
    gles_glUseProgram(p)
    let program = h.gl.program!
    func at(_ offset: Int) -> Float { program.block!.load(fromByteOffset: offset, as: Float.self) }
    func word(_ offset: Int) -> Int32 { program.block!.load(fromByteOffset: offset, as: Int32.self) }
    gles_glUniform1f(gles_glGetUniformLocation(p, "f"), 2.5)
    gles_glUniform3f(gles_glGetUniformLocation(p, "v3"), 1, 2, 3)
    gles_glUniform1i(gles_glGetUniformLocation(p, "i"), -7)
    gles_glUniform1f(gles_glGetUniformLocation(p, "b"), 3)
    let w: [Float] = [4, 5]
    gles_glUniform1fv(gles_glGetUniformLocation(p, "weights[1]"), 2, w)
    let m3: [Float] = [1, 2, 3, 4, 5, 6, 7, 8, 9]
    gles_glUniformMatrix3fv(gles_glGetUniformLocation(p, "m3"), 1, 0, m3)
    gles_glUniform1f(gles_glGetUniformLocation(p, "light.power"), 0.5)
    #expect(h.error() == GL_NO_ERROR)
    #expect(at(0) == 2.5)
    #expect(at(16) == 1 && at(20) == 2 && at(24) == 3)
    #expect(word(28) == -7)
    #expect(word(32) == 1)
    #expect(at(64) == 4 && at(80) == 5)
    // mat3's columns are 16 bytes apart.
    #expect(at(96) == 1 && at(112) == 4 && at(120) == 6 && at(128) == 7)
    #expect(at(224) == 0.5)
    // The wrong type, the wrong size, an array count for one value, a transposed matrix.
    gles_glUniform1i(gles_glGetUniformLocation(p, "f"), 1)
    #expect(h.error() == GL_INVALID_OPERATION)
    gles_glUniform2f(gles_glGetUniformLocation(p, "v3"), 1, 2)
    #expect(h.error() == GL_INVALID_OPERATION)
    gles_glUniform1fv(gles_glGetUniformLocation(p, "f"), 2, w)
    #expect(h.error() == GL_INVALID_OPERATION)
    gles_glUniformMatrix3fv(gles_glGetUniformLocation(p, "m3"), 1, 1, m3)
    #expect(h.error() == GL_INVALID_VALUE)
    // -1 is quietly nothing.
    gles_glUniform1f(-1, 1)
    #expect(h.error() == GL_NO_ERROR)
    #expect(gles_glGetUniformLocation(p, "weights[3]") == -1)
    #expect(gles_glGetUniformLocation(p, "nothing") == -1)
    var back = [Float](repeating: 0, count: 3)
    gles_glGetUniformfv(p, gles_glGetUniformLocation(p, "v3"), &back)
    #expect(back == [1, 2, 3])
    // Samplers are units.
    gles_glUniform1i(gles_glGetUniformLocation(p, "detail"), 3)
    #expect(program.samplerUnits == [0, 3])
    gles_glUniform1i(gles_glGetUniformLocation(p, "detail"), 99)
    #expect(h.error() == GL_INVALID_VALUE)
    var n: GLint = 0
    gles_glGetProgramiv(p, GL_ACTIVE_UNIFORMS, &n)
    #expect(n == 13)
    var name = [GLchar](repeating: 0, count: 64)
    var length: GLsizei = 0, size: GLint = 0
    var type: GLenum = 0
    for k in 0..<GLuint(n) {
      gles_glGetActiveUniform(p, k, 64, &length, &size, &type, &name)
      if String(cString: name) == "weights[0]" { #expect(size == 3 && type == GL_FLOAT) }
    }
    #expect(gles_glGetAttribLocation(p, "position") == 0)
  }

  @Test func clipSpaceIsTheCores() throws {
    let words = try coreClipSpace(spirv("flat.vert"))
    #expect(words.count > spirv("flat.vert").count)
    // The rewrite is SPIR-V the lowering takes, and the interface is unchanged.
    let i = try reflect(vertex: words, fragment: spirv("flat.frag"))
    #expect(i.attributes.count == 1)
    var layout = LoweringLayout(sets: [SetLayout(bindings: [DescriptorBinding(binding: 0, kind: .uniformBuffer)])])
    layout.vertexBindings = [VertexBinding(binding: 0, stride: 16)]
    layout.vertexAttributes = [VertexAttribute(location: 0, binding: 0, format: .rgba32Float, offset: 0)]
    _ = try lower(spirv: words, stage: .vertex, entryPoint: "main", layout: layout)
  }

  @Test func linkFailuresSay() {
    let h = Harness()
    let p = gles_glCreateProgram()
    gles_glLinkProgram(p)
    #expect(!h.linked(p))
    #expect(h.log(p).contains("vertex and a fragment"))
    gles_glUseProgram(p)
    #expect(h.error() == GL_INVALID_OPERATION)
    let s = gles_glCreateShader(GL_VERTEX_SHADER)
    gles_glCompileShader(s)
    var status: GLint = 9
    gles_glGetShaderiv(s, GL_COMPILE_STATUS, &status)
    // No front end on the host: GLSL doesn't compile, and says so.
    if unsafe shaderFrontEnd == nil { #expect(status == 0) }
    gles_glUseProgram(s)
    #expect(h.error() == GL_INVALID_OPERATION)
    gles_glUseProgram(9999)
    #expect(h.error() == GL_INVALID_VALUE)
  }

  /// A GLSL ES program, compiled and linked by the front end, its uniforms found by name, and drawn on the Mali backend.
  @Test func aGLSLProgramDraws() throws {
    let mali = try MaliDevice(transport: FakeTransport())
    let h = Harness(mali, depth: .depth32f, flipped: true)
    let vs = """
      attribute vec4 position;
      attribute vec2 texcoord;
      uniform mat4 mvp;
      varying vec2 uv;
      void main() { uv = texcoord; gl_Position = mvp * position; }
      """
    let fs = """
      precision mediump float;
      uniform sampler2D tex;
      uniform vec4 tint;
      varying vec2 uv;
      void main() { gl_FragColor = texture2D(tex, uv) * tint + vec4(gl_FragCoord.y * 0.0); }
      """
    func shader(_ type: GLenum, _ source: String) -> GLuint {
      let s = gles_glCreateShader(type)
      source.withCString { p in
        var ptr: UnsafePointer<GLchar>? = p
        gles_glShaderSource(s, 1, &ptr, nil)
      }
      gles_glCompileShader(s)
      var ok: GLint = 0
      gles_glGetShaderiv(s, GL_COMPILE_STATUS, &ok)
      #expect(ok == 1)
      return s
    }
    let p = gles_glCreateProgram()
    gles_glAttachShader(p, shader(GL_VERTEX_SHADER, vs))
    gles_glAttachShader(p, shader(GL_FRAGMENT_SHADER, fs))
    gles_glBindAttribLocation(p, 3, "texcoord")
    gles_glLinkProgram(p)
    #expect(h.linked(p), "\(h.log(p))")
    #expect(gles_glGetAttribLocation(p, "texcoord") == 3)
    gles_glUseProgram(p)
    let identity: [Float] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
    gles_glUniformMatrix4fv(gles_glGetUniformLocation(p, "mvp"), 1, 0, identity)
    gles_glUniform4f(gles_glGetUniformLocation(p, "tint"), 1, 1, 1, 1)
    #expect(h.error() == GL_NO_ERROR)
    h.fullTriangle()
    gles_glVertexAttribPointer(3, 2, GL_FLOAT, 0, 16, nil)
    gles_glEnableVertexAttribArray(3)
    gles_glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT)
    gles_glDrawArrays(GL_TRIANGLES, 0, 3)
    gles_glFinish()
    #expect(h.error() == GL_NO_ERROR)
    // The driver words of a window: y flipped in the vertex stage.
    let program = h.gl.program!
    #expect(program.interface.driverWords == 0)
    #expect(program.block!.load(as: Float.self) == -1)
    #expect(program.block!.load(fromByteOffset: 8, as: Float.self) == 64)
  }

  @Test func theMaliBackendTakesThePipelines() throws {
    nonisolated(unsafe) var said: [String] = []
    unsafe glesLog = { unsafe said.append($0) }
    defer { unsafe glesLog = nil }
    let mali = try MaliDevice(transport: FakeTransport())
    let h = Harness(mali, depth: .depth32f)
    for (v, f) in [("flat.vert", "flat.frag"), ("textured.vert", "textured.frag"), ("shaded.vert", "shaded.frag")] {
      let p = h.program(v, f)
      #expect(h.linked(p), "\(h.log(p))")
      gles_glUseProgram(p)
      h.fullTriangle()
      gles_glVertexAttribPointer(1, 4, GL_FLOAT, 0, 0, nil)
      gles_glEnableVertexAttribArray(1)
      gles_glEnable(GL_DEPTH_TEST)
      gles_glEnable(GL_BLEND)
      gles_glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
      gles_glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT)
      gles_glDrawArrays(GL_TRIANGLES, 0, 3)
      gles_glFinish()
      #expect(h.error() == GL_NO_ERROR, "\(v): \(unsafe said)")
    }
    #expect(h.gl.pipelinesMade == 3)
  }
}
