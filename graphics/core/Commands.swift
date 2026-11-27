// SPDX-License-Identifier: BSD-3-Clause

// Command lists (D174 section 1; gpucore(2)): what a client records and a queue
// runs. A list is data: an array of commands that name resources by handle
// and address, built with no device in hand and replayed by the backend at
// `submit`. So a list needs no image layout (the backend tracks each image's
// as it replays) and no API object, and the same rules judge it everywhere:
// `validate` is the one place those rules are written.
//
// A draw and a dispatch name their pipeline and one 64-bit root pointer, the
// GPU address of whatever the shaders read; the heap's textures, samplers
// and storage images are reached by index through that data.

/// What happens to an attachment's contents when a pass begins. A tiler needs this before the pass starts.
public enum LoadAction: Sendable, Equatable {
  /// Keep what is there (`DeviceFeatures.loadAttachments`).
  case load
  /// Fill with this colour (red, green, blue, alpha).
  case clear(Float, Float, Float, Float)
  /// The contents are about to be all drawn over: whatever is there may be lost.
  case dontCare
}

/// What happens to an attachment's contents when a pass ends.
public enum StoreAction: Sendable, Equatable {
  case store
  /// Nothing reads it afterwards: the device need not write it out.
  case discard
}

public struct Attachment: Sendable, Equatable {
  /// What the pass draws into: a view (the whole image, for the `image:` initializer).
  public var view: ImageView
  public var load: LoadAction
  public var store: StoreAction
  /// A single-sample view the pass resolves this multisampled attachment into as it ends (`DeviceFeatures.resolveAttachments`).
  public var resolve: ImageView?
  public init(image: GPUImage, load: LoadAction, store: StoreAction = .store) {
    self.view = ImageView(image)
    self.load = load
    self.store = store
    self.resolve = nil
  }
  public init(view: ImageView, load: LoadAction, store: StoreAction = .store, resolve: ImageView? = nil) {
    self.view = view
    self.load = load
    self.store = store
    self.resolve = resolve
  }
  /// The attachment's image; setting it makes the view the whole of the new image.
  public var image: GPUImage {
    get { view.image }
    set { view = ImageView(newValue) }
  }
}

/// What happens to one aspect (depth or stencil) of the depth and stencil attachment when a pass begins.
public enum AspectLoad: Sendable, Equatable {
  /// Keep what is there (`DeviceFeatures.loadAttachments`).
  case load
  /// Fill with the attachment's clear value.
  case clear
  case dontCare
}

/// A pass's depth and stencil attachment: a view of an image with the `depthStencilTarget` usage, the load and store
/// of each aspect, and the value a clear writes.
public struct DepthStencilAttachment: Sendable, Equatable {
  public var view: ImageView
  public var depthLoad: AspectLoad
  public var stencilLoad: AspectLoad
  public var depthStore: StoreAction
  public var stencilStore: StoreAction
  public var clearDepth: Float
  public var clearStencil: UInt32
  /// A single-sample view the pass resolves this attachment's depth and stencil into as it ends (`DeviceFeatures.depthStencilResolve`).
  public var resolve: ImageView?
  public init(view: ImageView, depthLoad: AspectLoad = .clear, stencilLoad: AspectLoad = .clear, depthStore: StoreAction = .store,
              stencilStore: StoreAction = .store, clearDepth: Float = 1, clearStencil: UInt32 = 0, resolve: ImageView? = nil) {
    self.view = view
    self.depthLoad = depthLoad
    self.stencilLoad = stencilLoad
    self.depthStore = depthStore
    self.stencilStore = stencilStore
    self.clearDepth = clearDepth
    self.clearStencil = clearStencil
    self.resolve = resolve
  }
  public init(image: GPUImage, depthLoad: AspectLoad = .clear, stencilLoad: AspectLoad = .clear, depthStore: StoreAction = .store,
              stencilStore: StoreAction = .store, clearDepth: Float = 1, clearStencil: UInt32 = 0) {
    self.init(view: ImageView(image), depthLoad: depthLoad, stencilLoad: stencilLoad, depthStore: depthStore,
              stencilStore: stencilStore, clearDepth: clearDepth, clearStencil: clearStencil)
  }
}

