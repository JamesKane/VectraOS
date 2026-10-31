cmake_minimum_required(VERSION 3.29)

if(NOT CMAKE_TOOLCHAIN_FILE)
  message(FATAL_ERROR "Configure with a preset, e.g. `cmake --preset amd64`")
endif()

project(vectraos LANGUAGES C ASM Swift)

set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# vx (Package.swift, SwiftPM) runs the build steps: elf2efi, mkbootfs,
# check-pixels. Every build asks SwiftPM for it, which is a
# no-op when it is current; steps that use it rerun only when it changed.
find_program(CROI_SWIFT swift REQUIRED)
set(VX ${CMAKE_SOURCE_DIR}/.build/debug/vx)
add_custom_target(vx
  COMMAND ${CROI_SWIFT} build --product vx
  # @IPCLibrary's plugin (IPCMacros), for the user programs that expand it
  # (croi_user_sys, croi_user_program IPC): building IPC builds it.
  COMMAND ${CROI_SWIFT} build --target IPC
  WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
  BYPRODUCTS ${VX} ${CMAKE_SOURCE_DIR}/.build/debug/IPCMacros
  COMMENT "Building vx and IPCMacros (SwiftPM)")
set(CROI_IPC_PLUGIN ${CMAKE_SOURCE_DIR}/.build/debug/IPCMacros)

set(CROI_EDK2_DIR /usr/share/edk2 CACHE PATH "edk2 firmware images for QEMU")
set(CROI_CMDLINE "" CACHE STRING "Kernel command line words every ESP's \\croi\\cmdline begins with")
set(CROI_CPU_PEERS "" CACHE STRING "Other nodes' public keys (hex, ;-separated) the board's cpu images answer, beside the terminal's")
if(CROI_CMDLINE STREQUAL "croi.test=1")  # the default before croi.test= named tests (D125)
  set(CROI_CMDLINE "" CACHE STRING "Kernel command line words every ESP's \\croi\\cmdline begins with" FORCE)
endif()
set(CROI_TESTS "all" CACHE STRING
    "What the self-test ESPs test (croi.test=, D125: all, groups, suites); empty boots them as production does")
if(CROI_TESTS)
  set(_tests " croi.test=${CROI_TESTS}")
endif()
set(CROI_USERBOOT_NEXT "bin/m2" CACHE STRING "The bootfs program userboot starts (userboot.next=)")
set(CROI_USERBOOT_SHUTDOWN "poweroff" CACHE STRING
    "What userboot does once that program exits (userboot.shutdown=: poweroff, reboot, or empty to idle)")
if(CROI_USERBOOT_SHUTDOWN)
  set(_shutdown " userboot.shutdown=${CROI_USERBOOT_SHUTDOWN}")
endif()
set(CROI_QEMU ${CMAKE_SOURCE_DIR}/tools/qemu.sh)

# Common ld.lld flags: static PIE, nothing implicit, unused sections dropped.
set(CROI_LINK_FLAGS
  -static -pie --no-dynamic-linker -ztext -znoexecstack
  -zmax-page-size=4096 -zseparate-loadable-segments
  --gc-sections --orphan-handling=error --build-id=sha1)

include(cmake/CroiImage.cmake)

add_subdirectory(lib/rt)
add_subdirectory(lib/handoff)
add_subdirectory(lib/fmt)
add_subdirectory(lib/pagetables)
add_subdirectory(lib/acpi)
add_subdirectory(lib/elf)
add_subdirectory(kernel)
add_subdirectory(boot)

# EFI system partition layout, served to QEMU as a virtual FAT drive.
set(CROI_ESP_DIR ${CMAKE_BINARY_DIR}/esp)
file(CONFIGURE OUTPUT ${CMAKE_BINARY_DIR}/cmdline
     CONTENT "${CROI_CMDLINE}${_tests} userboot.next=${CROI_USERBOOT_NEXT}${_shutdown}\n")
add_custom_target(esp ALL
  COMMAND ${CMAKE_COMMAND} -E make_directory ${CROI_ESP_DIR}/EFI/BOOT ${CROI_ESP_DIR}/croi
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
          $<TARGET_PROPERTY:loader-efi,CROI_EFI_FILE> ${CROI_ESP_DIR}/EFI/BOOT/${CROI_EFI_BOOT_NAME}
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
          $<TARGET_FILE:kernel> ${CROI_ESP_DIR}/croi/kernel.elf
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
          ${CMAKE_BINARY_DIR}/cmdline ${CMAKE_BINARY_DIR}/bootfs.img ${CROI_ESP_DIR}/croi/
  DEPENDS loader-efi kernel bootfs
  COMMENT "Assembling EFI system partition")

add_custom_target(run
  COMMAND ${CROI_QEMU} ${CROI_ARCH} ${CROI_ESP_DIR} ${CMAKE_BINARY_DIR}/qemu ${CROI_EDK2_DIR}
  DEPENDS esp USES_TERMINAL)

