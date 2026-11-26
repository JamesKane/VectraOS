// SPDX-License-Identifier: BSD-3-Clause

// The GLSL ES front end (graphics/glsl, glsl(2)) as the library's `ShaderFrontEnd`. Its programs map GL's clip space
// themselves (clip control .gl), and their uniform block begins with the 32 bytes of driver words the library writes
// before each draw (Draw.swift).

import GLSL

final class GLSLFrontEnd: ShaderFrontEnd {
  func compile(source: [UInt8], fragment: Bool) -> (shader: Any?, log: String) {
    switch GLSL.compile(source: source, stage: fragment ? .fragment : .vertex) {
    case .success(let s): return (s, s.log)
    case .failure(let e): return (nil, e.log)
    }
  }

  func link(vertex: Any, fragment: Any, attributeBindings: [(name: String, location: UInt32)]) -> Result<ProgramInterface, LinkFailure> {
    guard let v = vertex as? GLSLShader, let f = fragment as? GLSLShader else { return .failure(LinkFailure(log: "not GLSL shaders")) }
    let p: GLSLProgram
    do throws(GLSLError) { p = try GLSL.link(vertex: v, fragment: f, attributeBindings: attributeBindings) } catch {
      return .failure(LinkFailure(log: error.log))
    }
    let attributes = p.attributes.map { ActiveAttribute(name: $0.name, type: $0.type, arraySize: $0.arraySize, location: $0.location) }
    let uniforms = p.uniforms.map {
      ActiveUniform(name: $0.name, type: $0.type, arraySize: $0.arraySize, offset: $0.offset, arrayStride: $0.arrayStride,
                    matrixStride: $0.matrixStride, samplerBinding: $0.binding >= 0 ? UInt32($0.binding) : nil)
    }
    var i = ProgramInterface(vertexSPIRV: p.vertexSPIRV, fragmentSPIRV: p.fragmentSPIRV, attributes: attributes, uniforms: uniforms,
                             uniformBlockBytes: p.uniformBlockBytes, log: p.log, glClipSpace: false)
    i.driverWords = p.driverBlockOffset
    return .success(i)
  }
}

func defaultFrontEnd() -> (any ShaderFrontEnd)? { GLSLFrontEnd() }
