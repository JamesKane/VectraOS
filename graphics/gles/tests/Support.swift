// SPDX-License-Identifier: BSD-3-Clause

// What GL's host tests share: a context over a device (the test device, or the Mali backend over the fake transport)
// drawing into an off-screen surface of its own, gl-test's SPIR-V (user/tier1/gl-shaders), and programs made of it
// through the C entry points, as a C program makes them.

import Foundation
import GPUCore
import Testing

@testable import GLES

/// Every suite of GL's: one at a time, since the current context and EGL's state are the process's.
@Suite(.serialized) struct GLTests {}

let shaderDirectory = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent()
  .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("user/tier1/gl-shaders").path

func spirv(_ name: String) -> [UInt32] {
  let data = FileManager.default.contents(atPath: shaderDirectory + "/" + name + ".spv")!
  return data.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
}

/// An off-screen surface: an rgba8 image and, if asked, a depth and stencil one.
final class TestSurface: DefaultFramebuffer {
  let image: GPUImage
  let depth: GPUImage?
  init(_ device: any GPUDevice, width: Int32 = 64, height: Int32 = 64, depth depthFormat: PixelFormat? = nil, flipped: Bool = false) {
    image = try! device.makeImage(ImageDescriptor(format: .rgba8, width: width, height: height,
                                                  usage: .renderTarget | .copySource | .copyDestination | .sampled))
    depth = try! depthFormat.map { f throws(GPUError) in
      try device.makeImage(ImageDescriptor(format: f, width: width, height: height, usage: .depthStencilTarget))
    }
    self.flipped = flipped
  }
  let flipped: Bool
  var serial: UInt64 = 1
  var target: RenderTarget {
    let t = RenderTarget()
    t.color = ImageView(image)
    t.colorFormat = image.format
    t.width = image.width
    t.height = image.height
    t.flipped = flipped
    if let d = depth {
      t.depthStencil = ImageView(d)
      t.depthStencilFormat = d.format
      t.hasDepth = d.format.hasDepth
      t.hasStencil = d.format.hasStencil
      t.depthBits = 24
      t.stencilBits = d.format.hasStencil ? 8 : 0
    }
    return t
  }
}

/// A context made current on a surface of its own.
final class Harness {
  let device: any GPUDevice
  let frame: Frame
  let gl: GLContext
  let surface: TestSurface

  init(_ device: any GPUDevice = TestDevice(), depth: PixelFormat? = nil, width: Int32 = 64, height: Int32 = 64, flipped: Bool = false) {
    self.device = device
    frame = Frame(device: device)
    gl = GLContext(frame: frame, share: nil)
    surface = TestSurface(device, width: width, height: height, depth: depth, flipped: flipped)
    gl.madeCurrent(surface)
    unsafe currentContext = gl
  }

  var test: TestDevice { device as! TestDevice }

  /// A program of two of gl-test's shaders, as binaries.
  func program(_ vertex: String, _ fragment: String) -> GLuint {
    let p = gles_glCreateProgram()
    for (name, type) in [(vertex, GL_VERTEX_SHADER), (fragment, GL_FRAGMENT_SHADER)] {
      let s = gles_glCreateShader(type)
      var shader = s
      let words = spirv(name)
      words.withUnsafeBytes { gles_glShaderBinary(1, &shader, GL_SHADER_BINARY_FORMAT_SPIR_V, $0.baseAddress, GLsizei($0.count)) }
      gles_glAttachShader(p, s)
    }
    gles_glLinkProgram(p)
    return p
  }

  /// A program of GLSL ES sources, `position` at location 0.
  func glsl(_ vertex: String, _ fragment: String) -> GLuint {
    let p = gles_glCreateProgram()
    for (source, type) in [(vertex, GL_VERTEX_SHADER), (fragment, GL_FRAGMENT_SHADER)] {
      let s = gles_glCreateShader(type)
      source.withCString { c in
        var ptr: UnsafePointer<GLchar>? = c
        gles_glShaderSource(s, 1, &ptr, nil)
      }
      gles_glCompileShader(s)
      gles_glAttachShader(p, s)
    }
    gles_glBindAttribLocation(p, 0, "position")
    gles_glLinkProgram(p)
    return p
  }

  func linked(_ p: GLuint) -> Bool {
    var status: GLint = 0
    gles_glGetProgramiv(p, GL_LINK_STATUS, &status)
    return status == 1
  }

  func log(_ p: GLuint) -> String {
    var buffer = [GLchar](repeating: 0, count: 1024)
    var n: GLsizei = 0
    gles_glGetProgramInfoLog(p, 1024, &n, &buffer)
    return String(decoding: buffer.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }

  func error() -> GLenum { gles_glGetError() }

  /// A buffer holding `floats`.
  func buffer(_ floats: [Float], target: GLenum = GL_ARRAY_BUFFER) -> GLuint {
    var b: GLuint = 0
    gles_glGenBuffers(1, &b)
    gles_glBindBuffer(target, b)
    floats.withUnsafeBytes { gles_glBufferData(target, $0.count, $0.baseAddress, GL_STATIC_DRAW) }
    return b
  }


  /// Sets the flat program's transform (none: scale 1, offset 0) and colour.
  func uniforms(_ p: GLuint, color: [Float]) {
    gles_glUseProgram(p)
    let transform = gles_glGetUniformLocation(p, "transform")
    let c = gles_glGetUniformLocation(p, "color")
    gles_glUniform4f(transform, 1, 1, 0, 0)
    gles_glUniform4f(c, color[0], color[1], color[2], color[3])
  }

  /// A triangle over the whole surface, as a buffer at attribute 0.
  func fullTriangle() {
    _ = buffer([-1, -1, 0, 1, 3, -1, 0, 1, -1, 3, 0, 1])
    gles_glVertexAttribPointer(0, 4, GL_FLOAT, 0, 0, nil)
    gles_glEnableVertexAttribArray(0)
  }

  /// RGBA bytes of the surface read back.
  func read(_ x: GLint = 0, _ y: GLint = 0, _ w: GLsizei = 1, _ h: GLsizei = 1) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: Int(w) * Int(h) * 4)
    out.withUnsafeMutableBytes { gles_glReadPixels(x, y, w, h, GL_RGBA, GL_UNSIGNED_BYTE, $0.baseAddress) }
    return out
  }
}

/// The bytes at a root block's address (the test device's memory is host memory).
func load<T>(_ address: UInt64, _ offset: Int = 0, as: T.Type) -> T {
  UnsafeRawPointer(bitPattern: UInt(address))!.load(fromByteOffset: offset, as: T.self)
}