# An ESP of its own, esp-<name>: the kernel's, with `cmdline` after
# CROI_CMDLINE and, given BOOTFS, kernel/CMakeLists.txt's <bootfs>.img;
# ALL builds it by default.
function(croi_esp name cmdline)
  cmake_parse_arguments(_e "ALL" "BOOTFS" "" ${ARGN})
  set(_esp ${CMAKE_BINARY_DIR}/esp-${name})
  file(CONFIGURE OUTPUT ${CMAKE_BINARY_DIR}/cmdline-${name} CONTENT "${CROI_CMDLINE} ${cmdline}\n")
  set(_all)
  set(_copy)
  if(_e_ALL)
    set(_all ALL)
  endif()
  if(_e_BOOTFS)
    set(_copy COMMAND ${CMAKE_COMMAND} -E copy ${CMAKE_BINARY_DIR}/${_e_BOOTFS}.img ${_esp}/croi/bootfs.img)
  endif()
  add_custom_target(esp-${name} ${_all}
    COMMAND ${CMAKE_COMMAND} -E copy_directory ${CROI_ESP_DIR} ${_esp}
    COMMAND ${CMAKE_COMMAND} -E copy ${CMAKE_BINARY_DIR}/cmdline-${name} ${_esp}/croi/cmdline
    ${_copy})
  add_dependencies(esp-${name} esp ${_e_BOOTFS})
endfunction()
# The cpu images' ESPs (D77): the launcher and every service, a cpu
# server among them (kernel/CMakeLists.txt's bootfs-cpu*.img). run-cpu is
# vx boot --cpu's, the node's port 17019 on localhost's; boot-cpu, below,
# boots the tests' one.
croi_esp(cpu "userboot.next=bin/launcher croi.debug_syscalls=on" BOOTFS bootfs-cpu)
# The desktop's ESPs (D107): kernel/CMakeLists.txt's bootfs-desktop*.img,
# the launcher run with Radharc. run-desktop is vx boot --desktop's;
# boot-desktop, below, runs desktop-test to its end.
croi_esp(desktop "userboot.next=bin/launcher croi.debug_syscalls=on" BOOTFS bootfs-desktop)
add_custom_target(run-desktop
  COMMAND ${CROI_QEMU} ${CROI_ARCH} ${CMAKE_BINARY_DIR}/esp-desktop ${CMAKE_BINARY_DIR}/qemu ${CROI_EDK2_DIR}
  DEPENDS esp-desktop USES_TERMINAL)
add_custom_target(run-cpu
  COMMAND ${CROI_QEMU} --forward 17019:17019 ${CROI_ARCH} ${CMAKE_BINARY_DIR}/esp-cpu ${CMAKE_BINARY_DIR}/qemu ${CROI_EDK2_DIR}
  DEPENDS esp-cpu USES_TERMINAL)

enable_testing()
# Boot tests wait for userboot to report that the program it started from
# bootfs exited cleanly (userboot starts after the kernel's self-tests and
# "boot complete"); with userboot.shutdown= (K10e) QEMU must then exit by
# itself (--exits), except where the run is inspected at that point.
set(CROI_BOOT_DONE "userboot: ${CROI_USERBOOT_NEXT} exited with 0")
if(CROI_USERBOOT_SHUTDOWN)
  set(CROI_EXITS --exits)
endif()
# Boots through the loader into the kernel, which reports and idles; then
# checks the pattern the kernel drew on the framebuffer.
set(_fb_dump ${CMAKE_BINARY_DIR}/qemu/framebuffer.ppm)
add_test(NAME boot-smoke
  COMMAND ${CROI_QEMU} --test "${CROI_BOOT_DONE}" --screendump ${_fb_dump}
          ${CROI_ARCH} ${CROI_ESP_DIR} ${CMAKE_BINARY_DIR}/qemu ${CROI_EDK2_DIR})
set_tests_properties(boot-smoke PROPERTIES TIMEOUT 120 FIXTURES_SETUP framebuffer)
add_test(NAME framebuffer-pixels
  COMMAND ${VX} check-pixels ${_fb_dump}
          0,0,16,48,96 40,30,240,192,32 100,100,16,48,96)
set_tests_properties(framebuffer-pixels PROPERTIES FIXTURES_REQUIRED framebuffer)

