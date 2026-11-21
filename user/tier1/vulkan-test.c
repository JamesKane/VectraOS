// SPDX-License-Identifier: BSD-3-Clause

// vulkan-test (vulkan-test(8), D174 step 5): a Vulkan program in C over our
// loader and whatever driver the program's registry gives it. C because
// that is Vulkan's interface: it checks the layer as a port would use it.
// It makes an instance, lists the physical devices, and on the first with a
// queue that does graphics and compute runs four tests:
//   - a compute shader over two storage buffers and a push constant, whose
//     output it reads back and compares word for word;
//   - a triangle from a vertex buffer, drawn in a render pass that clears
//     a 64 by 64 RGBA8 image, copied to a buffer and compared with a CPU
//     reference: exactly at every pixel whose centre is at least one pixel
//     from an edge, and ignored nearer;
//   - a depth test: two triangles over the whole image, the nearer drawn
//     first, which must be all that shows;
//   - multisampling: the triangle into a four-sample image that the pass
//     resolves, exact away from the edges, mixed on them.
// The last two are skipped, and say so, where the device has no depth
// attachment or no four-sample colour. It exits 0 only if each that ran
// passed, after printing `ok: vulkan compute`, `ok: vulkan triangle`,
// `ok: vulkan depth` and `ok: vulkan multisample`. Its shaders are user/tier1/vulkan-shaders' (vx
// shaders makes shaders.h).

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "td_vulkan.h"
#include "shaders.h"

// The loader's entry point (graphics/vulkan/loader); every other command is
// asked of it by name.
extern PFN_vkVoidFunction vkGetInstanceProcAddr(VkInstance instance, const char *name);

#define COMMANDS(X)                                                                                                     \
  X(vkCreateInstance) X(vkDestroyInstance) X(vkEnumeratePhysicalDevices) X(vkGetPhysicalDeviceProperties) X(vkGetPhysicalDeviceFormatProperties)              \
  X(vkGetPhysicalDeviceMemoryProperties) X(vkGetPhysicalDeviceQueueFamilyProperties) X(vkCreateDevice)                  \
  X(vkDestroyDevice) X(vkGetDeviceQueue) X(vkCreateBuffer) X(vkDestroyBuffer) X(vkGetBufferMemoryRequirements)         \
  X(vkAllocateMemory) X(vkFreeMemory) X(vkBindBufferMemory) X(vkMapMemory) X(vkUnmapMemory) X(vkCreateShaderModule)   \
  X(vkDestroyShaderModule) X(vkCreateDescriptorSetLayout) X(vkDestroyDescriptorSetLayout) X(vkCreatePipelineLayout)   \
  X(vkDestroyPipelineLayout) X(vkCreateComputePipelines) X(vkCreateGraphicsPipelines) X(vkDestroyPipeline)            \
  X(vkCreateDescriptorPool) X(vkDestroyDescriptorPool) X(vkAllocateDescriptorSets) X(vkUpdateDescriptorSets)           \
  X(vkCreateImage) X(vkDestroyImage) X(vkGetImageMemoryRequirements) X(vkBindImageMemory) X(vkCreateImageView)         \
  X(vkDestroyImageView) X(vkCreateRenderPass) X(vkDestroyRenderPass) X(vkCreateFramebuffer) X(vkDestroyFramebuffer)   \
  X(vkCreateCommandPool) X(vkDestroyCommandPool) X(vkAllocateCommandBuffers) X(vkBeginCommandBuffer)                   \
  X(vkEndCommandBuffer) X(vkCmdBindPipeline) X(vkCmdBindDescriptorSets) X(vkCmdPushConstants) X(vkCmdDispatch)        \
  X(vkCmdPipelineBarrier) X(vkCmdBeginRenderPass) X(vkCmdEndRenderPass) X(vkCmdBindVertexBuffers) X(vkCmdDraw)         \
  X(vkCmdCopyImageToBuffer) X(vkQueueSubmit) X(vkCreateFence) X(vkDestroyFence) X(vkWaitForFences)                     \
  X(vkDeviceWaitIdle)

static struct {
#define X(name) PFN_##name name;
  COMMANDS(X)
#undef X
} vk;

static int failures;

static void check(int ok, const char *what) {
  if (!ok) {
    printf("vulkan-test: FAILED: %s\n", what);
    failures++;
  }
}

/// Whether `r` is VK_SUCCESS; says what failed if not.
static int succeeded(VkResult r, const char *call) {
  if (r == VK_SUCCESS) return 1;
  printf("vulkan-test: FAILED: %s returned %d\n", call, (int)r);
  failures++;
  return 0;
}