/// A rectangle of the attachments, in texels.
public struct RenderArea: Sendable, Equatable {
  public var x: Int32
  public var y: Int32
  public var width: UInt32
  public var height: UInt32
  public init(x: Int32 = 0, y: Int32 = 0, width: UInt32, height: UInt32) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }
}

/// A viewport: the rectangle of the attachments that normalized device coordinates map onto, and the depths that 0 and 1 map
/// to. A negative height flips it.
public struct Viewport: Sendable, Equatable {
  public var x: Float
  public var y: Float
  public var width: Float
  public var height: Float
  public var minDepth: Float
  public var maxDepth: Float
  public init(x: Float = 0, y: Float = 0, width: Float, height: Float, minDepth: Float = 0, maxDepth: Float = 1) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
    self.minDepth = minDepth
    self.maxDepth = maxDepth
  }
}

/// A pass with dynamic rendering: the attachments it draws into, each with its load and store. Every viewport and
/// scissor starts as the whole of the first attachment (depths 0 to 1).
public struct RenderingInfo: Sendable, Equatable {
  public var colors: [Attachment]
  public var depthStencil: DepthStencilAttachment?
  /// Layers drawn to (`DeviceFeatures.arrayImages`); 1 unless `viewMask` is 0 and the attachments have layers.
  public var layerCount: UInt32
  /// A multiview pass: bit n makes view n draw into layer n of each attachment (`DeviceFeatures.multiview`). 0 for none.
  public var viewMask: UInt32
  /// The part of the attachments the pass draws in; nil for all of them.
  public var renderArea: RenderArea?
  public init(colors: [Attachment], depthStencil: DepthStencilAttachment? = nil, layerCount: UInt32 = 1, viewMask: UInt32 = 0,
              renderArea: RenderArea? = nil) {
    self.colors = colors
    self.depthStencil = depthStencil
    self.layerCount = layerCount
    self.viewMask = viewMask
    self.renderArea = renderArea
  }
  public var width: Int32 { colors.first?.view.width ?? depthStencil?.view.width ?? 0 }
  public var height: Int32 { colors.first?.view.height ?? depthStencil?.view.height ?? 0 }
  /// Samples of every attachment's texel.
  public var samples: UInt32 { colors.first?.view.samples ?? depthStencil?.view.samples ?? 1 }
  /// The area drawn in: `renderArea`, or all of the attachments.
  public var area: RenderArea { renderArea ?? RenderArea(width: UInt32(max(width, 0)), height: UInt32(max(height, 0))) }
}

/// The stages a barrier names (D58): which earlier work must finish before which later work starts. There are no
/// access masks and no layouts: a barrier makes the earlier stages' writes visible to the later stages' reads
/// and writes.
public struct PipelineStages: Sendable, Equatable {
  public var rawValue: UInt32
  public init(rawValue: UInt32) { self.rawValue = rawValue }
  public static let compute = PipelineStages(rawValue: 1)
  public static let vertex = PipelineStages(rawValue: 2)
  public static let fragment = PipelineStages(rawValue: 4)
  public static let transfer = PipelineStages(rawValue: 8)
  public static let all = PipelineStages(rawValue: 15)

  public func contains(_ other: PipelineStages) -> Bool { rawValue & other.rawValue == other.rawValue }
  public static func | (a: PipelineStages, b: PipelineStages) -> PipelineStages {
    PipelineStages(rawValue: a.rawValue | b.rawValue)
  }
}

public enum IndexType: Sendable, Equatable {
  case uint16, uint32
  public var bytes: Int { self == .uint16 ? 2 : 4 }
}

// MARK: Regions and clears

public struct Offset3D: Sendable, Equatable {
  public var x: Int32
  public var y: Int32
  public var z: Int32
  public init(x: Int32 = 0, y: Int32 = 0, z: Int32 = 0) {
    self.x = x
    self.y = y
    self.z = z
  }
}

