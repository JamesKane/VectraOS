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


// MARK: The heap

public enum SamplerFilter: Sendable, Equatable { case nearest, linear }
public enum SamplerAddressMode: Sendable, Equatable {
  case clampToEdge, `repeat`, mirroredRepeat
  /// Mirrors once, then clamps to the edge.
  case mirrorClampToEdge
  /// Reads the sampler's `borderColor` outside the image.
  case clampToBorder
}
/// How a sampler picks between mip levels.
public enum SamplerMipmapMode: Sendable, Equatable { case nearest, linear }
/// What a sampler reads outside the image with `.clampToBorder`: transparent black, opaque black or opaque white, as
/// floats or as integers (for an integer format).
public enum BorderColor: Sendable, Equatable {
  case transparentBlackFloat, transparentBlackInt, opaqueBlackFloat, opaqueBlackInt, opaqueWhiteFloat, opaqueWhiteInt
}

/// A border colour of the sampler's own: four floats a float format reads, or four integers (an unsigned format reads
/// their bits) an integer format reads (`DeviceFeatures.customBorderColor`).
public enum CustomBorderColor: Sendable, Equatable {
  case float(Float, Float, Float, Float)
  case int(Int32, Int32, Int32, Int32)
}

public struct SamplerDescriptor: Sendable, Equatable {
  public var minFilter: SamplerFilter
  public var magFilter: SamplerFilter
  public var mipmapMode: SamplerMipmapMode
  public var addressModeU: SamplerAddressMode
  public var addressModeV: SamplerAddressMode
  public var addressModeW: SamplerAddressMode
  public var borderColor: BorderColor
  /// A border colour of the sampler's own, which `.clampToBorder` reads in place of `borderColor`; nil for `borderColor`'s.
  public var customBorderColor: CustomBorderColor?
  /// Added to the shader's level of detail, then the result clamped to `minLod` ... `maxLod`.
  public var mipLodBias: Float
  public var minLod: Float
  /// 1000 means no limit.
  public var maxLod: Float
  /// 1 for none; more filters anisotropically (up to `DeviceLimits.maxAnisotropy`).
  public var maxAnisotropy: Float
  /// A comparison sampler: the result is the comparison of the reference with the (depth) texel. nil for none.
  public var compare: CompareOp?
  /// The coordinates are in texels, not 0...1 (no mips, no anisotropy, no compare, clamped addressing).
  public var unnormalizedCoordinates: Bool

  /// `filter` sets both filters and `addressMode` all three axes, unless a field names one.
  public init(filter: SamplerFilter = .linear, addressMode: SamplerAddressMode = .clampToEdge, minFilter: SamplerFilter? = nil,
              magFilter: SamplerFilter? = nil, mipmapMode: SamplerMipmapMode = .nearest, addressModeU: SamplerAddressMode? = nil,
              addressModeV: SamplerAddressMode? = nil, addressModeW: SamplerAddressMode? = nil,
              borderColor: BorderColor = .transparentBlackFloat, mipLodBias: Float = 0, minLod: Float = 0, maxLod: Float = 1000,
              maxAnisotropy: Float = 1, compare: CompareOp? = nil, unnormalizedCoordinates: Bool = false,
              customBorderColor: CustomBorderColor? = nil) {
    self.customBorderColor = customBorderColor
    self.minFilter = minFilter ?? filter
    self.magFilter = magFilter ?? filter
    self.mipmapMode = mipmapMode
    self.addressModeU = addressModeU ?? addressMode
    self.addressModeV = addressModeV ?? addressMode
    self.addressModeW = addressModeW ?? addressMode
    self.borderColor = borderColor
    self.mipLodBias = mipLodBias
    self.minLod = minLod
    self.maxLod = maxLod
    self.maxAnisotropy = maxAnisotropy
    self.compare = compare
    self.unnormalizedCoordinates = unnormalizedCoordinates
  }

  /// The filter of a sampler whose two are the same (the minification filter otherwise).
  public var filter: SamplerFilter {
    get { minFilter }
    set {
      minFilter = newValue
      magFilter = newValue
    }
  }

  /// The addressing of a sampler whose three axes are the same (the U axis's otherwise).
  public var addressMode: SamplerAddressMode {
    get { addressModeU }
    set {
      addressModeU = newValue
      addressModeV = newValue
      addressModeW = newValue
    }
  }
}

// MARK: Pipelines

public enum BlendMode: Sendable, Equatable {
  /// The fragment's colour replaces the target's.
  case opaque
  /// Source alpha over: the fragment's colour by its alpha, the target's by what is left.
  case alpha
}

