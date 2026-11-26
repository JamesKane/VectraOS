// SPDX-License-Identifier: BSD-3-Clause

// The audio class (D82, D179): a device as 9front's audio(3) directory,
// which an audio driver serves from an AudioHardware and devmgr binds at
// /dev/audio/N:
//
//     ctl      the format, the period, and `start` and `stop`
//     stat     9front's audiostat line, then the class's
//     volume   9front's lines: `speed`, `delay`, and the device's
//              amplifiers (none here yet)
//     data     playback when written, capture when read, in the format
//              ctl set: interleaved little-endian frames
//
// One format serves both directions, 9front's (16-bit stereo at 44.1 kHz)
// unless the device can't take it. A write of data copies into the
// playback stream's cyclic buffer (D180), starting the stream, and waits
// for room; a read waits for the first captured period. The data file's
// operations run on a dispatcher of their own, so a waiting write
// doesn't hold up ctl, stat or volume.

import IPC
import Node
import Sys

public final class AudioUnit: @unchecked Sendable {
  public let hardware: AudioHardware
  let control: IPCDispatcher
  let data: IPCDispatcher
  let output: AudioStream?
  let input: AudioStream?
  let lock = Lock()
  public private(set) var format: PCMFormat
  public private(set) var periodFrames: Int

  public static let defaultPeriodFrames = 1024
  public static let periods = 8
  public static let lead = 2
  public static let periodRange = 32...8192

  /// The unit over `hardware`, its directory served on `control`, and
  /// its data file on `data` (each one of the unit's own, if a NodeTree
  /// mounts it: a tree waits on its dispatcher's thread for a mount's
  /// answers).
  public init(_ hardware: AudioHardware, control: IPCDispatcher, data: IPCDispatcher) {
    self.hardware = hardware
    self.control = control
    self.data = data
    let caps = hardware.capabilities(.output) ?? hardware.capabilities(.input)
    let f = caps?.nearest(.plan9) ?? .plan9
    format = f
    periodFrames = Self.defaultPeriodFrames
    output = hardware.capabilities(.output) == nil ? nil
      : AudioStream(.output, hardware, format: f, periodFrames: periodFrames, periods: Self.periods, lead: Self.lead)
    input = hardware.capabilities(.input) == nil ? nil
      : AudioStream(.input, hardware, format: f, periodFrames: periodFrames, periods: Self.periods, lead: Self.lead)
  }

  /// The device finished the oldest period it holds of `d`'s stream. On
  /// the driver's interrupt thread, with none of the driver's locks held.
  public func finished(_ d: AudioDirection) {
    (d == .output ? output : input)?.finished()
  }

  /// A channel to the unit's directory, to mount.
  public func channel() throws(Status) -> Handle { try channel(at: 0) }

  func channel(at node: Int) throws(Status) -> Handle {
    let ends = try Channel.create()
    try serve(ends.b, at: node)
    return ends.a
  }

  func serve(_ channel: consuming Handle, at node: Int) throws(Status) {
    let dispatcher = node == AudioNode.data ? data : control
    try dispatcher.add(NodeIPC.NodeServer(channel: channel, impl: AudioSession(unit: self, node: node)))
  }

  // MARK: The files

  /// ctl's text.
  public var ctlText: String {
    let (f, p) = lock.withLock { (format, periodFrames) }
    return "speed \(f.rate)\nformat \(f.sample.name) \(f.channels)\nperiod \(p)\n"
  }

  /// volume's text: 9front's `speed` and `delay` (frames buffered ahead of
  /// the device: the periods it is handed).
  public var volumeText: String {
    let (f, p) = lock.withLock { (format, periodFrames) }
    return "speed \(f.rate)\ndelay \(p * Self.lead + hardware.externalDelay)\n"
  }

  /// stat's text: 9front's audiostat line for playback, then the class's.
  public var statText: String {
    let (f, p) = lock.withLock { (format, periodFrames) }
    var s = ""
    let out = output?.snapshot
    let bufsize = out?.cycle?.bufferBytes ?? Self.periods * p * f.frameBytes
    let buffered = out?.cycle?.buffered ?? 0
    let offset = out?.playedBytes ?? 0
    s += "bufsize " + pad(UInt64(bufsize), 6) + " buffered " + pad(buffered, 6) + " offset " + pad(offset, 10)
      + " time " + pad(UInt64(max(out?.finishedAt ?? 0, 0)), 19) + "\n"
    s += "device \(hardware.name)\n"
    for d in [AudioDirection.output, .input] {
      if let c = hardware.capabilities(d) { s += c.line(d) + "\n" }
    }
    s += "format \(f.sample.name) \(f.channels)\nspeed \(f.rate)\nperiod \(p)\nperiods \(Self.periods)\n"
    s += "lead \(Self.lead)\ndelay \(hardware.externalDelay)\n"
    for (d, stream) in [(AudioDirection.output, output), (.input, input)] {
      guard let snap = stream?.snapshot else { continue }
      let state = snap.state == .stopped ? "stopped" : snap.state == .stopping ? "stopping" : "running"
      let c = snap.cycle
      s += "\(d.name) \(state) runs \(snap.runs) periods \(snap.played)"
      s += d == .output ? " underruns \(c?.underruns ?? 0)\n" : " overruns \(c?.overruns ?? 0)\n"
    }
    return s
  }

