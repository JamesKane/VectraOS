// SPDX-License-Identifier: BSD-3-Clause

// GL's objects (gles(3), "Objects"): buffers, textures, renderbuffers, framebuffers and vertex arrays, and the share
// group that names the shareable ones. An object is a class the names point at; the device's resources behind it are
// made when GL first gives it storage and given back (through the frame, which keeps what the open list reads until it
// is submitted) when it is deleted or re-specified.

import GPUCore

/// A buffer object: the CPU's copy of its bytes, which every call writes, and the device's copy a draw reads, brought up
/// to date before the draw. A device copy the GPU may still read (submitted, or in the open list) is never written: the
/// buffer moves to fresh memory and the old copy goes back once the GPU is past it.
@safe final class GLBuffer {
  let name: GLuint
  /// The CPU's copy (`size` bytes; mapped by MapBufferOES).
  var bytes: UnsafeMutableRawPointer?
  var size = 0
  var usage: GLenum = GL_STATIC_DRAW
  /// The device's copy and the bytes of it that are behind the CPU's (`dirtyLow ..< dirtyHigh`).
  var memory: GPUMemory?
  var memoryBytes = 0
  var dirtyLow = 0
  var dirtyHigh = 0
  /// The open list's epoch that last read it (the frame knows that list's timeline value).
  var openUse: UInt64 = 0
  var mapped = false
  var deleted = false

  init(name: GLuint) { self.name = name }
  deinit { unsafe bytes?.deallocate() }

  /// Gives the buffer `count` bytes (from `data`, or zeros).
  func respecify(_ count: Int, _ data: UnsafeRawPointer?, usage: GLenum) {
    if count != size {
      unsafe bytes?.deallocate()
      unsafe bytes = count > 0 ? UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 16) : nil
      size = count
    }
    if let b = unsafe bytes {
      if let data = unsafe data { unsafe b.copyMemory(from: data, byteCount: count) } else {
        unsafe b.initializeMemory(as: UInt8.self, repeating: 0, count: count)
      }
    }
    self.usage = usage
    markDirty(0, count)
  }

  func markDirty(_ low: Int, _ high: Int) {
    if dirtyHigh <= dirtyLow {
      dirtyLow = low
      dirtyHigh = high
    } else {
      dirtyLow = min(dirtyLow, low)
      dirtyHigh = max(dirtyHigh, high)
    }
  }

  var isDirty: Bool { dirtyHigh > dirtyLow || (memory == nil && size > 0) }
}

/// One mip level of one face of a texture, as GL specified it.
struct TextureLevel: Equatable {
  var width: Int32
  var height: Int32
  /// GL's internal format (the format given to TexImage2D), which completeness compares.
  var internalFormat: GLenum
}

/// A texture object: 2D or cube, its levels as GL specified them, and the device's image of the full mip chain of level
/// 0's size (a level GL never gave is never read: a sampler that doesn't mip reads level 0 alone, and one that does reads
/// a texture whose levels are all there).
final class GLTexture {
  let name: GLuint
  /// GL_TEXTURE_2D or GL_TEXTURE_CUBE_MAP once first bound; 0 before.
  var target: GLenum = 0
  /// [face][level]: one face for a 2D texture, six for a cube.
  var levels: [[TextureLevel?]] = []
  var image: GPUImage?
  var kind: StorageKind = .color(alpha: true)
  /// The heap's texture slot of `image`.
  var slot: UInt32?
  // Sampler state.
  var minFilter: GLenum = GL_NEAREST_MIPMAP_LINEAR
  var magFilter: GLenum = GL_LINEAR
  var wrapS: GLenum = GL_REPEAT
  var wrapT: GLenum = GL_REPEAT
  var maxAnisotropy: Float = 1
  /// The heap's sampler slot of the state above, and the generation of that slot it was found at.
  var samplerSlot: UInt32?
  var samplerGeneration: UInt64 = 0
  /// Completeness, as of the last change.
  var completeCache: Bool?
  /// The open list's epoch that last read it (the frame knows that list's timeline value).
  var openUse: UInt64 = 0
  var deleted = false

  init(name: GLuint) { self.name = name }

  var faces: Int { target == GL_TEXTURE_CUBE_MAP ? 6 : 1 }

  func level(face: Int, _ level: Int) -> TextureLevel? {
    guard face < levels.count, level < levels[face].count else { return nil }
    return levels[face][level]
  }

  var usesMipmaps: Bool { minFilter != GL_NEAREST && minFilter != GL_LINEAR }

  /// GL ES 2.0's completeness (section 3.7.10, and 3.8.2 for what sampling an incomplete texture reads).
  var isComplete: Bool {
    if let c = completeCache { return c }
    let c = computeComplete()
    completeCache = c
    return c
  }

