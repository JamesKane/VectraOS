# Tier 1 (D47): programs in C, C++ and full Swift, built by the
# *-vectraos toolchain (tools/toolchain: clang, lld and swiftc from the
# pinned Swift 6.4.0 sources with the series) against tier 1's sysroot,
# build/<arch>/sysroot: the floor as libsys.a, the libc as libc.a, the
# libc's headers and the floor's C interface (cmake/sysroot.cmake);
# libc++, libc++abi and libunwind (cmake/cxx.cmake); the Swift runtime and
# standard library (tools/toolchain/build_stdlib.sh) and FoundationEssentials
# (build_foundation.sh), with compiler-rt's builtins (build_builtins.sh).
# riscv64's Swift calling conventions are the series' (tools/toolchain/
# riscv64.md). The runtime, standard library and FoundationEssentials are
# also shared libraries (D124, link_shared.sh) in bootfs's lib/, which
# programs linked by croi_tier1_dynamic share.
#
#   croi_tier1(BOOTFS_VAR DEPENDS_VAR)
# Sets BOOTFS_VAR to the bootfs entries (bin/NAME=FILE) of tier 1's test
# programs and DEPENDS_VAR to their files; both empty when the toolchain
# or its builtins haven't been built (.cache/toolchain/out/bin/swiftc,
# tools/toolchain/build_builtins.sh).

include(${PROJECT_SOURCE_DIR}/cmake/cxx.cmake)

