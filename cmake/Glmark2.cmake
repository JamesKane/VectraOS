# SPDX-License-Identifier: BSD-3-Clause
#
# glmark2 (D183): the GLES 2.0 benchmark, ported as a tier 1 C++ program,
# glmark2-es2-vectraos, from its pinned release in .cache/ports/glmark2
# with our patch series applied (ports/glmark2: fetch.sh, apply-patches.sh).
# The sources and flavour are meson's GLESv2 + EGL ones (src/meson.build):
# the common sources, main.cpp, canvas-generic.cpp, gl-state-egl.cpp and
# glad's EGL and GLES 2 loaders, with our native state
# (native-state-vectraos.cpp, patch 0001); and the libpng, libjpeg-turbo
# and zlib glmark2 carries, compiled into it alone (D4, D183: nothing
# third-party is installed as a library). It loads EGL and GLES through
# glad's dlopen of libEGL.so and libGLESv2.so (dlfcn(2), through Ld), which
# finds them already loaded when bootfs's lib/ has them: the program names
# them as needed. Its data are lib/glmark2 in the images that run it
# (GLMARK_DATA_PATH, kernel/CMakeLists.txt).
#
# Included by croi_tier1 (cmake/Tier1.cmake) when the port's source is
# present; uses its variables (_clang, _lib, _t1_so, _shared_libs...).
#   croi_tier1_glmark2()   sets CROI_TIER1_GLMARK2 and CROI_TIER1_GLMARK2_DATA (bootfs entries of the data)

