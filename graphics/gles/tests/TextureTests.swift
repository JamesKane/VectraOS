// SPDX-License-Identifier: BSD-3-Clause

// Textures: every GL ES 2.0 format and type converted to the device's rgba8, the unpack alignment, completeness,
// samplers shared by their state, render to texture and the barrier before it is read.

import GPUCore
import Testing

@testable import GLES

extension GLTests {
  /// The texture's image's first texels, as the device has them.
  func texels(_ h: Harness, _ name: GLuint, count: Int) -> [UInt8] {
    gles_glFinish()
    let image = h.gl.share.textures[name]!.image!
    return Array(h.test.contents[image.handle]!.prefix(count * 4))
  }

  func texture() -> GLuint {
    var t: GLuint = 0
    gles_glGenTextures(1, &t)
    gles_glBindTexture(GL_TEXTURE_2D, t)
    return t
  }

  @Test func everyFormatBecomesRGBA8() {
    let h = Harness()
    gles_glPixelStorei(GL_UNPACK_ALIGNMENT, 1)
    func upload(_ format: GLenum, _ type: GLenum, _ bytes: [UInt8], width: GLsizei = 2) -> [UInt8] {
      let t = texture()
      bytes.withUnsafeBytes { gles_glTexImage2D(GL_TEXTURE_2D, 0, GLint(format), width, 1, 0, format, type, $0.baseAddress) }
      #expect(h.error() == GL_NO_ERROR)
      return texels(h, t, count: Int(width))
    }
    #expect(upload(GL_RGBA, GL_UNSIGNED_BYTE, [1, 2, 3, 4, 5, 6, 7, 8]) == [1, 2, 3, 4, 5, 6, 7, 8])
    #expect(upload(GL_RGB, GL_UNSIGNED_BYTE, [1, 2, 3, 4, 5, 6]) == [1, 2, 3, 255, 4, 5, 6, 255])
    #expect(upload(GL_LUMINANCE, GL_UNSIGNED_BYTE, [9, 200]) == [9, 9, 9, 255, 200, 200, 200, 255])
    #expect(upload(GL_ALPHA, GL_UNSIGNED_BYTE, [9, 200]) == [0, 0, 0, 9, 0, 0, 0, 200])
    #expect(upload(GL_LUMINANCE_ALPHA, GL_UNSIGNED_BYTE, [9, 10, 200, 201]) == [9, 9, 9, 10, 200, 200, 200, 201])
    // 565: red 31, green 0, blue 0; then red 0, green 63, blue 31.
    #expect(upload(GL_RGB, GL_UNSIGNED_SHORT_5_6_5, [0x00, 0xF8, 0xFF, 0x07]) == [255, 0, 0, 255, 0, 255, 255, 255])
    // 4444: 0xF00F (red 15, alpha 15), 0x0880.
    #expect(upload(GL_RGBA, GL_UNSIGNED_SHORT_4_4_4_4, [0x0F, 0xF0, 0x80, 0x08]) == [255, 0, 0, 255, 0, 136, 136, 0])
    // 5551: 0xF801 (red 31, alpha 1), 0x07C0 (green 31, alpha 0).
    #expect(upload(GL_RGBA, GL_UNSIGNED_SHORT_5_5_5_1, [0x01, 0xF8, 0xC0, 0x07]) == [255, 0, 0, 255, 0, 255, 0, 0])
    #expect(upload(GL_BGRA_EXT, GL_UNSIGNED_BYTE, [1, 2, 3, 4, 5, 6, 7, 8]) == [3, 2, 1, 4, 7, 6, 5, 8])
  }

