# SPDX-License-Identifier: BSD-3-Clause
#
# QEMU's edk2 firmware where there is no /usr/share/edk2: Homebrew's QEMU
# (macOS) ships the images flat in <prefix>/share/qemu (edk2-aarch64-code.fd,
# edk2-x86_64-code.fd, edk2-i386-vars.fd, edk2-riscv-*.fd), not in the layout
# tools/qemu.sh reads (ovmf/OVMF_CODE.fd, aarch64/QEMU_EFI-pflash.raw, ...).
# This derives that layout under the build tree, from the share directory of
# the qemu-system-* on PATH, and sets CROI_EDK2_DIR to it. Included only when
# the user gave no -DCROI_EDK2_DIR and /usr/share/edk2 is missing, so Linux
# is unchanged.

set(_qemu_share "")
foreach(_q qemu-system-aarch64 qemu-system-x86_64 qemu-system-riscv64)
  find_program(_qemu_bin ${_q})
  if(_qemu_bin)
    # The unresolved path, not the Cellar's: /opt/homebrew/bin/../share/qemu
    # outlives an upgrade.
    get_filename_component(_bindir "${_qemu_bin}" DIRECTORY)
    if(EXISTS "${_bindir}/../share/qemu/edk2-aarch64-code.fd")
      get_filename_component(_qemu_share "${_bindir}/../share/qemu" ABSOLUTE)
    endif()
  endif()
  unset(_qemu_bin CACHE)
  if(_qemu_share)
    break()
  endif()
endforeach()

if(NOT _qemu_share)
  message(STATUS "edk2: not at /usr/share/edk2, and no QEMU share directory with edk2 images on PATH; pass -DCROI_EDK2_DIR=")
else()
  set(_edk2 "${CMAKE_BINARY_DIR}/edk2")
  file(MAKE_DIRECTORY "${_edk2}/ovmf" "${_edk2}/aarch64" "${_edk2}/riscv")
  # name-in-layout  image-in-share
  set(_links
    ovmf/OVMF_CODE.fd edk2-x86_64-code.fd
    ovmf/OVMF_VARS.fd edk2-i386-vars.fd
    aarch64/QEMU_EFI-pflash.raw edk2-aarch64-code.fd
    riscv/RISCV_VIRT_CODE.fd edk2-riscv-code.fd
    riscv/RISCV_VIRT_VARS.fd edk2-riscv-vars.fd)
  list(LENGTH _links _n)
  math(EXPR _last "${_n} - 1")
  foreach(_i RANGE 0 ${_last} 2)
    math(EXPR _j "${_i} + 1")
    list(GET _links ${_i} _dst)
    list(GET _links ${_j} _src)
    if(EXISTS "${_qemu_share}/${_src}")
      file(CREATE_LINK "${_qemu_share}/${_src}" "${_edk2}/${_dst}" SYMBOLIC)
    endif()
  endforeach()
  # arm64's variable store: 64 MiB of zeros (what Linux's edk2 packages ship
  # as vars-template-pflash.raw), a sparse file.
  if(NOT EXISTS "${_edk2}/aarch64/vars-template-pflash.raw")
    execute_process(COMMAND dd if=/dev/null "of=${_edk2}/aarch64/vars-template-pflash.raw" bs=1048576 seek=64
                    OUTPUT_QUIET ERROR_QUIET)
  endif()
  set(CROI_EDK2_DIR "${_edk2}" CACHE PATH "edk2 firmware images for QEMU")
  message(STATUS "edk2: derived from ${_qemu_share} into ${_edk2}")
endif()
unset(_qemu_share)