if(CROI_ARCH STREQUAL amd64)
  # No TSC-deadline mode: timers fall back to local APIC one-shot mode.
  add_test(NAME boot-smoke-apic-oneshot
    COMMAND ${CROI_QEMU} --test "${CROI_BOOT_DONE}" ${CROI_EXITS}
            ${CROI_ARCH} ${CROI_ESP_DIR} ${CMAKE_BINARY_DIR}/qemu-apic-oneshot ${CROI_EDK2_DIR}
            -cpu max,-tsc-deadline)
  set_tests_properties(boot-smoke-apic-oneshot PROPERTIES TIMEOUT 120)

  # AMD-Vi instead of VT-d (QEMU takes one IOMMU at a time): the IOMMU
  # self-test's line, which a skipped test wouldn't print (K12b).
  add_test(NAME boot-amd-iommu
    COMMAND ${CROI_QEMU} --iommu amd --test "iommu:  AMD-Vi:"
            ${CROI_ARCH} ${CROI_ESP_DIR} ${CMAKE_BINARY_DIR}/qemu-amd-iommu ${CROI_EDK2_DIR})
  set_tests_properties(boot-amd-iommu PROPERTIES TIMEOUT 120)
  # AMD-Vi with XT (K12g): 128-bit interrupt remapping entries, x2APIC
  # destinations (boot-amd-iommu has the 32-bit ones).
  add_test(NAME boot-amd-iommu-xt
    COMMAND ${CROI_QEMU} --iommu amd-xt --test "iommu:  AMD-Vi:"
            ${CROI_ARCH} ${CROI_ESP_DIR} ${CMAKE_BINARY_DIR}/qemu-amd-iommu-xt ${CROI_EDK2_DIR})
  set_tests_properties(boot-amd-iommu-xt PROPERTIES TIMEOUT 120)
endif()

# The baseline (D51-D53): a CPU at it boots, with every program compiled
# to assume it, and the loader refuses one below it, naming what's missing
# (boot/Loader/Baseline.swift).
set(_baseline_cpu_amd64 IvyBridge)
set(_baseline_cpu_arm64 cortex-a76)
set(_baseline_cpu_rv64 rva22s64)
set(_below_cpu_amd64 Westmere)
set(_below_cpu_arm64 cortex-a72)
set(_below_cpu_rv64 rv64,zba=false)
add_test(NAME boot-baseline
  COMMAND ${CROI_QEMU} --test "${CROI_BOOT_DONE}" ${CROI_EXITS}
          ${CROI_ARCH} ${CROI_ESP_DIR} ${CMAKE_BINARY_DIR}/qemu-baseline ${CROI_EDK2_DIR}
          -cpu ${_baseline_cpu_${CROI_ARCH}})
set_tests_properties(boot-baseline PROPERTIES TIMEOUT 120)
add_test(NAME boot-below-baseline
  COMMAND ${CROI_QEMU} --test "baseline: no "
          ${CROI_ARCH} ${CROI_ESP_DIR} ${CMAKE_BINARY_DIR}/qemu-below-baseline ${CROI_EDK2_DIR}
          -cpu ${_below_cpu_${CROI_ARCH}})
set_tests_properties(boot-below-baseline PROPERTIES TIMEOUT 120)

if(CROI_ARCH STREQUAL amd64 AND EXISTS /dev/kvm)
  # Under KVM timing is real: the trace self-test enforces its probe-cost
  # budget, as Todhchai's M2 budgets will be measured.
  add_test(NAME boot-smoke-kvm
    COMMAND ${CROI_QEMU} --test "${CROI_BOOT_DONE}" ${CROI_EXITS}
            ${CROI_ARCH} ${CROI_ESP_DIR} ${CMAKE_BINARY_DIR}/qemu-kvm ${CROI_EDK2_DIR}
            -accel kvm -cpu host)
  set_tests_properties(boot-smoke-kvm PROPERTIES TIMEOUT 120)
endif()

# Self-tests off, as Todhchai boots (K9f): user space must still come up.
set(_esp_lean ${CMAKE_BINARY_DIR}/esp-lean)
croi_esp(lean "userboot.next=${CROI_USERBOOT_NEXT}${_shutdown} croi.debug_syscalls=on" ALL)
add_test(NAME boot-lean
  COMMAND ${CROI_QEMU} --test "${CROI_BOOT_DONE}" ${CROI_EXITS}
          ${CROI_ARCH} ${_esp_lean} ${CMAKE_BINARY_DIR}/qemu-lean ${CROI_EDK2_DIR})
set_tests_properties(boot-lean PROPERTIES TIMEOUT 120)

# A bootfs program's own boot (V2): userboot starts bin/<name> instead of
# m2, self-tests off, and the test passes when it exits with 0. Words after
# the name go on the command line (userboot passes them to the program as
# its environment).
function(croi_boot_program_test test name)
  list(JOIN ARGN " " _extra)
  if(_extra)
    set(_extra " ${_extra}")
  endif()
  croi_esp(${test} "userboot.next=bin/${name}${_shutdown} croi.debug_syscalls=on${_extra}" ALL)
  add_test(NAME boot-${test}
    COMMAND ${CROI_QEMU} --test "userboot: bin/${name} exited with 0" ${CROI_EXITS}
            ${CROI_ARCH} ${CMAKE_BINARY_DIR}/esp-${test} ${CMAKE_BINARY_DIR}/qemu-${test} ${CROI_EDK2_DIR})
  set_tests_properties(boot-${test} PROPERTIES TIMEOUT 120)
