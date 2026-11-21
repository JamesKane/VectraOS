// SPDX-License-Identifier: BSD-3-Clause

// The board's failure, reproduced on the interpreter: saxpy as the compiler once wrote it, each wait on the
// instruction that reads, faults (the G720 stored garbage for it, docs/gpu/valhall-board-findings.md), and the
// listing with the waits on instructions before the readers runs.

import ShaderTestKit
import Testing
import ValhallBackend
import ValhallBridge
import ValhallISA

@Suite struct OldSaxpyTests {
  @Test func theOldListingFaultsAndTheNewOneRuns() throws {
    let n = 40
    let xs = (0..<n).map { Float($0) * 0.5 }
    let ys = (0..<n).map { Float($0) * 2 }
    let buffers = [
      Buffer(binding: 0, bytes: bytes(xs.map(\.bitPattern))), Buffer(binding: 1, bytes: bytes(ys.map(\.bitPattern))),
    ]
    let push: [UInt32] = [Float(2.5).bitPattern, UInt32(n)]
    var cs = try compileText(Corpus.saxpy)
    let class32 = cs.shader.registerClass == .r32
    #expect(try probeWords(probeListing, class32: class32) == cs.shader.code)
    _ = try HostRun.dispatch(cs, buffers: buffers, push: push, grid: (2, 1, 1))
    cs.instructions = try ISATable.shared.assemble(program: probeListingOld)
    #expect(throws: (any Error).self) { _ = try HostRun.dispatch(cs, buffers: buffers, push: push, grid: (2, 1, 1)) }
  }
}
