# User-mode binaries (K6c's kernel/user split): built with the user flag
# set (CROI_USER_CFLAGS from cmake/arch), not the kernel's, by the same
# clang, into flat binaries the kernel includes (.incbin). K8's loader will
# take ELF files instead.
#
#   croi_user_binary(<out.bin> SOURCES ... LINKER_SCRIPT <ld> [PIC] [INCLUDES ...])
function(croi_user_binary output)
  cmake_parse_arguments(U "PIC" "LINKER_SCRIPT" "SOURCES;INCLUDES" ${ARGN})
  get_filename_component(_name ${output} NAME_WE)
  set(_elf ${CMAKE_CURRENT_BINARY_DIR}/${_name}.elf)
  set(_code -fno-pic -fno-pie -Wl,--no-pie)
  if(U_PIC)
    # Position independent without relocations: PIE code, hidden symbols,
    # linked statically at 0 (everything is PC-relative).
    set(_code -fPIE -fvisibility=hidden -Wl,--no-pie)
  endif()
  set(_includes -I${PROJECT_SOURCE_DIR}/user/include)
  foreach(_i ${U_INCLUDES})
    list(APPEND _includes -I${_i})
  endforeach()
  add_custom_command(OUTPUT ${output}
    COMMAND ${CMAKE_C_COMPILER} --target=${CROI_CLANG_TRIPLE} ${CROI_USER_CFLAGS} -std=c23 -O2 -fno-omit-frame-pointer -ffreestanding
            -fno-stack-protector -fno-builtin -nostdlib -static -fuse-ld=lld ${_code}
            -Wl,-T,${U_LINKER_SCRIPT} ${_includes} ${U_SOURCES} -o ${_elf} -MD -MF ${_elf}.d
    COMMAND ${CMAKE_OBJCOPY} -O binary ${_elf} ${output}
    DEPENDS ${U_SOURCES} ${U_LINKER_SCRIPT}
    DEPFILE ${_elf}.d  # the headers it includes
    COMMENT "Building user binary ${_name}")
endfunction()

# User programs (K8a): ELF executables linked at 0x1000000 with the floor
# (system/sys/floor, D49: entry and processargs, stdout over debuglog, the
# heap, threads' blocks and TLS; lib/rt's stack guard and 128-bit
# division) and the libc (system/libc: mem*, stdio, pthreads), from C
# and/or Embedded Swift sources. The kernel loads them
# (ProgramLoader), userboot from bootfs (K8b).
set(CROI_FLOOR_DIR ${PROJECT_SOURCE_DIR}/system/sys/floor)
set(CROI_USER_COMMON_CFLAGS --target=${CROI_CLANG_TRIPLE} ${CROI_USER_CFLAGS} -std=c23 -O2 -ffreestanding
    -fno-omit-frame-pointer -ffunction-sections -fdata-sections -fno-pic -fno-pie
    -I${PROJECT_SOURCE_DIR}/user/include -I${PROJECT_SOURCE_DIR}/system/libc/include
    -I${PROJECT_SOURCE_DIR}/kernel/include -I${CROI_FLOOR_DIR}/include -I${PROJECT_SOURCE_DIR}/lib/ring)

