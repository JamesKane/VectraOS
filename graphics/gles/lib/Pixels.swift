// SPDX-License-Identifier: BSD-3-Clause

// GL's pixels and the device's (gles(3), "Textures"). Every colour texture and renderbuffer is the device's rgba8,
// whatever GL format it was given as: an upload is converted on the CPU, once, into tightly packed rgba8 rows, so a
// shader reads every format the same way and no view swizzles. A depth texture is depth16 or depth32f. ReadPixels
// reads rgba8 (or a window's bgra8) back as GL's RGBA and UNSIGNED_BYTE.

import GPUCore
import VulkanLowering

/// A texture's or renderbuffer's storage on the device, by what GL asked for.
enum StorageKind: Equatable {
  /// rgba8; `alpha` false for a format without alpha (RGB, LUMINANCE, 565), which reads 1.
  case color(alpha: Bool)
  case depth(PixelFormat)
  case stencil(PixelFormat)
  case depthStencil(PixelFormat)

  var pixelFormat: PixelFormat {
    switch self {
    case .color: .rgba8
    case .depth(let f), .stencil(let f), .depthStencil(let f): f
    }
  }
}

/// The bytes a pixel of GL `format` and `type` takes in client memory, or nil for a pair GL ES 2.0 doesn't have (the
/// error to record: INVALID_ENUM for a type or format it doesn't know, INVALID_OPERATION for a known pair that doesn't go
/// together).
func clientPixelBytes(format: GLenum, type: GLenum) -> Result<Int, GLErrorCode> {
  switch type {
  case GL_UNSIGNED_BYTE:
    switch format {
    case GL_RGBA, GL_BGRA_EXT: return .success(4)
    case GL_RGB: return .success(3)
    case GL_LUMINANCE_ALPHA: return .success(2)
    case GL_LUMINANCE, GL_ALPHA: return .success(1)
    case GL_DEPTH_COMPONENT, GL_DEPTH_STENCIL_OES: return .failure(.invalidOperation)
    default: return .failure(.invalidEnum)
    }
  case GL_UNSIGNED_SHORT_5_6_5:
    switch format {
    case GL_RGB: return .success(2)
    case GL_RGBA, GL_LUMINANCE_ALPHA, GL_LUMINANCE, GL_ALPHA, GL_DEPTH_COMPONENT, GL_BGRA_EXT: return .failure(.invalidOperation)
    default: return .failure(.invalidEnum)
    }
  case GL_UNSIGNED_SHORT_4_4_4_4, GL_UNSIGNED_SHORT_5_5_5_1:
    switch format {
    case GL_RGBA: return .success(2)
    case GL_RGB, GL_LUMINANCE_ALPHA, GL_LUMINANCE, GL_ALPHA, GL_DEPTH_COMPONENT, GL_BGRA_EXT: return .failure(.invalidOperation)
    default: return .failure(.invalidEnum)
    }
  case GL_UNSIGNED_SHORT:
    if format == GL_DEPTH_COMPONENT { return .success(2) }
    return .failure(isKnownFormat(format) ? .invalidOperation : .invalidEnum)
  case GL_UNSIGNED_INT:
    if format == GL_DEPTH_COMPONENT { return .success(4) }
    return .failure(isKnownFormat(format) ? .invalidOperation : .invalidEnum)
  case GL_UNSIGNED_INT_24_8_OES:
    if format == GL_DEPTH_STENCIL_OES { return .success(4) }
    return .failure(isKnownFormat(format) ? .invalidOperation : .invalidEnum)
  default: return .failure(.invalidEnum)
  }
}

func isKnownFormat(_ f: GLenum) -> Bool {
  switch f {
  case GL_RGBA, GL_RGB, GL_LUMINANCE_ALPHA, GL_LUMINANCE, GL_ALPHA, GL_DEPTH_COMPONENT, GL_DEPTH_STENCIL_OES, GL_BGRA_EXT: true
  default: false
  }
}

