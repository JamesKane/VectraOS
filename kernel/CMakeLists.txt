add_library(kernel-swift OBJECT
  Kernel/Acpi/AcpiTables.swift
  Kernel/Acpi/Madt.swift
  Kernel/Acpi/Pptt.swift
  Kernel/Acpi/Rhct.swift
  Kernel/Acpi/Mcfg.swift
  Kernel/BootAllocator.swift
  Kernel/BootOptions.swift
  Kernel/Exceptions.swift
  Kernel/Framebuffer.swift
  Kernel/Heap.swift
  Kernel/Irq/Interrupts.swift
  Kernel/Irq/Ipi.swift
  Kernel/Irq/DeviceIrqs.swift
  Kernel/Irq/Its.swift
  Kernel/Irq/Aia.swift
  Kernel/KernelLayout.swift
  Kernel/KernelPageTables.swift
  Kernel/KernelStack.swift
  Kernel/Main.swift
  Kernel/Panic.swift
  Kernel/Power.swift
  Kernel/Random.swift
  Kernel/Pmm.swift
  Kernel/Ref.swift
  Kernel/Smp.swift
  Kernel/User/Syscalls.swift
  Kernel/User/TaskSyscalls.swift
  Kernel/User/IpcSyscalls.swift
  Kernel/User/PagerSyscalls.swift
  Kernel/User/InfoTopics.swift
  Kernel/User/DebugSyscalls.swift
  Kernel/User/SmcSyscalls.swift
  Kernel/User/DriverSyscalls.swift
  Kernel/User/DmaSyscalls.swift
  Kernel/User/CounterSyscalls.swift
  Kernel/User/IoPorts.swift
  Kernel/User/SyncSyscalls.swift
  Kernel/User/ExceptionSyscalls.swift
  Kernel/User/Vdso.swift
  Kernel/User/ProgramLoader.swift
  Kernel/User/ProgramSelfTest.swift
  Kernel/User/Userboot.swift
  Kernel/User/BootData.swift
  Kernel/User/VdsoSelfTest.swift
  Kernel/User/FpSelfTest.swift
  Kernel/User/UserSelfTest.swift
  Kernel/User/SyscallSelfTest.swift
  Kernel/Object/Status.swift
  Kernel/Object/KernelObject.swift
  Kernel/Object/Wait.swift
  Kernel/Object/Bind.swift
  Kernel/Object/HandleTable.swift
  Kernel/Object/Port.swift
  Kernel/Object/Process.swift
  Kernel/Object/Channel.swift
  Kernel/Object/ContentSize.swift
  Kernel/Object/Pager.swift
  Kernel/Object/Names.swift
  Kernel/Object/Debug.swift
  Kernel/Object/HardwareDebug.swift
  Kernel/Object/Futex.swift
  Kernel/Object/Exception.swift
  Kernel/Object/DebugLog.swift
  ${PROJECT_SOURCE_DIR}/lib/ring/Ring/Ring.swift  # the debuglog's ring (D38)
  ${PROJECT_SOURCE_DIR}/lib/ring/Ring/RingMemory.swift
  Kernel/Object/ProfileObject.swift
  Kernel/Object/Resource.swift
  Kernel/Object/InterruptObject.swift
  Kernel/Object/MsiObject.swift
  Kernel/Object/Dma.swift
  Kernel/Iommu/IoDomain.swift
  Kernel/Iommu/IntelIommu.swift
  Kernel/Iommu/InterruptRemapping.swift
  Kernel/Iommu/AmdIommu.swift
  Kernel/Iommu/SmmuV3.swift
  Kernel/Iommu/SmmuV2.swift
  Kernel/Iommu/SmmuV2SelfTest.swift
  Kernel/Iommu/RiscvIommu.swift
  Kernel/Object/KernelMemory.swift
  Kernel/Object/Counter.swift
  Kernel/Object/AccountObject.swift
  Kernel/Object/ProcessSelfTest.swift
  Kernel/Object/VmoObject.swift
  Kernel/Object/ObjectSelfTest.swift
  Kernel/Object/PortSelfTest.swift
  Kernel/Object/ResourceSelfTest.swift
  Kernel/Time/Clock.swift
  Kernel/Time/Timers.swift
  Kernel/Time/Watchdog.swift
  Kernel/Sched/Profile.swift
  Kernel/Sched/ExtendedState.swift
  Kernel/Sched/ExtendedStateSelfTest.swift
  Kernel/Sched/Thread.swift
  Kernel/Sched/Scheduler.swift
  Kernel/Sched/Idle.swift
  Kernel/Sched/SchedulerSelfTest.swift
  Kernel/Sched/MutexSelfTest.swift
  Kernel/Sched/DeadlineSelfTest.swift
  Kernel/SpinLock.swift
  Kernel/Trace/Trace.swift
  Kernel/Trace/Budgets.swift
  Kernel/Trace/Sampler.swift
  Kernel/Trace/Pmu.swift
  Kernel/Trace/PmuSelfTest.swift
  Kernel/Trace/SamplerSelfTest.swift
  Kernel/Trace/TraceSelfTest.swift
  Kernel/Uart.swift
  Kernel/Vm/ArchAspace.swift
  Kernel/Vm/KernelAspace.swift
  Kernel/Vm/UserAspace.swift
  Kernel/Vm/Vmo.swift
  Kernel/Vm/PageList.swift
  Kernel/Vm/Reclaim.swift
  Kernel/Vm/Loans.swift
  Kernel/Vm/MemoryAccount.swift
  Kernel/Vm/Jit.swift
  Kernel/Vm/ContiguousPool.swift
  Kernel/Vm/AspaceSelfTest.swift
  Kernel/Vm/VmoSelfTest.swift
  Kernel/Vm/RegionSelfTest.swift
  Kernel/Vm/ShootdownSelfTest.swift
  Kernel/Vm/PhysicalSelfTest.swift
  Kernel/Vm/AccountSelfTest.swift
  Kernel/Vm/JitSelfTest.swift)
