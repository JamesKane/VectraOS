// SPDX-License-Identifier: BSD-3-Clause

// virtio-gpu (Virtual I/O Device 1.2 §5.7; M3k, the 2D commands since
// M5a): its feature bits and configuration, and the control queue's
// requests and responses, each a 24-byte header (§5.7.6.7) and its body,
// little endian. A request is one buffer the device reads and its
// response one it writes.

import Virtio

public enum GPU {
  public enum Feature {
    public static let virgl: UInt64 = 1 << 0
    public static let edid: UInt64 = 1 << 1
    public static let resourceUUID: UInt64 = 1 << 2
    public static let resourceBlob: UInt64 = 1 << 3
  }

  public struct Config: Equatable, Sendable {
    public var scanouts: UInt32
    public var capsets: UInt32

    public init(scanouts: UInt32, capsets: UInt32) {
      self.scanouts = scanouts
      self.capsets = capsets
    }
  }

  public static func config<W: Window>(_ d: Device<W>) -> Config {
    Config(scanouts: UInt32(truncatingIfNeeded: d.config(8, width: 4)),
           capsets: UInt32(truncatingIfNeeded: d.config(12, width: 4)))
  }

  /// The control queue's index, and the cursor queue's.
  public static let controlQueue = 0, cursorQueue = 1

  /// The configuration's `events_read` (at 0) and `events_clear` (at 4)
  /// bit for a display change (§5.7.4).
  public static let displayEvent: UInt32 = 1 << 0

  /// Command types (§5.7.6.7).
  public enum Command {
    public static let getDisplayInfo: UInt32 = 0x0100, resourceCreate2D: UInt32 = 0x0101,
      resourceUnref: UInt32 = 0x0102, setScanout: UInt32 = 0x0103, resourceFlush: UInt32 = 0x0104,
      transferToHost2D: UInt32 = 0x0105, attachBacking: UInt32 = 0x0106, detachBacking: UInt32 = 0x0107,
      getEDID: UInt32 = 0x010A
  }
  /// Response types: OK ones, and the first error.
  public enum Response {
    public static let okNoData: UInt32 = 0x1100, okDisplayInfo: UInt32 = 0x1101, okEDID: UInt32 = 0x1104,
      errorBase: UInt32 = 0x1200
  }
  /// B8G8R8X8_UNORM: bytes B, G, R, X, so a little-endian 0x00RRGGBB word.
  public static let formatB8G8R8X8: UInt32 = 2
  public static let headerSize = 24
  public static let maxScanouts = 16

  public struct Rect: Equatable, Sendable {
    public var x, y, width, height: UInt32
    public init(x: UInt32, y: UInt32, width: UInt32, height: UInt32) {
      self.x = x
      self.y = y
      self.width = width
      self.height = height
    }
  }

  /// A request's bytes: its header (no fence, context 0) and body.
  static func request(_ type: UInt32, _ body: [UInt32]) -> [UInt8] {
    var out = le32(type) + le32(0) + [UInt8](repeating: 0, count: 16)
    for w in body { out += le32(w) }
    return out
  }
  static func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)] }
  static func le64(_ v: UInt64) -> [UInt8] { le32(UInt32(truncatingIfNeeded: v)) + le32(UInt32(v >> 32)) }
  static func rect(_ r: Rect) -> [UInt32] { [r.x, r.y, r.width, r.height] }

  public static func getDisplayInfo() -> [UInt8] { request(Command.getDisplayInfo, []) }
  public static let displayInfoSize = headerSize + maxScanouts * 24
  public static func getEDID(scanout: UInt32) -> [UInt8] { request(Command.getEDID, [scanout, 0]) }
  public static let edidSize = headerSize + 8 + 1024

  public static func createResource(id: UInt32, width: UInt32, height: UInt32) -> [UInt8] {
    request(Command.resourceCreate2D, [id, formatB8G8R8X8, width, height])
  }
  public static func unref(id: UInt32) -> [UInt8] { request(Command.resourceUnref, [id, 0]) }
  public static func setScanout(_ scanout: UInt32, resource: UInt32, _ r: Rect) -> [UInt8] {
    request(Command.setScanout, rect(r) + [scanout, resource])
  }
  public static func flush(resource: UInt32, _ r: Rect) -> [UInt8] {
    request(Command.resourceFlush, rect(r) + [resource, 0])
  }
  /// The rectangle `r` of the resource (rows `stride` bytes) from its backing.
  public static func transferToHost(resource: UInt32, _ r: Rect, stride: UInt32) -> [UInt8] {
    let offset = UInt64(r.y) * UInt64(stride) + UInt64(r.x) * 4
    var out = request(Command.transferToHost2D, rect(r))
    out += le64(offset) + le32(resource) + le32(0)
    return out
  }
  /// Backing for the resource: its pages' device addresses, each `page` bytes.
  public static func attachBacking(resource: UInt32, pages: [UInt64], page: UInt32) -> [UInt8] {
    var out = request(Command.attachBacking, [resource, UInt32(pages.count)])
    for p in pages { out += le64(p) + le32(page) + le32(0) }
    return out
  }
  public static func detachBacking(resource: UInt32) -> [UInt8] { request(Command.detachBacking, [resource, 0]) }

  static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
    UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
  }
  /// A response's type.
  public static func responseType(_ b: [UInt8]) -> UInt32 { b.count >= 4 ? u32(b, 0) : 0 }

  /// GET_DISPLAY_INFO's modes: each scanout's rectangle and whether it's enabled.
  public static func displayInfo(_ b: [UInt8]) -> [(rect: Rect, enabled: Bool)]? {
    guard b.count >= displayInfoSize, responseType(b) == Response.okDisplayInfo else { return nil }
    return (0..<maxScanouts).map { i in
      let o = headerSize + i * 24
      return (Rect(x: u32(b, o), y: u32(b, o + 4), width: u32(b, o + 8), height: u32(b, o + 12)), u32(b, o + 16) != 0)
    }
  }

  /// GET_EDID's bytes.
  public static func edid(_ b: [UInt8]) -> [UInt8]? {
    guard b.count >= edidSize, responseType(b) == Response.okEDID else { return nil }
    let size = min(Int(u32(b, headerSize)), 1024)
    return Array(b[(headerSize + 8)..<(headerSize + 8 + size)])
  }
}
