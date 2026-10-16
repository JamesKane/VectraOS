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
# heap, threads' blocks and TLS; lib/rt's mem*, stack guard and 128-bit
# division), from C and/or Embedded Swift sources. The kernel loads them
# (ProgramLoader), userboot from bootfs (K8b).
set(CROI_FLOOR_DIR ${PROJECT_SOURCE_DIR}/system/sys/floor)
set(CROI_USER_COMMON_CFLAGS --target=${CROI_CLANG_TRIPLE} ${CROI_USER_CFLAGS} -std=c23 -O2 -ffreestanding
    -fno-omit-frame-pointer -ffunction-sections -fdata-sections -fno-pic -fno-pie
    -I${PROJECT_SOURCE_DIR}/user/include -I${PROJECT_SOURCE_DIR}/kernel/include -I${CROI_FLOOR_DIR}/include)

# croi_user_floor(): builds the floor once per tree, ${CROI_USER_FLOOR}.
function(croi_user_floor)
  set(_dir ${CMAKE_BINARY_DIR}/user-floor)
  set(_c_sources
    ${CROI_FLOOR_DIR}/runtime.c
    ${PROJECT_SOURCE_DIR}/system/libc/native/errno.c
    ${PROJECT_SOURCE_DIR}/lib/rt/string.c
    ${PROJECT_SOURCE_DIR}/lib/rt/int128.c
    ${PROJECT_SOURCE_DIR}/lib/rt/stack_protector.c)
  set(_entry ${CROI_FLOOR_DIR}/entry/${CROI_ARCH}.S)
  set(_swift_sources
    ${CROI_FLOOR_DIR}/Start.swift ${CROI_FLOOR_DIR}/Stdout.swift ${CROI_FLOOR_DIR}/Heap.swift
    ${CROI_FLOOR_DIR}/Thread.swift ${CROI_FLOOR_DIR}/Threads.swift ${CROI_FLOOR_DIR}/Posix.swift
    ${CROI_FLOOR_DIR}/Waits.swift)
  file(GLOB _headers ${CROI_FLOOR_DIR}/include/* ${PROJECT_SOURCE_DIR}/user/include/croi/*.h
       ${PROJECT_SOURCE_DIR}/kernel/include/*.h)
  # Two flavors: fixed-address (ET_EXEC programs) and -fPIE (static PIEs,
  # K11b), libfloor.a and libfloor-pie.a.
  foreach(_flavor "" "-pie")
    set(_objects)
    set(_commands)
    set(_code)
    if(_flavor STREQUAL "-pie")
      set(_code -fPIE)
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
    # The floor's Swift: one Embedded module, runtime-free (-no-allocations:
    # it runs beneath tier 1's full Swift too, M6c).
    set(_xcc)
    foreach(_f ${CROI_USER_CFLAGS} ${_code} -std=c23 -fno-omit-frame-pointer -I${PROJECT_SOURCE_DIR}/user/include
               -I${PROJECT_SOURCE_DIR}/kernel/include -I${CROI_FLOOR_DIR}/include)
      list(APPEND _xcc -Xcc ${_f})
    endforeach()
    list(APPEND _commands COMMAND ${CMAKE_Swift_COMPILER} -target ${CROI_SWIFT_TRIPLE}
         -enable-experimental-feature Embedded -enable-experimental-feature Extern
         -parse-as-library -strict-memory-safety -wmo -Osize -Xfrontend -no-allocations
         -Xfrontend -function-sections -module-name Floor ${_xcc}
         -c ${_swift_sources} -o ${_dir}/floor-swift${_flavor}.o)
    list(APPEND _objects ${_dir}/floor-swift${_flavor}.o)
    add_custom_command(OUTPUT ${_dir}/libfloor${_flavor}.a
      COMMAND ${CMAKE_COMMAND} -E make_directory ${_dir}
      ${_commands}
      COMMAND ${CMAKE_COMMAND} -E rm -f ${_dir}/libfloor${_flavor}.a
      COMMAND ${CMAKE_AR} rcs ${_dir}/libfloor${_flavor}.a ${_objects}
      DEPENDS ${_c_sources} ${_entry} ${_swift_sources} ${_headers}
      COMMENT "Building the floor${_flavor}")
  endforeach()
  set(CROI_USER_FLOOR ${_dir}/libfloor.a PARENT_SCOPE)
  set(CROI_USER_FLOOR_PIE ${_dir}/libfloor-pie.a PARENT_SCOPE)
endfunction()

#   croi_user_program(<out.elf> [PIE] [EXPORT_DYNAMIC] [SYS] [SOURCES <c>...] [SWIFT <swift>...] [STACK <bytes>])
# SYS: the program imports Sys (croi_user_sys).
function(croi_user_program output)
  cmake_parse_arguments(U "PIE;EXPORT_DYNAMIC;SYS" "STACK" "SOURCES;SWIFT" ${ARGN})
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
    set(_sys_flags -I ${CROI_USER_SYS_DIR})
    set(_sys_libs ${CROI_USER_SYS})
  endif()
  get_filename_component(_name ${output} NAME_WE)
  set(_dir ${CMAKE_CURRENT_BINARY_DIR}/${_name}.dir)
  # EXPORT_DYNAMIC: a dynamic section with no relocations (a program that
  # hosts dlopen'd libraries); the loaders take it as a symbol table.
  # (lld makes a dynamic section for a non-PIC executable only when a
  # shared object is linked: an empty one, --as-needed, so no DT_NEEDED.)
  set(_dynamic_commands)
  set(_dynamic_inputs)
  if(U_EXPORT_DYNAMIC)
    set(_link --image-base=0x1000000 --export-dynamic --no-dynamic-linker)
    set(_dynamic_commands
        COMMAND ${CMAKE_C_COMPILER} --target=${CROI_CLANG_TRIPLE} -c -x c /dev/null -o ${_dir}/empty.o
        COMMAND ${CMAKE_LINKER} -shared -soname=libempty.so ${_dir}/empty.o -o ${_dir}/libempty.so)
    set(_dynamic_inputs --as-needed ${_dir}/libempty.so)
  endif()
  set(_objects)
  set(_commands)
  foreach(_source ${U_SOURCES})
    get_filename_component(_base ${_source} NAME_WE)
    list(APPEND _commands COMMAND ${CMAKE_C_COMPILER} ${CROI_USER_COMMON_CFLAGS} ${_cpie} -fstack-protector-strong
                                  -c ${_source} -o ${_dir}/${_base}.o)
    list(APPEND _objects ${_dir}/${_base}.o)
  endforeach()
  if(U_SWIFT)
    # The user-mode flags (not the kernel's -mno-sse and friends); C
    # declarations come from user/include/module.modulemap (CroiRuntime)
    # and the floor's (system/sys/floor/include).
    set(_xcc)
    foreach(_f ${CROI_USER_CFLAGS} ${_cpie} -std=c23 -fno-omit-frame-pointer -I${PROJECT_SOURCE_DIR}/user/include
               -I${PROJECT_SOURCE_DIR}/kernel/include -I${CROI_FLOOR_DIR}/include)
      list(APPEND _xcc -Xcc ${_f})
    endforeach()
    list(APPEND _commands COMMAND ${CMAKE_Swift_COMPILER} -target ${CROI_SWIFT_TRIPLE}
         -enable-experimental-feature Embedded -enable-experimental-feature Lifetimes
         -parse-as-library -strict-memory-safety -Werror StrictMemorySafety -wmo -Osize
         -Xfrontend -function-sections -module-name ${_name} ${_sys_flags} ${_xcc}
         -c ${U_SWIFT} -o ${_dir}/${_name}-swift.o)
    list(APPEND _objects ${_dir}/${_name}-swift.o)
  endif()
  add_custom_command(OUTPUT ${output}
    COMMAND ${CMAKE_COMMAND} -E make_directory ${_dir}
    ${_commands}
    ${_dynamic_commands}
    COMMAND ${CMAKE_LINKER} ${_link} -e _start -zseparate-loadable-segments
            -zmax-page-size=4096 -znoexecstack -zstack-size=${U_STACK} --gc-sections --build-id=sha1
            ${_objects} ${_sys_libs} ${_runtime} ${_dynamic_inputs} -o ${output}
    DEPENDS ${U_SOURCES} ${U_SWIFT} ${_sys_libs} ${_runtime} ${PROJECT_SOURCE_DIR}/user/include/module.modulemap
    COMMENT "Building user program ${_name}")
endfunction()

# croi_user_sys(): builds Sys once per tree (system/sys, V2): its modules
# SysABI, Sys (the API over the native backend) and LibSys (the start's
# views), Embedded Swift, into ${CROI_USER_SYS_DIR} (their .swiftmodule
# files) and ${CROI_USER_SYS} (libsys.a). Programs built with SYS import
# them. Static-PIE code, which fixed-address programs link too.
function(croi_user_sys)
  set(_dir ${CMAKE_BINARY_DIR}/user-sys)
  set(_sys ${PROJECT_SOURCE_DIR}/system/sys)
  set(_xcc)
  foreach(_f ${CROI_USER_CFLAGS} -fPIE -std=c23 -fno-omit-frame-pointer -I${PROJECT_SOURCE_DIR}/user/include
             -I${PROJECT_SOURCE_DIR}/kernel/include -I${CROI_FLOOR_DIR}/include)
    list(APPEND _xcc -Xcc ${_f})
  endforeach()
  set(_swiftc ${CMAKE_Swift_COMPILER} -target ${CROI_SWIFT_TRIPLE} -enable-experimental-feature Embedded
      -enable-experimental-feature Lifetimes -parse-as-library -strict-memory-safety -Werror StrictMemorySafety
      -wmo -Osize -Xfrontend -function-sections -I ${_dir} ${_xcc})
  set(_abi ${_sys}/abi/Values.swift)
  set(_api ${_sys}/api/Handles.swift ${_sys}/api/Lock.swift ${_sys}/api/Objects.swift
      ${_sys}/backend/native/Kernel.swift)
  set(_lib ${_sys}/native/Start.swift)
  file(GLOB _headers ${CROI_FLOOR_DIR}/include/* ${PROJECT_SOURCE_DIR}/user/include/croi/*.h
       ${PROJECT_SOURCE_DIR}/kernel/include/*.h)
  add_custom_command(OUTPUT ${_dir}/libsys.a
    COMMAND ${CMAKE_COMMAND} -E make_directory ${_dir}
    COMMAND ${_swiftc} -module-name SysABI -emit-module -emit-module-path ${_dir}/SysABI.swiftmodule
            -c ${_abi} -o ${_dir}/sysabi.o
    COMMAND ${_swiftc} -module-name Sys -emit-module -emit-module-path ${_dir}/Sys.swiftmodule
            -c ${_api} -o ${_dir}/sys.o
    COMMAND ${_swiftc} -module-name LibSys -emit-module -emit-module-path ${_dir}/LibSys.swiftmodule
            -c ${_lib} -o ${_dir}/libsys.o
    COMMAND ${CMAKE_COMMAND} -E rm -f ${_dir}/libsys.a
    COMMAND ${CMAKE_AR} rcs ${_dir}/libsys.a ${_dir}/sysabi.o ${_dir}/sys.o ${_dir}/libsys.o
    DEPENDS ${_abi} ${_api} ${_lib} ${_headers}
    COMMENT "Building Sys")
  set(CROI_USER_SYS_DIR ${_dir} PARENT_SCOPE)
  set(CROI_USER_SYS ${_dir}/libsys.a PARENT_SCOPE)
endfunction()