set_target_properties(kernel-swift PROPERTIES Swift_MODULE_NAME Kernel)
target_include_directories(kernel-swift PRIVATE include)
target_link_libraries(kernel-swift PRIVATE croi-fmt croi-handoff croi-pagetables croi-elf)

# Flag types are BitFlags, never OptionSet (cmake/CheckNoOptionSet.cmake).
get_target_property(_kernel_sources kernel-swift SOURCES)
list(TRANSFORM _kernel_sources PREPEND ${CMAKE_CURRENT_SOURCE_DIR}/ REGEX "^[^/]")
add_custom_command(OUTPUT ${CMAKE_CURRENT_BINARY_DIR}/no-optionset.stamp
  COMMAND ${CMAKE_COMMAND} "-DSOURCES=${_kernel_sources}" -DSTAMP=${CMAKE_CURRENT_BINARY_DIR}/no-optionset.stamp
          -P ${PROJECT_SOURCE_DIR}/cmake/CheckNoOptionSet.cmake
  DEPENDS ${_kernel_sources} ${PROJECT_SOURCE_DIR}/cmake/CheckNoOptionSet.cmake
  COMMENT "Checking the kernel declares no OptionSet"
  VERBATIM)
add_custom_target(kernel-no-optionset DEPENDS ${CMAKE_CURRENT_BINARY_DIR}/no-optionset.stamp)
add_dependencies(kernel-swift kernel-no-optionset)

# K14p/K14q: arm64 return addresses signed (pac-ret) and landing pads for
# indirect branches (bti). Hint-space instructions, NOPs where the CPU
# lacks the feature or it is off.
if(CROI_ARCH STREQUAL "arm64")
  target_compile_options(kernel-swift PRIVATE "SHELL:-Xcc -mbranch-protection=pac-ret+bti")
