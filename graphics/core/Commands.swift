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
  public var image: GPUImage
  public var load: LoadAction
  public var store: StoreAction
  public init(image: GPUImage, load: LoadAction, store: StoreAction = .store) {
    self.image = image
    self.load = load
    self.store = store
  }
}

/// A pass with dynamic rendering: the attachments it draws into, each with its load and store. The viewport and
/// scissor start as the whole of the first attachment.
public struct RenderingInfo: Sendable, Equatable {
  public var colors: [Attachment]
  public init(colors: [Attachment]) { self.colors = colors }
  public var width: Int32 { colors.first?.image.width ?? 0 }
  public var height: Int32 { colors.first?.image.height ?? 0 }
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

/// One recorded command.
public enum Command: Sendable, Equatable {
  case beginRendering(RenderingInfo)
  case endRendering
  case setViewport(x: Float, y: Float, width: Float, height: Float)
  case setScissor(x: Int32, y: Int32, width: UInt32, height: UInt32)
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
}

/// A recorded list of commands.
public struct GPUCommandList: Sendable, Equatable {
  public private(set) var commands: [Command] = []
  public init() {}
  public var isEmpty: Bool { commands.isEmpty }

  public mutating func append(_ c: Command) { commands.append(c) }
  public mutating func append(contentsOf other: GPUCommandList) { commands.append(contentsOf: other.commands) }

