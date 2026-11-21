// SPDX-License-Identifier: BSD-3-Clause

// Render passes and framebuffers (D174 amendment, step 5). The core draws in one pass at a time, each with its
// attachments, so a render pass of several subpasses is run as that many core passes: a subpass draws into the
// attachments it names, loading (`.load`) what an earlier subpass stored, and the last subpass to use an attachment
// gives it the render pass's store operation. Subpass dependencies are the core's own tracking. Input attachments
// have no core word and are refused.

import GPUCore
import TDVulkan

struct PassAttachment {
  var format: PixelFormat
  var samples: UInt32
  var load: VkAttachmentLoadOp
  var store: StoreAction
  var stencilLoad: VkAttachmentLoadOp
  var stencilStore: StoreAction
}

struct Subpass {
  /// Indices into the render pass's attachments.
  var colors: [Int]
  /// The attachment each colour attachment resolves into, or nil.
  var resolves: [Int?]
  var depthStencil: Int?
  /// The attachment the depth and stencil attachment resolves into, or nil.
  var depthStencilResolve: Int?
  var viewMask: UInt32
  /// The attachments the subpass reads as input attachments, each as a texture of its view (indices into the attachments).
  var inputs: [Int] = []
}

final class RenderPassObject: CoreObject {
  let attachments: [PassAttachment]
  let subpasses: [Subpass]
  init(attachments: [PassAttachment], subpasses: [Subpass]) {
    self.attachments = attachments
    self.subpasses = subpasses
  }

  /// What a pipeline made for subpass `index` draws into.
  func targets(_ index: Int, samples: UInt32? = nil) -> PipelineTargets? {
    guard index < subpasses.count else { return nil }
    let s = subpasses[index]
    var count: UInt32 = 1
    if let first = s.colors.first { count = attachments[first].samples } else if let d = s.depthStencil { count = attachments[d].samples }
    return PipelineTargets(colorFormats: s.colors.map { attachments[$0].format }, depthStencilFormat: s.depthStencil.map { attachments[$0].format },
                           samples: samples ?? count, viewMask: s.viewMask)
  }

  /// Whether a subpass after `index` reads attachment `a` as an input attachment: what the core's pass that ends at `index` stores must
  /// then be kept, whatever the render pass's store operation says of the end of the whole pass.
  func readLater(_ a: Int, after index: Int) -> Bool {
    for i in subpasses.indices where i > index && subpasses[i].inputs.contains(a) { return true }
    return false
  }

  /// The first and the last subpass that draws into attachment `a`.
  func span(_ a: Int) -> (first: Int, last: Int)? {
    var first: Int?
    var last = 0
    for (i, s) in subpasses.enumerated() where s.colors.contains(a) || s.depthStencil == a {
      if first == nil { first = i }
      last = i
    }
    return first.map { ($0, last) }
  }
}

func attachmentStore(_ op: VkAttachmentStoreOp) -> StoreAction { op == VK_ATTACHMENT_STORE_OP_DONT_CARE ? .discard : .store }

func core_vkDestroyRenderPass(_ device: VkDevice?, _ renderPass: VkRenderPass?, _ pAllocator: UnsafePointer<VkAllocationCallbacks>?) {
  unsafe Handle.destroy(renderPass)
}

/// One subpass's references, either structure's, as plain values.
private struct SubpassBuild {
  var colors: [UInt32] = []
  var resolves: [UInt32]?
  var depth: UInt32 = ~0
  var depthResolve: UInt32 = ~0
  var viewMask: UInt32 = 0
  var inputs: [UInt32] = []
  var graphics = true
}

