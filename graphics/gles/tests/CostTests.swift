// SPDX-License-Identifier: BSD-3-Clause

// What the library's CPU costs a draw and a frame, over a device that does nothing (no list judged or run): printed, not
// judged, since a host's times aren't the board's. (Not over the Mali backend on the fake transport, which copies all its
// memory at each submission.) GLES_COST in the environment runs it with 20,000 frames (the default
// is 200, a check that the path runs).

import Foundation
import GPUCore
import GPUCoreMali
import MaliFakeTransport
import Testing

@testable import GLES

/// The test device, its lists neither judged nor run.
final class NullQueue: GPUQueue {
  unowned let device: TestDevice
  init(_ device: TestDevice) { self.device = device }
  func submit(_ list: GPUCommandList, wait: UInt64, signal: UInt64) throws(GPUError) { device.reached = signal }
  func bindSparse(_ bindings: SparseBindings, wait: UInt64, signal: UInt64) throws(GPUError) {}
}

final class NullDevice: GPUDevice {
  let inner = TestDevice()
  lazy var queue = NullQueue(inner)
  var name: String { "null" }
  var backend: String { "null" }
  var limits: DeviceLimits { inner.limits }
  var graphicsQueue: any GPUQueue { queue }
  var computeQueue: (any GPUQueue)? { nil }
  func allocate(_ intent: MemoryIntent, bytes: Int) throws(GPUError) -> GPUMemory { try inner.allocate(intent, bytes: bytes) }
  func free(_ memory: GPUMemory) {}
  func makeImage(_ d: ImageDescriptor) throws(GPUError) -> GPUImage { try inner.makeImage(d) }
  func destroy(_ image: GPUImage) {}
  func writeTexture(_ index: UInt32, _ image: GPUImage) throws(GPUError) {}
  func writeSampler(_ index: UInt32, _ sampler: SamplerDescriptor) throws(GPUError) {}
  func writeStorageImage(_ index: UInt32, _ image: GPUImage) throws(GPUError) {}
  func makeGraphicsPipeline(_ d: GraphicsPipelineDescriptor) throws(GPUError) -> GPUPipeline { try inner.makeGraphicsPipeline(d) }
  func makeComputePipeline(spirv: [UInt8]) throws(GPUError) -> GPUPipeline { throw .unsupported("compute") }
  func destroy(_ pipeline: GPUPipeline) {}
  func makeQuerySet(_ kind: QueryKind, count: Int) throws(GPUError) -> GPUQuerySet { throw .unsupported("queries") }
  func destroy(_ set: GPUQuerySet) {}
  func results(_ set: GPUQuerySet, first: Int, count: Int) throws(GPUError) -> [UInt64] { [] }
  var completed: UInt64 { inner.reached }
  func wait(_ value: UInt64) throws(GPUError) {}
}

extension GLTests {
  @Test func whatADrawCosts() { measure(NullDevice(), "null") }

