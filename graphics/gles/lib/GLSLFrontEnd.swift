// SPDX-License-Identifier: BSD-3-Clause

// The GLSL ES front end (graphics/glsl, module GLSL) as the library's `ShaderFrontEnd`, where the module is built; where
// it isn't, there is no front end and shaders come as SPIR-V (glShaderBinary).

#if canImport(GLSL)
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
    do { p = try GLSL.link(vertex: v, fragment: f, attributeBindings: attributeBindings) } catch {
      return .failure(LinkFailure(log: error.log))
    }
    let attributes = p.attributes.map { ActiveAttribute(name: $0.name, type: $0.type, arraySize: $0.arraySize, location: $0.location) }
    let uniforms = p.uniforms.map {
      ActiveUniform(name: $0.name, type: $0.type, arraySize: $0.arraySize, offset: $0.offset, arrayStride: $0.arrayStride,
                    matrixStride: $0.matrixStride, samplerBinding: $0.samplerBinding)
    }
    return .success(ProgramInterface(vertexSPIRV: p.vertexSPIRV, fragmentSPIRV: p.fragmentSPIRV, attributes: attributes,
                                     uniforms: uniforms, uniformBlockBytes: p.uniformBlockBytes, log: p.log, glClipSpace: true))
  }
}

func defaultFrontEnd() -> (any ShaderFrontEnd)? { GLSLFrontEnd() }
#else
func defaultFrontEnd() -> (any ShaderFrontEnd)? { nil }
#endif
