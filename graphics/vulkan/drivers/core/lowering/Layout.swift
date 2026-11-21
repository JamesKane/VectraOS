// SPDX-License-Identifier: BSD-3-Clause

// The Vulkan layer's lowering (D174 step 5): what a Vulkan program's SPIR-V
// is rewritten against. Vulkan's descriptor sets, push constants and vertex
// input become reads through the core's one root pointer and its heap, so
// the core's pipelines take the result unchanged on every GPU. This file is
// the ABI the driver (graphics/vulkan/drivers/core) and the lowering share:
// the root block, the set records and the layouts that place them.

/// The root block the core's root pointer points at, one per draw or dispatch.
public enum RootBlock {
  /// `u64 set[4]`: each bound set record's GPU address, 0 where none is bound.
  public static let setsOffset = 0
  public static let maxSets = 4
  /// `u64 vertexBuffer[8]`: each bound vertex buffer's address plus its offset.
  public static let vertexBuffersOffset = 32
  public static let maxVertexBuffers = 8
  /// The push constants' bytes.
  public static let pushConstantsOffset = 96
  public static let maxPushConstantBytes = 128
  /// `u32 dynamicOffset[16]`: the dynamic offsets of the bound sets, as the pipeline layout orders them (by set, then
  /// by binding, then by element), each added to its buffer descriptor's address by the shader. Where the offsets
  /// live, and not in a copy of the set records, is the choice made in D174 (step 5, the design, part 2):
  ///   - the root block is written for every draw anyway, so a draw's dynamic offsets cost 64 bytes beside it,
  ///     where a copy of each dynamic set's record would cost its whole size (and a descriptor update between the
  ///     copy and the work would be lost, where Vulkan has the record read when the work runs);
  ///   - the set records stay what vkUpdateDescriptorSets wrote, so descriptor buffers (which hand the application
  ///     the record itself) and ordinary sets are one format;
  ///   - the existing offsets of the root block do not move: the region is appended after the push constants.
  /// The shader reads one 4-byte word and one 8-byte add for each dynamic descriptor it uses.
  /// 16 is above what Vulkan requires (8 uniform and 4 storage dynamic buffers per pipeline layout).
  public static let dynamicOffsetsOffset = 224
  public static let maxDynamicOffsets = 16
  public static let size = 288
}

/// What a descriptor is. Every descriptor is `descriptorSize` bytes in its set record:
/// - a buffer: `u64 address, u64 range`;
/// - a sampled image, a sampler or a storage image: `u32 slot` (its heap slot);
/// - a combined image sampler: `u32 textureSlot, u32 samplerSlot`.
public enum DescriptorKind: Sendable, Equatable {
  case uniformBuffer, storageBuffer, sampledImage, sampler, combinedImageSampler, storageImage
}

public let descriptorSize = 16

public struct DescriptorBinding: Sendable, Equatable {
  public var binding: UInt32
  public var kind: DescriptorKind
  /// Elements in the binding's array (1 for one descriptor).
  public var count: UInt32
  /// A dynamic uniform or storage buffer: each element's address gets one of the root block's dynamic offsets added
  /// (RootBlock.dynamicOffsetsOffset). The record is the same as for a plain buffer.
  public var dynamic: Bool
  public init(binding: UInt32, kind: DescriptorKind, count: UInt32 = 1, dynamic: Bool = false) {
    self.binding = binding
    self.kind = kind
    self.count = count
    self.dynamic = dynamic
  }
}

/// A set's bindings, each placed at its byte offset in the set record, in binding order.
public struct SetLayout: Sendable, Equatable {
  public private(set) var bindings: [DescriptorBinding] = []
  public private(set) var offsets: [UInt32] = []
  /// The record's size in bytes.
  public private(set) var size: Int = 0
  /// The dynamic descriptors the set has (each element of a dynamic binding counts): its share of the dynamic offsets.
  public private(set) var dynamicCount: Int = 0
  private var dynamicStarts: [Int] = []

