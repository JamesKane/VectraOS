// SPDX-License-Identifier: BSD-3-Clause

/// What Todhchai's hosted Vulkan uses: core 1.0–1.4, and the extensions
/// Loinnir needs to render, to share images as dmabufs with the compositor
/// (M1f2), and to report validation messages. Presentation is
/// VK_KHR_surface and VK_KHR_swapchain, with our own window surface.
public let loinnirSelection = VulkanSelection(
  maxVersion: "VK_VERSION_1_4",
  extensions: [
    "VK_EXT_debug_utils",
    "VK_KHR_external_memory_fd",
    "VK_KHR_external_semaphore_fd",
    "VK_EXT_external_memory_dma_buf",
    "VK_EXT_image_drm_format_modifier",
    "VK_EXT_physical_device_drm",
    "VK_EXT_queue_family_foreign",
    "VK_EXT_descriptor_buffer",
    "VK_EXT_shader_object",
    // A sampler's own border colour (GPUCoreVulkan's `customBorderColor`), where the host's Vulkan has it.
    "VK_EXT_custom_border_color",
    // Natively: a VkDeviceMemory's VMO, to hand Radharc (M5j). The Venus
    // client driver implements it itself.
    "VK_FUCHSIA_external_memory",
    // Presentation (D174, "Presentation, as designed"): a surface and a swapchain over a Radharc window. The window
    // surface itself (VK_VECTRA_window_surface) is ours, not Khronos's: vulkan_vectra.h.
    "VK_KHR_surface",
    "VK_KHR_swapchain",
  ])