endif()

add_executable(kernel
  arch/${CROI_ARCH}/start.S
  arch/${CROI_ARCH}/cpu.S
  arch/${CROI_ARCH}/exceptions.S
  arch/${CROI_ARCH}/smp.S
  arch/${CROI_ARCH}/thread.S
  arch/${CROI_ARCH}/usercopy.S
  arch/${CROI_ARCH}/usertest.S
  userprogram.S
  trace.c)
target_include_directories(kernel PRIVATE include)
if(CROI_ARCH STREQUAL "arm64")
  target_compile_options(kernel PRIVATE $<$<COMPILE_LANGUAGE:C>:-mbranch-protection=pac-ret+bti>)
endif()
target_link_libraries(kernel PRIVATE kernel-swift croi-rt)
set_target_properties(kernel PROPERTIES OUTPUT_NAME kernel.elf)
croi_image(kernel ENTRY _start BASE ${CROI_KERNEL_BASE})

# The kernel is ownership-only: refuse images that pull in Swift's
# refcounting runtime (see cmake/CheckNoArc.cmake).
add_custom_command(TARGET kernel POST_BUILD
  COMMAND ${CMAKE_COMMAND} -DNM=${CROI_TOOLCHAIN_DIR}/usr/bin/llvm-nm -DIMAGE=$<TARGET_FILE:kernel>
          -P ${PROJECT_SOURCE_DIR}/cmake/CheckNoArc.cmake
  COMMENT "Checking kernel is free of Swift refcounting")

# User binaries the kernel carries (cmake/CroiUser.cmake): the self-test
# program and the vDSO.
include(${PROJECT_SOURCE_DIR}/cmake/CroiUser.cmake)
set(_user_dir ${PROJECT_SOURCE_DIR}/user)
set(_user_bin ${CMAKE_CURRENT_BINARY_DIR}/usertest.bin)
croi_user_binary(${_user_bin}
  SOURCES ${_user_dir}/test/usertest.c
  LINKER_SCRIPT ${_user_dir}/test/user.ld
  INCLUDES ${CMAKE_CURRENT_SOURCE_DIR}/include ${PROJECT_SOURCE_DIR}/lib/ring)
set(_vdso_bin ${CMAKE_CURRENT_BINARY_DIR}/vdso.bin)
croi_user_binary(${_vdso_bin} PIC
  SOURCES ${_user_dir}/vdso/header.S ${_user_dir}/vdso/vdso.c
  LINKER_SCRIPT ${_user_dir}/vdso/vdso.ld
  INCLUDES ${CMAKE_CURRENT_SOURCE_DIR}/include)
croi_user_floor()
# Its suites (Suite.swift): one file each, run with swift.suite=<name>.
set(_swift_test_sources ${_user_dir}/test/swift/Main.swift ${_user_dir}/test/swift/Suite.swift
    ${_user_dir}/test/swift/BindSuite.swift ${_user_dir}/test/swift/VmoSuite.swift
    ${_user_dir}/test/swift/FutexSuite.swift ${_user_dir}/test/swift/ChannelSuite.swift
    ${_user_dir}/test/swift/ObjectSuite.swift
    ${_user_dir}/test/swift/CounterSuite.swift ${_user_dir}/test/swift/TimeSuite.swift
    ${_user_dir}/test/swift/InterruptSuite.swift
    ${_user_dir}/test/swift/MemorySuite.swift
    ${_user_dir}/test/swift/IdleSuite.swift ${_user_dir}/test/swift/RingSuite.swift
    ${_user_dir}/test/swift/DebuglogSuite.swift ${_user_dir}/test/swift/PortRingSuite.swift
    ${_user_dir}/test/swift/FloorSuite.swift ${_user_dir}/test/swift/LibcSuite.swift
    ${_user_dir}/lib/image/Image.swift
    ${PROJECT_SOURCE_DIR}/lib/ring/Ring/Ring.swift ${PROJECT_SOURCE_DIR}/lib/ring/Ring/RingMemory.swift)
