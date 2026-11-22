// SPDX-License-Identifier: BSD-3-Clause

// vulkan-present (vulkan-present(8), D174, "Presentation, as designed"): a Vulkan program in C that puts frames in a window
// of Radharc's, as a port would: VK_KHR_surface with our VK_VECTRA_window_surface, and VK_KHR_swapchain. C because that is
// Vulkan's interface. It runs where Radharc does and composes on the GPU (boot-venus), and checks:
//   - the extensions are offered, the surface says its size, its formats (B8G8R8A8 UNORM and SRGB) and FIFO;
//   - 120 frames are acquired, drawn (a clear colour that changes every frame, and on the last a triangle) and presented,
//     each call returning VK_SUCCESS (or VK_SUBOPTIMAL_KHR in the frame the window changed size);
//   - the window the frames are in is Radharc's, and what it composed is what was drawn: the pixels of the last frame, read
//     from Radharc's composed frame (/svc/windows/pixel), exactly: a pixel of the clear colour and one inside the triangle;
//   - the window is made fullscreen and put back, mid-run: the resize reaches the program as an event, the swapchain says
//     VK_ERROR_OUT_OF_DATE_KHR, and is made again with oldSwapchain, at the new size, each time.
// It prints `ok: vulkan present frames`, `ok: vulkan present pixels`, `ok: vulkan present resize` and
// `ok: vulkan present events`, and exits 0 only if each held. Its shaders are user/tier1/vulkan-shaders' (the triangle's).

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "td_vulkan.h"
#include "vulkan_vectra.h"
#include "shaders.h"

extern PFN_vkVoidFunction vkGetInstanceProcAddr(VkInstance instance, const char *name);

#define COMMANDS(X)                                                                                                     \
  X(vkCreateInstance) X(vkDestroyInstance) X(vkEnumeratePhysicalDevices) X(vkGetPhysicalDeviceQueueFamilyProperties)  \
  X(vkGetPhysicalDeviceMemoryProperties) X(vkCreateDevice) X(vkDestroyDevice) X(vkGetDeviceQueue) X(vkCreateBuffer)  \
  X(vkDestroyBuffer) X(vkGetBufferMemoryRequirements) X(vkAllocateMemory) X(vkFreeMemory) X(vkBindBufferMemory)       \
  X(vkMapMemory) X(vkUnmapMemory) X(vkCreateShaderModule) X(vkDestroyShaderModule) X(vkCreatePipelineLayout)          \
  X(vkDestroyPipelineLayout) X(vkCreateGraphicsPipelines) X(vkDestroyPipeline) X(vkCreateImageView)                   \
  X(vkDestroyImageView) X(vkCreateRenderPass) X(vkDestroyRenderPass) X(vkCreateFramebuffer) X(vkDestroyFramebuffer)   \
  X(vkCreateCommandPool) X(vkDestroyCommandPool) X(vkAllocateCommandBuffers) X(vkBeginCommandBuffer)                  \
  X(vkEndCommandBuffer) X(vkCmdBindPipeline) X(vkCmdBeginRenderPass) X(vkCmdEndRenderPass) X(vkCmdBindVertexBuffers)  \
  X(vkCmdDraw) X(vkQueueSubmit) X(vkCreateFence) X(vkDestroyFence) X(vkWaitForFences) X(vkResetFences)                \
  X(vkCreateSemaphore) X(vkDestroySemaphore) X(vkDeviceWaitIdle) X(vkDestroySurfaceKHR)                               \
  X(vkGetPhysicalDeviceSurfaceSupportKHR) X(vkGetPhysicalDeviceSurfaceCapabilitiesKHR)                                \
  X(vkGetPhysicalDeviceSurfaceFormatsKHR) X(vkGetPhysicalDeviceSurfacePresentModesKHR) X(vkCreateSwapchainKHR)        \
  X(vkDestroySwapchainKHR) X(vkGetSwapchainImagesKHR) X(vkAcquireNextImageKHR) X(vkQueuePresentKHR)                   \
  X(vkEnumerateInstanceExtensionProperties) X(vkEnumerateDeviceExtensionProperties) X(vkCreateVectraWindowSurface)    \
  X(vkPollVectraWindowEventsVECTRA) X(vkSetVectraWindowFullscreenVECTRA) X(vkResetCommandBuffer)

static struct {
#define X(name) PFN_##name name;
  COMMANDS(X)
#undef X
} vk;

static int failures;

static void check(int ok, const char *what) {
  if (!ok) {
    printf("vulkan-present: FAILED: %s\n", what);
    failures++;
  }
}

static int succeeded(VkResult r, const char *call) {
  if (r == VK_SUCCESS) return 1;
  printf("vulkan-present: FAILED: %s returned %d\n", call, (int)r);
  failures++;
  return 0;
}

