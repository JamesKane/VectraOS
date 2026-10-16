# Tier 1 (D47): programs in C, C++ and full Swift, built by the
# *-vectraos toolchain (tools/toolchain: clang, lld and swiftc from the
# pinned Swift 6.4.0 sources with the series) against tier 1's sysroot,
# build/<arch>/sysroot: the floor as libsys.a, the libc as libc.a, the
# libc's headers and the floor's C interface (cmake/sysroot.cmake);
# libc++, libc++abi and libunwind (cmake/cxx.cmake); the Swift runtime and
# standard library (tools/toolchain/build_stdlib.sh). amd64 only so far:
# the other machines need compiler-rt's builtins built for them.
#
#   croi_tier1(BOOTFS_VAR DEPENDS_VAR)
# Sets BOOTFS_VAR to the bootfs entries (bin/NAME=FILE) of tier 1's test
# programs and DEPENDS_VAR to their files; both empty when the toolchain
# hasn't been built (.cache/toolchain/out/bin/swiftc) or the arch has no
# tier 1 yet.

include(${PROJECT_SOURCE_DIR}/cmake/cxx.cmake)

function(croi_tier1 bootfs_var depends_var)
  set(${bootfs_var} "" PARENT_SCOPE)
  set(${depends_var} "" PARENT_SCOPE)
  set(_toolchain_bin ${PROJECT_SOURCE_DIR}/.cache/toolchain/out/bin)
  set(_builtins ${CROI_TOOLCHAIN_DIR}/usr/lib/clang/21/lib/linux/libclang_rt.builtins-x86_64.a)
  if(NOT CROI_ARCH STREQUAL amd64 OR NOT EXISTS ${_toolchain_bin}/swiftc OR NOT EXISTS ${_builtins})
    return()
  endif()
  set(_triple x86_64-unknown-vectraos)
  set(_sysroot ${CMAKE_BINARY_DIR}/sysroot)
  set(_out ${CMAKE_BINARY_DIR}/tier1)
  set(_src ${PROJECT_SOURCE_DIR}/user/tier1)
  set(_floor_include ${PROJECT_SOURCE_DIR}/system/sys/floor/include)
  file(GLOB _libc_headers CONFIGURE_DEPENDS ${PROJECT_SOURCE_DIR}/system/libc/include/*.h
       ${PROJECT_SOURCE_DIR}/system/libc/include/*/*.h ${PROJECT_SOURCE_DIR}/system/libc/include/module.modulemap)

  # The sysroot: the floor (fixed-address, as tier 1 links ET_EXEC), the libc.
  add_custom_command(OUTPUT ${_sysroot}/usr/lib/libsys.a ${_sysroot}/usr/lib/libc.a
    COMMAND ${CMAKE_COMMAND} -DFLOOR=${CROI_USER_FLOOR} -DLIBC=${CROI_USER_LIBC} -DBUILTINS=${_builtins}
            -DHEADERS=${PROJECT_SOURCE_DIR}/system/libc/include -DFLOOR_HEADER=${_floor_include}/td_floor.h
            -DCROI_HEADERS=${PROJECT_SOURCE_DIR}/user/include/croi -DKERNEL_HEADERS=${PROJECT_SOURCE_DIR}/kernel/include
            -DOBJCOPY=${CMAKE_OBJCOPY} -DAR=${CMAKE_AR} -DOUT=${_sysroot} -P ${PROJECT_SOURCE_DIR}/cmake/sysroot.cmake
    DEPENDS ${CROI_USER_FLOOR} ${CROI_USER_LIBC} ${PROJECT_SOURCE_DIR}/cmake/sysroot.cmake ${_libc_headers}
            ${PROJECT_SOURCE_DIR}/user/include/croi/syscall.h ${PROJECT_SOURCE_DIR}/kernel/include/module.modulemap
            ${_floor_include}/td_floor.h
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
  set(_static ${_sysroot}/usr/lib/swift_static/vectraos/x86_64)
  set(_swift_core ${_static}/libswiftCore.a ${_static}/libswift_Concurrency.a ${_static}/libswiftSynchronization.a)
  add_custom_target(swift-stdlib ALL
    COMMAND ${PROJECT_SOURCE_DIR}/tools/toolchain/build_stdlib.sh x86_64
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
    COMMAND ${_swiftc} -parse-as-library -I ${_floor_include} -I ${PROJECT_SOURCE_DIR}/user/include
            -I ${PROJECT_SOURCE_DIR}/kernel/include ${_src}/Async.swift -o ${_out}/swift-async
    DEPENDS swift-stdlib ${_swift_core} ${_src}/Async.swift ${_sysroot}/usr/lib/libsys.a
    COMMENT "swift-async, Swift concurrency on croi")
  set(_programs floor-hello cxx-hello swift-hello swift-start swift-async)
  set(_entries)
  set(_files)
  foreach(_p ${_programs})
    list(APPEND _entries bin/${_p}=${_out}/${_p})
    list(APPEND _files ${_out}/${_p})
  endforeach()
  add_custom_target(tier1 ALL DEPENDS ${_files})
  set(${bootfs_var} ${_entries} PARENT_SCOPE)
  set(${depends_var} ${_files} PARENT_SCOPE)
endfunction()