/// Whether a GL format's texels have alpha (an RGB texture reads alpha 1).
func formatHasAlpha(_ format: GLenum) -> Bool {
  format == GL_RGBA || format == GL_LUMINANCE_ALPHA || format == GL_ALPHA || format == GL_BGRA_EXT
}

/// The bytes from one client row to the next: `width` pixels of `pixelBytes`, rounded up to `alignment`.
func clientRowBytes(width: Int, pixelBytes: Int, alignment: Int) -> Int { align(width * pixelBytes, alignment) }

/// Expands 5, 6 and 4-bit channels to 8 bits as the spec's conversion does (round(c * 255 / max)).
@inline(__always) func expand5(_ v: UInt32) -> UInt8 { UInt8((v * 527 + 23) >> 6) }
@inline(__always) func expand6(_ v: UInt32) -> UInt8 { UInt8((v * 259 + 33) >> 6) }
@inline(__always) func expand4(_ v: UInt32) -> UInt8 { UInt8(v * 17) }

/// Converts `height` rows of `width` client pixels of `format` and `type`, `rowBytes` apart, from `source`, into the
/// device's texels at `destination`: tightly packed rgba8, or the depth format's bytes (`depth16`: the 16-bit values;
/// `depth32f`: each value over 2^32-1 as a float; `depth24stencil8`: the 24-8 words as they are).
func convertToDevice(_ source: UnsafeRawPointer, width: Int, height: Int, rowBytes: Int, format: GLenum, type: GLenum,
                     into destination: UnsafeMutableRawPointer, deviceFormat: PixelFormat) {
  let out = unsafe destination.assumingMemoryBound(to: UInt8.self)
  for y in 0..<height {
    let row = unsafe source + y * rowBytes
    let b = unsafe row.assumingMemoryBound(to: UInt8.self)
    switch (format, type, deviceFormat) {
    case (GL_DEPTH_COMPONENT, GL_UNSIGNED_SHORT, .depth16):
      unsafe (destination + y * width * 2).copyMemory(from: row, byteCount: width * 2)
    case (GL_DEPTH_COMPONENT, _, .depth32f), (GL_DEPTH_STENCIL_OES, _, .depth32f):
      let d = unsafe (destination + y * width * 4).assumingMemoryBound(to: Float.self)
      for x in 0..<width {
        let v = unsafe row.loadUnaligned(fromByteOffset: x * 4, as: UInt32.self)
        // A 24-8 word's depth is its top 24 bits.
        unsafe d[x] = format == GL_DEPTH_STENCIL_OES ? Float(v >> 8) / 16_777_215 : Float(Double(v) / 4_294_967_295)
      }
    case (GL_DEPTH_COMPONENT, GL_UNSIGNED_SHORT, .depth32f):
      let d = unsafe (destination + y * width * 4).assumingMemoryBound(to: Float.self)
      for x in 0..<width { unsafe d[x] = Float(row.loadUnaligned(fromByteOffset: x * 2, as: UInt16.self)) / 65535 }
    case (GL_DEPTH_COMPONENT, GL_UNSIGNED_INT, .depth16):
      let d = unsafe (destination + y * width * 2).assumingMemoryBound(to: UInt16.self)
      for x in 0..<width { unsafe d[x] = UInt16(row.loadUnaligned(fromByteOffset: x * 4, as: UInt32.self) >> 16) }
    case (_, _, .depth24stencil8), (_, _, .depth16), (_, _, .depth32f), (_, _, .stencil8), (_, _, .depth32fstencil8):
      let bytes = deviceFormat.texelBlock.bytes
      unsafe (destination + y * width * bytes).copyMemory(from: row, byteCount: width * min(bytes, 4))
    default:
      let o = unsafe out + y * width * 4
      switch (format, type) {
      case (GL_RGBA, GL_UNSIGNED_BYTE): unsafe UnsafeMutableRawPointer(o).copyMemory(from: row, byteCount: width * 4)
      case (GL_BGRA_EXT, GL_UNSIGNED_BYTE):
        for x in 0..<width {
          unsafe o[4 * x] = b[4 * x + 2]
          unsafe o[4 * x + 1] = b[4 * x + 1]
          unsafe o[4 * x + 2] = b[4 * x]
          unsafe o[4 * x + 3] = b[4 * x + 3]
        }
      case (GL_RGB, GL_UNSIGNED_BYTE):
        for x in 0..<width {
          unsafe o[4 * x] = b[3 * x]
          unsafe o[4 * x + 1] = b[3 * x + 1]
          unsafe o[4 * x + 2] = b[3 * x + 2]
          unsafe o[4 * x + 3] = 255
        }
      case (GL_LUMINANCE, GL_UNSIGNED_BYTE):
        for x in 0..<width {
          let l = unsafe b[x]
          unsafe o[4 * x] = l
          unsafe o[4 * x + 1] = l
          unsafe o[4 * x + 2] = l
          unsafe o[4 * x + 3] = 255
        }
      case (GL_ALPHA, GL_UNSIGNED_BYTE):
        for x in 0..<width {
          unsafe o[4 * x] = 0
          unsafe o[4 * x + 1] = 0
          unsafe o[4 * x + 2] = 0
          unsafe o[4 * x + 3] = b[x]
        }
      case (GL_LUMINANCE_ALPHA, GL_UNSIGNED_BYTE):
        for x in 0..<width {
          let l = unsafe b[2 * x]
          unsafe o[4 * x] = l
          unsafe o[4 * x + 1] = l
          unsafe o[4 * x + 2] = l
          unsafe o[4 * x + 3] = b[2 * x + 1]
        }
      case (GL_RGB, GL_UNSIGNED_SHORT_5_6_5):
        for x in 0..<width {
          let v = UInt32(unsafe row.loadUnaligned(fromByteOffset: 2 * x, as: UInt16.self))
          unsafe o[4 * x] = expand5(v >> 11)
          unsafe o[4 * x + 1] = expand6((v >> 5) & 63)
          unsafe o[4 * x + 2] = expand5(v & 31)
          unsafe o[4 * x + 3] = 255
        }
      case (GL_RGBA, GL_UNSIGNED_SHORT_4_4_4_4):
        for x in 0..<width {
          let v = UInt32(unsafe row.loadUnaligned(fromByteOffset: 2 * x, as: UInt16.self))
          unsafe o[4 * x] = expand4(v >> 12)
          unsafe o[4 * x + 1] = expand4((v >> 8) & 15)
          unsafe o[4 * x + 2] = expand4((v >> 4) & 15)
          unsafe o[4 * x + 3] = expand4(v & 15)
        }
      case (GL_RGBA, GL_UNSIGNED_SHORT_5_5_5_1):
        for x in 0..<width {
          let v = UInt32(unsafe row.loadUnaligned(fromByteOffset: 2 * x, as: UInt16.self))
          unsafe o[4 * x] = expand5(v >> 11)
          unsafe o[4 * x + 1] = expand5((v >> 6) & 31)
          unsafe o[4 * x + 2] = expand5((v >> 1) & 31)
          unsafe o[4 * x + 3] = v & 1 == 1 ? 255 : 0
        }
      default:
        unsafe UnsafeMutableRawPointer(o).initializeMemory(as: UInt8.self, repeating: 0, count: width * 4)
      }
    }
  }
}