static int load(VkInstance instance) {
  int missing = 0;
#define X(name)                                                                                                         \
  vk.name = (PFN_##name)vkGetInstanceProcAddr(instance, #name);                                                         \
  if (!vk.name) {                                                                                                       \
    printf("vulkan-test: FAILED: the loader has no %s\n", #name);                                                       \
    missing++;                                                                                                          \
  }
  COMMANDS(X)
#undef X
  return missing == 0;
}

static VkPhysicalDevice physical;
static VkDevice device;
static VkQueue queue;
static uint32_t family;
static VkPhysicalDeviceMemoryProperties memory;
static VkCommandPool pool;

static int memory_type(uint32_t allowed, VkMemoryPropertyFlags want) {
  for (uint32_t i = 0; i < memory.memoryTypeCount; i++) {
    if ((allowed & (1u << i)) && (memory.memoryTypes[i].propertyFlags & want) == want) return (int)i;
  }
  return -1;
}

typedef struct {
  VkBuffer buffer;
  VkDeviceMemory memory;
  void *mapped;
  VkDeviceSize size;
} Buffer;

/// A buffer of `size` bytes in host-visible, coherent memory, mapped.
static int make_buffer(Buffer *b, VkDeviceSize size, VkBufferUsageFlags usage) {
  memset(b, 0, sizeof *b);
  b->size = size;
  VkBufferCreateInfo info = {.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = size, .usage = usage,
                             .sharingMode = VK_SHARING_MODE_EXCLUSIVE};
  if (!succeeded(vk.vkCreateBuffer(device, &info, NULL, &b->buffer), "vkCreateBuffer")) return 0;
  VkMemoryRequirements need;
  vk.vkGetBufferMemoryRequirements(device, b->buffer, &need);
  int type = memory_type(need.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
  if (type < 0) {
    check(0, "a host-visible, coherent memory type");
    return 0;
  }
  VkMemoryAllocateInfo alloc = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = need.size,
                                .memoryTypeIndex = (uint32_t)type};
  if (!succeeded(vk.vkAllocateMemory(device, &alloc, NULL, &b->memory), "vkAllocateMemory")) return 0;
  if (!succeeded(vk.vkBindBufferMemory(device, b->buffer, b->memory, 0), "vkBindBufferMemory")) return 0;
  return succeeded(vk.vkMapMemory(device, b->memory, 0, size, 0, &b->mapped), "vkMapMemory");
}

static void free_buffer(Buffer *b) {
  if (b->mapped) vk.vkUnmapMemory(device, b->memory);
  if (b->buffer) vk.vkDestroyBuffer(device, b->buffer, NULL);
  if (b->memory) vk.vkFreeMemory(device, b->memory, NULL);
}

/// Submits `cmd` and waits for it.
static int run(VkCommandBuffer cmd, const char *what) {
  VkFenceCreateInfo fence_info = {.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
  VkFence fence;
  if (!succeeded(vk.vkCreateFence(device, &fence_info, NULL, &fence), "vkCreateFence")) return 0;
  VkSubmitInfo submit = {.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cmd};
  int ok = succeeded(vk.vkQueueSubmit(queue, 1, &submit, fence), "vkQueueSubmit");
  if (ok) {
    VkResult r = vk.vkWaitForFences(device, 1, &fence, VK_TRUE, 10ull * 1000 * 1000 * 1000);
    if (r != VK_SUCCESS) printf("vulkan-test: %s: vkWaitForFences returned %d\n", what, (int)r);
    ok = succeeded(r, "vkWaitForFences");
  }
  vk.vkDestroyFence(device, fence, NULL);
  return ok;
}

static VkCommandBuffer begin_commands(void) {
  VkCommandBufferAllocateInfo info = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = pool,
                                      .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1};
  VkCommandBuffer cmd = NULL;
  if (!succeeded(vk.vkAllocateCommandBuffers(device, &info, &cmd), "vkAllocateCommandBuffers")) return NULL;
  VkCommandBufferBeginInfo begin = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
                                    .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT};
  if (!succeeded(vk.vkBeginCommandBuffer(cmd, &begin), "vkBeginCommandBuffer")) return NULL;
  return cmd;
}

static VkShaderModule make_shader(const uint32_t *words, size_t bytes, const char *what) {
  VkShaderModuleCreateInfo info = {.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .codeSize = bytes,
                                   .pCode = words};
  VkShaderModule module = NULL;
  if (!succeeded(vk.vkCreateShaderModule(device, &info, NULL, &module), what)) return NULL;
  return module;
}

// MARK: Compute

static void compute_test(void) {
  enum { count = 1000 };
  struct {
    uint32_t scale, offset, count;
  } constants = {3, 0x1234, count};
  Buffer source = {0}, target = {0};
  VkShaderModule shader = NULL;
  VkDescriptorSetLayout set_layout = NULL;
  VkPipelineLayout layout = NULL;
  VkPipeline pipeline = NULL;
  VkDescriptorPool descriptors = NULL;
  int ok = 0;

  if (!make_buffer(&source, count * 4, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT)) goto done;
  if (!make_buffer(&target, count * 4, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT)) goto done;
  uint32_t *in = source.mapped, *out = target.mapped;
  for (uint32_t i = 0; i < count; i++) {
    in[i] = i * 7 + 3;
    out[i] = 0xdeadbeef;
  }

  shader = make_shader(compute_comp, sizeof compute_comp, "vkCreateShaderModule (compute)");
  if (!shader) goto done;
  VkDescriptorSetLayoutBinding bindings[2];
  for (uint32_t i = 0; i < 2; i++) {
    bindings[i] = (VkDescriptorSetLayoutBinding){.binding = i, .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                                                 .descriptorCount = 1, .stageFlags = VK_SHADER_STAGE_COMPUTE_BIT};
  }
  VkDescriptorSetLayoutCreateInfo set_info = {.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
                                              .bindingCount = 2, .pBindings = bindings};
  if (!succeeded(vk.vkCreateDescriptorSetLayout(device, &set_info, NULL, &set_layout), "vkCreateDescriptorSetLayout")) goto done;
  VkPushConstantRange range = {.stageFlags = VK_SHADER_STAGE_COMPUTE_BIT, .offset = 0, .size = sizeof constants};
  VkPipelineLayoutCreateInfo layout_info = {.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, .setLayoutCount = 1,
                                            .pSetLayouts = &set_layout, .pushConstantRangeCount = 1,
                                            .pPushConstantRanges = &range};
  if (!succeeded(vk.vkCreatePipelineLayout(device, &layout_info, NULL, &layout), "vkCreatePipelineLayout")) goto done;
  VkComputePipelineCreateInfo pipeline_info = {
      .sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
      .stage = {.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_COMPUTE_BIT,
                .module = shader, .pName = "main"},
      .layout = layout};
  if (!succeeded(vk.vkCreateComputePipelines(device, NULL, 1, &pipeline_info, NULL, &pipeline), "vkCreateComputePipelines")) goto done;

  VkDescriptorPoolSize size = {.type = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 2};
  VkDescriptorPoolCreateInfo pool_info = {.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, .maxSets = 1,
                                          .poolSizeCount = 1, .pPoolSizes = &size};
  if (!succeeded(vk.vkCreateDescriptorPool(device, &pool_info, NULL, &descriptors), "vkCreateDescriptorPool")) goto done;
  VkDescriptorSet set;
  VkDescriptorSetAllocateInfo set_alloc = {.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
                                           .descriptorPool = descriptors, .descriptorSetCount = 1,
                                           .pSetLayouts = &set_layout};
  if (!succeeded(vk.vkAllocateDescriptorSets(device, &set_alloc, &set), "vkAllocateDescriptorSets")) goto done;
  VkDescriptorBufferInfo buffer_infos[2] = {{source.buffer, 0, VK_WHOLE_SIZE}, {target.buffer, 0, VK_WHOLE_SIZE}};
  VkWriteDescriptorSet writes[2];
  for (uint32_t i = 0; i < 2; i++) {
    writes[i] = (VkWriteDescriptorSet){.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = set, .dstBinding = i,
                                       .descriptorCount = 1, .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                                       .pBufferInfo = &buffer_infos[i]};
  }
  vk.vkUpdateDescriptorSets(device, 2, writes, 0, NULL);

  VkCommandBuffer cmd = begin_commands();
  if (!cmd) goto done;
  vk.vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, pipeline);
  vk.vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, layout, 0, 1, &set, 0, NULL);
  vk.vkCmdPushConstants(cmd, layout, VK_SHADER_STAGE_COMPUTE_BIT, 0, sizeof constants, &constants);
  vk.vkCmdDispatch(cmd, (count + 63) / 64, 1, 1);
  VkMemoryBarrier barrier = {.sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER, .srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT,
                             .dstAccessMask = VK_ACCESS_HOST_READ_BIT};
  vk.vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &barrier, 0, NULL,
                          0, NULL);
  if (!succeeded(vk.vkEndCommandBuffer(cmd), "vkEndCommandBuffer")) goto done;
  if (!run(cmd, "compute")) goto done;

  int wrong = 0;
  for (uint32_t i = 0; i < count; i++) {
    uint32_t want = in[i] * constants.scale + constants.offset + i;
    if (out[i] != want) {
      if (wrong < 4) printf("vulkan-test: compute: word %u is %08x, not %08x\n", i, out[i], want);
      wrong++;
    }
  }
  check(wrong == 0, "the compute shader's output matches the reference word for word");
  ok = wrong == 0;