  private func computeComplete() -> Bool {
    guard let base = level(face: 0, 0), base.width > 0, base.height > 0, image != nil else { return false }
    if target == GL_TEXTURE_CUBE_MAP {
      guard base.width == base.height else { return false }
      for f in 1..<6 where level(face: f, 0) != base { return false }
    }
    if usesMipmaps {
      let count = Int(fullMipCount(base.width, base.height))
      for f in 0..<faces {
        for l in 0..<count {
          let w = max(1, base.width >> Int32(l)), h = max(1, base.height >> Int32(l))
          guard let lv = level(face: f, l), lv.width == w, lv.height == h, lv.internalFormat == base.internalFormat else { return false }
        }
      }
    }
    return true
  }

  /// The sampler GL's state describes. A filter without mipmaps reads level 0 alone, but keeps the choice between the
  /// magnification and minification filters (a maximum level of detail of 0.25, under which a nearest mip is level 0).
  var samplerDescriptor: SamplerDescriptor {
    func filter(_ f: GLenum) -> SamplerFilter {
      f == GL_NEAREST || f == GL_NEAREST_MIPMAP_NEAREST || f == GL_NEAREST_MIPMAP_LINEAR ? .nearest : .linear
    }
    func address(_ w: GLenum) -> SamplerAddressMode {
      switch w {
      case GL_CLAMP_TO_EDGE: .clampToEdge
      case GL_MIRRORED_REPEAT: .mirroredRepeat
      default: .repeat
      }
    }
    let mip: SamplerMipmapMode = minFilter == GL_NEAREST_MIPMAP_LINEAR || minFilter == GL_LINEAR_MIPMAP_LINEAR ? .linear : .nearest
    return SamplerDescriptor(minFilter: filter(minFilter), magFilter: filter(magFilter), mipmapMode: mip,
                             addressModeU: address(wrapS), addressModeV: address(wrapT), addressModeW: .clampToEdge,
                             maxLod: usesMipmaps ? 1000 : 0.25, maxAnisotropy: maxAnisotropy)
  }
}

/// A renderbuffer: an image a framebuffer draws into and nothing samples.
final class GLRenderbuffer {
  let name: GLuint
  var image: GPUImage?
  var internalFormat: GLenum = GL_RGBA4
  var kind: StorageKind = .color(alpha: true)
  var width: Int32 = 0
  var height: Int32 = 0
  var deleted = false
  init(name: GLuint) { self.name = name }
}

/// What a framebuffer's attachment point holds.
enum FramebufferAttachment {
  case none
  case texture(GLTexture, level: Int, face: Int)
  case renderbuffer(GLRenderbuffer)

  var isNone: Bool {
    if case .none = self { return true }
    return false
  }
}

final class GLFramebuffer {
  let name: GLuint
  var color: FramebufferAttachment = .none
  var depth: FramebufferAttachment = .none
  var stencil: FramebufferAttachment = .none
  init(name: GLuint) { self.name = name }
}

/// One generic vertex attribute's array state.
struct VertexAttribState {
  var enabled = false
  var size = 4
  var type: GLenum = GL_FLOAT
  var normalized = false
  /// As given (0: tightly packed).
  var stride: Int32 = 0
  var buffer: GLBuffer?
  /// The offset into `buffer`, or the client's address where there is no buffer.
  var pointer: UInt = 0

  var effectiveStride: Int {
    if stride != 0 { return Int(stride) }
    return size * (attributeComponentBytes(type) ?? 4)
  }
}

/// A vertex array object (OES_vertex_array_object): the attribute arrays and the element buffer. Name 0 is the context's.
final class GLVertexArray {
  let name: GLuint
  var attributes = [VertexAttribState](repeating: VertexAttribState(), count: maxVertexAttribs)
  var elementBuffer: GLBuffer?
  var deleted = false
  init(name: GLuint) { self.name = name }
}

/// The vertex attributes a program may have: one root-block vertex buffer each (RootBlock.maxVertexBuffers).
let maxVertexAttribs = 8

/// The names of one kind of object, and the objects they name.
struct NameTable<T: AnyObject> {
  private(set) var objects: [GLuint: T] = [:]
  /// Names generated but not yet bound to an object.
  private var reserved: [GLuint: Bool] = [:]
  private var next: GLuint = 1

  mutating func generate() -> GLuint {
    while objects[next] != nil || reserved[next] != nil { next &+= 1 }
    let n = next
    reserved[n] = true
    next &+= 1
    return n
  }

  subscript(name: GLuint) -> T? { objects[name] }

  func isName(_ name: GLuint) -> Bool { objects[name] != nil || reserved[name] != nil }

  mutating func insert(_ name: GLuint, _ object: T) {
    reserved[name] = nil
    objects[name] = object
  }

  mutating func remove(_ name: GLuint) -> T? {
    reserved[name] = nil
    return objects.removeValue(forKey: name)
  }
}

/// What contexts made sharing one another share (EGL's share_context): buffers, textures, renderbuffers, shaders and
/// programs. Framebuffers and vertex arrays are each context's own.
final class ShareGroup {
  var buffers = NameTable<GLBuffer>()
  var textures = NameTable<GLTexture>()
  var renderbuffers = NameTable<GLRenderbuffer>()
  /// Shaders and programs share one namespace.
  var shaderObjects: [GLuint: AnyObject] = [:]
  var nextShaderName: GLuint = 1
}
