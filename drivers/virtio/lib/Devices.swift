// SPDX-License-Identifier: BSD-3-Clause

// What the other virtio devices' configurations say (Virtual I/O Device
// 1.2): network (§5.1), input (§5.8) and
// sound (§5.14); GPU's (§5.7) is drivers/display/virtio-gpu's. Each
// reads only the configuration; their queues carry the rest, once croi's
// BTI lets the device reach memory.

/// Device ids (§5): a modern PCI device is 0x1040 plus the type; the
/// transitional ones below 0x1040 predate it.
public enum DeviceType {
  public static let network: UInt16 = 1
  public static let block: UInt16 = 2
  public static let gpu: UInt16 = 16
  public static let input: UInt16 = 18
  public static let sound: UInt16 = 25

  public static func modernID(_ type: UInt16) -> UInt16 { 0x1040 + type }
}

public enum Network {
  public enum Feature {
    public static let mtu: UInt64 = 1 << 3
    public static let mac: UInt64 = 1 << 5
    public static let status: UInt64 = 1 << 16
    public static let multiqueue: UInt64 = 1 << 22
  }

  public struct Config: Equatable, Sendable {
    public var mac: [UInt8]?
    /// Bit 0: the link is up.
    public var status: UInt16?
    public var mtu: UInt16?
    public var queuePairs: UInt16

    public init(mac: [UInt8]?, status: UInt16?, mtu: UInt16?, queuePairs: UInt16) {
      self.mac = mac
      self.status = status
      self.mtu = mtu
      self.queuePairs = queuePairs
    }
  }

  public static func config<W: Window>(_ d: Device<W>) -> Config {
    let f = d.features
    return Config(
      mac: f & Feature.mac != 0 ? (0..<6).map { UInt8(truncatingIfNeeded: d.config($0, width: 1)) } : nil,
      status: f & Feature.status != 0 ? UInt16(truncatingIfNeeded: d.config(6, width: 2)) : nil,
      mtu: f & Feature.mtu != 0 ? UInt16(truncatingIfNeeded: d.config(10, width: 2)) : nil,
      queuePairs: f & Feature.multiqueue != 0 ? UInt16(truncatingIfNeeded: d.config(8, width: 2)) : 1)
  }

  /// `52:54:00:12:34:56`.
  public static func text(_ mac: [UInt8]) -> String {
    let digits = Array("0123456789abcdef".utf8)
    var out: [UInt8] = []
    for (i, b) in mac.enumerated() {
      if i > 0 { out.append(UInt8(ascii: ":")) }
      out += [digits[Int(b >> 4)], digits[Int(b & 15)]]
    }
    return String(decoding: out, as: UTF8.self)
  }
}

public enum Input {
  /// virtio_input_config's select values (§5.8.4).
  public static let idName: UInt8 = 0x01
  public static let idSerial: UInt8 = 0x02
  public static let idDevids: UInt8 = 0x03
  public static let propBits: UInt8 = 0x10
  public static let eventBits: UInt8 = 0x11
  public static let absInfo: UInt8 = 0x12

  /// Asks the configuration (select, subsel) and reads the answer: `size`
  /// bytes of data at 8.
  public static func query<W: Window>(_ d: Device<W>, _ select: UInt8, _ subsel: UInt8 = 0) -> [UInt8] {
    d.setConfig(0, width: 1, UInt64(select))
    d.setConfig(1, width: 1, UInt64(subsel))
    let size = min(Int(d.config(2, width: 1)), 128)
    return (0..<size).map { UInt8(truncatingIfNeeded: d.config(8 + $0, width: 1)) }
  }

  public struct Identity: Equatable, Sendable {
    public var name: String
    public var bus: UInt16
    public var vendor: UInt16
    public var product: UInt16
    public var version: UInt16
    /// The event types it reports (EV_KEY 1, EV_REL 2, EV_ABS 3...).
    public var eventTypes: [UInt8]

    public init(name: String, bus: UInt16, vendor: UInt16, product: UInt16, version: UInt16, eventTypes: [UInt8]) {
      self.name = name
      self.bus = bus
      self.vendor = vendor
      self.product = product
      self.version = version
      self.eventTypes = eventTypes
    }
  }

  public static func identity<W: Window>(_ d: Device<W>) -> Identity {
    var nameBytes = query(d, idName)
    while nameBytes.last == 0 { nameBytes.removeLast() }  // QEMU counts the terminator
    let name = String(decoding: nameBytes, as: UTF8.self)
    let ids = query(d, idDevids)
    func le16(_ i: Int) -> UInt16 { i + 1 < ids.count ? UInt16(ids[i]) | UInt16(ids[i + 1]) << 8 : 0 }
    var types: [UInt8] = []
    for t in UInt8(1)..<0x20 where !query(d, eventBits, t).isEmpty { types.append(t) }
    return Identity(name: name, bus: le16(0), vendor: le16(2), product: le16(4), version: le16(6), eventTypes: types)
  }
}