static int load(VkInstance instance) {
  int missing = 0;
#define X(name)                                                                                                         \
  vk.name = (PFN_##name)vkGetInstanceProcAddr(instance, #name);                                                         \
  if (!vk.name) {                                                                                                       \
    printf("vulkan-present: FAILED: the loader has no %s\n", #name);                                                    \
    missing++;                                                                                                          \
  }
  COMMANDS(X)
#undef X
  return missing == 0;
}

static VkInstance instance;
static VkPhysicalDevice physical;
static VkDevice device;
static VkQueue queue;
static uint32_t family;
static VkPhysicalDeviceMemoryProperties memory;
static VkCommandPool pool;
static VkSurfaceKHR surface;

enum { frames = 120, max_images = 3 };
enum { window_width = 320, window_height = 240 };

typedef struct {
  float x, y, r, g, b, a;
} Vertex;

static const Vertex triangle[3] = {
    {-0.5f, -0.5f, 1, 1, 0, 1},
    {0.5f, -0.5f, 1, 1, 0, 1},
    {0.0f, 0.5f, 1, 1, 0, 1},
};

static int memory_type(uint32_t allowed, VkMemoryPropertyFlags want) {
  for (uint32_t i = 0; i < memory.memoryTypeCount; i++) {
    if ((allowed & (1u << i)) && (memory.memoryTypes[i].propertyFlags & want) == want) return (int)i;
  }
  return -1;
}

// MARK: The swapchain and what is made for it

typedef struct {
  VkSwapchainKHR chain;
  VkExtent2D extent;
  uint32_t count;
  VkImage images[max_images];
  VkImageView views[max_images];
  VkFramebuffer framebuffers[max_images];
  VkCommandBuffer commands[max_images];
  VkPipeline pipeline;
} Swap;

static VkRenderPass pass;
static VkPipelineLayout layout;
static VkShaderModule vertex_shader, fragment_shader;
static VkBuffer vertex_buffer;
static VkDeviceMemory vertex_memory;
static VkSemaphore acquired, rendered;
static VkFence in_flight;

static void destroy_swap_resources(Swap *s) {
  for (uint32_t i = 0; i < s->count; i++) {
    if (s->framebuffers[i]) vk.vkDestroyFramebuffer(device, s->framebuffers[i], NULL);
    if (s->views[i]) vk.vkDestroyImageView(device, s->views[i], NULL);
    s->framebuffers[i] = NULL;
    s->views[i] = NULL;
  }
  if (s->pipeline) vk.vkDestroyPipeline(device, s->pipeline, NULL);
  s->pipeline = NULL;
}

/// A pipeline for `extent`, in the render pass.
static int make_pipeline(Swap *s) {
  VkPipelineShaderStageCreateInfo stages[2] = {
      {.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_VERTEX_BIT,
       .module = vertex_shader, .pName = "main"},
      {.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_FRAGMENT_BIT,
       .module = fragment_shader, .pName = "main"},
  };
  VkVertexInputBindingDescription binding = {0, sizeof(Vertex), VK_VERTEX_INPUT_RATE_VERTEX};
  VkVertexInputAttributeDescription attributes[2] = {{0, 0, VK_FORMAT_R32G32_SFLOAT, 0},
                                                     {1, 0, VK_FORMAT_R32G32B32A32_SFLOAT, 8}};
  VkPipelineVertexInputStateCreateInfo vertex_input = {.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
                                                       .vertexBindingDescriptionCount = 1,
                                                       .pVertexBindingDescriptions = &binding,
                                                       .vertexAttributeDescriptionCount = 2,
                                                       .pVertexAttributeDescriptions = attributes};
  VkPipelineInputAssemblyStateCreateInfo assembly = {.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
                                                     .topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST};
  VkViewport viewport = {0, 0, (float)s->extent.width, (float)s->extent.height, 0, 1};
  VkRect2D scissor = {{0, 0}, s->extent};
  VkPipelineViewportStateCreateInfo viewport_state = {.sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
                                                      .viewportCount = 1, .pViewports = &viewport, .scissorCount = 1,
                                                      .pScissors = &scissor};
  VkPipelineRasterizationStateCreateInfo raster = {.sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
                                                   .polygonMode = VK_POLYGON_MODE_FILL, .cullMode = VK_CULL_MODE_NONE,
                                                   .frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE, .lineWidth = 1.0f};
  VkPipelineMultisampleStateCreateInfo multisample = {.sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
                                                      .rasterizationSamples = VK_SAMPLE_COUNT_1_BIT};
  VkPipelineColorBlendAttachmentState blend_attachment = {
      .colorWriteMask = VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT | VK_COLOR_COMPONENT_B_BIT |
                        VK_COLOR_COMPONENT_A_BIT};
  VkPipelineColorBlendStateCreateInfo blend = {.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
                                               .attachmentCount = 1, .pAttachments = &blend_attachment};
  VkGraphicsPipelineCreateInfo info = {.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO, .stageCount = 2,
                                       .pStages = stages, .pVertexInputState = &vertex_input,
                                       .pInputAssemblyState = &assembly, .pViewportState = &viewport_state,
                                       .pRasterizationState = &raster, .pMultisampleState = &multisample,
                                       .pColorBlendState = &blend, .layout = layout, .renderPass = pass, .subpass = 0};
  return succeeded(vk.vkCreateGraphicsPipelines(device, NULL, 1, &info, NULL, &s->pipeline), "vkCreateGraphicsPipelines");
}

/// A swapchain for the surface at its current size, replacing `old` (which is destroyed once the new one exists).
static int make_swap(Swap *s, Swap *old) {
  VkSurfaceCapabilitiesKHR caps;
  if (!succeeded(vk.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(physical, surface, &caps), "vkGetPhysicalDeviceSurfaceCapabilitiesKHR"))
    return 0;
  memset(s, 0, sizeof *s);
  s->extent = caps.currentExtent;
  VkSwapchainCreateInfoKHR info = {.sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR, .surface = surface,
                                   .minImageCount = 3, .imageFormat = VK_FORMAT_B8G8R8A8_UNORM,
                                   .imageColorSpace = VK_COLOR_SPACE_SRGB_NONLINEAR_KHR, .imageExtent = caps.currentExtent,
                                   .imageArrayLayers = 1,
                                   .imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT,
                                   .imageSharingMode = VK_SHARING_MODE_EXCLUSIVE,
                                   .preTransform = VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR,
                                   .compositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR, .presentMode = VK_PRESENT_MODE_FIFO_KHR,
                                   .clipped = VK_TRUE, .oldSwapchain = old ? old->chain : NULL};
  if (!succeeded(vk.vkCreateSwapchainKHR(device, &info, NULL, &s->chain), "vkCreateSwapchainKHR")) return 0;
  s->count = max_images;
  if (!succeeded(vk.vkGetSwapchainImagesKHR(device, s->chain, &s->count, s->images), "vkGetSwapchainImagesKHR")) return 0;
  check(s->count >= 2 && s->count <= max_images, "the swapchain has two or three images");
  for (uint32_t i = 0; i < s->count; i++) {
    VkImageViewCreateInfo view = {.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = s->images[i],
                                  .viewType = VK_IMAGE_VIEW_TYPE_2D, .format = VK_FORMAT_B8G8R8A8_UNORM,
                                  .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1}};
    if (!succeeded(vk.vkCreateImageView(device, &view, NULL, &s->views[i]), "vkCreateImageView")) return 0;
    VkFramebufferCreateInfo fb = {.sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO, .renderPass = pass,
                                  .attachmentCount = 1, .pAttachments = &s->views[i], .width = s->extent.width,
                                  .height = s->extent.height, .layers = 1};
    if (!succeeded(vk.vkCreateFramebuffer(device, &fb, NULL, &s->framebuffers[i]), "vkCreateFramebuffer")) return 0;
    VkCommandBufferAllocateInfo alloc = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = pool,
                                         .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1};
    if (!succeeded(vk.vkAllocateCommandBuffers(device, &alloc, &s->commands[i]), "vkAllocateCommandBuffers")) return 0;
  }
  if (!make_pipeline(s)) return 0;
  if (old) {
    vk.vkDeviceWaitIdle(device);
    destroy_swap_resources(old);
    vk.vkDestroySwapchainKHR(device, old->chain, NULL);
    old->chain = NULL;
  }
  return 1;
}

