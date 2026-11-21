// SPDX-License-Identifier: BSD-3-Clause

// The layer's mapping of 1D images, mapped views, texel buffers and input attachments onto the core: each Vulkan call is
// followed to the core state it makes (the fake device keeps what the core was asked for), and the descriptors to the
// records the lowering reads.

import GPUCore
import Testing
import TDVulkan
@testable import VulkanCoreDriver
import VulkanLowering

private let storageUsage = VK_IMAGE_USAGE_STORAGE_BIT.rawValue
private let texelUsage = VK_BUFFER_USAGE_UNIFORM_TEXEL_BUFFER_BIT.rawValue | VK_BUFFER_USAGE_STORAGE_TEXEL_BUFFER_BIT.rawValue

private func core(_ view: VkImageView?) -> ImageView { Handle.get(view, ImageViewObject.self)!.view }

private func word(_ set: VkDescriptorSet?, at offset: Int) -> UInt32 {
  let s = Handle.get(set, DescriptorSetObject.self)!
  return UnsafeRawPointer(s.pointer!).load(fromByteOffset: offset, as: UInt32.self)
}

@Suite struct OneDimensionalLayerTests {
  @Test func aOneDimensionalImageAndItsViewsAreTheCores() throws {
    let vk = fullVK()
    let (r, image) = vk.fullImage(VK_IMAGE_TYPE_1D, VK_FORMAT_R32_UINT, 32, 1, usage: sampledUsage | storageUsage)
    #expect(r == VK_SUCCESS)
    let d = Handle.get(image, ImageObject.self)!.image
    #expect(d.dimension == .d1 && d.width == 32 && d.height == 1 && d.layers == 1)
    let view = vk.fullView(image, VK_IMAGE_VIEW_TYPE_1D, VK_FORMAT_R32_UINT)
    #expect(view.0 == VK_SUCCESS)
    #expect(core(view.1).dimension == .d1)
    let object = Handle.get(view.1, ImageViewObject.self)!
    // A sampled and a storage image: a slot in each of the heap's arrays, and the view is what the heap was given.
    #expect(vk.gpu.textureViews[object.textureSlot!]?.dimension == .d1)
    #expect(vk.gpu.storageViews[object.storageSlot!]?.dimension == .d1)

    // An array of 1D images has layers, and the 1D array view of it.
    let (ra, array) = vk.fullImage(VK_IMAGE_TYPE_1D, VK_FORMAT_RGBA8_UNORM_FOR_TESTS, 16, 1, layers: 4, usage: sampledUsage)
    #expect(ra == VK_SUCCESS)
    let av = vk.fullView(array, VK_IMAGE_VIEW_TYPE_1D_ARRAY, VK_FORMAT_RGBA8_UNORM_FOR_TESTS, layers: 4)
    #expect(av.0 == VK_SUCCESS && core(av.1).dimension == .d1Array && core(av.1).layerCount == 4)
    // One layer of it as a 1D view.
    let one = vk.fullView(array, VK_IMAGE_VIEW_TYPE_1D, VK_FORMAT_RGBA8_UNORM_FOR_TESTS, layer: 2)
    #expect(one.0 == VK_SUCCESS && core(one.1).baseLayer == 2 && core(one.1).dimension == .d1)

    // The shapes the core refuses: a 2D view of it, a 1D image that is drawn into, a 1D view of a 2D image.
    #expect(vk.fullView(image, VK_IMAGE_VIEW_TYPE_2D, VK_FORMAT_R32_UINT).0 == VK_ERROR_UNKNOWN)
    #expect(vk.fullImage(VK_IMAGE_TYPE_1D, VK_FORMAT_RGBA8_UNORM_FOR_TESTS, 16, 1, usage: colorUsage).0 == VK_ERROR_UNKNOWN)
    let flat = vk.fullImage(VK_IMAGE_TYPE_2D, VK_FORMAT_RGBA8_UNORM_FOR_TESTS, 16, 16, usage: sampledUsage).1
    #expect(vk.fullView(flat, VK_IMAGE_VIEW_TYPE_1D, VK_FORMAT_RGBA8_UNORM_FOR_TESTS).0 == VK_ERROR_UNKNOWN)
  }