public struct Extent3D: Sendable, Equatable {
  public var width: UInt32
  public var height: UInt32
  public var depth: UInt32
  public init(width: UInt32, height: UInt32, depth: UInt32 = 1) {
    self.width = width
    self.height = height
    self.depth = depth
  }
}

/// A region of an image copied to a region of another (or the same) image, or resolved: the extent is in texels of
/// the source (blocks of the same size, for compressed formats).
public struct ImageCopyRegion: Sendable, Equatable {
  public var srcSubresource: ImageSubresourceLayers
  public var srcOffset: Offset3D
  public var dstSubresource: ImageSubresourceLayers
  public var dstOffset: Offset3D
  public var extent: Extent3D
  public init(srcSubresource: ImageSubresourceLayers = ImageSubresourceLayers(), srcOffset: Offset3D = Offset3D(),
              dstSubresource: ImageSubresourceLayers = ImageSubresourceLayers(), dstOffset: Offset3D = Offset3D(), extent: Extent3D) {
    self.srcSubresource = srcSubresource
    self.srcOffset = srcOffset
    self.dstSubresource = dstSubresource
    self.dstOffset = dstOffset
    self.extent = extent
  }
}

/// A region blitted: the source corners are scaled onto the destination's, and a corner past the other flips the image.
public struct ImageBlitRegion: Sendable, Equatable {
  public var srcSubresource: ImageSubresourceLayers
  public var srcMin: Offset3D
  public var srcMax: Offset3D
  public var dstSubresource: ImageSubresourceLayers
  public var dstMin: Offset3D
  public var dstMax: Offset3D
  public init(srcSubresource: ImageSubresourceLayers = ImageSubresourceLayers(), srcMin: Offset3D = Offset3D(), srcMax: Offset3D,
              dstSubresource: ImageSubresourceLayers = ImageSubresourceLayers(), dstMin: Offset3D = Offset3D(), dstMax: Offset3D) {
    self.srcSubresource = srcSubresource
    self.srcMin = srcMin
    self.srcMax = srcMax
    self.dstSubresource = dstSubresource
    self.dstMin = dstMin
    self.dstMax = dstMax
  }
}

/// A region of an image copied to or from a buffer: rows of `bufferRowLength` texels (0: the extent's width), slices of
/// `bufferImageHeight` rows (0: the extent's height), from `bufferOffset`. Texels are blocks, for a compressed format.
public struct BufferImageRegion: Sendable, Equatable {
  public var bufferOffset: Int
  public var bufferRowLength: UInt32
  public var bufferImageHeight: UInt32
  public var subresource: ImageSubresourceLayers
  public var imageOffset: Offset3D
  public var imageExtent: Extent3D
  public init(bufferOffset: Int = 0, bufferRowLength: UInt32 = 0, bufferImageHeight: UInt32 = 0,
              subresource: ImageSubresourceLayers = ImageSubresourceLayers(), imageOffset: Offset3D = Offset3D(), imageExtent: Extent3D) {
    self.bufferOffset = bufferOffset
    self.bufferRowLength = bufferRowLength
    self.bufferImageHeight = bufferImageHeight
    self.subresource = subresource
    self.imageOffset = imageOffset
    self.imageExtent = imageExtent
  }
}

/// The value a clear writes into a colour image: floats for a unorm, snorm, sRGB or float format, integers for the others.
public enum ClearColor: Sendable, Equatable {
  case float(Float, Float, Float, Float)
  case uint(UInt32, UInt32, UInt32, UInt32)
  case sint(Int32, Int32, Int32, Int32)

  public var channelClass: ChannelClass {
    switch self {
    case .float: .float
    case .uint: .uint
    case .sint: .sint
    }
  }
}

/// One attachment a `clearAttachments` command clears: colour attachment `index`, or the depth and stencil attachment's aspects.
public enum ClearAttachment: Sendable, Equatable {
  case color(index: Int, ClearColor)
  case depthStencil(aspects: ImageAspects, depth: Float, stencil: UInt32)
}