  func pad(_ n: UInt64, _ width: Int) -> String {
    let digits = "\(n)"
    let spaces = width - digits.utf8.count
    var s = ""
    if spaces > 0 { for _ in 0..<spaces { s += " " } }
    return s + digits
  }

  /// ctl's lines: `speed N`, `format NAME CHANNELS`, `period FRAMES`,
  /// `start [out|in]`, `stop [out|in]`.
  public func command(_ text: String) throws(NodeIPC.NodeError) {
    let all = AudioText.lines(text)
    guard !all.isEmpty else { throw .invalid }
    for words in all {
      let verb = words[0]
      if AudioText.same(verb, "start") || AudioText.same(verb, "stop") {
        guard words.count <= 2 else { throw .invalid }
        var streams: [AudioStream] = []
        if words.count == 1 || AudioText.same(words[1], "out"), let o = output { streams.append(o) }
        if words.count == 1 || AudioText.same(words[1], "in"), let i = input { streams.append(i) }
        guard words.count == 1 || AudioText.same(words[1], "out") || AudioText.same(words[1], "in") else {
          throw .invalid
        }
        guard !streams.isEmpty else { throw .unsupported }
        for s in streams {
          if AudioText.same(verb, "stop") {
            s.stop()
          } else {
            try s.lock.withLock { () throws(NodeIPC.NodeError) in
              if s.state == .stopped { try s.startLocked() }
            }
          }
        }
      } else {
        var (f, p) = lock.withLock { (format, periodFrames) }
        if AudioText.same(verb, "speed"), words.count == 2, let n = AudioText.number(words[1]) {
          f.rate = UInt32(n)
        } else if AudioText.same(verb, "format"), words.count == 2 || words.count == 3,
          let s = SampleFormat.named(words[1])
        {
          f.sample = s
          if words.count == 3 {
            guard let n = AudioText.number(words[2]), n >= 1, n <= 32 else { throw .invalid }
            f.channels = Int(n)
          }
        } else if AudioText.same(verb, "period"), words.count == 2, let n = AudioText.number(words[1]),
          Self.periodRange.contains(Int(n)), n & (n - 1) == 0
        {
          p = Int(n)
        } else {
          throw .invalid
        }
        try configure(f, periodFrames: p)
      }
    }
  }

  /// volume's lines: `speed N`; amplifiers this device lacks are refused.
  public func volumeCommand(_ text: String) throws(NodeIPC.NodeError) {
    for words in AudioText.lines(text) {
      guard AudioText.same(words[0], "speed") else { throw .unsupported }
      try command(words.joined(separator: " "))
    }
  }

  /// A format and period for both directions: each stream the device has
  /// must take it.
  func configure(_ f: PCMFormat, periodFrames p: Int) throws(NodeIPC.NodeError) {
    for d in [AudioDirection.output, .input] {
      if let c = hardware.capabilities(d), !c.allows(f) { throw .unsupported }
    }
    guard Self.periods * p * f.frameBytes <= hardware.maxBufferBytes else { throw .invalid }
    let same = lock.withLock { format == f && periodFrames == p }
    guard !same else { return }
    output?.reconfigure(f, periodFrames: p)
    input?.reconfigure(f, periodFrames: p)
    lock.withLock {
      format = f
      periodFrames = p
    }
  }

  func write(_ bytes: [UInt8]) throws(NodeIPC.NodeError) -> UInt32 {
    guard let output else { throw .unsupported }
    return try output.write(bytes)
  }

  func read(max: Int) throws(NodeIPC.NodeError) -> [UInt8] {
    guard let input else { throw .unsupported }
    return try input.read(max: max)
  }
}

/// The directory's nodes.
enum AudioNode {
  static let directory = 0
  static let ctl = 1
  static let stat = 2
  static let volume = 3
  static let data = 4
  static let names = ["", "ctl", "stat", "volume", "data"]

  static func stat(_ node: Int) -> NodeIPC.Stat {
    NodeIPC.Stat(qid: NodeIPC.Qid(path: UInt64(node) + 1, version: 0, kind: node == 0 ? .directory : .file),
                 name: names[node], size: 0, modified: 0, attributes: [])
  }

  static func child(_ name: String) -> Int? {
    for i in 1..<names.count where NodeIPC.same(names[i], name) { return i }
    return nil
  }
}

