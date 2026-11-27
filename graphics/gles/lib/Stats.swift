// SPDX-License-Identifier: BSD-3-Clause

// What a frame cost (gles(2), ENVIRONMENT): with GLES_STATS in the environment, the library counts what each frame (from
// one glFinish or swap to the next) recorded and submitted, and every 500 frames prints the means as one `gles: stats`
// line, with the device's own account of its last submission where it gives one (`glesDeviceProfile`).

import GPUCore

/// Whether frames are counted (c/procs.c sets it from GLES_STATS when the library loads), and whether each step of a
/// submission is also timed on the GPU (GLES_STATS=gpu).
public nonisolated(unsafe) var glesStats = false
public nonisolated(unsafe) var glesGPUTimes = false
/// The monotonic clock in nanoseconds (the native platform's; 0 hosted).
public nonisolated(unsafe) var glesClock: () -> UInt64 = { 0 }
/// The device's account of its last submission, for the stats line (the native platform's, on Mali).
public nonisolated(unsafe) var glesDeviceProfile: ((any GPUDevice) -> String?)? = nil

@c(gles_setStats) public func gles_setStats(_ on: Int32) {
  unsafe glesStats = on != 0
  unsafe glesGPUTimes = on == 2
}

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
  /// GLES_STATS=gpu: each step's GPU time summed over the frames, by its place in the frame's last submission, with what
  /// the step is (p a pass, c a copy or blit, d a dispatch), and the frames the sums are of.
  var stepNs: [UInt64] = []
  var stepKinds: [UInt8] = []
  var timedFrames = 0
}

/// GLES_STATS=gpu: the timestamps of the submission being timed.
struct StepTimer {
  var set: GPUQuerySet?
  /// The steps of the last submission timed, by kind (its timestamps are one more).
  var kinds: [UInt8] = []
  var failed = false
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

  /// GLES_STATS=gpu: the list with a timestamp before its first step and after each.
  func timed(_ l: GPUCommandList) -> GPUCommandList {
    if timer.set == nil && !timer.failed {
      timer.set = try? device.makeQuerySet(.timestamp, count: 1024)
      if timer.set == nil { timer.failed = true }
    }
    guard let set = timer.set else { return l }
    var out = GPUCommandList()
    var kinds: [UInt8] = []
    out.writeTimestamp(set, index: 0)
    for c in l.commands {
      out.append(c)
      var kind: UInt8 = 0
      switch c {
      case .endRendering: kind = UInt8(ascii: "p")
      case .copyBuffer, .copyBufferToImage, .copyImageToBuffer, .copyImage, .blitImage, .copyBufferToImageRegions,
        .copyImageToBufferRegions, .fillBuffer, .updateBuffer:
        kind = UInt8(ascii: "c")
      case .dispatch, .dispatchIndirect: kind = UInt8(ascii: "d")
      default: break
      }
      if kind != 0 && kinds.count < 1023 {
        kinds.append(kind)
        out.writeTimestamp(set, index: kinds.count)
      }
    }
    timer.kinds = kinds
    return out
  }

  /// GLES_STATS=gpu: the timed submission is done; its steps' times are added.
  func addStepTimes() {
    guard let set = timer.set, !timer.kinds.isEmpty, let t = try? device.results(set, first: 0, count: timer.kinds.count + 1)
    else { return }
    if stats.stepKinds != timer.kinds {
      stats.stepKinds = timer.kinds
      stats.stepNs = [UInt64](repeating: 0, count: timer.kinds.count)
      stats.timedFrames = 0
    }
    let ps = limits.timestampPeriodPicoseconds
    for k in 0..<timer.kinds.count where t[k + 1] >= t[k] { stats.stepNs[k] &+= (t[k + 1] - t[k]) &* ps / 1000 }
    stats.timedFrames += 1
    timer.kinds = []
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
    if stats.timedFrames > 0 {
      // Each step's mean in microseconds, sixteen a line.
      var line = ""
      var total: UInt64 = 0
      for (k, ns) in stats.stepNs.enumerated() {
        let us = ns / UInt64(stats.timedFrames) / 1000
        total += us
        line += " " + String(UnicodeScalar(stats.stepKinds[k])) + String(us)
        if k % 16 == 15 || k == stats.stepNs.count - 1 {
          say("stats: gpu us" + line)
          line = ""
        }
      }
      say("stats: gpu us total \(total) over \(stats.timedFrames) frames")
    }
    let start = stats.frameStart
    stats = FrameStats()
    stats.samplerBase = heap.writes
    stats.frameStart = start
  }
}
