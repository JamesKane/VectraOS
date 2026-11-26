// SPDX-License-Identifier: BSD-3-Clause

// virtio-snd (Virtual I/O Device 1.2 §5.14): its configuration, its
// control requests and their answers, and the forms of a PCM transfer.
// Queue 0 takes control requests (a request the device reads and an
// answer it writes), queue 1 events, queue 2 playback transfers and
// queue 3 capture's: each transfer a 4-byte header naming the stream,
// the frames, and an 8-byte status the device writes. Everything is
// little-endian.

import AudioDevice
import Virtio

public enum Sound {
  /// The queues.
  public static let controlQueue = 0
  public static let eventQueue = 1
  public static let txQueue = 2
  public static let rxQueue = 3

  /// Request codes (§5.14.6).
  public static let pcmInfo: UInt32 = 0x0100
  public static let pcmSetParams: UInt32 = 0x0101
  public static let pcmPrepare: UInt32 = 0x0102
  public static let pcmRelease: UInt32 = 0x0103
  public static let pcmStart: UInt32 = 0x0104
  public static let pcmStop: UInt32 = 0x0105
  /// Event codes.
  public static let jackConnected: UInt32 = 0x1000
  public static let jackDisconnected: UInt32 = 0x1001
  public static let pcmPeriodElapsed: UInt32 = 0x1100
  public static let pcmXrun: UInt32 = 0x1101
  /// Status codes.
  public static let ok: UInt32 = 0x8000
  public static let badMessage: UInt32 = 0x8001
  public static let notSupported: UInt32 = 0x8002
  public static let ioError: UInt32 = 0x8003

  /// The status a transfer's answer and a control answer start with.
  public static let statusBytes = 8
  public static let pcmInfoBytes = 32

  /// virtio_snd_config: jacks, streams and channel maps.
  public struct Config: Equatable, Sendable {
    public var jacks: UInt32
    public var streams: UInt32
    public var chmaps: UInt32
    public init(jacks: UInt32, streams: UInt32, chmaps: UInt32) {
      self.jacks = jacks
      self.streams = streams
      self.chmaps = chmaps
    }
  }

  public static func config<W: Window>(_ d: Device<W>) -> Config {
    Config(jacks: UInt32(truncatingIfNeeded: d.config(0, width: 4)),
           streams: UInt32(truncatingIfNeeded: d.config(4, width: 4)),
           chmaps: UInt32(truncatingIfNeeded: d.config(8, width: 4)))
  }

  // MARK: Formats and rates

  /// The format codes the class names, by bit (VIRTIO_SND_PCM_FMT_*).
  public static let formatBits: [(bit: Int, format: SampleFormat)] = [
    (3, .s8), (4, .u8), (5, .s16), (15, .s24), (17, .s32), (19, .f32),
  ]
  /// The rates, by bit (VIRTIO_SND_PCM_RATE_*).
  public static let rateBits: [UInt32] = [
    5512, 8000, 11025, 16000, 22050, 32000, 44100, 48000, 64000, 88200, 96000, 176400, 192000, 384000,
  ]

  public static func formatCode(_ f: SampleFormat) -> UInt8 {
    for e in formatBits where e.format == f { return UInt8(e.bit) }
    return 0
  }

  public static func rateCode(_ r: UInt32) -> UInt8? {
    for (i, rate) in rateBits.enumerated() where rate == r { return UInt8(i) }
    return nil
  }

  // MARK: Streams

  /// virtio_snd_pcm_info: a stream's direction and what it takes.
  public struct PCMInfo: Equatable, Sendable {
    public var id: UInt32
    public var function: UInt32
    public var features: UInt32
    public var formats: UInt64
    public var rates: UInt64
    public var direction: AudioDirection
    public var channelsMin: UInt8
    public var channelsMax: UInt8

    public init(id: UInt32, function: UInt32, features: UInt32, formats: UInt64, rates: UInt64,
                direction: AudioDirection, channelsMin: UInt8, channelsMax: UInt8) {
      self.id = id
      self.function = function
      self.features = features
      self.formats = formats
      self.rates = rates
      self.direction = direction
      self.channelsMin = channelsMin
      self.channelsMax = channelsMax
    }

    /// What the class can use of it: the formats it names, the rates it
    /// knows.
    public var capabilities: PCMCapabilities {
      PCMCapabilities(
        samples: Sound.formatBits.filter { formats & (1 << UInt64($0.bit)) != 0 }.map { $0.format },
        rates: Sound.rateBits.enumerated().filter { rates & (1 << UInt64($0.offset)) != 0 }.map { $0.element },
        channels: Int(channelsMin)...Int(max(channelsMin, channelsMax)))
    }
  }

  // MARK: Messages

  static func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * UInt32($0))) } }

  static func le32(_ b: [UInt8], _ at: Int) -> UInt32 {
    guard at + 4 <= b.count else { return 0 }
    return UInt32(b[at]) | UInt32(b[at + 1]) << 8 | UInt32(b[at + 2]) << 16 | UInt32(b[at + 3]) << 24
  }

  static func le64(_ b: [UInt8], _ at: Int) -> UInt64 { UInt64(le32(b, at)) | UInt64(le32(b, at + 4)) << 32 }

  /// virtio_snd_query_info: `count` items of `size` bytes from `start`.
  public static func queryInfo(_ code: UInt32, start: UInt32, count: UInt32, size: UInt32) -> [UInt8] {
    le32(code) + le32(start) + le32(count) + le32(size)
  }

  /// virtio_snd_pcm_hdr: a request on one stream (PREPARE, RELEASE,
  /// START, STOP).
  public static func pcm(_ code: UInt32, stream: UInt32) -> [UInt8] { le32(code) + le32(stream) }

  /// virtio_snd_pcm_set_params.
  public static func setParams(stream: UInt32, bufferBytes: UInt32, periodBytes: UInt32, format: PCMFormat)
    -> [UInt8]?
  {
    guard let rate = rateCode(format.rate), formatCode(format.sample) != 0, format.channels <= 255 else { return nil }
    return pcm(pcmSetParams, stream: stream) + le32(bufferBytes) + le32(periodBytes) + le32(0)
      + [UInt8(format.channels), formatCode(format.sample), rate, 0]
  }

  /// An answer's status: its first word.
  public static func status(_ answer: [UInt8]) -> UInt32 { le32(answer, 0) }

  /// PCM_INFO's answer: the status, then `count` virtio_snd_pcm_info of
  /// 32 bytes, the first numbered `start`.
  public static func pcmInfos(_ answer: [UInt8], start: UInt32, count: Int) -> [PCMInfo] {
    var out: [PCMInfo] = []
    for i in 0..<count {
      let at = 4 + i * pcmInfoBytes
      guard at + pcmInfoBytes <= answer.count else { break }
      out.append(PCMInfo(id: start + UInt32(i), function: le32(answer, at), features: le32(answer, at + 4),
                         formats: le64(answer, at + 8), rates: le64(answer, at + 16),
                         direction: answer[at + 24] == 1 ? .input : .output,
                         channelsMin: answer[at + 25], channelsMax: answer[at + 26]))
    }
    return out
  }

  /// virtio_snd_event: its type and data.
  public static func event(_ b: [UInt8]) -> (type: UInt32, data: UInt32) { (le32(b, 0), le32(b, 4)) }

  /// What an error status means, for status lines.
  public static func name(status: UInt32) -> String {
    switch status {
    case ok: "OK"
    case badMessage: "BAD_MSG"
    case notSupported: "NOT_SUPP"
    case ioError: "IO_ERR"
    default: "status \(status)"
    }
  }
}
