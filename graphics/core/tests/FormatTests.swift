// SPDX-License-Identifier: BSD-3-Clause

// The format table (D174 amendment): each format's texel block, aspects and numeric type against the Vulkan
// specification's values (VulkanFormatFacts, from data/vk.xml), and the capability query.

import Testing

@testable import GPUCore

private func fact(_ f: PixelFormat) -> (name: String, blockSize: Int, blockWidth: Int, blockHeight: Int, components: String)? {
  let n = vulkanName(f)
  for row in vulkanFormatFacts where row.name == n { return row }
  return nil
}

@Suite struct FormatTableTests {
  @Test func everyFormatHasASpecificationRowAndNoTwoShareOne() {
    var seen: [String] = []
    for f in PixelFormat.all {
      #expect(fact(f) != nil, "no row for \(f)")
      let n = vulkanName(f)
      #expect(!seen.contains(n), "\(n) twice")
      seen.append(n)
    }
    #expect(PixelFormat.all.count == vulkanFormatFacts.count)
  }

  @Test func blockSizesAndExtentsAreTheSpecificationsForEachFormat() {
    for f in PixelFormat.all {
      guard let row = fact(f) else { continue }
      let b = f.texelBlock
      #expect(b.bytes == row.blockSize, "\(row.name) block bytes \(b.bytes) vs \(row.blockSize)")
      #expect(b.width == row.blockWidth && b.height == row.blockHeight, "\(row.name) block extent")
    }
  }

  @Test func aspectsAreTheSpecificationsComponents() {
    for f in PixelFormat.all {
      guard let row = fact(f) else { continue }
      var expected = 0 as UInt32
      for c in row.components.split(separator: " ") {
        switch c.first {
        case "D": expected |= ImageAspects.depth.rawValue
        case "S": expected |= ImageAspects.stencil.rawValue
        default: expected |= ImageAspects.color.rawValue
        }
      }
      #expect(f.aspects.rawValue == expected, "\(row.name) aspects")
      #expect(f.isDepthStencil == (expected & ImageAspects.color.rawValue == 0))
    }
  }

  @Test func numericTypesAreTheSpecificationsFirstComponents() {
    for f in PixelFormat.all {
      guard let row = fact(f), let first = row.components.split(separator: " ").first else { continue }
      let type = first.split(separator: ":")[1]
      let expected: NumericType = switch type {
      case "UNORM": .unorm
      case "SNORM": .snorm
      case "UINT": .uint
      case "SINT": .sint
      case "SFLOAT": .float
      case "UFLOAT": .ufloat
      case "SRGB": .srgb
      default: .unorm
      }
      #expect(f.numericType == expected, "\(row.name) numeric type")
    }
  }

  @Test func compressedFormatsAreThoseWithBlocksOrCompressedComponents() {
    for f in PixelFormat.all {
      guard let row = fact(f) else { continue }
      #expect(f.isCompressed == (row.name.hasSuffix("_BLOCK")), "\(row.name)")
      #expect(f.isCompressed == (f.family != nil))
    }
  }

  @Test func theFamiliesAreTheirFormats() {
    #expect(PixelFormat.astc(.b8x6).family == .astc && PixelFormat.astcSRGB(.b4x4).family == .astc)
    #expect(PixelFormat.etc2rgb8.family == .etc2 && PixelFormat.eacRG11snorm.family == .etc2)
    #expect(PixelFormat.bc7srgb.family == .bc && PixelFormat.bc4.family == .bc)
    #expect(PixelFormat.rgba8.family == nil && PixelFormat.depth16.family == nil)
    #expect(ASTCBlock.all.count == 14)
  }

  @Test func theOldFormatsKeepTheirNamesAndSizes() {
    #expect(PixelFormat.rgba8.bytesPerPixel == 4)
    #expect(PixelFormat.bgra8.bytesPerPixel == 4)
    #expect(PixelFormat.bgra8srgb.bytesPerPixel == 4)
    #expect(PixelFormat.r8.bytesPerPixel == 1)
    #expect(PixelFormat.bgra8srgb.isSRGB && !PixelFormat.bgra8.isSRGB)
    #expect(PixelFormat.astc(.b4x4).bytesPerPixel == 0)
  }