# croi_user_floor(): builds the floor and the libc once per tree:
# ${CROI_USER_FLOOR} (libfloor.a) and ${CROI_USER_LIBC} (libc.a, its
# pthreads in it, as glibc's are). Three Embedded modules, in the order
# they import each other: LibC (system/libc, V2: the functions under their
# C names, with native/'s C), the Floor, which takes getenv from it, and
# PThread, over the Floor's threads and futexes. All three are
# runtime-free (-no-allocations: they run beneath tier 1's full Swift too,
# M6c). The libc is static-PIE code, which fixed-address programs link too.
function(croi_user_floor)
  set(_dir ${CMAKE_BINARY_DIR}/user-floor)
  set(_libc ${PROJECT_SOURCE_DIR}/system/libc)
  set(_c_sources
    ${CROI_FLOOR_DIR}/runtime.c
    ${CROI_FLOOR_DIR}/stdio.c
    ${PROJECT_SOURCE_DIR}/lib/rt/int128.c
    ${PROJECT_SOURCE_DIR}/lib/rt/stack_protector.c)
  set(_entry ${CROI_FLOOR_DIR}/entry/${CROI_ARCH}.S)
  set(_swift_sources
    ${CROI_FLOOR_DIR}/Start.swift ${CROI_FLOOR_DIR}/Stdout.swift ${CROI_FLOOR_DIR}/Heap.swift
    ${CROI_FLOOR_DIR}/Thread.swift ${CROI_FLOOR_DIR}/Threads.swift ${CROI_FLOOR_DIR}/Posix.swift
    ${CROI_FLOOR_DIR}/Waits.swift)
  set(_libc_swift
    ${_libc}/string/Memory.swift ${_libc}/string/Strings.swift ${_libc}/string/Strerror.swift
    ${_libc}/stdlib/Stdlib.swift ${_libc}/stdlib/Strtod.swift ${_libc}/stdlib/Errno.swift
    ${_libc}/stdio/Format.swift ${_libc}/stdio/Decimal.swift ${_libc}/ctype/Ctype.swift
    ${_libc}/math/Exact.swift ${_libc}/math/Transcendental.swift ${_libc}/math/generated/Constants.swift
    ${_libc}/native/Exports.swift)
  set(_libc_c ${_libc}/native/errno.c ${_libc}/native/stdio.c ${_libc}/native/stdlib.c ${_libc}/native/files.c)
  set(_pthread_swift
    ${_libc}/pthread/lib/Condition.swift ${_libc}/pthread/lib/Keys.swift ${_libc}/pthread/lib/Mutex.swift
    ${_libc}/pthread/lib/Once.swift ${_libc}/pthread/lib/RWLock.swift ${_libc}/pthread/lib/Threads.swift
    ${_libc}/pthread/lib/Words.swift ${_libc}/pthread/platform/floor/Platform.swift
    ${_libc}/pthread/native/Exports.swift)
  file(GLOB_RECURSE _headers ${CROI_FLOOR_DIR}/include/* ${PROJECT_SOURCE_DIR}/user/include/croi/*.h
       ${PROJECT_SOURCE_DIR}/kernel/include/*.h ${_libc}/include/* ${_libc}/native/include/*
       ${_libc}/pthread/c/include/*)
  set(_swiftc ${CMAKE_Swift_COMPILER} -target ${CROI_SWIFT_TRIPLE}
      -enable-experimental-feature Embedded -enable-experimental-feature Extern
      -parse-as-library -strict-memory-safety -wmo -Osize -Xfrontend -no-allocations
      -Xfrontend -function-sections -I ${_dir})

  # The libc: PIE code, its module beside the floor's.
  set(_xcc)
  foreach(_f ${CROI_USER_CFLAGS} -fPIE -std=c23 -fno-omit-frame-pointer -I${_libc}/native/include
             -I${_libc}/pthread/c/include -I${PROJECT_SOURCE_DIR}/user/include -I${PROJECT_SOURCE_DIR}/kernel/include
             -I${CROI_FLOOR_DIR}/include)
    list(APPEND _xcc -Xcc ${_f})
  endforeach()
  set(_libc_objects ${_dir}/libc-swift.o)
  # No loop in it may become a call to the functions it defines.
  set(_libc_commands COMMAND ${_swiftc} -Xllvm -disable-loop-idiom-all ${_xcc} -module-name LibC
      -emit-module -emit-module-path ${_dir}/LibC.swiftmodule -c ${_libc_swift} -o ${_dir}/libc-swift.o)
  foreach(_source ${_libc_c})
    get_filename_component(_name ${_source} NAME_WE)
    list(APPEND _libc_commands COMMAND ${CMAKE_C_COMPILER} ${CROI_USER_COMMON_CFLAGS} -fPIE -fstack-protector-strong
         -I${_libc}/include -I${_libc}/native/include -c ${_source} -o ${_dir}/libc-${_name}.o)
    list(APPEND _libc_objects ${_dir}/libc-${_name}.o)
  endforeach()
  add_custom_command(OUTPUT ${_dir}/LibC.swiftmodule ${_libc_objects}
    COMMAND ${CMAKE_COMMAND} -E make_directory ${_dir}
    ${_libc_commands}
    DEPENDS ${_libc_swift} ${_libc_c} ${_headers}
    COMMENT "Building the libc")

  # Two flavors of the floor: fixed-address (ET_EXEC programs) and -fPIE
  # (static PIEs, K11b), libfloor.a and libfloor-pie.a. The first emits
  # its module, for PThread.
  foreach(_flavor "" "-pie")
    set(_objects)
    set(_commands)
    set(_code)
    set(_module)
    if(_flavor STREQUAL "-pie")
      set(_code -fPIE)
    else()
      set(_module -emit-module -emit-module-path ${_dir}/Floor.swiftmodule)
    endif()
    foreach(_source ${_c_sources} ${_entry})
      get_filename_component(_name ${_source} NAME_WE)
      set(_object ${_dir}/${_name}${_flavor}.o)
      set(_protect -fstack-protector-strong)
      if(_name STREQUAL stack_protector)
        set(_protect -fno-stack-protector)
      endif()
      list(APPEND _commands COMMAND ${CMAKE_C_COMPILER} ${CROI_USER_COMMON_CFLAGS} ${_code} ${_protect}
                                    -c ${_source} -o ${_object})
      list(APPEND _objects ${_object})
    endforeach()
    set(_xcc)
    foreach(_f ${CROI_USER_CFLAGS} ${_code} -std=c23 -fno-omit-frame-pointer -I${_libc}/native/include -I${PROJECT_SOURCE_DIR}/user/include
               -I${PROJECT_SOURCE_DIR}/kernel/include -I${CROI_FLOOR_DIR}/include)
      list(APPEND _xcc -Xcc ${_f})
    endforeach()
    list(APPEND _commands COMMAND ${_swiftc} ${_xcc} -module-name Floor ${_module}
         -c ${_swift_sources} -o ${_dir}/floor-swift${_flavor}.o)
    list(APPEND _objects ${_dir}/floor-swift${_flavor}.o)
    set(_outputs ${_dir}/libfloor${_flavor}.a)
    if(_module)
      list(APPEND _outputs ${_dir}/Floor.swiftmodule)
    endif()
    add_custom_command(OUTPUT ${_outputs}
      COMMAND ${CMAKE_COMMAND} -E make_directory ${_dir}
      ${_commands}
      COMMAND ${CMAKE_COMMAND} -E rm -f ${_dir}/libfloor${_flavor}.a
      COMMAND ${CMAKE_AR} rcs ${_dir}/libfloor${_flavor}.a ${_objects}
      DEPENDS ${_c_sources} ${_entry} ${_swift_sources} ${_headers} ${_dir}/LibC.swiftmodule
      COMMENT "Building the floor${_flavor}")
  endforeach()

  # The pthreads, over the floor; then libc.a.
  set(_xcc)
  foreach(_f ${CROI_USER_CFLAGS} -fPIE -std=c23 -fno-omit-frame-pointer -I${_libc}/pthread/c/include -I${_libc}/native/include
             -I${PROJECT_SOURCE_DIR}/user/include -I${PROJECT_SOURCE_DIR}/kernel/include -I${CROI_FLOOR_DIR}/include)
    list(APPEND _xcc -Xcc ${_f})
  endforeach()
  add_custom_command(OUTPUT ${_dir}/libc.a
    COMMAND ${_swiftc} ${_xcc} -module-name PThread -c ${_pthread_swift} -o ${_dir}/pthread-swift.o
    COMMAND ${CMAKE_COMMAND} -E rm -f ${_dir}/libc.a
    COMMAND ${CMAKE_AR} rcs ${_dir}/libc.a ${_libc_objects} ${_dir}/pthread-swift.o
    DEPENDS ${_pthread_swift} ${_libc_objects} ${_dir}/Floor.swiftmodule ${_headers}
    COMMENT "Building the pthreads")
  set(CROI_USER_FLOOR ${_dir}/libfloor.a PARENT_SCOPE)
  set(CROI_USER_FLOOR_PIE ${_dir}/libfloor-pie.a PARENT_SCOPE)
  set(CROI_USER_LIBC ${_dir}/libc.a PARENT_SCOPE)
endfunction()

#   croi_user_program(<out.elf> [PIE] [EXPORT_DYNAMIC] [SYS] [IPC] [SOURCES <c>...] [SWIFT <swift>...]
#                     [INCLUDES <dir>...] [STACK <bytes>])
# SYS: the program imports Sys (croi_user_sys). IPC: it declares an
# @IPCLibrary (the macro's plugin, CROI_IPC_PLUGIN) or its C includes
# td_wire.h. INCLUDES: more header directories, for C and Swift's clang.
function(croi_user_program output)
  cmake_parse_arguments(U "PIE;EXPORT_DYNAMIC;SYS;IPC" "STACK" "SOURCES;SWIFT;INCLUDES" ${ARGN})
  # PIE: a static PIE (K11b), linked at 0, loaded at a random base by
  # croi's loaders, which apply its R_*_RELATIVE relocations.
  set(_cpie)
  set(_link -static --image-base=0x1000000)
  set(_runtime ${CROI_USER_FLOOR})
  if(U_PIE)
    set(_cpie -fPIE)
    set(_link -static -pie --no-dynamic-linker -ztext)
    set(_runtime ${CROI_USER_FLOOR_PIE})
  endif()
  if(NOT U_STACK)
    set(U_STACK 262144)
  endif()
  set(_sys_flags)
  set(_sys_libs)
  if(U_SYS)
    set(_sys_flags -I ${CROI_USER_SYS_DIR} -Xcc -I${PROJECT_SOURCE_DIR}/system/trace/c/include)
    set(_sys_libs ${CROI_USER_SYS})
  endif()
  set(_includes)
  set(_ipc_flags)
  set(_ipc_depends)
  if(U_IPC)
    list(APPEND U_INCLUDES ${PROJECT_SOURCE_DIR}/system/ipc/c/include)
    set(_ipc_flags -load-plugin-executable "${CROI_IPC_PLUGIN}\#IPCMacros")
    set(_ipc_depends vx ${CROI_IPC_PLUGIN})
  endif()
  foreach(_i ${U_INCLUDES})
    list(APPEND _includes -I${_i})
  endforeach()
  get_filename_component(_name ${output} NAME_WE)
  set(_dir ${CMAKE_CURRENT_BINARY_DIR}/${_name}.dir)
  # EXPORT_DYNAMIC: a dynamic section with no relocations (a program that
  # hosts dlopen'd libraries); the loaders take it as a symbol table. Its
  # runtime (the floor and the libc) is linked whole, so a library finds
  # any of it there: one heap, one of everything. Sys and Ld
  # (SYS) are linked as needed and not exported (--exclude-libs): a library
  # compiles in what it uses of Sys, and exported, their unused functions
  # would stay, some needing the Unicode tables (String's ==), which only
  # amd64's Embedded toolchain has, or the hasher's seed.
  # (lld makes a dynamic section for a non-PIC executable only when a
  # shared object is linked: an empty one, --as-needed, so no DT_NEEDED.)
  set(_dynamic_commands)
  set(_dynamic_inputs)
  set(_whole)
  set(_whole_end)
  if(U_EXPORT_DYNAMIC)
    set(_link --image-base=0x1000000 --export-dynamic --exclude-libs=libsys.a --no-dynamic-linker)
    set(_dynamic_commands
        COMMAND ${CMAKE_C_COMPILER} --target=${CROI_CLANG_TRIPLE} -c -x c /dev/null -o ${_dir}/empty.o
        COMMAND ${CMAKE_LINKER} -shared -soname=libempty.so ${_dir}/empty.o -o ${_dir}/libempty.so)
    set(_dynamic_inputs --as-needed ${_dir}/libempty.so)
    set(_whole --whole-archive)
    set(_whole_end --no-whole-archive)
  endif()
  set(_objects)
  set(_commands)
  foreach(_source ${U_SOURCES})
    get_filename_component(_base ${_source} NAME_WE)
    list(APPEND _commands COMMAND ${CMAKE_C_COMPILER} ${CROI_USER_COMMON_CFLAGS} ${_cpie} -fstack-protector-strong ${_includes}
                                  -c ${_source} -o ${_dir}/${_base}.o)
    list(APPEND _objects ${_dir}/${_base}.o)
  endforeach()
  if(U_SWIFT)
    # The user-mode flags (not the kernel's -mno-sse and friends); C
    # declarations come from user/include/module.modulemap (CroiRuntime),
    # the floor's (system/sys/floor/include) and the libc's.
    set(_xcc)
    foreach(_f ${CROI_USER_CFLAGS} ${_cpie} -std=c23 -fno-omit-frame-pointer -I${PROJECT_SOURCE_DIR}/user/include
               -I${PROJECT_SOURCE_DIR}/system/libc/include
               -I${PROJECT_SOURCE_DIR}/kernel/include -I${CROI_FLOOR_DIR}/include ${_includes})
      list(APPEND _xcc -Xcc ${_f})
    endforeach()
    list(APPEND _commands COMMAND ${CMAKE_Swift_COMPILER} -target ${CROI_SWIFT_TRIPLE}
         -enable-experimental-feature Embedded -enable-experimental-feature Lifetimes -enable-experimental-feature Extern
         -parse-as-library -strict-memory-safety -Werror StrictMemorySafety -wmo -Osize
         -Xfrontend -function-sections -module-name ${_name} ${_sys_flags} ${_ipc_flags} ${_xcc}
         -c ${U_SWIFT} -o ${_dir}/${_name}-swift.o)
    list(APPEND _objects ${_dir}/${_name}-swift.o)
  endif()
  add_custom_command(OUTPUT ${output}
    COMMAND ${CMAKE_COMMAND} -E make_directory ${_dir}
    ${_commands}
    ${_dynamic_commands}
    COMMAND ${CMAKE_LINKER} ${_link} -e _start -zseparate-loadable-segments
            -zmax-page-size=4096 -znoexecstack -zstack-size=${U_STACK} --gc-sections --build-id=sha1
            ${_objects} ${_sys_libs} ${_whole} ${_runtime} ${CROI_USER_LIBC} ${_whole_end} ${_dynamic_inputs}
            -o ${output}
    DEPENDS ${U_SOURCES} ${U_SWIFT} ${_sys_libs} ${_runtime} ${CROI_USER_LIBC} ${_ipc_depends}
            ${PROJECT_SOURCE_DIR}/user/include/module.modulemap
    COMMENT "Building user program ${_name}")
endfunction()

#   croi_user_library(<lib<name>.so> [SYS] [SOURCES <c>...] [SWIFT <swift>...])
# A shared object for dlopen (system/ld), for bootfs's lib/: position-
# independent code linked with only its own sources. What it uses of the
# libc, the floor and (SYS) Sys it takes from the program that loads it,
# an EXPORT_DYNAMIC one. Its Swift module is named after it.
function(croi_user_library output)
  cmake_parse_arguments(U "SYS" "" "SOURCES;SWIFT" ${ARGN})
  get_filename_component(_name ${output} NAME_WE)
  string(REGEX REPLACE "^lib" "" _module ${_name})
  set(_dir ${CMAKE_CURRENT_BINARY_DIR}/${_name}.dir)
  set(_sys_flags)
  set(_sys_depends)
  if(U_SYS)
    set(_sys_flags -I ${CROI_USER_SYS_DIR} -Xcc -I${PROJECT_SOURCE_DIR}/system/trace/c/include)
    set(_sys_depends ${CROI_USER_SYS})
  endif()
  set(_objects)
  set(_commands)
  foreach(_source ${U_SOURCES})
    get_filename_component(_base ${_source} NAME_WE)
    list(APPEND _commands COMMAND ${CMAKE_C_COMPILER} ${CROI_USER_COMMON_CFLAGS} -fPIC -fstack-protector-strong
                                  -c ${_source} -o ${_dir}/${_base}.o)
    list(APPEND _objects ${_dir}/${_base}.o)
  endforeach()
  if(U_SWIFT)
    set(_xcc)
    foreach(_f ${CROI_USER_CFLAGS} -fPIC -std=c23 -fno-omit-frame-pointer -I${PROJECT_SOURCE_DIR}/user/include
               -I${PROJECT_SOURCE_DIR}/system/libc/include
               -I${PROJECT_SOURCE_DIR}/kernel/include -I${CROI_FLOOR_DIR}/include)
      list(APPEND _xcc -Xcc ${_f})
    endforeach()
    list(APPEND _commands COMMAND ${CMAKE_Swift_COMPILER} -target ${CROI_SWIFT_TRIPLE}
         -enable-experimental-feature Embedded -enable-experimental-feature Lifetimes -enable-experimental-feature Extern
         -parse-as-library -strict-memory-safety -Werror StrictMemorySafety -wmo -Osize
         -Xfrontend -function-sections -module-name ${_module} ${_sys_flags} ${_xcc}
         -c ${U_SWIFT} -o ${_dir}/${_name}-swift.o)
    list(APPEND _objects ${_dir}/${_name}-swift.o)
  endif()
  add_custom_command(OUTPUT ${output}
    COMMAND ${CMAKE_COMMAND} -E make_directory ${_dir}
    ${_commands}
    COMMAND ${CMAKE_LINKER} -shared -soname=${_name}.so -zseparate-loadable-segments -zmax-page-size=4096
            -znoexecstack -ztext --gc-sections --build-id=sha1 ${_objects} -o ${output}
    DEPENDS ${U_SOURCES} ${U_SWIFT} ${_sys_depends} ${PROJECT_SOURCE_DIR}/user/include/module.modulemap
    COMMENT "Building user library ${_name}")
endfunction()

# croi_user_sys(): builds Sys once per tree (system/sys, V2): its modules
# SysABI, Loader (croi's ELF and bootfs readers and user/lib/loader's
# segments and programs: userboot's loading, shared), Sys (the API over
# the native backend, which starts processes through Loader), LibSys (the
# start's views), Ld (system/ld: dlopen, over Loader), the trace (Ring,
# TraceFormat, Trace, TraceSession), IPC (system/ipc: IPCWire, and IPC, the runtime
# @IPCLibrary's code calls; the macro is CROI_IPC_PLUGIN) and Node
# (system/node: the protocol, NodeTree, namespaces and /srv) and Launch
# (system/launch: manifests and the launcher, D65), Embedded
# Swift, into ${CROI_USER_SYS_DIR} (their .swiftmodule files) and
# ${CROI_USER_SYS} (libsys.a). Programs built with SYS import them.
# Static-PIE code, which fixed-address programs link too.
function(croi_user_sys)
  set(_dir ${CMAKE_BINARY_DIR}/user-sys)
  set(_sys ${PROJECT_SOURCE_DIR}/system/sys)
  set(_xcc)
  foreach(_f ${CROI_USER_CFLAGS} -fPIE -std=c23 -fno-omit-frame-pointer -I${PROJECT_SOURCE_DIR}/user/include
             -I${PROJECT_SOURCE_DIR}/system/libc/include
             -I${PROJECT_SOURCE_DIR}/kernel/include -I${CROI_FLOOR_DIR}/include
             -I${PROJECT_SOURCE_DIR}/system/trace/c/include)
    list(APPEND _xcc -Xcc ${_f})
  endforeach()
  set(_swiftc ${CMAKE_Swift_COMPILER} -target ${CROI_SWIFT_TRIPLE} -enable-experimental-feature Embedded
      -enable-experimental-feature Lifetimes -parse-as-library -strict-memory-safety -Werror StrictMemorySafety
      -wmo -Osize -Xfrontend -function-sections -I ${_dir} ${_xcc})
  set(_abi ${_sys}/abi/Values.swift)
  set(_loader ${PROJECT_SOURCE_DIR}/lib/elf/Elf/ElfImage.swift ${PROJECT_SOURCE_DIR}/user/lib/loader/Bootfs.swift
      ${PROJECT_SOURCE_DIR}/user/lib/loader/Segments.swift ${PROJECT_SOURCE_DIR}/user/lib/loader/Program.swift)
  set(_api ${_sys}/api/Handles.swift ${_sys}/api/Lock.swift ${_sys}/api/Objects.swift ${_sys}/api/Startup.swift
      ${_sys}/backend/native/Kernel.swift ${_sys}/backend/native/Loader.swift
      ${_sys}/backend/native/UTC.swift ${_sys}/backend/native/Stdio.swift)
  set(_lib ${_sys}/native/Start.swift)
  set(_ld ${PROJECT_SOURCE_DIR}/system/ld/lib/Dynamic.swift ${PROJECT_SOURCE_DIR}/system/ld/native/Linker.swift
      ${PROJECT_SOURCE_DIR}/system/ld/native/Exports.swift)
  # The trace (system/trace, D50): the one ring, the format, the writer
  # over the region a process is given (td_trace_cpu.h's inline counter
  # and atomics; a thread's ring pointer is the floor's thread block's,
  # so td_trace_cpu.c is the hosted build's) and the session.
  set(_trace ${PROJECT_SOURCE_DIR}/system/trace)
  set(_ring ${PROJECT_SOURCE_DIR}/lib/ring/Ring/Ring.swift ${PROJECT_SOURCE_DIR}/lib/ring/Ring/RingMemory.swift)
  set(_trace_format ${_trace}/format/Format.swift)
  set(_trace_writer ${_trace}/writer/Trace.swift ${_trace}/writer/native/Region.swift)
  set(_trace_session ${_trace}/session/Session.swift)
  file(GLOB _ipc_wire CONFIGURE_DEPENDS ${PROJECT_SOURCE_DIR}/system/ipc/wire/*.swift)
  file(GLOB _ipc CONFIGURE_DEPENDS ${PROJECT_SOURCE_DIR}/system/ipc/runtime/*.swift)
  file(GLOB _node CONFIGURE_DEPENDS ${PROJECT_SOURCE_DIR}/system/node/lib/*.swift)
  file(GLOB _launch CONFIGURE_DEPENDS ${PROJECT_SOURCE_DIR}/system/launch/lib/*.swift)
  # ACPI (drivers/bus/acpi, D74): the tables and the AML interpreter, linked
  # only by what imports it (devmgr, bin/acpi-test).
  file(GLOB _acpi CONFIGURE_DEPENDS ${PROJECT_SOURCE_DIR}/drivers/bus/acpi/lib/*.swift)
  # PCI over ECAM (drivers/bus/pci, D74): devmgr and bin/pci-test.
  file(GLOB _pci CONFIGURE_DEPENDS ${PROJECT_SOURCE_DIR}/drivers/bus/pci/lib/*.swift)
  # The driver host's library and devmgr's (drivers/host, drivers/devmgr/lib, D74).
  file(GLOB _driver_host CONFIGURE_DEPENDS ${PROJECT_SOURCE_DIR}/drivers/host/*.swift)
  file(GLOB _devmgr CONFIGURE_DEPENDS ${PROJECT_SOURCE_DIR}/drivers/devmgr/lib/*.swift)
  # virtio and the input class (drivers/virtio/lib, drivers/input/lib, D74).
  file(GLOB _virtio CONFIGURE_DEPENDS ${PROJECT_SOURCE_DIR}/drivers/virtio/lib/*.swift)
  file(GLOB _input CONFIGURE_DEPENDS ${PROJECT_SOURCE_DIR}/drivers/input/lib/*.swift)
  # kbdfs's keyboard and console (services/kbdfs/lib, D83).
  file(GLOB _kbdfs CONFIGURE_DEPENDS ${PROJECT_SOURCE_DIR}/services/kbdfs/lib/*.swift)
  # The console's grid, renderer and font (services/console/lib, V2 item 8).
  file(GLOB_RECURSE _console CONFIGURE_DEPENDS ${PROJECT_SOURCE_DIR}/services/console/lib/*.swift)
  file(GLOB _headers ${CROI_FLOOR_DIR}/include/* ${PROJECT_SOURCE_DIR}/user/include/croi/*.h
       ${PROJECT_SOURCE_DIR}/kernel/include/*.h)
  add_custom_command(OUTPUT ${_dir}/libsys.a
    COMMAND ${CMAKE_COMMAND} -E make_directory ${_dir}
    COMMAND ${_swiftc} -module-name SysABI -emit-module -emit-module-path ${_dir}/SysABI.swiftmodule
            -c ${_abi} -o ${_dir}/sysabi.o
    COMMAND ${_swiftc} -module-name Loader -emit-module -emit-module-path ${_dir}/Loader.swiftmodule
            -c ${_loader} -o ${_dir}/loader.o
    COMMAND ${_swiftc} -module-name Ring -emit-module -emit-module-path ${_dir}/Ring.swiftmodule
            -c ${_ring} -o ${_dir}/ring.o
    COMMAND ${_swiftc} -module-name Sys -emit-module -emit-module-path ${_dir}/Sys.swiftmodule
            -c ${_api} -o ${_dir}/sys.o
    COMMAND ${_swiftc} -module-name LibSys -emit-module -emit-module-path ${_dir}/LibSys.swiftmodule
            -c ${_lib} -o ${_dir}/libsys.o
    COMMAND ${_swiftc} -module-name Ld -emit-module -emit-module-path ${_dir}/Ld.swiftmodule
            -c ${_ld} -o ${_dir}/ld.o
    COMMAND ${_swiftc} -module-name TraceFormat -emit-module -emit-module-path ${_dir}/TraceFormat.swiftmodule
            -c ${_trace_format} -o ${_dir}/traceformat.o
    COMMAND ${_swiftc} -module-name Trace -emit-module -emit-module-path ${_dir}/Trace.swiftmodule
            -c ${_trace_writer} -o ${_dir}/trace.o
    COMMAND ${_swiftc} -module-name TraceSession -emit-module -emit-module-path ${_dir}/TraceSession.swiftmodule
            -c ${_trace_session} -o ${_dir}/tracesession.o
    COMMAND ${_swiftc} -module-name IPCWire -emit-module -emit-module-path ${_dir}/IPCWire.swiftmodule
            -c ${_ipc_wire} -o ${_dir}/ipcwire.o
    COMMAND ${_swiftc} -load-plugin-executable "${CROI_IPC_PLUGIN}\#IPCMacros" -module-name IPC -emit-module
            -emit-module-path ${_dir}/IPC.swiftmodule -c ${_ipc} -o ${_dir}/ipc.o
    COMMAND ${_swiftc} -load-plugin-executable "${CROI_IPC_PLUGIN}\#IPCMacros" -module-name Node -emit-module
            -emit-module-path ${_dir}/Node.swiftmodule -c ${_node} -o ${_dir}/node.o
    COMMAND ${_swiftc} -module-name Launch -emit-module -emit-module-path ${_dir}/Launch.swiftmodule
            -c ${_launch} -o ${_dir}/launch.o
    COMMAND ${_swiftc} -module-name TDACPI -emit-module -emit-module-path ${_dir}/TDACPI.swiftmodule
            -c ${_acpi} -o ${_dir}/acpi.o
    COMMAND ${_swiftc} -module-name PCI -emit-module -emit-module-path ${_dir}/PCI.swiftmodule
            -c ${_pci} -o ${_dir}/pci.o
    COMMAND ${_swiftc} -module-name DriverHost -emit-module -emit-module-path ${_dir}/DriverHost.swiftmodule
            -c ${_driver_host} -o ${_dir}/driverhost.o
    COMMAND ${_swiftc} -module-name DevMgr -emit-module -emit-module-path ${_dir}/DevMgr.swiftmodule
            -c ${_devmgr} -o ${_dir}/devmgr.o
    COMMAND ${_swiftc} -module-name Virtio -emit-module -emit-module-path ${_dir}/Virtio.swiftmodule
            -c ${_virtio} -o ${_dir}/virtio.o
    COMMAND ${_swiftc} -module-name InputDevice -emit-module -emit-module-path ${_dir}/InputDevice.swiftmodule
            -c ${_input} -o ${_dir}/input.o
    COMMAND ${_swiftc} -module-name Kbdfs -emit-module -emit-module-path ${_dir}/Kbdfs.swiftmodule
            -c ${_kbdfs} -o ${_dir}/kbdfs.o
    COMMAND ${_swiftc} -module-name Console -emit-module -emit-module-path ${_dir}/Console.swiftmodule
            -c ${_console} -o ${_dir}/console.o
    COMMAND ${CMAKE_COMMAND} -E rm -f ${_dir}/libsys.a
    COMMAND ${CMAKE_AR} rcs ${_dir}/libsys.a ${_dir}/sysabi.o ${_dir}/loader.o ${_dir}/sys.o ${_dir}/libsys.o ${_dir}/ld.o
            ${_dir}/ring.o ${_dir}/traceformat.o ${_dir}/trace.o ${_dir}/tracesession.o
            ${_dir}/ipcwire.o ${_dir}/ipc.o ${_dir}/node.o ${_dir}/launch.o ${_dir}/acpi.o ${_dir}/pci.o
            ${_dir}/driverhost.o ${_dir}/devmgr.o ${_dir}/virtio.o ${_dir}/input.o ${_dir}/kbdfs.o ${_dir}/console.o
    DEPENDS ${_abi} ${_loader} ${_api} ${_lib} ${_ld} ${_ring} ${_trace_format} ${_trace_writer} ${_trace_session} ${_ipc_wire}
            ${_ipc} ${_node} ${_launch} ${_acpi} ${_pci} ${_driver_host} ${_devmgr} ${_virtio} ${_input} ${_kbdfs} ${_console}
            ${_headers} vx ${CROI_IPC_PLUGIN}
    COMMENT "Building Sys")
  set(CROI_USER_SYS_DIR ${_dir} PARENT_SCOPE)
  set(CROI_USER_SYS ${_dir}/libsys.a PARENT_SCOPE)
endfunction()
