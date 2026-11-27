// SPDX-License-Identifier: BSD-3-Clause

// Running one stage of a small program on the IR interpreter: a fragment shader with given varyings and uniforms, or a
// vertex shader with given attributes; the results of every IR variant (as lowered, optimised, scalarised).

@testable import GLSL
import ShaderCompiler
import ShaderTestKit
import Testing

/// A varying's declaration ("vec3 n") and the value the fragment shader receives (column by column).
struct Varying {
  var decl: String
  var value: [Float]
  var name: String { String(decl.split(separator: " ").last!) }
  var type: String { String(decl.split(separator: " ").dropLast().last!) }
}

/// The fragment shader's gl_FragColor (or gl_FragData[0]) in every IR variant.
func runFragment(
  _ fs: String, varyings: [Varying] = [], uniforms: (inout UniformBlock) -> Void = { _ in }, fragCoord: [Float] = [0.5, 0.5, 0.5, 1],
  options: GLSLLinkOptions = GLSLLinkOptions(), flip: Bool = false, height: Float = 0, texel: ((UInt64, [Float], Int) -> Float)? = nil
) throws -> [[Float]] {
  var vs = "attribute vec4 p;\n"
  for v in varyings { vs += "varying \(v.decl);\n" }
  vs += "void main() {\n  gl_Position = p;\n"
  for v in varyings { vs += "  \(v.name) = \(v.type)(0.0);\n" }
  vs += "}\n"
  let p = try linkProgram(vs, fs, options: options)
  var block = UniformBlock(p, flip: flip, height: height)
  uniforms(&block)
  var inputs: [Int: [Float]] = [:]
  for v in varyings {
    guard let l = p.varyings.first(where: { $0.name == v.name }) else { continue }
    let (cols, rows) = columnComponents(l.type)
    for c in 0..<(cols * l.arraySize) { inputs[Int(l.location) + c] = Array(v.value[(c * rows)..<((c + 1) * rows)]) }
  }
  var out: [[Float]] = []
  for (name, ir) in try lowerAndCompile(p, .fragment) {
    let m = try run(ir, p, block: block, inputs: inputs, fragCoord: fragCoord, texel: texel)
    guard let o = output(m, ir, location: 0) else { throw TestFailure("\(name): no gl_FragColor") }
    out.append(o)
  }
  return out
}

/// The value of one expression of a fragment shader, as gl_FragColor's first components.
func evaluate(_ expr: String, components: Int = 4, varyings: [Varying] = [], prelude: String = "", derivatives: Bool = false) throws -> [[Float]] {
  var fs = derivatives ? "#extension GL_OES_standard_derivatives : enable\n" : ""
  fs += "precision highp float;\n"
  for v in varyings { fs += "varying \(v.decl);\n" }
  fs += prelude + "\nvoid main() {\n"
  switch components {
  case 1: fs += "  gl_FragColor = vec4(\(expr), 0.0, 0.0, 0.0);\n"
  case 2: fs += "  gl_FragColor = vec4(\(expr), 0.0, 0.0);\n"
  case 3: fs += "  gl_FragColor = vec4(\(expr), 0.0);\n"
  default: fs += "  gl_FragColor = vec4(\(expr));\n"
  }
  fs += "}\n"
  return try runFragment(fs, varyings: varyings).map { Array($0.prefix(components)) }
}

/// A vertex shader's position and varyings (by name) in every IR variant, attributes given by name.
func runVertex(
  _ vs: String, fs: String, attributes: [String: [Float]], uniforms: (inout UniformBlock) -> Void = { _ in },
  options: GLSLLinkOptions = GLSLLinkOptions(), flip: Bool = false
) throws -> [(position: [Float], varyings: [String: [Float]])] {
  let p = try linkProgram(vs, fs, options: options)
  var block = UniformBlock(p, flip: flip)
  uniforms(&block)
  let (_, offsets, stride) = loweringLayout(p)
  var vb = [UInt8](repeating: 0, count: Int(stride))
  for a in p.attributes {
    guard let v = attributes[a.name] else { continue }
    let (cols, rows) = columnComponents(a.type)
    for c in 0..<cols {
      let off = Int(offsets[a.location + UInt32(c)]!)
      for r in 0..<rows where c * rows + r < v.count { put32(&vb, off + 4 * r, v[c * rows + r].bitPattern) }
    }
  }
  var out: [(position: [Float], varyings: [String: [Float]])] = []
  for (name, ir) in try lowerAndCompile(p, .vertex) {
    let m = try run(ir, p, block: block, vertexBytes: vb)
    guard let pos = output(m, ir, location: -1) else { throw TestFailure("\(name): no position") }
    var vars: [String: [Float]] = [:]
    for l in p.varyings {
      let (cols, _) = columnComponents(l.type)
      var v: [Float] = []
      for c in 0..<(cols * l.arraySize) { v += output(m, ir, location: Int(l.location) + c) ?? [] }
      vars[l.name] = v
    }
    out.append((pos, vars))
  }
  return out
}

/// Every variant gave `want` (within a relative tolerance).
func expectAll(_ got: [[Float]], _ want: [Float], tolerance: Float = 1e-5, _ what: String, sourceLocation: Testing.SourceLocation = #_sourceLocation) {
  for (i, g) in got.enumerated() {
    #expect(close(g, want, tolerance), "\(what) [\(["lowered", "optimized", "scalarised"][min(i, 2)])]: got \(g), wanted \(want)", sourceLocation: sourceLocation)
  }
}