public enum Sound {
  public enum Feature {
    public static let controls: UInt64 = 1 << 0
  }

  public struct Config: Equatable, Sendable {
    public var jacks: UInt32
    public var streams: UInt32
    public var channelMaps: UInt32
    public var controls: UInt32?

    public init(jacks: UInt32, streams: UInt32, channelMaps: UInt32, controls: UInt32?) {
      self.jacks = jacks
      self.streams = streams
      self.channelMaps = channelMaps
      self.controls = controls
    }
  }

  public static func config<W: Window>(_ d: Device<W>) -> Config {
    Config(jacks: UInt32(truncatingIfNeeded: d.config(0, width: 4)),
           streams: UInt32(truncatingIfNeeded: d.config(4, width: 4)),
           channelMaps: UInt32(truncatingIfNeeded: d.config(8, width: 4)),
           controls: d.features & Feature.controls != 0 ? UInt32(truncatingIfNeeded: d.config(12, width: 4)) : nil)
  }

  // MARK: Requests (§5.14.6)

  /// Queues: control, events, output (tx), input (rx).
  public static let controlQueue = 0, eventQueue = 1, txQueue = 2, rxQueue = 3

  /// Request codes.
  public static let pcmInfo: UInt32 = 0x0100
  public static let pcmSetParams: UInt32 = 0x0101
  public static let pcmPrepare: UInt32 = 0x0102
  public static let pcmRelease: UInt32 = 0x0103
  public static let pcmStart: UInt32 = 0x0104
  public static let pcmStop: UInt32 = 0x0105
  /// Status codes.
  public static let ok: UInt32 = 0x8000
  public static let badMessage: UInt32 = 0x8001
  public static let notSupported: UInt32 = 0x8002
  public static let ioError: UInt32 = 0x8003

  /// PCM formats (VIRTIO_SND_PCM_FMT_*) and rates (VIRTIO_SND_PCM_RATE_*), as bit numbers.
  public static let formatS16: UInt8 = 5
  public static let formatS32: UInt8 = 17
  public static let formatFloat: UInt8 = 19
  public static let rates: [UInt32] = [5512, 8000, 11025, 16000, 22050, 32000, 44100, 48000, 64000, 88200, 96000,
                                       176400, 192000, 384000]
  public static func rateCode(_ hz: UInt32) -> UInt8? { rates.firstIndex(of: hz).map { UInt8($0) } }
  public static let output: UInt8 = 0

  static func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * UInt32($0))) } }

  /// virtio_snd_query_info for `count` PCM streams from `start` (each
  /// answer 32 bytes: virtio_snd_pcm_info).
  public static func queryPCM(start: UInt32, count: UInt32) -> [UInt8] {
    le32(pcmInfo) + le32(start) + le32(count) + le32(32)
  }

  /// virtio_snd_pcm_info, from its 32 bytes.
  public struct PCMInfo: Equatable, Sendable {
    public var features: UInt32
    public var formats: UInt64
    public var rates: UInt64
    public var direction: UInt8
    public var channelsMin: UInt8
    public var channelsMax: UInt8

    public init(_ b: ArraySlice<UInt8>) {
      func u32(_ o: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(b[b.startIndex + o + $1]) << (8 * UInt32($1)) } }
      func u64(_ o: Int) -> UInt64 { UInt64(u32(o)) | UInt64(u32(o + 4)) << 32 }
      features = u32(4)
      formats = u64(8)
      rates = u64(16)
      direction = b[b.startIndex + 24]
      channelsMin = b[b.startIndex + 25]
      channelsMax = b[b.startIndex + 26]
    }

    public func supports(format: UInt8) -> Bool { formats & (1 << UInt64(format)) != 0 }
    public func supports(rate hz: UInt32) -> Bool { rateCode(hz).map { rates & (1 << UInt64($0)) != 0 } ?? false }
  }

  /// virtio_snd_pcm_set_params.
  public static func setParams(stream: UInt32, bufferBytes: UInt32, periodBytes: UInt32, channels: UInt8, format: UInt8,
                               rate: UInt8) -> [UInt8]
  {
    le32(pcmSetParams) + le32(stream) + le32(bufferBytes) + le32(periodBytes) + le32(0) + [channels, format, rate, 0]
  }

  /// virtio_snd_pcm_hdr: prepare, release, start, stop.
  public static func pcm(_ code: UInt32, stream: UInt32) -> [UInt8] { le32(code) + le32(stream) }

  /// virtio_snd_pcm_xfer: an output buffer's header.
  public static func transfer(stream: UInt32) -> [UInt8] { le32(stream) }
}