  @Test func byteSizesCountWholeBlocks() {
    #expect(PixelFormat.rgba8.byteSize(width: 5, height: 3) == 60)
    #expect(PixelFormat.astc(.b4x4).byteSize(width: 5, height: 5) == 4 * 16)
    #expect(PixelFormat.astc(.b12x12).byteSize(width: 13, height: 1) == 2 * 16)
    #expect(PixelFormat.bc1rgb.byteSize(width: 4, height: 4) == 8)
    #expect(PixelFormat.rgba8.byteSize(width: 2, height: 2, depth: 3) == 48)
    #expect(PixelFormat.depth32fstencil8.byteSize(width: 2, height: 2) == 20)
    #expect(PixelFormat.depth32fstencil8.byteSize(width: 2, height: 2, aspect: .depth) == 16)
    #expect(PixelFormat.depth32fstencil8.byteSize(width: 2, height: 2, aspect: .stencil) == 4)
    #expect(PixelFormat.depth24stencil8.bytesPerTexel(aspect: .depth) == 4)
    #expect(PixelFormat.depth16.bytesPerTexel(aspect: .stencil) == 0)
  }

  @Test func theDescriptorSizesItsMips() {
    let d = ImageDescriptor(format: .rgba8, width: 100, height: 37, mipLevels: 7, usage: .sampled)
    #expect(d.maxMipLevels == 7)
    #expect(d.mipExtent(0).width == 100 && d.mipExtent(1).width == 50 && d.mipExtent(6).width == 1)
    #expect(d.mipExtent(6).height == 1)
    #expect(d.byteSize(mip: 1) == 50 * 18 * 4)
    let v = ImageDescriptor(format: .r8, width: 8, height: 4, depth: 16, dimension: .d3, usage: .sampled)
    #expect(v.maxMipLevels == 5)
    #expect(v.mipExtent(2).depth == 4 && v.byteSize(mip: 0) == 8 * 4 * 16)
  }

  @Test func theCapabilityQueryIsWhatABackendFilled() {
    var l = DeviceLimits()
    #expect(l.formats(.rgba8) == FormatCapabilities())
    #expect(!l.formats(.rgba8).sampled)
    var c = FormatCapabilities()
    c.sampled = true
    c.renderTarget = true
    c.renderSamples = .upToFour
    l.setFormat(.rgba8, c)
    #expect(l.formats(.rgba8).renderTarget && l.formats(.rgba8).renderSamples.contains(4))
    #expect(!l.formats(.rgba8).renderSamples.contains(8))
    #expect(!l.formats(.bgra8).sampled)
    c.sampled = false
    l.setFormat(.rgba8, c)
    #expect(!l.formats(.rgba8).sampled)
    #expect(l.formatTable.count == 1)
  }

  @Test func sampleCountsAreSetsOfPowersOfTwo() {
    #expect(SampleCounts.upToEight.contains(1) && SampleCounts.upToEight.contains(8))
    #expect(!SampleCounts.upToEight.contains(16))
    #expect(!SampleCounts.upToEight.contains(3))
    #expect(!SampleCounts.upToEight.contains(0))
    #expect(!SampleCounts.upToEight.contains(128))
    #expect(SampleCounts.upToEight.maximum == 8)
    #expect(SampleCounts.none.maximum == 0)
    #expect(SampleCounts(rawValue: 64).contains(64))
  }

  @Test func theFakeFullDeviceListsEveryFormat() {
    let l = FakeDevice.fullLimits()
    #expect(l.formatTable.count == PixelFormat.all.count)
    #expect(l.formats(.depth32f).depthTarget && !l.formats(.depth32f).renderTarget)
    #expect(l.formats(.astc(.b6x6)).sampled && !l.formats(.astc(.b6x6)).renderTarget)
    #expect(l.formats(.r32uint).storageAtomic && !l.formats(.r32float).storageAtomic)
  }

  @Test func theFakeFullDeviceHasEveryFeature() {
    // Every Bool of DeviceFeatures is true on the full device: a flag added without being set there is found here.
    let f = FakeDevice.fullFeatures()
    for child in Mirror(reflecting: f).children {
      #expect(child.value as? Bool == true, "\(child.label ?? "?") is not set on the full device")
    }
  }

  @Test func aDefaultDeviceHasNoNewFeature() {
    // Every flag the core gained is false by default: a device that doesn't say has none.
    let f = DeviceFeatures()
    for child in Mirror(reflecting: f).children {
      #expect(child.value as? Bool == false, "\(child.label ?? "?") defaults to true")
    }
    #expect(DeviceLimits().formatTable.isEmpty && DeviceLimits().maxSamples == 1)
  }
}
