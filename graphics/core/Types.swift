// SPDX-License-Identifier: BSD-3-Clause

// The core's vocabulary (D174 section 1; gpucore(2)): what a native GPU
// driver and a client of one say to each other. Nothing here names a
// graphics API: a backend maps these onto Vulkan (graphics/core/vulkan) or
// onto a GPU's own command streams (graphics/core/mali).
//
// Everything a client holds is a small value: a handle is a number the
// device made, which only that device understands. A handle is valid until
// it is destroyed, and destroying one is always safe: the device keeps the
// resource until the work submitted before the call has finished.

/// Why a core call failed.
public enum GPUError: Error, Equatable, Sendable {
  /// This device can't do it (a format, a feature, a size); the words say what.
  case unsupported(String)
  /// The caller broke the contract (a draw outside a pass, a handle from another device); the words say how.
  case invalid(String)
  /// The device is out of memory, heap slots or addresses.
  case outOfMemory(String)
  /// A call of the backend failed: its name, and the backend's own code.
  case failed(String, code: Int32)
  /// No device: nothing offers what this backend needs.
  case noDevice(String)
  /// The device is gone (a reset or a lost group); make another.
  case lost
}

// MARK: Memory

/// Where an allocation lives, by what it is for (D56).
public enum MemoryIntent: Sendable {
  /// CPU-written, GPU-read: per-frame data and uploads. Has a CPU pointer.
  case upload
  /// GPU-only: the fastest for the GPU. No CPU pointer.
  case device
  /// GPU-written, CPU-read: results to inspect. Has a CPU pointer.
  case readback
}

/// GPU memory: a 64-bit address a shader can follow, and where the intent allows, a CPU pointer to the same
/// bytes. `handle` is the device's.
@safe public struct GPUMemory: @unchecked Sendable, Equatable {
  public let handle: UInt64
  public let address: UInt64
  public let pointer: UnsafeMutableRawPointer?
  public let size: Int
  public let intent: MemoryIntent

  @unsafe public init(handle: UInt64, address: UInt64, pointer: UnsafeMutableRawPointer?, size: Int, intent: MemoryIntent) {
    self.handle = handle
    self.address = address
    unsafe self.pointer = unsafe pointer
    self.size = size
    self.intent = intent
  }

  public static func == (a: GPUMemory, b: GPUMemory) -> Bool { a.handle == b.handle && a.address == b.address }
}

// MARK: Images

public enum PixelFormat: Sendable, Equatable {
  case rgba8, bgra8, r8
  /// bgra8 whose bytes are sRGB: sampled and blended in light (D110).
  case bgra8srgb

  public var bytesPerPixel: Int { self == .r8 ? 1 : 4 }
}

/// What an image may be used for. The device picks its layout and tiling from this and tracks the layout itself;
/// there are no image layouts at the interface.
public struct ImageUsage: Sendable, Equatable {
  public var rawValue: UInt32
  public init(rawValue: UInt32) { self.rawValue = rawValue }
  /// Read by shaders through the heap's textures.
  public static let sampled = ImageUsage(rawValue: 1)
  /// Drawn into by a render pass.
  public static let renderTarget = ImageUsage(rawValue: 2)
  /// Read and written by shaders through the heap's storage images.
  public static let storage = ImageUsage(rawValue: 4)
  /// The source of a copy.
  public static let copySource = ImageUsage(rawValue: 8)
  /// The destination of a copy.
  public static let copyDestination = ImageUsage(rawValue: 16)

  public func contains(_ other: ImageUsage) -> Bool { rawValue & other.rawValue == other.rawValue }
  public static func | (a: ImageUsage, b: ImageUsage) -> ImageUsage { ImageUsage(rawValue: a.rawValue | b.rawValue) }
}

public struct ImageDescriptor: Sendable, Equatable {
  public var format: PixelFormat
  public var width: Int32
  public var height: Int32
  public var usage: ImageUsage
  public init(format: PixelFormat, width: Int32, height: Int32, usage: ImageUsage) {
    self.format = format
    self.width = width
    self.height = height
    self.usage = usage
  }
}