  public init(bindings: [DescriptorBinding]) {
    let sorted = bindings.sorted { $0.binding < $1.binding }
    var at = 0
    for b in sorted {
      self.bindings.append(b)
      offsets.append(UInt32(at))
      dynamicStarts.append(dynamicCount)
      if b.dynamic { dynamicCount += Int(b.count) }
      at += Int(b.count) * descriptorSize
    }
    size = at
  }

  /// The index, among the set's dynamic offsets, of the first element of dynamic binding `binding`; nil for any other.
  public func dynamicIndex(_ binding: UInt32) -> Int? {
    for i in bindings.indices where bindings[i].binding == binding { return bindings[i].dynamic ? dynamicStarts[i] : nil }
    return nil
  }

  /// Binding `binding`'s offset and description, or nil where the set has no such binding.
  public func find(_ binding: UInt32) -> (offset: UInt32, binding: DescriptorBinding)? {
    for i in bindings.indices where bindings[i].binding == binding { return (offsets[i], bindings[i]) }
    return nil
  }
}

/// A vertex attribute's format, as the shader converts it from the buffer's words.
public enum VertexFormat: Sendable, Equatable {
  case r32Float, rg32Float, rgb32Float, rgba32Float
  case r32Uint, rg32Uint, rgb32Uint, rgba32Uint
  case r32Sint, rg32Sint, rgb32Sint, rgba32Sint
  /// Four bytes to four floats in [0, 1].
  case rgba8Unorm
  public var bytes: Int {
    switch self {
    case .r32Float, .r32Uint, .r32Sint, .rgba8Unorm: 4
    case .rg32Float, .rg32Uint, .rg32Sint: 8
    case .rgb32Float, .rgb32Uint, .rgb32Sint: 12
    case .rgba32Float, .rgba32Uint, .rgba32Sint: 16
    }
  }
}

public struct VertexBinding: Sendable, Equatable {
  public var binding: UInt32
  public var stride: UInt32
  public var perInstance: Bool
  public init(binding: UInt32, stride: UInt32, perInstance: Bool = false) {
    self.binding = binding
    self.stride = stride
    self.perInstance = perInstance
  }
}

public struct VertexAttribute: Sendable, Equatable {
  public var location: UInt32
  public var binding: UInt32
  public var format: VertexFormat
  public var offset: UInt32
  public init(location: UInt32, binding: UInt32, format: VertexFormat, offset: UInt32) {
    self.location = location
    self.binding = binding
    self.format = format
    self.offset = offset
  }
}

/// What a pipeline's stages are lowered against: its pipeline layout's sets and push constants, and for the vertex
/// stage, its vertex input.
public struct LoweringLayout: Sendable, Equatable {
  /// Set `i`'s layout, nil where the pipeline layout has none.
  public var sets: [SetLayout?]
  public var pushConstantBytes: Int
  public var vertexBindings: [VertexBinding]
  public var vertexAttributes: [VertexAttribute]
  /// The index, among the pipeline layout's dynamic offsets (RootBlock.dynamicOffsetsOffset), of set `set`'s first.
  public func dynamicBase(set: Int) -> Int {
    var n = 0
    for i in 0..<min(set, sets.count) { n += sets[i]?.dynamicCount ?? 0 }
    return n
  }

  public init(sets: [SetLayout?] = [], pushConstantBytes: Int = 0, vertexBindings: [VertexBinding] = [],
              vertexAttributes: [VertexAttribute] = []) {
    self.sets = sets
    self.pushConstantBytes = pushConstantBytes
    self.vertexBindings = vertexBindings
    self.vertexAttributes = vertexAttributes
  }
}

public enum ShaderStage: Sendable, Equatable { case vertex, fragment, compute }

/// Why a program couldn't be lowered: the words name what it uses.
public enum LoweringError: Error, Equatable, Sendable {
  /// The program uses something the layer leaves out (a 3D image, an input attachment...).
  case unsupported(String)
  /// The program and the layout disagree (a binding the layout has no entry for, a location with no attribute).
  case invalid(String)
  /// The words aren't SPIR-V the reader takes.
  case malformed(String)
}