done:
  if (pipeline) vk.vkDestroyPipeline(device, pipeline, NULL);
  if (descriptors) vk.vkDestroyDescriptorPool(device, descriptors, NULL);
  if (layout) vk.vkDestroyPipelineLayout(device, layout, NULL);
  if (set_layout) vk.vkDestroyDescriptorSetLayout(device, set_layout, NULL);
  if (shader) vk.vkDestroyShaderModule(device, shader, NULL);
  free_buffer(&source);
  free_buffer(&target);
  if (ok) printf("vulkan-test: ok: vulkan compute\n");
}

// MARK: Triangle

enum { size = 64 };

typedef struct {
  float x, y, r, g, b, a;
} Vertex;

static const Vertex triangle[3] = {
    {-0.8f, -0.8f, 1, 1, 0, 1},
    {0.8f, -0.6f, 1, 1, 0, 1},
    {-0.2f, 0.8f, 1, 1, 0, 1},
};
static const uint8_t clear_pixel[4] = {0, 0, 255, 255};
static const uint8_t triangle_pixel[4] = {255, 255, 0, 255};

static float edge(float ax, float ay, float bx, float by, float px, float py) {
  return (bx - ax) * (py - ay) - (by - ay) * (px - ax);
}

/// The distance from (px, py) to the segment a to b.
static float segment_distance(float ax, float ay, float bx, float by, float px, float py) {
  float dx = bx - ax, dy = by - ay;
  float t = ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy);
  t = t < 0 ? 0 : t > 1 ? 1 : t;
  float cx = ax + t * dx - px, cy = ay + t * dy - py;
  return sqrtf(cx * cx + cy * cy);
}

/// Whether the pixel (x, y)'s centre is inside the triangle, and whether it is at least one pixel from every edge.
static int reference(int x, int y, int *judged) {
  float v[3][2];
  for (int i = 0; i < 3; i++) {
    v[i][0] = (triangle[i].x + 1) * 0.5f * size;
    v[i][1] = (triangle[i].y + 1) * 0.5f * size;
  }
  float px = x + 0.5f, py = y + 0.5f;
  float area = edge(v[0][0], v[0][1], v[1][0], v[1][1], v[2][0], v[2][1]);
  float sign = area < 0 ? -1.0f : 1.0f;
  int inside = 1;
  float nearest = 1e9f;
  for (int i = 0; i < 3; i++) {
    int j = (i + 1) % 3;
    float e = sign * edge(v[i][0], v[i][1], v[j][0], v[j][1], px, py);
    if (e < 0) inside = 0;
    float d = segment_distance(v[i][0], v[i][1], v[j][0], v[j][1], px, py);
    if (d < nearest) nearest = d;
  }
  *judged = nearest >= 1.0f;
  return inside;
}

