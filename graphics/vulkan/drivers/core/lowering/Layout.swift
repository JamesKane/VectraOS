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
  public static let size = 224
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
  public init(binding: UInt32, kind: DescriptorKind, count: UInt32 = 1) {
    self.binding = binding
    self.kind = kind
    self.count = count
  }
}

/// A set's bindings, each placed at its byte offset in the set record, in binding order.
public struct SetLayout: Sendable, Equatable {
  public private(set) var bindings: [DescriptorBinding] = []
  public private(set) var offsets: [UInt32] = []
  /// The record's size in bytes.
  public private(set) var size: Int = 0

  public init(bindings: [DescriptorBinding]) {
    let sorted = bindings.sorted { $0.binding < $1.binding }
    var at = 0
    for b in sorted {
      self.bindings.append(b)
      offsets.append(UInt32(at))
      at += Int(b.count) * descriptorSize
    }
    size = at
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