endfunction()
# Sys over the kernel (bin/sys-test), dlopen (bin/dl-test), IPC
# (bin/ipc-test), Node (bin/node-test) and a trace session
# (bin/trace-test), whose export vx trace collect then reads from the
# boot's console (qemu.sh keeps it).
croi_boot_program_test(sys sys-test)
croi_boot_program_test(dl dl-test)
croi_boot_program_test(ipc ipc-test)
croi_boot_program_test(node node-test)
croi_boot_program_test(acpi acpi-test)
croi_boot_program_test(pci pci-test)
# A spare PL011's interrupt from user mode (bin/irq-test, D125): arm64,
# whose test boots have virt's second PL011 (qemu.sh).
if(CROI_ARCH STREQUAL arm64)
  croi_boot_program_test(irq irq-test)
endif()
# Warm boot (D101): bin/warmboot-test warm-boots into this build's kernel
# (bootfs-warmboot.img holds it) with the same bootfs, and its second boot
# exits 0. amd64 and arm64.
if(CROI_ARCH STREQUAL amd64 OR CROI_ARCH STREQUAL arm64)
  croi_esp(warmboot "userboot.next=bin/warmboot-test${_shutdown} croi.debug_syscalls=on" BOOTFS bootfs-warmboot ALL)
  add_test(NAME boot-warmboot
    COMMAND ${CROI_QEMU} --test "userboot: bin/warmboot-test exited with 0" ${CROI_EXITS}
            ${CROI_ARCH} ${CMAKE_BINARY_DIR}/esp-warmboot ${CMAKE_BINARY_DIR}/qemu-warmboot ${CROI_EDK2_DIR})
  set_tests_properties(boot-warmboot PROPERTIES TIMEOUT 120)
endif()
# The launcher (V2's item 4): bootfs's manifests, run until bin/launch-test
# ends; it exits with its code.
croi_boot_program_test(launch launcher launcher.until=launch-test)
# The board images (kernel/CMakeLists.txt's bootfs-board*.img): bootfs-board run until
# bin/board-test ends: esp-board is the Orange Pi 6 Plus's, rebooting into
# its own OS when done; boot-board runs it in QEMU, which keeps it working.
if(CROI_ARCH STREQUAL arm64)
  croi_esp(board "userboot.next=bin/launcher userboot.shutdown=reboot croi.halt_on_panic=false launcher.until=board-test"
    BOOTFS bootfs-board)
  croi_esp(board-test "userboot.next=bin/launcher${_shutdown} launcher.until=board-test" BOOTFS bootfs-board ALL)
  # The board's V3 link: its cpu server for this terminal, running for good.
  croi_esp(board-cpu "userboot.next=bin/launcher croi.debug_syscalls=on croi.halt_on_panic=false"
    BOOTFS bootfs-board-cpu)
  # The board's desktop: Radharc on its display, and the cpu server.
  croi_esp(board-desktop "userboot.next=bin/launcher croi.debug_syscalls=on croi.halt_on_panic=false"
    BOOTFS bootfs-board-desktop)
  add_test(NAME boot-board
    COMMAND ${CROI_QEMU} --test "userboot: bin/launcher exited with 0" ${CROI_EXITS}
            --nvme ${CMAKE_BINARY_DIR}/qemu-board/nvme.img --usb
            ${CROI_ARCH} ${CMAKE_BINARY_DIR}/esp-board-test ${CMAKE_BINARY_DIR}/qemu-board ${CROI_EDK2_DIR})
  set_tests_properties(boot-board PROPERTIES TIMEOUT 180)
