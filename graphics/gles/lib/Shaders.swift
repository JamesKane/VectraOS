// SPDX-License-Identifier: BSD-3-Clause

// Shader and program objects (gles(3), "Shaders"). A shader is GLSL ES source the front end compiles, or SPIR-V given
// as a binary; a program links two of the same kind into a `ProgramInterface`. The program keeps its default uniform
// block on the CPU (`block`), which glUniform* writes and each draw that finds it changed copies into the frame's
// upload memory; sampler uniforms are texture units, which a draw turns into heap slots. A program's stages are lowered
// once for its fragment stage and once for each vertex layout it is drawn with, and its pipelines are kept by the state
// they were made for (Draw.swift).

import GPUCore
import VulkanLowering

/// What compiles and links GLSL ES for the library: the GLSL front end (GLSLFrontEnd.swift, where the module is built),
/// or a test's.
public protocol ShaderFrontEnd: AnyObject {
  /// A compiled shader (the front end's own value) and its log, or nil and the log of what was wrong.
  func compile(source: [UInt8], fragment: Bool) -> (shader: Any?, log: String)
  /// The program two compiled shaders link to, with the attributes bound where the application said.
  func link(vertex: Any, fragment: Any, attributeBindings: [(name: String, location: UInt32)]) -> Result<ProgramInterface, LinkFailure>
}

public struct LinkFailure: Error {
  public var log: String
  public init(log: String) { self.log = log }
}

/// The front end GL's shaders compile with; nil, and glCompileShader fails saying there is none.
public nonisolated(unsafe) var shaderFrontEnd: (any ShaderFrontEnd)? = defaultFrontEnd()

final class GLShader {
  let name: GLuint
  let type: GLenum
  var source: [UInt8] = []
  var compiled: Any?
  /// SPIR-V given by glShaderBinary.
  var binary: [UInt32]?
  var compileStatus = false
  var log = ""
  var deletePending = false
  /// The programs it is attached to.
  var attachments = 0
  init(name: GLuint, type: GLenum) {
    self.name = name
    self.type = type
  }
  var isFragment: Bool { type == GL_FRAGMENT_SHADER }
}

/// One location of a uniform: which uniform, and which element of it.
struct UniformLocation {
  var uniform: Int
  var element: Int
}

/// A program's lowered vertex stage, by the vertex layout it was lowered against.
struct LoweredVertex {
  var layout: VertexLayout
  var bytes: [UInt8]
}

/// What a draw reads of a program's attributes: for each location the program has (in `locations`), the format and the
/// stride of the root-block vertex buffer it reads, which the vertex stage is lowered against.
struct VertexLayout: Hashable {
  var formats: [UInt8]
  var strides: [UInt32]
}

@safe final class GLProgram {
  let name: GLuint
  var vertexShader: GLShader?
  var fragmentShader: GLShader?
  var bindings: [(name: String, location: UInt32)] = []
  var linkStatus = false
  var validateStatus = false
  var log = ""
  var deletePending = false
  /// Bumps at each successful link: a pipeline keyed by an older link is never used.
  var linkSerial: UInt64 = 0

  // What the last successful link made.
  var interface = ProgramInterface(vertexSPIRV: [], fragmentSPIRV: [], attributes: [], uniforms: [], uniformBlockBytes: 0)
  var locations: [UniformLocation] = []
  /// The first location of each uniform.
  var firstLocation: [Int] = []
  /// The uniform block, as glUniform* leaves it.
  var block: UnsafeMutableRawPointer?
  var blockBytes = 0
  /// The block's copy in the frame's upload memory, valid while `blockStamp` is the ring's.
  var blockAddress: UInt64 = 0
  var blockStamp: UInt64 = 0
  var blockDirty = true
  /// The texture unit of each sampler binding's element: `samplerUnits[i]` is binding `samplerBindings[i]`'s.
  var samplerBindings: [UInt32] = []
  var samplerIsCube: [Bool] = []
  var samplerUnits: [Int32] = []
  /// The vertex stage's input locations, in the order a draw fills them.
  var attributeLocations: [UInt32] = []
  var attributeComponents: [Int] = []
  // Lowering and pipelines.
  var setLayout = SetLayout(bindings: [])
  var lowering = LoweringLayout()
  var fragmentBytes: [UInt8] = []
  var vertexBytes: [LoweredVertex] = []
  var vertexWords: [UInt32] = []
  var pipelines: [PipelineKey: GPUPipeline] = [:]

  init(name: GLuint) { self.name = name }
  deinit { unsafe block?.deallocate() }

  func uniformLocation(_ name: String) -> GLint {
    // "a", "a[0]" and "a[i]" of an array; "s.m" of a structure.
    var base = name
    var index = 0
    if name.last == "]", let open = name.lastIndex(of: "[") {
      let digits = name[name.index(after: open)..<name.index(before: name.endIndex)]
      guard let i = Int(digits), i >= 0 else { return -1 }
      index = i
      base = String(name[..<open])
    }
    for (u, uniform) in interface.uniforms.enumerated() {
      let n = uniform.name
      let plain = n.hasSuffix("[0]") ? String(n.dropLast(3)) : n
      if plain == base || (index == 0 && n == name) {
        guard index < uniform.arraySize else { return -1 }
        if index > 0 && !n.hasSuffix("[0]") { return -1 }
        return GLint(firstLocation[u] + index)
      }
    }
    return -1
  }

