# SPDX-License-Identifier: BSD-3-Clause
#
# Tier 1's sysroot (M6c), for the *-vectraos toolchain (tools/toolchain):
# the floor as libsys.a and our libc as libc.a (its pthreads in it, as
# glibc's are since 2.34: no -lpthread), with every swift_* symbol
# made local (the Embedded objects carry weak copies of the runtime's entry
# points, which would otherwise stand in for the full runtime's; the floor
# never calls them, -no-allocations sees to it), an empty libm.a until it
# has functions, compiler-rt's builtins, and our headers with their module
# map (SwiftVectraOSLibc, M6e), and the floor's C interface (td_floor.h,
# which the Swift runtime's executor and Mutex call, M6f).
#
#   cmake -DFLOOR=... -DLIBC=... -DBUILTINS=... -DHEADERS=... -DFLOOR_HEADER=... -DCROI_HEADERS=...
#         -DKERNEL_HEADERS=... -DOBJCOPY=... -DAR=... -DOUT=...
#         -P sysroot.cmake

file(MAKE_DIRECTORY ${OUT}/usr/lib ${OUT}/usr/include)
# The libc's archive has its pthreads in it already (croi_user_floor).
foreach(pair "${FLOOR};libsys.a" "${LIBC};libc.a")
  list(GET pair 0 from)
  list(GET pair 1 to)
  execute_process(COMMAND ${OBJCOPY} --wildcard --localize-symbol=swift_* ${from} ${OUT}/usr/lib/${to}
                  RESULT_VARIABLE r)
  if(NOT r EQUAL 0)
    message(FATAL_ERROR "sysroot: can't make ${to}")
  endif()
endforeach()
file(REMOVE ${OUT}/usr/lib/libm.a)
execute_process(COMMAND ${AR} rc ${OUT}/usr/lib/libm.a)
if(EXISTS "${BUILTINS}")
  file(COPY_FILE ${BUILTINS} ${OUT}/usr/lib/libclang_rt.builtins.a)
endif()
file(COPY ${HEADERS}/ DESTINATION ${OUT}/usr/include FILES_MATCHING PATTERN "*.h" PATTERN "module.modulemap")
file(COPY ${FLOOR_HEADER} DESTINATION ${OUT}/usr/include)
# The ABI's headers (D45): croi/syscall.h and the kernel's headers it
# includes, which are the CroiAbi module's in kernel/include's module map
# (td_floor.h includes croi/syscall.h, and the runtime's executor and
# Mutex include td_floor.h).
file(MAKE_DIRECTORY ${OUT}/usr/include/croi)
file(COPY ${CROI_HEADERS}/syscall.h DESTINATION ${OUT}/usr/include/croi)
file(READ ${KERNEL_HEADERS}/module.modulemap _map)
string(REGEX MATCH "module CroiAbi {[^}]*}" _abi "${_map}")
string(REGEX MATCHALL "header \"[^\"]+\"" _lines "${_abi}")
foreach(_line ${_lines})
  string(REGEX REPLACE "header \"([^\"]+)\"" "\\1" _header "${_line}")
  file(COPY ${KERNEL_HEADERS}/${_header} DESTINATION ${OUT}/usr/include/croi)
endforeach()