/// A rectangle and the layers of it a `clearAttachments` command clears.
public struct ClearRect: Sendable, Equatable {
  public var x: Int32
  public var y: Int32
  public var width: UInt32
  public var height: UInt32
  public var baseLayer: UInt32
  public var layerCount: UInt32
  public init(x: Int32 = 0, y: Int32 = 0, width: UInt32, height: UInt32, baseLayer: UInt32 = 0, layerCount: UInt32 = 1) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
    self.baseLayer = baseLayer
    self.layerCount = layerCount
  }
}

/// One recorded command.
public enum Command: Sendable, Equatable {
  case beginRendering(RenderingInfo)
  case endRendering
  case setViewport(x: Float, y: Float, width: Float, height: Float)
  case setScissor(x: Int32, y: Int32, width: UInt32, height: UInt32)
  /// Viewports `first` on, with their depth ranges; past the first needs `DeviceFeatures.multiViewport`.
  case setViewports(first: UInt32, [Viewport])
  /// Scissors `first` on, one for each viewport.
  case setScissors(first: UInt32, [RenderArea])
  case draw(GPUPipeline, root: UInt64, vertexCount: UInt32, instanceCount: UInt32, firstVertex: UInt32, firstInstance: UInt32)
  case drawIndexed(GPUPipeline, root: UInt64, indices: GPUMemory, indexOffset: Int, indexType: IndexType, indexCount: UInt32,
                   instanceCount: UInt32, firstIndex: UInt32, vertexOffset: Int32, firstInstance: UInt32)
  /// `drawCount` draws whose arguments (four 32-bit words each: vertexCount, instanceCount, firstVertex,
  /// firstInstance) are in `arguments` at `offset`, `stride` bytes apart.
  case drawIndirect(GPUPipeline, root: UInt64, arguments: GPUMemory, offset: Int, drawCount: UInt32, stride: UInt32)
  /// Arguments of five 32-bit words each: indexCount, instanceCount, firstIndex, vertexOffset, firstInstance.
  case drawIndexedIndirect(GPUPipeline, root: UInt64, indices: GPUMemory, indexOffset: Int, indexType: IndexType,
                           arguments: GPUMemory, offset: Int, drawCount: UInt32, stride: UInt32)
  case dispatch(GPUPipeline, root: UInt64, x: UInt32, y: UInt32, z: UInt32)
  /// Three 32-bit words at `offset`: the workgroup counts.
  case dispatchIndirect(GPUPipeline, root: UInt64, arguments: GPUMemory, offset: Int)
  case copyBuffer(from: GPUMemory, fromOffset: Int, to: GPUMemory, toOffset: Int, bytes: Int)
  /// Tightly packed rows of the image's format, from `offset`.
  case copyBufferToImage(GPUMemory, offset: Int, GPUImage)
  case copyImageToBuffer(GPUImage, GPUMemory, offset: Int)
  case barrier(from: PipelineStages, to: PipelineStages)
  case writeTimestamp(GPUQuerySet, index: Int, after: PipelineStages)
  case beginQuery(GPUQuerySet, index: Int)
  case endQuery(GPUQuerySet, index: Int)
  // The full feature set (D174's amendment): each of these needs a feature `validate` names.
  /// Copies regions between two images (or one): `DeviceFeatures.copyImage`.
  case copyImage(src: GPUImage, dst: GPUImage, regions: [ImageCopyRegion])
  /// Scales regions of one image onto regions of another: `DeviceFeatures.blitImage`.
  case blitImage(src: GPUImage, dst: GPUImage, regions: [ImageBlitRegion], filter: SamplerFilter)
  /// Resolves a multisampled colour image into a single-sampled one: `DeviceFeatures.resolveImage`.
  case resolveImage(src: GPUImage, dst: GPUImage, regions: [ImageCopyRegion])
  /// `DeviceFeatures.imageRegionCopies`.
  case copyBufferToImageRegions(GPUMemory, GPUImage, regions: [BufferImageRegion])
  case copyImageToBufferRegions(GPUImage, GPUMemory, regions: [BufferImageRegion])
  case fillBuffer(GPUMemory, offset: Int, bytes: Int, value: UInt32)
  case updateBuffer(GPUMemory, offset: Int, data: [UInt8])
  case clearColorImage(GPUImage, ClearColor, ranges: [ImageSubresourceRange])
  case clearDepthStencilImage(GPUImage, depth: Float, stencil: UInt32, ranges: [ImageSubresourceRange])
  /// Inside a pass: clears parts of its attachments.
  case clearAttachments([ClearAttachment], rects: [ClearRect])
  /// The state a pipeline leaves to the pass (`DynamicStates`), set inside a pass.
  case setBlendConstants(BlendConstants)
  case setStencilReference(StencilFaces, UInt32)
  case setStencilCompareMask(StencilFaces, UInt32)
  case setStencilWriteMask(StencilFaces, UInt32)
  case setDepthBias(constant: Float, clamp: Float, slope: Float)
  case setDepthBounds(min: Float, max: Float)
  case setLineWidth(Float)
  /// Draws as many as the 32-bit count at `countOffset` of `countBuffer` says, up to `maxDrawCount`.
  case drawIndirectCount(GPUPipeline, root: UInt64, arguments: GPUMemory, offset: Int, countBuffer: GPUMemory, countOffset: Int,
                         maxDrawCount: UInt32, stride: UInt32)
  case drawIndexedIndirectCount(GPUPipeline, root: UInt64, indices: GPUMemory, indexOffset: Int, indexType: IndexType,
                                arguments: GPUMemory, offset: Int, countBuffer: GPUMemory, countOffset: Int, maxDrawCount: UInt32,
                                stride: UInt32)
  /// A barrier that names the subresources it concerns, for a backend that can use them.
  case imageBarrier(from: PipelineStages, to: PipelineStages, image: GPUImage, range: ImageSubresourceRange)
}