struct AudioSession: NodeIPC.NodeHandler {
  let unit: AudioUnit
  let node: Int

  func text(_ s: String, _ offset: UInt64, _ max: UInt32) -> [UInt8] {
    let t = Array(s.utf8)
    let from = Int(Swift.min(offset, UInt64(t.count)))
    return Array(t[from..<Swift.min(t.count, from + Int(max))])
  }

  mutating func batch(_ ops: [NodeIPC.Op], open: Bool) -> NodeIPC.Reply {
    var results: [NodeIPC.Outcome] = []
    guard ops.count <= NodeIPC.maxOps else { return failed(results, 0, .tooManyOps) }
    var at = node
    for i in ops.indices {
      do throws(NodeIPC.NodeError) {
        switch ops[i] {
        case .walk(let names):
          var qids: [NodeIPC.Qid] = []
          for name in names {
            if NodeIPC.same(name, "..") {
              at = AudioNode.directory
            } else {
              guard at == AudioNode.directory, let c = AudioNode.child(name) else { throw .notFound }
              at = c
            }
            qids.append(AudioNode.stat(at).qid)
          }
          results.append(.walked(qids))
        case .stat:
          results.append(.stat(AudioNode.stat(at)))
        case .readdir(let cursor, _, _):
          guard at == AudioNode.directory else { throw .notDirectory }
          let all = AudioNode.names.count - 1
          let from = Int(Swift.min(cursor, UInt64(all)))
          let entries = (from..<all).map { AudioNode.stat($0 + 1) }
          results.append(.dir(NodeIPC.DirBatch(entries: entries, next: UInt64(all), done: true)))
        case .read(let offset, let max):
          switch at {
          case AudioNode.ctl: results.append(.data(text(unit.ctlText, offset, max)))
          case AudioNode.stat: results.append(.data(text(unit.statText, offset, max)))
          case AudioNode.volume: results.append(.data(text(unit.volumeText, offset, max)))
          case AudioNode.data: results.append(.data(try unit.read(max: Swift.min(Int(max), NodeIPC.maxIO))))
          default: throw .isDirectory
          }
        case .write(_, let data):
          switch at {
          case AudioNode.ctl:
            try unit.command(String(decoding: data, as: UTF8.self))
            results.append(.wrote(UInt32(data.count)))
          case AudioNode.volume:
            try unit.volumeCommand(String(decoding: data, as: UTF8.self))
            results.append(.wrote(UInt32(data.count)))
          case AudioNode.data:
            guard data.count <= NodeIPC.maxIO else { throw .invalid }
            results.append(.wrote(try unit.write(data)))
          case AudioNode.stat: throw .denied
          default: throw .isDirectory
          }
        case .watch:
          throw .unsupported
        case .create, .remove:
          throw .denied
        }
      } catch {
        return failed(results, i, error)
      }
    }
    guard open else { return NodeIPC.Reply(results: results, failure: nil, node: nil) }
    do throws(Status) {
      return NodeIPC.Reply(results: results, failure: nil, node: try unit.channel(at: at))
    } catch {
      return failed(results, ops.count, .io)
    }
  }

  func failed(_ results: [NodeIPC.Outcome], _ index: Int, _ error: NodeIPC.NodeError) -> NodeIPC.Reply {
    NodeIPC.Reply(results: results, failure: NodeIPC.Failure(index: UInt32(index), code: error.rawValue), node: nil)
  }

  /// No ring yet: data is read and written by message (D180: the audio
  /// service will be lent the buffer itself).
  mutating func attach(_ bulk: consuming NodeIPC.Bulk) throws(NodeIPC.NodeError) { throw .unsupported }

  func memory(executable: Bool) throws(NodeIPC.NodeError) -> NodeIPC.Memory { throw .unsupported }

  func wstat(_ change: NodeIPC.Wstat) throws(NodeIPC.NodeError) { throw .denied }

  /// No bytes ahead: a stream's are read when asked for.
  mutating func openAhead(_ ops: [NodeIPC.Op], max: UInt32) -> NodeIPC.Ahead {
    NodeIPC.Ahead(batch(ops, open: true))
  }

  /// No fids: a device's few clients each open a channel.
  func openFid(_ ops: [NodeIPC.Op], fid: UInt32, ahead: UInt32, clunk: [UInt32]) throws(NodeIPC.NodeError)
    -> NodeIPC.Ahead
  { throw .unsupported }

  func fidBatch(_ fid: UInt32, _ ops: [NodeIPC.Op], open: Bool, clunk: [UInt32]) throws(NodeIPC.NodeError)
    -> NodeIPC.Reply
  { throw .unsupported }

  func clunk(_ fids: [UInt32]) throws(NodeIPC.NodeError) { throw .unsupported }

  func clone(_ channel: consuming Handle) { _ = try? unit.serve(channel, at: node) }
}