public enum PrimitiveTopology: Sendable, Equatable {
  case triangleList, triangleStrip, lineList, pointList
  case lineStrip, triangleFan
  /// Patches for the tessellation stages (`GraphicsPipelineDescriptor.patchControlPoints`).
  case patchList
}

/// A graphics pipeline: SPIR-V for a vertex and a fragment stage, and the fixed state a pass draws with. Shaders
/// read everything through the root pointer (a draw's one 64-bit push constant) and the heap, so there is no
/// vertex input state and no pipeline layout to state: every pipeline has the one.
///
/// Every field after `topology` has a default that means what the pipeline was before it was there: no depth or
/// stencil, no culling, filled polygons, one sample, the blend `blend` names on every target.
public struct GraphicsPipelineDescriptor: Sendable, Equatable {
  public var vertex: [UInt8]
  public var fragment: [UInt8]
  /// The colour attachments' formats, in order.
  public var colorFormats: [PixelFormat]
  public var blend: BlendMode
  public var topology: PrimitiveTopology
  /// The depth and stencil attachment's format, nil for a pass with none.
  public var depthStencilFormat: PixelFormat?
  public var depthStencil: DepthStencilState
  public var rasterization: RasterizationState
  public var multisample: MultisampleState
  /// The blend of each colour attachment, which replaces `blend` where not nil (one for each, or one for all).
  public var attachmentBlends: [ColorBlendAttachment]?
  public var logicOp: LogicOp?
  public var blendConstants: BlendConstants
  /// The state a pass's commands set in place of this descriptor's.
  public var dynamic: DynamicStates
  public var primitiveRestart: Bool
  /// Control points of a patch (`.patchList`).
  public var patchControlPoints: UInt32
  /// The stages beyond vertex and fragment, where a device has them.
  public var geometry: [UInt8]?
  public var tessellationControl: [UInt8]?
  public var tessellationEvaluation: [UInt8]?
  /// Values for the modules' specialization constants, by constant id.
  public var specialization: [SpecializationConstant]
  /// Views of an attachment that a multiview pass draws to (`RenderingInfo.viewMask`); 0 for none.
  public var viewMask: UInt32

  public init(vertex: [UInt8], fragment: [UInt8], colorFormats: [PixelFormat], blend: BlendMode = .alpha,
              topology: PrimitiveTopology = .triangleList, depthStencilFormat: PixelFormat? = nil,
              depthStencil: DepthStencilState = DepthStencilState(), rasterization: RasterizationState = RasterizationState(),
              multisample: MultisampleState = MultisampleState(), attachmentBlends: [ColorBlendAttachment]? = nil,
              logicOp: LogicOp? = nil, blendConstants: BlendConstants = BlendConstants(), dynamic: DynamicStates = DynamicStates(),
              primitiveRestart: Bool = false, patchControlPoints: UInt32 = 0, geometry: [UInt8]? = nil,
              tessellationControl: [UInt8]? = nil, tessellationEvaluation: [UInt8]? = nil,
              specialization: [SpecializationConstant] = [], viewMask: UInt32 = 0) {
    self.vertex = vertex
    self.fragment = fragment
    self.colorFormats = colorFormats
    self.blend = blend
    self.topology = topology
    self.depthStencilFormat = depthStencilFormat
    self.depthStencil = depthStencil
    self.rasterization = rasterization
    self.multisample = multisample
    self.attachmentBlends = attachmentBlends
    self.logicOp = logicOp
    self.blendConstants = blendConstants
    self.dynamic = dynamic
    self.primitiveRestart = primitiveRestart
    self.patchControlPoints = patchControlPoints
    self.geometry = geometry
    self.tessellationControl = tessellationControl
    self.tessellationEvaluation = tessellationEvaluation
    self.specialization = specialization
    self.viewMask = viewMask
  }

  /// The blend of each colour attachment: `attachmentBlends` (one entry stands for all), else `blend`'s on all.
  public var effectiveBlends: [ColorBlendAttachment] {
    if let b = attachmentBlends, !b.isEmpty {
      if b.count == 1 && colorFormats.count > 1 { return [ColorBlendAttachment](repeating: b[0], count: colorFormats.count) }
      return b
    }
    return [ColorBlendAttachment](repeating: blend == .alpha ? .alphaOver : .opaque, count: colorFormats.count)
  }

  /// What a pass must have for the pipeline to draw in it.
  public var targets: PipelineTargets {
    PipelineTargets(colorFormats: colorFormats, depthStencilFormat: depthStencilFormat, samples: multisample.samples,
                    viewMask: viewMask)
  }
}

public enum PipelineKind: Sendable, Equatable { case graphics, compute }

