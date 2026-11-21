// SPDX-License-Identifier: BSD-3-Clause

// Loinnir (sdk.md §5): the SDK's GPU library, in the "No Graphics API" style,
// over the core (D174 section 5; graphics/core, gpucore(2)). One device and
// queue, one bindless texture heap, one pipeline layout (the heap plus a root
// pointer per draw), memory by GPU address, and a 64-bit timeline for every
// submission. Which GPU driver is under it is the platform's choice: Vulkan
// (Venus under QEMU, a host's own) or a native driver such as Mali's.
//
//   let gpu = try Loinnir.open(window: win, loop: &loop)
//   let verts = try gpu.alloc(.upload, bytes: 64 << 10)
//   let pso = try gpu.pipeline(vertex: vs, fragment: fs, target: .bgra8)
//   if let target = try gpu.frame(&loop, config) {
//     var cmd = try gpu.commands()
//     cmd.render(to: target, clear: (0, 0, 0, 1)) { r in r.draw(pso, root: verts.address, vertices: 3) }
//     try gpu.present(&loop, config, after: try gpu.submit(cmd))
//   }

import GPUCore

@safe public final class Loinnir {
  public let gpu: GPUContext
  let core: any GPUDevice
  public private(set) var timelineValue: UInt64 = 0
  var textures = TextureTable()
  /// Heap slots: the next never used, and those freed, each reusable once the GPU is past the work submitted
  /// when it was freed.
  var nextSlot: UInt32 = 0
  var freeSlots: [UInt32] = []
  var retiredSlots: [(value: UInt64, slot: UInt32)] = []

  /// How frames reach a window, if there is one (the backend's: native/Present.swift).
  var presentation: (any LoinnirPresentation)?

  /// A GPU with no window, for offscreen work and tests.
  public static func headless() throws(LoinnirError) -> Loinnir {
    try Loinnir(gpu: try GPUContext())
  }

  init(gpu: GPUContext) throws(LoinnirError) {
    self.gpu = gpu
    core = gpu.core
    // The heap's one sampler: linear, clamped to the edge.
    if core.limits.features.sampledImages {
      do { try core.writeSampler(0, SamplerDescriptor(filter: .linear, addressMode: .clampToEdge)) } catch {
        throw LoinnirError(error)
      }
    }
  }

  deinit {
    presentation = nil
    try? core.wait(timelineValue)
    for t in textures.all { core.destroy(t) }
  }

  // MARK: Pipelines

  /// A graphics pipeline from SPIR-V: vertex and fragment shaders reading their inputs through the root pointer
  /// and the heap, drawing triangles into one color target with alpha blending.
  public func pipeline(vertex: [UInt8], fragment: [UInt8], target: TextureFormat) throws(LoinnirError) -> Pipeline {
    guard vertex.count % 4 == 0, vertex.count >= 20 else { throw .unsupported("not SPIR-V (\(vertex.count) bytes)") }
    guard fragment.count % 4 == 0, fragment.count >= 20 else { throw .unsupported("not SPIR-V (\(fragment.count) bytes)") }
    do {
      let p = try core.makeGraphicsPipeline(
        GraphicsPipelineDescriptor(vertex: vertex, fragment: fragment, colorFormats: [target.core], blend: .alpha))
      return Pipeline(core: p)
    } catch {
      throw LoinnirError(error)
    }
  }

  // MARK: Commands and the timeline

  /// A command list to record into.
  public func commands() throws(LoinnirError) -> CommandList {
    reclaim()
    return CommandList(owner: self)
  }

  /// Submits a recorded list. The GPU signals the returned timeline value when it's done.
  @discardableResult
  public func submit(_ list: consuming CommandList) throws(LoinnirError) -> UInt64 {
    let recorded = list.core
    let value = timelineValue + 1
    do {
      try core.graphicsQueue.submit(recorded, wait: 0, signal: value)
    } catch {
      throw LoinnirError(error)
    }
    timelineValue = value
    return value
  }

  /// Waits until the GPU has reached `value` on the timeline.
  public func wait(_ value: UInt64) throws(LoinnirError) {
    do { try core.wait(value) } catch { throw LoinnirError(error) }
    reclaim()
  }

  /// The timeline value the GPU has finished.
  public var completed: UInt64 { core.completed }

  /// Hands heap slots back that the GPU is done with.
  func reclaim() {
    let done = core.completed
    retiredSlots.removeAll { r in
      guard r.value <= done else { return false }
      freeSlots.append(r.slot)
      return true
    }
  }
}

/// The textures, by heap index (an array: tier 0 has no hashed collections).
struct TextureTable {
  var records: [GPUImage?] = []
  subscript(index: UInt32) -> GPUImage? {
    get { Int(index) < records.count ? records[Int(index)] : nil }
    set {
      while records.count <= Int(index) { records.append(nil) }
      records[Int(index)] = newValue
    }
  }
  var all: [GPUImage] { records.compactMap { $0 } }
}

/// A window's presentation, as a backend does it.
protocol LoinnirPresentation: AnyObject {}

/// A compiled pipeline.
@safe public struct Pipeline: @unchecked Sendable {
  let core: GPUPipeline
}

/// An image Loinnir owns, as an opaque handle outside Loinnir (a window's backbuffer is one).
@safe public final class ImageRecord {
  let image: GPUImage
  init(image: GPUImage) { self.image = image }
}

/// What a render pass draws into.
public enum RenderTarget {
  case texture(Texture)
  /// The window's image for this frame (from `frame`).
  case backbuffer(ImageRecord)
}