endif()
# cpu (D77): the tests' terminal (services/cpu/tests/boot-cpu.sh) calls the
# node's cpu server with vx cpu, through a port of its own for each arch,
# and runs rc there, which tier 1 builds.
get_property(_tier1_built GLOBAL PROPERTY CROI_TIER1_PROGRAMS)
if(_tier1_built)
  croi_esp(cpu-test "userboot.next=bin/launcher croi.debug_syscalls=on" BOOTFS bootfs-cpu-test ALL)
  set(_cpu_port_amd64 27019)
  set(_cpu_port_arm64 27020)
  set(_cpu_port_rv64 27021)
  add_test(NAME boot-cpu
    COMMAND ${CROI_QEMU} --test "cpu: listening on" --forward ${_cpu_port_${CROI_ARCH}}:17019 --timeout 240
            --then "${CMAKE_SOURCE_DIR}/services/cpu/tests/boot-cpu.sh ${VX} ${_cpu_port_${CROI_ARCH}} ${CMAKE_BINARY_DIR}/qemu-cpu ${CMAKE_BINARY_DIR}/kernel/plumber.elf ${CROI_ARCH} $<TARGET_FILE:kernel> ${CMAKE_BINARY_DIR}/bootfs-cpu-test.img"
            ${CROI_ARCH} ${CMAKE_BINARY_DIR}/esp-cpu-test ${CMAKE_BINARY_DIR}/qemu-cpu ${CROI_EDK2_DIR})
  set_tests_properties(boot-cpu PROPERTIES TIMEOUT 300)
  # A cold boot keeps /data (D105): the cpu image twice on one virtio disk.
  set(_persist_port_amd64 27022)
  set(_persist_port_arm64 27023)
  set(_persist_port_rv64 27024)
  add_test(NAME boot-persist
    COMMAND ${CMAKE_SOURCE_DIR}/services/cpu/tests/boot-persist.sh ${VX} ${CROI_QEMU} ${_persist_port_${CROI_ARCH}}
            ${CROI_ARCH} ${CMAKE_BINARY_DIR}/esp-cpu-test ${CMAKE_BINARY_DIR}/qemu-persist ${CROI_EDK2_DIR})
  set_tests_properties(boot-persist PROPERTIES TIMEOUT 300)
  # An encrypted volume unlocked at the console's prompt (D153): the cpu
  # image on a disk vx disk --encrypt makes, its keys typed through the
  # monitor.
  set(_unlock_port_amd64 27028)
  set(_unlock_port_arm64 27029)
  set(_unlock_port_rv64 27030)
  add_test(NAME boot-unlock
    COMMAND ${CMAKE_SOURCE_DIR}/services/cpu/tests/boot-unlock.sh ${VX} ${CROI_QEMU} ${_unlock_port_${CROI_ARCH}}
            ${CROI_ARCH} ${CMAKE_BINARY_DIR}/esp-cpu-test ${CMAKE_BINARY_DIR}/qemu-unlock ${CROI_EDK2_DIR})
  set_tests_properties(boot-unlock PROPERTIES TIMEOUT 300)
  # And by a swarm member, nothing typed (D153): two cpu images, the
  # member's unlock port relayed to the node; three ports each, from these.
  set(_swarm_unlock_port_amd64 27031)
  set(_swarm_unlock_port_arm64 27034)
  set(_swarm_unlock_port_rv64 27037)
  add_test(NAME boot-swarm-unlock
    COMMAND ${CMAKE_SOURCE_DIR}/services/cpu/tests/boot-swarm-unlock.sh ${VX} ${CROI_QEMU}
            ${_swarm_unlock_port_${CROI_ARCH}} ${CROI_ARCH} ${CMAKE_BINARY_DIR}/esp-cpu-test
            ${CMAKE_BINARY_DIR}/qemu-swarm-unlock ${CROI_EDK2_DIR})
  set_tests_properties(boot-swarm-unlock PROPERTIES TIMEOUT 300)
  # Hot reload (hotreload(2), D122): the tests' terminal reloads minimal's
  # frame in minimal-hot through vx reload (sdk/tests/hot/boot-reload.sh).
  set(_reload_port_amd64 27025)
  set(_reload_port_arm64 27026)
  set(_reload_port_rv64 27027)
  add_test(NAME boot-reload
    COMMAND ${CROI_QEMU} --test "cpu: listening on" --forward ${_reload_port_${CROI_ARCH}}:17019 --timeout 240
            --then "${CMAKE_SOURCE_DIR}/sdk/tests/hot/boot-reload.sh ${VX} ${_reload_port_${CROI_ARCH}} ${CMAKE_BINARY_DIR}/qemu-reload ${CMAKE_BINARY_DIR}"
            ${CROI_ARCH} ${CMAKE_BINARY_DIR}/esp-cpu-test ${CMAKE_BINARY_DIR}/qemu-reload ${CROI_EDK2_DIR})
  set_tests_properties(boot-reload PROPERTIES TIMEOUT 300)
endif()
# A launcher boot (bootfs-<name>-test.img) run until bin/<UNTIL> ends
# (<name>-test unless said): boot-<name> passes when the launcher exits
# with 0. OPTIONS go to qemu.sh, QEMU to QEMU.
function(croi_launcher_test name)
  cmake_parse_arguments(_t "" "UNTIL;TIMEOUT" "OPTIONS;QEMU" ${ARGN})
  if(NOT _t_UNTIL)
    set(_t_UNTIL ${name}-test)
  endif()
  if(NOT _t_TIMEOUT)
    set(_t_TIMEOUT 240)
  endif()
  croi_esp(${name}-test "userboot.next=bin/launcher${_shutdown} croi.debug_syscalls=on launcher.until=${_t_UNTIL}"
    BOOTFS bootfs-${name}-test ALL)
  add_test(NAME boot-${name}
    COMMAND ${CROI_QEMU} --test "userboot: bin/launcher exited with 0" ${CROI_EXITS} ${_t_OPTIONS}
            ${CROI_ARCH} ${CMAKE_BINARY_DIR}/esp-${name}-test ${CMAKE_BINARY_DIR}/qemu-${name} ${CROI_EDK2_DIR}
            ${_t_QEMU})
  set_tests_properties(boot-${name} PROPERTIES TIMEOUT ${_t_TIMEOUT})