/// Writes `height` rows of `width` device texels (rgba8, or bgra8 where `bgra`), `sourceRowBytes` apart, as GL's RGBA
/// and UNSIGNED_BYTE rows `rowBytes` apart at `destination`, the last source row first where `flip` (a window's image,
/// whose first row is the top), alpha 255 where `opaque`.
func readBack(_ source: UnsafeRawPointer, sourceRowBytes: Int, width: Int, height: Int, bgra: Bool, flip: Bool, opaque: Bool,
              into destination: UnsafeMutableRawPointer, rowBytes: Int) {
  for y in 0..<height {
    let s = unsafe (source + (flip ? height - 1 - y : y) * sourceRowBytes).assumingMemoryBound(to: UInt8.self)
    let d = unsafe (destination + y * rowBytes).assumingMemoryBound(to: UInt8.self)
    if !bgra && !opaque {
      unsafe UnsafeMutableRawPointer(d).copyMemory(from: UnsafeRawPointer(s), byteCount: width * 4)
      continue
    }
    for x in 0..<width {
      unsafe d[4 * x] = bgra ? s[4 * x + 2] : s[4 * x]
      unsafe d[4 * x + 1] = s[4 * x + 1]
      unsafe d[4 * x + 2] = bgra ? s[4 * x] : s[4 * x + 2]
      unsafe d[4 * x + 3] = opaque ? 255 : s[4 * x + 3]
    }
  }
}

