add_library(kernel-swift OBJECT
  Kernel/Acpi/AcpiTables.swift
  Kernel/Acpi/Madt.swift
  Kernel/Acpi/Pptt.swift
  Kernel/Acpi/Rhct.swift
  Kernel/Acpi/Mcfg.swift
  Kernel/BootAllocator.swift
  Kernel/BootOptions.swift
  Kernel/BoardRules.swift
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
  Kernel/WarmBoot.swift
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
  Kernel/Object/Notes.swift
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
  Kernel/Iommu/SmmuV3SelfTest.swift
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
# The crypto (D89), whose suite checks it as Embedded Swift on the target.
file(GLOB _crypto_sources CONFIGURE_DEPENDS ${PROJECT_SOURCE_DIR}/crypto/lib/*.swift)
# 9gate's codec and Noise IK (D77, D78), the same for theirs.
file(GLOB _gate_sources CONFIGURE_DEPENDS ${PROJECT_SOURCE_DIR}/services/9gate/p9/*.swift
     ${PROJECT_SOURCE_DIR}/services/9gate/noise/*.swift)
# PixelKernels (D129) and Light under it, the same as crypto's.
file(GLOB _pixel_kernel_sources CONFIGURE_DEPENDS ${PROJECT_SOURCE_DIR}/ui/kernels/lib/*.swift
     ${PROJECT_SOURCE_DIR}/ui/light/lib/*.swift)
# Its suites (Suite.swift): one file each, run with swift.suite=<name>.
set(_swift_test_sources ${_user_dir}/test/swift/Main.swift ${_user_dir}/test/swift/Suite.swift
    ${_user_dir}/test/swift/BindSuite.swift ${_user_dir}/test/swift/VmoSuite.swift
    ${_user_dir}/test/swift/FutexSuite.swift ${_user_dir}/test/swift/ChannelSuite.swift
    ${_user_dir}/test/swift/ObjectSuite.swift
    ${_user_dir}/test/swift/CounterSuite.swift ${_user_dir}/test/swift/TimeSuite.swift
    ${_user_dir}/test/swift/InterruptSuite.swift ${_user_dir}/test/swift/DmaSuite.swift
    ${_user_dir}/test/swift/DriverSuite.swift
    ${_user_dir}/test/swift/MemorySuite.swift
    ${_user_dir}/test/swift/IdleSuite.swift ${_user_dir}/test/swift/RingSuite.swift
    ${_user_dir}/test/swift/DebuglogSuite.swift ${_user_dir}/test/swift/PortRingSuite.swift
    ${_user_dir}/test/swift/FloorSuite.swift ${_user_dir}/test/swift/LibcSuite.swift
    ${_user_dir}/test/swift/NoteSuite.swift
    ${_user_dir}/test/swift/CryptoSuite.swift ${_crypto_sources}
    ${_user_dir}/test/swift/GateSuite.swift ${_gate_sources}
    ${_user_dir}/test/swift/PixelsSuite.swift ${_pixel_kernel_sources}
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
# (bootfs, segments, programs, linked programs) and system/ld's core with
# Sys (its Loader module).
set(_userboot ${CMAKE_CURRENT_BINARY_DIR}/userboot.elf)
croi_user_program(${_userboot} PIE
  SWIFT ${_user_dir}/userboot/Main.swift ${_user_dir}/userboot/Power.swift
        ${_user_dir}/lib/loader/Bootfs.swift ${_user_dir}/lib/loader/Segments.swift ${_user_dir}/lib/loader/Program.swift
        ${_user_dir}/lib/loader/Linked.swift ${PROJECT_SOURCE_DIR}/system/ld/lib/Dynamic.swift
        ${PROJECT_SOURCE_DIR}/system/ld/lib/Link.swift ${PROJECT_SOURCE_DIR}/lib/elf/Elf/ElfImage.swift)
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
# bin/link-test (D124): a program linked against lib/liblinkb.so and
# lib/liblinka.so, which needs liblinkb.so too; dl-test starts it. liblinkb
# is named first, so it loads first and liblinka last, and liblinka's
# initializers must still run after liblinkb's.
set(_link_b ${CMAKE_CURRENT_BINARY_DIR}/liblinkb.so)
croi_user_library(${_link_b} SOURCES ${_ld_tests}/linkb.c)
set(_link_a ${CMAKE_CURRENT_BINARY_DIR}/liblinka.so)
croi_user_library(${_link_a} SOURCES ${_ld_tests}/linka.c NEEDS ${_link_b})
set(_link_test ${CMAKE_CURRENT_BINARY_DIR}/linktest.elf)
croi_user_program(${_link_test} PIE SYS SWIFT ${PROJECT_SOURCE_DIR}/system/ld/tests/linked/Main.swift
                  NEEDS ${_link_b} ${_link_a})
# bin/link-stale: linked against another build of liblinkb.so, which
# bootfs doesn't have; dl-test checks it is refused.
set(_link_b_stale ${CMAKE_CURRENT_BINARY_DIR}/stale/liblinkb.so)
croi_user_library(${_link_b_stale} SOURCES ${_ld_tests}/linkb.c DEFINES LINKB_STALE)
set(_link_stale ${CMAKE_CURRENT_BINARY_DIR}/linkstale.elf)
croi_user_program(${_link_stale} PIE SOURCES ${_ld_tests}/stale.c NEEDS ${_link_b_stale})
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
croi_user_program(${_acpi_test} PIE SYS SWIFT ${PROJECT_SOURCE_DIR}/drivers/bus/acpi/tests/native/Main.swift
                  ${PROJECT_SOURCE_DIR}/drivers/bus/acpi/tests/native/Firmware.swift)
# bin/irq-test (D125): a spare PL011's interrupt in loopback, found in the
# DSDT, from user mode; the boot-irq test starts it (arm64).
set(_irq_test ${CMAKE_CURRENT_BINARY_DIR}/irqtest.elf)
croi_user_program(${_irq_test} PIE SYS SWIFT ${PROJECT_SOURCE_DIR}/drivers/bus/acpi/tests/native/irq/Main.swift
                  ${PROJECT_SOURCE_DIR}/drivers/bus/acpi/tests/native/Firmware.swift)
# bin/warmboot-test (D101): a warm boot into this build's kernel, which
# boot-warmboot's bootfs (bootfs-warmboot.img, below) holds at
# lib/warm/kernel.elf.
set(_warmboot_test ${CMAKE_CURRENT_BINARY_DIR}/warmboottest.elf)
croi_user_program(${_warmboot_test} PIE SYS SWIFT ${PROJECT_SOURCE_DIR}/system/sys/tests/warmboot/Main.swift)
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
croi_user_program(${_launch_test} PIE SYS IPC SWIFT ${_launch}/tests/native/Main.swift)
# bin/board-test: the board image's client, what a stable board shows.
set(_board_test ${CMAKE_CURRENT_BINARY_DIR}/boardtest.elf)
croi_user_program(${_board_test} PIE SYS IPC SWIFT ${PROJECT_SOURCE_DIR}/services/board-test/Main.swift)
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
# bin/devmgr and its drivers (V2 item 7c, D74): every arch. etc/drivers is
# every drivers/**/driver.manifest, in path order (DevMgrTests checks the
# same set has no two drivers sharing a rule).
set(_devmgr ${CMAKE_CURRENT_BINARY_DIR}/devmgr.elf)
croi_user_program(${_devmgr} PIE SYS IPC SWIFT ${PROJECT_SOURCE_DIR}/drivers/devmgr/Main.swift)
set(_edu ${CMAKE_CURRENT_BINARY_DIR}/edu.elf)
croi_user_program(${_edu} PIE SYS IPC SWIFT ${PROJECT_SOURCE_DIR}/drivers/test/edu/Main.swift)
# bin/proc (V3, D79): /proc, a directory a process, every arch.
set(_proc ${CMAKE_CURRENT_BINARY_DIR}/proc.elf)
croi_user_program(${_proc} PIE SYS IPC SWIFT ${PROJECT_SOURCE_DIR}/services/proc/Main.swift)
# bin/plumber (V2 item 8, D85): plumber(4)'s files, every arch.
set(_plumber ${CMAKE_CURRENT_BINARY_DIR}/plumber.elf)
croi_user_program(${_plumber} PIE SYS IPC SWIFT ${PROJECT_SOURCE_DIR}/services/plumber/Main.swift)
# bin/console (V2 item 8): the log on the framebuffer, every arch.
set(_console ${CMAKE_CURRENT_BINARY_DIR}/console.elf)
croi_user_program(${_console} PIE SYS IPC SWIFT ${PROJECT_SOURCE_DIR}/services/console/Main.swift)
# bin/kbdfs (D83): the keyboard and the console, every arch.
set(_kbdfs ${CMAKE_CURRENT_BINARY_DIR}/kbdfs.elf)
croi_user_program(${_kbdfs} PIE SYS IPC SWIFT ${PROJECT_SOURCE_DIR}/services/kbdfs/Main.swift)
# bin/power (D130): CPPC's highest level and the thermal zones' trips, every arch.
set(_power ${CMAKE_CURRENT_BINARY_DIR}/power.elf)
croi_user_program(${_power} PIE SYS IPC SWIFT ${PROJECT_SOURCE_DIR}/services/power/Main.swift
                  ${PROJECT_SOURCE_DIR}/services/power/lib/Power.swift)
# bin/mouse (D83): the pointer, every arch.
set(_mouse ${CMAKE_CURRENT_BINARY_DIR}/mouse.elf)
croi_user_program(${_mouse} PIE SYS IPC SWIFT ${PROJECT_SOURCE_DIR}/services/mouse/Main.swift)
# bin/radharc (D107): the compositor on the boot framebuffer, and
# bin/desktop-test, its first clients (boot-desktop). Only in the
# desktop's images, below.
set(_radharc ${CMAKE_CURRENT_BINARY_DIR}/radharc.elf)
croi_user_program(${_radharc} PIE SYS IPC SWIFT ${PROJECT_SOURCE_DIR}/services/radharc/Main.swift
  ${PROJECT_SOURCE_DIR}/services/radharc/Desk.swift ${PROJECT_SOURCE_DIR}/services/radharc/Display.swift
  INCLUDES ${PROJECT_SOURCE_DIR}/graphics/vulkan/c/include ${PROJECT_SOURCE_DIR}/graphics/venus/c/include)
set(_desktop_test ${CMAKE_CURRENT_BINARY_DIR}/desktoptest.elf)
croi_user_program(${_desktop_test} PIE SYS IPC SWIFT ${PROJECT_SOURCE_DIR}/services/radharc/tests/native/Main.swift)
# bin/minimal, the SDK's reference app, and bin/sdk-test (boot-sdk).
set(_minimal ${CMAKE_CURRENT_BINARY_DIR}/minimal.elf)
croi_user_program(${_minimal} PIE SYS IPC SWIFT ${PROJECT_SOURCE_DIR}/sdk/examples/minimal/Main.swift)
# Hot reload (hotreload(2), D122): bin/minimal-hot, minimal hot reloading
# its frame, and the frame's images: version 1, version 2, one whose state
# has another layout, and version 4 beside 10,000 generated lines (boot-reload).
set(_minimal_hot ${CMAKE_CURRENT_BINARY_DIR}/minimalhot.elf)
croi_user_program(${_minimal_hot} PIE SYS IPC EXPORT_DYNAMIC SWIFT ${PROJECT_SOURCE_DIR}/sdk/examples/minimal/hot/Main.swift)
set(_hot_frame ${PROJECT_SOURCE_DIR}/sdk/examples/minimal/hot/Frame.swift)
croi_user_library(${CMAKE_CURRENT_BINARY_DIR}/libminimalframe.so SYS IPC ONONE SWIFT ${_hot_frame})
croi_user_library(${CMAKE_CURRENT_BINARY_DIR}/libminimalframe2.so SYS IPC ONONE SWIFT ${_hot_frame} DEFINES HOT_V2)
croi_user_library(${CMAKE_CURRENT_BINARY_DIR}/libminimalframe3.so SYS IPC ONONE SWIFT ${_hot_frame} DEFINES HOT_LAYOUT2)
# The 10,000 lines: ordinary code (a struct, an enum and a switch over it,
# eighteen lines a time), generated once into the build tree.
set(_hot10k_filler ${CMAKE_CURRENT_BINARY_DIR}/hot10k/Module.swift)
if(NOT EXISTS ${_hot10k_filler})
  set(_filler "// Generated by kernel/CMakeLists.txt: 10,000 lines for reload.module_10k.\n")
  foreach(_i RANGE 1 555)
    string(APPEND _filler "struct Item${_i} {\n  var name: String\n  var count: Int\n  var weight: Double\n"
           "  func total(_ other: Item${_i}) -> Int {\n    let sum: Int = count + other.count\n    return sum\n  }\n}\n"
           "enum Kind${_i} { case a, b, c }\nfunc describe${_i}(_ k: Kind${_i}, _ item: Item${_i}) -> String {\n"
           "  switch k {\n  case .a: return item.name\n  case .b: return \"b\"\n  case .c: return \"c\"\n  }\n}\n\n")
  endforeach()
  file(WRITE ${_hot10k_filler} "${_filler}")
endif()
croi_user_library(${CMAKE_CURRENT_BINARY_DIR}/libhot10k.so SYS IPC ONONE SWIFT ${_hot_frame} ${_hot10k_filler}
                  DEFINES HOT_10K)
add_custom_target(hot-images ALL DEPENDS ${CMAKE_CURRENT_BINARY_DIR}/libminimalframe.so
                  ${CMAKE_CURRENT_BINARY_DIR}/libminimalframe2.so ${CMAKE_CURRENT_BINARY_DIR}/libminimalframe3.so)
add_custom_target(hot10k DEPENDS ${CMAKE_CURRENT_BINARY_DIR}/libhot10k.so)
set(_sdk_test ${CMAKE_CURRENT_BINARY_DIR}/sdktest.elf)
croi_user_program(${_sdk_test} PIE SYS IPC SWIFT ${PROJECT_SOURCE_DIR}/sdk/tests/native/Main.swift)
set(_virtio_input ${CMAKE_CURRENT_BINARY_DIR}/virtioinput.elf)
croi_user_program(${_virtio_input} PIE SYS IPC SWIFT ${PROJECT_SOURCE_DIR}/drivers/input/virtio-input/Main.swift)
# bin/virtio-blk (D106): the block class over virtio-blk, sd(3)'s directory.
# virtio-gpu (D120): the display class over virtio's 2D commands.
set(_virtio_gpu ${CMAKE_CURRENT_BINARY_DIR}/virtiogpu.elf)
croi_user_program(${_virtio_gpu} PIE SYS IPC SWIFT ${PROJECT_SOURCE_DIR}/drivers/display/virtio-gpu/Main.swift
  ${PROJECT_SOURCE_DIR}/drivers/display/virtio-gpu/Context3D.swift)
# bin/linlon: a Linlon-D6 display engine, the display class by flipping only (linlon(3)).
set(_linlon ${CMAKE_CURRENT_BINARY_DIR}/linlon.elf)
croi_user_program(${_linlon} PIE SYS IPC SWIFT ${PROJECT_SOURCE_DIR}/drivers/display/linlon/Main.swift
                  ${PROJECT_SOURCE_DIR}/drivers/display/linlon/lib/Linlon.swift)
set(_virtio_blk ${CMAKE_CURRENT_BINARY_DIR}/virtioblk.elf)
croi_user_program(${_virtio_blk} PIE SYS IPC SWIFT ${PROJECT_SOURCE_DIR}/drivers/block/virtio-blk/Main.swift
                  ${PROJECT_SOURCE_DIR}/drivers/block/virtio-blk/lib/Block.swift
                  ${PROJECT_SOURCE_DIR}/drivers/block/virtio-blk/lib/Disk.swift)
# bin/nvme: the block class over an NVMe controller, sd(3)'s directory.
set(_nvme ${CMAKE_CURRENT_BINARY_DIR}/nvme.elf)
croi_user_program(${_nvme} PIE SYS IPC SWIFT ${PROJECT_SOURCE_DIR}/drivers/block/nvme/Main.swift
                  ${PROJECT_SOURCE_DIR}/drivers/block/nvme/lib/Controller.swift)
# bin/xhci: an xHCI host controller, its hubs and HID boot devices (xhci(3)).
set(_xhci ${CMAKE_CURRENT_BINARY_DIR}/xhci.elf)
croi_user_program(${_xhci} PIE SYS IPC SWIFT ${PROJECT_SOURCE_DIR}/drivers/usb/xhci/Main.swift
                  ${PROJECT_SOURCE_DIR}/drivers/usb/xhci/lib/Controller.swift
                  ${PROJECT_SOURCE_DIR}/drivers/usb/xhci/lib/Bus.swift
                  ${PROJECT_SOURCE_DIR}/drivers/usb/lib/Descriptors.swift)
# bin/scmi: the SCMI agent, the power class (scmi(3)).
set(_scmi ${CMAKE_CURRENT_BINARY_DIR}/scmi.elf)
croi_user_program(${_scmi} PIE SYS IPC SWIFT ${PROJECT_SOURCE_DIR}/drivers/power/scmi/Main.swift
                  ${PROJECT_SOURCE_DIR}/drivers/power/scmi/lib/SCMI.swift)
# bin/mali: an Arm Mali CSF GPU's probe (mali(3)).
set(_mali ${CMAKE_CURRENT_BINARY_DIR}/mali.elf)
croi_user_program(${_mali} PIE SYS IPC SWIFT ${PROJECT_SOURCE_DIR}/drivers/gpu/mali/Main.swift
                  ${PROJECT_SOURCE_DIR}/drivers/gpu/mali/lib/Mali.swift)
# bin/virtio-net (D82): the net class over virtio-net, ether(3)'s directory.
set(_virtio_net ${CMAKE_CURRENT_BINARY_DIR}/virtionet.elf)
croi_user_program(${_virtio_net} PIE SYS IPC SWIFT ${PROJECT_SOURCE_DIR}/drivers/net/virtio-net/Main.swift
                  ${PROJECT_SOURCE_DIR}/drivers/net/virtio-net/lib/NetBackend.swift)
# bin/rge: the net class over the Realtek RTL8126, ether(3)'s directory.
set(_rge ${CMAKE_CURRENT_BINARY_DIR}/rge.elf)
croi_user_program(${_rge} PIE SYS IPC SWIFT ${PROJECT_SOURCE_DIR}/drivers/net/rge/Main.swift
                  ${PROJECT_SOURCE_DIR}/drivers/net/rge/lib/Chip.swift ${PROJECT_SOURCE_DIR}/drivers/net/rge/lib/Rings.swift)
# bin/net (D79): the network stack, /net's protocols, every arch.
set(_net ${CMAKE_CURRENT_BINARY_DIR}/net.elf)
croi_user_program(${_net} PIE SYS IPC SWIFT ${PROJECT_SOURCE_DIR}/services/net/Main.swift)
# bin/cs and bin/dns (D79): names, /net/cs and /net/dns, with the database
# at lib/ndb.
set(_cs ${CMAKE_CURRENT_BINARY_DIR}/cs.elf)
croi_user_program(${_cs} PIE SYS IPC SWIFT ${PROJECT_SOURCE_DIR}/services/ndb/cs/Main.swift)
set(_dns ${CMAKE_CURRENT_BINARY_DIR}/dns.elf)
croi_user_program(${_dns} PIE SYS IPC SWIFT ${PROJECT_SOURCE_DIR}/services/ndb/dns/Main.swift)
set(_ndb ${PROJECT_SOURCE_DIR}/services/ndb)
# bin/9gate (D77, D78): 9P2000 between nodes, over Noise IK.
set(_9gate ${CMAKE_CURRENT_BINARY_DIR}/gate.elf)  # a module named gate: 9gate is no identifier
croi_user_program(${_9gate} PIE SYS IPC SWIFT ${PROJECT_SOURCE_DIR}/services/9gate/9gate/Main.swift)
set(_9gate_manifest ${PROJECT_SOURCE_DIR}/services/9gate/9gate/9gate.manifest)
# bin/factotum (D75): keys, and the protocols run with them.
set(_factotum ${CMAKE_CURRENT_BINARY_DIR}/factotum.elf)
croi_user_program(${_factotum} PIE SYS IPC SWIFT ${PROJECT_SOURCE_DIR}/services/factotum/Main.swift)
set(_factotum_manifest ${PROJECT_SOURCE_DIR}/services/factotum/factotum.manifest)
# bin/ramdisk (ramdisk(4)): a disk in memory, sd(3)'s directory; and
# bin/fs (fs(4)), a Taisce volume on it (D8).
set(_ramdisk ${CMAKE_CURRENT_BINARY_DIR}/ramdisk.elf)
croi_user_program(${_ramdisk} PIE SYS IPC SWIFT ${PROJECT_SOURCE_DIR}/services/ramdisk/Main.swift)
set(_ramdisk_manifest ${PROJECT_SOURCE_DIR}/services/ramdisk/ramdisk.manifest)
set(_fs ${CMAKE_CURRENT_BINARY_DIR}/fsservice.elf)  # its module's name, fs, would differ from Fs only by case
croi_user_program(${_fs} PIE SYS IPC SWIFT ${PROJECT_SOURCE_DIR}/services/fs/Main.swift)
set(_fs_manifest ${PROJECT_SOURCE_DIR}/services/fs/fs.manifest)
# The board tools (D79): rc scripts over ctl files.
set(_scripts ${PROJECT_SOURCE_DIR}/shell/scripts)
# bin/cpu (D77): the cpu server, only in the cpu images below.
set(_cpu ${CMAKE_CURRENT_BINARY_DIR}/cpu.elf)
croi_user_program(${_cpu} PIE SYS IPC SWIFT ${PROJECT_SOURCE_DIR}/services/cpu/Main.swift)
file(GLOB_RECURSE _driver_manifests CONFIGURE_DEPENDS ${PROJECT_SOURCE_DIR}/drivers/*/driver.manifest)
list(SORT _driver_manifests)
set(_drivers_index ${CMAKE_CURRENT_BINARY_DIR}/drivers.index)
add_custom_command(OUTPUT ${_drivers_index}
  COMMAND ${CMAKE_COMMAND} -E cat ${_driver_manifests} > ${_drivers_index}
  DEPENDS ${_driver_manifests}
  COMMENT "Collecting the drivers' match records")
set(CROI_DEVMGR_IOPORT "")
set(CROI_DEVMGR_SMC "")
if(CROI_ARCH STREQUAL amd64)
  set(CROI_DEVMGR_IOPORT "resource ioport")
elseif(CROI_ARCH STREQUAL arm64)
  set(CROI_DEVMGR_SMC "resource smc")
endif()
set(_devmgr_manifest ${CMAKE_CURRENT_BINARY_DIR}/devmgr.manifest)
configure_file(${PROJECT_SOURCE_DIR}/drivers/devmgr/devmgr.manifest.in ${_devmgr_manifest} @ONLY)
set(CROI_LAUNCH_TEST_USES "")
if(CROI_ARCH STREQUAL amd64)
  list(APPEND _time_bootfs etc/manifests/time.manifest=${_manifests}/time.manifest)
  set(CROI_LAUNCH_TEST_USES "use time")
endif()
set(_launch_test_manifest ${CMAKE_CURRENT_BINARY_DIR}/launch-test.manifest)
configure_file(${_manifests}/launch-test.manifest.in ${_launch_test_manifest} @ONLY)
# The manual (D86): man/'s pages at lib/man/, with the index vx writes
# from them; manifests mount it at /lib/man.
file(GLOB _man_pages RELATIVE ${PROJECT_SOURCE_DIR}/man CONFIGURE_DEPENDS ${PROJECT_SOURCE_DIR}/man/[1-8]/*)
list(SORT _man_pages)
set(_man_bootfs)
set(_man_files)
foreach(_p ${_man_pages})
  list(APPEND _man_bootfs lib/man/${_p}=${PROJECT_SOURCE_DIR}/man/${_p})
  list(APPEND _man_files ${PROJECT_SOURCE_DIR}/man/${_p})
endforeach()
set(_man_index ${CMAKE_CURRENT_BINARY_DIR}/man.index)
add_custom_command(OUTPUT ${_man_index}
  COMMAND ${VX} man --index ${_man_index}
  WORKING_DIRECTORY ${PROJECT_SOURCE_DIR}
  DEPENDS ${_man_files} vx ${VX}
  COMMENT "Indexing the manual")
# Tier 1's programs (D47), when the *-vectraos toolchain has been built.
include(${PROJECT_SOURCE_DIR}/cmake/Tier1.cmake)
croi_tier1(_tier1_bootfs _tier1_files)
set(CROI_BOOTFS_IMAGE ${CMAKE_BINARY_DIR}/bootfs.img PARENT_SCOPE)
set(_bootfs_entries bin/m2=${_m2} bin/sys-test=${_sys_test} bin/dl-test=${_dl_test}
          lib/libdltest.so=${_dl_c} lib/libdlswift.so=${_dl_swift} bin/link-test=${_link_test} bin/link-stale=${_link_stale}
          lib/liblinka.so=${_link_a} lib/liblinkb.so=${_link_b} bin/trace-test=${_trace_test} bin/ipc-test=${_ipc_test}
          bin/node-test=${_node_test} bin/acpi-test=${_acpi_test} bin/irq-test=${_irq_test} bin/pci-test=${_pci_test} bin/warmboot-test=${_warmboot_test}
          bin/launcher=${_launcher} bin/launch-service=${_launch_service}
          bin/launch-test=${_launch_test} etc/manifests/a.manifest=${_manifests}/a.manifest
          etc/manifests/b.manifest=${_manifests}/b.manifest
          etc/manifests/launch-test.manifest=${_launch_test_manifest} ${_time_bootfs}
          bin/bootfs=${_bootfs_service} etc/manifests/bootfs.manifest=${_manifests}/bootfs.manifest
          bin/devmgr=${_devmgr} bin/edu=${_edu} bin/virtio-input=${_virtio_input} bin/virtio-net=${_virtio_net} bin/rge=${_rge} bin/virtio-blk=${_virtio_blk} bin/nvme=${_nvme} bin/xhci=${_xhci} bin/scmi=${_scmi} bin/mali=${_mali} bin/virtio-gpu=${_virtio_gpu} bin/linlon=${_linlon} etc/drivers=${_drivers_index}
          etc/manifests/devmgr.manifest=${_devmgr_manifest}
          bin/kbdfs=${_kbdfs} etc/manifests/kbdfs.manifest=${PROJECT_SOURCE_DIR}/services/kbdfs/kbdfs.manifest
          bin/mouse=${_mouse} etc/manifests/mouse.manifest=${PROJECT_SOURCE_DIR}/services/mouse/mouse.manifest
          bin/power=${_power} etc/manifests/power.manifest=${PROJECT_SOURCE_DIR}/services/power/power.manifest
          bin/console=${_console} etc/manifests/console.manifest=${PROJECT_SOURCE_DIR}/services/console/console.manifest
          bin/plumber=${_plumber} etc/manifests/plumber.manifest=${PROJECT_SOURCE_DIR}/services/plumber/plumber.manifest
          ${_man_bootfs} lib/man/index=${_man_index}
          bin/proc=${_proc} etc/manifests/proc.manifest=${PROJECT_SOURCE_DIR}/services/proc/proc.manifest
          bin/net=${_net} etc/manifests/net.manifest=${PROJECT_SOURCE_DIR}/services/net/net.manifest
          bin/cs=${_cs} etc/manifests/cs.manifest=${_ndb}/cs/cs.manifest
          bin/dns=${_dns} etc/manifests/dns.manifest=${_ndb}/dns/dns.manifest
          lib/ndb/local=${_ndb}/db/local lib/ndb/common=${_ndb}/db/common
          bin/9gate=${_9gate} etc/manifests/9gate.manifest=${_9gate_manifest}
          bin/factotum=${_factotum} etc/manifests/factotum.manifest=${_factotum_manifest}
          lib/factotum/keys=${PROJECT_SOURCE_DIR}/services/factotum/keys
          bin/ramdisk=${_ramdisk}
          bin/fs=${_fs} etc/manifests/fs.manifest=${_fs_manifest}
          bin/log=${_scripts}/log bin/restart=${_scripts}/restart bin/reboot=${_scripts}/reboot
          bin/poweroff=${_scripts}/poweroff bin/warmboot=${_scripts}/warmboot bin/trace=${_scripts}/trace
          ${_tier1_bootfs})
set(_bootfs_depends ${_m2} ${_sys_test} ${_dl_test} ${_dl_c} ${_dl_swift} ${_link_test} ${_link_stale} ${_link_a} ${_link_b} ${_trace_test} ${_ipc_test} ${_node_test} ${_acpi_test} ${_irq_test} ${_pci_test} ${_warmboot_test}
          ${_launcher} ${_launch_service} ${_launch_test} ${_manifests}/a.manifest ${_manifests}/b.manifest
          ${_launch_test_manifest} ${_time} ${_manifests}/time.manifest
          ${_bootfs_service} ${_manifests}/bootfs.manifest
          ${_devmgr} ${_edu} ${_virtio_input} ${_virtio_net} ${_rge} ${_virtio_blk} ${_nvme} ${_xhci} ${_scmi} ${_mali} ${_virtio_gpu} ${_linlon} ${_drivers_index} ${_devmgr_manifest}
          ${_kbdfs} ${PROJECT_SOURCE_DIR}/services/kbdfs/kbdfs.manifest
          ${_mouse} ${PROJECT_SOURCE_DIR}/services/mouse/mouse.manifest
          ${_power} ${PROJECT_SOURCE_DIR}/services/power/power.manifest
          ${_console} ${PROJECT_SOURCE_DIR}/services/console/console.manifest
          ${_plumber} ${PROJECT_SOURCE_DIR}/services/plumber/plumber.manifest
          ${_proc} ${PROJECT_SOURCE_DIR}/services/proc/proc.manifest
          ${_net} ${PROJECT_SOURCE_DIR}/services/net/net.manifest
          ${_cs} ${_ndb}/cs/cs.manifest ${_dns} ${_ndb}/dns/dns.manifest ${_ndb}/db/local ${_ndb}/db/common
          ${_9gate} ${_9gate_manifest} ${_factotum} ${_factotum_manifest} ${PROJECT_SOURCE_DIR}/services/factotum/keys
          ${_ramdisk} ${_fs} ${_fs_manifest}
          ${_scripts}/log ${_scripts}/restart ${_scripts}/reboot ${_scripts}/poweroff ${_scripts}/warmboot
          ${_scripts}/trace
          ${_man_files} ${_man_index} ${_tier1_files} vx ${VX})
add_custom_command(OUTPUT ${CMAKE_BINARY_DIR}/bootfs.img
  COMMAND ${VX} mkbootfs ${CMAKE_BINARY_DIR}/bootfs.img ${_bootfs_entries}
  DEPENDS ${_bootfs_depends}
  COMMENT "Building bootfs")
add_custom_target(bootfs DEPENDS ${CMAKE_BINARY_DIR}/bootfs.img)
# boot-warmboot's (D101): bootfs and this build's kernel at
# lib/warm/kernel.elf, which bin/warmboot-test warm-boots into.
add_custom_command(OUTPUT ${CMAKE_BINARY_DIR}/bootfs-warmboot.img
  COMMAND ${VX} mkbootfs ${CMAKE_BINARY_DIR}/bootfs-warmboot.img ${_bootfs_entries}
          lib/warm/kernel.elf=$<TARGET_FILE:kernel>
  DEPENDS ${_bootfs_depends} kernel
  COMMENT "Building bootfs for boot-warmboot")
add_custom_target(bootfs-warmboot DEPENDS ${CMAKE_BINARY_DIR}/bootfs-warmboot.img)
# The cpu images (D77): bootfs and the cpu server, its manifest, the key
# of the terminal it answers (lib/cpu/terminal) and the node's own key,
# which the terminal knows (lib/factotum/keys), which no other image has.
# bootfs-cpu-test.img has the tests' keys (boot-cpu); bootfs-cpu.img the
# ones vx boot --cpu writes to cpu/terminal and cpu/keys.
# Without the launcher's own test and its services, which judge a normal
# image.
set(_cpu_image_entries ${_bootfs_entries})
list(FILTER _cpu_image_entries EXCLUDE REGEX "^(bin/launch-test|etc/manifests/(launch-test|a|b)\\.manifest|lib/factotum/keys)=")
set(_cpu_entries bin/cpu=${_cpu} etc/manifests/cpu.manifest=${PROJECT_SOURCE_DIR}/services/cpu/cpu.manifest
          etc/launcher/push=${PROJECT_SOURCE_DIR}/system/launch/launcher/push
          bin/minimal-hot=${_minimal_hot}
          etc/manifests/minimal-hot.manifest=${PROJECT_SOURCE_DIR}/sdk/examples/minimal/hot/minimal-hot.manifest)
set(_cpu_test_key ${PROJECT_SOURCE_DIR}/services/cpu/tests/terminal.pub)
set(_cpu_test_node ${PROJECT_SOURCE_DIR}/services/cpu/tests/node.keys)
add_custom_command(OUTPUT ${CMAKE_BINARY_DIR}/bootfs-cpu-test.img
  COMMAND ${VX} mkbootfs ${CMAKE_BINARY_DIR}/bootfs-cpu-test.img ${_cpu_image_entries} ${_cpu_entries}
          lib/cpu/terminal=${_cpu_test_key} lib/factotum/keys=${_cpu_test_node}
  DEPENDS ${_bootfs_depends} ${_cpu} ${PROJECT_SOURCE_DIR}/services/cpu/cpu.manifest ${PROJECT_SOURCE_DIR}/system/launch/launcher/push
          ${_minimal_hot} ${PROJECT_SOURCE_DIR}/sdk/examples/minimal/hot/minimal-hot.manifest
          ${_cpu_test_key} ${_cpu_test_node}
  COMMENT "Building bootfs for boot-cpu")
add_custom_target(bootfs-cpu-test DEPENDS ${CMAKE_BINARY_DIR}/bootfs-cpu-test.img)
add_custom_command(OUTPUT ${CMAKE_BINARY_DIR}/bootfs-cpu.img
  COMMAND ${VX} mkbootfs ${CMAKE_BINARY_DIR}/bootfs-cpu.img ${_cpu_image_entries} ${_cpu_entries}
          lib/cpu/terminal=${CMAKE_BINARY_DIR}/cpu/terminal lib/factotum/keys=${CMAKE_BINARY_DIR}/cpu/keys
  DEPENDS ${_bootfs_depends} ${_cpu} ${PROJECT_SOURCE_DIR}/services/cpu/cpu.manifest ${PROJECT_SOURCE_DIR}/system/launch/launcher/push
          ${_minimal_hot} ${PROJECT_SOURCE_DIR}/sdk/examples/minimal/hot/minimal-hot.manifest
          ${CMAKE_BINARY_DIR}/cpu/terminal ${CMAKE_BINARY_DIR}/cpu/keys
  COMMENT "Building bootfs for vx boot --cpu")
add_custom_target(bootfs-cpu DEPENDS ${CMAKE_BINARY_DIR}/bootfs-cpu.img)
# The board images: every service, the console and its shell among them,
# with fs on an NVMe disk's taisce partition
# (services/fs/fs-nvme.manifest), and without the test programs or the
# launcher's own test and its services. bootfs-board.img runs until
# bin/board-test ends; bootfs-board-cpu.img is the board's V3 link, with
# a cpu server for this terminal (the keys `vx cpu-keys` writes), which
# vx remote boot --image board-cpu sends.
set(_board_entries ${_bootfs_entries})
list(FILTER _board_entries EXCLUDE REGEX "^(bin/(m2|sys-test|dl-test|link-test|link-stale|trace-test|ipc-test|node-test|acpi-test|irq-test|pci-test|warmboot-test|launch-service|launch-test)|lib/lib(dltest|dlswift|linka|linkb)\\.so|lib/factotum/keys|etc/manifests/(launch-test|a|b|fs)\\.manifest)=")
list(APPEND _board_entries etc/manifests/fs.manifest=${PROJECT_SOURCE_DIR}/services/fs/fs-nvme.manifest)
set(_board_depends ${_bootfs_depends} ${PROJECT_SOURCE_DIR}/services/fs/fs-nvme.manifest)
add_custom_command(OUTPUT ${CMAKE_BINARY_DIR}/bootfs-board.img
  COMMAND ${VX} mkbootfs ${CMAKE_BINARY_DIR}/bootfs-board.img ${_board_entries}
          lib/factotum/keys=${PROJECT_SOURCE_DIR}/services/factotum/keys bin/board-test=${_board_test}
          etc/manifests/board-test.manifest=${PROJECT_SOURCE_DIR}/services/board-test/board-test.manifest
  DEPENDS ${_board_depends} ${_board_test} ${PROJECT_SOURCE_DIR}/services/board-test/board-test.manifest
  COMMENT "Building bootfs for the board")
add_custom_target(bootfs-board DEPENDS ${CMAKE_BINARY_DIR}/bootfs-board.img)
add_custom_target(cpu-keys
  COMMAND ${VX} cpu-keys ${CMAKE_BINARY_DIR}/cpu
  BYPRODUCTS ${CMAKE_BINARY_DIR}/cpu/terminal ${CMAKE_BINARY_DIR}/cpu/keys
  DEPENDS vx
  COMMENT "Writing the cpu image's keys")
add_custom_command(OUTPUT ${CMAKE_BINARY_DIR}/bootfs-board-cpu.img
  COMMAND ${VX} mkbootfs ${CMAKE_BINARY_DIR}/bootfs-board-cpu.img ${_board_entries} ${_cpu_entries}
          lib/cpu/terminal=${CMAKE_BINARY_DIR}/cpu/terminal lib/factotum/keys=${CMAKE_BINARY_DIR}/cpu/keys
  DEPENDS ${_board_depends} ${_cpu} ${PROJECT_SOURCE_DIR}/services/cpu/cpu.manifest ${PROJECT_SOURCE_DIR}/system/launch/launcher/push
          ${_minimal_hot} ${PROJECT_SOURCE_DIR}/sdk/examples/minimal/hot/minimal-hot.manifest
          ${CMAKE_BINARY_DIR}/cpu/terminal ${CMAKE_BINARY_DIR}/cpu/keys
  COMMENT "Building bootfs for the board's cpu server")
add_custom_target(bootfs-board-cpu DEPENDS ${CMAKE_BINARY_DIR}/bootfs-board-cpu.img)
add_dependencies(bootfs-board-cpu cpu-keys)
# The desktop's images (D107): bootfs and Radharc, which takes the
# framebuffer from the console and /dev/kbd from its shell, without the
# launcher's own test and its services. bootfs-desktop-test.img has
# desktop-test (boot-desktop); bootfs-desktop.img is vx boot --desktop's.
# The faces Kit's programs choose from (data/fonts, with their licences):
# lib/fonts/<family>/<file>.
file(GLOB _font_files RELATIVE ${PROJECT_SOURCE_DIR}/data/fonts CONFIGURE_DEPENDS
     ${PROJECT_SOURCE_DIR}/data/fonts/*/*.ttf ${PROJECT_SOURCE_DIR}/data/fonts/*/*.otf
     ${PROJECT_SOURCE_DIR}/data/fonts/*/OFL.txt ${PROJECT_SOURCE_DIR}/data/fonts/*/LICENSE.md)
list(FILTER _font_files EXCLUDE REGEX "^spleen/")
set(_font_entries)
set(_font_depends)
foreach(_f ${_font_files})
  list(APPEND _font_entries lib/fonts/${_f}=${PROJECT_SOURCE_DIR}/data/fonts/${_f})
  list(APPEND _font_depends ${PROJECT_SOURCE_DIR}/data/fonts/${_f})
endforeach()
# Radharc, its themes and its faces: the desktop's images', and the board's.
set(_radharc_entries bin/radharc=${_radharc} etc/manifests/radharc.manifest=${PROJECT_SOURCE_DIR}/services/radharc/radharc.manifest
          lib/theme/platinum-indigo=${PROJECT_SOURCE_DIR}/ui/theme/themes/platinum-indigo
          lib/theme/neon-tab=${PROJECT_SOURCE_DIR}/ui/theme/themes/neon-tab ${_font_entries})
set(_radharc_depends ${_radharc} ${PROJECT_SOURCE_DIR}/services/radharc/radharc.manifest
  ${PROJECT_SOURCE_DIR}/ui/theme/themes/platinum-indigo ${PROJECT_SOURCE_DIR}/ui/theme/themes/neon-tab ${_font_depends})
set(_desktop_entries ${_cpu_image_entries} lib/factotum/keys=${PROJECT_SOURCE_DIR}/services/factotum/keys ${_radharc_entries})
set(_desktop_depends ${_bootfs_depends} ${_radharc_depends})
add_custom_command(OUTPUT ${CMAKE_BINARY_DIR}/bootfs-desktop-test.img
  COMMAND ${VX} mkbootfs ${CMAKE_BINARY_DIR}/bootfs-desktop-test.img ${_desktop_entries}
          bin/desktop-test=${_desktop_test}
          etc/manifests/desktop-test.manifest=${PROJECT_SOURCE_DIR}/services/radharc/tests/native/desktop-test.manifest
  DEPENDS ${_desktop_depends} ${_desktop_test} ${PROJECT_SOURCE_DIR}/services/radharc/tests/native/desktop-test.manifest
  COMMENT "Building bootfs for boot-desktop")
add_custom_target(bootfs-desktop-test DEPENDS ${CMAKE_BINARY_DIR}/bootfs-desktop-test.img)
# The workspaces (D116): master-stack, the first layout for `tile`, and
# chords, which holds Radharc's shortcuts. Only in vx boot --desktop's
# image and boot-workspaces': chords asks on the trusted prompt as it
# starts, which other desktop tests would see.
set(_master_stack ${CMAKE_CURRENT_BINARY_DIR}/masterstack.elf)
croi_user_program(${_master_stack} PIE SYS IPC SWIFT ${PROJECT_SOURCE_DIR}/shell/layouts/master-stack/Main.swift
  ${PROJECT_SOURCE_DIR}/shell/layouts/master-stack/lib/MasterStack.swift)
set(_chords ${CMAKE_CURRENT_BINARY_DIR}/chords.elf)
croi_user_program(${_chords} PIE SYS IPC SWIFT ${PROJECT_SOURCE_DIR}/shell/chords/Main.swift
  ${PROJECT_SOURCE_DIR}/shell/chords/lib/ChordMap.swift)
set(_workspaces_test ${CMAKE_CURRENT_BINARY_DIR}/workspacestest.elf)
croi_user_program(${_workspaces_test} PIE SYS IPC SWIFT ${PROJECT_SOURCE_DIR}/shell/layouts/tests/native/Main.swift)
set(_workspaces_entries bin/master-stack=${_master_stack}
    etc/manifests/master-stack.manifest=${PROJECT_SOURCE_DIR}/shell/layouts/master-stack/master-stack.manifest
    bin/chords=${_chords} etc/manifests/chords.manifest=${PROJECT_SOURCE_DIR}/shell/chords/chords.manifest)
set(_workspaces_depends ${_master_stack} ${PROJECT_SOURCE_DIR}/shell/layouts/master-stack/master-stack.manifest
    ${_chords} ${PROJECT_SOURCE_DIR}/shell/chords/chords.manifest)
set(_workspaces_tests ${PROJECT_SOURCE_DIR}/shell/layouts/tests/native)
add_custom_command(OUTPUT ${CMAKE_BINARY_DIR}/bootfs-workspaces-test.img
  COMMAND ${VX} mkbootfs ${CMAKE_BINARY_DIR}/bootfs-workspaces-test.img ${_desktop_entries} ${_workspaces_entries}
          bin/workspaces-test=${_workspaces_test}
          etc/manifests/workspaces-test.manifest=${_workspaces_tests}/workspaces-test.manifest
          etc/manifests/master-stack-next.manifest=${_workspaces_tests}/master-stack-next.manifest
  DEPENDS ${_desktop_depends} ${_workspaces_depends} ${_workspaces_test} ${_workspaces_tests}/workspaces-test.manifest
          ${_workspaces_tests}/master-stack-next.manifest
  COMMENT "Building bootfs for boot-workspaces")
add_custom_target(bootfs-workspaces-test DEPENDS ${CMAKE_BINARY_DIR}/bootfs-workspaces-test.img)
# boot-display's (D120): the desktop with display-test; QEMU adds a
# virtio GPU (CMakeLists.txt).
set(_display_test ${CMAKE_CURRENT_BINARY_DIR}/displaytest.elf)
croi_user_program(${_display_test} PIE SYS IPC SWIFT ${PROJECT_SOURCE_DIR}/drivers/display/tests/native/Main.swift)
set(_display_tests ${PROJECT_SOURCE_DIR}/drivers/display/tests/native)
add_custom_command(OUTPUT ${CMAKE_BINARY_DIR}/bootfs-display-test.img
  COMMAND ${VX} mkbootfs ${CMAKE_BINARY_DIR}/bootfs-display-test.img ${_desktop_entries}
          bin/display-test=${_display_test} etc/manifests/display-test.manifest=${_display_tests}/display-test.manifest
  DEPENDS ${_desktop_depends} ${_display_test} ${_display_tests}/display-test.manifest
  COMMENT "Building bootfs for boot-display")
add_custom_target(bootfs-display-test DEPENDS ${CMAKE_BINARY_DIR}/bootfs-display-test.img)
# boot-venus's (D121): the desktop with loinnir-test; QEMU adds a virtio GPU
# with Venus (CMakeLists.txt).
set(_loinnir_test ${CMAKE_CURRENT_BINARY_DIR}/loinnirtest.elf)
croi_user_program(${_loinnir_test} PIE SYS IPC SWIFT ${PROJECT_SOURCE_DIR}/graphics/loinnir/tests/native/Main.swift
  ${PROJECT_SOURCE_DIR}/graphics/loinnir/tests/native/generated/LoinnirShaders.swift
  INCLUDES ${PROJECT_SOURCE_DIR}/graphics/vulkan/c/include ${PROJECT_SOURCE_DIR}/graphics/venus/c/include)
set(_loinnir_tests ${PROJECT_SOURCE_DIR}/graphics/loinnir/tests/native)
set(_compose_test ${CMAKE_CURRENT_BINARY_DIR}/composetest.elf)
croi_user_program(${_compose_test} PIE SYS IPC SWIFT ${PROJECT_SOURCE_DIR}/services/radharc/tests/gpu/Main.swift
  INCLUDES ${PROJECT_SOURCE_DIR}/graphics/vulkan/c/include ${PROJECT_SOURCE_DIR}/graphics/venus/c/include)
set(_compose_tests ${PROJECT_SOURCE_DIR}/services/radharc/tests/gpu)
# boot-rio's (D129): Radharc's CPU renderer, a 1080p scene composed and timed.
set(_compose_cpu ${CMAKE_CURRENT_BINARY_DIR}/composecpu.elf)
croi_user_program(${_compose_cpu} PIE SYS IPC SWIFT ${PROJECT_SOURCE_DIR}/services/radharc/tests/cpu/Main.swift)
set(_compose_cpu_manifest ${PROJECT_SOURCE_DIR}/services/radharc/tests/cpu/compose-cpu.manifest)
add_custom_command(OUTPUT ${CMAKE_BINARY_DIR}/bootfs-venus-test.img
  COMMAND ${VX} mkbootfs ${CMAKE_BINARY_DIR}/bootfs-venus-test.img ${_desktop_entries}
          bin/loinnir-test=${_loinnir_test} etc/manifests/loinnir-test.manifest=${_loinnir_tests}/loinnir-test.manifest
          bin/compose-test=${_compose_test} etc/manifests/compose-test.manifest=${_compose_tests}/compose-test.manifest
  DEPENDS ${_desktop_depends} ${_loinnir_test} ${_loinnir_tests}/loinnir-test.manifest ${_compose_test}
          ${_compose_tests}/compose-test.manifest
  COMMENT "Building bootfs for boot-venus")
add_custom_target(bootfs-venus-test DEPENDS ${CMAKE_BINARY_DIR}/bootfs-venus-test.img)
# boot-lock's (D118): the desktop with factotum's keys the login key, and
# lock-test.
set(_lock_test ${CMAKE_CURRENT_BINARY_DIR}/locktest.elf)
croi_user_program(${_lock_test} PIE SYS IPC SWIFT ${PROJECT_SOURCE_DIR}/services/radharc/tests/lock/Main.swift)
set(_lock_tests ${PROJECT_SOURCE_DIR}/services/radharc/tests/lock)
set(_lock_entries ${_desktop_entries})
list(FILTER _lock_entries EXCLUDE REGEX "^lib/factotum/keys=")
add_custom_command(OUTPUT ${CMAKE_BINARY_DIR}/bootfs-lock-test.img
  COMMAND ${VX} mkbootfs ${CMAKE_BINARY_DIR}/bootfs-lock-test.img ${_lock_entries}
          lib/factotum/keys=${_lock_tests}/keys bin/lock-test=${_lock_test}
          etc/manifests/lock-test.manifest=${_lock_tests}/lock-test.manifest
  DEPENDS ${_desktop_depends} ${_lock_test} ${_lock_tests}/keys ${_lock_tests}/lock-test.manifest
  COMMENT "Building bootfs for boot-lock")
add_custom_target(bootfs-lock-test DEPENDS ${CMAKE_BINARY_DIR}/bootfs-lock-test.img)
# boot-sdk's: the desktop with sdk-test and minimal.
add_custom_command(OUTPUT ${CMAKE_BINARY_DIR}/bootfs-sdk-test.img
  COMMAND ${VX} mkbootfs ${CMAKE_BINARY_DIR}/bootfs-sdk-test.img ${_desktop_entries}
          bin/sdk-test=${_sdk_test} etc/manifests/sdk-test.manifest=${PROJECT_SOURCE_DIR}/sdk/tests/native/sdk-test.manifest
          bin/minimal=${_minimal} etc/manifests/minimal.manifest=${PROJECT_SOURCE_DIR}/sdk/examples/minimal/minimal.manifest
  DEPENDS ${_desktop_depends} ${_sdk_test} ${_minimal} ${PROJECT_SOURCE_DIR}/sdk/tests/native/sdk-test.manifest
          ${PROJECT_SOURCE_DIR}/sdk/examples/minimal/minimal.manifest
  COMMENT "Building bootfs for boot-sdk")
add_custom_target(bootfs-sdk-test DEPENDS ${CMAKE_BINARY_DIR}/bootfs-sdk-test.img)
# boot-kit's, with tier 1: the desktop with kit-test and the sample's
# digests.
get_property(_kit_test GLOBAL PROPERTY CROI_TIER1_KIT_TEST)
if(_kit_test)
  add_custom_command(OUTPUT ${CMAKE_BINARY_DIR}/bootfs-kit-test.img
    COMMAND ${VX} mkbootfs ${CMAKE_BINARY_DIR}/bootfs-kit-test.img ${_desktop_entries}
            bin/kit-test=${_kit_test} etc/manifests/kit-test.manifest=${PROJECT_SOURCE_DIR}/ui/kit/tests/native/kit-test.manifest
            lib/kit/kit-sample.tsv=${PROJECT_SOURCE_DIR}/ui/kit/tests/kit-sample.tsv
    DEPENDS ${_desktop_depends} ${_kit_test} ${PROJECT_SOURCE_DIR}/ui/kit/tests/native/kit-test.manifest
            ${PROJECT_SOURCE_DIR}/ui/kit/tests/kit-sample.tsv
    COMMENT "Building bootfs for boot-kit")
  add_custom_target(bootfs-kit-test DEPENDS ${CMAKE_BINARY_DIR}/bootfs-kit-test.img)
endif()
# rio, with tier 1: its windows in vx boot --desktop's image, and in
# boot-rio's with rio-test (not in the other tests', whose windows and
# pixels its first window would cover).
get_property(_rio GLOBAL PROPERTY CROI_TIER1_RIO)
get_property(_rio_test GLOBAL PROPERTY CROI_TIER1_RIO_TEST)
get_property(_vt GLOBAL PROPERTY CROI_TIER1_VT)
get_property(_vt_test GLOBAL PROPERTY CROI_TIER1_VT_TEST)
get_property(_tracker GLOBAL PROPERTY CROI_TIER1_TRACKER)
get_property(_tracker_test GLOBAL PROPERTY CROI_TIER1_TRACKER_TEST)
get_property(_deskbar GLOBAL PROPERTY CROI_TIER1_DESKBAR)
get_property(_deskbar_test GLOBAL PROPERTY CROI_TIER1_DESKBAR_TEST)
get_property(_preferences GLOBAL PROPERTY CROI_TIER1_PREFERENCES)
get_property(_inspector GLOBAL PROPERTY CROI_TIER1_INSPECTOR)
get_property(_settings_test GLOBAL PROPERTY CROI_TIER1_SETTINGS_TEST)
get_property(_notices GLOBAL PROPERTY CROI_TIER1_NOTICES)
get_property(_notices_test GLOBAL PROPERTY CROI_TIER1_NOTICES_TEST)
get_property(_guide GLOBAL PROPERTY CROI_TIER1_GUIDE)
set(_rio_entries)
set(_rio_depends)
set(_tracker_entries)
set(_tracker_depends)
set(_deskbar_entries)
set(_deskbar_depends)
set(_settings_entries)
set(_settings_depends)
set(_notices_entries)
set(_notices_depends)
set(_guide_entries)
set(_guide_depends)
if(_rio)
  # (vt with it: it runs in rio's windows.)
  set(_rio_entries bin/rio=${_rio} etc/manifests/rio.manifest=${PROJECT_SOURCE_DIR}/shell/rio/rio.manifest bin/vt=${_vt})
  set(_rio_depends ${_rio} ${PROJECT_SOURCE_DIR}/shell/rio/rio.manifest ${_vt})
  set(_tracker_entries bin/tracker=${_tracker}
      etc/manifests/tracker.manifest=${PROJECT_SOURCE_DIR}/shell/tracker/tracker.manifest)
  set(_tracker_depends ${_tracker} ${PROJECT_SOURCE_DIR}/shell/tracker/tracker.manifest)
  set(_deskbar_entries bin/deskbar=${_deskbar}
      etc/manifests/deskbar.manifest=${PROJECT_SOURCE_DIR}/shell/deskbar/deskbar.manifest)
  set(_deskbar_depends ${_deskbar} ${PROJECT_SOURCE_DIR}/shell/deskbar/deskbar.manifest)
  # The Settings app (D115): a preference app a manifest, and the Inspector.
  set(_settings_entries bin/preferences=${_preferences} bin/inspector=${_inspector}
      etc/manifests/inspector.manifest=${PROJECT_SOURCE_DIR}/shell/inspector/inspector.manifest)
  set(_settings_depends ${_preferences} ${_inspector} ${PROJECT_SOURCE_DIR}/shell/inspector/inspector.manifest)
  # Notices (D117): the slips and the drawer.
  set(_notices_entries bin/notices=${_notices}
      etc/manifests/notices.manifest=${PROJECT_SOURCE_DIR}/shell/notices/notices.manifest)
  set(_notices_depends ${_notices} ${PROJECT_SOURCE_DIR}/shell/notices/notices.manifest)
  # guide (guide(1)): the manual as hypertext, an app.
  set(_guide_entries bin/guide=${_guide} etc/manifests/guide.manifest=${PROJECT_SOURCE_DIR}/shell/guide/guide.manifest)
  set(_guide_depends ${_guide} ${PROJECT_SOURCE_DIR}/shell/guide/guide.manifest)
  foreach(_area appearance keyboard mouse deskbar grants)
    set(_m ${PROJECT_SOURCE_DIR}/shell/preferences/prefs-${_area}.manifest)
    list(APPEND _settings_entries etc/manifests/prefs-${_area}.manifest=${_m})
    list(APPEND _settings_depends ${_m})
  endforeach()
  add_custom_command(OUTPUT ${CMAKE_BINARY_DIR}/bootfs-rio-test.img
    COMMAND ${VX} mkbootfs ${CMAKE_BINARY_DIR}/bootfs-rio-test.img ${_desktop_entries} ${_rio_entries}
            bin/rio-test=${_rio_test}
            etc/manifests/rio-test.manifest=${PROJECT_SOURCE_DIR}/shell/rio/tests/native/rio-test.manifest
            bin/minimal=${_minimal} etc/manifests/minimal.manifest=${PROJECT_SOURCE_DIR}/shell/rio/tests/native/minimal.manifest
            bin/compose-cpu=${_compose_cpu} etc/manifests/compose-cpu.manifest=${_compose_cpu_manifest}
    DEPENDS ${_desktop_depends} ${_rio_depends} ${_rio_test} ${PROJECT_SOURCE_DIR}/shell/rio/tests/native/rio-test.manifest
            ${_minimal} ${PROJECT_SOURCE_DIR}/shell/rio/tests/native/minimal.manifest ${_compose_cpu} ${_compose_cpu_manifest}
    COMMENT "Building bootfs for boot-rio")
  add_custom_target(bootfs-rio-test DEPENDS ${CMAKE_BINARY_DIR}/bootfs-rio-test.img)
  # boot-vt's: rio, vt and vt-test, which is also the program vt runs.
  add_custom_command(OUTPUT ${CMAKE_BINARY_DIR}/bootfs-vt-test.img
    COMMAND ${VX} mkbootfs ${CMAKE_BINARY_DIR}/bootfs-vt-test.img ${_desktop_entries} ${_rio_entries}
            bin/vt-test=${_vt_test}
            etc/manifests/vt-test.manifest=${PROJECT_SOURCE_DIR}/shell/vt/tests/native/vt-test.manifest
    DEPENDS ${_desktop_depends} ${_rio_depends} ${_vt_test} ${PROJECT_SOURCE_DIR}/shell/vt/tests/native/vt-test.manifest
    COMMENT "Building bootfs for boot-vt")
  add_custom_target(bootfs-vt-test DEPENDS ${CMAKE_BINARY_DIR}/bootfs-vt-test.img)
  # boot-tracker's: Tracker and tracker-test (the desktop, the chooser, and
  # the 100k listing check).
  add_custom_command(OUTPUT ${CMAKE_BINARY_DIR}/bootfs-tracker-test.img
    COMMAND ${VX} mkbootfs ${CMAKE_BINARY_DIR}/bootfs-tracker-test.img ${_desktop_entries} ${_tracker_entries}
            bin/tracker-test=${_tracker_test}
            etc/manifests/tracker-test.manifest=${PROJECT_SOURCE_DIR}/shell/tracker/tests/native/tracker-test.manifest
    DEPENDS ${_desktop_depends} ${_tracker_depends} ${_tracker_test}
            ${PROJECT_SOURCE_DIR}/shell/tracker/tests/native/tracker-test.manifest
    COMMENT "Building bootfs for boot-tracker")
  add_custom_target(bootfs-tracker-test DEPENDS ${CMAKE_BINARY_DIR}/bootfs-tracker-test.img)
  # boot-deskbar's: Deskbar (saying what it does), minimal as an app, and
  # deskbar-test.
  set(_deskbar_tests ${PROJECT_SOURCE_DIR}/shell/deskbar/tests/native)
  add_custom_command(OUTPUT ${CMAKE_BINARY_DIR}/bootfs-deskbar-test.img
    COMMAND ${VX} mkbootfs ${CMAKE_BINARY_DIR}/bootfs-deskbar-test.img ${_desktop_entries}
            bin/deskbar=${_deskbar} etc/manifests/deskbar.manifest=${_deskbar_tests}/deskbar.manifest
            bin/minimal=${_minimal} etc/manifests/minimal.manifest=${_deskbar_tests}/minimal.manifest
            bin/deskbar-test=${_deskbar_test} etc/manifests/deskbar-test.manifest=${_deskbar_tests}/deskbar-test.manifest
    DEPENDS ${_desktop_depends} ${_deskbar} ${_minimal} ${_deskbar_test} ${_deskbar_tests}/deskbar.manifest
            ${_deskbar_tests}/minimal.manifest ${_deskbar_tests}/deskbar-test.manifest
    COMMENT "Building bootfs for boot-deskbar")
  add_custom_target(bootfs-deskbar-test DEPENDS ${CMAKE_BINARY_DIR}/bootfs-deskbar-test.img)
  # boot-settings's: Keyboard's and Grants' preference apps and the
  # Inspector, as plain services settings-test uses.
  set(_settings_tests ${PROJECT_SOURCE_DIR}/shell/preferences/tests/native)
  add_custom_command(OUTPUT ${CMAKE_BINARY_DIR}/bootfs-settings-test.img
    COMMAND ${VX} mkbootfs ${CMAKE_BINARY_DIR}/bootfs-settings-test.img ${_desktop_entries}
            bin/preferences=${_preferences} etc/manifests/prefs-keyboard.manifest=${_settings_tests}/prefs-keyboard.manifest
            etc/manifests/prefs-grants.manifest=${_settings_tests}/prefs-grants.manifest
            bin/inspector=${_inspector} etc/manifests/inspector.manifest=${_settings_tests}/inspector.manifest
            bin/settings-test=${_settings_test} etc/manifests/settings-test.manifest=${_settings_tests}/settings-test.manifest
    DEPENDS ${_desktop_depends} ${_preferences} ${_inspector} ${_settings_test} ${_settings_tests}/prefs-keyboard.manifest
            ${_settings_tests}/prefs-grants.manifest ${_settings_tests}/inspector.manifest
            ${_settings_tests}/settings-test.manifest
    COMMENT "Building bootfs for boot-settings")
  add_custom_target(bootfs-settings-test DEPENDS ${CMAKE_BINARY_DIR}/bootfs-settings-test.img)
  # boot-notices's: notices (saying what it does) and notices-test.
  set(_notices_tests ${PROJECT_SOURCE_DIR}/shell/notices/tests/native)
  add_custom_command(OUTPUT ${CMAKE_BINARY_DIR}/bootfs-notices-test.img
    COMMAND ${VX} mkbootfs ${CMAKE_BINARY_DIR}/bootfs-notices-test.img ${_desktop_entries}
            bin/notices=${_notices} etc/manifests/notices.manifest=${_notices_tests}/notices.manifest
            bin/notices-test=${_notices_test} etc/manifests/notices-test.manifest=${_notices_tests}/notices-test.manifest
    DEPENDS ${_desktop_depends} ${_notices} ${_notices_test} ${_notices_tests}/notices.manifest
            ${_notices_tests}/notices-test.manifest
    COMMENT "Building bootfs for boot-notices")
  add_custom_target(bootfs-notices-test DEPENDS ${CMAKE_BINARY_DIR}/bootfs-notices-test.img)
  # boot-guide's: guide as a plain service, and guide-test.
  set(_guide_test ${CMAKE_CURRENT_BINARY_DIR}/guidetest.elf)
  croi_user_program(${_guide_test} PIE SYS IPC SWIFT ${PROJECT_SOURCE_DIR}/shell/guide/tests/native/Main.swift)
  set(_guide_tests ${PROJECT_SOURCE_DIR}/shell/guide/tests/native)
  add_custom_command(OUTPUT ${CMAKE_BINARY_DIR}/bootfs-guide-test.img
    COMMAND ${VX} mkbootfs ${CMAKE_BINARY_DIR}/bootfs-guide-test.img ${_desktop_entries}
            bin/guide=${_guide} etc/manifests/guide.manifest=${_guide_tests}/guide.manifest
            bin/guide-test=${_guide_test} etc/manifests/guide-test.manifest=${_guide_tests}/guide-test.manifest
    DEPENDS ${_desktop_depends} ${_guide} ${_guide_test} ${_guide_tests}/guide.manifest ${_guide_tests}/guide-test.manifest
    COMMENT "Building bootfs for boot-guide")
  add_custom_target(bootfs-guide-test DEPENDS ${CMAKE_BINARY_DIR}/bootfs-guide-test.img)
endif()
add_custom_command(OUTPUT ${CMAKE_BINARY_DIR}/bootfs-desktop.img
  COMMAND ${VX} mkbootfs ${CMAKE_BINARY_DIR}/bootfs-desktop.img ${_desktop_entries} ${_rio_entries} ${_tracker_entries}
          ${_deskbar_entries} ${_settings_entries} ${_workspaces_entries} ${_notices_entries} ${_guide_entries}
  DEPENDS ${_desktop_depends} ${_rio_depends} ${_tracker_depends} ${_deskbar_depends} ${_settings_depends}
          ${_workspaces_depends} ${_notices_depends} ${_guide_depends}
  COMMENT "Building bootfs for vx boot --desktop")
add_custom_target(bootfs-desktop DEPENDS ${CMAKE_BINARY_DIR}/bootfs-desktop.img)
# The board's desktop: bootfs-board-cpu.img's services and cpu server, and
# vx boot --desktop's: Radharc on the display driver devmgr binds (the
# Sky1's lit engine), with rio, its apps and the workspaces, running for
# good.
add_custom_command(OUTPUT ${CMAKE_BINARY_DIR}/bootfs-board-desktop.img
  COMMAND ${VX} mkbootfs ${CMAKE_BINARY_DIR}/bootfs-board-desktop.img ${_board_entries} ${_cpu_entries}
          lib/cpu/terminal=${CMAKE_BINARY_DIR}/cpu/terminal lib/factotum/keys=${CMAKE_BINARY_DIR}/cpu/keys
          ${_radharc_entries} ${_rio_entries} ${_tracker_entries} ${_deskbar_entries} ${_settings_entries}
          ${_workspaces_entries} ${_notices_entries} ${_guide_entries}
  DEPENDS ${_board_depends} ${_cpu} ${PROJECT_SOURCE_DIR}/services/cpu/cpu.manifest ${PROJECT_SOURCE_DIR}/system/launch/launcher/push
          ${_minimal_hot} ${PROJECT_SOURCE_DIR}/sdk/examples/minimal/hot/minimal-hot.manifest
          ${CMAKE_BINARY_DIR}/cpu/terminal ${CMAKE_BINARY_DIR}/cpu/keys
          ${_radharc_depends} ${_rio_depends} ${_tracker_depends} ${_deskbar_depends} ${_settings_depends}
          ${_workspaces_depends} ${_notices_depends} ${_guide_depends}
  COMMENT "Building bootfs for the board's desktop")
add_custom_target(bootfs-board-desktop DEPENDS ${CMAKE_BINARY_DIR}/bootfs-board-desktop.img)
add_dependencies(bootfs-board-desktop cpu-keys)