// MARK: Drawing a frame

/// The frame's clear colour as bytes (red, green, blue): each channel a whole step of UNORM, so what is written is exact.
static void frame_color(int frame, uint8_t rgb[3]) {
  rgb[0] = (uint8_t)((frame * 2) & 255);
  rgb[1] = (uint8_t)(255 - ((frame * 2) & 255));
  rgb[2] = (uint8_t)(32 + (frame & 63));
}

/// Draws frame `frame` into image `index` of `s`: the clear colour, and the triangle in the last.
static int draw(Swap *s, uint32_t index, int frame) {
  VkCommandBuffer cmd = s->commands[index];
  VkCommandBufferBeginInfo begin = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
                                    .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT};
  vk.vkResetCommandBuffer(cmd, 0);
  if (!succeeded(vk.vkBeginCommandBuffer(cmd, &begin), "vkBeginCommandBuffer")) return 0;
  uint8_t rgb[3];
  frame_color(frame, rgb);
  VkClearValue clear = {.color = {.float32 = {rgb[0] / 255.0f, rgb[1] / 255.0f, rgb[2] / 255.0f, 1.0f}}};
  VkRenderPassBeginInfo info = {.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO, .renderPass = pass,
                                .framebuffer = s->framebuffers[index], .renderArea = {{0, 0}, s->extent},
                                .clearValueCount = 1, .pClearValues = &clear};
  vk.vkCmdBeginRenderPass(cmd, &info, VK_SUBPASS_CONTENTS_INLINE);
  if (frame == frames - 1) {
    vk.vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, s->pipeline);
    VkDeviceSize offset = 0;
    vk.vkCmdBindVertexBuffers(cmd, 0, 1, &vertex_buffer, &offset);
    vk.vkCmdDraw(cmd, 3, 1, 0, 0);
  }
  vk.vkCmdEndRenderPass(cmd);
  return succeeded(vk.vkEndCommandBuffer(cmd), "vkEndCommandBuffer");
}