set(_swift_test ${CMAKE_CURRENT_BINARY_DIR}/swifttest.elf)
croi_user_program(${_swift_test} PIE SOURCES ${_user_dir}/test/swift/LibcSuite.c SWIFT ${_swift_test_sources})
# The same as a fixed-address program with a dynamic section and no
# relocations (Todhchai's dlopen hosts, linked --export-dynamic).
set(_swift_test_exec ${CMAKE_CURRENT_BINARY_DIR}/swifttestexec.elf)
croi_user_program(${_swift_test_exec} EXPORT_DYNAMIC SOURCES ${_user_dir}/test/swift/LibcSuite.c
  SWIFT ${_swift_test_sources})
# userboot (K8b), carried in the kernel image like Zircon's; it shares
# lib/elf's sources with the kernel and loader, and user/lib/loader's
# (bootfs, segments, programs) with Sys (its Loader module).
set(_userboot ${CMAKE_CURRENT_BINARY_DIR}/userboot.elf)
croi_user_program(${_userboot} PIE
  SWIFT ${_user_dir}/userboot/Main.swift ${_user_dir}/userboot/Power.swift
        ${_user_dir}/lib/loader/Bootfs.swift ${_user_dir}/lib/loader/Segments.swift ${_user_dir}/lib/loader/Program.swift
        ${PROJECT_SOURCE_DIR}/lib/elf/Elf/ElfImage.swift)
set_source_files_properties(userprogram.S PROPERTIES
  OBJECT_DEPENDS "${_user_bin};${_vdso_bin};${_swift_test};${_swift_test_exec};${_userboot}"
  COMPILE_DEFINITIONS "CROI_USER_PROGRAM=\"${_user_bin}\";CROI_VDSO=\"${_vdso_bin}\";CROI_SWIFT_TEST=\"${_swift_test}\";CROI_SWIFT_TEST_EXEC=\"${_swift_test_exec}\";CROI_USERBOOT=\"${_userboot}\"")

# bootfs (K8b): the programs userboot can start, in Zircon's bootfs format
# (vx mkbootfs), served on the ESP as \croi\bootfs.img.
set(_m2 ${CMAKE_CURRENT_BINARY_DIR}/m2.elf)
croi_user_program(${_m2} PIE SWIFT ${_user_dir}/m2/Main.swift ${_user_dir}/m2/Sys.swift ${_user_dir}/m2/Bench.swift
                  ${_user_dir}/m2/RingBench.swift ${_user_dir}/lib/image/Image.swift ${PROJECT_SOURCE_DIR}/lib/ring/Ring/Ring.swift
                  ${PROJECT_SOURCE_DIR}/lib/ring/Ring/RingMemory.swift)