endfunction()
# The desktop (D107): Radharc on the boot framebuffer, run until
# bin/desktop-test ends; the screendump then shows its window's layers
# where it placed them (its content at 100, 100: a solid 0x336699, and an
# image at 10, 10 of it, its first row red and the rest green), on
# Platinum Indigo's desk (0x3f5868, at 20, 20).
croi_esp(desktop-test "userboot.next=bin/launcher${_shutdown} croi.debug_syscalls=on launcher.until=desktop-test"
  BOOTFS bootfs-desktop-test ALL)
set(_desktop_dump ${CMAKE_BINARY_DIR}/qemu-desktop/desktop.ppm)
add_test(NAME boot-desktop
  COMMAND ${CROI_QEMU} --test "userboot: bin/launcher exited with 0" --screendump ${_desktop_dump}
          ${CROI_ARCH} ${CMAKE_BINARY_DIR}/esp-desktop-test ${CMAKE_BINARY_DIR}/qemu-desktop ${CROI_EDK2_DIR})
set_tests_properties(boot-desktop PROPERTIES TIMEOUT 180 FIXTURES_SETUP desktop)
add_test(NAME desktop-pixels
  COMMAND ${VX} check-pixels ${_desktop_dump} 150,180,51,102,153 110,110,255,0,0 120,125,0,255,0
          20,20,63,88,104)
set_tests_properties(desktop-pixels PROPERTIES FIXTURES_REQUIRED desktop)
# The SDK (sdk(2)): bin/sdk-test's loop, window and routing on Radharc,
# with the reference app, minimal, beside it.
croi_launcher_test(sdk TIMEOUT 180)
# Workspaces (D116): bin/workspaces-test's twenty windows tiled by
# master-stack and put back by chords' Super-Shift-T (desktop.mode_switch),
# chords' grant answered on the prompt and revoked, master-stack killed
# and back, and an app's frame kept for its next window.
croi_launcher_test(workspaces TIMEOUT 180)
# The display class (D120): bin/display-test with a virtio GPU of two
# outputs, one enabled at 1024x768: Radharc composes onto it, not the boot
# framebuffer, and the GPU's screendump has the window's colour (at
# 150, 150) on Platinum Indigo's desk (at 20, 20).
croi_esp(display-test "userboot.next=bin/launcher${_shutdown} croi.debug_syscalls=on launcher.until=display-test"
  BOOTFS bootfs-display-test ALL)
set(_display_dump ${CMAKE_BINARY_DIR}/qemu-display/display.ppm)
add_test(NAME boot-display
  COMMAND ${CROI_QEMU} --test "userboot: bin/launcher exited with 0" --screendump ${_display_dump}
          --screendump-device gpu0
          ${CROI_ARCH} ${CMAKE_BINARY_DIR}/esp-display-test ${CMAKE_BINARY_DIR}/qemu-display ${CROI_EDK2_DIR}
          -device virtio-gpu-pci,id=gpu0,iommu_platform=on,disable-legacy=on,max_outputs=2,edid=on,xres=1024,yres=768)
set_tests_properties(boot-display PROPERTIES TIMEOUT 180 FIXTURES_SETUP display)
add_test(NAME display-pixels
  COMMAND ${VX} check-pixels ${_display_dump} 150,150,204,51,102 20,20,63,88,104)
set_tests_properties(display-pixels PROPERTIES FIXTURES_REQUIRED display)
# The GPU stack (D121): bin/loinnir-test draws through our loader, Venus and
# the GPU class on virtio-gpu, rendered by QEMU on the host's GPU (egl-headless).
croi_launcher_test(venus UNTIL compose-test
  QEMU -device virtio-gpu-gl-pci,id=gpu0,iommu_platform=on,disable-legacy=on,blob=on,venus=on,hostmem=1G
       -display egl-headless -object memory-backend-memfd,id=mem,size=512M,share=on -machine memory-backend=mem)
# The lock screen (D118): bin/lock-test locks, types a wrong and the right
# password, uses Control-Alt-Delete, waits a minute for the lock, and
# kills Radharc while locked.
croi_launcher_test(lock OPTIONS --timeout 200)
# Kit (kit(2)), with tier 1: bin/kit-test's Kit window on Radharc.
get_property(_kit_test GLOBAL PROPERTY CROI_TIER1_KIT_TEST)
if(_kit_test)
  croi_launcher_test(kit)