private func makeRenderPass(_ attachments: [PassAttachment], _ builds: [SubpassBuild]) -> RenderPassObject? {
  var subpasses: [Subpass] = []
  for b in builds {
    guard b.graphics else {
      say("unsupported: a compute subpass")
      return nil
    }
    var colors: [Int] = []
    for a in b.colors {
      if a == ~0 || Int(a) >= attachments.count {
        say("unsupported: a subpass attachment that is unused or out of range")
        return nil
      }
      colors.append(Int(a))
    }
    var resolves = [Int?](repeating: nil, count: colors.count)
    if let r = b.resolves {
      for (i, a) in r.enumerated() where i < colors.count && a != ~0 {
        guard Int(a) < attachments.count else { return nil }
        resolves[i] = Int(a)
      }
    }
    var depth: Int?
    if b.depth != ~0 {
      guard Int(b.depth) < attachments.count else { return nil }
      depth = Int(b.depth)
    }
    var depthResolve: Int?
    if b.depthResolve != ~0 {
      guard Int(b.depthResolve) < attachments.count else { return nil }
      depthResolve = Int(b.depthResolve)
    }
    var inputs: [Int] = []
    for a in b.inputs where a != ~0 {
      guard Int(a) < attachments.count else {
        say("unsupported: an input attachment out of range")
        return nil
      }
      inputs.append(Int(a))
    }
    subpasses.append(Subpass(colors: colors, resolves: resolves, depthStencil: depth, depthStencilResolve: depthResolve, viewMask: b.viewMask, inputs: inputs))
  }
  return RenderPassObject(attachments: attachments, subpasses: subpasses)
}

func core_vkCreateRenderPass(_ device: VkDevice?, _ pCreateInfo: UnsafePointer<VkRenderPassCreateInfo>?,
                             _ pAllocator: UnsafePointer<VkAllocationCallbacks>?,
                             _ pRenderPass: UnsafeMutablePointer<VkRenderPass?>?) -> VkResult
{
  guard let info = unsafe pCreateInfo, let out = unsafe pRenderPass else { return VK_ERROR_INITIALIZATION_FAILED }
  var attachments: [PassAttachment] = []
  for i in 0..<Int(unsafe info.pointee.attachmentCount) {
    let a = unsafe info.pointee.pAttachments[i]
    guard let f = unsafe pixelFormat(a.format) else {
      say(unsafe "unsupported: a render pass attachment of format \(a.format.rawValue)")
      return VK_ERROR_FORMAT_NOT_SUPPORTED
    }
    unsafe attachments.append(PassAttachment(format: f, samples: a.samples.rawValue, load: a.loadOp, store: attachmentStore(a.storeOp),
                                             stencilLoad: a.stencilLoadOp, stencilStore: attachmentStore(a.stencilStoreOp)))
  }
  // VK_KHR_multiview's masks, one for each subpass.
  var masks: UnsafePointer<UInt32>?
  if let m = unsafe findStructure(UnsafeRawPointer(info.pointee.pNext), VK_STRUCTURE_TYPE_RENDER_PASS_MULTIVIEW_CREATE_INFO) {
    let mv = unsafe m.assumingMemoryBound(to: VkRenderPassMultiviewCreateInfo.self)
    if unsafe mv.pointee.subpassCount > 0 { unsafe masks = mv.pointee.pViewMasks }
  }
  var builds: [SubpassBuild] = []
  for i in 0..<Int(unsafe info.pointee.subpassCount) {
    let s = unsafe info.pointee.pSubpasses[i]
    var b = SubpassBuild()
    b.graphics = unsafe s.pipelineBindPoint == VK_PIPELINE_BIND_POINT_GRAPHICS
    for k in unsafe 0..<Int(s.inputAttachmentCount) { b.inputs.append(unsafe s.pInputAttachments[k].attachment) }
    for k in unsafe 0..<Int(s.colorAttachmentCount) { b.colors.append(unsafe s.pColorAttachments[k].attachment) }
    if let r = unsafe s.pResolveAttachments {
      var list: [UInt32] = []
      for k in unsafe 0..<Int(s.colorAttachmentCount) { list.append(unsafe r[k].attachment) }
      b.resolves = list
    }
    if let d = unsafe s.pDepthStencilAttachment { b.depth = unsafe d.pointee.attachment }
    if let masks = unsafe masks { b.viewMask = unsafe masks[i] }
    builds.append(b)
  }
  guard let pass = makeRenderPass(attachments, builds) else { return VK_ERROR_FEATURE_NOT_PRESENT }
  unsafe out.pointee = Handle.make(pass)
  return VK_SUCCESS
}