  @Test func aDeviceWithoutThemRefusesThemAsItsOwn() throws {
    let vk = VK()
    #expect(vk.fullImage(VK_IMAGE_TYPE_1D, VK_FORMAT_RGBA8_UNORM_FOR_TESTS, 16, 1, usage: sampledUsage).0 == VK_ERROR_FEATURE_NOT_PRESENT)
  }

  @Test func theDeviceReportsOneDimensionalFormatProperties() throws {
    let vk = fullVK()
    var p = VkImageFormatProperties()
    let query = vk.fn("vkGetPhysicalDeviceImageFormatProperties", PFN_vkGetPhysicalDeviceImageFormatProperties.self)
    #expect(query(vk.physical, VK_FORMAT_R8G8B8A8_UNORM, VK_IMAGE_TYPE_1D, VK_IMAGE_TILING_OPTIMAL, sampledUsage, 0, &p) == VK_SUCCESS)
    #expect(p.maxExtent.height == 1 && p.maxExtent.depth == 1 && p.maxArrayLayers == 256)
    // Nothing draws into a 1D image, and no depth or compressed format is one.
    #expect(query(vk.physical, VK_FORMAT_R8G8B8A8_UNORM, VK_IMAGE_TYPE_1D, VK_IMAGE_TILING_OPTIMAL, colorUsage, 0, &p) == VK_ERROR_FORMAT_NOT_SUPPORTED)
    #expect(query(vk.physical, VK_FORMAT_D32_SFLOAT, VK_IMAGE_TYPE_1D, VK_IMAGE_TILING_OPTIMAL, sampledUsage, 0, &p) == VK_ERROR_FORMAT_NOT_SUPPORTED)
    #expect(query(vk.physical, VK_FORMAT_R8G8B8A8_UNORM, VK_IMAGE_TYPE_1D, VK_IMAGE_TILING_OPTIMAL, sampledUsage, 0, &p) == VK_SUCCESS)
    let old = VK()
    #expect(old.fn("vkGetPhysicalDeviceImageFormatProperties", PFN_vkGetPhysicalDeviceImageFormatProperties.self)(
      old.physical, VK_FORMAT_R8G8B8A8_UNORM, VK_IMAGE_TYPE_1D, VK_IMAGE_TILING_OPTIMAL, sampledUsage, 0, &p) == VK_ERROR_FORMAT_NOT_SUPPORTED)
  }
}

private let VK_FORMAT_RGBA8_UNORM_FOR_TESTS = VK_FORMAT_R8G8B8A8_UNORM

@Suite struct ViewSwizzleLayerTests {
  private func view(_ vk: VK, _ image: VkImage?, _ m: VkComponentMapping) -> (VkResult, VkImageView?) {
    var info = VkImageViewCreateInfo()
    info.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO
    info.image = image
    info.viewType = VK_IMAGE_VIEW_TYPE_2D
    info.format = VK_FORMAT_R8G8B8A8_UNORM
    info.components = m
    info.subresourceRange = VkImageSubresourceRange(aspectMask: 1, baseMipLevel: 0, levelCount: 1, baseArrayLayer: 0, layerCount: 1)
    var out: VkImageView?
    let r = vk.fn("vkCreateImageView", PFN_vkCreateImageView.self)(vk.device, &info, nil, &out)
    return (r, out)
  }

  @Test func aMappingIsTheCoresAndAStorageViewKeepsNone() throws {
    let vk = fullVK()
    // An image read through a view that swaps red and blue: the texel's own (r, g, b, a) read as (b, g, r, a).
    let image = vk.fullImage(VK_IMAGE_TYPE_2D, VK_FORMAT_R8G8B8A8_UNORM, 8, 8, usage: sampledUsage | storageUsage).1
    var m = VkComponentMapping()
    m.r = VK_COMPONENT_SWIZZLE_B
    m.b = VK_COMPONENT_SWIZZLE_R
    m.a = VK_COMPONENT_SWIZZLE_ONE
    let (r, v) = view(vk, image, m)
    #expect(r == VK_SUCCESS)
    let want = ComponentMapping(r: .b, g: .identity, b: .r, a: .one)
    #expect(core(v).swizzle == want)
    let o = Handle.get(v, ImageViewObject.self)!
    #expect(vk.gpu.textureViews[o.textureSlot!]?.swizzle == want)
    #expect(vk.gpu.storageViews[o.storageSlot!]?.swizzle == .identity, "a storage image maps nothing")
    // The identity, spelled either way, is the whole image.
    var same = VkComponentMapping()
    same.g = VK_COMPONENT_SWIZZLE_G
    #expect(core(view(vk, image, same).1).isWholeImage)
  }