  /// Takes what a link made: the uniforms' locations, a zeroed block, the samplers at unit 0, the layout the stages are
  /// lowered against.
  func install(_ i: ProgramInterface) throws(LoweringError) {
    interface = i
    locations = []
    firstLocation = []
    for (u, uniform) in i.uniforms.enumerated() {
      firstLocation.append(locations.count)
      for e in 0..<max(uniform.arraySize, 1) { locations.append(UniformLocation(uniform: u, element: e)) }
    }
    unsafe block?.deallocate()
    blockBytes = align(max(i.uniformBlockBytes, 16), 16)
    unsafe block = UnsafeMutableRawPointer.allocate(byteCount: blockBytes, alignment: 16)
    unsafe block!.initializeMemory(as: UInt8.self, repeating: 0, count: blockBytes)
    blockDirty = true
    blockStamp = 0
    samplerBindings = []
    samplerIsCube = []
    var bindings = [DescriptorBinding(binding: 0, kind: .uniformBuffer)]
    for u in i.uniforms {
      guard let b = u.samplerBinding else { continue }
      bindings.append(DescriptorBinding(binding: b, kind: .combinedImageSampler, count: UInt32(max(u.arraySize, 1))))
      for e in 0..<max(u.arraySize, 1) {
        samplerBindings.append(b + UInt32(e))
        samplerIsCube.append(u.type == GL_SAMPLER_CUBE)
      }
    }
    samplerUnits = [Int32](repeating: 0, count: samplerBindings.count)
    setLayout = SetLayout(bindings: bindings)
    lowering = LoweringLayout(sets: [setLayout])
    attributeLocations = []
    attributeComponents = []
    for a in i.attributes.sorted(by: { $0.location < $1.location }) {
      // A matrix is a column at each location from its own.
      let columns = a.type == GL_FLOAT_MAT2 ? 2 : a.type == GL_FLOAT_MAT3 ? 3 : a.type == GL_FLOAT_MAT4 ? 4 : 1
      for c in 0..<columns {
        attributeLocations.append(a.location + UInt32(c))
        attributeComponents.append(columns > 1 ? columns : componentCount(a.type))
      }
    }
    vertexWords = i.vertexSPIRV
    fragmentBytes = try bytes(lower(spirv: i.fragmentSPIRV, stage: .fragment, entryPoint: "main", layout: lowering))
    vertexBytes = []
    pipelines = [:]
  }

  /// The vertex stage lowered against `layout`: found, or lowered now.
  func vertexStage(_ layout: VertexLayout) throws(LoweringError) -> [UInt8] {
    for v in vertexBytes where v.layout == layout { return v.bytes }
    var l = lowering
    for (n, location) in attributeLocations.enumerated() {
      l.vertexBindings.append(VertexBinding(binding: location, stride: layout.strides[n]))
      l.vertexAttributes.append(VertexAttribute(location: location, binding: location,
                                                format: vertexFormat(code: layout.formats[n]), offset: 0))
    }
    let b = try bytes(lower(spirv: vertexWords, stage: .vertex, entryPoint: "main", layout: l))
    vertexBytes.append(LoweredVertex(layout: layout, bytes: b))
    return b
  }

  /// The texture unit sampler element `n` reads.
  func unit(_ n: Int) -> Int { Int(samplerUnits[n]) }
}

func bytes(_ words: [UInt32]) -> [UInt8] {
  var out = [UInt8](repeating: 0, count: words.count * 4)
  for (i, w) in words.enumerated() {
    out[4 * i] = UInt8(truncatingIfNeeded: w)
    out[4 * i + 1] = UInt8(truncatingIfNeeded: w >> 8)
    out[4 * i + 2] = UInt8(truncatingIfNeeded: w >> 16)
    out[4 * i + 3] = UInt8(truncatingIfNeeded: w >> 24)
  }
  return out
}

/// The vertex formats as a draw's layout keeps them, one byte each.
let vertexFormatCodes: [VertexFormat] = [.r32Float, .rg32Float, .rgb32Float, .rgba32Float, .rgba8Unorm]
func vertexFormat(code: UInt8) -> VertexFormat { vertexFormatCodes[Int(code)] }
func vertexFormatCode(_ f: VertexFormat) -> UInt8 {
  switch f {
  case .r32Float: 0
  case .rg32Float: 1
  case .rgb32Float: 2
  case .rgba32Float: 3
  default: 4
  }
}

// MARK: Linking

extension GLProgram {
  /// Links the attached shaders: the front end's link of two GLSL shaders, or `reflect` of two binaries.
  func link() {
    linkStatus = false
    validateStatus = false
    guard let v = vertexShader, let f = fragmentShader else {
      log = "a program needs a vertex and a fragment shader attached"
      return
    }
    guard v.compileStatus, f.compileStatus else {
      log = "a shader attached didn't compile"
      return
    }
    var made: ProgramInterface
    if let vb = v.binary, let fb = f.binary {
      do throws(ReflectError) { made = try reflect(vertex: vb, fragment: fb) } catch {
        log = "the binaries' interface: \(error)"
        return
      }
    } else if let vc = v.compiled, let fc = f.compiled, let frontEnd = unsafe shaderFrontEnd {
      switch frontEnd.link(vertex: vc, fragment: fc, attributeBindings: bindings) {
      case .success(let p): made = p
      case .failure(let e):
        log = e.log
        return
      }
    } else {
      log = "a program of a GLSL shader and a binary"
      return
    }
    for a in made.attributes where a.location >= UInt32(maxVertexAttribs) {
      log = "the attribute \(a.name) is at location \(a.location), past the \(maxVertexAttribs) the library has"
      return
    }
    if made.glClipSpace {
      do throws(ReflectError) { made.vertexSPIRV = try coreClipSpace(made.vertexSPIRV) } catch {
        log = "the vertex stage's clip space: \(error)"
        return
      }
    }
    do throws(LoweringError) { try install(made) } catch {
      log = "the program can't be lowered for the device: \(error)"
      return
    }
    log = made.log
    linkStatus = true
    linkSerial &+= 1
  }
}