  @Test func rowsAreUnpackAligned() {
    let h = Harness()
    let t = texture()
    // Two RGB rows of one texel, each row padded to four bytes.
    let bytes: [UInt8] = [1, 2, 3, 0, 4, 5, 6, 0]
    bytes.withUnsafeBytes { gles_glTexImage2D(GL_TEXTURE_2D, 0, GLint(GL_RGB), 1, 2, 0, GL_RGB, GL_UNSIGNED_BYTE, $0.baseAddress) }
    #expect(texels(h, t, count: 2) == [1, 2, 3, 255, 4, 5, 6, 255])
    // A sub-image lands where it is put.
    let one: [UInt8] = [7, 8, 9, 10]
    one.withUnsafeBytes { gles_glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 1, 1, 1, GL_RGB, GL_UNSIGNED_BYTE, $0.baseAddress) }
    #expect(texels(h, t, count: 2) == [1, 2, 3, 255, 7, 8, 9, 255])
    gles_glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 1, 1, 2, GL_RGB, GL_UNSIGNED_BYTE, nil)
    #expect(h.error() == GL_INVALID_VALUE)
    gles_glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, nil)
    #expect(h.error() == GL_INVALID_OPERATION)
  }

  @Test func completenessFollowsTheFilter() {
    let h = Harness()
    let t = texture()
    gles_glTexImage2D(GL_TEXTURE_2D, 0, GLint(GL_RGBA), 4, 4, 0, GL_RGBA, GL_UNSIGNED_BYTE, nil)
    let tex = h.gl.share.textures[t]!
    // The default minification filter mips: level 0 alone is incomplete.
    #expect(!tex.isComplete)
    gles_glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GLint(GL_LINEAR))
    #expect(tex.isComplete)
    gles_glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GLint(GL_LINEAR_MIPMAP_LINEAR))
    gles_glGenerateMipmap(GL_TEXTURE_2D)
    #expect(tex.isComplete)
    #expect(tex.image!.mipLevels == 3)
    #expect(tex.samplerDescriptor.mipmapMode == .linear)
    gles_glFinish()
    #expect(h.test.commands.contains { if case .blitImage = $0 { true } else { false } })
    // A filter without mips reads level 0 alone, keeping the magnification filter.
    gles_glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GLint(GL_NEAREST))
    #expect(tex.samplerDescriptor.maxLod == 0.25 && tex.samplerDescriptor.magFilter == .linear)
    #expect(h.error() == GL_NO_ERROR)
  }

  @Test func samplersAreKeptByTheirState() {
    let h = Harness(TestDevice(heapSamplers: 4))
    let p = h.program("textured.vert", "textured.frag")
    #expect(h.linked(p), "\(h.log(p))")
    h.uniforms(p, color: [1, 1, 1, 1])
    h.fullTriangle()
    let white: [UInt8] = [255, 255, 255, 255]
    for i in 0..<10 {
      let t = texture()
      white.withUnsafeBytes { gles_glTexImage2D(GL_TEXTURE_2D, 0, GLint(GL_RGBA), 1, 1, 0, GL_RGBA, GL_UNSIGNED_BYTE, $0.baseAddress) }
      // Six states among ten textures, more than the four slots: the open list is submitted when it needs a slot.
      gles_glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GLint(i % 2 == 0 ? GL_NEAREST : GL_LINEAR))
      gles_glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GLint([GL_REPEAT, GL_CLAMP_TO_EDGE, GL_MIRRORED_REPEAT][i % 3]))
      gles_glDrawArrays(GL_TRIANGLES, 0, 3)
    }
    gles_glFinish()
    #expect(h.error() == GL_NO_ERROR)
    let d = h.test
    #expect(d.samplers.count == 4)
    #expect(d.draws.count == 10)
    // Each draw's set record names a texture and a sampler that were written.
    for draw in d.draws {
      let set = load(draw.root, 0, as: UInt64.self)
      #expect(d.textures[load(set, 16, as: UInt32.self)] != nil)
      #expect(load(set, 20, as: UInt32.self) < 4)
    }
  }

  @Test func anIncompleteTextureReadsBlack() {
    let h = Harness()
    let p = h.program("textured.vert", "textured.frag")
    h.uniforms(p, color: [1, 1, 1, 1])
    h.fullTriangle()
    _ = texture()
    gles_glDrawArrays(GL_TRIANGLES, 0, 3)
    gles_glFinish()
    let d = h.test
    let set = load(d.draws[0].root, 0, as: UInt64.self)
    let image = d.textures[load(set, 16, as: UInt32.self)]!
    #expect(image.width == 1 && d.contents[image.handle]! == [0, 0, 0, 255])
  }

  @Test func renderToTextureThenSampleIt() {
    let h = Harness()
    let t = texture()
    gles_glTexImage2D(GL_TEXTURE_2D, 0, GLint(GL_RGBA), 16, 16, 0, GL_RGBA, GL_UNSIGNED_BYTE, nil)
    gles_glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GLint(GL_LINEAR))
    var f: GLuint = 0
    gles_glGenFramebuffers(1, &f)
    gles_glBindFramebuffer(GL_FRAMEBUFFER, f)
    gles_glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, t, 0)
    #expect(gles_glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE)
    gles_glClearColor(0, 1, 0, 1)
    gles_glClear(GL_COLOR_BUFFER_BIT)
    let p = h.program("textured.vert", "textured.frag")
    h.uniforms(p, color: [1, 1, 1, 1])
    h.fullTriangle()
    gles_glDrawArrays(GL_TRIANGLES, 0, 3)
    gles_glBindFramebuffer(GL_FRAMEBUFFER, 0)
    gles_glClear(GL_COLOR_BUFFER_BIT)
    gles_glDrawArrays(GL_TRIANGLES, 0, 3)
    gles_glFinish()
    let d = h.test
    #expect(d.passes.count == 2)
    #expect(d.passes[0].colors[0].view.image == h.gl.share.textures[t]!.image!)
    // A barrier between the pass that drew the texture and the one that reads it.
    let c = d.commands
    let end = c.firstIndex { $0 == .endRendering }!
    let begin = c.lastIndex { if case .beginRendering = $0 { true } else { false } }!
    #expect(c[end..<begin].contains { if case .barrier = $0 { true } else { false } })
    #expect(texels(h, t, count: 1) == [0, 255, 0, 255])
    #expect(h.error() == GL_NO_ERROR)
  }

  @Test func renderbuffersAndCompleteness() {
    let h = Harness()
    var f: GLuint = 0, r: [GLuint] = [0, 0]
    gles_glGenFramebuffers(1, &f)
    gles_glGenRenderbuffers(2, &r)
    gles_glBindFramebuffer(GL_FRAMEBUFFER, f)
    gles_glBindRenderbuffer(GL_RENDERBUFFER, r[0])
    gles_glRenderbufferStorage(GL_RENDERBUFFER, GL_RGB565, 32, 32)
    gles_glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, r[0])
    gles_glBindRenderbuffer(GL_RENDERBUFFER, r[1])
    gles_glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT16, 16, 16)
    gles_glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, r[1])
    #expect(gles_glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_INCOMPLETE_DIMENSIONS)
    gles_glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT16, 32, 32)
    #expect(gles_glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE)
    var bits: GLint = 0
    gles_glGetIntegerv(GL_GREEN_BITS, &bits)
    #expect(bits == 6)
    gles_glGetIntegerv(GL_DEPTH_BITS, &bits)
    #expect(bits == 16)
    gles_glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &bits)
    #expect(bits == 32)
    // A colour format with no alpha reads alpha 1.
    gles_glClearColor(1, 0, 0, 0)
    gles_glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT)
    #expect(h.read() == [255, 0, 0, 255])
    gles_glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, 0)
    gles_glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, r[1])
    #expect(gles_glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_INCOMPLETE_ATTACHMENT)
    #expect(h.error() == GL_NO_ERROR)
  }

  @Test func copyTexImageReadsTheFramebuffer() {
    let h = Harness()
    gles_glClearColor(0, 0, 1, 1)
    gles_glClear(GL_COLOR_BUFFER_BIT)
    let t = texture()
    gles_glCopyTexImage2D(GL_TEXTURE_2D, 0, GL_RGB, 0, 0, 4, 4, 0)
    #expect(h.error() == GL_NO_ERROR)
    gles_glFinish()
    #expect(h.test.commands.contains { if case .copyImage = $0 { true } else { false } })
    let image = h.gl.share.textures[t]!.image!
    #expect(image.width == 4)
  }
}