public struct GPUPipeline: Sendable, Equatable {
  public let handle: UInt64
  public let kind: PipelineKind
  /// The attachments a graphics pipeline draws into, for a backend that says (`GraphicsPipelineDescriptor.targets`):
  /// a pass is held to them. nil: not said, not checked.
  public let targets: PipelineTargets?
  public init(handle: UInt64, kind: PipelineKind, targets: PipelineTargets? = nil) {
    self.handle = handle
    self.kind = kind
    self.targets = targets
  }
}

// MARK: Queries

/// The counters a pipeline-statistics query reads, each a bit: the query's results hold one value for each set bit,
/// in the order of the bits.
public struct PipelineStatistics: Sendable, Equatable {
  public var rawValue: UInt32
  public init(rawValue: UInt32) { self.rawValue = rawValue }
  public static let inputAssemblyVertices = PipelineStatistics(rawValue: 1)
  public static let inputAssemblyPrimitives = PipelineStatistics(rawValue: 2)
  public static let vertexShaderInvocations = PipelineStatistics(rawValue: 4)
  public static let geometryShaderInvocations = PipelineStatistics(rawValue: 8)
  public static let geometryShaderPrimitives = PipelineStatistics(rawValue: 16)
  public static let clippingInvocations = PipelineStatistics(rawValue: 32)
  public static let clippingPrimitives = PipelineStatistics(rawValue: 64)
  public static let fragmentShaderInvocations = PipelineStatistics(rawValue: 128)
  public static let tessellationControlPatches = PipelineStatistics(rawValue: 256)
  public static let tessellationEvaluationInvocations = PipelineStatistics(rawValue: 512)
  public static let computeShaderInvocations = PipelineStatistics(rawValue: 1024)

  /// The number of counters set.
  public var count: Int { rawValue.nonzeroBitCount }
  public func contains(_ other: PipelineStatistics) -> Bool { rawValue & other.rawValue == other.rawValue }
  public static func | (a: PipelineStatistics, b: PipelineStatistics) -> PipelineStatistics {
    PipelineStatistics(rawValue: a.rawValue | b.rawValue)
  }
}

public enum QueryKind: Sendable, Equatable {
  /// A timestamp, in the device's ticks (`DeviceLimits.timestampPeriodPicoseconds`).
  case timestamp
  /// The samples that passed between `beginQuery` and `endQuery`.
  case occlusion
  /// The counters named, between `beginQuery` and `endQuery`: `results` returns one value for each counter of each query.
  case pipelineStatistics(PipelineStatistics)
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

/// What a device can do; a call it can't do throws `.unsupported`, and the feature says so beforehand. Each flag
/// from `depth` on is false by default (a device says what it has), and so is every one a backend didn't know of.
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

  // Images.
  /// Depth attachments: formats with a depth aspect, a depth test and write.
  public var depth = false
  /// Stencil attachments: formats with a stencil aspect, the stencil test.
  public var stencil = false
  /// Images of more than one mip level.
  public var mipmaps = false
  /// Images of more than one layer, and passes with layers.
  public var arrayImages = false
  public var cubeImages = false
  /// 3D images.
  public var volumeImages = false
  /// Multisampled images and passes (`DeviceLimits.maxSamples` and the format's counts say how many).
  public var multisample = false
  public var compressedASTC = false
  public var compressedETC2 = false
  public var compressedBC = false
  /// Two views of one image, or a view of another (compatible) format.
  public var imageViews = false
  /// 1D images, and 1D and 1D array views (`ImageDimension.d1`).
  public var images1D = false
  /// A view whose components are mapped (an `ImageView.swizzle` that isn't the identity).
  public var imageSwizzle = false

  // Samplers.
  public var samplerAnisotropy = false
  public var samplerCompare = false
  public var samplerBorder = false
  /// A sampler's own border colour (`SamplerDescriptor.customBorderColor`), float and integer, for any format.
  public var customBorderColor = false
  public var unnormalizedCoordinates = false
  /// A minification filter that isn't the magnification filter.
  public var samplerMinMagFilters = false
  /// Different addressing on the three axes.
  public var samplerAxisAddressModes = false
  /// `SamplerAddressMode.mirrorClampToEdge`.
  public var samplerMirrorClampToEdge = false

  // Pipeline state.
  /// Cull modes other than none.
  public var cullModes = false
  /// Rasterizer discard.
  public var rasterizerDiscard = false
  /// Every blend factor and operation, a colour write mask and blend constants: not only opaque and source alpha over.
  public var generalBlend = false
  public var independentBlend = false
  public var dualSourceBlend = false
  public var logicOps = false
  /// Polygon modes other than fill.
  public var fillModeNonSolid = false
  public var wideLines = false
  public var depthClamp = false
  public var depthBias = false
  public var depthBounds = false
  public var geometryShader = false
  public var tessellation = false
  public var multiview = false
  /// Line strips and triangle fans.
  public var extendedTopologies = false
  public var primitiveRestart = false
  public var sampleShading = false
  public var alphaToCoverage = false
  public var alphaToOne = false
  public var specializationConstants = false
  /// A pass's state set by commands (`DynamicStates`).
  public var dynamicState = false
  /// More than one colour attachment in a pass.
  public var multipleColorAttachments = false