// MARK: Vertex attributes

/// The bytes one component of a vertex attribute of GL `type` takes; nil for a type an attribute can't be.
func attributeComponentBytes(_ type: GLenum) -> Int? {
  switch type {
  case GL_BYTE, GL_UNSIGNED_BYTE: 1
  case GL_SHORT, GL_UNSIGNED_SHORT: 2
  case GL_FLOAT, GL_FIXED: 4
  default: nil
  }
}

/// The lowering's format for an attribute the shader can read straight from its buffer: `size` floats, or four
/// normalized unsigned bytes; nil for one that is converted to floats first.
func nativeVertexFormat(size: Int, type: GLenum, normalized: Bool) -> VertexFormat? {
  if type == GL_FLOAT {
    switch size {
    case 1: return .r32Float
    case 2: return .rg32Float
    case 3: return .rgb32Float
    default: return .rgba32Float
    }
  }
  if type == GL_UNSIGNED_BYTE && normalized && size == 4 { return .rgba8Unorm }
  return nil
}

func floatVertexFormat(_ size: Int) -> VertexFormat {
  switch size {
  case 1: .r32Float
  case 2: .rg32Float
  case 3: .rgb32Float
  default: .rgba32Float
  }
}

/// Converts `count` vertices of an attribute (`size` components of `type`, `stride` bytes apart, from `source`) to
/// tightly packed 32-bit floats at `destination`, normalized as GL ES 2.0's table 2.7 says where `normalized`.
func convertAttribute(_ source: UnsafeRawPointer, count: Int, size: Int, type: GLenum, normalized: Bool, stride: Int,
                      into destination: UnsafeMutableRawPointer) {
  let out = unsafe destination.assumingMemoryBound(to: Float.self)
  for v in 0..<count {
    let p = unsafe source + v * stride
    for c in 0..<size {
      let f: Float
      switch type {
      case GL_BYTE:
        let x = Float(unsafe p.load(fromByteOffset: c, as: Int8.self))
        f = normalized ? (2 * x + 1) / 255 : x
      case GL_UNSIGNED_BYTE:
        let x = Float(unsafe p.load(fromByteOffset: c, as: UInt8.self))
        f = normalized ? x / 255 : x
      case GL_SHORT:
        let x = Float(unsafe p.loadUnaligned(fromByteOffset: 2 * c, as: Int16.self))
        f = normalized ? (2 * x + 1) / 65535 : x
      case GL_UNSIGNED_SHORT:
        let x = Float(unsafe p.loadUnaligned(fromByteOffset: 2 * c, as: UInt16.self))
        f = normalized ? x / 65535 : x
      case GL_FIXED: f = Float(unsafe p.loadUnaligned(fromByteOffset: 4 * c, as: Int32.self)) / 65536
      default: f = unsafe p.loadUnaligned(fromByteOffset: 4 * c, as: Float.self)
      }
      unsafe out[v * size + c] = f
    }
  }
}
