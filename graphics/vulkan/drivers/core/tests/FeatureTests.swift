// SPDX-License-Identifier: BSD-3-Clause

// The layer's specialization constants, dynamic buffers, immutable samplers and descriptor buffers, driven through its
// vkGetInstanceProcAddr over the fake core device (Harness.swift).

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif
import GPUCore
import Testing
import TDVulkan
@testable import VulkanCoreDriver
import VulkanLowering

extension VulkanCoreDriverTests {
  // MARK: Specialization constants

  @Test func specializationConstantsReachTheLoweringPerStage() throws {
    let vk = VK()
    let layout = vk.pipelineLayout([])
    // A float (4 bytes), a bool (4 bytes), a 64-bit value, and a byte: each map entry's bytes, little-endian.
    let (made, _) = vk.computePipeline(
      layout, specialization: [(3, 4, 0x3F80_0000), (9, 4, 1), (12, 8, 0x1122_3344_5566_7788), (0, 1, 0xAB)])
    #expect(made == VK_SUCCESS)
    #expect(loweredStages.count == 1)
    #expect(
      loweredStages[0].spec == [
        SpecConstant(id: 3, value: 0x3F80_0000), SpecConstant(id: 9, value: 1), SpecConstant(id: 12, value: 0x1122_3344_5566_7788),
        SpecConstant(id: 0, value: 0xAB),
      ])

    // A graphics pipeline's stages each have their own.
    let pass = renderPass(vk)
    var o = PipelineOptions()
    o.vertexSpecialization = [(1, 4, 7)]
    o.fragmentSpecialization = [(1, 4, 8), (2, 4, 9)]
    loweredStages = []
    let (r, _) = graphicsPipeline(vk, layout, pass, o)
    #expect(r == VK_SUCCESS)
    #expect(loweredStages.count == 2)
    #expect(loweredStages[0].stage == .vertex && loweredStages[0].spec == [SpecConstant(id: 1, value: 7)])
    #expect(loweredStages[1].stage == .fragment && loweredStages[1].spec == [SpecConstant(id: 1, value: 8), SpecConstant(id: 2, value: 9)])