static void triangle_test(void) {
  Buffer vertices = {0}, readback = {0};
  VkImage image = NULL;
  VkDeviceMemory image_memory = NULL;
  VkImageView view = NULL;
  VkRenderPass pass = NULL;
  VkFramebuffer framebuffer = NULL;
  VkShaderModule vertex_shader = NULL, fragment_shader = NULL;
  VkPipelineLayout layout = NULL;
  VkPipeline pipeline = NULL;
  int ok = 0;

  if (!make_buffer(&vertices, sizeof triangle, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT)) goto done;
  memcpy(vertices.mapped, triangle, sizeof triangle);
  if (!make_buffer(&readback, size * size * 4, VK_BUFFER_USAGE_TRANSFER_DST_BIT)) goto done;
  memset(readback.mapped, 0x5a, size * size * 4);

  VkImageCreateInfo image_info = {.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D,
                                  .format = VK_FORMAT_R8G8B8A8_UNORM, .extent = {size, size, 1}, .mipLevels = 1,
                                  .arrayLayers = 1, .samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_OPTIMAL,
                                  .usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
                                  .sharingMode = VK_SHARING_MODE_EXCLUSIVE, .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED};
  if (!succeeded(vk.vkCreateImage(device, &image_info, NULL, &image), "vkCreateImage")) goto done;
  VkMemoryRequirements need;
  vk.vkGetImageMemoryRequirements(device, image, &need);
  int type = memory_type(need.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
  if (type < 0) type = memory_type(need.memoryTypeBits, 0);
  if (type < 0) {
    check(0, "a memory type for the image");
    goto done;
  }
  VkMemoryAllocateInfo alloc = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = need.size,
                                .memoryTypeIndex = (uint32_t)type};
  if (!succeeded(vk.vkAllocateMemory(device, &alloc, NULL, &image_memory), "vkAllocateMemory (image)")) goto done;
  if (!succeeded(vk.vkBindImageMemory(device, image, image_memory, 0), "vkBindImageMemory")) goto done;
  VkImageViewCreateInfo view_info = {.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = image,
                                     .viewType = VK_IMAGE_VIEW_TYPE_2D, .format = VK_FORMAT_R8G8B8A8_UNORM,
                                     .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1}};
  if (!succeeded(vk.vkCreateImageView(device, &view_info, NULL, &view), "vkCreateImageView")) goto done;

  VkAttachmentDescription attachment = {.format = VK_FORMAT_R8G8B8A8_UNORM, .samples = VK_SAMPLE_COUNT_1_BIT,
                                        .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR, .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
                                        .stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE,
                                        .stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
                                        .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
                                        .finalLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL};
  VkAttachmentReference reference_color = {0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};
  VkSubpassDescription subpass = {.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS, .colorAttachmentCount = 1,
                                  .pColorAttachments = &reference_color};
  VkSubpassDependency dependencies[2] = {
      {.srcSubpass = VK_SUBPASS_EXTERNAL, .dstSubpass = 0, .srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
       .dstStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
       .dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT},
      {.srcSubpass = 0, .dstSubpass = VK_SUBPASS_EXTERNAL, .srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
       .dstStageMask = VK_PIPELINE_STAGE_TRANSFER_BIT, .srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
       .dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT},
  };
  VkRenderPassCreateInfo pass_info = {.sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO, .attachmentCount = 1,
                                      .pAttachments = &attachment, .subpassCount = 1, .pSubpasses = &subpass,
                                      .dependencyCount = 2, .pDependencies = dependencies};
  if (!succeeded(vk.vkCreateRenderPass(device, &pass_info, NULL, &pass), "vkCreateRenderPass")) goto done;
  VkFramebufferCreateInfo framebuffer_info = {.sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO, .renderPass = pass,
                                              .attachmentCount = 1, .pAttachments = &view, .width = size,
                                              .height = size, .layers = 1};
  if (!succeeded(vk.vkCreateFramebuffer(device, &framebuffer_info, NULL, &framebuffer), "vkCreateFramebuffer")) goto done;

  vertex_shader = make_shader(triangle_vert, sizeof triangle_vert, "vkCreateShaderModule (vertex)");
  fragment_shader = make_shader(triangle_frag, sizeof triangle_frag, "vkCreateShaderModule (fragment)");
  if (!vertex_shader || !fragment_shader) goto done;
  VkPipelineLayoutCreateInfo layout_info = {.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO};
  if (!succeeded(vk.vkCreatePipelineLayout(device, &layout_info, NULL, &layout), "vkCreatePipelineLayout")) goto done;

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
  VkViewport viewport = {0, 0, size, size, 0, 1};
  VkRect2D scissor = {{0, 0}, {size, size}};
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
  VkGraphicsPipelineCreateInfo pipeline_info = {.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO, .stageCount = 2,
                                                .pStages = stages, .pVertexInputState = &vertex_input,
                                                .pInputAssemblyState = &assembly, .pViewportState = &viewport_state,
                                                .pRasterizationState = &raster, .pMultisampleState = &multisample,
                                                .pColorBlendState = &blend, .layout = layout, .renderPass = pass,
                                                .subpass = 0};
  if (!succeeded(vk.vkCreateGraphicsPipelines(device, NULL, 1, &pipeline_info, NULL, &pipeline), "vkCreateGraphicsPipelines")) goto done;

  VkCommandBuffer cmd = begin_commands();
  if (!cmd) goto done;
  VkClearValue clear = {.color = {.float32 = {0, 0, 1, 1}}};
  VkRenderPassBeginInfo begin = {.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO, .renderPass = pass,
                                 .framebuffer = framebuffer, .renderArea = {{0, 0}, {size, size}},
                                 .clearValueCount = 1, .pClearValues = &clear};
  vk.vkCmdBeginRenderPass(cmd, &begin, VK_SUBPASS_CONTENTS_INLINE);
  vk.vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
  VkDeviceSize offset = 0;
  vk.vkCmdBindVertexBuffers(cmd, 0, 1, &vertices.buffer, &offset);
  vk.vkCmdDraw(cmd, 3, 1, 0, 0);
  vk.vkCmdEndRenderPass(cmd);
  VkBufferImageCopy copy = {.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, .imageExtent = {size, size, 1}};
  vk.vkCmdCopyImageToBuffer(cmd, image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, readback.buffer, 1, &copy);
  VkMemoryBarrier barrier = {.sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER, .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
                             .dstAccessMask = VK_ACCESS_HOST_READ_BIT};
  vk.vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &barrier, 0, NULL, 0,
                          NULL);
  if (!succeeded(vk.vkEndCommandBuffer(cmd), "vkEndCommandBuffer")) goto done;
  if (!run(cmd, "triangle")) goto done;

  const uint8_t *pixels = readback.mapped;
  int inside = 0, outside = 0, ignored = 0, wrong = 0;
  for (int y = 0; y < size; y++) {
    for (int x = 0; x < size; x++) {
      int judged;
      int in = reference(x, y, &judged);
      if (!judged) {
        ignored++;
        continue;
      }
      in ? inside++ : outside++;
      const uint8_t *want = in ? triangle_pixel : clear_pixel;
      const uint8_t *got = pixels + (y * size + x) * 4;
      if (memcmp(got, want, 4) != 0) {
        if (wrong < 6) {
          printf("vulkan-test: triangle: pixel %d, %d is %02x%02x%02x%02x, not %02x%02x%02x%02x\n", x, y, got[0], got[1],
                 got[2], got[3], want[0], want[1], want[2], want[3]);
        }
        wrong++;
      }
    }
  }
  printf("vulkan-test: triangle: %d pixels inside, %d outside, %d near an edge and not judged, %d wrong\n", inside,
         outside, ignored, wrong);
  check(inside >= 300 && outside >= 300, "the reference judges pixels both inside and outside the triangle");
  check(wrong == 0, "the triangle's pixels match the reference away from its edges");
  ok = wrong == 0 && inside >= 300 && outside >= 300;
