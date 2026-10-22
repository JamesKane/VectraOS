// SPDX-License-Identifier: BSD-3-Clause

// bin/loinnir-test (boot-venus, D121): Loinnir's draw tests on the device,
// through our loader, the Venus client driver and the GPU class to
// virtio-gpu's driver host, on the host's GPU (graphics/loinnir/tests'
// DrawTests, as a native program).
// A triangle drawn through the root pointer, a texture sampled from the
// bindless heap by index, and the timeline; each read back through
// host-visible memory. The shaders are tests/native/generated's copies.

import GPUClient
import Loinnir
import Node
import Sys

@main struct LoinnirTest {
  static func fail(_ what: String) -> Never {
    print("loinnir-test: FAILED: \(what)")
    Process.exit(code: 1)
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
      try triangle()
      try textured()
      try timeline()
    } catch {
      fail("\(error)")
    }
    print("loinnir-test: passed")
    Process.exit(code: 0)
  }

  /// The top-left half of a 64x64 target in red, over a blue clear.
  static func triangle() throws(LoinnirError) {
    let gpu = try Loinnir.headless()
    print("loinnir-test: on \(gpu.gpu.name)")
    let target = try gpu.texture(.rgba8, width: 64, height: 64, renderTarget: true)
    let pso = try gpu.pipeline(vertex: LoinnirShaders.triangleVert, fragment: LoinnirShaders.triangleFrag, target: .rgba8)
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
    guard pixel(readback, 64, 2, 2) == [255, 0, 0, 255] else { fail("triangle: inside is \(pixel(readback, 64, 2, 2))") }
    guard pixel(readback, 64, 61, 61) == [0, 0, 255, 255] else { fail("triangle: outside is \(pixel(readback, 64, 61, 61))") }
    print("loinnir-test: a triangle through the root pointer")
  }

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