# bin/sys-test (V2): Sys over the kernel, as SysTests checks it hosted; the
# boot-sys test starts it.
croi_user_sys()
set(_sys_test ${CMAKE_CURRENT_BINARY_DIR}/systest.elf)
croi_user_program(${_sys_test} PIE SYS SWIFT ${PROJECT_SOURCE_DIR}/system/sys/tests/native/Main.swift)
# bin/dl-test (V2): dlopen, a dlopen host loading lib/libdltest.so (C) and
# lib/libdlswift.so (Embedded Swift over Sys); the boot-dl test starts it.
set(_ld_tests ${PROJECT_SOURCE_DIR}/system/ld/tests/native)
set(_dl_test ${CMAKE_CURRENT_BINARY_DIR}/dltest.elf)
croi_user_program(${_dl_test} EXPORT_DYNAMIC SYS SWIFT ${_ld_tests}/Main.swift)
set(_dl_c ${CMAKE_CURRENT_BINARY_DIR}/libdltest.so)
croi_user_library(${_dl_c} SOURCES ${_ld_tests}/dltest.c)
set(_dl_swift ${CMAKE_CURRENT_BINARY_DIR}/libdlswift.so)
croi_user_library(${_dl_swift} SYS SWIFT ${_ld_tests}/DlSwift.swift)
# bin/trace-test (V2, D50): a recording, the kernel's and its own, checked
# and exported; the boot-trace test starts it.
set(_trace_test ${CMAKE_CURRENT_BINARY_DIR}/tracetest.elf)
croi_user_program(${_trace_test} PIE SYS SWIFT ${PROJECT_SOURCE_DIR}/system/trace/tests/native/Main.swift)
# bin/ipc-test (V2): IPC over the kernel, Echo's server and clients in
# Swift and C (idlc's test_ipc.h) and the dispatcher; the boot-ipc test
# starts it.
set(_ipc_tests ${PROJECT_SOURCE_DIR}/system/ipc/tests)
set(_ipc_test ${CMAKE_CURRENT_BINARY_DIR}/ipctest.elf)
croi_user_program(${_ipc_test} PIE SYS IPC SWIFT ${_ipc_tests}/native/Main.swift ${_ipc_tests}/echo/Echo.swift
                  SOURCES ${_ipc_tests}/c/idl_c_tests.c
                  INCLUDES ${_ipc_tests}/c/include ${_ipc_tests}/c/generated)
# bin/node-test (V2): Node over the kernel, batches, mounts, watches,
# namespaces and /srv; the boot-node test starts it.
set(_node_test ${CMAKE_CURRENT_BINARY_DIR}/nodetest.elf)
croi_user_program(${_node_test} PIE SYS SWIFT ${PROJECT_SOURCE_DIR}/system/node/tests/native/Main.swift)
# bin/acpi-test (V2 item 7a, D74): the AML interpreter on this boot's own
# firmware tables; the boot-acpi test starts it.
set(_acpi_test ${CMAKE_CURRENT_BINARY_DIR}/acpitest.elf)
croi_user_program(${_acpi_test} PIE SYS SWIFT ${PROJECT_SOURCE_DIR}/drivers/bus/acpi/tests/native/Main.swift)
# bin/pci-test (V2 item 7b, D74): PCI over this boot's ECAM; the boot-pci
# test starts it.
set(_pci_test ${CMAKE_CURRENT_BINARY_DIR}/pcitest.elf)
croi_user_program(${_pci_test} PIE SYS SWIFT ${PROJECT_SOURCE_DIR}/drivers/bus/pci/tests/native/Main.swift)
# bin/launcher (V2): bootfs's programs started by bootfs's manifests;
# with them, the launcher's boot test: bin/launch-service (services a and
# b) and bin/launch-test, its client (the boot-launch test).
set(_launch ${PROJECT_SOURCE_DIR}/system/launch)
set(_launcher ${CMAKE_CURRENT_BINARY_DIR}/launcher.elf)
croi_user_program(${_launcher} PIE SYS SWIFT ${_launch}/launcher/Main.swift)
set(_launch_service ${CMAKE_CURRENT_BINARY_DIR}/launchservice.elf)
croi_user_program(${_launch_service} PIE SYS SWIFT ${_launch}/tests/native/Service.swift
                  ${_launch}/tests/TreeService.swift)
set(_launch_test ${CMAKE_CURRENT_BINARY_DIR}/launchtest.elf)
croi_user_program(${_launch_test} PIE SYS IPC SWIFT ${_launch}/tests/native/Main.swift
                  ${PROJECT_SOURCE_DIR}/services/pty/lib/Protocol.swift)
set(_manifests ${_launch}/tests/native/manifests)
# bin/time (D48): UTC from the RTC, on amd64, which alone has the CMOS's
# ports; elsewhere it publishes nothing, so only amd64's bootfs runs it.
set(_time ${CMAKE_CURRENT_BINARY_DIR}/time.elf)
croi_user_program(${_time} PIE SYS SWIFT ${PROJECT_SOURCE_DIR}/services/time/Main.swift
                  ${PROJECT_SOURCE_DIR}/services/time/lib/RTC.swift)