endif()
# rio (rio(1)), with tier 1: bin/rio-test types into rc's window.
get_property(_rio_test GLOBAL PROPERTY CROI_TIER1_RIO_TEST)
if(_rio_test)
  croi_launcher_test(rio)
  # V5's exit budgets with real timing (D123): the same image under KVM,
  # where rio-test's terminal.key_draw and desktop.cold_start mean what
  # they say (under TCG they measure the emulator).
  if(CROI_ARCH STREQUAL amd64 AND EXISTS /dev/kvm)
    add_test(NAME boot-rio-kvm
      COMMAND ${CROI_QEMU} --test "userboot: bin/launcher exited with 0" ${CROI_EXITS}
              ${CROI_ARCH} ${CMAKE_BINARY_DIR}/esp-rio-test ${CMAKE_BINARY_DIR}/qemu-rio-kvm ${CROI_EDK2_DIR}
              -accel kvm -cpu host)
    set_tests_properties(boot-rio-kvm PROPERTIES TIMEOUT 240)
  endif()
  # vt (vt(1)): bin/vt-test runs vt in rio's window, with itself as the
  # program that wants xterm.
  croi_launcher_test(vt)
  # Tracker (tracker(4)): bin/tracker-test checks the desktop, the file
  # chooser in Radharc's prompt, its plumber ports, and the warm 100k
  # listing budget.
  croi_launcher_test(tracker)
  # Deskbar (deskbar(4), D114): bin/deskbar-test checks its panel and
  # clock, the launcher's apps, and that an idle desktop wakes it not at
  # all.
  croi_launcher_test(deskbar)
  # The Settings app (preferences(4), inspector(4), D115): bin/settings-test
  # presses Keyboard's preferences and Grants' Revoke by keys, and checks
  # that the Inspector reads /proc only while someone is at the desktop.
  croi_launcher_test(settings)
  # guide (guide(1)): bin/guide-test plumbs rc(1) to guide and moves it with
  # Browse, Retrace, the Index and a link.
  croi_launcher_test(guide)
  # Notices (notices(4), D117): bin/notices-test posts, refuses and clicks
  # away slips, keeps, puts back and forgets clips, opens the drawer, and
  # kills notices to see it come back within Settings' limit.
  croi_launcher_test(notices)
endif()
croi_boot_program_test(trace trace-test)
add_test(NAME trace-collect
  COMMAND ${VX} trace collect ${CMAKE_BINARY_DIR}/qemu-trace/console.log ${CMAKE_BINARY_DIR}/trace)
set_tests_properties(boot-trace PROPERTIES FIXTURES_SETUP trace-console)
set_tests_properties(trace-collect PROPERTIES FIXTURES_REQUIRED trace-console)
# Tier 1 (D47): each test program of the *-vectraos toolchain, booted
# (cmake/Tier1.cmake builds them when the toolchain and its builtins are there).
get_property(_tier1_programs GLOBAL PROPERTY CROI_TIER1_PROGRAMS)
foreach(_t1 ${_tier1_programs})
  croi_boot_program_test(${_t1} ${_t1})
endforeach()

if(CROI_ARCH STREQUAL arm64 OR CROI_ARCH STREQUAL rv64)
  # Guest time from instruction counts (QEMU -icount; sleep=off skips idle
  # time), so a loaded host can't stretch it: m2's timed paths run in a
  # time that doesn't depend on the machine. The RTCs follow guest time.
  # Not amd64 (QEMU 10.2 aborts: "Bad icount read" during interrupt
  # controller and clock setup), and not the full boots: icount runs the
  # CPUs in turn, a steady steal the deadline self-tests can't absorb.
  add_test(NAME boot-lean-icount
    COMMAND ${CROI_QEMU} --test "${CROI_BOOT_DONE}" ${CROI_EXITS}
            ${CROI_ARCH} ${_esp_lean} ${CMAKE_BINARY_DIR}/qemu-lean-icount ${CROI_EDK2_DIR}
            -icount shift=auto,sleep=off -rtc clock=vm)
  set_tests_properties(boot-lean-icount PROPERTIES TIMEOUT 120)
endif()

# Reboot (K10e): the machine resets; -no-reboot makes QEMU exit on it.
croi_esp(reboot "userboot.next=${CROI_USERBOOT_NEXT} userboot.shutdown=reboot croi.debug_syscalls=on" ALL)
add_test(NAME boot-reboot
  COMMAND ${CROI_QEMU} --test "croi kernel: rebooting" --exits
          ${CROI_ARCH} ${CMAKE_BINARY_DIR}/esp-reboot ${CMAKE_BINARY_DIR}/qemu-reboot ${CROI_EDK2_DIR})
set_tests_properties(boot-reboot PROPERTIES TIMEOUT 120)