done:
  if (pipeline) vk.vkDestroyPipeline(device, pipeline, NULL);
  if (layout) vk.vkDestroyPipelineLayout(device, layout, NULL);
  if (vertex_shader) vk.vkDestroyShaderModule(device, vertex_shader, NULL);
  if (fragment_shader) vk.vkDestroyShaderModule(device, fragment_shader, NULL);
  if (framebuffer) vk.vkDestroyFramebuffer(device, framebuffer, NULL);
  if (pass) vk.vkDestroyRenderPass(device, pass, NULL);
  if (view) vk.vkDestroyImageView(device, view, NULL);
  if (image) vk.vkDestroyImage(device, image, NULL);
  if (image_memory) vk.vkFreeMemory(device, image_memory, NULL);
  free_buffer(&vertices);
  free_buffer(&readback);
  if (ok) printf("vulkan-test: ok: vulkan triangle\n");
}

// MARK: Depth and multisampling
//
// Two more draws through the layer, on devices that have the feature: where the physical device says it has no depth
// attachment or no four-sample colour, the case is skipped and said so.

typedef struct {
  VkImage image;
  VkDeviceMemory memory;
  VkImageView view;
} Image;

static int make_image(Image *i, VkFormat format, VkSampleCountFlagBits samples, VkImageUsageFlags usage,
                      VkImageAspectFlags aspect) {
  memset(i, 0, sizeof *i);
  VkImageCreateInfo info = {.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D, .format = format,
                            .extent = {size, size, 1}, .mipLevels = 1, .arrayLayers = 1, .samples = samples,
                            .tiling = VK_IMAGE_TILING_OPTIMAL, .usage = usage,
                            .sharingMode = VK_SHARING_MODE_EXCLUSIVE, .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED};
  if (!succeeded(vk.vkCreateImage(device, &info, NULL, &i->image), "vkCreateImage")) return 0;
  VkMemoryRequirements need;
  vk.vkGetImageMemoryRequirements(device, i->image, &need);
  int type = memory_type(need.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
  if (type < 0) type = memory_type(need.memoryTypeBits, 0);
  if (type < 0) {
    check(0, "a memory type for the image");
    return 0;
  }
  VkMemoryAllocateInfo alloc = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = need.size,
                                .memoryTypeIndex = (uint32_t)type};
  if (!succeeded(vk.vkAllocateMemory(device, &alloc, NULL, &i->memory), "vkAllocateMemory (image)")) return 0;
  if (!succeeded(vk.vkBindImageMemory(device, i->image, i->memory, 0), "vkBindImageMemory")) return 0;
  VkImageViewCreateInfo view_info = {.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = i->image,
                                     .viewType = VK_IMAGE_VIEW_TYPE_2D, .format = format,
                                     .subresourceRange = {aspect, 0, 1, 0, 1}};
  return succeeded(vk.vkCreateImageView(device, &view_info, NULL, &i->view), "vkCreateImageView");
}

static void free_image(Image *i) {
  if (i->view) vk.vkDestroyImageView(device, i->view, NULL);
  if (i->image) vk.vkDestroyImage(device, i->image, NULL);
  if (i->memory) vk.vkFreeMemory(device, i->memory, NULL);
  memset(i, 0, sizeof *i);
}

/// A graphics pipeline over a vertex shader of `stride`-byte vertices (a position of `position` format, then a colour), the
/// triangle's fragment shader, `samples` samples and, where `depth`, a depth test (less) and write.
static VkPipeline make_pipeline(VkRenderPass pass, VkPipelineLayout layout, const uint32_t *words, size_t bytes,
                                uint32_t stride, VkFormat position, uint32_t color_offset, VkSampleCountFlagBits samples,
                                int depth) {
  VkShaderModule vs = make_shader(words, bytes, "vkCreateShaderModule (vertex)");
  VkShaderModule fs = make_shader(triangle_frag, sizeof triangle_frag, "vkCreateShaderModule (fragment)");
  VkPipeline pipeline = NULL;
  if (vs && fs) {
    VkPipelineShaderStageCreateInfo stages[2] = {
        {.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_VERTEX_BIT, .module = vs,
         .pName = "main"},
        {.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_FRAGMENT_BIT, .module = fs,
         .pName = "main"},
    };
    VkVertexInputBindingDescription binding = {0, stride, VK_VERTEX_INPUT_RATE_VERTEX};
    VkVertexInputAttributeDescription attributes[2] = {{0, 0, position, 0},
                                                       {1, 0, VK_FORMAT_R32G32B32A32_SFLOAT, color_offset}};
    VkPipelineVertexInputStateCreateInfo vertex_input = {.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
                                                         .vertexBindingDescriptionCount = 1,
                                                         .pVertexBindingDescriptions = &binding,
                                                         .vertexAttributeDescriptionCount = 2,
                                                         .pVertexAttributeDescriptions = attributes};
    VkPipelineInputAssemblyStateCreateInfo assembly = {.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
                                                       .topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST};
    VkViewport viewport = {0, 0, size, size, 0, 1};
    VkRect2D scissor = {{0, 0}, {size, size}};
    VkPipelineViewportStateCreateInfo viewport_state = {.sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
                                                        .viewportCount = 1, .pViewports = &viewport, .scissorCount = 1,
                                                        .pScissors = &scissor};
    VkPipelineRasterizationStateCreateInfo raster = {.sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
                                                     .polygonMode = VK_POLYGON_MODE_FILL, .cullMode = VK_CULL_MODE_NONE,
                                                     .frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE, .lineWidth = 1.0f};
    VkPipelineMultisampleStateCreateInfo multisample = {.sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
                                                        .rasterizationSamples = samples};
    VkPipelineDepthStencilStateCreateInfo depth_state = {.sType = VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
                                                         .depthTestEnable = depth, .depthWriteEnable = depth,
                                                         .depthCompareOp = VK_COMPARE_OP_LESS};
    VkPipelineColorBlendAttachmentState blend_attachment = {
        .colorWriteMask = VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT | VK_COLOR_COMPONENT_B_BIT |
                          VK_COLOR_COMPONENT_A_BIT};
    VkPipelineColorBlendStateCreateInfo blend = {.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
                                                 .attachmentCount = 1, .pAttachments = &blend_attachment};
    VkGraphicsPipelineCreateInfo info = {.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO, .stageCount = 2,
                                         .pStages = stages, .pVertexInputState = &vertex_input,
                                         .pInputAssemblyState = &assembly, .pViewportState = &viewport_state,
                                         .pRasterizationState = &raster, .pMultisampleState = &multisample,
                                         .pDepthStencilState = &depth_state, .pColorBlendState = &blend, .layout = layout,
                                         .renderPass = pass, .subpass = 0};
    if (!succeeded(vk.vkCreateGraphicsPipelines(device, NULL, 1, &info, NULL, &pipeline), "vkCreateGraphicsPipelines")) {
      pipeline = NULL;
    }
  }
  if (vs) vk.vkDestroyShaderModule(device, vs, NULL);
  if (fs) vk.vkDestroyShaderModule(device, fs, NULL);
  return pipeline;
}

