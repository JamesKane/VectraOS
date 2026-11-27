# ports/vkmark: vkmark for VectraOS

vkmark, the Vulkan benchmark, ported as a tier 1 C++ program to measure our
Vulkan layer (graphics/vulkan/drivers/core) on the Orange Pi 6 Plus's Mali
backend, in a window of Radharc's and headless (D177's `uc_vkmark`).
vkmark is LGPL-2.1: none of its files are in this tree. Its pinned release
is fetched into `.cache/ports/vkmark` and our patches, kept here as a series,
are applied to it there, as glmark2's are (ports/glmark2).

```sh
ports/vkmark/fetch.sh            # vkmark 2025.01 (2bf2ca7f1623), Vulkan-Headers v1.4.341, glm 1.0.1; vkmark's tagged vectraos-base
ports/vkmark/apply-patches.sh    # patches/*.patch onto vkmark with git am (--reset to start over)
```

With the patched source present, tier 1's build (cmake/Tier1.cmake)
includes `cmake/Vkmark.cmake`, which compiles vkmark's sources (meson's
list, `src/meson.build`) with the tier 1 clang++ into `bin/vkmark`, linked
against FDIO, the Vulkan layer's registry and the shared Swift runtime, and
its data into bootfs's `lib/vkmark`. vkmark(8) is its page.

## The series

| Patch | What |
|---|---|
| 0001 | Models read without assimp: a small loader for 3DS, PLY and OBJ, giving what assimp's steps gave `Model::to_mesh` (vkmark's `tests/model_test.cpp` passes unchanged) |
| 0002 | One program over a loader that exports `vkGetInstanceProcAddr`: window systems compiled in (`VKMARK_STATIC_WINDOW_SYSTEMS`), `vulkan.hpp`'s dynamic dispatcher, `--list-devices` without `VK_KHR_display`, no signal handlers, and `format_map_gen.h` committed |
| 0003 | A window system for VectraOS: a window of Radharc's through `VK_VECTRA_window_surface` (the layer's `vulkan_vectra.h`) and a swapchain; Escape or closing the window ends the run; mailbox becomes FIFO |

To change a patch: commit in `.cache/ports/vkmark` (amend, or reset to
`vectraos-base` and re-apply), then write the series again with
`git -C .cache/ports/vkmark format-patch --keep-subject -o ports/vkmark/patches vectraos-base`,
and review its diff.

## Its dependencies, and how each is carried

- **Vulkan's C++ interface.** vkmark is written against `vulkan.hpp`, so it
  is compiled against Khronos's Vulkan-Headers at v1.4.341, the version of
  `data/vulkan/vk.xml` that our `td_vulkan.h` is generated from. They are
  headers (Apache-2.0 OR MIT), compiled into vkmark alone; nothing of them
  is installed. Our layer is reached through `vkGetInstanceProcAddr`
  alone, by `vulkan.hpp`'s dynamic dispatcher (patch 0002), so no
  `libvulkan` exporting every command is needed.
- **glm** 1.0.1 (MIT), headers only, compiled into vkmark alone.
- **assimp** is not carried. It is a large library reading dozens of
  formats; the scenes read four files in two formats (3DS and PLY), so
  patch 0001 replaces it with a loader of about 500 lines.
- **Shaders.** vkmark ships each shader's SPIR-V beside its GLSL
  (`data/shaders/*.spv`); bootfs takes the SPIR-V as it is, so no shader
  compiler runs at build time, ours or a host's.
- **Textures.** vkmark carries stb_image (public domain) and reads its PNG
  and JPEG textures with it.
- **The format map.** vkmark's meson build writes `format_map_gen.h` from
  vk.xml with Python, which this tree doesn't have; patch 0002 commits what
  that script writes from Vulkan-Headers v1.4.341's registry (the same
  `VkFormat` block as data/vulkan/vk.xml's).

The off-screen run is vkmark's own headless window system, over
`VK_EXT_headless_surface`, which the layer implements (vulkansurface(2)).
