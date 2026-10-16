# SPDX-License-Identifier: BSD-3-Clause
#
# Tier 1's C++ floor (M6d): LLVM's libc++, libc++abi and libunwind (the
# toolchain exception, principle 29), from the toolchain's llvm-project
# (.cache/toolchain/work), built static by the *-vectraos clang against our
# libc's headers in tier 1's sysroot and installed into it (its headers in
# usr/include/c++/v1, the archives in usr/lib).
#
# As far as the Swift runtime and C++ programs need them: exceptions (with
# libunwind, which finds unwind tables through dl_iterate_phdr), RTTI, and
# threads over our pthreads; no localization, wide characters, file system,
# random device, time zones or terminal, which our libc doesn't have yet;
# no dladdr (static programs have no dynamic symbol table). Their layouts
# are our libc's (std::mutex holds our pthread_mutex_t), so they're rebuilt
# whenever the sysroot's headers change: the build runs each time and ninja
# inside it decides.
#
#   croi_tier1_cxx(TRIPLE SYSROOT)   defines the target `cxx`

include(ExternalProject)

function(croi_tier1_cxx triple sysroot)
  set(_toolchain ${PROJECT_SOURCE_DIR}/.cache/toolchain)
  set(_bin ${_toolchain}/out/bin)
  # CMake's Generic platform builds no shared libraries, and turns the
  # runtimes' (excluded) shared targets into a second static archive of the
  # same name: saying it has them keeps them apart, and none is built.
  file(WRITE ${CMAKE_BINARY_DIR}/cxx-shared.cmake "set_property(GLOBAL PROPERTY TARGET_SUPPORTS_SHARED_LIBS TRUE)\n")
  ExternalProject_Add(cxx
    SOURCE_DIR ${_toolchain}/work/llvm-project/runtimes
    BINARY_DIR ${CMAKE_BINARY_DIR}/cxx
    INSTALL_DIR ${sysroot}/usr
    DEPENDS sysroot
    BUILD_ALWAYS ON
    CMAKE_GENERATOR Ninja
    LIST_SEPARATOR |
    CMAKE_ARGS
      -DCMAKE_BUILD_TYPE=Release -DCMAKE_SYSTEM_NAME=Generic -DCMAKE_SYSROOT=${sysroot}
      -DCMAKE_PROJECT_INCLUDE=${CMAKE_BINARY_DIR}/cxx-shared.cmake
      -DCMAKE_C_COMPILER=${_bin}/clang -DCMAKE_CXX_COMPILER=${_bin}/clang++ -DCMAKE_ASM_COMPILER=${_bin}/clang
      -DCMAKE_C_COMPILER_TARGET=${triple} -DCMAKE_CXX_COMPILER_TARGET=${triple} -DCMAKE_ASM_COMPILER_TARGET=${triple}
      -DCMAKE_AR=${_bin}/llvm-ar -DCMAKE_RANLIB=${_bin}/llvm-ranlib -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY
      -DCMAKE_INSTALL_PREFIX=<INSTALL_DIR>
      -DLLVM_ENABLE_RUNTIMES=libunwind|libcxx|libcxxabi -DLLVM_ENABLE_PER_TARGET_RUNTIME_DIR=OFF
      -DLIBCXX_ENABLE_SHARED=OFF -DLIBCXX_ENABLE_STATIC=ON -DLIBCXX_ENABLE_EXCEPTIONS=ON -DLIBCXX_ENABLE_RTTI=ON
      -DLIBCXX_ENABLE_THREADS=ON -DLIBCXX_HAS_PTHREAD_API=ON -DLIBCXX_HAS_PTHREAD_LIB=NO -DLIBCXX_HAS_RT_LIB=NO
      -DLIBCXX_HAS_ATOMIC_LIB=NO -DLIBCXX_ENABLE_MONOTONIC_CLOCK=ON -DLIBCXX_ENABLE_FILESYSTEM=OFF
      -DLIBCXX_ENABLE_LOCALIZATION=OFF -DLIBCXX_ENABLE_WIDE_CHARACTERS=OFF -DLIBCXX_ENABLE_UNICODE=OFF
      -DLIBCXX_ENABLE_RANDOM_DEVICE=OFF -DLIBCXX_ENABLE_TIME_ZONE_DATABASE=OFF -DLIBCXX_HAS_TERMINAL_AVAILABLE=OFF
      -DLIBCXX_CXX_ABI=libcxxabi -DLIBCXX_USE_COMPILER_RT=ON -DLIBCXX_INCLUDE_TESTS=OFF
      -DLIBCXX_INCLUDE_BENCHMARKS=OFF
      -DLIBCXXABI_ENABLE_SHARED=OFF -DLIBCXXABI_ENABLE_STATIC=ON -DLIBCXXABI_ENABLE_EXCEPTIONS=ON
      -DLIBCXXABI_ENABLE_THREADS=ON -DLIBCXXABI_HAS_PTHREAD_API=ON -DLIBCXXABI_HAS_PTHREAD_LIB=NO
      -DLIBCXXABI_USE_LLVM_UNWINDER=ON -DLIBCXXABI_ENABLE_STATIC_UNWINDER=ON -DLIBCXXABI_USE_COMPILER_RT=ON
      -DLIBCXXABI_INCLUDE_TESTS=OFF
      -DLIBUNWIND_ENABLE_SHARED=OFF -DLIBUNWIND_ENABLE_STATIC=ON -DLIBUNWIND_ENABLE_THREADS=ON
      -DLIBUNWIND_HAS_PTHREAD_LIB=NO -DLIBUNWIND_HAS_DL_LIB=NO -DLIBUNWIND_USE_COMPILER_RT=ON
      -DLIBUNWIND_INCLUDE_TESTS=OFF -DLIBUNWIND_ADDITIONAL_COMPILE_FLAGS=-D_LIBUNWIND_USE_DLADDR=0
    BUILD_COMMAND ninja cxx_static cxxabi_static unwind_static
    INSTALL_COMMAND ninja install-cxx install-cxxabi install-unwind
    USES_TERMINAL_BUILD OFF
    LOG_CONFIGURE ON LOG_BUILD ON LOG_INSTALL ON LOG_OUTPUT_ON_FAILURE ON)
endfunction()
