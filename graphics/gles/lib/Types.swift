// SPDX-License-Identifier: BSD-3-Clause

// OpenGL ES 2.0 and EGL over the core (D183; gles(3), egl(3)). This module is the GL state machine in Swift on
// `GPUDevice` and `GPUQueue`, as the Vulkan layer is, and EGL's displays, configs, surfaces and contexts over a
// platform that opens the device and the windows (native/Platform.swift: Radharc's; hosted, a test's). The C names
// (`gl*`, `egl*`) are Exports.swift's and ExportsEGL.swift's, called by the C entry points in c/.
//
// The pieces:
//   Types.swift      GL's C types, and the errors
//   Objects.swift    buffers, textures, renderbuffers, framebuffers, vertex arrays and the share group
//   Shaders.swift    shader and program objects, the front end (GLSL, or SPIR-V given as a binary), uniforms
//   Spirv.swift      the SPIR-V a program arrives as: its interface read, and GL's clip space made the core's
//   Pixels.swift     GL's pixel formats and types to the device's, and back; vertex formats
//   Frame.swift      the frame: the upload ring, the open list and pass, the heap's slots, submission
//   Context.swift    a context's state and its calls
//   Draw.swift       draws: vertex input, the root block, pipelines by state
//   Queries.swift    Get*, IsEnabled and GetString
//   EGL.swift        EGL
// A context is used by one thread at a time; the current one is the process's (not per thread).

import GPUCore

public typealias GLenum = UInt32
public typealias GLboolean = UInt8
public typealias GLbitfield = UInt32
public typealias GLint = Int32
public typealias GLsizei = Int32
public typealias GLuint = UInt32
public typealias GLfloat = Float
public typealias GLclampf = Float
public typealias GLfixed = Int32
public typealias GLintptr = Int
public typealias GLsizeiptr = Int
public typealias GLchar = CChar
public typealias GLubyte = UInt8

public typealias EGLint = Int32
public typealias EGLBoolean = UInt32
public typealias EGLenum = UInt32
public typealias EGLAttrib = Int

/// What a GL call records when it fails (the spec's errors): the first since the last `glGetError` is kept.
public enum GLErrorCode: GLenum, Error {
  case invalidEnum = 0x0500
  case invalidValue = 0x0501
  case invalidOperation = 0x0502
  case outOfMemory = 0x0505
  case invalidFramebufferOperation = 0x0506
}

/// A device's or the library's message, where one is listened to (egl(3), ENVIRONMENT): what was refused and why.
public nonisolated(unsafe) var glesLog: ((String) -> Void)? = nil

func say(_ text: String) { unsafe glesLog?("gles: " + text) }

extension GLboolean {
  var isTrue: Bool { self != 0 }
}

extension Bool {
  var gl: GLboolean { self ? 1 : 0 }
  var egl: EGLBoolean { self ? 1 : 0 }
}

/// Rounds `value` up to a multiple of `alignment` (a power of two).
@inline(__always) func align(_ value: Int, _ alignment: Int) -> Int { (value + alignment - 1) & ~(alignment - 1) }

/// The number of mip levels a full chain of a `width` by `height` image has.
func fullMipCount(_ width: Int32, _ height: Int32) -> UInt32 {
  let largest = max(width, height, 1)
  return UInt32(Int32.bitWidth - largest.leadingZeroBitCount)
}

func isPowerOfTwo(_ v: Int32) -> Bool { v > 0 && v & (v - 1) == 0 }

/// egl.h's constants that are casts, which the generated file leaves out.
public let EGL_DONT_CARE: EGLint = -1
public let EGL_UNKNOWN: EGLint = -1