static VkFormatFeatureFlags format_features(VkFormat format) {
  VkFormatProperties p;
  vk.vkGetPhysicalDeviceFormatProperties(physical, format, &p);
  return p.optimalTilingFeatures;
}

/// The copy of a colour image into `readback` and the barrier that makes it the host's.
static void read_back(VkCommandBuffer cmd, VkImage image, VkBuffer readback) {
  VkBufferImageCopy copy = {.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, .imageExtent = {size, size, 1}};
  vk.vkCmdCopyImageToBuffer(cmd, image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, readback, 1, &copy);
  VkMemoryBarrier barrier = {.sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER, .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
                             .dstAccessMask = VK_ACCESS_HOST_READ_BIT};
  vk.vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &barrier, 0, NULL, 0, NULL);
}

typedef struct {
  float x, y, z, r, g, b, a;
} DepthVertex;

/// Two triangles that each cover the whole image, the nearer drawn first: with a depth test the farther one, drawn after,
/// must not show; without one it would. Every pixel is judged.
static void depth_test(void) {
  Buffer vertices = {0}, readback = {0};
  Image color = {0}, depth = {0};
  VkRenderPass pass = NULL;
  VkFramebuffer framebuffer = NULL;
  VkPipelineLayout layout = NULL;
  VkPipeline pipeline = NULL;
  int ok = 0;
  if (!(format_features(VK_FORMAT_D32_SFLOAT) & VK_FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT)) {
    printf("vulkan-test: skipped: vulkan depth (the device has no depth attachment)\n");
    return;
  }
  static const DepthVertex quads[6] = {
      {-1, -1, 0.3f, 1, 0, 0, 1}, {3, -1, 0.3f, 1, 0, 0, 1}, {-1, 3, 0.3f, 1, 0, 0, 1},
      {-1, -1, 0.7f, 0, 1, 0, 1}, {3, -1, 0.7f, 0, 1, 0, 1}, {-1, 3, 0.7f, 0, 1, 0, 1},
  };
  if (!make_buffer(&vertices, sizeof quads, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT)) goto done;
  memcpy(vertices.mapped, quads, sizeof quads);
  if (!make_buffer(&readback, size * size * 4, VK_BUFFER_USAGE_TRANSFER_DST_BIT)) goto done;
  memset(readback.mapped, 0x5a, size * size * 4);
  if (!make_image(&color, VK_FORMAT_R8G8B8A8_UNORM, VK_SAMPLE_COUNT_1_BIT,
                  VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT, VK_IMAGE_ASPECT_COLOR_BIT)) goto done;
  if (!make_image(&depth, VK_FORMAT_D32_SFLOAT, VK_SAMPLE_COUNT_1_BIT, VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT,
                  VK_IMAGE_ASPECT_DEPTH_BIT)) goto done;

  VkAttachmentDescription attachments[2] = {
      {.format = VK_FORMAT_R8G8B8A8_UNORM, .samples = VK_SAMPLE_COUNT_1_BIT, .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
       .storeOp = VK_ATTACHMENT_STORE_OP_STORE, .stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE,
       .stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE, .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
       .finalLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL},
      {.format = VK_FORMAT_D32_SFLOAT, .samples = VK_SAMPLE_COUNT_1_BIT, .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
       .storeOp = VK_ATTACHMENT_STORE_OP_DONT_CARE, .stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE,
       .stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE, .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
       .finalLayout = VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL},
  };
  VkAttachmentReference color_reference = {0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};
  VkAttachmentReference depth_reference = {1, VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL};
  VkSubpassDescription subpass = {.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS, .colorAttachmentCount = 1,
                                  .pColorAttachments = &color_reference, .pDepthStencilAttachment = &depth_reference};
  VkRenderPassCreateInfo pass_info = {.sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO, .attachmentCount = 2,
                                      .pAttachments = attachments, .subpassCount = 1, .pSubpasses = &subpass};
  if (!succeeded(vk.vkCreateRenderPass(device, &pass_info, NULL, &pass), "vkCreateRenderPass (depth)")) goto done;
  VkImageView views[2] = {color.view, depth.view};
  VkFramebufferCreateInfo framebuffer_info = {.sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO, .renderPass = pass,
                                              .attachmentCount = 2, .pAttachments = views, .width = size, .height = size,
                                              .layers = 1};
  if (!succeeded(vk.vkCreateFramebuffer(device, &framebuffer_info, NULL, &framebuffer), "vkCreateFramebuffer (depth)")) goto done;
  VkPipelineLayoutCreateInfo layout_info = {.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO};
  if (!succeeded(vk.vkCreatePipelineLayout(device, &layout_info, NULL, &layout), "vkCreatePipelineLayout")) goto done;
  pipeline = make_pipeline(pass, layout, depth_vert, sizeof depth_vert, sizeof(DepthVertex), VK_FORMAT_R32G32B32_SFLOAT, 12,
                           VK_SAMPLE_COUNT_1_BIT, 1);
  if (!pipeline) goto done;

  VkCommandBuffer cmd = begin_commands();
  if (!cmd) goto done;
  VkClearValue clears[2] = {{.color = {.float32 = {0, 0, 1, 1}}}, {.depthStencil = {1.0f, 0}}};
  VkRenderPassBeginInfo begin = {.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO, .renderPass = pass,
                                 .framebuffer = framebuffer, .renderArea = {{0, 0}, {size, size}}, .clearValueCount = 2,
                                 .pClearValues = clears};
  vk.vkCmdBeginRenderPass(cmd, &begin, VK_SUBPASS_CONTENTS_INLINE);
  vk.vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
  VkDeviceSize offset = 0;
  vk.vkCmdBindVertexBuffers(cmd, 0, 1, &vertices.buffer, &offset);
  vk.vkCmdDraw(cmd, 3, 1, 0, 0);
  vk.vkCmdDraw(cmd, 3, 1, 3, 0);
  vk.vkCmdEndRenderPass(cmd);
  read_back(cmd, color.image, readback.buffer);
  if (!succeeded(vk.vkEndCommandBuffer(cmd), "vkEndCommandBuffer")) goto done;
  if (!run(cmd, "depth")) goto done;

  const uint8_t *pixels = readback.mapped;
  int near_pixels = 0, wrong = 0;
  for (int i = 0; i < size * size; i++) {
    const uint8_t *got = pixels + i * 4;
    if (got[0] == 255 && got[1] == 0 && got[2] == 0 && got[3] == 255) near_pixels++;
    else {
      if (wrong < 6) printf("vulkan-test: depth: pixel %d is %02x%02x%02x%02x, not ff0000ff\n", i, got[0], got[1], got[2], got[3]);
      wrong++;
    }
  }
  printf("vulkan-test: depth: %d pixels of the nearer triangle, %d wrong\n", near_pixels, wrong);
  check(wrong == 0, "the nearer triangle covers the farther one drawn after it");
  ok = wrong == 0;
done:
  if (pipeline) vk.vkDestroyPipeline(device, pipeline, NULL);
  if (layout) vk.vkDestroyPipelineLayout(device, layout, NULL);
  if (framebuffer) vk.vkDestroyFramebuffer(device, framebuffer, NULL);
  if (pass) vk.vkDestroyRenderPass(device, pass, NULL);
  free_image(&color);
  free_image(&depth);
  free_buffer(&vertices);
  free_buffer(&readback);
  if (ok) printf("vulkan-test: ok: vulkan depth\n");
}