  @Test func aDeviceWithoutMappingRefusesIt() throws {
    let vk = VK()
    let image = vk.image(VK_FORMAT_R8G8B8A8_UNORM, 4, 4, usage: sampledUsage)
    var m = VkComponentMapping()
    m.r = VK_COMPONENT_SWIZZLE_B
    #expect(view(vk, image, m).0 == VK_ERROR_FEATURE_NOT_PRESENT)
  }
}

@Suite struct TexelBufferLayerTests {
  private func bufferView(_ vk: VK, _ buffer: VkBuffer?, _ format: VkFormat, offset: UInt64 = 0, range: UInt64 = ~0) -> (VkResult, VkBufferView?) {
    var info = VkBufferViewCreateInfo()
    info.sType = VK_STRUCTURE_TYPE_BUFFER_VIEW_CREATE_INFO
    info.buffer = buffer
    info.format = format
    info.offset = offset
    info.range = range
    var out: VkBufferView?
    let r = vk.fn("vkCreateBufferView", PFN_vkCreateBufferView.self)(vk.device, &info, nil, &out)
    return (r, out)
  }

  @Test func aBufferViewIsTheCoresAndItsDescriptorsAreTheSlots() throws {
    let vk = fullVK()
    let memory = vk.allocate(1, 4096)
    let buffer = vk.buffer(1024, usage: texelUsage, in: memory, at: 256)
    let (r, view) = bufferView(vk, buffer, VK_FORMAT_R32_UINT, offset: 64, range: 128)
    #expect(r == VK_SUCCESS)
    let o = Handle.get(view, BufferViewObject.self)!
    // The core's view is memory, where in it (the buffer's place plus the view's offset), how much, and the format.
    #expect(o.view.format == .r32uint && o.view.offset == 256 + 64 && o.view.range == 128 && o.view.elementCount == 32)
    #expect(vk.gpu.texelBuffers[o.texelSlot!] == o.view && vk.gpu.storageTexelBuffers[o.storageTexelSlot!] == o.view)

    // A set with both kinds: the record holds each slot, and a view's slot is its own heap array's.
    let layout = vk.setLayout([(0, VK_DESCRIPTOR_TYPE_UNIFORM_TEXEL_BUFFER, 1), (1, VK_DESCRIPTOR_TYPE_STORAGE_TEXEL_BUFFER, 2)])
    let pool = vk.descriptorPool(sets: 1, sizes: [(VK_DESCRIPTOR_TYPE_UNIFORM_TEXEL_BUFFER, 1), (VK_DESCRIPTOR_TYPE_STORAGE_TEXEL_BUFFER, 2)])
    let (allocated, set) = vk.allocateSet(pool, layout)
    #expect(allocated == VK_SUCCESS)
    var handle = view
    func write(_ binding: UInt32, _ type: VkDescriptorType, element: UInt32 = 0) {
      withUnsafePointer(to: &handle) { hp in
        var w = VkWriteDescriptorSet()
        w.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
        w.dstSet = set
        w.dstBinding = binding
        w.dstArrayElement = element
        w.descriptorCount = 1
        w.descriptorType = type
        w.pTexelBufferView = hp
        vk.fn("vkUpdateDescriptorSets", PFN_vkUpdateDescriptorSets.self)(vk.device, 1, &w, 0, nil)
      }
    }
    write(0, VK_DESCRIPTOR_TYPE_UNIFORM_TEXEL_BUFFER)
    write(1, VK_DESCRIPTOR_TYPE_STORAGE_TEXEL_BUFFER, element: 1)
    #expect(word(set, at: 0) == o.texelSlot!)
    // Binding 1's element 1 is at 16 + 16.
    #expect(word(set, at: 32) == o.storageTexelSlot!)
    // The lowering's layout knows the kinds.
    let l = Handle.get(layout, SetLayoutObject.self)!.layout
    #expect(l.find(0)?.binding.kind == .uniformTexelBuffer && l.find(1)?.binding.kind == .storageTexelBuffer)

    // A view of a buffer that can be neither is taken by neither array; its destroy gives its slots back.
    let used = o.texelSlot!
    vk.fn("vkDestroyBufferView", PFN_vkDestroyBufferView.self)(vk.device, view, nil)
    let again = bufferView(vk, buffer, VK_FORMAT_R32_UINT)
    #expect(again.0 == VK_SUCCESS && Handle.get(again.1, BufferViewObject.self)!.texelSlot == used)
  }

