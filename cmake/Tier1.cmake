# Tier 1 (D47): programs in C, C++ and full Swift, built by the
# *-vectraos toolchain (tools/toolchain: clang, lld and swiftc from the
# pinned Swift 6.4.0 sources with the series) against tier 1's sysroot,
# build/<arch>/sysroot: the floor as libsys.a, the libc as libc.a, the
# libc's headers and the floor's C interface (cmake/sysroot.cmake);
# libc++, libc++abi and libunwind (cmake/cxx.cmake); the Swift runtime and
# standard library (tools/toolchain/build_stdlib.sh) and FoundationEssentials
# (build_foundation.sh), with compiler-rt's builtins (build_builtins.sh).
# amd64 and arm64 so far: riscv64 waits for Swift's calling conventions in
# its LLVM.
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
  # Not riscv64 yet: its LLVM has no Swift calling conventions (clang
  # rejects swiftcall, which the runtime's C++ uses; no guaranteed tail
  # calls for swifttailcc), docs/roadmap.md.
  if(_machine STREQUAL riscv64 OR NOT EXISTS ${_toolchain_bin}/swiftc OR NOT EXISTS ${_builtins})
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
  add_custom_command(OUTPUT ${_out}/hello/libInventory.a ${_out}/hello/Inventory.swiftmodule
    COMMAND ${CMAKE_COMMAND} -E make_directory ${_out}/hello
    COMMAND ${_swiftc} -parse-as-library -emit-library -static -emit-module -module-name Inventory
            ${_src}/Inventory.swift -o ${_out}/hello/libInventory.a -emit-module-path ${_out}/hello/Inventory.swiftmodule
    DEPENDS swift-stdlib ${_swift_core} ${_src}/Inventory.swift
    COMMENT "swift-hello's Inventory module, by the *-vectraos swiftc")
  add_custom_command(OUTPUT ${_out}/swift-hello
    COMMAND ${_swiftc} -I ${_out}/hello -L ${_out}/hello -lInventory ${_src}/Main.swift -o ${_out}/swift-hello
    DEPENDS ${_out}/hello/libInventory.a ${_src}/Main.swift ${_sysroot}/usr/lib/libsys.a
    COMMENT "swift-hello, full Swift by the *-vectraos swiftc")
  add_custom_command(OUTPUT ${_out}/swift-start
    COMMAND ${_swiftc} -parse-as-library ${_src}/Start.swift -o ${_out}/swift-start
    DEPENDS swift-stdlib ${_swift_core} ${_src}/Start.swift ${_sysroot}/usr/lib/libsys.a
    COMMENT "swift-start, the smallest full Swift program")
  add_custom_command(OUTPUT ${_out}/swift-async
    COMMAND ${_swiftc} -parse-as-library ${_src}/Async.swift -o ${_out}/swift-async
    DEPENDS swift-stdlib ${_swift_core} ${_src}/Async.swift ${_sysroot}/usr/lib/libsys.a
    COMMENT "swift-async, Swift concurrency on croi")
  # FoundationEssentials (tools/toolchain/build_foundation.sh, after the
  # stdlib, into the same place), then foundation-test.
  set(_foundation ${_static}/libFoundationEssentials.a ${_static}/lib_FoundationCShims.a
      ${_static}/lib_FoundationCollections.a)
  add_custom_target(swift-foundation ALL
    COMMAND ${PROJECT_SOURCE_DIR}/tools/toolchain/build_foundation.sh ${_machine}
    BYPRODUCTS ${_foundation}
    DEPENDS swift-stdlib
    COMMENT "Tier 1's FoundationEssentials (tools/toolchain/build_foundation.sh)")
  add_custom_command(OUTPUT ${_out}/foundation-test
    COMMAND ${_swiftc} -parse-as-library ${_src}/Foundation.swift -o ${_out}/foundation-test
    DEPENDS swift-foundation ${_foundation} ${_src}/Foundation.swift ${_sysroot}/usr/lib/libsys.a
    COMMENT "foundation-test, FoundationEssentials on croi")
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
        COMMAND ${_clang} -ffunction-sections -c ${PROJECT_SOURCE_DIR}/${_c} -o ${_lib}/${name}-${_stem}.o
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
  endfunction()
  set(_sys system/sys)
  croi_tier1_library(SysABI SOURCES ${_sys}/abi/Values.swift)
  croi_tier1_library(Loader SOURCES lib/elf/Elf/ElfImage.swift user/lib/loader/Bootfs.swift
                                    user/lib/loader/Segments.swift user/lib/loader/Program.swift)
  croi_tier1_library(Ring SOURCES lib/ring/Ring/Ring.swift lib/ring/Ring/RingMemory.swift)
  croi_tier1_library(Sys SOURCES ${_sys}/api/Handles.swift ${_sys}/api/Lock.swift ${_sys}/api/Objects.swift
                                 ${_sys}/api/Startup.swift ${_sys}/backend/native/Kernel.swift
                                 ${_sys}/backend/native/Loader.swift ${_sys}/backend/native/UTC.swift
                                 ${_sys}/backend/native/Stdio.swift
                     USES SysABI Loader Ring)
  croi_tier1_library(LibSys SOURCES ${_sys}/native/Start.swift USES Sys)
  croi_tier1_library(TraceFormat SOURCES system/trace/format/Format.swift)
  croi_tier1_library(Trace SOURCES system/trace/writer/Trace.swift system/trace/writer/native/Region.swift
                     USES TraceFormat Ring Sys LibSys INCLUDES system/trace/c/include)
  file(GLOB _ipc_wire_t1 RELATIVE ${PROJECT_SOURCE_DIR} CONFIGURE_DEPENDS ${PROJECT_SOURCE_DIR}/system/ipc/wire/*.swift)
  file(GLOB _ipc_t1 RELATIVE ${PROJECT_SOURCE_DIR} CONFIGURE_DEPENDS ${PROJECT_SOURCE_DIR}/system/ipc/runtime/*.swift)
  file(GLOB _node_t1 RELATIVE ${PROJECT_SOURCE_DIR} CONFIGURE_DEPENDS ${PROJECT_SOURCE_DIR}/system/node/lib/*.swift)
  file(GLOB _launch_t1 RELATIVE ${PROJECT_SOURCE_DIR} CONFIGURE_DEPENDS ${PROJECT_SOURCE_DIR}/system/launch/lib/*.swift)
  croi_tier1_library(IPCWire SOURCES ${_ipc_wire_t1})
  croi_tier1_library(IPC SOURCES ${_ipc_t1} USES IPCWire Sys Trace INCLUDES system/trace/c/include)
  croi_tier1_library(Node SOURCES ${_node_t1} USES IPC Ring INCLUDES system/trace/c/include)
  croi_tier1_library(Launch SOURCES ${_launch_t1} USES Node INCLUDES system/trace/c/include)
  # FDIO (system/fdio): POSIX's files over the namespace, the fs protocol's
  # client side with it (services/fs).
  croi_tier1_library(Fs SOURCES services/fs/lib/Fs.swift services/fs/lib/Client.swift services/fs/lib/Listing.swift
                     USES Node INCLUDES system/trace/c/include)
  croi_tier1_library(FDIO SOURCES system/fdio/lib/FDIO.swift system/fdio/lib/Walk.swift
                                  system/fdio/native/Startup.swift system/fdio/native/Exports.swift
                                  system/fdio/native/Fts.swift
                     CSOURCES system/fdio/native/open.c
                     USES Fs Node INCLUDES system/trace/c/include)
  set(_t1_libs SysABI Loader Ring Sys LibSys TraceFormat Trace IPCWire IPC Node Launch Fs FDIO)
  set(_t1_archives ${_t1_libs})
  list(TRANSFORM _t1_archives PREPEND ${_lib}/lib)
  list(TRANSFORM _t1_archives APPEND .a)
  set(_t1_link ${_t1_libs})
  list(REVERSE _t1_link)
  list(TRANSFORM _t1_link PREPEND -l)
  # node-test, as full Swift: what bin/node-test checks, on tier 1's
  # builds of Sys, IPC (its macro's code), Node and the rings.
  add_custom_command(OUTPUT ${_out}/node-test-t1
    COMMAND ${_swiftc} -parse-as-library -strict-memory-safety -enable-experimental-feature Lifetimes
            -I ${_lib} -I ${PROJECT_SOURCE_DIR}/system/trace/c/include -L ${_lib} ${_t1_link}
            -load-plugin-executable "${CROI_IPC_PLUGIN}\#IPCMacros"
            ${PROJECT_SOURCE_DIR}/system/node/tests/native/Main.swift -o ${_out}/node-test-t1
    DEPENDS ${_t1_archives} ${PROJECT_SOURCE_DIR}/system/node/tests/native/Main.swift
    COMMENT "node-test for tier 1")
  # fdio-test: FDIO's C names and the libc's stdio over a tree.
  add_custom_command(OUTPUT ${_out}/fdio-test
    COMMAND ${_swiftc} -parse-as-library -I ${_lib} -I ${PROJECT_SOURCE_DIR}/system/trace/c/include -L ${_lib}
            ${_t1_link} -load-plugin-executable "${CROI_IPC_PLUGIN}\#IPCMacros"
            ${PROJECT_SOURCE_DIR}/system/fdio/tests/native/Main.swift -o ${_out}/fdio-test
    DEPENDS ${_t1_archives} ${PROJECT_SOURCE_DIR}/system/fdio/tests/native/Main.swift
    COMMENT "fdio-test, for tier 1")
  set(_programs floor-hello cxx-hello swift-hello swift-start swift-async foundation-test node-test-t1 fdio-test)
  set(_entries)
  set(_files)
  foreach(_p ${_programs})
    list(APPEND _entries bin/${_p}=${_out}/${_p})
    list(APPEND _files ${_out}/${_p})
  endforeach()
  add_custom_target(tier1 ALL DEPENDS ${_files})
  set(${bootfs_var} ${_entries} PARENT_SCOPE)
  set(${depends_var} ${_files} PARENT_SCOPE)
  # The top level boots each (CMakeLists.txt).
  set_property(GLOBAL PROPERTY CROI_TIER1_PROGRAMS ${_programs})
endfunction()