func core_vkCreateRenderPass2(_ device: VkDevice?, _ pCreateInfo: UnsafePointer<VkRenderPassCreateInfo2>?,
                              _ pAllocator: UnsafePointer<VkAllocationCallbacks>?,
                              _ pRenderPass: UnsafeMutablePointer<VkRenderPass?>?) -> VkResult
{
  guard let info = unsafe pCreateInfo, let out = unsafe pRenderPass else { return VK_ERROR_INITIALIZATION_FAILED }
  var attachments: [PassAttachment] = []
  for i in 0..<Int(unsafe info.pointee.attachmentCount) {
    let a = unsafe info.pointee.pAttachments[i]
    guard let f = unsafe pixelFormat(a.format) else {
      say(unsafe "unsupported: a render pass attachment of format \(a.format.rawValue)")
      return VK_ERROR_FORMAT_NOT_SUPPORTED
    }
    unsafe attachments.append(PassAttachment(format: f, samples: a.samples.rawValue, load: a.loadOp, store: attachmentStore(a.storeOp),
                                             stencilLoad: a.stencilLoadOp, stencilStore: attachmentStore(a.stencilStoreOp)))
  }
  var builds: [SubpassBuild] = []
  for i in 0..<Int(unsafe info.pointee.subpassCount) {
    let s = unsafe info.pointee.pSubpasses[i]
    var b = SubpassBuild()
    b.graphics = unsafe s.pipelineBindPoint == VK_PIPELINE_BIND_POINT_GRAPHICS
    for k in unsafe 0..<Int(s.inputAttachmentCount) { b.inputs.append(unsafe s.pInputAttachments[k].attachment) }
    b.viewMask = unsafe s.viewMask
    for k in unsafe 0..<Int(s.colorAttachmentCount) { b.colors.append(unsafe s.pColorAttachments[k].attachment) }
    if let r = unsafe s.pResolveAttachments {
      var list: [UInt32] = []
      for k in unsafe 0..<Int(s.colorAttachmentCount) { list.append(unsafe r[k].attachment) }
      b.resolves = list
    }
    if let d = unsafe s.pDepthStencilAttachment { b.depth = unsafe d.pointee.attachment }
    if let m = unsafe findStructure(UnsafeRawPointer(s.pNext), VK_STRUCTURE_TYPE_SUBPASS_DESCRIPTION_DEPTH_STENCIL_RESOLVE),
      let r = unsafe m.assumingMemoryBound(to: VkSubpassDescriptionDepthStencilResolve.self).pointee.pDepthStencilResolveAttachment
    {
      b.depthResolve = unsafe r.pointee.attachment
    }
    builds.append(b)
  }
  guard let pass = makeRenderPass(attachments, builds) else { return VK_ERROR_FEATURE_NOT_PRESENT }
  unsafe out.pointee = Handle.make(pass)
  return VK_SUCCESS
}

// MARK: Framebuffers

final class FramebufferObject: CoreObject {
  let views: [ImageViewObject]
  let width: UInt32
  let height: UInt32
  let layers: UInt32
  init(views: [ImageViewObject], width: UInt32, height: UInt32, layers: UInt32) {
    self.views = views
    self.width = width
    self.height = height
    self.layers = layers
  }
}

func core_vkCreateFramebuffer(_ device: VkDevice?, _ pCreateInfo: UnsafePointer<VkFramebufferCreateInfo>?,
                              _ pAllocator: UnsafePointer<VkAllocationCallbacks>?,
                              _ pFramebuffer: UnsafeMutablePointer<VkFramebuffer?>?) -> VkResult
{
  guard let info = unsafe pCreateInfo, let out = unsafe pFramebuffer else { return VK_ERROR_INITIALIZATION_FAILED }
  guard unsafe info.pointee.flags == 0 else {
    say("unsupported: an imageless framebuffer")
    return VK_ERROR_FEATURE_NOT_PRESENT
  }
  var views: [ImageViewObject] = []
  for i in 0..<Int(unsafe info.pointee.attachmentCount) {
    guard let v = unsafe Handle.get(info.pointee.pAttachments[i], ImageViewObject.self) else { return VK_ERROR_INITIALIZATION_FAILED }
    views.append(v)
  }
  unsafe out.pointee = Handle.make(FramebufferObject(views: views, width: info.pointee.width, height: info.pointee.height,
                                                     layers: max(info.pointee.layers, 1)))
  return VK_SUCCESS
}

func core_vkDestroyFramebuffer(_ device: VkDevice?, _ framebuffer: VkFramebuffer?, _ pAllocator: UnsafePointer<VkAllocationCallbacks>?) {
  unsafe Handle.destroy(framebuffer)
}

// MARK: The core's passes

