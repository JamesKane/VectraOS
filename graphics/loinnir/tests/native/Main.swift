// SPDX-License-Identifier: BSD-3-Clause

// bin/loinnir-test (boot-venus, D121; the board's, D174 section 5): Loinnir's
// draw tests on the device, on the core of whichever GPU is offered: through
// our loader, the Venus client driver and the GPU class to virtio-gpu's driver
// host on the host's GPU, or on the board through the native Mali driver
// (graphics/loinnir/tests' DrawTests, as a native program).
// A triangle drawn through the root pointer, a texture sampled from the
// bindless heap by index, and the
// timeline; each read back through host-visible memory. The shaders are
// tests/native/generated's copies.

import GPUClient
import Loinnir
import Node
import Sys

@main struct LoinnirTest {
  static func fail(_ what: String) -> Never {
    print("loinnir-test: FAILED: \(what)")
    Process.exit(code: 1)
  }

  /// An error in words: Embedded Swift can't print an enum's value.
  static func describe(_ e: LoinnirError) -> String {
    switch e {
    case .vulkan(let v):
      switch v {
      case .noLoader: return "no Vulkan loader"
      case .failed(let call, let result): return "\(call) failed with \(result.rawValue)"
      case .missing(let name): return "the driver has no \(name)"
      }
    case .window(let why): return "window: " + why
    case .unsupported(let why): return why
    }
  }

  static func pixel(_ a: GPUAllocation, _ width: Int, _ x: Int, _ y: Int) -> [UInt8] {
    let p = unsafe a.pointer!.advanced(by: (y * width + x) * 4).assumingMemoryBound(to: UInt8.self)
    return unsafe [p[0], p[1], p[2], p[3]]
  }

  static func main() {
    let ns: Namespace
    do throws(NamespaceError) { ns = try Namespace(Startup.current) } catch { fail("no namespace") }
    GPUContext.namespace = ns
    do throws(LoinnirError) {
      try constantTriangle()
      try triangle()
      try textured()
      try timeline()
      try coreCases()
    } catch {
      fail(describe(error))
    }
    print("loinnir-test: passed")
    Process.exit(code: 0)
  }

  static func hex(_ p: [UInt8]) -> String {
    let digits: [Character] = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"]
    var out = "0x"
    for b in p {
      out.append(digits[Int(b >> 4)])
      out.append(digits[Int(b & 15)])
    }
    return out
  }

  /// The top-left half of a 64x64 target drawn in `want` (a green of `wantAlt` is as good) over a blue clear,
  /// on the core of the GPU offered, read back and judged pixel by pixel as gpu-test judges its triangle. A
  /// pixel within a pixel of the diagonal is not judged; every other must be exactly the triangle's colour
  /// or exactly the clear.
  static func triangle(fragment: [UInt8], want: [UInt8], wantAlt: [UInt8], name: String) throws(LoinnirError) {
    let gpu = try Loinnir.headless()
    print("loinnir-test: on \(gpu.gpu.name) (\(gpu.gpu.backend))")
    let target = try gpu.texture(.rgba8, width: 64, height: 64, renderTarget: true, sampled: false)
    let pso = try gpu.pipeline(vertex: LoinnirShaders.triangleVert, fragment: fragment, target: .rgba8)
    let verts = try gpu.alloc(.upload, bytes: 3 * 32)
    let f = unsafe verts.pointer!.assumingMemoryBound(to: Float.self)
    let corners: [(Float, Float)] = [(-1, -1), (1, -1), (-1, 1)]
    for i in 0..<3 {
      unsafe f[i * 8 + 0] = corners[i].0
      unsafe f[i * 8 + 1] = corners[i].1
      unsafe f[i * 8 + 4] = 1
      unsafe f[i * 8 + 5] = 0
      unsafe f[i * 8 + 6] = 0
      unsafe f[i * 8 + 7] = 1
    }
    let readback = try gpu.alloc(.readback, bytes: 64 * 64 * 4)
    var cmd = try gpu.commands()
    cmd.render(to: .texture(target), clear: (0, 0, 1, 1)) { r in r.draw(pso, root: verts.address, vertices: 3) }
    cmd.copy(target, to: readback)
    try gpu.wait(try gpu.submit(cmd))
    let clear: [UInt8] = [0, 0, 255, 255]
    var inside = 0
    var outside = 0
    var wrongInside = 0
    var wrongOutside = 0
    var first = ""
    for y in 0..<64 {
      for x in 0..<64 {
        // The pixel's centre is inside the triangle where x + y + 1 < 64.
        let d = x + y - 63
        if d >= -1 && d <= 1 { continue }
        let p = pixel(readback, 64, x, y)
        if d < 0 {
          inside += 1
          if p != want && p != wantAlt {
            wrongInside += 1
            if first.isEmpty { first = "(\(x), \(y)) inside reads \(hex(p)), expected \(hex(want))" }
          }
        } else {
          outside += 1
          if p != clear {
            wrongOutside += 1
            if first.isEmpty { first = "(\(x), \(y)) outside reads \(hex(p)), expected \(hex(clear))" }
          }
        }
      }
    }
    guard wrongInside + wrongOutside == 0 else {
      fail("\(name): \(wrongInside) of \(inside) inside pixels and \(wrongOutside) of \(outside) outside pixels are wrong: \(first)")
    }
    print("loinnir-test: a \(name) through the root pointer")
    print("loinnir-test: ok: Loinnir drew a \(name) on the core (\(gpu.gpu.backend): \(inside) pixels inside, \(outside) outside)")
  }

  /// The colour comes from the vertices, through a varying.
  static func triangle() throws(LoinnirError) {
    try triangle(fragment: LoinnirShaders.triangleFrag, want: [255, 0, 0, 255], wantAlt: [255, 0, 0, 255], name: "triangle")
  }