  func measure(_ device: any GPUDevice, _ name: String, profile: (() -> String)? = nil) {
    let frames = ProcessInfo.processInfo.environment["GLES_COST"] != nil ? 20_000 : 200
    let h = Harness(device, depth: .depth32f)
    let p = h.program("textured.vert", "textured.frag")
    h.uniforms(p, color: [1, 1, 1, 1])
    h.fullTriangle()
    gles_glVertexAttribPointer(1, 2, GL_FLOAT, 0, 16, nil)
    gles_glEnableVertexAttribArray(1)
    var t: GLuint = 0
    gles_glGenTextures(1, &t)
    gles_glBindTexture(GL_TEXTURE_2D, t)
    let white: [UInt8] = [255, 255, 255, 255]
    gles_glTexImage2D(GL_TEXTURE_2D, 0, GLint(GL_RGBA), 1, 1, 0, GL_RGBA, GL_UNSIGNED_BYTE, white)
    gles_glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GLint(GL_LINEAR))
    gles_glEnable(GL_DEPTH_TEST)
    let color = gles_glGetUniformLocation(p, "color")
    for draws in [1, 10, 100] {
      let start = DispatchTime.now().uptimeNanoseconds
      for f in 0..<frames {
        gles_glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT)
        for d in 0..<draws {
          // A uniform changed each draw, as a scene's matrix is.
          gles_glUniform4f(color, 1, Float(d) / 100, Float(f % 2), 1)
          gles_glDrawArrays(GL_TRIANGLES, 0, 3)
        }
        gles_glFinish()
      }
      let ns = Double(DispatchTime.now().uptimeNanoseconds - start) / Double(frames)
      print("gles cost (\(name)): \(draws) draws a frame: \(Int(ns / 1000)) us a frame, \(Int(ns / Double(draws))) ns a draw"
        + (profile.map { "; " + $0() } ?? ""))
    }
    // Passes over framebuffer objects: four textures drawn into and each sampled in a pass of the surface, as a desktop
    // of windows is.
    var textures = [GLuint](repeating: 0, count: 4), fbos = [GLuint](repeating: 0, count: 4)
    gles_glGenTextures(4, &textures)
    gles_glGenFramebuffers(4, &fbos)
    for i in 0..<4 {
      gles_glBindTexture(GL_TEXTURE_2D, textures[i])
      gles_glTexImage2D(GL_TEXTURE_2D, 0, GLint(GL_RGBA), 256, 256, 0, GL_RGBA, GL_UNSIGNED_BYTE, nil)
      gles_glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GLint(GL_LINEAR))
      gles_glBindFramebuffer(GL_FRAMEBUFFER, fbos[i])
      gles_glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, textures[i], 0)
    }
    gles_glDisable(GL_DEPTH_TEST)
    let start = DispatchTime.now().uptimeNanoseconds
    for f in 0..<frames {
      for i in 0..<4 {
        gles_glBindFramebuffer(GL_FRAMEBUFFER, fbos[i])
        gles_glViewport(0, 0, 256, 256)
        gles_glClear(GL_COLOR_BUFFER_BIT)
        gles_glBindTexture(GL_TEXTURE_2D, t)
        gles_glUniform4f(color, 1, Float(i) / 4, Float(f % 2), 1)
        gles_glDrawArrays(GL_TRIANGLES, 0, 3)
      }
      gles_glBindFramebuffer(GL_FRAMEBUFFER, 0)
      gles_glViewport(0, 0, 64, 64)
      gles_glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT)
      for i in 0..<4 {
        gles_glBindTexture(GL_TEXTURE_2D, textures[i])
        gles_glDrawArrays(GL_TRIANGLES, 0, 3)
      }
      gles_glFinish()
    }
    let ns = Double(DispatchTime.now().uptimeNanoseconds - start) / Double(frames)
    print("gles cost (\(name)): four framebuffer objects and a composite: \(Int(ns / 1000)) us a frame, "
      + "\(h.frame.passesSubmitted / max(frames, 1)) passes" + (profile.map { "; " + $0() } ?? ""))
    #expect(h.error() == GL_NO_ERROR)
  }

  @Test func whatAManyDrawFrameCosts() throws {
    let fake = FakeTransport()
    fake.keepsSubmits = false
    manyDraws(try MaliDevice(transport: fake), "mali")
  }

  @Test func whatAManyDrawFrameCostsGL() { manyDraws(NullDevice(), "null") }

  /// A frame of glmark2's ideas as GL sees it: 353 draws in one pass, most of them indexed draws of one buffer with nothing
  /// changed between them, the rest after a matrix or a vertex attribute changed.
  func manyDraws(_ device: any GPUDevice, _ name: String) {
    let frames = ProcessInfo.processInfo.environment["GLES_COST"].flatMap { Int($0) } ?? 100
    let h = Harness(device, depth: .depth32f, width: 800, height: 600)
    let vs = """
      attribute vec3 position;
      attribute vec3 normal;
      uniform mat4 modelview;
      uniform mat4 projection;
      uniform mat3 normalMatrix;
      uniform vec3 light;
      varying vec3 lit;
      void main() {
        lit = max(dot(normalMatrix * normal, light), 0.0) * vec3(1.0);
        gl_Position = projection * modelview * vec4(position, 1.0);
      }
      """
    let fs = """
      precision mediump float;
      uniform vec4 tint;
      varying vec3 lit;
      void main() { gl_FragColor = vec4(lit, 1.0) * tint; }
      """
    let p = h.glsl(vs, fs)
    let q = h.glsl(vs, fs)
    #expect(h.linked(p) && h.linked(q), "\(h.log(p))")
    var vertices: [Float] = []
    for i in 0..<1024 { vertices += [Float(i % 32) / 32, Float(i / 32) / 32, 0, 0, 0, 1] }
    let vbo = h.buffer(vertices)
    var indices: [UInt16] = []
    for i in 0..<3000 { indices.append(UInt16(i % 1024)) }
    var ebo: GLuint = 0
    gles_glGenBuffers(1, &ebo)
    gles_glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, ebo)
    indices.withUnsafeBytes { gles_glBufferData(GL_ELEMENT_ARRAY_BUFFER, $0.count, $0.baseAddress, GL_STATIC_DRAW) }
    var matrix: [Float] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
    let normal: [Float] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
    func locations(_ p: GLuint) -> [GLint] {
      let u: [String] = ["modelview", "projection", "normalMatrix", "light", "tint"], a: [String] = ["position", "normal"]
      return u.map { n in n.withCString { gles_glGetUniformLocation(p, $0) } } + a.map { n in n.withCString { gles_glGetAttribLocation(p, $0) } }
    }
    let lp = locations(p), lq = locations(q)
    gles_glEnable(GL_DEPTH_TEST)
    gles_glEnable(GL_CULL_FACE)
    let start = DispatchTime.now().uptimeNanoseconds
    for f in 0..<frames {
      gles_glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT)
      // The table and the logo: runs of indexed draws, a matrix between runs.
      gles_glUseProgram(p)
      gles_glUniformMatrix4fv(lp[1], 1, 0, matrix)
      gles_glUniform3f(lp[3], 0, 0, 1)
      gles_glUniform4f(lp[4], 1, 1, 1, 1)
      gles_glBindBuffer(GL_ARRAY_BUFFER, vbo)
      gles_glVertexAttribPointer(GLuint(lp[5]), 3, GL_FLOAT, 0, 24, nil)
      gles_glVertexAttribPointer(GLuint(lp[6]), 3, GL_FLOAT, 0, 24, UnsafeRawPointer(bitPattern: 12))
      gles_glEnableVertexAttribArray(GLuint(lp[5]))
      gles_glEnableVertexAttribArray(GLuint(lp[6]))
      gles_glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, ebo)
      for d in 0..<316 {
        if d % 5 == 0 {
          matrix[12] = Float(d) / 316
          matrix[13] = Float(f % 7)
          gles_glUniformMatrix4fv(lp[0], 1, 0, matrix)
          gles_glUniformMatrix3fv(lp[2], 1, 0, normal)
        }
        gles_glDrawElements(GL_TRIANGLES, 6, GL_UNSIGNED_SHORT, UnsafeRawPointer(bitPattern: 12 * (d % 200)))
      }
      // The paper: a draw of its own each, its matrices and attributes set again.
      gles_glUseProgram(q)
      gles_glUniformMatrix4fv(lq[1], 1, 0, matrix)
      for d in 0..<37 {
        matrix[14] = Float(d) / 37
        gles_glUniformMatrix4fv(lq[0], 1, 0, matrix)
        gles_glUniformMatrix3fv(lq[2], 1, 0, normal)
        gles_glBindBuffer(GL_ARRAY_BUFFER, vbo)
        gles_glVertexAttribPointer(GLuint(lq[5]), 3, GL_FLOAT, 0, 24, nil)
        gles_glVertexAttribPointer(GLuint(lq[6]), 3, GL_FLOAT, 0, 24, UnsafeRawPointer(bitPattern: 12))
        gles_glDrawArrays(GL_TRIANGLE_STRIP, GLint(4 * d), 4)
      }
      gles_glFinish()
    }
    let ns = Double(DispatchTime.now().uptimeNanoseconds - start) / Double(frames)
    print("gles cost (\(name)): ideas' 353 draws a frame: \(Int(ns / 1000)) us a frame, \(Int(ns / 353)) ns a draw")
    #expect(h.error() == GL_NO_ERROR)
  }
}