/// The load of an attachment the render pass says is cleared, loaded or ignored, for the first subpass that uses it; a
/// later subpass loads what the one before stored.
func loadAction(_ op: VkAttachmentLoadOp, _ value: VkClearValue, format: PixelFormat) -> LoadAction {
  if op == VK_ATTACHMENT_LOAD_OP_LOAD { return .load }
  if op == VK_ATTACHMENT_LOAD_OP_CLEAR {
    // An integer attachment's clear is not a float clear: it is made by `clearAttachments` after the pass begins.
    guard format.channelClass == .float else { return .dontCare }
    let c = unsafe value.color.float32
    return .clear(c.0, c.1, c.2, c.3)
  }
  return .dontCare
}

func aspectLoad(_ op: VkAttachmentLoadOp) -> AspectLoad {
  if op == VK_ATTACHMENT_LOAD_OP_LOAD { return .load }
  if op == VK_ATTACHMENT_LOAD_OP_CLEAR { return .clear }
  return .dontCare
}

/// The core's pass for subpass `index` of `pass` over `framebuffer`, with the clear values of the begin, and the clears of
/// integer attachments that the pass must make once it has begun.
func subpassRendering(_ pass: RenderPassObject, _ index: Int, _ fb: FramebufferObject, clears: UnsafePointer<VkClearValue>?,
                      clearCount: Int, area: VkRect2D) -> (info: RenderingInfo, integerClears: [ClearAttachment])?
{
  let s = pass.subpasses[index]
  func clearValue(_ a: Int) -> VkClearValue { a < clearCount ? unsafe clears![a] : VkClearValue() }
  var colors: [Attachment] = []
  var integer: [ClearAttachment] = []
  for (k, a) in s.colors.enumerated() {
    guard a < fb.views.count else { return nil }
    let d = pass.attachments[a]
    let span = pass.span(a)
    let first = span?.first == index
    let last = span?.last == index
    var load: LoadAction = .load
    if first {
      load = loadAction(d.load, clearValue(a), format: d.format)
      if d.load == VK_ATTACHMENT_LOAD_OP_CLEAR && d.format.channelClass != .float {
        let c = unsafe clearValue(a).color
        if d.format.channelClass == .uint {
          integer.append(.color(index: k, .uint(unsafe c.uint32.0, unsafe c.uint32.1, unsafe c.uint32.2, unsafe c.uint32.3)))
        } else {
          integer.append(.color(index: k, .sint(unsafe c.int32.0, unsafe c.int32.1, unsafe c.int32.2, unsafe c.int32.3)))
        }
      }
    }
    var resolve: ImageView?
    if let r = s.resolves[k], r < fb.views.count { resolve = fb.views[r].view }
    colors.append(Attachment(view: fb.views[a].view, load: load, store: last && !pass.readLater(a, after: index) ? d.store : .store, resolve: resolve))
  }
  var depthStencil: DepthStencilAttachment?
  if let a = s.depthStencil {
    guard a < fb.views.count else { return nil }
    let d = pass.attachments[a]
    let span = pass.span(a)
    let first = span?.first == index
    let last = span?.last == index
    let v = clearValue(a)
    var resolve: ImageView?
    if let r = s.depthStencilResolve, r < fb.views.count { resolve = fb.views[r].view }
    depthStencil = DepthStencilAttachment(
      view: fb.views[a].view, depthLoad: first ? aspectLoad(d.load) : .load, stencilLoad: first ? aspectLoad(d.stencilLoad) : .load,
      depthStore: last && !pass.readLater(a, after: index) ? d.store : .store,
      stencilStore: last && !pass.readLater(a, after: index) ? d.stencilStore : .store, clearDepth: unsafe v.depthStencil.depth,
      clearStencil: unsafe v.depthStencil.stencil, resolve: resolve)
  }
  let full = area.offset.x == 0 && area.offset.y == 0 && area.extent.width == fb.width && area.extent.height == fb.height
  let renderArea: RenderArea? = full ? nil : RenderArea(x: area.offset.x, y: area.offset.y, width: area.extent.width, height: area.extent.height)
  let layers = s.viewMask != 0 ? 1 : fb.layers
  return (RenderingInfo(colors: colors, depthStencil: depthStencil, layerCount: layers, viewMask: s.viewMask, renderArea: renderArea), integer)
}