function(croi_tier1_glmark2)
  set(_g ${PROJECT_SOURCE_DIR}/.cache/ports/glmark2)
  set(_s ${_g}/src)
  set(_o ${_out}/glmark2.dir)
  set(_name glmark2-es2-vectraos)
  set(_common benchmark-collection.cpp benchmark.cpp canvas-generic.cpp gl-headers.cpp gl-visual-config.cpp
      image-reader.cpp libmatrix/log.cc libmatrix/mat.cc libmatrix/program.cc libmatrix/shader-source.cc
      libmatrix/util.cc main-loop.cpp mesh.cpp model.cpp options.cpp results-file.cpp scene-buffer.cpp
      scene-build.cpp scene-bump.cpp scene-clear.cpp scene-conditionals.cpp scene.cpp scene-default-options.cpp
      scene-desktop.cpp scene-effect-2d.cpp scene-function.cpp scene-grid.cpp scene-ideas/a.cc scene-ideas.cpp
      scene-ideas/d.cc scene-ideas/e.cc scene-ideas/i.cc scene-ideas/lamp.cc scene-ideas/logo.cc scene-ideas/m.cc
      scene-ideas/n.cc scene-ideas/o.cc scene-ideas/s.cc scene-ideas/splines.cc scene-ideas/table.cc
      scene-ideas/t.cc scene-jellyfish.cpp scene-loop.cpp scene-pulsar.cpp scene-refract.cpp scene-shading.cpp
      scene-shadow.cpp scene-terrain/base-renderer.cpp scene-terrain/blur-renderer.cpp
      scene-terrain/copy-renderer.cpp scene-terrain.cpp scene-terrain/luminance-renderer.cpp
      scene-terrain/normal-from-height-renderer.cpp scene-terrain/overlay-renderer.cpp
      scene-terrain/renderer-chain.cpp scene-terrain/simplex-noise-renderer.cpp scene-terrain/terrain-renderer.cpp
      scene-terrain/texture-renderer.cpp scene-texture.cpp shared-library.cpp text-renderer.cpp texture.cpp
      main.cpp gl-state-egl.cpp native-state-vectraos.cpp)
  # Our budgets (budgets-vectraos.cpp, patch 0002; glmark2(8)'s BUDGETS). A checkout patched before 0002 has
  # none: glmark2 is built without them, so its board run never says its budgets are met, and configuring says so.
  if(EXISTS ${_s}/budgets-vectraos.cpp)
    list(APPEND _common budgets-vectraos.cpp)
  else()
    message(WARNING "glmark2: .cache/ports/glmark2 predates patch 0002, so glmark2 is built without its budgets: "
      "run ports/glmark2/apply-patches.sh --reset and configure again")
  endif()
  set(_glad glad/src/egl.c glad/src/gles2.c)
  # The bundled libraries, as glmark2's waf build lists them (src/wscript_build).
  file(GLOB _png RELATIVE ${_s} ${_s}/libpng/*.c)
  file(GLOB _zlib RELATIVE ${_s} ${_s}/zlib/*.c)
  set(_jpeg)
  foreach(_j jcapimin jcapistd jccoefct jccolor jcdctmgr jchuff jcinit jcmainct jcmarker jcmaster jcomapi jcparam
             jcphuff jcprepct jcsample jdapimin jdapistd jdatadst jdatasrc jdcoefct jdcolor jddctmgr jdhuff jdinput
             jdmainct jdmarker jdmaster jdmerge jdphuff jdpostct jdsample jerror jfdctflt jfdctfst jfdctint jidctflt
             jidctfst jidctint jidctred jmemmgr jmemnobs jquant1 jquant2 jsimd_none jutils)
    list(APPEND _jpeg libjpeg-turbo/${_j}.c)
  endforeach()
  set(_defines -DGLMARK2_USE_VECTRAOS -DGLMARK2_USE_GLESv2 -DGLMARK2_USE_EGL -DUSE_EXCEPTIONS
      -DEGL_NO_PLATFORM_SPECIFIC_TYPES -DGLMARK_VERSION="2023.01" -DGLMARK_DATA_PATH="/lib/glmark2"
      -DGLMARK2_EXECUTABLE="${_name}"
      # libpng's option for a libc with no gmtime (it only converts a time for writing, which glmark2 never
      # does), and zlib's for one with <unistd.h>.
      -DPNG_NO_CONVERT_tIME -DZ_HAVE_UNISTD_H)
  set(_includes -I${_s} -I${_s}/libmatrix -I${_s}/scene-ideas -I${_s}/scene-terrain -I${_s}/glad/include
      -I${_s}/libpng -I${_s}/zlib -I${_s}/libjpeg-turbo)
  # Third-party C, compiled as it is: its warnings are its own.
  set(_cflags --target=${_triple} --sysroot=${_sysroot} -O2 -ffunction-sections -w)
  set(_objects)
  foreach(_f ${_common} ${_glad} ${_png} ${_zlib} ${_jpeg})
    string(REPLACE "/" "_" _b ${_f})
    string(REGEX REPLACE "\\.[a-z]+$" ".o" _b ${_b})
    if(_f MATCHES "\\.c$")
      set(_cc ${_toolchain_bin}/clang -std=gnu11)
    else()
      set(_cc ${_toolchain_bin}/clang++ -std=c++14)
    endif()
    add_custom_command(OUTPUT ${_o}/${_b}
      COMMAND ${CMAKE_COMMAND} -E make_directory ${_o}
      COMMAND ${_cc} ${_cflags} ${_defines} ${_includes} -c ${_s}/${_f} -o ${_o}/${_b}
      DEPENDS cxx ${_s}/${_f} ${_sysroot}/usr/lib/libsys.a
      COMMENT "glmark2: ${_f}" VERBATIM)
    list(APPEND _objects ${_o}/${_b})
  endforeach()
  # The EGL and GLES libraries (graphics/gles), when tier 1 builds them and
  # names them in CROI_TIER1_GLES, as needed: loaded with the program, so
  # that glad's dlopen finds them. With the Swift runtime's libraries they
  # need: a library dlopen loads may not have TLS (dlfcn(2)).
  set(_gl_needed)
  get_property(_gl_needed GLOBAL PROPERTY CROI_TIER1_GLES)
  add_custom_command(OUTPUT ${_out}/${_name}
    COMMAND ${_toolchain_bin}/swift-autolink-extract ${_lib}/libFDIO.a -o ${_o}/autolink
    COMMAND ${VX} library-note ${_o}/libraries.c ${_gl_needed} ${_lib}/libLd.so ${_t1_so} ${_shared_libs}
    COMMAND ${_toolchain_bin}/clang --target=${_triple} -c ${_o}/libraries.c -o ${_o}/libraries.o
    COMMAND ${_toolchain_bin}/ld.lld --build-id=sha1 -z max-page-size=0x1000 -z noexecstack -z now --eh-frame-hdr
            --no-dynamic-linker -e _start --image-base=0x1000000 -z separate-loadable-segments -z stack-size=1048576
            --gc-sections --no-as-needed ${_gl_needed} ${_shared_libs} --as-needed
            ${_static}/swiftrt.o ${_objects} ${_o}/libraries.o ${_lib}/libFDIO.a ${_lib}/libLd.so ${_t1_so}
            -L${_shared} @${_o}/autolink -L${_builtins_dir} -L${_sysroot}/usr/lib
            -lc++ -lc++abi -lunwind --start-group -lsys -lc -lm --end-group -lclang_rt.builtins -o ${_out}/${_name}
    DEPENDS ${_objects} swift-shared vx ${_shared_libs} ${_t1_so} ${_lib}/libFDIO.a ${_lib}/libLd.so ${_gl_needed}
            ${_sysroot}/usr/lib/libsys.a
    COMMENT "${_name}, C++ linked with FDIO, dlopen and the shared Swift runtime")
  add_custom_target(glmark2 ALL DEPENDS ${_out}/${_name})
  # Its data (models, shaders, textures): lib/glmark2/<path>.
  file(GLOB_RECURSE _data RELATIVE ${_g}/data ${_g}/data/models/* ${_g}/data/shaders/* ${_g}/data/textures/*)
  set(_data_entries)
  foreach(_d ${_data})
    list(APPEND _data_entries lib/glmark2/${_d}=${_g}/data/${_d})
  endforeach()
  set_property(GLOBAL PROPERTY CROI_TIER1_GLMARK2 ${_out}/${_name})
  set_property(GLOBAL PROPERTY CROI_TIER1_GLMARK2_DATA ${_data_entries})
endfunction()