  // Commands.
  public var copyImage = false
  public var blitImage = false
  public var resolveImage = false
  /// A pass that resolves its multisampled colour attachments as it ends, and one that resolves depth.
  public var resolveAttachments = false
  public var depthStencilResolve = false
  /// Copies between buffers and images with regions: mips, layers, offsets and a row length.
  public var imageRegionCopies = false
  public var fillBuffer = false
  public var updateBuffer = false
  public var clearImage = false
  public var clearAttachments = false
  public var drawIndirectCount = false
  public var pipelineStatisticsQueries = false
  /// Memory and images made over another process's pages (`importHandle`).
  public var importHandle = false
  /// A window's frames are the GPU's own images (`exportWindowHandle`): `makePresentImage` gives them direct and never
  /// staged, and refuses a frame the device can't share that way.
  public var presentDirect = false

  // What shaders may do (SPIR-V's capabilities).
  public var shaderFloat16 = false
  public var shaderInt8 = false
  public var shaderInt16 = false
  public var shaderInt64 = false
  public var shaderFloat64 = false
  /// Subgroup operations: basic, vote, ballot, arithmetic, shuffle and quad (`DeviceLimits.subgroupSize`).
  public var subgroupOperations = false
  /// Atomics on 32-bit and 64-bit integers in buffers.
  public var shaderAtomic32 = false
  public var shaderAtomic64 = false
  public var shaderImageAtomics = false
  public var shaderDerivatives = false
  public var shaderStorageImageExtendedFormats = false
  public var shaderStorageImageReadWithoutFormat = false
  public var shaderStorageImageWriteWithoutFormat = false
  public var shaderClipDistance = false
  public var shaderCullDistance = false
  public var shaderImageGatherExtended = false
  public var shaderMinLod = false
  public var shaderDrawParameters = false
  public var shaderDemoteToHelperInvocation = false
  public var shaderViewportIndexLayer = false
  public var shaderStencilExport = false
  public var shaderSampleRateShading = false
  public var shaderFloatControls = false

  // Texel buffers.
  /// Uniform texel buffers: `BufferView`s in the heap's texel-buffer slots, fetched by a shader (`samplerBuffer`).
  public var uniformTexelBuffers = false
  /// Storage texel buffers: `BufferView`s in the heap's storage-texel-buffer slots, read, written and (for the formats that
  /// say so) given atomics by a shader (`imageBuffer`).
  public var storageTexelBuffers = false
  public init() {}
}

public struct DeviceLimits: Sendable, Equatable {
  public var features = DeviceFeatures()
  /// Slots in the heap's three arrays.
  public var heapTextures: UInt32 = 0
  public var heapSamplers: UInt32 = 0
  public var heapStorageImages: UInt32 = 0
  /// Slots in the heap's two texel-buffer arrays: uniform texel buffers, and storage texel buffers.
  public var heapTexelBuffers: UInt32 = 0
  public var heapStorageTexelBuffers: UInt32 = 0
  /// The most texels a texel buffer view may cover.
  public var maxTexelBufferElements: UInt32 = 0
  public var maxImageDimension: Int32 = 0
  /// The largest 3D image's side, and the most layers of an image.
  public var maxImageDimension3D: Int32 = 0
  public var maxImageArrayLayers: UInt32 = 1
  /// The most samples of any multisampled image (1 for none).
  public var maxSamples: UInt32 = 1
  /// The most anisotropy a sampler may ask for (1 for none).
  public var maxAnisotropy: Float = 1
  /// The widest line a pipeline or a pass may set (`wideLines`), and the one that is always there.
  public var maxLineWidth: Float = 1
  /// The most colour attachments in a pass (1 where `multipleColorAttachments` is false).
  public var maxColorAttachments: UInt32 = 1
  /// The most views a multiview pass draws.
  public var maxMultiviewViews: UInt32 = 0
  /// The most control points of a patch.
  public var maxPatchControlPoints: UInt32 = 0
  /// Threads in a subgroup, 0 where there are no subgroup operations.
  public var subgroupSize: UInt32 = 0
  /// One timestamp tick, in picoseconds; 0 where there are no timestamps.
  public var timestampPeriodPicoseconds: UInt64 = 0
  /// What the device does with each format it lists; read with `formats(_:)`.
  public var formatTable: [FormatEntry] = []
  public init() {}
}
