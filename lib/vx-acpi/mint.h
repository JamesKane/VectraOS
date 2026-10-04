// vx-acpi mint: what bus-acpi asks devmgr for, on the channel devmgr gives it
// ("devmgr"), when its AML first reaches hardware (ADR-0024 item 4, M5 step
// 7b): a range of memory (a physical VMO, uncached), of I/O ports (an IoRange,
// x86_64), or a PCI function's configuration space (its 4 KiB of ECAM, a
// physical VMO). devmgr refuses what is RAM, the kernel's own, or another
// driver's grant: the reply then has the status in flags and no handle.

#pragma once

#include "../../abi/vx/abi.h"

enum : uint32_t { VX_ACPI_MINT = 0x746e'696d }; // "mint": the channel's one ordinal
enum : uint32_t { VX_ACPI_MEMORY = 1, VX_ACPI_IO = 2, VX_ACPI_PCI = 3, VX_ACPI_OFF = 4 };

typedef struct vx_acpi_mint {
  vx_msg_header h;
  uint32_t kind; // VX_ACPI_MEMORY, _IO or _PCI
  uint32_t reserved;
  uint64_t base; // memory: page-aligned; I/O: the first port; PCI: segment << 16 | requester ID
  uint64_t size; // memory: a whole number of pages; I/O: ports; PCI: 4096
} vx_acpi_mint;
// VX_ACPI_OFF (base and size 0): the machine off through the kernel's PSCI
// call, for a firmware whose ACPI cannot (hardware-reduced, no sleep
// registers: QEMU's aarch64). The reply comes only if it did not happen.

// /srv/acpi, bus-acpi's post: a client's request, by channel_call, is a
// vx_msg_header with this ordinal. VX_ACPI_POWER_OFF: the machine off (S5,
// or PSCI through devmgr); the reply, with the status in flags, comes only if
// it did not happen.
enum : uint32_t { VX_ACPI_POWER_OFF = 0x6666'6f70 }; // "poff"
