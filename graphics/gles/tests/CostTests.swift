// SPDX-License-Identifier: BSD-3-Clause

// What the library's CPU costs a draw and a frame, over a device that does nothing (no list judged or run): printed, not
// judged, since a host's times aren't the board's. GLES_COST in the environment runs it with 20,000 frames (the default
// is 200, a check that the path runs).

import Foundation
import GPUCore
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
  @Test func whatADrawCosts() {
    let frames = ProcessInfo.processInfo.environment["GLES_COST"] != nil ? 20_000 : 200
    let h = Harness(NullDevice(), depth: .depth32f)
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
      print("gles cost: \(draws) draws a frame: \(Int(ns / 1000)) us a frame, \(Int(ns / Double(draws))) ns a draw")
    }
    #expect(h.error() == GL_NO_ERROR)
  }
}
