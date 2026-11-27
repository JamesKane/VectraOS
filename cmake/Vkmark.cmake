# SPDX-License-Identifier: BSD-3-Clause
#
# vkmark (vkmark(8)): the Vulkan benchmark, ported as a tier 1 C++ program,
# vkmark, from its pinned release in .cache/ports/vkmark with our patch
# series applied (ports/vkmark: fetch.sh, apply-patches.sh), compiled
# against the Vulkan-Headers (vulkan.hpp) and glm that fetch.sh pins beside
# it, which are headers only. The sources are meson's (src/meson.build):
# vkmark's core, its scenes and vkutil, and two window systems compiled in
# (patch 0002, VKMARK_STATIC_WINDOW_SYSTEMS): upstream's headless one, over
# VK_EXT_headless_surface, and ours (patch 0003), a window of Radharc's
# over VK_VECTRA_window_surface. Its models are read by the loader of patch
# 0001, not assimp; its shaders are the SPIR-V vkmark ships, and its
# textures are read by the stb_image it carries. It reaches Vulkan through
# vkGetInstanceProcAddr alone (vulkan.hpp's dynamic dispatcher), linked as
# vulkan-present is: against the Vulkan layer's registry, which opens
# windows through the SDK. Its data are lib/vkmark in the images that run it
# (VKMARK_DATA_DIR, kernel/CMakeLists.txt).
#
# Included by croi_tier1 (cmake/Tier1.cmake) when the port's source is
# present and the layer is built; uses its variables (_clang, _lib, _core_so...).
#   croi_tier1_vkmark()   sets CROI_TIER1_VKMARK and CROI_TIER1_VKMARK_DATA (bootfs entries of the data)

