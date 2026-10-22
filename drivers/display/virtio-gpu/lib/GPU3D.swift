// SPDX-License-Identifier: BSD-3-Clause

// virtio-gpu's 3D side (Virtual I/O Device 1.3 §5.7; M5g): capability
// sets, contexts on a capset (CONTEXT_INIT), blob resources and their
// mapping into the host-visible shared memory region, command submission,
// and fences. A request's header names its context, and a fenced one its
// fence id and, with INFO_RING_IDX, the context's timeline (ring) it is on:
// the device answers it only once the fence has signalled, so answers can
// come back in another order than the requests went.

extension GPU {
  public enum Feature3D {
    public static let contextInit: UInt64 = 1 << 4
  }

  public enum Command3D {
    public static let getCapsetInfo: UInt32 = 0x0108, getCapset: UInt32 = 0x0109, resourceCreateBlob: UInt32 = 0x010C,
      contextCreate: UInt32 = 0x0200, contextDestroy: UInt32 = 0x0201, contextAttach: UInt32 = 0x0202,
      contextDetach: UInt32 = 0x0203, submit3D: UInt32 = 0x0207, resourceMapBlob: UInt32 = 0x0208,
      resourceUnmapBlob: UInt32 = 0x0209
  }

  public enum Response3D {
    public static let okCapsetInfo: UInt32 = 0x1102, okCapset: UInt32 = 0x1103, okMapInfo: UInt32 = 0x1106
  }

  /// Header flags: a fence, and the timeline it is on.
  public enum Flag {
    public static let fence: UInt32 = 1 << 0
    public static let ringIndex: UInt32 = 1 << 1
  }

  /// blob_mem: memory the host makes for the context (Venus's blobs).
  public static let blobHost3D: UInt32 = 2
  public enum BlobFlag {
    public static let mappable: UInt32 = 1, shareable: UInt32 = 2, crossDevice: UInt32 = 4
  }

  /// The shared memory region host-visible blobs are mapped into (§5.7.5).
  public static let hostVisibleRegion: UInt8 = 1

  /// map_info's cache types.
  public enum MapCache {
    public static let cached: UInt32 = 1, uncached: UInt32 = 2, writeCombined: UInt32 = 3
  }

  /// A request's header (§5.7.6.7): type, flags, fence id, context, ring.
  public static func header(_ type: UInt32, context: UInt32 = 0, fence: UInt64? = nil, ring: UInt8? = nil) -> [UInt8] {
    let flags = (fence != nil ? Flag.fence : 0) | (fence != nil && ring != nil ? Flag.ringIndex : 0)
    return le32(type) + le32(flags) + le64(fence ?? 0) + le32(context) + [ring ?? 0, 0, 0, 0]
  }

  public static func getCapsetInfo(index: UInt32) -> [UInt8] { header(Command3D.getCapsetInfo) + le32(index) + le32(0) }
  public static let capsetInfoSize = headerSize + 16

  /// GET_CAPSET_INFO's answer: the capset's id, highest version and size.
  public static func capsetInfo(_ b: [UInt8]) -> (id: UInt32, maxVersion: UInt32, maxSize: UInt32)? {
    guard b.count >= capsetInfoSize, responseType(b) == Response3D.okCapsetInfo else { return nil }
    return (u32(b, headerSize), u32(b, headerSize + 4), u32(b, headerSize + 8))
  }

  public static func getCapset(id: UInt32, version: UInt32) -> [UInt8] { header(Command3D.getCapset) + le32(id) + le32(version) }

  /// GET_CAPSET's answer: the capset's bytes.
  public static func capset(_ b: [UInt8], size: Int) -> [UInt8]? {
    guard b.count >= headerSize + size, responseType(b) == Response3D.okCapset else { return nil }
    return Array(b[headerSize..<(headerSize + size)])
  }

  /// A context on capset `capset` (context_init's low byte), named for
  /// the host's logs (up to 64 bytes).
  public static func contextCreate(_ context: UInt32, capset: UInt32, name: [UInt8]) -> [UInt8] {
    let n = Array(name.prefix(64))
    return header(Command3D.contextCreate, context: context) + le32(UInt32(n.count)) + le32(capset & 0xFF) + n
      + [UInt8](repeating: 0, count: 64 - n.count)
  }

  public static func contextDestroy(_ context: UInt32) -> [UInt8] { header(Command3D.contextDestroy, context: context) }

  public static func contextAttach(_ context: UInt32, resource: UInt32) -> [UInt8] {
    header(Command3D.contextAttach, context: context) + le32(resource) + le32(0)
  }

  public static func contextDetach(_ context: UInt32, resource: UInt32) -> [UInt8] {
    header(Command3D.contextDetach, context: context) + le32(resource) + le32(0)
  }

  /// A blob the host makes for `context`'s object `blobID` (0: shared
  /// memory, for Venus), with no guest pages behind it.
  public static func createBlob(_ context: UInt32, resource: UInt32, flags: UInt32, blobID: UInt64, size: UInt64)
    -> [UInt8]
  {
    header(Command3D.resourceCreateBlob, context: context) + le32(resource) + le32(blobHost3D) + le32(flags) + le32(0)
      + le64(blobID) + le64(size)
  }

  /// Maps a blob at `offset` in the host-visible region.
  public static func mapBlob(_ context: UInt32, resource: UInt32, offset: UInt64) -> [UInt8] {
    header(Command3D.resourceMapBlob, context: context) + le32(resource) + le32(0) + le64(offset)
  }
  public static let mapInfoSize = headerSize + 8

  /// RESOURCE_MAP_BLOB's answer: how the CPU should map it.
  public static func mapInfo(_ b: [UInt8]) -> UInt32? {
    guard b.count >= mapInfoSize, responseType(b) == Response3D.okMapInfo else { return nil }
    return u32(b, headerSize) & 0x0F
  }

  public static func unmapBlob(_ context: UInt32, resource: UInt32) -> [UInt8] {
    header(Command3D.resourceUnmapBlob, context: context) + le32(resource) + le32(0)
  }

  /// A command stream for `context`'s renderer, fenced on `ring` if
  /// `fence` is given.
  public static func submit3D(_ context: UInt32, stream: [UInt8], fence: UInt64? = nil, ring: UInt8? = nil) -> [UInt8] {
    header(Command3D.submit3D, context: context, fence: fence, ring: ring) + le32(UInt32(stream.count)) + le32(0) + stream
  }

  /// A response header's fence id, for matching a fenced request's answer.
  public static func fenceID(_ b: [UInt8]) -> UInt64? {
    guard b.count >= headerSize, u32(b, 4) & Flag.fence != 0 else { return nil }
    return UInt64(u32(b, 8)) | UInt64(u32(b, 12)) << 32
  }
}