function(croi_tier1 bootfs_var depends_var)
  set(${bootfs_var} "" PARENT_SCOPE)
  set(${depends_var} "" PARENT_SCOPE)
  set(_toolchain_bin ${PROJECT_SOURCE_DIR}/.cache/toolchain/out/bin)
  set(_machine ${CMAKE_SYSTEM_PROCESSOR})  # x86_64, aarch64, riscv64
  set(_triple ${_machine}-unknown-vectraos)
  set(_builtins ${_toolchain_bin}/../lib/clang/21/lib/${_triple}/libclang_rt.builtins.a)
  if(NOT EXISTS ${_toolchain_bin}/swiftc OR NOT EXISTS ${_builtins})
    return()
  endif()
  set(_sysroot ${CMAKE_BINARY_DIR}/sysroot)
  set(_out ${CMAKE_BINARY_DIR}/tier1)
  set(_src ${PROJECT_SOURCE_DIR}/user/tier1)
  set(_floor_include ${PROJECT_SOURCE_DIR}/system/sys/floor/include)
  file(GLOB _libc_headers CONFIGURE_DEPENDS ${PROJECT_SOURCE_DIR}/system/libc/include/*.h
       ${PROJECT_SOURCE_DIR}/system/libc/include/*/*.h ${PROJECT_SOURCE_DIR}/system/libc/include/module.modulemap)

  # The sysroot: the floor (fixed-address, as tier 1 links ET_EXEC), the libc.
  add_custom_command(OUTPUT ${_sysroot}/usr/lib/libsys.a ${_sysroot}/usr/lib/libc.a
    COMMAND ${CMAKE_COMMAND} -DFLOOR=${CROI_USER_FLOOR} -DLIBC=${CROI_USER_LIBC} -DBUILTINS=${_builtins}
            -DHEADERS=${PROJECT_SOURCE_DIR}/system/libc/include -DFLOOR_HEADERS=${_floor_include}
            -DCROI_HEADERS=${PROJECT_SOURCE_DIR}/user/include/croi -DKERNEL_HEADERS=${PROJECT_SOURCE_DIR}/kernel/include
            -DOBJCOPY=${CMAKE_OBJCOPY} -DAR=${CMAKE_AR} -DOUT=${_sysroot} -P ${PROJECT_SOURCE_DIR}/cmake/sysroot.cmake
    DEPENDS ${CROI_USER_FLOOR} ${CROI_USER_LIBC} ${_builtins} ${PROJECT_SOURCE_DIR}/cmake/sysroot.cmake ${_libc_headers}
            ${PROJECT_SOURCE_DIR}/user/include/croi/syscall.h ${PROJECT_SOURCE_DIR}/kernel/include/module.modulemap
            ${_floor_include}/td_floor.h ${_floor_include}/td_native.h ${_floor_include}/td_utc.h
            ${_floor_include}/td_stdio.h ${PROJECT_SOURCE_DIR}/user/include/croi/runtime.h
            ${PROJECT_SOURCE_DIR}/user/include/croi/mmio.h
    COMMENT "Tier 1's sysroot")
  add_custom_target(sysroot ALL DEPENDS ${_sysroot}/usr/lib/libsys.a)

  set(_clang ${_toolchain_bin}/clang --target=${_triple} --sysroot=${_sysroot} -O2)
  # C: floor-hello.
  add_custom_command(OUTPUT ${_out}/floor-hello
    COMMAND ${CMAKE_COMMAND} -E make_directory ${_out}
    COMMAND ${_clang} ${_src}/floor-hello.c -o ${_out}/floor-hello
    DEPENDS sysroot ${_sysroot}/usr/lib/libsys.a ${_src}/floor-hello.c
    COMMENT "floor-hello, by the *-vectraos clang")
  # C++: libc++, libc++abi, libunwind into the sysroot, then cxx-hello.
  croi_tier1_cxx(${_triple} ${_sysroot})
  add_custom_command(OUTPUT ${_out}/cxx-hello
    COMMAND ${CMAKE_COMMAND} -E make_directory ${_out}
    COMMAND ${_toolchain_bin}/clang++ --target=${_triple} --sysroot=${_sysroot} -O2 -std=c++20
            ${_src}/cxx-hello.cpp -o ${_out}/cxx-hello
    DEPENDS cxx ${_src}/cxx-hello.cpp ${_sysroot}/usr/lib/libsys.a
    COMMENT "cxx-hello, by the *-vectraos clang++")
  # Swift: the runtime and standard library (ninja inside decides what's
  # stale), then swift-hello (a library module and a program), swift-start
  # and swift-async.
  set(_static ${_sysroot}/usr/lib/swift_static/vectraos/${_machine})
  set(_swift_core ${_static}/libswiftCore.a ${_static}/libswift_Concurrency.a ${_static}/libswiftSynchronization.a)
  add_custom_target(swift-stdlib ALL
    COMMAND ${PROJECT_SOURCE_DIR}/tools/toolchain/build_stdlib.sh ${_machine}
    BYPRODUCTS ${_swift_core}
    DEPENDS cxx
    COMMENT "Tier 1's Swift runtime and standard library (tools/toolchain/build_stdlib.sh)")
  set(_swiftc ${_toolchain_bin}/swiftc -target ${_triple} -sdk ${_sysroot}
      -resource-dir ${_sysroot}/usr/lib/swift_static -O)
  # The shared runtime (D124): the archives above linked into lib<name>.so
  # (tools/toolchain/link_shared.sh), after FoundationEssentials, below.
  set(_shared ${_out}/shared)
  set(_shared_names swiftCore swift_Builtin_float swiftSynchronization swift_Concurrency swift_RegexParser
      swift_StringProcessing swiftRegexBuilder swiftObservation swiftVectraOSLibc swiftSwiftOnoneSupport
      _FoundationCShims _FoundationCollections FoundationEssentials)
  set(_shared_libs)
  set(_shared_entries)
  foreach(_n ${_shared_names})
    list(APPEND _shared_libs ${_shared}/lib${_n}.so)
    list(APPEND _shared_entries lib/lib${_n}.so=${_shared}/lib${_n}.so)
  endforeach()
  #   croi_tier1_dynamic(NAME SOURCES <swift>... [FLAGS <swiftc flags>...] [LIBS <lib.so>...] [LINK <inputs>...]
  #                      [DEPENDS <files>...])
  # A full Swift program linked against the shared runtime (D124): swiftc
  # compiles it to one object; ld.lld links it as clang's VectraOS
  # toolchain links a static one (fixed address, _start, the floor, the
  # libc and libc++ from the sysroot), but with the shared libraries its
  # object autolinks, a note of their builds (vx library-note) and no
  # interpreter: the process that starts it loads and binds them
  # (linkmap(6)). LIBS: tier 1's own shared libraries it uses
  # (croi_tier1_library's), noted too; LINK: more inputs, such as static
  # libraries.
  function(croi_tier1_dynamic name)
    cmake_parse_arguments(D "" "" "SOURCES;FLAGS;LIBS;LINK;DEPENDS" ${ARGN})
    set(_o ${_out}/${name}.dir)
    add_custom_command(OUTPUT ${_out}/${name}
      COMMAND ${CMAKE_COMMAND} -E make_directory ${_o}
      COMMAND ${_swiftc} -wmo -c ${D_FLAGS} ${D_SOURCES} -o ${_o}/${name}.o
      COMMAND ${_toolchain_bin}/swift-autolink-extract ${_o}/${name}.o -o ${_o}/autolink
      COMMAND ${VX} library-note ${_o}/libraries.c ${D_LIBS} ${_shared_libs}
      COMMAND ${_clang} -c ${_o}/libraries.c -o ${_o}/libraries.o
      COMMAND ${_toolchain_bin}/ld.lld --build-id=sha1 -z max-page-size=0x1000 -z noexecstack -z now --eh-frame-hdr
              --no-dynamic-linker -e _start --image-base=0x1000000 -z separate-loadable-segments -z stack-size=262144
              --gc-sections --as-needed ${_static}/swiftrt.o ${_o}/${name}.o ${_o}/libraries.o ${D_LINK} ${D_LIBS}
              -L${_shared} @${_o}/autolink -L${_builtins_dir} -L${_sysroot}/usr/lib
              -lc++ -lc++abi -lunwind --start-group -lsys -lc -lm --end-group -lclang_rt.builtins -o ${_out}/${name}
      DEPENDS swift-shared vx ${_shared_libs} ${D_SOURCES} ${D_LIBS} ${D_DEPENDS} ${_sysroot}/usr/lib/libsys.a
      COMMENT "${name}, linked against the shared Swift runtime")
  endfunction()
  get_filename_component(_builtins_dir ${_builtins} DIRECTORY)
  add_custom_command(OUTPUT ${_out}/hello/libInventory.a ${_out}/hello/Inventory.swiftmodule
    COMMAND ${CMAKE_COMMAND} -E make_directory ${_out}/hello
    COMMAND ${_swiftc} -parse-as-library -emit-library -static -emit-module -module-name Inventory
            ${_src}/Inventory.swift -o ${_out}/hello/libInventory.a -emit-module-path ${_out}/hello/Inventory.swiftmodule
    DEPENDS swift-stdlib ${_swift_core} ${_src}/Inventory.swift
    COMMENT "swift-hello's Inventory module, by the *-vectraos swiftc")
  croi_tier1_dynamic(swift-hello SOURCES ${_src}/Main.swift FLAGS -I ${_out}/hello
                     LINK ${_out}/hello/libInventory.a DEPENDS ${_out}/hello/libInventory.a)
  add_custom_command(OUTPUT ${_out}/swift-start
    COMMAND ${_swiftc} -parse-as-library ${_src}/Start.swift -o ${_out}/swift-start
    DEPENDS swift-stdlib ${_swift_core} ${_src}/Start.swift ${_sysroot}/usr/lib/libsys.a
    COMMENT "swift-start, the smallest full Swift program")
  croi_tier1_dynamic(swift-async SOURCES ${_src}/Async.swift FLAGS -parse-as-library)
  # FoundationEssentials (tools/toolchain/build_foundation.sh, after the
  # stdlib, into the same place), then foundation-test.
  set(_foundation ${_static}/libFoundationEssentials.a ${_static}/lib_FoundationCShims.a
      ${_static}/lib_FoundationCollections.a)
  add_custom_target(swift-foundation ALL
    COMMAND ${PROJECT_SOURCE_DIR}/tools/toolchain/build_foundation.sh ${_machine}
    BYPRODUCTS ${_foundation}
    DEPENDS swift-stdlib
    COMMENT "Tier 1's FoundationEssentials (tools/toolchain/build_foundation.sh)")
  add_custom_target(swift-shared ALL
    COMMAND ${PROJECT_SOURCE_DIR}/tools/toolchain/link_shared.sh ${_machine} ${_shared}
    BYPRODUCTS ${_shared_libs}
    DEPENDS swift-foundation vx
    COMMENT "Tier 1's shared runtime (tools/toolchain/link_shared.sh)")
  croi_tier1_dynamic(foundation-test SOURCES ${_src}/Foundation.swift FLAGS -parse-as-library)
  # Tier 0's libraries for tier 1 (V2's item 6: rc and FDIO are tier 1):
  # each built by the *-vectraos swiftc into tier1/lib (its module and
  # archive), after those it uses, from the same sources as tier 0's.
  set(_lib ${_out}/lib)
  function(croi_tier1_library name)
    cmake_parse_arguments(T "" "" "SOURCES;USES;INCLUDES;CSOURCES" ${ARGN})
    # C sources: by the *-vectraos clang, into the same archive.
    set(_c_steps)
    foreach(_c ${T_CSOURCES})
      get_filename_component(_stem ${_c} NAME_WE)
      list(APPEND _c_steps
        COMMAND ${_clang} -ffunction-sections -fPIC -ftls-model=initial-exec -c ${PROJECT_SOURCE_DIR}/${_c}
                -o ${_lib}/${name}-${_stem}.o
        COMMAND ${_toolchain_bin}/llvm-ar r ${_lib}/lib${name}.a ${_lib}/${name}-${_stem}.o)
    endforeach()
    list(TRANSFORM T_CSOURCES PREPEND ${PROJECT_SOURCE_DIR}/)
    list(TRANSFORM T_INCLUDES PREPEND -I${PROJECT_SOURCE_DIR}/)
    list(TRANSFORM T_SOURCES PREPEND ${PROJECT_SOURCE_DIR}/)
    set(_uses ${T_USES})
    list(TRANSFORM _uses PREPEND ${_lib}/)
    list(TRANSFORM _uses APPEND .swiftmodule)
    add_custom_command(OUTPUT ${_lib}/lib${name}.a ${_lib}/${name}.swiftmodule
      COMMAND ${CMAKE_COMMAND} -E make_directory ${_lib}
      COMMAND ${_swiftc} -parse-as-library -wmo -strict-memory-safety -enable-experimental-feature Lifetimes
              -I ${_lib} ${T_INCLUDES} -load-plugin-executable "${CROI_IPC_PLUGIN}\#IPCMacros"
              -emit-library -static -emit-module -module-name ${name} -emit-module-path ${_lib}/${name}.swiftmodule
              -o ${_lib}/lib${name}.a ${T_SOURCES}
      ${_c_steps}
      # swiftc keeps an unchanged module's time, but -O inlines across
      # modules: what uses this library is rebuilt whenever it is.
      COMMAND ${CMAKE_COMMAND} -E touch ${_lib}/${name}.swiftmodule
      DEPENDS swift-stdlib ${_swift_core} ${T_SOURCES} ${T_CSOURCES} ${_uses} ${_sysroot}/usr/lib/libsys.a ${CROI_IPC_PLUGIN}
      COMMENT "${name} for tier 1, by the *-vectraos swiftc")
    # And shared (D124): the archive whole, with swiftrt.o, needing the
    # libraries it uses and the standard library's it autolinks, and
    # noting their builds.
    set(_needs ${T_USES})
    list(TRANSFORM _needs PREPEND ${_lib}/lib)
    list(TRANSFORM _needs APPEND .so)
    add_custom_command(OUTPUT ${_lib}/lib${name}.so
      COMMAND ${_toolchain_bin}/swift-autolink-extract ${_lib}/lib${name}.a -o ${_lib}/${name}.autolink
      COMMAND ${VX} library-note ${_lib}/${name}-libraries.c ${_needs} ${_shared_libs}
      COMMAND ${_clang} -c ${_lib}/${name}-libraries.c -o ${_lib}/${name}-libraries.o
      COMMAND ${_toolchain_bin}/ld.lld -shared -soname lib${name}.so --build-id=sha1 -z max-page-size=0x1000
              -z separate-loadable-segments -z noexecstack -z now -z text --eh-frame-hdr --as-needed ${_static}/swiftrt.o
              --whole-archive ${_lib}/lib${name}.a --no-whole-archive ${_lib}/${name}-libraries.o ${_needs}
              -L${_shared} @${_lib}/${name}.autolink -o ${_lib}/lib${name}.so
      DEPENDS ${_lib}/lib${name}.a ${_needs} swift-shared vx ${_shared_libs}
      COMMENT "lib${name}.so for tier 1")
  endfunction()
  set(_sys system/sys)
  croi_tier1_library(SysABI SOURCES ${_sys}/abi/Values.swift)
  croi_tier1_library(Loader SOURCES lib/elf/Elf/ElfImage.swift user/lib/loader/Bootfs.swift
                                    user/lib/loader/Segments.swift user/lib/loader/Program.swift
                                    system/ld/lib/Dynamic.swift system/ld/lib/Link.swift
                                    user/lib/loader/Linked.swift)
  croi_tier1_library(Ring SOURCES lib/ring/Ring/Ring.swift lib/ring/Ring/RingMemory.swift)
  croi_tier1_library(Sys SOURCES ${_sys}/api/Handles.swift ${_sys}/api/Lock.swift ${_sys}/api/Objects.swift
                                 ${_sys}/api/Startup.swift ${_sys}/backend/native/Kernel.swift
                                 ${_sys}/backend/native/Loader.swift ${_sys}/backend/native/UTC.swift
                                 ${_sys}/backend/native/Stdio.swift
                     USES SysABI Loader Ring)
  croi_tier1_library(TraceFormat SOURCES system/trace/format/Format.swift)
  croi_tier1_library(Trace SOURCES system/trace/writer/Trace.swift system/trace/writer/native/Region.swift
                     USES TraceFormat Ring Sys INCLUDES system/trace/c/include)
  file(GLOB _ipc_wire_t1 RELATIVE ${PROJECT_SOURCE_DIR} CONFIGURE_DEPENDS ${PROJECT_SOURCE_DIR}/system/ipc/wire/*.swift)
  file(GLOB _ipc_t1 RELATIVE ${PROJECT_SOURCE_DIR} CONFIGURE_DEPENDS ${PROJECT_SOURCE_DIR}/system/ipc/runtime/*.swift)
  file(GLOB _node_t1 RELATIVE ${PROJECT_SOURCE_DIR} CONFIGURE_DEPENDS ${PROJECT_SOURCE_DIR}/system/node/lib/*.swift)
  file(GLOB _directives_t1 RELATIVE ${PROJECT_SOURCE_DIR} CONFIGURE_DEPENDS ${PROJECT_SOURCE_DIR}/system/directives/lib/*.swift)
  file(GLOB _launch_t1 RELATIVE ${PROJECT_SOURCE_DIR} CONFIGURE_DEPENDS ${PROJECT_SOURCE_DIR}/system/launch/lib/*.swift)
  croi_tier1_library(IPCWire SOURCES ${_ipc_wire_t1})
  croi_tier1_library(IPC SOURCES ${_ipc_t1} USES IPCWire Sys Trace INCLUDES system/trace/c/include)
  croi_tier1_library(Node SOURCES ${_node_t1} USES IPC Ring INCLUDES system/trace/c/include)
  croi_tier1_library(Directives SOURCES ${_directives_t1})
  croi_tier1_library(Launch SOURCES ${_launch_t1} USES Directives Node INCLUDES system/trace/c/include)
  # FDIO (system/fdio): POSIX's files over the namespace, the fs protocol's
  # client side with it (services/fs).
  croi_tier1_library(Fs SOURCES services/fs/lib/Fs.swift services/fs/lib/Client.swift services/fs/lib/Listing.swift
                     USES Node INCLUDES system/trace/c/include)
  croi_tier1_library(Settings SOURCES system/settings/lib/Settings.swift
                     USES Fs IPC Node Sys INCLUDES system/trace/c/include)
  croi_tier1_library(FDIO SOURCES system/fdio/lib/FDIO.swift system/fdio/lib/Walk.swift
                                  system/fdio/native/Startup.swift system/fdio/native/Exports.swift
                                  system/fdio/native/Fts.swift
                     CSOURCES system/fdio/native/open.c system/fdio/native/nftw.c
                     USES Fs Node INCLUDES system/trace/c/include)
  # The desktop's libraries (D107): the text stack, the theme, UICore,
  # Radharc's protocol, the plumber's messages and the SDK, from the same
  # sources as tier 0's; then Kit, its platform and its sample.
  file(GLOB_RECURSE _unicode_t1 RELATIVE ${PROJECT_SOURCE_DIR} CONFIGURE_DEPENDS ${PROJECT_SOURCE_DIR}/text/unicode/lib/*.swift)
  foreach(_l opentype shape raster msdf atlas layout)
    file(GLOB _${_l}_t1 RELATIVE ${PROJECT_SOURCE_DIR} CONFIGURE_DEPENDS ${PROJECT_SOURCE_DIR}/text/${_l}/lib/*.swift)
  endforeach()
  file(GLOB _light_t1 RELATIVE ${PROJECT_SOURCE_DIR} CONFIGURE_DEPENDS ${PROJECT_SOURCE_DIR}/ui/light/lib/*.swift)
  file(GLOB _pixelkernels_t1 RELATIVE ${PROJECT_SOURCE_DIR} CONFIGURE_DEPENDS ${PROJECT_SOURCE_DIR}/ui/kernels/lib/*.swift)
  file(GLOB _ndbfile_t1 RELATIVE ${PROJECT_SOURCE_DIR} CONFIGURE_DEPENDS ${PROJECT_SOURCE_DIR}/system/ndb/lib/*.swift)
  file(GLOB _themes_t1 RELATIVE ${PROJECT_SOURCE_DIR} CONFIGURE_DEPENDS ${PROJECT_SOURCE_DIR}/ui/theme/lib/*.swift)
  file(GLOB _accesstree_t1 RELATIVE ${PROJECT_SOURCE_DIR} CONFIGURE_DEPENDS ${PROJECT_SOURCE_DIR}/ui/access/lib/*.swift)
  file(GLOB_RECURSE _uicore_t1 RELATIVE ${PROJECT_SOURCE_DIR} CONFIGURE_DEPENDS ${PROJECT_SOURCE_DIR}/ui/core/lib/*.swift)
  file(GLOB _kbdfs_t1 RELATIVE ${PROJECT_SOURCE_DIR} CONFIGURE_DEPENDS ${PROJECT_SOURCE_DIR}/services/kbdfs/lib/*.swift)
  file(GLOB _radharc_t1 RELATIVE ${PROJECT_SOURCE_DIR} CONFIGURE_DEPENDS ${PROJECT_SOURCE_DIR}/services/radharc/lib/*.swift)
  file(GLOB _plumber_t1 RELATIVE ${PROJECT_SOURCE_DIR} CONFIGURE_DEPENDS ${PROJECT_SOURCE_DIR}/services/plumber/lib/*.swift)
  file(GLOB _vx_t1 RELATIVE ${PROJECT_SOURCE_DIR} CONFIGURE_DEPENDS ${PROJECT_SOURCE_DIR}/sdk/core/*.swift
       ${PROJECT_SOURCE_DIR}/sdk/native/*.swift)
  croi_tier1_library(TDUnicode SOURCES ${_unicode_t1})
  croi_tier1_library(OpenType SOURCES ${_opentype_t1})
  croi_tier1_library(Shape SOURCES ${_shape_t1} USES OpenType TDUnicode)
  croi_tier1_library(Raster SOURCES ${_raster_t1} USES OpenType)
  croi_tier1_library(MSDF SOURCES ${_msdf_t1} USES OpenType)
  croi_tier1_library(GlyphAtlas SOURCES ${_atlas_t1} USES MSDF Raster OpenType)
  croi_tier1_library(Light SOURCES ${_light_t1})
  croi_tier1_library(PixelKernels SOURCES ${_pixelkernels_t1} USES Light)
  croi_tier1_library(TextLayout SOURCES ${_layout_t1} USES GlyphAtlas MSDF Shape OpenType TDUnicode Light PixelKernels)
  croi_tier1_library(NdbFile SOURCES ${_ndbfile_t1})
  croi_tier1_library(Themes SOURCES ${_themes_t1} USES NdbFile)
  croi_tier1_library(AccessTree SOURCES ${_accesstree_t1})
  croi_tier1_library(UICore SOURCES ${_uicore_t1} USES AccessTree Themes Light PixelKernels Raster TextLayout GlyphAtlas MSDF
                                                    Shape OpenType TDUnicode)
  croi_tier1_library(Kbdfs SOURCES ${_kbdfs_t1} USES TDUnicode)
  croi_tier1_library(Radharc SOURCES ${_radharc_t1} USES Themes Light PixelKernels Kbdfs NdbFile TDUnicode IPC Node Ring UICore TextLayout
                     INCLUDES system/trace/c/include)
  croi_tier1_library(Plumber SOURCES ${_plumber_t1})
  croi_tier1_library(VX SOURCES ${_vx_t1} USES Plumber Radharc Themes IPC Node Sys Trace INCLUDES system/trace/c/include)
  file(GLOB_RECURSE _codecs_t1 RELATIVE ${PROJECT_SOURCE_DIR} CONFIGURE_DEPENDS ${PROJECT_SOURCE_DIR}/codecs/lib/*.swift)
  croi_tier1_library(Codecs SOURCES ${_codecs_t1} USES Directives)
  set(_t1_libs SysABI Loader Ring Sys TraceFormat Trace IPCWire IPC Node Directives Codecs Launch Fs Settings FDIO)
  # Tier 1's libraries shared (D124): what its programs link against, all
  # in bootfs's lib/. But FDIO: it gives the libc's file calls (write,
  # read, fstat...), whose weak defaults in the floor and the libc it
  # replaces, and a program's own definitions come first, so it links
  # into each program with the libc (_fdio), as it did when everything was
  # static: a program's descriptors, the rings its starter gives
  # included, are FDIO's.
  set(_fdio LINK ${_lib}/libFDIO.a DEPENDS ${_lib}/libFDIO.a)
  set(_t1_shared_libs ${_t1_libs})
  list(REMOVE_ITEM _t1_shared_libs FDIO)
  set(_t1_so ${_t1_shared_libs})
  list(TRANSFORM _t1_so PREPEND ${_lib}/lib)
  list(TRANSFORM _t1_so APPEND .so)
  # node-test, as full Swift: what bin/node-test checks, on tier 1's
  # builds of Sys, IPC (its macro's code), Node and the rings.
  set(_t1_flags -I ${_lib} -I ${PROJECT_SOURCE_DIR}/system/trace/c/include -load-plugin-executable "${CROI_IPC_PLUGIN}\#IPCMacros")
  croi_tier1_dynamic(node-test-t1 SOURCES ${PROJECT_SOURCE_DIR}/system/node/tests/native/Main.swift
                     FLAGS -parse-as-library -strict-memory-safety -enable-experimental-feature Lifetimes ${_t1_flags}
                     LIBS ${_t1_so})
  # fdio-test: FDIO's C names and the libc's stdio over a tree.
  croi_tier1_dynamic(fdio-test SOURCES ${PROJECT_SOURCE_DIR}/system/fdio/tests/native/Main.swift
                     FLAGS -parse-as-library -enable-experimental-feature Extern ${_t1_flags} LIBS ${_t1_so} ${_fdio})
  # rc, the shell (shell/rc), and its file commands (shell/commands): one
  # program, each command its name in bootfs. No boot tests of their own:
  # the launcher's (bin/launch-test) runs rc.
  file(GLOB _rc_t1 RELATIVE ${PROJECT_SOURCE_DIR} CONFIGURE_DEPENDS ${PROJECT_SOURCE_DIR}/shell/rc/lib/*.swift)
  croi_tier1_library(Rc SOURCES ${_rc_t1})
  file(GLOB _guide_t1 RELATIVE ${PROJECT_SOURCE_DIR} CONFIGURE_DEPENDS ${PROJECT_SOURCE_DIR}/system/guide/lib/*.swift)
  croi_tier1_library(Guide SOURCES ${_guide_t1} USES Directives)
  croi_tier1_library(Commands SOURCES shell/commands/lib/Commands.swift shell/commands/lib/ManPages.swift
                                      shell/commands/lib/Usage.swift shell/commands/lib/Processes.swift
                     USES Fs Node Guide INCLUDES system/trace/c/include)
  croi_tier1_dynamic(rc SOURCES ${PROJECT_SOURCE_DIR}/shell/rc/Main.swift ${PROJECT_SOURCE_DIR}/shell/rc/native/System.swift
                                ${PROJECT_SOURCE_DIR}/shell/rc/native/Terminal.swift
                     FLAGS -parse-as-library -enable-experimental-feature Lifetimes ${_t1_flags}
                     LIBS ${_lib}/libRc.so ${_t1_so} ${_fdio})
  croi_tier1_dynamic(commands SOURCES ${PROJECT_SOURCE_DIR}/shell/commands/Main.swift
                     FLAGS -parse-as-library ${_t1_flags}
                     LIBS ${_lib}/libCommands.so ${_lib}/libGuide.so ${_t1_so} ${_fdio})
  # The console's shell (shell/rc/shell.manifest) runs rc where it's built.
  set(_shell_entries bin/rc=${_out}/rc etc/manifests/shell.manifest=${PROJECT_SOURCE_DIR}/shell/rc/shell.manifest)
  foreach(_c ls cat mkdir rm mv cp touch man lookman sig ps kill sleep)
    list(APPEND _shell_entries bin/${_c}=${_out}/commands)
  endforeach()
  set(_programs floor-hello cxx-hello swift-hello swift-start swift-async foundation-test node-test-t1 fdio-test)
  set(_entries)
  set(_files)
  foreach(_p ${_programs})
    list(APPEND _entries bin/${_p}=${_out}/${_p})
    list(APPEND _files ${_out}/${_p})
  endforeach()
  list(APPEND _entries ${_shell_entries} ${_shared_entries})
  list(APPEND _files ${_shared_libs})
  list(APPEND _files ${_out}/rc ${_out}/commands ${PROJECT_SOURCE_DIR}/shell/rc/shell.manifest)
  # Kit (ui/kit, kit(2)): its views, its platform over the SDK, its sample;
  # and kit-test, which boot-kit boots in the desktop (kernel/CMakeLists.txt).
  croi_tier1_library(Kit SOURCES ui/kit/lib/Kit.swift USES UICore AccessTree)
  croi_tier1_library(KitSample SOURCES ui/kit/sample/Sample.swift USES Kit)
  croi_tier1_library(KitPlatform SOURCES ui/kit/platform/Run.swift USES Kit VX Kbdfs Node Sys INCLUDES system/trace/c/include)
  set(_kit_libs KitPlatform KitSample Kit VX Plumber Radharc Kbdfs UICore AccessTree Themes NdbFile TextLayout PixelKernels Light
                GlyphAtlas MSDF Raster Shape OpenType TDUnicode)
  set(_kit_so ${_kit_libs})
  list(TRANSFORM _kit_so PREPEND ${_lib}/lib)
  list(TRANSFORM _kit_so APPEND .so)
  croi_tier1_dynamic(kit-test SOURCES ${PROJECT_SOURCE_DIR}/ui/kit/tests/native/Main.swift ${_native_check}
                     FLAGS -parse-as-library ${_t1_flags} LIBS ${_kit_so} ${_t1_so} ${_fdio})
  set_property(GLOBAL PROPERTY CROI_TIER1_KIT_TEST ${_out}/kit-test)
  # rio (shell/rio, rio(1)): text windows in Radharc running rc, in the
  # desktop's images (kernel/CMakeLists.txt); rio-test, which boot-rio boots.
  # vt (shell/vt, vt(1)): TerminalCore and its screen as a Kit app, in a
  # rio window's surface; vt-test, which boot-vt boots.
  file(GLOB _rio_t1 RELATIVE ${PROJECT_SOURCE_DIR} CONFIGURE_DEPENDS ${PROJECT_SOURCE_DIR}/shell/rio/lib/*.swift)
  croi_tier1_library(Rio SOURCES ${_rio_t1} USES Kit UICore Kbdfs IPC Node TDUnicode INCLUDES system/trace/c/include)
  file(GLOB _terminal_t1 RELATIVE ${PROJECT_SOURCE_DIR} CONFIGURE_DEPENDS ${PROJECT_SOURCE_DIR}/shell/vt/core/*.swift)
  croi_tier1_library(TerminalCore SOURCES ${_terminal_t1})
  file(GLOB _terminal_app_t1 RELATIVE ${PROJECT_SOURCE_DIR} CONFIGURE_DEPENDS ${PROJECT_SOURCE_DIR}/shell/vt/app/*.swift)
  croi_tier1_library(TerminalApp SOURCES ${_terminal_app_t1} USES TerminalCore Kit UICore Kbdfs)
  file(GLOB _tracker_t1 RELATIVE ${PROJECT_SOURCE_DIR} CONFIGURE_DEPENDS ${PROJECT_SOURCE_DIR}/shell/tracker/lib/*.swift)
  croi_tier1_library(Tracker SOURCES ${_tracker_t1} USES Codecs Fs IPC Node Sys INCLUDES system/trace/c/include)
  file(GLOB _tracker_app_t1 RELATIVE ${PROJECT_SOURCE_DIR} CONFIGURE_DEPENDS ${PROJECT_SOURCE_DIR}/shell/tracker/app/*.swift)
  croi_tier1_library(TrackerApp SOURCES ${_tracker_app_t1} USES Tracker Kit UICore Node Sys INCLUDES system/trace/c/include)
  # Deskbar (shell/deskbar, deskbar(4), D114); deskbar-test, which
  # boot-deskbar boots.
  file(GLOB _deskbar_app_t1 RELATIVE ${PROJECT_SOURCE_DIR} CONFIGURE_DEPENDS ${PROJECT_SOURCE_DIR}/shell/deskbar/app/*.swift)
  croi_tier1_library(DeskbarApp SOURCES ${_deskbar_app_t1} USES Kit UICore)
  # The Settings app (D115): the preference apps and the Inspector;
  # settings-test, which boot-settings boots.
  file(GLOB _preferences_app_t1 RELATIVE ${PROJECT_SOURCE_DIR} CONFIGURE_DEPENDS
       ${PROJECT_SOURCE_DIR}/shell/preferences/app/*.swift)
  croi_tier1_library(PreferencesApp SOURCES ${_preferences_app_t1} USES Kit UICore Settings
                     INCLUDES system/trace/c/include)
  file(GLOB _inspector_app_t1 RELATIVE ${PROJECT_SOURCE_DIR} CONFIGURE_DEPENDS ${PROJECT_SOURCE_DIR}/shell/inspector/app/*.swift)
  croi_tier1_library(InspectorApp SOURCES ${_inspector_app_t1} USES Kit UICore)
  # Notices (D117): the slips and the drawer; notices-test, which
  # boot-notices boots.
  file(GLOB _notices_t1 RELATIVE ${PROJECT_SOURCE_DIR} CONFIGURE_DEPENDS ${PROJECT_SOURCE_DIR}/shell/notices/lib/*.swift)
  croi_tier1_library(Notices SOURCES ${_notices_t1} USES NdbFile)
  file(GLOB _notices_app_t1 RELATIVE ${PROJECT_SOURCE_DIR} CONFIGURE_DEPENDS ${PROJECT_SOURCE_DIR}/shell/notices/app/*.swift)
  croi_tier1_library(NoticesApp SOURCES ${_notices_app_t1} USES Notices Kit UICore)
  # guide (guide(1)): the manual as hypertext.
  file(GLOB _guide_viewer_t1 RELATIVE ${PROJECT_SOURCE_DIR} CONFIGURE_DEPENDS ${PROJECT_SOURCE_DIR}/shell/guide/lib/*.swift)
  croi_tier1_library(GuideViewer SOURCES ${_guide_viewer_t1} USES Guide Directives)
  file(GLOB _guide_app_t1 RELATIVE ${PROJECT_SOURCE_DIR} CONFIGURE_DEPENDS ${PROJECT_SOURCE_DIR}/shell/guide/app/*.swift)
  croi_tier1_library(GuideApp SOURCES ${_guide_app_t1} USES GuideViewer Guide Directives Kit UICore)
  set(_shell_programs rio:shell/rio/Main.swift rio-test:shell/rio/tests/native/Main.swift vt:shell/vt/Main.swift
                      vt-test:shell/vt/tests/native/Main.swift tracker:shell/tracker/Main.swift
                      tracker-test:shell/tracker/tests/native/Main.swift deskbar:shell/deskbar/Main.swift
                      deskbar-test:shell/deskbar/tests/native/Main.swift preferences:shell/preferences/Main.swift
                      inspector:shell/inspector/Main.swift settings-test:shell/preferences/tests/native/Main.swift
                      notices:shell/notices/Main.swift notices-test:shell/notices/tests/native/Main.swift
                      guide:shell/guide/Main.swift)
  # The shell's apps, each against the libraries the apps share.
  set(_app_so GuideApp GuideViewer Guide NoticesApp Notices PreferencesApp InspectorApp DeskbarApp TrackerApp Tracker
              TerminalApp TerminalCore Rio)
  list(TRANSFORM _app_so PREPEND ${_lib}/lib)
  list(TRANSFORM _app_so APPEND .so)
  set(_shell_outputs)
  foreach(_entry ${_shell_programs})
    string(REPLACE ":" ";" _pair ${_entry})
    list(GET _pair 0 _p)
    list(GET _pair 1 _main)
    set(_check)
    if(_p MATCHES "-test$")
      set(_check ${_native_check})
    endif()
    croi_tier1_dynamic(${_p} SOURCES ${PROJECT_SOURCE_DIR}/${_main} ${_check} FLAGS -parse-as-library ${_t1_flags}
                       LIBS ${_app_so} ${_kit_so} ${_t1_so} ${_fdio})
    list(APPEND _shell_outputs ${_out}/${_p})
  endforeach()
  # Every library tier 1 built, shared, in bootfs's lib/.
  foreach(_so ${_t1_so} ${_kit_so} ${_app_so} ${_lib}/libRc.so ${_lib}/libCommands.so)
    get_filename_component(_n ${_so} NAME)
    set_property(GLOBAL APPEND PROPERTY CROI_TIER1_SHARED lib/${_n}=${_so})
    set_property(GLOBAL APPEND PROPERTY CROI_TIER1_SHARED_FILES ${_so})
  endforeach()
  set_property(GLOBAL PROPERTY CROI_TIER1_RIO ${_out}/rio)
  set_property(GLOBAL PROPERTY CROI_TIER1_RIO_TEST ${_out}/rio-test)
  set_property(GLOBAL PROPERTY CROI_TIER1_VT ${_out}/vt)
  set_property(GLOBAL PROPERTY CROI_TIER1_VT_TEST ${_out}/vt-test)
  set_property(GLOBAL PROPERTY CROI_TIER1_TRACKER ${_out}/tracker)
  set_property(GLOBAL PROPERTY CROI_TIER1_TRACKER_TEST ${_out}/tracker-test)
  set_property(GLOBAL PROPERTY CROI_TIER1_DESKBAR ${_out}/deskbar)
  set_property(GLOBAL PROPERTY CROI_TIER1_DESKBAR_TEST ${_out}/deskbar-test)
  set_property(GLOBAL PROPERTY CROI_TIER1_PREFERENCES ${_out}/preferences)
  set_property(GLOBAL PROPERTY CROI_TIER1_INSPECTOR ${_out}/inspector)
  set_property(GLOBAL PROPERTY CROI_TIER1_SETTINGS_TEST ${_out}/settings-test)
  set_property(GLOBAL PROPERTY CROI_TIER1_NOTICES ${_out}/notices)
  set_property(GLOBAL PROPERTY CROI_TIER1_NOTICES_TEST ${_out}/notices-test)
  set_property(GLOBAL PROPERTY CROI_TIER1_GUIDE ${_out}/guide)
  get_property(_t1_shared GLOBAL PROPERTY CROI_TIER1_SHARED)
  get_property(_t1_shared_files GLOBAL PROPERTY CROI_TIER1_SHARED_FILES)
  list(REMOVE_DUPLICATES _t1_shared)
  list(REMOVE_DUPLICATES _t1_shared_files)
  list(APPEND _entries ${_t1_shared})
  list(APPEND _files ${_t1_shared_files})
  add_custom_target(tier1 ALL DEPENDS ${_files} ${_out}/kit-test ${_shell_outputs})
  set(${bootfs_var} ${_entries} PARENT_SCOPE)
  set(${depends_var} ${_files} PARENT_SCOPE)
  # The top level boots each (CMakeLists.txt).
  set_property(GLOBAL PROPERTY CROI_TIER1_PROGRAMS ${_programs})
endfunction()