typedef struct {
  int presented;
  int out_of_date;
  int suboptimal;
  int errors;
} Counts;

/// Acquires, draws and presents one frame. Returns 1 if it was presented, 0 if the swapchain is out of date (nothing was drawn
/// or the present was refused), -1 on an error.
static int frame_once(Swap *s, int frame, Counts *c) {
  uint32_t index = 0;
  VkResult r = vk.vkAcquireNextImageKHR(device, s->chain, UINT64_MAX, acquired, NULL, &index);
  if (r == VK_ERROR_OUT_OF_DATE_KHR) {
    c->out_of_date++;
    return 0;
  }
  if (r == VK_SUBOPTIMAL_KHR) c->suboptimal++;
  else if (r != VK_SUCCESS) {
    printf("vulkan-present: vkAcquireNextImageKHR returned %d\n", (int)r);
    c->errors++;
    return -1;
  }
  if (index >= s->count) {
    printf("vulkan-present: acquired image %u of %u\n", index, s->count);
    c->errors++;
    return -1;
  }
  if (!draw(s, index, frame)) {
    c->errors++;
    return -1;
  }
  VkPipelineStageFlags stage = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
  VkSubmitInfo submit = {.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .waitSemaphoreCount = 1, .pWaitSemaphores = &acquired,
                         .pWaitDstStageMask = &stage, .commandBufferCount = 1, .pCommandBuffers = &s->commands[index],
                         .signalSemaphoreCount = 1, .pSignalSemaphores = &rendered};
  vk.vkResetFences(device, 1, &in_flight);
  if (!succeeded(vk.vkQueueSubmit(queue, 1, &submit, in_flight), "vkQueueSubmit")) {
    c->errors++;
    return -1;
  }
  VkResult waited = vk.vkWaitForFences(device, 1, &in_flight, VK_TRUE, 10ull * 1000 * 1000 * 1000);
  if (waited != VK_SUCCESS) {
    printf("vulkan-present: vkWaitForFences returned %d\n", (int)waited);
    c->errors++;
    return -1;
  }
  VkResult result = VK_SUCCESS;
  VkPresentInfoKHR present = {.sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR, .waitSemaphoreCount = 1,
                              .pWaitSemaphores = &rendered, .swapchainCount = 1, .pSwapchains = &s->chain,
                              .pImageIndices = &index, .pResults = &result};
  r = vk.vkQueuePresentKHR(queue, &present);
  if (r == VK_SUCCESS) {
    c->presented++;
    return 1;
  }
  if (r == VK_SUBOPTIMAL_KHR) {
    // Shown, at the size it was drawn for: the window changed meanwhile.
    c->suboptimal++;
    c->presented++;
    return 1;
  }
  if (r == VK_ERROR_OUT_OF_DATE_KHR) {
    c->out_of_date++;
    return 0;
  }
  printf("vulkan-present: vkQueuePresentKHR returned %d\n", (int)r);
  c->errors++;
  return -1;
}

// MARK: Radharc's composed frame

/// The window's content rectangle in the screen, from Radharc's window list (`id x y width height focused title`).
static int window_rect(int *x, int *y, int *w, int *h) {
  int fd = open("/svc/windows/list", O_RDONLY);
  if (fd < 0) return 0;
  char text[4096];
  ssize_t n = read(fd, text, sizeof text - 1);
  close(fd);
  if (n <= 0) return 0;
  text[n] = 0;
  for (char *line = text; *line;) {
    char *eol = strchr(line, '\n');
    if (eol) *eol = 0;
    // id x y width height focus title
    char *p = line;
    long v[5];
    int ok = 1;
    for (int i = 0; i < 5 && ok; i++) {
      char *end;
      v[i] = strtol(p, &end, 10);
      if (end == p) ok = 0;
      p = end;
    }
    if (ok) {
      while (*p == ' ') p++;
      while (*p && *p != ' ') p++;  // the focus word
      while (*p == ' ') p++;
      if (strcmp(p, "vulkan-present") == 0) {
        *x = (int)v[1];
        *y = (int)v[2];
        *w = (int)v[3];
        *h = (int)v[4];
        return 1;
      }
    }
    if (!eol) break;
    line = eol + 1;
  }
  return 0;
}