/// A recorded list of commands.
public struct GPUCommandList: Sendable, Equatable {
  public private(set) var commands: [Command] = []
  public init() {}
  public var isEmpty: Bool { commands.isEmpty }
  public var count: Int { commands.count }

  public mutating func append(_ c: Command) { commands.append(c) }
  /// `c` before the command at `index` (`count`: after the last). A recorder that learns a pass's begin only as the pass
  /// ends puts it before the pass's commands this way, moving them rather than copying them.
  public mutating func insert(_ c: Command, at index: Int) { commands.insert(c, at: index) }
  public mutating func append(contentsOf other: GPUCommandList) { commands.append(contentsOf: other.commands) }

  public mutating func beginRendering(_ info: RenderingInfo) { commands.append(.beginRendering(info)) }
  public mutating func endRendering() { commands.append(.endRendering) }
  public mutating func setViewport(x: Float, y: Float, width: Float, height: Float) {
    commands.append(.setViewport(x: x, y: y, width: width, height: height))
  }
  public mutating func setScissor(x: Int32, y: Int32, width: UInt32, height: UInt32) {
    commands.append(.setScissor(x: x, y: y, width: width, height: height))
  }
  public mutating func setViewports(first: UInt32 = 0, _ viewports: [Viewport]) {
    commands.append(.setViewports(first: first, viewports))
  }
  public mutating func setScissors(first: UInt32 = 0, _ scissors: [RenderArea]) {
    commands.append(.setScissors(first: first, scissors))
  }
  public mutating func draw(_ pipeline: GPUPipeline, root: UInt64, vertices: UInt32, instances: UInt32 = 1,
                            firstVertex: UInt32 = 0, firstInstance: UInt32 = 0) {
    commands.append(.draw(pipeline, root: root, vertexCount: vertices, instanceCount: instances, firstVertex: firstVertex,
                          firstInstance: firstInstance))
  }
  public mutating func drawIndexed(_ pipeline: GPUPipeline, root: UInt64, indices: GPUMemory, indexOffset: Int = 0,
                                   indexType: IndexType, count: UInt32, instances: UInt32 = 1, firstIndex: UInt32 = 0,
                                   vertexOffset: Int32 = 0, firstInstance: UInt32 = 0) {
    commands.append(.drawIndexed(pipeline, root: root, indices: indices, indexOffset: indexOffset, indexType: indexType,
                                 indexCount: count, instanceCount: instances, firstIndex: firstIndex,
                                 vertexOffset: vertexOffset, firstInstance: firstInstance))
  }
  public mutating func drawIndirect(_ pipeline: GPUPipeline, root: UInt64, arguments: GPUMemory, offset: Int = 0,
                                    drawCount: UInt32 = 1, stride: UInt32 = 16) {
    commands.append(.drawIndirect(pipeline, root: root, arguments: arguments, offset: offset, drawCount: drawCount, stride: stride))
  }
  public mutating func drawIndexedIndirect(_ pipeline: GPUPipeline, root: UInt64, indices: GPUMemory, indexOffset: Int = 0,
                                           indexType: IndexType, arguments: GPUMemory, offset: Int = 0,
                                           drawCount: UInt32 = 1, stride: UInt32 = 20) {
    commands.append(.drawIndexedIndirect(pipeline, root: root, indices: indices, indexOffset: indexOffset,
                                         indexType: indexType, arguments: arguments, offset: offset, drawCount: drawCount,
                                         stride: stride))
  }
  public mutating func dispatch(_ pipeline: GPUPipeline, root: UInt64, x: UInt32, y: UInt32 = 1, z: UInt32 = 1) {
    commands.append(.dispatch(pipeline, root: root, x: x, y: y, z: z))
  }
  public mutating func dispatchIndirect(_ pipeline: GPUPipeline, root: UInt64, arguments: GPUMemory, offset: Int = 0) {
    commands.append(.dispatchIndirect(pipeline, root: root, arguments: arguments, offset: offset))
  }
  public mutating func copy(_ from: GPUMemory, fromOffset: Int = 0, to: GPUMemory, toOffset: Int = 0, bytes: Int) {
    commands.append(.copyBuffer(from: from, fromOffset: fromOffset, to: to, toOffset: toOffset, bytes: bytes))
  }
  public mutating func copy(_ from: GPUMemory, offset: Int = 0, to image: GPUImage) {
    commands.append(.copyBufferToImage(from, offset: offset, image))
  }
  public mutating func copy(_ image: GPUImage, to memory: GPUMemory, offset: Int = 0) {
    commands.append(.copyImageToBuffer(image, memory, offset: offset))
  }
  public mutating func barrier(from: PipelineStages = .all, to: PipelineStages = .all) {
    commands.append(.barrier(from: from, to: to))
  }
  public mutating func writeTimestamp(_ set: GPUQuerySet, index: Int, after: PipelineStages = .all) {
    commands.append(.writeTimestamp(set, index: index, after: after))
  }
  public mutating func beginQuery(_ set: GPUQuerySet, index: Int) { commands.append(.beginQuery(set, index: index)) }
  public mutating func endQuery(_ set: GPUQuerySet, index: Int) { commands.append(.endQuery(set, index: index)) }