/// The triangle drawn into a four-sample image that the render pass resolves into a single-sample one: inside and outside
/// the triangle the colours are exact, and along its edges there are pixels that are neither, since the samples differ.
static void multisample_test(void) {
  Buffer vertices = {0}, readback = {0};
  Image many = {0}, one = {0};
  VkRenderPass pass = NULL;
  VkFramebuffer framebuffer = NULL;
  VkPipelineLayout layout = NULL;
  VkPipeline pipeline = NULL;
  int ok = 0;
  VkPhysicalDeviceProperties properties;
  vk.vkGetPhysicalDeviceProperties(physical, &properties);
  VkFormatFeatureFlags features = format_features(VK_FORMAT_R8G8B8A8_UNORM);
  if (!(properties.limits.framebufferColorSampleCounts & VK_SAMPLE_COUNT_4_BIT) ||
      !(features & VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT)) {
    printf("vulkan-test: skipped: vulkan multisample (the device has no four-sample colour)\n");
    return;
  }
  if (!make_buffer(&vertices, sizeof triangle, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT)) goto done;
  memcpy(vertices.mapped, triangle, sizeof triangle);
  if (!make_buffer(&readback, size * size * 4, VK_BUFFER_USAGE_TRANSFER_DST_BIT)) goto done;
  memset(readback.mapped, 0x5a, size * size * 4);
  if (!make_image(&many, VK_FORMAT_R8G8B8A8_UNORM, VK_SAMPLE_COUNT_4_BIT, VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
                  VK_IMAGE_ASPECT_COLOR_BIT)) goto done;
  if (!make_image(&one, VK_FORMAT_R8G8B8A8_UNORM, VK_SAMPLE_COUNT_1_BIT,
                  VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT, VK_IMAGE_ASPECT_COLOR_BIT)) goto done;

  VkAttachmentDescription attachments[2] = {
      {.format = VK_FORMAT_R8G8B8A8_UNORM, .samples = VK_SAMPLE_COUNT_4_BIT, .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
       .storeOp = VK_ATTACHMENT_STORE_OP_DONT_CARE, .stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE,
       .stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE, .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
       .finalLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL},
      {.format = VK_FORMAT_R8G8B8A8_UNORM, .samples = VK_SAMPLE_COUNT_1_BIT, .loadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE,
       .storeOp = VK_ATTACHMENT_STORE_OP_STORE, .stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE,
       .stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE, .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
       .finalLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL},
  };
  VkAttachmentReference color_reference = {0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};
  VkAttachmentReference resolve_reference = {1, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};
  VkSubpassDescription subpass = {.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS, .colorAttachmentCount = 1,
                                  .pColorAttachments = &color_reference, .pResolveAttachments = &resolve_reference};
  VkRenderPassCreateInfo pass_info = {.sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO, .attachmentCount = 2,
                                      .pAttachments = attachments, .subpassCount = 1, .pSubpasses = &subpass};
  if (!succeeded(vk.vkCreateRenderPass(device, &pass_info, NULL, &pass), "vkCreateRenderPass (multisample)")) goto done;
  VkImageView views[2] = {many.view, one.view};
  VkFramebufferCreateInfo framebuffer_info = {.sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO, .renderPass = pass,
                                              .attachmentCount = 2, .pAttachments = views, .width = size, .height = size,
                                              .layers = 1};
  if (!succeeded(vk.vkCreateFramebuffer(device, &framebuffer_info, NULL, &framebuffer), "vkCreateFramebuffer (multisample)")) goto done;
  VkPipelineLayoutCreateInfo layout_info = {.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO};
  if (!succeeded(vk.vkCreatePipelineLayout(device, &layout_info, NULL, &layout), "vkCreatePipelineLayout")) goto done;
  pipeline = make_pipeline(pass, layout, triangle_vert, sizeof triangle_vert, sizeof(Vertex), VK_FORMAT_R32G32_SFLOAT, 8,
                           VK_SAMPLE_COUNT_4_BIT, 0);
  if (!pipeline) goto done;

  VkCommandBuffer cmd = begin_commands();
  if (!cmd) goto done;
  VkClearValue clear = {.color = {.float32 = {0, 0, 1, 1}}};
  VkClearValue clears[2] = {clear, clear};
  VkRenderPassBeginInfo begin = {.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO, .renderPass = pass,
                                 .framebuffer = framebuffer, .renderArea = {{0, 0}, {size, size}}, .clearValueCount = 2,
                                 .pClearValues = clears};
  vk.vkCmdBeginRenderPass(cmd, &begin, VK_SUBPASS_CONTENTS_INLINE);
  vk.vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
  VkDeviceSize offset = 0;
  vk.vkCmdBindVertexBuffers(cmd, 0, 1, &vertices.buffer, &offset);
  vk.vkCmdDraw(cmd, 3, 1, 0, 0);
  vk.vkCmdEndRenderPass(cmd);
  read_back(cmd, one.image, readback.buffer);
  if (!succeeded(vk.vkEndCommandBuffer(cmd), "vkEndCommandBuffer")) goto done;
  if (!run(cmd, "multisample")) goto done;

  const uint8_t *pixels = readback.mapped;
  int inside = 0, outside = 0, partial = 0, wrong = 0;
  for (int y = 0; y < size; y++) {
    for (int x = 0; x < size; x++) {
      int judged;
      int in = reference(x, y, &judged);
      const uint8_t *got = pixels + (y * size + x) * 4;
      if (!judged) {
        // Near an edge: any mix of the two is right, and a mix that is neither colour is the multisampling.
        if (memcmp(got, triangle_pixel, 4) != 0 && memcmp(got, clear_pixel, 4) != 0) partial++;
        continue;
      }
      in ? inside++ : outside++;
      const uint8_t *want = in ? triangle_pixel : clear_pixel;
      if (memcmp(got, want, 4) != 0) {
        if (wrong < 6) {
          printf("vulkan-test: multisample: pixel %d, %d is %02x%02x%02x%02x, not %02x%02x%02x%02x\n", x, y, got[0], got[1],
                 got[2], got[3], want[0], want[1], want[2], want[3]);
        }
        wrong++;
      }
    }
  }
  printf("vulkan-test: multisample: %d pixels inside, %d outside, %d partly covered near an edge, %d wrong\n", inside, outside,
         partial, wrong);
  check(wrong == 0, "the resolved triangle's pixels match the reference away from its edges");
  check(partial >= 8, "the resolve mixes the samples of the pixels on the triangle's edges");
  ok = wrong == 0 && partial >= 8;
done:
  if (pipeline) vk.vkDestroyPipeline(device, pipeline, NULL);
  if (layout) vk.vkDestroyPipelineLayout(device, layout, NULL);
  if (framebuffer) vk.vkDestroyFramebuffer(device, framebuffer, NULL);
  if (pass) vk.vkDestroyRenderPass(device, pass, NULL);
  free_image(&many);
  free_image(&one);
  free_buffer(&vertices);
  free_buffer(&readback);
  if (ok) printf("vulkan-test: ok: vulkan multisample\n");
}