/// Radharc's composed pixel at the screen's (x, y), as 0xRRGGBB, or -1.
static long composed_pixel(int x, int y) {
  char text[32];
  int n = snprintf(text, sizeof text, "%d %d", x, y);
  int fd = open("/svc/windows/pixel", O_WRONLY);
  if (fd < 0) return -1;
  ssize_t w = write(fd, text, (size_t)n);
  close(fd);
  if (w != n) return -1;
  fd = open("/svc/windows/pixel", O_RDONLY);
  if (fd < 0) return -1;
  char out[32];
  ssize_t got = read(fd, out, sizeof out - 1);
  close(fd);
  if (got <= 0) return -1;
  out[got] = 0;
  char *end;
  long v = strtol(out, &end, 16);
  return end == out ? -1 : v;
}

static void pause_ms(long ms) {
  struct timespec t = {ms / 1000, (ms % 1000) * 1000000};
  nanosleep(&t, NULL);
}

static int pixels_test(const Swap *s) {
  int x, y, w, h;
  uint8_t rgb[3];
  frame_color(frames - 1, rgb);
  long want_clear = (long)rgb[0] << 16 | (long)rgb[1] << 8 | rgb[2];
  long want_triangle = 0xffff00;
  // The last present is on the glass within a few vblanks.
  long got_clear = -1, got_triangle = -1;
  int px_clear = 0, py_clear = 0, px_tri = 0, py_tri = 0;
  for (int attempt = 0; attempt < 100; attempt++) {
    if (!window_rect(&x, &y, &w, &h)) {
      pause_ms(50);
      continue;
    }
    // A pixel at the image's corner, and one in the triangle's middle (its centroid, a third up from the base).
    px_clear = x + 8;
    py_clear = y + 8;
    px_tri = x + (int)s->extent.width / 2;
    py_tri = y + (int)((float)s->extent.height * 0.4167f);
    got_clear = composed_pixel(px_clear, py_clear);
    got_triangle = composed_pixel(px_tri, py_tri);
    if (got_clear == want_clear && got_triangle == want_triangle) break;
    pause_ms(50);
  }
  printf("vulkan-present: window at %d,%d %dx%d; Radharc composed %06lx at %d,%d (the clear colour %06lx) and %06lx at %d,%d (the "
         "triangle, %06lx)\n",
         x, y, w, h, got_clear, px_clear, py_clear, want_clear, got_triangle, px_tri, py_tri, want_triangle);
  check(got_clear == want_clear, "the composed pixel in the clear region is the last frame's clear colour, exactly");
  check(got_triangle == want_triangle, "the composed pixel inside the triangle is the triangle's colour, exactly");
  return got_clear == want_clear && got_triangle == want_triangle;
}

// MARK: Events

typedef struct {
  int resizes;
  int last_w, last_h;
  int keys;
  int closes;
} Seen;

static void poll_events(Seen *seen) {
  for (;;) {
    VkVectraWindowEventVECTRA events[16];
    uint32_t n = 16;
    VkResult r = vk.vkPollVectraWindowEventsVECTRA(instance, surface, &n, events);
    if (r != VK_SUCCESS && r != VK_INCOMPLETE) return;
    for (uint32_t i = 0; i < n; i++) {
      switch (events[i].type) {
        case VK_VECTRA_WINDOW_EVENT_RESIZE:
          seen->resizes++;
          seen->last_w = events[i].x;
          seen->last_h = events[i].y;
          break;
        case VK_VECTRA_WINDOW_EVENT_KEY_DOWN:
        case VK_VECTRA_WINDOW_EVENT_KEY_UP: seen->keys++; break;
        case VK_VECTRA_WINDOW_EVENT_CLOSE: seen->closes++; break;
        default: break;
      }
    }
    if (r == VK_SUCCESS) return;
  }
}

/// Asks for fullscreen (or back) at the next frame and presents frames until the swapchain says it is out of date, then makes
/// another. Returns 1 if the swapchain said so and the new one has the size the window now has.
static int resize_through(Swap *s, int on, int *frame, Counts *c, Seen *seen) {
  uint32_t was_w = s->extent.width, was_h = s->extent.height;
  if (!succeeded(vk.vkSetVectraWindowFullscreenVECTRA(instance, surface, on ? VK_TRUE : VK_FALSE), "vkSetVectraWindowFullscreenVECTRA"))
    return 0;
  int before = c->out_of_date;
  int tries = 0;
  while (c->out_of_date == before && tries < 600 && *frame < frames - 1) {
    int r = frame_once(s, *frame, c);
    if (r < 0) return 0;
    if (r > 0) (*frame)++;
    tries++;
  }
  poll_events(seen);
  if (c->out_of_date == before) {
    printf("vulkan-present: the swapchain never said it was out of date after %d frames\n", tries);
    return 0;
  }
  Swap next;
  if (!make_swap(&next, s)) return 0;
  *s = next;
  printf("vulkan-present: out of date after %d frames, made again at %ux%u (was %ux%u)\n", tries, s->extent.width,
         s->extent.height, was_w, was_h);
  return s->extent.width != was_w || s->extent.height != was_h;
}

// MARK: Main