set(_time_bootfs bin/time=${_time})
# bin/bootfs (D71): the boot image as a tree, on every arch; manifests
# mount its bin/ at /bin.
set(_bootfs_service ${CMAKE_CURRENT_BINARY_DIR}/bootfs.elf)
croi_user_program(${_bootfs_service} PIE SYS IPC SWIFT ${PROJECT_SOURCE_DIR}/services/bootfs/Main.swift)
# bin/pty (D46): the pty service, on every arch; launch-test runs rc on one.
set(_pty_src ${PROJECT_SOURCE_DIR}/services/pty)
set(_pty ${CMAKE_CURRENT_BINARY_DIR}/pty.elf)
croi_user_program(${_pty} PIE SYS IPC SWIFT ${_pty_src}/Main.swift ${_pty_src}/lib/Protocol.swift ${_pty_src}/lib/Server.swift
                  ${_pty_src}/lib/LineDiscipline.swift)
set(CROI_LAUNCH_TEST_USES "")
if(CROI_ARCH STREQUAL amd64)
  list(APPEND _time_bootfs etc/manifests/time.manifest=${_manifests}/time.manifest)
  set(CROI_LAUNCH_TEST_USES "use time")
endif()
set(_launch_test_manifest ${CMAKE_CURRENT_BINARY_DIR}/launch-test.manifest)
configure_file(${_manifests}/launch-test.manifest.in ${_launch_test_manifest} @ONLY)
# Tier 1's programs (D47), when the *-vectraos toolchain has been built.
include(${PROJECT_SOURCE_DIR}/cmake/Tier1.cmake)
croi_tier1(_tier1_bootfs _tier1_files)
set(CROI_BOOTFS_IMAGE ${CMAKE_BINARY_DIR}/bootfs.img PARENT_SCOPE)
add_custom_command(OUTPUT ${CMAKE_BINARY_DIR}/bootfs.img
  COMMAND ${VX} mkbootfs ${CMAKE_BINARY_DIR}/bootfs.img
          bin/m2=${_m2} bin/sys-test=${_sys_test} bin/dl-test=${_dl_test}
          lib/libdltest.so=${_dl_c} lib/libdlswift.so=${_dl_swift} bin/trace-test=${_trace_test} bin/ipc-test=${_ipc_test}
          bin/node-test=${_node_test} bin/acpi-test=${_acpi_test} bin/pci-test=${_pci_test} bin/launcher=${_launcher} bin/launch-service=${_launch_service}
          bin/launch-test=${_launch_test} etc/manifests/a.manifest=${_manifests}/a.manifest
          etc/manifests/b.manifest=${_manifests}/b.manifest
          etc/manifests/launch-test.manifest=${_launch_test_manifest} ${_time_bootfs}
          bin/pty=${_pty} etc/manifests/pty.manifest=${_manifests}/pty.manifest
          bin/bootfs=${_bootfs_service} etc/manifests/bootfs.manifest=${_manifests}/bootfs.manifest
          ${_tier1_bootfs}
  DEPENDS ${_m2} ${_sys_test} ${_dl_test} ${_dl_c} ${_dl_swift} ${_trace_test} ${_ipc_test} ${_node_test} ${_acpi_test} ${_pci_test}
          ${_launcher} ${_launch_service} ${_launch_test} ${_manifests}/a.manifest ${_manifests}/b.manifest
          ${_launch_test_manifest} ${_time} ${_manifests}/time.manifest ${_pty} ${_manifests}/pty.manifest
          ${_bootfs_service} ${_manifests}/bootfs.manifest
          ${_tier1_files} vx ${VX}
  COMMENT "Building bootfs")
add_custom_target(bootfs DEPENDS ${CMAKE_BINARY_DIR}/bootfs.img)
