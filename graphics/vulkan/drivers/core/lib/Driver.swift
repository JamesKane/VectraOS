// SPDX-License-Identifier: BSD-3-Clause

// The layer's entry points, by name, and the vkGetInstanceProcAddr and vkGetDeviceProcAddr the loader calls
// (D121): every command is given out for any handle, as Venus's driver does, and the loader filters by level.

import TDVulkan

/// Every command the layer implements, by name.
let coreEntries: [(name: StaticString, function: PFN_vkVoidFunction)] = [
  ("vkAllocateCommandBuffers", unsafe unsafeBitCast(core_vkAllocateCommandBuffers as PFN_vkAllocateCommandBuffers, to: PFN_vkVoidFunction.self)),
  ("vkAllocateDescriptorSets", unsafe unsafeBitCast(core_vkAllocateDescriptorSets as PFN_vkAllocateDescriptorSets, to: PFN_vkVoidFunction.self)),
  ("vkAllocateMemory", unsafe unsafeBitCast(core_vkAllocateMemory as PFN_vkAllocateMemory, to: PFN_vkVoidFunction.self)),
  ("vkBeginCommandBuffer", unsafe unsafeBitCast(core_vkBeginCommandBuffer as PFN_vkBeginCommandBuffer, to: PFN_vkVoidFunction.self)),
  ("vkBindBufferMemory", unsafe unsafeBitCast(core_vkBindBufferMemory as PFN_vkBindBufferMemory, to: PFN_vkVoidFunction.self)),
  ("vkBindBufferMemory2", unsafe unsafeBitCast(core_vkBindBufferMemory2 as PFN_vkBindBufferMemory2, to: PFN_vkVoidFunction.self)),
  ("vkBindImageMemory", unsafe unsafeBitCast(core_vkBindImageMemory as PFN_vkBindImageMemory, to: PFN_vkVoidFunction.self)),
  ("vkBindImageMemory2", unsafe unsafeBitCast(core_vkBindImageMemory2 as PFN_vkBindImageMemory2, to: PFN_vkVoidFunction.self)),
  ("vkCmdBeginQuery", unsafe unsafeBitCast(core_vkCmdBeginQuery as PFN_vkCmdBeginQuery, to: PFN_vkVoidFunction.self)),
  ("vkCmdBeginRendering", unsafe unsafeBitCast(core_vkCmdBeginRendering as PFN_vkCmdBeginRendering, to: PFN_vkVoidFunction.self)),
  ("vkCmdBeginRenderPass", unsafe unsafeBitCast(core_vkCmdBeginRenderPass as PFN_vkCmdBeginRenderPass, to: PFN_vkVoidFunction.self)),
  ("vkCmdBeginRenderPass2", unsafe unsafeBitCast(core_vkCmdBeginRenderPass2 as PFN_vkCmdBeginRenderPass2, to: PFN_vkVoidFunction.self)),
  ("vkCmdBindDescriptorSets", unsafe unsafeBitCast(core_vkCmdBindDescriptorSets as PFN_vkCmdBindDescriptorSets, to: PFN_vkVoidFunction.self)),
  ("vkCmdBindIndexBuffer", unsafe unsafeBitCast(core_vkCmdBindIndexBuffer as PFN_vkCmdBindIndexBuffer, to: PFN_vkVoidFunction.self)),
  ("vkCmdBindPipeline", unsafe unsafeBitCast(core_vkCmdBindPipeline as PFN_vkCmdBindPipeline, to: PFN_vkVoidFunction.self)),
  ("vkCmdBindVertexBuffers", unsafe unsafeBitCast(core_vkCmdBindVertexBuffers as PFN_vkCmdBindVertexBuffers, to: PFN_vkVoidFunction.self)),
  ("vkCmdClearColorImage", unsafe unsafeBitCast(core_vkCmdClearColorImage as PFN_vkCmdClearColorImage, to: PFN_vkVoidFunction.self)),
  ("vkCmdCopyBuffer", unsafe unsafeBitCast(core_vkCmdCopyBuffer as PFN_vkCmdCopyBuffer, to: PFN_vkVoidFunction.self)),
  ("vkCmdCopyBufferToImage", unsafe unsafeBitCast(core_vkCmdCopyBufferToImage as PFN_vkCmdCopyBufferToImage, to: PFN_vkVoidFunction.self)),
  ("vkCmdCopyImageToBuffer", unsafe unsafeBitCast(core_vkCmdCopyImageToBuffer as PFN_vkCmdCopyImageToBuffer, to: PFN_vkVoidFunction.self)),
  ("vkCmdDispatch", unsafe unsafeBitCast(core_vkCmdDispatch as PFN_vkCmdDispatch, to: PFN_vkVoidFunction.self)),
  ("vkCmdDispatchIndirect", unsafe unsafeBitCast(core_vkCmdDispatchIndirect as PFN_vkCmdDispatchIndirect, to: PFN_vkVoidFunction.self)),
  ("vkCmdDraw", unsafe unsafeBitCast(core_vkCmdDraw as PFN_vkCmdDraw, to: PFN_vkVoidFunction.self)),
  ("vkCmdDrawIndexed", unsafe unsafeBitCast(core_vkCmdDrawIndexed as PFN_vkCmdDrawIndexed, to: PFN_vkVoidFunction.self)),
  ("vkCmdDrawIndexedIndirect", unsafe unsafeBitCast(core_vkCmdDrawIndexedIndirect as PFN_vkCmdDrawIndexedIndirect, to: PFN_vkVoidFunction.self)),
  ("vkCmdDrawIndirect", unsafe unsafeBitCast(core_vkCmdDrawIndirect as PFN_vkCmdDrawIndirect, to: PFN_vkVoidFunction.self)),
  ("vkCmdEndQuery", unsafe unsafeBitCast(core_vkCmdEndQuery as PFN_vkCmdEndQuery, to: PFN_vkVoidFunction.self)),
  ("vkCmdEndRendering", unsafe unsafeBitCast(core_vkCmdEndRendering as PFN_vkCmdEndRendering, to: PFN_vkVoidFunction.self)),
  ("vkCmdEndRenderPass", unsafe unsafeBitCast(core_vkCmdEndRenderPass as PFN_vkCmdEndRenderPass, to: PFN_vkVoidFunction.self)),
  ("vkCmdEndRenderPass2", unsafe unsafeBitCast(core_vkCmdEndRenderPass2 as PFN_vkCmdEndRenderPass2, to: PFN_vkVoidFunction.self)),
  ("vkCmdFillBuffer", unsafe unsafeBitCast(core_vkCmdFillBuffer as PFN_vkCmdFillBuffer, to: PFN_vkVoidFunction.self)),
  ("vkCmdNextSubpass", unsafe unsafeBitCast(core_vkCmdNextSubpass as PFN_vkCmdNextSubpass, to: PFN_vkVoidFunction.self)),
  ("vkCmdPipelineBarrier", unsafe unsafeBitCast(core_vkCmdPipelineBarrier as PFN_vkCmdPipelineBarrier, to: PFN_vkVoidFunction.self)),
  ("vkCmdPipelineBarrier2", unsafe unsafeBitCast(core_vkCmdPipelineBarrier2 as PFN_vkCmdPipelineBarrier2, to: PFN_vkVoidFunction.self)),
  ("vkCmdPushConstants", unsafe unsafeBitCast(core_vkCmdPushConstants as PFN_vkCmdPushConstants, to: PFN_vkVoidFunction.self)),
  ("vkCmdResetQueryPool", unsafe unsafeBitCast(core_vkCmdResetQueryPool as PFN_vkCmdResetQueryPool, to: PFN_vkVoidFunction.self)),
  ("vkCmdSetScissor", unsafe unsafeBitCast(core_vkCmdSetScissor as PFN_vkCmdSetScissor, to: PFN_vkVoidFunction.self)),
  ("vkCmdSetViewport", unsafe unsafeBitCast(core_vkCmdSetViewport as PFN_vkCmdSetViewport, to: PFN_vkVoidFunction.self)),
  ("vkCmdUpdateBuffer", unsafe unsafeBitCast(core_vkCmdUpdateBuffer as PFN_vkCmdUpdateBuffer, to: PFN_vkVoidFunction.self)),
  ("vkCmdWriteTimestamp", unsafe unsafeBitCast(core_vkCmdWriteTimestamp as PFN_vkCmdWriteTimestamp, to: PFN_vkVoidFunction.self)),
  ("vkCmdWriteTimestamp2", unsafe unsafeBitCast(core_vkCmdWriteTimestamp2 as PFN_vkCmdWriteTimestamp2, to: PFN_vkVoidFunction.self)),
  ("vkCreateBuffer", unsafe unsafeBitCast(core_vkCreateBuffer as PFN_vkCreateBuffer, to: PFN_vkVoidFunction.self)),
  ("vkCreateCommandPool", unsafe unsafeBitCast(core_vkCreateCommandPool as PFN_vkCreateCommandPool, to: PFN_vkVoidFunction.self)),
  ("vkCreateComputePipelines", unsafe unsafeBitCast(core_vkCreateComputePipelines as PFN_vkCreateComputePipelines, to: PFN_vkVoidFunction.self)),
  ("vkCreateDescriptorPool", unsafe unsafeBitCast(core_vkCreateDescriptorPool as PFN_vkCreateDescriptorPool, to: PFN_vkVoidFunction.self)),
  ("vkCreateDescriptorSetLayout", unsafe unsafeBitCast(core_vkCreateDescriptorSetLayout as PFN_vkCreateDescriptorSetLayout, to: PFN_vkVoidFunction.self)),
  ("vkCreateDevice", unsafe unsafeBitCast(core_vkCreateDevice as PFN_vkCreateDevice, to: PFN_vkVoidFunction.self)),
  ("vkCreateFence", unsafe unsafeBitCast(core_vkCreateFence as PFN_vkCreateFence, to: PFN_vkVoidFunction.self)),
  ("vkCreateFramebuffer", unsafe unsafeBitCast(core_vkCreateFramebuffer as PFN_vkCreateFramebuffer, to: PFN_vkVoidFunction.self)),
  ("vkCreateGraphicsPipelines", unsafe unsafeBitCast(core_vkCreateGraphicsPipelines as PFN_vkCreateGraphicsPipelines, to: PFN_vkVoidFunction.self)),
  ("vkCreateImage", unsafe unsafeBitCast(core_vkCreateImage as PFN_vkCreateImage, to: PFN_vkVoidFunction.self)),
  ("vkCreateImageView", unsafe unsafeBitCast(core_vkCreateImageView as PFN_vkCreateImageView, to: PFN_vkVoidFunction.self)),
  ("vkCreateInstance", unsafe unsafeBitCast(core_vkCreateInstance as PFN_vkCreateInstance, to: PFN_vkVoidFunction.self)),
  ("vkCreatePipelineCache", unsafe unsafeBitCast(core_vkCreatePipelineCache as PFN_vkCreatePipelineCache, to: PFN_vkVoidFunction.self)),
  ("vkCreatePipelineLayout", unsafe unsafeBitCast(core_vkCreatePipelineLayout as PFN_vkCreatePipelineLayout, to: PFN_vkVoidFunction.self)),
  ("vkCreateQueryPool", unsafe unsafeBitCast(core_vkCreateQueryPool as PFN_vkCreateQueryPool, to: PFN_vkVoidFunction.self)),
  ("vkCreateRenderPass", unsafe unsafeBitCast(core_vkCreateRenderPass as PFN_vkCreateRenderPass, to: PFN_vkVoidFunction.self)),
  ("vkCreateRenderPass2", unsafe unsafeBitCast(core_vkCreateRenderPass2 as PFN_vkCreateRenderPass2, to: PFN_vkVoidFunction.self)),
  ("vkCreateSampler", unsafe unsafeBitCast(core_vkCreateSampler as PFN_vkCreateSampler, to: PFN_vkVoidFunction.self)),
  ("vkCreateSemaphore", unsafe unsafeBitCast(core_vkCreateSemaphore as PFN_vkCreateSemaphore, to: PFN_vkVoidFunction.self)),
  ("vkCreateShaderModule", unsafe unsafeBitCast(core_vkCreateShaderModule as PFN_vkCreateShaderModule, to: PFN_vkVoidFunction.self)),
  ("vkDestroyBuffer", unsafe unsafeBitCast(core_vkDestroyBuffer as PFN_vkDestroyBuffer, to: PFN_vkVoidFunction.self)),
  ("vkDestroyCommandPool", unsafe unsafeBitCast(core_vkDestroyCommandPool as PFN_vkDestroyCommandPool, to: PFN_vkVoidFunction.self)),
  ("vkDestroyDescriptorPool", unsafe unsafeBitCast(core_vkDestroyDescriptorPool as PFN_vkDestroyDescriptorPool, to: PFN_vkVoidFunction.self)),
  ("vkDestroyDescriptorSetLayout", unsafe unsafeBitCast(core_vkDestroyDescriptorSetLayout as PFN_vkDestroyDescriptorSetLayout, to: PFN_vkVoidFunction.self)),
  ("vkDestroyDevice", unsafe unsafeBitCast(core_vkDestroyDevice as PFN_vkDestroyDevice, to: PFN_vkVoidFunction.self)),
  ("vkDestroyFence", unsafe unsafeBitCast(core_vkDestroyFence as PFN_vkDestroyFence, to: PFN_vkVoidFunction.self)),
  ("vkDestroyFramebuffer", unsafe unsafeBitCast(core_vkDestroyFramebuffer as PFN_vkDestroyFramebuffer, to: PFN_vkVoidFunction.self)),
  ("vkDestroyImage", unsafe unsafeBitCast(core_vkDestroyImage as PFN_vkDestroyImage, to: PFN_vkVoidFunction.self)),
  ("vkDestroyImageView", unsafe unsafeBitCast(core_vkDestroyImageView as PFN_vkDestroyImageView, to: PFN_vkVoidFunction.self)),
  ("vkDestroyInstance", unsafe unsafeBitCast(core_vkDestroyInstance as PFN_vkDestroyInstance, to: PFN_vkVoidFunction.self)),
  ("vkDestroyPipeline", unsafe unsafeBitCast(core_vkDestroyPipeline as PFN_vkDestroyPipeline, to: PFN_vkVoidFunction.self)),
  ("vkDestroyPipelineCache", unsafe unsafeBitCast(core_vkDestroyPipelineCache as PFN_vkDestroyPipelineCache, to: PFN_vkVoidFunction.self)),
  ("vkDestroyPipelineLayout", unsafe unsafeBitCast(core_vkDestroyPipelineLayout as PFN_vkDestroyPipelineLayout, to: PFN_vkVoidFunction.self)),
  ("vkDestroyQueryPool", unsafe unsafeBitCast(core_vkDestroyQueryPool as PFN_vkDestroyQueryPool, to: PFN_vkVoidFunction.self)),
  ("vkDestroyRenderPass", unsafe unsafeBitCast(core_vkDestroyRenderPass as PFN_vkDestroyRenderPass, to: PFN_vkVoidFunction.self)),
  ("vkDestroySampler", unsafe unsafeBitCast(core_vkDestroySampler as PFN_vkDestroySampler, to: PFN_vkVoidFunction.self)),
  ("vkDestroySemaphore", unsafe unsafeBitCast(core_vkDestroySemaphore as PFN_vkDestroySemaphore, to: PFN_vkVoidFunction.self)),
  ("vkDestroyShaderModule", unsafe unsafeBitCast(core_vkDestroyShaderModule as PFN_vkDestroyShaderModule, to: PFN_vkVoidFunction.self)),
  ("vkDeviceWaitIdle", unsafe unsafeBitCast(core_vkDeviceWaitIdle as PFN_vkDeviceWaitIdle, to: PFN_vkVoidFunction.self)),
  ("vkEndCommandBuffer", unsafe unsafeBitCast(core_vkEndCommandBuffer as PFN_vkEndCommandBuffer, to: PFN_vkVoidFunction.self)),
  ("vkEnumerateDeviceExtensionProperties", unsafe unsafeBitCast(core_vkEnumerateDeviceExtensionProperties as PFN_vkEnumerateDeviceExtensionProperties, to: PFN_vkVoidFunction.self)),
  ("vkEnumerateDeviceLayerProperties", unsafe unsafeBitCast(core_vkEnumerateDeviceLayerProperties as PFN_vkEnumerateDeviceLayerProperties, to: PFN_vkVoidFunction.self)),
  ("vkEnumerateInstanceExtensionProperties", unsafe unsafeBitCast(core_vkEnumerateInstanceExtensionProperties as PFN_vkEnumerateInstanceExtensionProperties, to: PFN_vkVoidFunction.self)),
  ("vkEnumerateInstanceLayerProperties", unsafe unsafeBitCast(core_vkEnumerateInstanceLayerProperties as PFN_vkEnumerateInstanceLayerProperties, to: PFN_vkVoidFunction.self)),
  ("vkEnumerateInstanceVersion", unsafe unsafeBitCast(core_vkEnumerateInstanceVersion as PFN_vkEnumerateInstanceVersion, to: PFN_vkVoidFunction.self)),
  ("vkEnumeratePhysicalDevices", unsafe unsafeBitCast(core_vkEnumeratePhysicalDevices as PFN_vkEnumeratePhysicalDevices, to: PFN_vkVoidFunction.self)),
  ("vkFlushMappedMemoryRanges", unsafe unsafeBitCast(core_vkFlushMappedMemoryRanges as PFN_vkFlushMappedMemoryRanges, to: PFN_vkVoidFunction.self)),
  ("vkFreeCommandBuffers", unsafe unsafeBitCast(core_vkFreeCommandBuffers as PFN_vkFreeCommandBuffers, to: PFN_vkVoidFunction.self)),
  ("vkFreeDescriptorSets", unsafe unsafeBitCast(core_vkFreeDescriptorSets as PFN_vkFreeDescriptorSets, to: PFN_vkVoidFunction.self)),
  ("vkFreeMemory", unsafe unsafeBitCast(core_vkFreeMemory as PFN_vkFreeMemory, to: PFN_vkVoidFunction.self)),
  ("vkGetBufferDeviceAddress", unsafe unsafeBitCast(core_vkGetBufferDeviceAddress as PFN_vkGetBufferDeviceAddress, to: PFN_vkVoidFunction.self)),
  ("vkGetBufferMemoryRequirements", unsafe unsafeBitCast(core_vkGetBufferMemoryRequirements as PFN_vkGetBufferMemoryRequirements, to: PFN_vkVoidFunction.self)),
  ("vkGetBufferMemoryRequirements2", unsafe unsafeBitCast(core_vkGetBufferMemoryRequirements2 as PFN_vkGetBufferMemoryRequirements2, to: PFN_vkVoidFunction.self)),
  ("vkGetDeviceProcAddr", unsafe unsafeBitCast(core_vkGetDeviceProcAddr as PFN_vkGetDeviceProcAddr, to: PFN_vkVoidFunction.self)),
  ("vkGetDeviceQueue", unsafe unsafeBitCast(core_vkGetDeviceQueue as PFN_vkGetDeviceQueue, to: PFN_vkVoidFunction.self)),
  ("vkGetDeviceQueue2", unsafe unsafeBitCast(core_vkGetDeviceQueue2 as PFN_vkGetDeviceQueue2, to: PFN_vkVoidFunction.self)),
  ("vkGetFenceStatus", unsafe unsafeBitCast(core_vkGetFenceStatus as PFN_vkGetFenceStatus, to: PFN_vkVoidFunction.self)),
  ("vkGetImageMemoryRequirements", unsafe unsafeBitCast(core_vkGetImageMemoryRequirements as PFN_vkGetImageMemoryRequirements, to: PFN_vkVoidFunction.self)),
  ("vkGetImageMemoryRequirements2", unsafe unsafeBitCast(core_vkGetImageMemoryRequirements2 as PFN_vkGetImageMemoryRequirements2, to: PFN_vkVoidFunction.self)),
  ("vkGetInstanceProcAddr", unsafe unsafeBitCast(core_vkGetInstanceProcAddr as PFN_vkGetInstanceProcAddr, to: PFN_vkVoidFunction.self)),
  ("vkGetPhysicalDeviceFeatures", unsafe unsafeBitCast(core_vkGetPhysicalDeviceFeatures as PFN_vkGetPhysicalDeviceFeatures, to: PFN_vkVoidFunction.self)),
  ("vkGetPhysicalDeviceFeatures2", unsafe unsafeBitCast(core_vkGetPhysicalDeviceFeatures2 as PFN_vkGetPhysicalDeviceFeatures2, to: PFN_vkVoidFunction.self)),
  ("vkGetPhysicalDeviceFormatProperties", unsafe unsafeBitCast(core_vkGetPhysicalDeviceFormatProperties as PFN_vkGetPhysicalDeviceFormatProperties, to: PFN_vkVoidFunction.self)),
  ("vkGetPhysicalDeviceImageFormatProperties", unsafe unsafeBitCast(core_vkGetPhysicalDeviceImageFormatProperties as PFN_vkGetPhysicalDeviceImageFormatProperties, to: PFN_vkVoidFunction.self)),
  ("vkGetPhysicalDeviceMemoryProperties", unsafe unsafeBitCast(core_vkGetPhysicalDeviceMemoryProperties as PFN_vkGetPhysicalDeviceMemoryProperties, to: PFN_vkVoidFunction.self)),
  ("vkGetPhysicalDeviceMemoryProperties2", unsafe unsafeBitCast(core_vkGetPhysicalDeviceMemoryProperties2 as PFN_vkGetPhysicalDeviceMemoryProperties2, to: PFN_vkVoidFunction.self)),
  ("vkGetPhysicalDeviceProperties", unsafe unsafeBitCast(core_vkGetPhysicalDeviceProperties as PFN_vkGetPhysicalDeviceProperties, to: PFN_vkVoidFunction.self)),
  ("vkGetPhysicalDeviceProperties2", unsafe unsafeBitCast(core_vkGetPhysicalDeviceProperties2 as PFN_vkGetPhysicalDeviceProperties2, to: PFN_vkVoidFunction.self)),
  ("vkGetPhysicalDeviceQueueFamilyProperties", unsafe unsafeBitCast(core_vkGetPhysicalDeviceQueueFamilyProperties as PFN_vkGetPhysicalDeviceQueueFamilyProperties, to: PFN_vkVoidFunction.self)),
  ("vkGetPhysicalDeviceQueueFamilyProperties2", unsafe unsafeBitCast(core_vkGetPhysicalDeviceQueueFamilyProperties2 as PFN_vkGetPhysicalDeviceQueueFamilyProperties2, to: PFN_vkVoidFunction.self)),
  ("vkGetPipelineCacheData", unsafe unsafeBitCast(core_vkGetPipelineCacheData as PFN_vkGetPipelineCacheData, to: PFN_vkVoidFunction.self)),
  ("vkGetQueryPoolResults", unsafe unsafeBitCast(core_vkGetQueryPoolResults as PFN_vkGetQueryPoolResults, to: PFN_vkVoidFunction.self)),
  ("vkGetSemaphoreCounterValue", unsafe unsafeBitCast(core_vkGetSemaphoreCounterValue as PFN_vkGetSemaphoreCounterValue, to: PFN_vkVoidFunction.self)),
  ("vkInvalidateMappedMemoryRanges", unsafe unsafeBitCast(core_vkInvalidateMappedMemoryRanges as PFN_vkInvalidateMappedMemoryRanges, to: PFN_vkVoidFunction.self)),
  ("vkMapMemory", unsafe unsafeBitCast(core_vkMapMemory as PFN_vkMapMemory, to: PFN_vkVoidFunction.self)),
  ("vkMergePipelineCaches", unsafe unsafeBitCast(core_vkMergePipelineCaches as PFN_vkMergePipelineCaches, to: PFN_vkVoidFunction.self)),
  ("vkQueueSubmit", unsafe unsafeBitCast(core_vkQueueSubmit as PFN_vkQueueSubmit, to: PFN_vkVoidFunction.self)),
  ("vkQueueSubmit2", unsafe unsafeBitCast(core_vkQueueSubmit2 as PFN_vkQueueSubmit2, to: PFN_vkVoidFunction.self)),
  ("vkQueueWaitIdle", unsafe unsafeBitCast(core_vkQueueWaitIdle as PFN_vkQueueWaitIdle, to: PFN_vkVoidFunction.self)),
  ("vkResetCommandBuffer", unsafe unsafeBitCast(core_vkResetCommandBuffer as PFN_vkResetCommandBuffer, to: PFN_vkVoidFunction.self)),
  ("vkResetCommandPool", unsafe unsafeBitCast(core_vkResetCommandPool as PFN_vkResetCommandPool, to: PFN_vkVoidFunction.self)),
  ("vkResetDescriptorPool", unsafe unsafeBitCast(core_vkResetDescriptorPool as PFN_vkResetDescriptorPool, to: PFN_vkVoidFunction.self)),
  ("vkResetFences", unsafe unsafeBitCast(core_vkResetFences as PFN_vkResetFences, to: PFN_vkVoidFunction.self)),
  ("vkSignalSemaphore", unsafe unsafeBitCast(core_vkSignalSemaphore as PFN_vkSignalSemaphore, to: PFN_vkVoidFunction.self)),
  ("vkTrimCommandPool", unsafe unsafeBitCast(core_vkTrimCommandPool as PFN_vkTrimCommandPool, to: PFN_vkVoidFunction.self)),
  ("vkUnmapMemory", unsafe unsafeBitCast(core_vkUnmapMemory as PFN_vkUnmapMemory, to: PFN_vkVoidFunction.self)),
  ("vkUpdateDescriptorSets", unsafe unsafeBitCast(core_vkUpdateDescriptorSets as PFN_vkUpdateDescriptorSets, to: PFN_vkVoidFunction.self)),
  ("vkWaitForFences", unsafe unsafeBitCast(core_vkWaitForFences as PFN_vkWaitForFences, to: PFN_vkVoidFunction.self)),
  ("vkWaitSemaphores", unsafe unsafeBitCast(core_vkWaitSemaphores as PFN_vkWaitSemaphores, to: PFN_vkVoidFunction.self)),
]

/// A command's entry point by name, or nil.
func coreProcAddress(_ name: UnsafePointer<CChar>?) -> PFN_vkVoidFunction? {
  guard let name = unsafe name else { return nil }
  for entry in coreEntries {
    var i = 0
    let s = unsafe entry.name.utf8Start
    while unsafe s[i] != 0, unsafe UInt8(bitPattern: name[i]) == s[i] { i += 1 }
    if unsafe s[i] == 0 && name[i] == 0 { return entry.function }
  }
  return nil
}

/// The layer's vkGetInstanceProcAddr, as the loader calls a driver's: standard pointer types only.
public let coreGetInstanceProcAddr: @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> UnsafeRawPointer? = {
  instance, name in unsafe unsafeBitCast(coreProcAddress(name), to: UnsafeRawPointer?.self)
}

/// The layer's vkGetDeviceProcAddr.
public let coreGetDeviceProcAddr: @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> UnsafeRawPointer? = {
  device, name in unsafe unsafeBitCast(coreProcAddress(name), to: UnsafeRawPointer?.self)
}