  public mutating func beginRendering(_ info: RenderingInfo) { commands.append(.beginRendering(info)) }
  public mutating func endRendering() { commands.append(.endRendering) }
  public mutating func setViewport(x: Float, y: Float, width: Float, height: Float) {
    commands.append(.setViewport(x: x, y: y, width: width, height: height))
  }
  public mutating func setScissor(x: Int32, y: Int32, width: UInt32, height: UInt32) {
    commands.append(.setScissor(x: x, y: y, width: width, height: height))
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

  /// Draws a pass: `body` records into the list between a begin and an end.
  public mutating func render(_ info: RenderingInfo, _ body: (inout GPUCommandList) -> Void) {
    beginRendering(info)
    body(&self)
    endRendering()
  }

  // MARK: The rules

  /// Whether the device can run the list, and if not, why not: the rules every backend holds a list to, so a
  /// list that one runs and another refuses is the other's refusal of a feature (`.unsupported`), never of
  /// the list's shape (`.invalid`).
  public func validate(features: DeviceFeatures) -> GPUError? {
    var pass: RenderingInfo?
    var passDraws = 0
    for c in commands {
      switch c {
      case .beginRendering(let info):
        if pass != nil { return .invalid("a pass begins inside a pass") }
        if info.colors.isEmpty { return .invalid("a pass with no attachment") }
        if info.colors.count > 8 { return .invalid("a pass with more than eight attachments") }
        for a in info.colors {
          if !a.image.usage.contains(.renderTarget) { return .invalid("an attachment that isn't a render target") }
          if a.image.width != info.width || a.image.height != info.height { return .invalid("attachments of different sizes") }
          if a.load == .load && !features.loadAttachments { return .unsupported("a pass that loads its attachment's contents") }
        }
        pass = info
        passDraws = 0
      case .endRendering:
        if pass == nil { return .invalid("a pass ends that didn't begin") }
        pass = nil
      case .setViewport, .setScissor:
        if pass == nil { return .invalid("a viewport or scissor outside a pass") }
      case .draw(let p, _, _, _, _, _):
        if let e = drawable(p, pass) { return e }
        passDraws += 1
        if passDraws > 1 && !features.multipleDrawsPerPass { return .unsupported("more than one draw in a pass") }
      case .drawIndexed(let p, _, let indices, let offset, let type, let count, _, let first, _, _):
        if let e = drawable(p, pass) { return e }
        if !features.indexedDraw { return .unsupported("indexed draws") }
        if offset < 0 || offset + (Int(first) + Int(count)) * type.bytes > indices.size { return .invalid("indices past their memory") }
        passDraws += 1
        if passDraws > 1 && !features.multipleDrawsPerPass { return .unsupported("more than one draw in a pass") }
      case .drawIndirect(let p, _, let args, let offset, let count, let stride):
        if let e = drawable(p, pass) { return e }
        if !features.indirectDraw { return .unsupported("indirect draws") }
        if offset < 0 || stride < 16 || count > 0 && offset + (Int(count) - 1) * Int(stride) + 16 > args.size {
          return .invalid("indirect arguments past their memory")
        }
        passDraws += 1
        if passDraws > 1 && !features.multipleDrawsPerPass { return .unsupported("more than one draw in a pass") }
      case .drawIndexedIndirect(let p, _, _, _, _, let args, let offset, let count, let stride):
        if let e = drawable(p, pass) { return e }
        if !features.indirectDraw || !features.indexedDraw { return .unsupported("indirect indexed draws") }
        if offset < 0 || stride < 20 || count > 0 && offset + (Int(count) - 1) * Int(stride) + 20 > args.size {
          return .invalid("indirect arguments past their memory")
        }
        passDraws += 1
        if passDraws > 1 && !features.multipleDrawsPerPass { return .unsupported("more than one draw in a pass") }
      case .dispatch(let p, _, let x, let y, let z):
        if pass != nil { return .invalid("a dispatch inside a pass") }
        if p.kind != .compute { return .invalid("a dispatch of a graphics pipeline") }
        if x == 0 || y == 0 || z == 0 { return .invalid("a dispatch of no workgroups") }
      case .dispatchIndirect(let p, _, let args, let offset):
        if pass != nil { return .invalid("a dispatch inside a pass") }
        if p.kind != .compute { return .invalid("a dispatch of a graphics pipeline") }
        if !features.indirectDispatch { return .unsupported("indirect dispatch") }
        if offset < 0 || offset + 12 > args.size { return .invalid("indirect arguments past their memory") }
      case .copyBuffer(let from, let fo, let dst, let dstOffset, let bytes):
        if pass != nil { return .invalid("a copy inside a pass") }
        if bytes < 0 || fo < 0 || dstOffset < 0 || fo + bytes > from.size || dstOffset + bytes > dst.size { return .invalid("a copy past its memory") }
      case .copyBufferToImage(let m, let offset, let image):
        if pass != nil { return .invalid("a copy inside a pass") }
        if !image.usage.contains(.copyDestination) { return .invalid("a copy into an image that isn't a copy destination") }
        if offset < 0 || offset + Int(image.width) * Int(image.height) * image.format.bytesPerPixel > m.size {
          return .invalid("a copy past its memory")
        }
      case .copyImageToBuffer(let image, let m, let offset):
        if pass != nil { return .invalid("a copy inside a pass") }
        if !image.usage.contains(.copySource) { return .invalid("a copy out of an image that isn't a copy source") }
        if offset < 0 || offset + Int(image.width) * Int(image.height) * image.format.bytesPerPixel > m.size {
          return .invalid("a copy past its memory")
        }
      case .barrier:
        if pass != nil { return .invalid("a barrier inside a pass") }
      case .writeTimestamp(let set, let index, _):
        if set.kind != .timestamp { return .invalid("a timestamp into an occlusion set") }
        if !features.timestampQueries { return .unsupported("timestamp queries") }
        if index < 0 || index >= set.count { return .invalid("a query past its set") }
      case .beginQuery(let set, let index), .endQuery(let set, let index):
        if set.kind != .occlusion { return .invalid("an occlusion query in a timestamp set") }
        if !features.occlusionQueries { return .unsupported("occlusion queries") }
        if pass == nil { return .invalid("an occlusion query outside a pass") }
        if index < 0 || index >= set.count { return .invalid("a query past its set") }
      }
    }
    if pass != nil { return .invalid("a pass that never ends") }
    return nil
  }

  private func drawable(_ p: GPUPipeline, _ pass: RenderingInfo?) -> GPUError? {
    if pass == nil { return .invalid("a draw outside a pass") }
    if p.kind != .graphics { return .invalid("a draw with a compute pipeline") }
    return nil
  }
}
