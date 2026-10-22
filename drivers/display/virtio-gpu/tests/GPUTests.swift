// SPDX-License-Identifier: BSD-3-Clause

// virtio-gpu's 2D requests and responses (M5a), byte for byte against
// Virtual I/O Device 1.2 §5.7.6.

import Testing
import VirtioGPU

func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)] }
func header(_ type: UInt32) -> [UInt8] { le32(type) + [UInt8](repeating: 0, count: 20) }

@Test func requestsHaveTheSpecificationsLayout() {
  #expect(GPU.getDisplayInfo() == header(0x0100))
  #expect(GPU.createResource(id: 7, width: 1280, height: 800) == header(0x0101) + le32(7) + le32(2) + le32(1280) + le32(800))
  #expect(GPU.setScanout(0, resource: 7, GPU.Rect(x: 0, y: 0, width: 1280, height: 800)).count == 48)
  #expect(GPU.setScanout(1, resource: 7, GPU.Rect(x: 0, y: 0, width: 4, height: 2)).suffix(8) == le32(1) + le32(7))
  #expect(GPU.flush(resource: 7, GPU.Rect(x: 1, y: 2, width: 3, height: 4))
    == header(0x0104) + le32(1) + le32(2) + le32(3) + le32(4) + le32(7) + le32(0))
  // A rectangle at (8, 2) in rows of 4096 bytes starts 2 * 4096 + 8 * 4 in.
  let t = GPU.transferToHost(resource: 7, GPU.Rect(x: 8, y: 2, width: 16, height: 16), stride: 4096)
  #expect(t.count == 56 && Array(t[40..<48]) == [32, 32, 0, 0, 0, 0, 0, 0] && Array(t[48..<52]) == le32(7))
  let a = GPU.attachBacking(resource: 7, pages: [0x1000, 0x5_0000_3000], page: 4096)
  #expect(a.count == 32 + 2 * 16 && Array(a[24..<32]) == le32(7) + le32(2))
  #expect(Array(a[48..<64]) == [0, 0x30, 0, 0, 5, 0, 0, 0] + le32(4096) + le32(0))
  #expect(GPU.getEDID(scanout: 0) == header(0x010A) + le32(0) + le32(0))
}

@Test func responsesDecode() {
  var info = header(0x1101)
  for i in 0..<16 {
    let enabled: UInt32 = i == 0 ? 1 : 0
    info += le32(0) + le32(0) + le32(i == 0 ? 1280 : 0) + le32(i == 0 ? 800 : 0) + le32(enabled) + le32(0)
  }
  let modes = GPU.displayInfo(info)
  #expect(modes?.count == 16 && modes?[0].rect == GPU.Rect(x: 0, y: 0, width: 1280, height: 800) && modes?[0].enabled == true)
  #expect(modes?[1].enabled == false)
  #expect(GPU.displayInfo(header(0x1200) + [UInt8](repeating: 0, count: 384)) == nil)
  let edid = header(0x1104) + le32(128) + le32(0) + [UInt8](repeating: 0xAB, count: 1024)
  #expect(GPU.edid(edid) == [UInt8](repeating: 0xAB, count: 128))
}

// The 3D side (M5g), against §5.7.6's structures.
@Test func threeDRequestsHaveTheSpecificationsLayout() {
  func u32(_ b: [UInt8], _ o: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(b[o + $1]) << (8 * $1) } }
  func u64(_ b: [UInt8], _ o: Int) -> UInt64 { UInt64(u32(b, o)) | UInt64(u32(b, o + 4)) << 32 }

  // A fenced submission on ring 3 of context 7: flags FENCE | INFO_RING_IDX.
  let submit = GPU.submit3D(7, stream: [1, 2, 3, 4, 5, 6, 7, 8], fence: 0x1_0000_0002, ring: 3)
  #expect(submit.count == 24 + 8 + 8)
  #expect(u32(submit, 0) == 0x0207 && u32(submit, 4) == 3 && u64(submit, 8) == 0x1_0000_0002)
  #expect(u32(submit, 16) == 7 && submit[20] == 3 && u32(submit, 24) == 8 && Array(submit[32...]) == [1, 2, 3, 4, 5, 6, 7, 8])
  // Unfenced: no flags, no ring.
  let plain = GPU.submit3D(7, stream: [])
  #expect(u32(plain, 4) == 0 && plain[20] == 0)

  // CTX_CREATE: nlen, context_init (the capset), 64 bytes of name.
  let create = GPU.contextCreate(7, capset: 4, name: Array("todhchai".utf8))
  #expect(create.count == 24 + 8 + 64 && u32(create, 0) == 0x0200 && u32(create, 16) == 7)
  #expect(u32(create, 24) == 8 && u32(create, 28) == 4 && Array(create[32..<40]) == Array("todhchai".utf8))

  // RESOURCE_CREATE_BLOB: resource, blob_mem HOST3D, flags, no entries, id, size.
  let blob = GPU.createBlob(7, resource: 5, flags: GPU.BlobFlag.mappable, blobID: 42, size: 1 << 20)
  #expect(blob.count == 24 + 32 && u32(blob, 0) == 0x010C && u32(blob, 16) == 7)
  #expect(u32(blob, 24) == 5 && u32(blob, 28) == 2 && u32(blob, 32) == 1 && u32(blob, 36) == 0)
  #expect(u64(blob, 40) == 42 && u64(blob, 48) == 1 << 20)

  // RESOURCE_MAP_BLOB: resource, padding, offset in the region.
  let map = GPU.mapBlob(7, resource: 5, offset: 0x20_0000)
  #expect(map.count == 24 + 16 && u32(map, 0) == 0x0208 && u32(map, 24) == 5 && u64(map, 32) == 0x20_0000)

  #expect(GPU.getCapsetInfo(index: 2).count == 32 && u32(GPU.getCapsetInfo(index: 2), 24) == 2)
  #expect(u32(GPU.getCapset(id: 4, version: 0), 24) == 4)
}

@Test func threeDResponsesDecode() {
  func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
  let header = { (type: UInt32, flags: UInt32, fence: UInt64) in
    le32(type) + le32(flags) + le32(UInt32(truncatingIfNeeded: fence)) + le32(UInt32(fence >> 32)) + [UInt8](repeating: 0, count: 8)
  }
  let info = header(0x1102, 0, 0) + le32(4) + le32(0) + le32(160) + le32(0)
  #expect(GPU.capsetInfo(info).map { [$0.id, $0.maxVersion, $0.maxSize] } == [4, 0, 160])
  let capset = header(0x1103, 0, 0) + [1, 0, 0, 0, 0x4E, 0x41, 0x40, 0]
  #expect(GPU.capset(capset, size: 8) == [1, 0, 0, 0, 0x4E, 0x41, 0x40, 0])
  #expect(GPU.mapInfo(header(0x1106, 0, 0) + le32(3) + le32(0)) == GPU.MapCache.writeCombined)
  #expect(GPU.mapInfo(header(0x1100, 0, 0) + le32(3) + le32(0)) == nil)
  #expect(GPU.fenceID(header(0x1100, 1, 77)) == 77)
  #expect(GPU.fenceID(header(0x1100, 0, 77)) == nil)
}
