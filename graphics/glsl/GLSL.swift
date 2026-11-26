// SPDX-License-Identifier: BSD-3-Clause

// The GLSL ES 1.00 front end (D183): what the GLES library calls. `compile` preprocesses, parses and checks one
// shader; `link` matches a vertex and a fragment shader's interfaces, lays out the uniforms and the attributes, and
// emits each stage's Vulkan-style SPIR-V (CodeGen.swift), which vulkanlowering(2) puts on the core and the device's
// compiler takes from there.

public enum GLSLStage: Sendable { case vertex, fragment }

/// A failed compile or link: GL's info log.
public struct GLSLError: Error, Sendable {
  public var log: String
  public init(log: String) { self.log = log }
}

/// The implementation's limits, which the built-in constants report and the link enforces. The defaults are GL ES
/// 2.0's minimums, but for the vertex textures (the core samples in any stage).
public struct GLSLLimits: Sendable {
  public var maxVertexAttribs = 8
  public var maxVertexUniformVectors = 256
  public var maxVaryingVectors = 15
  public var maxVertexTextureImageUnits = 16
  public var maxCombinedTextureImageUnits = 32
  public var maxTextureImageUnits = 16
  public var maxFragmentUniformVectors = 256
  public var maxDrawBuffers = 1
  public init() {}
}

/// A compiled shader: the checked program inside, and the compile's log (its warnings).
public struct GLSLShader: Sendable {
  public var stage: GLSLStage
  public var log: String
  var program: Program
}

/// Compiles one shader's source: a result whatever happens, as glCompileShader always has a log; on failure the
/// error's log says why.
public func compile(source: [UInt8], stage: GLSLStage, limits: GLSLLimits = GLSLLimits()) -> Result<GLSLShader, GLSLError> {
  var lexer = Lexer(source, diags: Diagnostics())
  let (tokens, d0) = lexer.run()
  var pp = Preprocessor(stage: stage, diags: d0)
  let r = pp.run(tokens)
  var parser = Parser(
    tokens: r.tokens, stage: stage, diags: r.diags, limits: limits, derivatives: r.derivatives, invariantAll: r.invariantAll)
  if r.diags.errors == 0 {
    do throws(SyntaxError) {
      try parser.translationUnit()
      parser.finish()
    } catch {}
  }
  if parser.diags.errors > 0 { return .failure(GLSLError(log: parser.diags.log)) }
  return .success(GLSLShader(stage: stage, log: parser.diags.log, program: parser.prog))
}

/// A vertex attribute the program reads (glGetActiveAttrib's view) and the location it has.
public struct ActiveAttribute: Sendable, Equatable {
  public var name: String
  /// GL's enum: GL_FLOAT (0x1406), GL_FLOAT_VEC2 to 4 (0x8B50 to 0x8B52), GL_FLOAT_MAT2 to 4 (0x8B5A to 0x8B5C).
  public var type: UInt32
  public var arraySize: Int
  /// The first location; a matrix takes one a column, at `location` up (each column a vector input of its own).
  public var location: UInt32
}

/// A uniform the program uses (glGetActiveUniform's view, one an array or a leaf of a structure: `s.m`, `a[0]`), and
/// where it lives.
public struct ActiveUniform: Sendable, Equatable {
  /// An array's name ends in `[0]`.
  public var name: String
  /// GL's enum: GL_FLOAT, GL_FLOAT_VEC2..4, GL_INT (0x1404), GL_INT_VEC2..4 (0x8B53..), GL_BOOL (0x8B56),
  /// GL_BOOL_VEC2..4 (0x8B57..), GL_FLOAT_MAT2..4 (0x8B5A..), GL_SAMPLER_2D (0x8B5E), GL_SAMPLER_CUBE (0x8B60).
  public var type: UInt32
  /// 1 for a uniform that is not an array.
  public var arraySize: Int
  /// A sampler's binding (set 0; element i of an array at `binding + i`); -1 for the rest.
  public var binding: Int
  /// The rest: the byte offset in the uniform block (set 0, binding 0, std140), the stride of an array's elements
  /// (0 for one that is not an array) and of a matrix's columns (16; 0 for a non-matrix). An int or a bool is a 32-bit
  /// word (a bool 0 or 1), a float a binary32.
  public var offset: Int
  public var arrayStride: Int
  public var matrixStride: Int
  public var isSampler: Bool { binding >= 0 }
}

/// A varying the two stages share, and the location the link gave it.
public struct LinkedVarying: Sendable, Equatable {
  public var name: String
  public var type: UInt32
  public var arraySize: Int
  /// The first location; each column of a matrix and each element of an array takes the next.
  public var location: UInt32
}

/// How the vertex stage's position reaches the core, which takes Vulkan's clip space.
public enum GLSLClipControl: Sendable {
  /// GL's: the vertex stage's epilogue maps GL's clip-space z (-w to w) onto Vulkan's (0 to w), z' = (z + w) / 2, and
  /// multiplies y by the driver block's `positionYScale`; the fragment stage's gl_FragCoord.y and gl_PointCoord.y
  /// follow the block's words (see `GLSLProgram.driverBlockOffset`).
  case gl
  /// Nothing changed: the program's gl_Position, gl_FragCoord and gl_PointCoord are Vulkan's.
  case vulkan
}

public struct GLSLLinkOptions: Sendable {
  public var clipControl: GLSLClipControl = .gl
  public var limits = GLSLLimits()
  /// The SPIR-V entry points' name.
  public var entryPoint = "main"
  public init() {}
}

/// A linked program: each stage's SPIR-V and the interfaces the GLES library binds.
public struct GLSLProgram: Sendable {
  public var vertexSPIRV: [UInt32]
  public var fragmentSPIRV: [UInt32]
  public var attributes: [ActiveAttribute]
  public var uniforms: [ActiveUniform]
  public var varyings: [LinkedVarying]
  /// The uniform block's size in bytes (a multiple of 16): set 0, binding 0, one uniform buffer both stages read.
  public var uniformBlockBytes: Int
  /// Where the driver's words are in the uniform block (with clip control .gl), 32 bytes the GLES library writes:
  ///   +0  float positionYScale   1 to keep GL's y (an image read back bottom row first, as glReadPixels does), -1 to
  ///                              flip it (an image presented top row first)
  ///   +4  float fragCoordYScale  gl_FragCoord.y = fragCoordYScale * y + fragCoordYOffset (y the core's, from the top):
  ///   +8  float fragCoordYOffset   1 and 0 when positionYScale is 1, -1 and the framebuffer's height when it is -1
  ///   +12 float pointCoordYScale gl_PointCoord.y = 0.5 + pointCoordYScale * (y - 0.5): -1 when positionYScale is 1
  ///   +16 float depthRangeNear   gl_DepthRange.near, .far and .diff (glDepthRangef's)
  ///   +20 float depthRangeFar
  ///   +24 float depthRangeDiff
  /// Always 0: the block always begins with them (the program's own uniforms from offset 32).
  public var driverBlockOffset: Int
  /// The highest sampler binding plus one (bindings 1 to this less one are combined image samplers).
  public var samplerBindings: Int
  public var log: String
}