// MARK: Main

int main(void) {
  VkInstance instance = NULL;
  PFN_vkCreateInstance create = (PFN_vkCreateInstance)vkGetInstanceProcAddr(NULL, "vkCreateInstance");
  if (!create) {
    printf("vulkan-test: FAILED: the loader has no vkCreateInstance\n");
    return 1;
  }
  VkApplicationInfo app = {.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .pApplicationName = "vulkan-test",
                           .apiVersion = (1u << 22) | (3u << 12)};
  VkInstanceCreateInfo info = {.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app};
  if (!succeeded(create(&info, NULL, &instance), "vkCreateInstance")) return 1;
  if (!load(instance)) return 1;

  uint32_t count = 0;
  if (!succeeded(vk.vkEnumeratePhysicalDevices(instance, &count, NULL), "vkEnumeratePhysicalDevices")) return 1;
  VkPhysicalDevice devices[8];
  if (count > 8) count = 8;
  if (!succeeded(vk.vkEnumeratePhysicalDevices(instance, &count, devices), "vkEnumeratePhysicalDevices")) return 1;
  printf("vulkan-test: %u physical device%s\n", count, count == 1 ? "" : "s");
  check(count > 0, "there is a physical device");
  int chosen = -1;
  for (uint32_t i = 0; i < count; i++) {
    VkPhysicalDeviceProperties properties;
    vk.vkGetPhysicalDeviceProperties(devices[i], &properties);
    printf("vulkan-test: device %u: %s (type %d, Vulkan %u.%u)\n", i, properties.deviceName, (int)properties.deviceType,
           properties.apiVersion >> 22, (properties.apiVersion >> 12) & 0x3ff);
    uint32_t families = 0;
    vk.vkGetPhysicalDeviceQueueFamilyProperties(devices[i], &families, NULL);
    VkQueueFamilyProperties family_properties[16];
    if (families > 16) families = 16;
    vk.vkGetPhysicalDeviceQueueFamilyProperties(devices[i], &families, family_properties);
    for (uint32_t f = 0; f < families && chosen < 0; f++) {
      VkQueueFlags need = VK_QUEUE_GRAPHICS_BIT | VK_QUEUE_COMPUTE_BIT;
      if ((family_properties[f].queueFlags & need) == need) {
        chosen = (int)i;
        family = f;
      }
    }
  }
  if (chosen < 0) {
    check(0, "a physical device with a queue family for graphics and compute");
    return 1;
  }
  physical = devices[chosen];
  vk.vkGetPhysicalDeviceMemoryProperties(physical, &memory);

  float priority = 1.0f;
  VkDeviceQueueCreateInfo queue_info = {.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueFamilyIndex = family,
                                        .queueCount = 1, .pQueuePriorities = &priority};
  VkDeviceCreateInfo device_info = {.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .queueCreateInfoCount = 1,
                                    .pQueueCreateInfos = &queue_info};
  if (!succeeded(vk.vkCreateDevice(physical, &device_info, NULL, &device), "vkCreateDevice")) return 1;
  vk.vkGetDeviceQueue(device, family, 0, &queue);
  VkCommandPoolCreateInfo pool_info = {.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .queueFamilyIndex = family};
  if (!succeeded(vk.vkCreateCommandPool(device, &pool_info, NULL, &pool), "vkCreateCommandPool")) return 1;

  compute_test();
  triangle_test();
  depth_test();
  multisample_test();

  vk.vkDeviceWaitIdle(device);
  vk.vkDestroyCommandPool(device, pool, NULL);
  vk.vkDestroyDevice(device, NULL);
  vk.vkDestroyInstance(instance, NULL);
  if (failures) {
    printf("vulkan-test: FAILED, %d checks\n", failures);
    return 1;
  }
  printf("vulkan-test: passed\n");
  return 0;
}