# Out of memory (K14a): watermarks above all of RAM, so the watchdog finds
# the boot out of memory at once, evicts what it can, signals OOM and
# reboots (Zircon's default) after the timeout; -no-reboot exits QEMU.
croi_esp(oom "userboot.next=${CROI_USERBOOT_NEXT} croi.debug_syscalls=on croi.oom.outofmemory_mb=4000 croi.oom.critical_mb=4100 croi.oom.warning_mb=4200 croi.oom.reboot_timeout_ms=200" ALL)
add_test(NAME boot-oom
  COMMAND ${CROI_QEMU} --test "out of memory; rebooting in 200 ms" --exits
          ${CROI_ARCH} ${CMAKE_BINARY_DIR}/esp-oom ${CMAKE_BINARY_DIR}/qemu-oom ${CROI_EDK2_DIR})
set_tests_properties(boot-oom PROPERTIES TIMEOUT 120)

if(CROI_ARCH STREQUAL amd64)
  # Interrupt remapping off (K12f): TCG boots remap every interrupt, so
  # this keeps the compatibility-format MSI and IOAPIC paths covered.
  set(_esp_intremap ${CMAKE_BINARY_DIR}/esp-intremap-off)
  file(CONFIGURE OUTPUT ${CMAKE_BINARY_DIR}/cmdline-intremap-off
       CONTENT "${CROI_CMDLINE}${_tests} userboot.next=${CROI_USERBOOT_NEXT}${_shutdown} croi.intremap=off\n")
  add_custom_target(esp-intremap-off ALL
    COMMAND ${CMAKE_COMMAND} -E copy_directory ${CROI_ESP_DIR} ${_esp_intremap}
    COMMAND ${CMAKE_COMMAND} -E copy ${CMAKE_BINARY_DIR}/cmdline-intremap-off ${_esp_intremap}/croi/cmdline
    DEPENDS esp)
  add_test(NAME boot-intremap-off
    COMMAND ${CROI_QEMU} --test "${CROI_BOOT_DONE}" ${CROI_EXITS}
            ${CROI_ARCH} ${_esp_intremap} ${CMAKE_BINARY_DIR}/qemu-intremap-off ${CROI_EDK2_DIR})
  set_tests_properties(boot-intremap-off PROPERTIES TIMEOUT 180)
endif()

if(CROI_ARCH STREQUAL rv64)
  # The RISC-V IOMMU without MSI_FLAT: base device contexts in a 2-level
  # directory (the default boot has extended ones in 3 levels; K12e), and
  # with AIA, a claimed device's MSIs through identity-mapped interrupt
  # files alone (no MSI page table; K12j).
  add_test(NAME boot-riscv-iommu-base
    COMMAND ${CROI_QEMU} --iommu base --aia --test "iommu:  RISC-V IOMMU:"
            ${CROI_ARCH} ${CROI_ESP_DIR} ${CMAKE_BINARY_DIR}/qemu-riscv-iommu ${CROI_EDK2_DIR})
  set_tests_properties(boot-riscv-iommu-base PROPERTIES TIMEOUT 180)
  # AIA (K12i): the APLIC and IMSICs instead of the PLIC; the whole boot
  # test, wired interrupts through the APLIC and MSIs through the IMSICs.
  add_test(NAME boot-aia
    COMMAND ${CROI_QEMU} --aia --test "${CROI_BOOT_DONE}" ${CROI_EXITS}
            ${CROI_ARCH} ${CROI_ESP_DIR} ${CMAKE_BINARY_DIR}/qemu-aia ${CROI_EDK2_DIR})
  set_tests_properties(boot-aia PROPERTIES TIMEOUT 240)
endif()

if(CROI_ARCH STREQUAL arm64)
  # The DBG2 console path (QEMU's SPCR can't be turned off): an ESP whose
  # command line makes the loader try DBG2 first.
  set(_esp_dbg2 ${CMAKE_BINARY_DIR}/esp-dbg2)
  add_custom_target(esp-dbg2 ALL
    COMMAND ${CMAKE_COMMAND} -E copy_directory ${CROI_ESP_DIR} ${_esp_dbg2}
    COMMAND ${CMAKE_COMMAND} -E echo "loader.console=dbg2" > ${_esp_dbg2}/croi/cmdline
    DEPENDS esp)
  add_test(NAME boot-dbg2-console
    COMMAND ${CROI_QEMU} --test "at 0x9000000 (DBG2)"
            ${CROI_ARCH} ${_esp_dbg2} ${CMAKE_BINARY_DIR}/qemu-dbg2 ${CROI_EDK2_DIR})
  set_tests_properties(boot-dbg2-console PROPERTIES TIMEOUT 120)

  # Firmware at EL2 with a GICv3: the loader must drop to EL1.
  add_test(NAME boot-smoke-el2
    COMMAND ${CROI_QEMU} --test "${CROI_BOOT_DONE}" ${CROI_EXITS}
            ${CROI_ARCH} ${CROI_ESP_DIR} ${CMAKE_BINARY_DIR}/qemu-el2 ${CROI_EDK2_DIR}
            -machine virtualization=on,gic-version=3)
  set_tests_properties(boot-smoke-el2 PROPERTIES TIMEOUT 120)
endif()