function(croi_tier1_vkmark)
  set(_v ${PROJECT_SOURCE_DIR}/.cache/ports/vkmark)
  set(_s ${_v}/src)
  set(_o ${_out}/vkmark.dir)
  set(_name vkmark)
  set(_sources benchmark.cpp benchmark_collection.cpp default_benchmarks.cpp device_uuid.cpp log.cpp main_loop.cpp
      mesh.cpp model.cpp options.cpp scene.cpp scene_collection.cpp util.cpp vulkan_state.cpp window_system_loader.cpp
      main.cpp
      vkutil/buffer_builder.cpp vkutil/copy_buffer.cpp vkutil/descriptor_set_builder.cpp
      vkutil/find_matching_memory_type.cpp vkutil/framebuffer_builder.cpp vkutil/image_builder.cpp
      vkutil/image_view_builder.cpp vkutil/map_memory.cpp vkutil/one_time_command_buffer.cpp
      vkutil/pipeline_builder.cpp vkutil/render_pass_builder.cpp vkutil/semaphore_builder.cpp
      vkutil/texture_builder.cpp vkutil/transition_image_layout.cpp
      scenes/clear_scene.cpp scenes/cube_scene.cpp scenes/default_options_scene.cpp scenes/desktop_scene.cpp
      scenes/effect2d_scene.cpp scenes/shading_scene.cpp scenes/texture_scene.cpp scenes/vertex_scene.cpp
      ws/swapchain_window_system.cpp
      ws/headless_window_system_plugin.cpp ws/headless_native_system.cpp
      ws/vectraos_window_system_plugin.cpp ws/vectraos_native_system.cpp)
  set(_defines -DVKMARK_VERSION_STR="2025.01" -DVKMARK_DATA_DIR="/lib/vkmark" -DVKMARK_WINDOW_SYSTEM_DIR=""
      "-DVKMARK_STATIC_WINDOW_SYSTEMS=X(headless)X(vectraos)"
      -DVULKAN_HPP_DISPATCH_LOADER_DYNAMIC=1 -DVULKAN_HPP_ENABLE_DYNAMIC_LOADER_TOOL=0)
  set(_includes -I${_v} -I${_s} -I${PROJECT_SOURCE_DIR}/.cache/ports/vulkan-headers/include
      -I${PROJECT_SOURCE_DIR}/.cache/ports/glm)
  # Third-party C++, compiled as it is: its warnings are its own.
  # -fPIE: it takes vkGetInstanceProcAddr's address, which a shared library gives (through the GOT, as the symbol is
  # protected there).
  set(_cflags --target=${_triple} --sysroot=${_sysroot} -std=c++17 -O2 -fPIE -ffunction-sections -w)
  set(_objects)
  foreach(_f ${_sources})
    string(REPLACE "/" "_" _b ${_f})
    string(REGEX REPLACE "\\.cpp$" ".o" _b ${_b})
    # A window system's plugin functions under its own names (patch 0002); ours sees the layer's vulkan_vectra.h.
    set(_ws)
    if(_f MATCHES "^ws/([a-z]+)_window_system_plugin\\.cpp$")
      set(_w ${CMAKE_MATCH_1})
      foreach(_fn load_options probe create)
        list(APPEND _ws -Dvkmark_window_system_${_fn}=vkmark_${_w}_window_system_${_fn})
      endforeach()
    endif()
    if(_f MATCHES "^ws/vectraos_")
      list(APPEND _ws -I${PROJECT_SOURCE_DIR}/graphics/vulkan/c/include)
    endif()
    add_custom_command(OUTPUT ${_o}/${_b}
      COMMAND ${CMAKE_COMMAND} -E make_directory ${_o}
      COMMAND ${_toolchain_bin}/clang++ ${_cflags} ${_defines} ${_ws} ${_includes} -c ${_s}/${_f} -o ${_o}/${_b}
      DEPENDS cxx ${_s}/${_f} ${_sysroot}/usr/lib/libsys.a ${PROJECT_SOURCE_DIR}/graphics/vulkan/c/include/vulkan_vectra.h
      COMMENT "vkmark: ${_f}" VERBATIM)
    list(APPEND _objects ${_o}/${_b})
  endforeach()
  # The Vulkan layer's registry and the SDK's libraries it opens windows through, as vulkan-present links them.
  add_custom_command(OUTPUT ${_out}/${_name}
    COMMAND ${_toolchain_bin}/swift-autolink-extract ${_lib}/libFDIO.a -o ${_o}/autolink
    COMMAND ${VX} library-note ${_o}/libraries.c ${_lib}/libVulkanCoreRegistry.so ${_core_so} ${_t1_so} ${_shared_libs}
    COMMAND ${_toolchain_bin}/clang --target=${_triple} -c ${_o}/libraries.c -o ${_o}/libraries.o
    COMMAND ${_toolchain_bin}/ld.lld --build-id=sha1 -z max-page-size=0x1000 -z noexecstack -z now --eh-frame-hdr
            --no-dynamic-linker -e _start --image-base=0x1000000 -z separate-loadable-segments -z stack-size=1048576
            --gc-sections --no-as-needed ${_lib}/libVulkanCoreRegistry.so --as-needed
            ${_static}/swiftrt.o ${_objects} ${_o}/libraries.o ${_lib}/libFDIO.a ${_core_so} ${_t1_so}
            -L${_shared} @${_o}/autolink -L${_builtins_dir} -L${_sysroot}/usr/lib
            -lc++ -lc++abi -lunwind --start-group -lsys -lc -lm --end-group -lclang_rt.builtins -o ${_out}/${_name}
    DEPENDS ${_objects} swift-shared vx ${_shared_libs} ${_t1_so} ${_core_so} ${_lib}/libFDIO.a
            ${_sysroot}/usr/lib/libsys.a
    COMMENT "${_name}, C++ linked with FDIO, the Vulkan layer and the shared Swift runtime")
  add_custom_target(vkmark ALL DEPENDS ${_out}/${_name})
  # Its data (models, shaders as SPIR-V, textures): lib/vkmark/<path>. The GLSL beside the SPIR-V isn't read.
  file(GLOB_RECURSE _data RELATIVE ${_v}/data ${_v}/data/models/* ${_v}/data/shaders/*.spv ${_v}/data/textures/*)
  set(_data_entries)
  foreach(_d ${_data})
    list(APPEND _data_entries lib/vkmark/${_d}=${_v}/data/${_d})
  endforeach()
  set_property(GLOBAL PROPERTY CROI_TIER1_VKMARK ${_out}/${_name})
  set_property(GLOBAL PROPERTY CROI_TIER1_VKMARK_DATA ${_data_entries})
endfunction()
