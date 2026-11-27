// SPDX-License-Identifier: BSD-3-Clause

// What a frame cost (gles(2), ENVIRONMENT): with GLES_STATS in the environment, the library counts what each frame (from
// one glFinish or swap to the next) recorded and submitted, and every 500 frames prints the means as one `gles: stats`
// line, with the device's own account of its last submission where it gives one (`glesDeviceProfile`).

import GPUCore

/// Whether frames are counted (c/procs.c sets it from GLES_STATS when the library loads).
public nonisolated(unsafe) var glesStats = false
/// The monotonic clock in nanoseconds (the native platform's; 0 hosted).
public nonisolated(unsafe) var glesClock: () -> UInt64 = { 0 }
/// The device's account of its last submission, for the stats line (the native platform's, on Mali).
public nonisolated(unsafe) var glesDeviceProfile: ((any GPUDevice) -> String?)? = nil

@c(gles_setStats) public func gles_setStats(_ on: Int32) { unsafe glesStats = on != 0 }

struct FrameStats {
  var frames = 0
  var submits = 0
  var passes = 0
  var draws = 0
  var commands = 0
  var copies = 0
  var barriers = 0
  var samplerWrites = 0
  var textureWrites = 0
  var images = 0
  var pipelines = 0
  /// Nanoseconds from the last frame's end to the submission (the program's and the library's CPU), in the submission,
  /// and waiting for the GPU.
  var recordNs: UInt64 = 0
  var submitNs: UInt64 = 0
  var waitNs: UInt64 = 0
  var frameStart: UInt64 = 0
  /// The heap's sampler writes when the count began.
  var samplerBase = 0
}

extension Frame {
  /// Counts what a list being submitted holds.
  func count(_ l: GPUCommandList) {
    stats.submits += 1
    stats.commands += l.commands.count
    for c in l.commands {
      switch c {
      case .barrier, .imageBarrier: stats.barriers += 1
      case .copyBuffer, .copyBufferToImage, .copyImageToBuffer, .copyImage, .blitImage, .copyBufferToImageRegions,
        .copyImageToBufferRegions:
        stats.copies += 1
      default: break
      }
    }
  }

  /// A frame ended (glFinish or a swap): every 500, the means.
  func frameEnded() {
    guard unsafe glesStats else { return }
    stats.frames += 1
    guard stats.frames == 500 else { return }
    stats.samplerWrites = heap.writes &- stats.samplerBase
    let n = Double(stats.frames)
    func m(_ v: Int) -> String { String(Double(Int((Double(v) / n) * 10)) / 10) }
    func us(_ v: UInt64) -> String { String(Int(Double(v) / n / 1000)) }
    // Short lines: the board's console drops what is past about 200 characters.
    say("stats: per frame \(m(stats.submits)) submits, \(m(stats.passes)) passes, \(m(stats.draws)) draws, \(m(stats.commands)) "
      + "commands, \(m(stats.copies)) copies, \(m(stats.barriers)) barriers")
    say("stats: per frame \(m(stats.samplerWrites)) sampler, \(m(stats.textureWrites)) texture slots written, \(m(stats.images)) "
      + "images, \(m(stats.pipelines)) pipelines made")
    say("stats: per frame recording \(us(stats.recordNs)) us, submitting \(us(stats.submitNs)) us, waiting \(us(stats.waitNs)) us")
    if let p = unsafe glesDeviceProfile, let s = p(device) { say("stats: the last submission: " + s) }
    let start = stats.frameStart
    stats = FrameStats()
    stats.samplerBase = heap.writes
    stats.frameStart = start
  }
}