  // MARK: The full feature set

  public mutating func copyImage(_ src: GPUImage, to dst: GPUImage, regions: [ImageCopyRegion]) {
    commands.append(.copyImage(src: src, dst: dst, regions: regions))
  }
  public mutating func blitImage(_ src: GPUImage, to dst: GPUImage, regions: [ImageBlitRegion], filter: SamplerFilter = .nearest) {
    commands.append(.blitImage(src: src, dst: dst, regions: regions, filter: filter))
  }
  public mutating func resolveImage(_ src: GPUImage, to dst: GPUImage, regions: [ImageCopyRegion]) {
    commands.append(.resolveImage(src: src, dst: dst, regions: regions))
  }
  public mutating func copy(_ from: GPUMemory, to image: GPUImage, regions: [BufferImageRegion]) {
    commands.append(.copyBufferToImageRegions(from, image, regions: regions))
  }
  public mutating func copy(_ image: GPUImage, to memory: GPUMemory, regions: [BufferImageRegion]) {
    commands.append(.copyImageToBufferRegions(image, memory, regions: regions))
  }
  public mutating func fill(_ memory: GPUMemory, offset: Int = 0, bytes: Int, value: UInt32) {
    commands.append(.fillBuffer(memory, offset: offset, bytes: bytes, value: value))
  }
  public mutating func update(_ memory: GPUMemory, offset: Int = 0, data: [UInt8]) {
    commands.append(.updateBuffer(memory, offset: offset, data: data))
  }
  public mutating func clear(_ image: GPUImage, color: ClearColor, ranges: [ImageSubresourceRange]? = nil) {
    commands.append(.clearColorImage(image, color, ranges: ranges ?? [ImageSubresourceRange(all: image)]))
  }
  public mutating func clear(_ image: GPUImage, depth: Float, stencil: UInt32 = 0, ranges: [ImageSubresourceRange]? = nil) {
    commands.append(.clearDepthStencilImage(image, depth: depth, stencil: stencil, ranges: ranges ?? [ImageSubresourceRange(all: image)]))
  }
  public mutating func clearAttachments(_ attachments: [ClearAttachment], rects: [ClearRect]) {
    commands.append(.clearAttachments(attachments, rects: rects))
  }
  public mutating func setBlendConstants(_ constants: BlendConstants) { commands.append(.setBlendConstants(constants)) }
  public mutating func setStencilReference(_ faces: StencilFaces = .both, _ value: UInt32) {
    commands.append(.setStencilReference(faces, value))
  }
  public mutating func setStencilCompareMask(_ faces: StencilFaces = .both, _ value: UInt32) {
    commands.append(.setStencilCompareMask(faces, value))
  }
  public mutating func setStencilWriteMask(_ faces: StencilFaces = .both, _ value: UInt32) {
    commands.append(.setStencilWriteMask(faces, value))
  }
  public mutating func setDepthBias(constant: Float, clamp: Float = 0, slope: Float) {
    commands.append(.setDepthBias(constant: constant, clamp: clamp, slope: slope))
  }
  public mutating func setDepthBounds(min: Float, max: Float) { commands.append(.setDepthBounds(min: min, max: max)) }
  public mutating func setLineWidth(_ width: Float) { commands.append(.setLineWidth(width)) }
  public mutating func drawIndirectCount(_ pipeline: GPUPipeline, root: UInt64, arguments: GPUMemory, offset: Int = 0,
                                         countBuffer: GPUMemory, countOffset: Int = 0, maxDrawCount: UInt32, stride: UInt32 = 16) {
    commands.append(.drawIndirectCount(pipeline, root: root, arguments: arguments, offset: offset, countBuffer: countBuffer,
                                       countOffset: countOffset, maxDrawCount: maxDrawCount, stride: stride))
  }
  public mutating func drawIndexedIndirectCount(_ pipeline: GPUPipeline, root: UInt64, indices: GPUMemory, indexOffset: Int = 0,
                                                indexType: IndexType, arguments: GPUMemory, offset: Int = 0, countBuffer: GPUMemory,
                                                countOffset: Int = 0, maxDrawCount: UInt32, stride: UInt32 = 20) {
    commands.append(.drawIndexedIndirectCount(pipeline, root: root, indices: indices, indexOffset: indexOffset,
                                              indexType: indexType, arguments: arguments, offset: offset, countBuffer: countBuffer,
                                              countOffset: countOffset, maxDrawCount: maxDrawCount, stride: stride))
  }
  public mutating func barrier(image: GPUImage, range: ImageSubresourceRange? = nil, from: PipelineStages = .all,
                               to: PipelineStages = .all) {
    commands.append(.imageBarrier(from: from, to: to, image: image, range: range ?? ImageSubresourceRange(all: image)))
  }

  /// Draws a pass: `body` records into the list between a begin and an end.
  public mutating func render(_ info: RenderingInfo, _ body: (inout GPUCommandList) -> Void) {
    beginRendering(info)
    body(&self)
    endRendering()
  }

}
