// SPDX-License-Identifier: BSD-3-Clause

// Memory and images over another process's pages (gpucore(2); panthor 04 section 4.8.3.1 and 09 section 9.6.4, 11 section
// 11.7.1): `exportHandle` gives a handle to the VMO behind memory, and `importHandle` maps the pages of such a handle into this
// device's VM, GPU-cacheable like all the memory of this backend, and into this process, as the VMO's owner mapped them (write-
// combining, for what this backend exports). The pages are the other process's too, so they are non-coherent for the CPU of
// either: nothing here takes it that a CPU write in the other process is visible without a barrier the writer made; what the
// GPU reads is what the owner had made visible when the submission was made, and every stream's end cleans and invalidates the
// GPU's caches (CSBuilder.cleanCachesForHost), so a later submission reads what was written in between.

import GPUCore

#if canImport(MaliCore)
  import MaliCore
#endif

extension MaliDevice {
  /// A new handle to the VMO behind `memory`: for another process to be given, which maps it (or imports it) as it likes.
  public func exportHandle(_ memory: GPUMemory) -> UInt32? {
    guard let region = memories[memory.handle] else { return nil }
    return region.buffer.exportMappableVMO()
  }

  /// A new handle to a `scanout` image's pages that another process may map and import (`importHandle(_:as:)`), where
  /// `exportHandle(_:)` gives the display's, which can't map them.
  public func exportMappableHandle(_ image: GPUImage) -> UInt32? {
    guard let r = images[image.handle], r.descriptor.usage.contains(.scanout), r.descriptor.format.bytesPerPixel == 4,
      r.rowStride == Int(r.descriptor.width) * 4
    else { return nil }
    return r.region.buffer.exportMappableVMO()
  }

  public func importHandle(_ vmo: UInt32, intent: MemoryIntent, bytes: Int) throws(GPUError) -> GPUMemory {
    guard bytes > 0 else { throw .invalid("an import of no bytes") }
    reclaim()
    let region = try makeImportedRegion(vmo, bytes: bytes)
    let handle = memories.insert(region)
    return unsafe GPUMemory(handle: handle, address: region.address, pointer: intent == .device ? nil : region.buffer.pointer,
                            size: bytes, intent: intent)
  }

  /// An image over the pages of `vmo`, laid out as an exported `scanout` image is: one level and layer of four-byte texels in rows
  /// of `width * 4` bytes (a multiple of 64). Its plane descriptors can't follow its texels (the pages are the owner's), so every
  /// view of it has an array of its own.
  public func importHandle(_ vmo: UInt32, as d: ImageDescriptor) throws(GPUError) -> GPUImage {
    guard d.dimension == .d2, d.mipLevels == 1, d.layers == 1, d.samples == 1, !d.format.isCompressed, !d.format.isDepthStencil,
      d.format.bytesPerPixel == 4, Int(d.width) * 4 % ImageLayout.alignment == 0
    else { throw .unsupported("an imported image that isn't one level of four-byte texels in rows of a multiple of 64 bytes") }
    var plain = d
    plain.usage = d.usage.contains(.scanout) ? d.usage : d.usage | .scanout
    if let e = plain.check(limits: baseLimits) { throw e }
    guard let texel = d.format.texelFormat(aspect: .color) else { throw .unsupported("an imported image of \(d.format)") }
    reclaim()
    let layout = ImageLayout(format: texel, kind: .linear, width: Int(d.width), height: Int(d.height))
    let region = try makeImportedRegion(vmo, bytes: layout.levels[0].rowStride * Int(d.height))
    let record = ImageRecord(region: region, descriptor: d, rowStride: layout.levels[0].rowStride, layout: layout, planeAt: nil)
    record.planes = [AspectPlane(aspect: .color, layout: layout, offset: 0, texel: texel)]
    return GPUImage(handle: images.insert(record), descriptor: d)
  }

  /// The pages of `vmo` mapped here and bound in the VM, GPU-cacheable.
  func makeImportedRegion(_ vmo: UInt32, bytes: Int) throws(GPUError) -> Region {
    let size = (bytes + 4095) & ~4095
    let buffer = try transport.importBuffer(vmo: vmo, size: size)
    let address: UInt64
    do { address = try takeAddress(size) } catch {
      transport.destroyBuffer(buffer)
      throw error
    }
    do { try transport.bind(vm: vm, buffer: buffer, address: address, gpuCacheable: true) } catch {
      transport.destroyBuffer(buffer)
      throw error
    }
    return Region(buffer: buffer, address: address, size: buffer.size)
  }
}