public struct GPUImage: Sendable, Equatable {
  public let handle: UInt64
  public let descriptor: ImageDescriptor
  public init(handle: UInt64, descriptor: ImageDescriptor) {
    self.handle = handle
    self.descriptor = descriptor
  }
  public var width: Int32 { descriptor.width }
  public var height: Int32 { descriptor.height }
  public var format: PixelFormat { descriptor.format }
  public var usage: ImageUsage { descriptor.usage }
}

// MARK: The heap

public enum SamplerFilter: Sendable, Equatable { case nearest, linear }
public enum SamplerAddressMode: Sendable, Equatable { case clampToEdge, `repeat`, mirroredRepeat }

public struct SamplerDescriptor: Sendable, Equatable {
  public var filter: SamplerFilter
  public var addressMode: SamplerAddressMode
  public init(filter: SamplerFilter = .linear, addressMode: SamplerAddressMode = .clampToEdge) {
    self.filter = filter
    self.addressMode = addressMode
  }
}

// MARK: Pipelines

public enum BlendMode: Sendable, Equatable {
  /// The fragment's colour replaces the target's.
  case opaque
  /// Source alpha over: the fragment's colour by its alpha, the target's by what is left.
  case alpha
}

public enum PrimitiveTopology: Sendable, Equatable { case triangleList, triangleStrip, lineList, pointList }

/// A graphics pipeline: SPIR-V for a vertex and a fragment stage, and the fixed state a pass draws with. Shaders
/// read everything through the root pointer (a draw's one 64-bit push constant) and the heap, so there is no
/// vertex input state and no pipeline layout to state: every pipeline has the one.
public struct GraphicsPipelineDescriptor: Sendable, Equatable {
  public var vertex: [UInt8]
  public var fragment: [UInt8]
  /// The colour attachments' formats, in order.
  public var colorFormats: [PixelFormat]
  public var blend: BlendMode
  public var topology: PrimitiveTopology
  public init(vertex: [UInt8], fragment: [UInt8], colorFormats: [PixelFormat], blend: BlendMode = .alpha,
              topology: PrimitiveTopology = .triangleList) {
    self.vertex = vertex
    self.fragment = fragment
    self.colorFormats = colorFormats
    self.blend = blend
    self.topology = topology
  }
}

public enum PipelineKind: Sendable, Equatable { case graphics, compute }

public struct GPUPipeline: Sendable, Equatable {
  public let handle: UInt64
  public let kind: PipelineKind
  public init(handle: UInt64, kind: PipelineKind) {
    self.handle = handle
    self.kind = kind
  }
}

// MARK: Queries

public enum QueryKind: Sendable, Equatable {
  /// A timestamp, in the device's ticks (`DeviceLimits.timestampPeriodPicoseconds`).
  case timestamp
  /// The samples that passed between `beginQuery` and `endQuery`.
  case occlusion
}

public struct GPUQuerySet: Sendable, Equatable {
  public let handle: UInt64
  public let kind: QueryKind
  public let count: Int
  public init(handle: UInt64, kind: QueryKind, count: Int) {
    self.handle = handle
    self.kind = kind
    self.count = count
  }
}

// MARK: Limits and features

/// What a device can do; a call it can't do throws `.unsupported`, and the feature says so beforehand.
public struct DeviceFeatures: Sendable, Equatable {
  public var computeQueue = false
  public var indirectDispatch = false
  public var indirectDraw = false
  public var indexedDraw = false
  public var sampledImages = false
  public var storageImages = false
  public var timestampQueries = false
  public var occlusionQueries = false
  /// A render pass can keep the attachment's contents (`LoadAction.load`).
  public var loadAttachments = false
  /// More than one draw in a pass, and more than one pass over an image.
  public var multipleDrawsPerPass = false
  public init() {}
}

public struct DeviceLimits: Sendable, Equatable {
  public var features = DeviceFeatures()
  /// Slots in the heap's three arrays.
  public var heapTextures: UInt32 = 0
  public var heapSamplers: UInt32 = 0
  public var heapStorageImages: UInt32 = 0
  public var maxImageDimension: Int32 = 0
  /// One timestamp tick, in picoseconds; 0 where there are no timestamps.
  public var timestampPeriodPicoseconds: UInt64 = 0
  public init() {}
}
