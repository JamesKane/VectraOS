// SPDX-License-Identifier: BSD-3-Clause

// Loinnir v0 with no window: draws into textures and reads the pixels back.

import Glibc
import Loinnir
import Testing

/// A committed SPIR-V shader beside this file (td shaders writes them).
func spirv(_ name: String, file: String = #filePath) -> [UInt8] {
  let dir = file[..<file.lastIndex(of: "/")!]
  let path = "\(dir)/shaders/\(name).spv"
  guard let f = fopen(path, "rb") else { return [] }
  defer { fclose(f) }
  var bytes: [UInt8] = []
  var chunk = [UInt8](repeating: 0, count: 4096)
  while case let n = fread(&chunk, 1, chunk.count, f), n > 0 { bytes += chunk[..<n] }
  return bytes
}

/// The RGBA pixel at (x, y) of a tightly packed rgba8 readback.
func pixel(_ a: GPUAllocation, _ t: Texture, _ x: Int, _ y: Int) -> [UInt8] {
  let p = a.pointer!.advanced(by: (y * Int(t.width) + x) * 4).assumingMemoryBound(to: UInt8.self)
  return [p[0], p[1], p[2], p[3]]
}

@Suite(.serialized) struct DrawTests {
  @Test func aTriangleIsDrawnThroughTheRootPointer() throws {
    let gpu = try Loinnir.headless()
    let target = try gpu.texture(.rgba8, width: 64, height: 64, renderTarget: true)
    let pso = try gpu.pipeline(vertex: spirv("triangle.vert"), fragment: spirv("triangle.frag"), target: .rgba8)

    // Three vertices of 32 bytes (vec2 position, vec4 color at 16): the
    // top-left half of the target, in red.
    let verts = try gpu.alloc(.upload, bytes: 3 * 32)
    let f = verts.pointer!.assumingMemoryBound(to: Float.self)
    for (i, (x, y)) in [(-1, -1), (1, -1), (-1, 1)].enumerated() {
      f[i * 8 + 0] = Float(x)
      f[i * 8 + 1] = Float(y)
      (f[i * 8 + 4], f[i * 8 + 5], f[i * 8 + 6], f[i * 8 + 7]) = (1, 0, 0, 1)
    }
    let readback = try gpu.alloc(.readback, bytes: 64 * 64 * 4)

    var cmd = try gpu.commands()
    cmd.render(to: .texture(target), clear: (0, 0, 1, 1)) { r in r.draw(pso, root: verts.address, vertices: 3) }
    cmd.copy(target, to: readback)
    try gpu.wait(try gpu.submit(cmd))

    #expect(pixel(readback, target, 2, 2) == [255, 0, 0, 255])  // inside: red
    #expect(pixel(readback, target, 61, 61) == [0, 0, 255, 255])  // outside: the clear
  }

  @Test func aTextureIsSampledFromTheHeapByIndex() throws {
    let gpu = try Loinnir.headless()
    // Two textures, so the one sampled isn't at index 0.
    _ = try gpu.texture(.rgba8, width: 8, height: 8)
    let source = try gpu.texture(.rgba8, width: 8, height: 8)
    #expect(source.index == 1)
    let target = try gpu.texture(.rgba8, width: 32, height: 32, renderTarget: true)

    let pixels = try gpu.alloc(.upload, bytes: 8 * 8 * 4)
    let p = pixels.pointer!.assumingMemoryBound(to: UInt8.self)
    for i in 0..<64 { (p[i * 4], p[i * 4 + 1], p[i * 4 + 2], p[i * 4 + 3]) = (10, 200, 30, 255) }
    let params = try gpu.alloc(.upload, bytes: 16)
    params.pointer!.storeBytes(of: source.index, as: UInt32.self)
    let pso = try gpu.pipeline(vertex: spirv("textured.vert"), fragment: spirv("textured.frag"), target: .rgba8)
    let readback = try gpu.alloc(.readback, bytes: 32 * 32 * 4)

    var cmd = try gpu.commands()
    cmd.copy(pixels, to: source)
    cmd.render(to: .texture(target), clear: (0, 0, 0, 1)) { r in r.draw(pso, root: params.address, vertices: 6) }
    cmd.copy(target, to: readback)
    try gpu.wait(try gpu.submit(cmd))

    #expect(pixel(readback, target, 16, 16) == [10, 200, 30, 255])
    #expect(pixel(readback, target, 1, 30) == [10, 200, 30, 255])
  }

  @Test func submissionsCountUpTheTimeline() throws {
    let gpu = try Loinnir.headless()
    let a = try gpu.submit(try gpu.commands())
    let b = try gpu.submit(try gpu.commands())
    #expect(b == a + 1)
    try gpu.wait(b)
    #expect(gpu.completed >= b)
  }

  @Test func notSPIRVIsRefused() throws {
    let gpu = try Loinnir.headless()
    #expect(throws: LoinnirError.self) { try gpu.pipeline(vertex: [1, 2, 3], fragment: [], target: .rgba8) }
  }
}