  /// The fragment shader's colour is a constant (orange): no varying is read, so this proves the core's path alone.
  static func constantTriangle() throws(LoinnirError) {
    var bytes: [UInt8] = []
    for w in constantFragment {
      for i in 0..<4 { bytes.append(UInt8(truncatingIfNeeded: w >> UInt32(8 * i))) }
    }
    try triangle(fragment: bytes, want: [255, 127, 0, 255], wantAlt: [255, 128, 0, 255], name: "constant-colour triangle")
  }

  /// gpu-test's triangle fragment shader (outColor = vec4(1, 0.5, 0, 1)), as SPIR-V words.
  static let constantFragment: [UInt32] = [
    0x07230203, 0x00010600, 0x00000000, 0x00000015, 0x00000000, 0x00020011, 0x00000001, 0x0003000e,
    0x00000000, 0x00000001, 0x0006000f, 0x00000004, 0x00000001, 0x6e69616d, 0x00000000, 0x00000002,
    0x00030010, 0x00000001, 0x00000007, 0x00040047, 0x00000002, 0x0000001e, 0x00000000, 0x00020013,
    0x00000003, 0x00030021, 0x00000004, 0x00000003, 0x00020014, 0x00000005, 0x00040015, 0x00000006,
    0x00000020, 0x00000000, 0x00040015, 0x00000007, 0x00000020, 0x00000001, 0x00030016, 0x00000008,
    0x00000020, 0x00040017, 0x00000009, 0x00000008, 0x00000002, 0x00040017, 0x0000000a, 0x00000008,
    0x00000004, 0x0004002b, 0x00000007, 0x0000000b, 0x00000000, 0x0004002b, 0x00000007, 0x0000000c,
    0x00000001, 0x0004002b, 0x00000008, 0x0000000d, 0x00000000, 0x0004002b, 0x00000008, 0x0000000e,
    0x3f800000, 0x0004002b, 0x00000008, 0x0000000f, 0x3f000000, 0x00040020, 0x00000010, 0x00000003,
    0x0000000a, 0x00040020, 0x00000011, 0x00000001, 0x00000007, 0x00040020, 0x00000012, 0x00000001,
    0x0000000a, 0x0004003b, 0x00000010, 0x00000002, 0x00000003, 0x0007002c, 0x0000000a, 0x00000013,
    0x0000000e, 0x0000000f, 0x0000000d, 0x0000000e, 0x00050036, 0x00000003, 0x00000001, 0x00000000,
    0x00000004, 0x000200f8, 0x00000014, 0x0003003e, 0x00000002, 0x00000013, 0x000100fd, 0x00010038,
  ]

  /// A texture at heap index 1 drawn over a 32x32 target.
  static func textured() throws(LoinnirError) {
    let gpu = try Loinnir.headless()
    _ = try gpu.texture(.rgba8, width: 8, height: 8)
    let source = try gpu.texture(.rgba8, width: 8, height: 8)
    guard source.index == 1 else { fail("textured: index \(source.index)") }
    let target = try gpu.texture(.rgba8, width: 32, height: 32, renderTarget: true)
    let pixels = try gpu.alloc(.upload, bytes: 8 * 8 * 4)
    let p = unsafe pixels.pointer!.assumingMemoryBound(to: UInt8.self)
    for i in 0..<64 {
      unsafe p[i * 4] = 10
      unsafe p[i * 4 + 1] = 200
      unsafe p[i * 4 + 2] = 30
      unsafe p[i * 4 + 3] = 255
    }
    let params = try gpu.alloc(.upload, bytes: 16)
    unsafe params.pointer!.storeBytes(of: source.index, as: UInt32.self)
    let pso = try gpu.pipeline(vertex: LoinnirShaders.texturedVert, fragment: LoinnirShaders.texturedFrag, target: .rgba8)
    let readback = try gpu.alloc(.readback, bytes: 32 * 32 * 4)
    var cmd = try gpu.commands()
    cmd.copy(pixels, to: source)
    cmd.render(to: .texture(target), clear: (0, 0, 0, 1)) { r in r.draw(pso, root: params.address, vertices: 6) }
    cmd.copy(target, to: readback)
    try gpu.wait(try gpu.submit(cmd))
    for (x, y) in [(16, 16), (1, 30)] where pixel(readback, 32, x, y) != [10, 200, 30, 255] {
      fail("textured: (\(x), \(y)) is \(pixel(readback, 32, x, y))")
    }
    print("loinnir-test: a texture sampled from the heap by index")
  }

  /// The core's full feature set (CoreCases.swift): drawn and judged on the Vulkan backend, whose device reports what the host GPU has.
  /// The board's native drivers are judged by their own tests.
  static func coreCases() throws(LoinnirError) {
    let gpu = try Loinnir.headless()
    guard gpu.gpu.backend.utf8.elementsEqual("vulkan".utf8) else {
      print("loinnir-test: skip: core cases: the \(gpu.gpu.backend) backend is judged by its own tests")
      return
    }
    CoreCases(gpu.gpu.core).runAll()
    _ = gpu.timelineValue
  }

  static func timeline() throws(LoinnirError) {
    let gpu = try Loinnir.headless()
    let a = try gpu.submit(try gpu.commands())
    let b = try gpu.submit(try gpu.commands())
    guard b == a + 1 else { fail("timeline: \(a) then \(b)") }
    try gpu.wait(b)
    guard gpu.completed >= b else { fail("timeline: completed \(gpu.completed) below \(b)") }
    print("loinnir-test: submissions count up the timeline")
  }
}