    // No specialization info, no constants.
    loweredStages = []
    _ = vk.computePipeline(layout)
    #expect(loweredStages.count == 1 && loweredStages[0].spec.isEmpty)
  }

  // MARK: Dynamic buffers

  @Test func dynamicOffsetsLandWhereTheLoweredShaderReadsThem() throws {
    let vk = VK()
    // Set 0: a dynamic storage buffer, a plain uniform buffer, and two dynamic uniform buffers. Set 1: one dynamic.
    let set0 = vk.setLayout([
      (0, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER_DYNAMIC, 1), (1, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 1),
      (2, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC, 2),
    ])
    let set1 = vk.setLayout([(0, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER_DYNAMIC, 1)])
    let pipelineLayout = vk.pipelineLayout([set0, set1], push: 4)
    let (made, pipeline) = vk.computePipeline(pipelineLayout)
    #expect(made == VK_SUCCESS)

    // The lowering is told which descriptors are dynamic, and where each one's offset is.
    let lowering = loweredStages[0].layout
    let a = try #require(lowering.sets[0])
    let b = try #require(lowering.sets[1])
    #expect(a.bindings.map(\.dynamic) == [true, false, true])
    #expect(a.dynamicCount == 3 && b.dynamicCount == 1)
    #expect(lowering.dynamicBase(set: 1) == 3)
    // The records are what plain buffers have: 16 bytes a descriptor.
    #expect(a.offsets == [0, 16, 32] && a.size == 64)

    let pool = vk.descriptorPool(
      sets: 2, sizes: [(VK_DESCRIPTOR_TYPE_STORAGE_BUFFER_DYNAMIC, 2), (VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 1), (VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC, 2)])
    let (_, s0) = vk.allocateSet(pool, set0)
    let (_, s1) = vk.allocateSet(pool, set1)
    let memory = vk.allocate(MemoryTypes.upload, 4096)
    let usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT.rawValue | VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT.rawValue
    let buffer = vk.buffer(2048, usage: usage, in: memory)
    vk.writeBuffers(s0, binding: 0, type: VK_DESCRIPTOR_TYPE_STORAGE_BUFFER_DYNAMIC, [VkDescriptorBufferInfo(buffer: buffer, offset: 256, range: 512)])
    vk.writeBuffers(s0, binding: 2, type: VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC, [
      VkDescriptorBufferInfo(buffer: buffer, offset: 0, range: 64), VkDescriptorBufferInfo(buffer: buffer, offset: 1024, range: 64),
    ])
    vk.writeBuffers(s1, binding: 0, type: VK_DESCRIPTOR_TYPE_STORAGE_BUFFER_DYNAMIC, [VkDescriptorBufferInfo(buffer: buffer, offset: 0, range: ~0)])

    let cp = vk.commandPool()
    let cb = vk.commandBuffer(cp)
    vk.begin(cb)
    var sets: [VkDescriptorSet?] = [s0, s1]
    // The application's order: set 0's dynamic descriptors by binding (0; 2 and 3), then set 1's.
    var offsets: [UInt32] = [256, 64, 128, 512]
    vk.fn("vkCmdBindPipeline", PFN_vkCmdBindPipeline.self)(cb, VK_PIPELINE_BIND_POINT_COMPUTE, pipeline)
    vk.fn("vkCmdBindDescriptorSets", PFN_vkCmdBindDescriptorSets.self)(cb, VK_PIPELINE_BIND_POINT_COMPUTE, pipelineLayout, 0, 2, &sets, 4, &offsets)
    vk.fn("vkCmdDispatch", PFN_vkCmdDispatch.self)(cb, 1, 1, 1)
    // Set 1 bound again alone, with its own offset: set 0's stay.
    var again: [VkDescriptorSet?] = [s1]
    var offset1: [UInt32] = [768]
    vk.fn("vkCmdBindDescriptorSets", PFN_vkCmdBindDescriptorSets.self)(cb, VK_PIPELINE_BIND_POINT_COMPUTE, pipelineLayout, 1, 1, &again, 1, &offset1)
    vk.fn("vkCmdDispatch", PFN_vkCmdDispatch.self)(cb, 1, 1, 1)
    #expect(vk.end(cb) == VK_SUCCESS)
    #expect(vk.submit([cb], fence: vk.fence()) == VK_SUCCESS)
    let dispatches = vk.gpu.submitted[0].list.dispatches
    #expect(dispatches.count == 2)

    func word(_ root: UInt64, _ index: Int) -> UInt32 { vk.gpu.read(root + UInt64(RootBlock.dynamicOffsetsOffset + 4 * index), as: UInt32.self) }
    // Where the lowering reads the (set, binding, element)'s offset: dynamicBase(set) + dynamicIndex(binding) + element.
    func index(_ set: Int, _ binding: UInt32, _ element: Int) -> Int {
      lowering.dynamicBase(set: set) + lowering.sets[set]!.dynamicIndex(binding)! + element
    }
    let first = dispatches[0].root
    #expect(word(first, index(0, 0, 0)) == 256)
    #expect(word(first, index(0, 2, 0)) == 64)
    #expect(word(first, index(0, 2, 1)) == 128)
    #expect(word(first, index(1, 0, 0)) == 512)
    #expect(word(first, 4) == 0)
    let second = dispatches[1].root
    #expect(word(second, index(0, 0, 0)) == 256)
    #expect(word(second, index(0, 2, 1)) == 128)
    #expect(word(second, index(1, 0, 0)) == 768)

    // The record holds the descriptor's own address, not the adjusted one: the shader adds the offset.
    let base = vk.address(of: buffer)
    let record = vk.gpu.read(first + UInt64(RootBlock.setsOffset), as: UInt64.self)
    #expect(vk.gpu.read(record, as: UInt64.self) == base + 256)
    #expect(vk.gpu.read(record + 8, as: UInt64.self) == 512)
    #expect(vk.gpu.read(record + 32 + 16, as: UInt64.self) == base + 1024)
    // A draw with no dynamic descriptors has none to write: the region stays zero.
    let plain = vk.setLayout([(0, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1)])
    let plainLayout = vk.pipelineLayout([plain])
    let (_, plainPipeline) = vk.computePipeline(plainLayout)
    let cb2 = vk.commandBuffer(cp)
    vk.begin(cb2)
    vk.fn("vkCmdBindPipeline", PFN_vkCmdBindPipeline.self)(cb2, VK_PIPELINE_BIND_POINT_COMPUTE, plainPipeline)
    vk.fn("vkCmdDispatch", PFN_vkCmdDispatch.self)(cb2, 1, 1, 1)
    #expect(vk.end(cb2) == VK_SUCCESS)
    #expect(vk.submit([cb2], fence: vk.fence()) == VK_SUCCESS)
    let plainRoot = vk.gpu.submitted[1].list.dispatches[0].root
    for i in 0..<RootBlock.maxDynamicOffsets { #expect(word(plainRoot, i) == 0) }
  }

  @Test func dynamicOffsetCountsAreChecked() throws {
    let vk = VK()
    let set = vk.setLayout([(0, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC, 2)])
    let pipelineLayout = vk.pipelineLayout([set])
    let pool = vk.descriptorPool(sets: 1, sizes: [(VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC, 2)])
    let (_, s) = vk.allocateSet(pool, set)
    let cp = vk.commandPool()
    var sets: [VkDescriptorSet?] = [s]
    var offsets: [UInt32] = [0, 0, 0]
    for count in [1, 3] as [UInt32] {
      let cb = vk.commandBuffer(cp)
      vk.begin(cb)
      vk.fn("vkCmdBindDescriptorSets", PFN_vkCmdBindDescriptorSets.self)(cb, VK_PIPELINE_BIND_POINT_COMPUTE, pipelineLayout, 0, 1, &sets, count, &offsets)
      #expect(vk.end(cb) == VK_ERROR_UNKNOWN, "\(count) offsets")
    }
    // More dynamic descriptors in one pipeline layout than the root block has room for.
    let big = (0..<2).map { _ in vk.setLayout([(0, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER_DYNAMIC, UInt32(RootBlock.maxDynamicOffsets / 2 + 1))]) }
    var info = VkPipelineLayoutCreateInfo()
    info.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO
    info.setLayoutCount = 2
    var out: VkPipelineLayout?
    big.withUnsafeBufferPointer { bp in
      info.pSetLayouts = bp.baseAddress
      #expect(vk.fn("vkCreatePipelineLayout", PFN_vkCreatePipelineLayout.self)(vk.device, &info, nil, &out) == VK_ERROR_FEATURE_NOT_PRESENT)
    }
  }

  // MARK: Immutable samplers

  @Test func immutableSamplersAreInEverySetAndNeverWritten() throws {
    let vk = VK()
    let sA = vk.sampler()
    let sB = vk.sampler()
    let sC = vk.sampler()
    // The heap's slots, in the order they were made.
    #expect(vk.gpu.samplers[0] != nil && vk.gpu.samplers[1] != nil && vk.gpu.samplers[2] != nil)
    var combined: [VkSampler?] = [sC, sA]
    var only: [VkSampler?] = [sB]
    var layout: VkDescriptorSetLayout?
    combined.withUnsafeBufferPointer { cp in
      only.withUnsafeBufferPointer { op in
        let bindings = [
          VkDescriptorSetLayoutBinding(binding: 0, descriptorType: VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, descriptorCount: 2,
                                       stageFlags: VK_SHADER_STAGE_ALL.rawValue, pImmutableSamplers: cp.baseAddress),
          VkDescriptorSetLayoutBinding(binding: 1, descriptorType: VK_DESCRIPTOR_TYPE_SAMPLER, descriptorCount: 1,
                                       stageFlags: VK_SHADER_STAGE_ALL.rawValue, pImmutableSamplers: op.baseAddress),
          VkDescriptorSetLayoutBinding(binding: 2, descriptorType: VK_DESCRIPTOR_TYPE_SAMPLER, descriptorCount: 1,
                                       stageFlags: VK_SHADER_STAGE_ALL.rawValue, pImmutableSamplers: nil),
        ]
        bindings.withUnsafeBufferPointer { bp in
          var info = VkDescriptorSetLayoutCreateInfo()
          info.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO
          info.bindingCount = 3
          info.pBindings = bp.baseAddress
          #expect(vk.fn("vkCreateDescriptorSetLayout", PFN_vkCreateDescriptorSetLayout.self)(vk.device, &info, nil, &layout) == VK_SUCCESS)
        }
      }
    }
    let pool = vk.descriptorPool(sets: 2, sizes: [(VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 2), (VK_DESCRIPTOR_TYPE_SAMPLER, 2)])
    let (_, set) = vk.allocateSet(pool, layout)
    let record = vk.gpu.allocations.first { $0.size == 96 }!.address
    // Combined elements at 0 and 16 (their samplers at +4: C's slot 2, A's slot 0), the sampler binding at 32 (B, slot 1).
    #expect(vk.gpu.read(record + 4, as: UInt32.self) == 2)
    #expect(vk.gpu.read(record + 20, as: UInt32.self) == 0)
    #expect(vk.gpu.read(record + 32, as: UInt32.self) == 1)
    #expect(vk.gpu.read(record + 48, as: UInt32.self) == 0)

    // An update writes the image part and leaves the sampler; a write to the immutable sampler binding does nothing.
    let image = vk.image(usage: VK_IMAGE_USAGE_SAMPLED_BIT.rawValue)
    let view0 = vk.view(image)
    let view1 = vk.view(image)
    vk.writeImages(set, binding: 0, type: VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, [
      VkDescriptorImageInfo(sampler: sB, imageView: view1, imageLayout: VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL)
    ])
    _ = view0
    #expect(vk.gpu.read(record, as: UInt32.self) == 1)
    #expect(vk.gpu.read(record + 4, as: UInt32.self) == 2)
    vk.writeImages(set, binding: 1, type: VK_DESCRIPTOR_TYPE_SAMPLER, [VkDescriptorImageInfo(sampler: sA, imageView: nil, imageLayout: VK_IMAGE_LAYOUT_UNDEFINED)])
    #expect(vk.gpu.read(record + 32, as: UInt32.self) == 1)
    // A binding without immutable samplers takes its sampler as written.
    vk.writeImages(set, binding: 2, type: VK_DESCRIPTOR_TYPE_SAMPLER, [VkDescriptorImageInfo(sampler: sA, imageView: nil, imageLayout: VK_IMAGE_LAYOUT_UNDEFINED)])
    #expect(vk.gpu.read(record + 48, as: UInt32.self) == 0)
    vk.writeImages(set, binding: 2, type: VK_DESCRIPTOR_TYPE_SAMPLER, [VkDescriptorImageInfo(sampler: sC, imageView: nil, imageLayout: VK_IMAGE_LAYOUT_UNDEFINED)])
    #expect(vk.gpu.read(record + 48, as: UInt32.self) == 2)

    // Immutable samplers belong to sampler and combined image sampler bindings only.
    var bad: [VkSampler?] = [sA]
    bad.withUnsafeBufferPointer { sp in
      var b = VkDescriptorSetLayoutBinding(binding: 0, descriptorType: VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, descriptorCount: 1,
                                           stageFlags: VK_SHADER_STAGE_ALL.rawValue, pImmutableSamplers: sp.baseAddress)
      var info = VkDescriptorSetLayoutCreateInfo()
      info.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO
      info.bindingCount = 1
      var out: VkDescriptorSetLayout?
      withUnsafePointer(to: &b) { bp in
        info.pBindings = bp
        #expect(vk.fn("vkCreateDescriptorSetLayout", PFN_vkCreateDescriptorSetLayout.self)(vk.device, &info, nil, &out) == VK_ERROR_INITIALIZATION_FAILED)
      }
    }
  }

  // MARK: Descriptor buffers

  @Test func theDescriptorBufferExtensionIsListedAndDescribed() throws {
    let vk = VK()
    var count: UInt32 = 0
    #expect(vk.fn("vkEnumerateDeviceExtensionProperties", PFN_vkEnumerateDeviceExtensionProperties.self)(vk.physical, nil, &count, nil) == VK_SUCCESS)
    #expect(count == 1)
    var props = [VkExtensionProperties](repeating: VkExtensionProperties(), count: 1)
    #expect(vk.fn("vkEnumerateDeviceExtensionProperties", PFN_vkEnumerateDeviceExtensionProperties.self)(vk.physical, nil, &count, &props) == VK_SUCCESS)
    let name = withUnsafeBytes(of: props[0].extensionName) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
    #expect(name == "VK_EXT_descriptor_buffer")
    // Too small a list says so.
    count = 0
    var none = [VkExtensionProperties](repeating: VkExtensionProperties(), count: 1)
    #expect(vk.fn("vkEnumerateDeviceExtensionProperties", PFN_vkEnumerateDeviceExtensionProperties.self)(vk.physical, nil, &count, &none) == VK_INCOMPLETE)

    var buffer = VkPhysicalDeviceDescriptorBufferPropertiesEXT()
    buffer.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DESCRIPTOR_BUFFER_PROPERTIES_EXT
    withUnsafeMutablePointer(to: &buffer) { bp in
      var p2 = VkPhysicalDeviceProperties2()
      p2.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2
      p2.pNext = UnsafeMutableRawPointer(bp)
      vk.fn("vkGetPhysicalDeviceProperties2", PFN_vkGetPhysicalDeviceProperties2.self)(vk.physical, &p2)
    }
    #expect(buffer.descriptorBufferOffsetAlignment == 16)
    #expect(buffer.uniformBufferDescriptorSize == descriptorSize && buffer.storageBufferDescriptorSize == descriptorSize)
    #expect(buffer.samplerDescriptorSize == descriptorSize && buffer.sampledImageDescriptorSize == descriptorSize)
    #expect(buffer.storageImageDescriptorSize == descriptorSize && buffer.combinedImageSamplerDescriptorSize == descriptorSize)
    #expect(buffer.combinedImageSamplerDescriptorSingleArray == 1)
    #expect(buffer.maxDescriptorBufferBindings == 4)

    var features = VkPhysicalDeviceDescriptorBufferFeaturesEXT()
    features.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DESCRIPTOR_BUFFER_FEATURES_EXT
    withUnsafeMutablePointer(to: &features) { fp in
      var f2 = VkPhysicalDeviceFeatures2()
      f2.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2
      f2.pNext = UnsafeMutableRawPointer(fp)
      vk.fn("vkGetPhysicalDeviceFeatures2", PFN_vkGetPhysicalDeviceFeatures2.self)(vk.physical, &f2)
    }
    #expect(features.descriptorBuffer == 1)
    #expect(features.descriptorBufferPushDescriptors == 0 && features.descriptorBufferCaptureReplay == 0)

    // A device may enable it, and no other extension.
    func create(_ names: [String]) -> VkResult {
      var q = VkDeviceQueueCreateInfo()
      q.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO
      q.queueCount = 1
      var priority: Float = 1
      var result = VK_SUCCESS
      var device: VkDevice?
      withUnsafePointer(to: &priority) { pp in
        q.pQueuePriorities = pp
        let cstrings = names.map { strdup($0) }
        var pointers: [UnsafePointer<CChar>?] = cstrings.map { UnsafePointer($0) }
        withUnsafePointer(to: &q) { qp in
          pointers.withUnsafeMutableBufferPointer { np in
            var d = VkDeviceCreateInfo()
            d.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO
            d.queueCreateInfoCount = 1
            d.pQueueCreateInfos = qp
            d.enabledExtensionCount = UInt32(names.count)
            d.ppEnabledExtensionNames = UnsafePointer(np.baseAddress)
            result = vk.fn("vkCreateDevice", PFN_vkCreateDevice.self)(vk.physical, &d, nil, &device)
          }
        }
        for c in cstrings { free(c) }
      }
      return result
    }
    #expect(create(["VK_EXT_descriptor_buffer"]) == VK_SUCCESS)
    #expect(create(["VK_KHR_swapchain"]) == VK_ERROR_EXTENSION_NOT_PRESENT)
  }

  @Test func theDescriptorBufferSequence() throws {
    let vk = VK()
    // Binding 0 a uniform buffer, 2 two combined image samplers, 5 a storage buffer: records at 0, 16 and 48.
    let layout = vk.setLayout([
      (0, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 1), (2, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 2), (5, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1),
    ])
    var size: VkDeviceSize = 0
    vk.fn("vkGetDescriptorSetLayoutSizeEXT", PFN_vkGetDescriptorSetLayoutSizeEXT.self)(vk.device, layout, &size)
    #expect(size == 64)
    var offsets: [VkDeviceSize] = [~0, ~0, ~0]
    for (i, binding) in [UInt32(0), 2, 5].enumerated() {
      vk.fn("vkGetDescriptorSetLayoutBindingOffsetEXT", PFN_vkGetDescriptorSetLayoutBindingOffsetEXT.self)(vk.device, layout, binding, &offsets[i])
    }
    #expect(offsets == [0, 16, 48])
    // A layout that is only an empty record: nothing to size.
    let empty = vk.setLayout([])
    var emptySize: VkDeviceSize = ~0
    vk.fn("vkGetDescriptorSetLayoutSizeEXT", PFN_vkGetDescriptorSetLayoutSizeEXT.self)(vk.device, empty, &emptySize)
    #expect(emptySize == 0)

    // The application's descriptor buffer: memory with a buffer made for it, two sets' room.
    let memory = vk.allocate(MemoryTypes.upload, 4096)
    let heap = vk.map(memory)
    let descriptors = vk.buffer(
      1024, usage: VK_BUFFER_USAGE_RESOURCE_DESCRIPTOR_BUFFER_BIT_EXT.rawValue | VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT.rawValue, in: memory, at: 0)
    let data = vk.buffer(
      1024, usage: VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT.rawValue | VK_BUFFER_USAGE_STORAGE_BUFFER_BIT.rawValue | VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT.rawValue,
      in: memory, at: 2048)
    let base = vk.address(of: descriptors)
    let dataAddress = vk.address(of: data)

    let image = vk.image(usage: VK_IMAGE_USAGE_SAMPLED_BIT.rawValue)
    let view = vk.view(image)
    let sampler0 = vk.sampler()
    let sampler1 = vk.sampler()
    let get = vk.fn("vkGetDescriptorEXT", PFN_vkGetDescriptorEXT.self)
    // The second set of the buffer starts at 128.
    let set1 = 128
    func put(_ info: inout VkDescriptorGetInfoEXT, at offset: Int) {
      get(vk.device, &info, descriptorSize, heap + offset)
    }
    var uniform = VkDescriptorAddressInfoEXT()
    uniform.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_ADDRESS_INFO_EXT
    uniform.address = dataAddress + 32
    uniform.range = 96
    withUnsafePointer(to: &uniform) { up in
      var info = VkDescriptorGetInfoEXT()
      info.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_GET_INFO_EXT
      info.type = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER
      info.data.pUniformBuffer = up
      put(&info, at: set1 + 0)
    }
    var storage = VkDescriptorAddressInfoEXT()
    storage.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_ADDRESS_INFO_EXT
    storage.address = dataAddress + 512
    storage.range = 256
    withUnsafePointer(to: &storage) { sp in
      var info = VkDescriptorGetInfoEXT()
      info.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_GET_INFO_EXT
      info.type = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER
      info.data.pStorageBuffer = sp
      put(&info, at: set1 + 48)
    }
    for (k, s) in [sampler0, sampler1].enumerated() {
      var combined = VkDescriptorImageInfo(sampler: s, imageView: view, imageLayout: VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL)
      withUnsafePointer(to: &combined) { cp in
        var info = VkDescriptorGetInfoEXT()
        info.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_GET_INFO_EXT
        info.type = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
        info.data.pCombinedImageSampler = cp
        put(&info, at: set1 + 16 + 16 * k)
      }
    }
    // The 16 bytes are what a set's record holds.
    let record = UInt64(base) + UInt64(set1)
    #expect(vk.gpu.read(record, as: UInt64.self) == dataAddress + 32)
    #expect(vk.gpu.read(record + 8, as: UInt64.self) == 96)
    #expect(vk.gpu.read(record + 16, as: UInt32.self) == 0)  // the view's texture slot
    #expect(vk.gpu.read(record + 20, as: UInt32.self) == 0)  // sampler 0
    #expect(vk.gpu.read(record + 32, as: UInt32.self) == 0)
    #expect(vk.gpu.read(record + 36, as: UInt32.self) == 1)  // sampler 1
    #expect(vk.gpu.read(record + 48, as: UInt64.self) == dataAddress + 512)
    #expect(vk.gpu.read(record + 56, as: UInt64.self) == 256)

    // Bind: the buffer, then the set at an offset in it.
    let pipelineLayout = vk.pipelineLayout([layout, layout])
    let (_, pipeline) = vk.computePipeline(pipelineLayout)
    let cp = vk.commandPool()
    let cb = vk.commandBuffer(cp)
    vk.begin(cb)
    var binding = VkDescriptorBufferBindingInfoEXT()
    binding.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_BUFFER_BINDING_INFO_EXT
    binding.address = base
    binding.usage = VK_BUFFER_USAGE_RESOURCE_DESCRIPTOR_BUFFER_BIT_EXT.rawValue
    var other = binding
    other.address = base + 512
    var bindings = [binding, other]
    vk.fn("vkCmdBindPipeline", PFN_vkCmdBindPipeline.self)(cb, VK_PIPELINE_BIND_POINT_COMPUTE, pipeline)
    vk.fn("vkCmdBindDescriptorBuffersEXT", PFN_vkCmdBindDescriptorBuffersEXT.self)(cb, 2, &bindings)
    // Set 0 from buffer 0 at 128, set 1 from buffer 1 at 64.
    var indices: [UInt32] = [0, 1]
    var at: [VkDeviceSize] = [128, 64]
    vk.fn("vkCmdSetDescriptorBufferOffsetsEXT", PFN_vkCmdSetDescriptorBufferOffsetsEXT.self)(
      cb, VK_PIPELINE_BIND_POINT_COMPUTE, pipelineLayout, 0, 2, &indices, &at)
    vk.fn("vkCmdDispatch", PFN_vkCmdDispatch.self)(cb, 1, 1, 1)
    // Set 1 moved on its own, within the first buffer.
    var one: [UInt32] = [0]
    var move: [VkDeviceSize] = [256]
    vk.fn("vkCmdSetDescriptorBufferOffsetsEXT", PFN_vkCmdSetDescriptorBufferOffsetsEXT.self)(
      cb, VK_PIPELINE_BIND_POINT_COMPUTE, pipelineLayout, 1, 1, &one, &move)
    vk.fn("vkCmdDispatch", PFN_vkCmdDispatch.self)(cb, 1, 1, 1)
    #expect(vk.end(cb) == VK_SUCCESS)
    #expect(vk.submit([cb], fence: vk.fence()) == VK_SUCCESS)
    let dispatches = vk.gpu.submitted[0].list.dispatches
    #expect(dispatches.count == 2)
    func setAddress(_ d: Int, _ i: Int) -> UInt64 { vk.gpu.read(dispatches[d].root + UInt64(RootBlock.setsOffset + 8 * i), as: UInt64.self) }
    #expect(setAddress(0, 0) == base + 128)
    #expect(setAddress(0, 1) == base + 512 + 64)
    #expect(setAddress(1, 0) == base + 128)
    #expect(setAddress(1, 1) == base + 256)
    #expect(setAddress(0, 2) == 0)
    // The set the buffer holds at 128 is the one the descriptors were written to: the record the shader reads.
    #expect(vk.gpu.read(setAddress(0, 0), as: UInt64.self) == dataAddress + 32)
    // More buffers than a command buffer holds fail the end of it.
    let cb2 = vk.commandBuffer(cp)
    vk.begin(cb2)
    var many = [VkDescriptorBufferBindingInfoEXT](repeating: binding, count: 5)
    vk.fn("vkCmdBindDescriptorBuffersEXT", PFN_vkCmdBindDescriptorBuffersEXT.self)(cb2, 5, &many)
    #expect(vk.end(cb2) == VK_ERROR_FEATURE_NOT_PRESENT)
  }
}