  @Test func theShapesTheCoreRefusesAreInvalid() throws {
    let vk = fullVK()
    let memory = vk.allocate(1, 4096)
    let buffer = vk.buffer(256, usage: texelUsage, in: memory)
    #expect(bufferView(vk, buffer, VK_FORMAT_R32_UINT, offset: 0, range: 10).0 == VK_ERROR_UNKNOWN)  // not whole texels
    #expect(bufferView(vk, buffer, VK_FORMAT_D32_SFLOAT).0 == VK_ERROR_UNKNOWN)
    #expect(bufferView(vk, buffer, VK_FORMAT_UNDEFINED).0 == VK_ERROR_FORMAT_NOT_SUPPORTED)
  }

  @Test func aDeviceWithoutThemRefusesThemAsItsOwn() throws {
    let vk = VK()
    let memory = vk.allocate(1, 4096)
    let buffer = vk.buffer(256, usage: VK_BUFFER_USAGE_UNIFORM_TEXEL_BUFFER_BIT.rawValue, in: memory)
    #expect(bufferView(vk, buffer, VK_FORMAT_R32_UINT).0 == VK_ERROR_FEATURE_NOT_PRESENT)
    // And the device says it has no texel-buffer features of the format.
    var props = VkFormatProperties()
    vk.fn("vkGetPhysicalDeviceFormatProperties", PFN_vkGetPhysicalDeviceFormatProperties.self)(vk.physical, VK_FORMAT_R32_UINT, &props)
    #expect(props.bufferFeatures == 0)
    let full = fullVK()
    full.fn("vkGetPhysicalDeviceFormatProperties", PFN_vkGetPhysicalDeviceFormatProperties.self)(full.physical, VK_FORMAT_R32_UINT, &props)
    #expect(props.bufferFeatures & VK_FORMAT_FEATURE_UNIFORM_TEXEL_BUFFER_BIT.rawValue != 0)
    #expect(props.bufferFeatures & VK_FORMAT_FEATURE_STORAGE_TEXEL_BUFFER_ATOMIC_BIT.rawValue != 0)
  }
}