int main(void) {
  PFN_vkCreateInstance create = (PFN_vkCreateInstance)vkGetInstanceProcAddr(NULL, "vkCreateInstance");
  if (!create) {
    printf("vulkan-present: FAILED: the loader has no vkCreateInstance\n");
    return 1;
  }
  // The extensions the layer offers, asked before anything is made.
  PFN_vkEnumerateInstanceExtensionProperties enumerate =
      (PFN_vkEnumerateInstanceExtensionProperties)vkGetInstanceProcAddr(NULL, "vkEnumerateInstanceExtensionProperties");
  uint32_t extension_count = 0;
  int has_surface = 0, has_window = 0;
  if (enumerate && enumerate(NULL, &extension_count, NULL) == VK_SUCCESS && extension_count > 0) {
    VkExtensionProperties *all = calloc(extension_count, sizeof *all);
    enumerate(NULL, &extension_count, all);
    for (uint32_t i = 0; i < extension_count; i++) {
      if (strcmp(all[i].extensionName, VK_KHR_SURFACE_EXTENSION_NAME) == 0) has_surface = 1;
      if (strcmp(all[i].extensionName, VK_VECTRA_WINDOW_SURFACE_EXTENSION_NAME) == 0) has_window = 1;
    }
    free(all);
  }
  check(has_surface && has_window, "the instance offers VK_KHR_surface and VK_VECTRA_window_surface");
  if (!has_surface || !has_window) return 1;

  const char *instance_extensions[2] = {VK_KHR_SURFACE_EXTENSION_NAME, VK_VECTRA_WINDOW_SURFACE_EXTENSION_NAME};
  VkApplicationInfo app = {.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .pApplicationName = "vulkan-present",
                           .apiVersion = (1u << 22) | (3u << 12)};
  VkInstanceCreateInfo info = {.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app,
                               .enabledExtensionCount = 2, .ppEnabledExtensionNames = instance_extensions};
  if (!succeeded(create(&info, NULL, &instance), "vkCreateInstance")) return 1;
  if (!load(instance)) return 1;

  uint32_t count = 1;
  VkPhysicalDevice devices[1];
  VkResult listed = vk.vkEnumeratePhysicalDevices(instance, &count, devices);
  if ((listed != VK_SUCCESS && listed != VK_INCOMPLETE) || count == 0) {
    check(0, "there is a physical device");
    return 1;
  }
  physical = devices[0];
  vk.vkGetPhysicalDeviceMemoryProperties(physical, &memory);
  uint32_t families = 0;
  vk.vkGetPhysicalDeviceQueueFamilyProperties(physical, &families, NULL);
  VkQueueFamilyProperties family_properties[16];
  if (families > 16) families = 16;
  vk.vkGetPhysicalDeviceQueueFamilyProperties(physical, &families, family_properties);
  int found = 0;
  for (uint32_t f = 0; f < families && !found; f++) {
    if (family_properties[f].queueFlags & VK_QUEUE_GRAPHICS_BIT) {
      family = f;
      found = 1;
    }
  }
  check(found, "a queue family for graphics");
  if (!found) return 1;

  // The window, as a surface.
  VkVectraWindowSurfaceCreateInfo surface_info = {.sType = VK_STRUCTURE_TYPE_VECTRA_WINDOW_SURFACE_CREATE_INFO,
                                                  .pTitle = "vulkan-present", .width = window_width, .height = window_height};
  if (!succeeded(vk.vkCreateVectraWindowSurface(instance, &surface_info, NULL, &surface), "vkCreateVectraWindowSurface")) return 1;
  VkBool32 supported = VK_FALSE;
  vk.vkGetPhysicalDeviceSurfaceSupportKHR(physical, family, surface, &supported);
  check(supported == VK_TRUE, "the queue family presents to the surface");
  VkSurfaceCapabilitiesKHR caps;
  if (!succeeded(vk.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(physical, surface, &caps), "vkGetPhysicalDeviceSurfaceCapabilitiesKHR"))
    return 1;
  printf("vulkan-present: the surface is %ux%u, %u to %u images\n", caps.currentExtent.width, caps.currentExtent.height,
         caps.minImageCount, caps.maxImageCount);
  check(caps.currentExtent.width == window_width && caps.currentExtent.height == window_height,
        "the surface's extent is the window's size");
  check(caps.minImageCount >= 2 && caps.maxImageCount <= 3, "two to three images");
  uint32_t format_count = 0;
  vk.vkGetPhysicalDeviceSurfaceFormatsKHR(physical, surface, &format_count, NULL);
  VkSurfaceFormatKHR formats[8];
  if (format_count > 8) format_count = 8;
  vk.vkGetPhysicalDeviceSurfaceFormatsKHR(physical, surface, &format_count, formats);
  int unorm = 0, srgb = 0;
  for (uint32_t i = 0; i < format_count; i++) {
    if (formats[i].format == VK_FORMAT_B8G8R8A8_UNORM) unorm = 1;
    if (formats[i].format == VK_FORMAT_B8G8R8A8_SRGB) srgb = 1;
  }
  check(unorm && srgb, "the surface offers B8G8R8A8 UNORM and SRGB");
  uint32_t mode_count = 0;
  vk.vkGetPhysicalDeviceSurfacePresentModesKHR(physical, surface, &mode_count, NULL);
  VkPresentModeKHR modes[4];
  if (mode_count > 4) mode_count = 4;
  vk.vkGetPhysicalDeviceSurfacePresentModesKHR(physical, surface, &mode_count, modes);
  check(mode_count == 1 && modes[0] == VK_PRESENT_MODE_FIFO_KHR, "FIFO is the surface's present mode");

  // The device, with the swapchain.
  uint32_t device_extension_count = 0;
  vk.vkEnumerateDeviceExtensionProperties(physical, NULL, &device_extension_count, NULL);
  VkExtensionProperties *device_extensions = calloc(device_extension_count + 1, sizeof *device_extensions);
  vk.vkEnumerateDeviceExtensionProperties(physical, NULL, &device_extension_count, device_extensions);
  int has_swapchain = 0;
  for (uint32_t i = 0; i < device_extension_count; i++) {
    if (strcmp(device_extensions[i].extensionName, VK_KHR_SWAPCHAIN_EXTENSION_NAME) == 0) has_swapchain = 1;
  }
  free(device_extensions);
  check(has_swapchain, "the device offers VK_KHR_swapchain");
  if (!has_swapchain) return 1;
  const char *device_extension = VK_KHR_SWAPCHAIN_EXTENSION_NAME;
  float priority = 1.0f;
  VkDeviceQueueCreateInfo queue_info = {.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueFamilyIndex = family,
                                        .queueCount = 1, .pQueuePriorities = &priority};
  VkDeviceCreateInfo device_info = {.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .queueCreateInfoCount = 1,
                                    .pQueueCreateInfos = &queue_info, .enabledExtensionCount = 1,
                                    .ppEnabledExtensionNames = &device_extension};
  if (!succeeded(vk.vkCreateDevice(physical, &device_info, NULL, &device), "vkCreateDevice")) return 1;
  vk.vkGetDeviceQueue(device, family, 0, &queue);
  VkCommandPoolCreateInfo pool_info = {.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
                                       .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT, .queueFamilyIndex = family};
  if (!succeeded(vk.vkCreateCommandPool(device, &pool_info, NULL, &pool), "vkCreateCommandPool")) return 1;

  // What every frame uses: a render pass, the triangle's shaders and vertices, and the semaphores.
  VkAttachmentDescription attachment = {.format = VK_FORMAT_B8G8R8A8_UNORM, .samples = VK_SAMPLE_COUNT_1_BIT,
                                        .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR, .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
                                        .stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE,
                                        .stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
                                        .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
                                        .finalLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR};
  VkAttachmentReference reference_color = {0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};
  VkSubpassDescription subpass = {.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS, .colorAttachmentCount = 1,
                                  .pColorAttachments = &reference_color};
  VkSubpassDependency dependency = {.srcSubpass = VK_SUBPASS_EXTERNAL, .dstSubpass = 0,
                                    .srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
                                    .dstStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
                                    .dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT};
  VkRenderPassCreateInfo pass_info = {.sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO, .attachmentCount = 1,
                                      .pAttachments = &attachment, .subpassCount = 1, .pSubpasses = &subpass,
                                      .dependencyCount = 1, .pDependencies = &dependency};
  if (!succeeded(vk.vkCreateRenderPass(device, &pass_info, NULL, &pass), "vkCreateRenderPass")) return 1;
  VkShaderModuleCreateInfo vs = {.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .codeSize = sizeof triangle_vert,
                                 .pCode = triangle_vert};
  VkShaderModuleCreateInfo fs = {.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .codeSize = sizeof triangle_frag,
                                 .pCode = triangle_frag};
  if (!succeeded(vk.vkCreateShaderModule(device, &vs, NULL, &vertex_shader), "vkCreateShaderModule (vertex)")) return 1;
  if (!succeeded(vk.vkCreateShaderModule(device, &fs, NULL, &fragment_shader), "vkCreateShaderModule (fragment)")) return 1;
  VkPipelineLayoutCreateInfo layout_info = {.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO};
  if (!succeeded(vk.vkCreatePipelineLayout(device, &layout_info, NULL, &layout), "vkCreatePipelineLayout")) return 1;
  VkBufferCreateInfo buffer_info = {.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = sizeof triangle,
                                    .usage = VK_BUFFER_USAGE_VERTEX_BUFFER_BIT, .sharingMode = VK_SHARING_MODE_EXCLUSIVE};
  if (!succeeded(vk.vkCreateBuffer(device, &buffer_info, NULL, &vertex_buffer), "vkCreateBuffer")) return 1;
  VkMemoryRequirements need;
  vk.vkGetBufferMemoryRequirements(device, vertex_buffer, &need);
  int type = memory_type(need.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
  if (type < 0) {
    check(0, "a host-visible, coherent memory type");
    return 1;
  }
  VkMemoryAllocateInfo alloc = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = need.size,
                                .memoryTypeIndex = (uint32_t)type};
  if (!succeeded(vk.vkAllocateMemory(device, &alloc, NULL, &vertex_memory), "vkAllocateMemory")) return 1;
  vk.vkBindBufferMemory(device, vertex_buffer, vertex_memory, 0);
  void *mapped = NULL;
  if (!succeeded(vk.vkMapMemory(device, vertex_memory, 0, sizeof triangle, 0, &mapped), "vkMapMemory")) return 1;
  memcpy(mapped, triangle, sizeof triangle);
  VkSemaphoreCreateInfo semaphore_info = {.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
  VkFenceCreateInfo fence_info = {.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
  if (!succeeded(vk.vkCreateSemaphore(device, &semaphore_info, NULL, &acquired), "vkCreateSemaphore")) return 1;
  if (!succeeded(vk.vkCreateSemaphore(device, &semaphore_info, NULL, &rendered), "vkCreateSemaphore")) return 1;
  if (!succeeded(vk.vkCreateFence(device, &fence_info, NULL, &in_flight), "vkCreateFence")) return 1;

  Swap swap;
  if (!make_swap(&swap, NULL)) return 1;

  // The frames: fullscreen a third in, and back two thirds in, each making the swapchain out of date.
  Counts counts = {0};
  Seen seen = {0};
  int frame = 0, resized_up = 0, resized_down = 0;
  int failed_frame = 0;
  while (frame < frames) {
    if (frame == frames / 3 && !resized_up) {
      resized_up = resize_through(&swap, 1, &frame, &counts, &seen) ? 1 : -1;
      if (resized_up < 0) break;
      continue;
    }
    if (frame == 2 * frames / 3 && !resized_down) {
      resized_down = resize_through(&swap, 0, &frame, &counts, &seen) ? 1 : -1;
      if (resized_down < 0) break;
      continue;
    }
    int r = frame_once(&swap, frame, &counts);
    if (r < 0) {
      failed_frame = 1;
      break;
    }
    if (r > 0) {
      frame++;
    } else {
      // Out of date by itself (the window changed under us): make it again.
      Swap next;
      if (!make_swap(&next, &swap)) {
        failed_frame = 1;
        break;
      }
      swap = next;
    }
    poll_events(&seen);
  }
  poll_events(&seen);
  printf("vulkan-present: %d frames presented, %d out of date, %d suboptimal, %d errors; %d resize events (last %dx%d)\n",
         counts.presented, counts.out_of_date, counts.suboptimal, counts.errors, seen.resizes, seen.last_w, seen.last_h);
  check(!failed_frame && counts.errors == 0, "every frame was acquired and presented without an error");
  check(frame == frames, "all 120 frames were drawn");
  check(counts.presented >= frames, "every frame was presented");
  if (!failed_frame && counts.errors == 0 && frame == frames && counts.presented >= frames) {
    printf("vulkan-present: ok: vulkan present frames\n");
  }
  if (resized_up == 1 && resized_down == 1 && counts.out_of_date >= 2) {
    printf("vulkan-present: ok: vulkan present resize\n");
  } else {
    check(0, "fullscreen and back each made the swapchain out of date and it was made again at the new size");
  }
  if (seen.resizes >= 2) {
    printf("vulkan-present: ok: vulkan present events\n");
  } else {
    check(0, "the window's resizes arrived as events");
  }
  if (!failed_frame && frame == frames && pixels_test(&swap)) printf("vulkan-present: ok: vulkan present pixels\n");

  vk.vkDeviceWaitIdle(device);
  destroy_swap_resources(&swap);
  vk.vkDestroySwapchainKHR(device, swap.chain, NULL);
  vk.vkDestroyFence(device, in_flight, NULL);
  vk.vkDestroySemaphore(device, acquired, NULL);
  vk.vkDestroySemaphore(device, rendered, NULL);
  vk.vkUnmapMemory(device, vertex_memory);
  vk.vkDestroyBuffer(device, vertex_buffer, NULL);
  vk.vkFreeMemory(device, vertex_memory, NULL);
  vk.vkDestroyPipelineLayout(device, layout, NULL);
  vk.vkDestroyShaderModule(device, vertex_shader, NULL);
  vk.vkDestroyShaderModule(device, fragment_shader, NULL);
  vk.vkDestroyRenderPass(device, pass, NULL);
  vk.vkDestroyCommandPool(device, pool, NULL);
  vk.vkDestroyDevice(device, NULL);
  vk.vkDestroySurfaceKHR(instance, surface, NULL);
  vk.vkDestroyInstance(instance, NULL);
  if (failures) {
    printf("vulkan-present: FAILED, %d checks\n", failures);
    return 1;
  }
  printf("vulkan-present: passed\n");
  return 0;
}