@Suite struct InputAttachmentLayerTests {
  @Test func aSubpassReadsWhatTheOneBeforeStoredAsATexture() throws {
    let vk = fullVK()
    // A is drawn in subpass 0 and read in subpass 1, which draws B; the render pass says A's contents are not kept, which
    // would be the end of the pass's A: the core's first pass must store it nevertheless, for the second to read.
    let usageA = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT.rawValue | VK_IMAGE_USAGE_INPUT_ATTACHMENT_BIT.rawValue
    let a = vk.fullImage(VK_IMAGE_TYPE_2D, VK_FORMAT_R8G8B8A8_UNORM, 8, 8, usage: usageA).1
    let b = vk.fullImage(VK_IMAGE_TYPE_2D, VK_FORMAT_R8G8B8A8_UNORM, 8, 8, usage: colorUsage).1
    let viewA = vk.fullView(a, VK_IMAGE_VIEW_TYPE_2D, VK_FORMAT_R8G8B8A8_UNORM).1
    let viewB = vk.fullView(b, VK_IMAGE_VIEW_TYPE_2D, VK_FORMAT_R8G8B8A8_UNORM).1
    // The image is a texture of the core, and its view has the slot the descriptor will name.
    #expect(Handle.get(a, ImageObject.self)!.image.usage.contains(.sampled))
    let slot = try #require(Handle.get(viewA, ImageViewObject.self)!.textureSlot)
    #expect(Handle.get(viewB, ImageViewObject.self)!.textureSlot == nil)

    let (r, pass) = makePass(
      vk,
      [vk.attachment(VK_FORMAT_R8G8B8A8_UNORM, load: VK_ATTACHMENT_LOAD_OP_CLEAR, store: VK_ATTACHMENT_STORE_OP_DONT_CARE),
       vk.attachment(VK_FORMAT_R8G8B8A8_UNORM, load: VK_ATTACHMENT_LOAD_OP_DONT_CARE, store: VK_ATTACHMENT_STORE_OP_STORE)],
      [SubpassSpec(colors: [0]), SubpassSpec(colors: [1], inputs: [0])])
    #expect(r == VK_SUCCESS)
    let rp = Handle.get(pass, RenderPassObject.self)!
    #expect(rp.subpasses[1].inputs == [0] && rp.subpasses[0].inputs.isEmpty)

    // The input-attachment binding holds the view's texture slot.
    let layout = vk.setLayout([(0, VK_DESCRIPTOR_TYPE_INPUT_ATTACHMENT, 1)])
    let pool = vk.descriptorPool(sets: 1, sizes: [(VK_DESCRIPTOR_TYPE_INPUT_ATTACHMENT, 1)])
    let (allocated, set) = vk.allocateSet(pool, layout)
    #expect(allocated == VK_SUCCESS)
    vk.writeImages(set, binding: 0, type: VK_DESCRIPTOR_TYPE_INPUT_ATTACHMENT,
                   [VkDescriptorImageInfo(sampler: nil, imageView: viewA, imageLayout: VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL)])
    #expect(word(set, at: 0) == slot)
    #expect(Handle.get(layout, SetLayoutObject.self)!.layout.find(0)?.binding.kind == .inputAttachment)

    // The core's passes: the first stores A (not the pass's discard), a barrier follows, and the second draws B.
    let fb = makeFramebuffer(vk, pass, [viewA, viewB], 8, 8)
    let cb = vk.commandBuffer(vk.commandPool())
    vk.begin(cb)
    var begin = VkRenderPassBeginInfo()
    begin.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO
    begin.renderPass = pass
    begin.framebuffer = fb
    begin.renderArea = VkRect2D(offset: VkOffset2D(x: 0, y: 0), extent: VkExtent2D(width: 8, height: 8))
    var clears = [VkClearValue(), VkClearValue()]
    clears[0].color.float32 = (0.25, 0.5, 0.75, 1)
    clears.withUnsafeBufferPointer { cv in
      begin.clearValueCount = 2
      begin.pClearValues = cv.baseAddress
      vk.fn("vkCmdBeginRenderPass", PFN_vkCmdBeginRenderPass.self)(cb, &begin, VK_SUBPASS_CONTENTS_INLINE)
    }
    vk.fn("vkCmdNextSubpass", PFN_vkCmdNextSubpass.self)(cb, VK_SUBPASS_CONTENTS_INLINE)
    vk.fn("vkCmdEndRenderPass", PFN_vkCmdEndRenderPass.self)(cb)
    #expect(vk.end(cb) == VK_SUCCESS)
    #expect(vk.submit([cb]) == VK_SUCCESS)
    let c = vk.gpu.submitted[0].list.commands
    #expect(c.count == 5)
    guard case .beginRendering(let s0) = c[0], case .beginRendering(let s1) = c[3] else { return }
    #expect(c[1] == .endRendering && c[4] == .endRendering)
    #expect(c[2] == .barrier(from: .fragment, to: .fragment), "the first pass has ended and its writes are made visible")
    #expect(s0.colors[0].load == .clear(0.25, 0.5, 0.75, 1) && s0.colors[0].store == .store)
    #expect(s1.colors.count == 1 && s1.colors[0].view.image == Handle.get(b, ImageObject.self)!.image)
  }

  @Test func anInputAttachmentOfNoAttachmentIsLeftOut() throws {
    let vk = fullVK()
    var attachments = [vk.attachment(VK_FORMAT_R8G8B8A8_UNORM)]
    var sub = VkSubpassDescription()
    sub.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS
    sub.colorAttachmentCount = 1
    sub.pColorAttachments = leak([VkAttachmentReference(attachment: 0, layout: VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL)])
    sub.inputAttachmentCount = 1
    sub.pInputAttachments = leak([VkAttachmentReference(attachment: ~0, layout: VK_IMAGE_LAYOUT_UNDEFINED)])
    var info = VkRenderPassCreateInfo()
    info.sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO
    info.attachmentCount = 1
    info.pAttachments = leak(attachments)
    info.subpassCount = 1
    info.pSubpasses = leak([sub])
    var out: VkRenderPass?
    attachments.removeAll()
    #expect(vk.fn("vkCreateRenderPass", PFN_vkCreateRenderPass.self)(vk.device, &info, nil, &out) == VK_SUCCESS)
    #expect(Handle.get(out, RenderPassObject.self)!.subpasses[0].inputs.isEmpty)
  }
}
