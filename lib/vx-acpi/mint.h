// vx-acpi mint: what bus-acpi asks devmgr for, on the channel devmgr gives it
// ("devmgr"), when its AML first reaches hardware (ADR-0024 item 4, M5 step
// 7b): a range of memory (a physical VMO, uncached), of I/O ports (an IoRange,
// x86_64), or a PCI function's configuration space (its 4 KiB of ECAM, a
// physical VMO). devmgr refuses what is RAM, the kernel's own, or another
// driver's grant: the reply then has the status in flags and no handle.

#pragma once

#include "../../abi/vx/abi.h"

enum : uint32_t { VX_ACPI_MINT = 0x746e'696d }; // "mint": the channel's one ordinal
enum : uint32_t { VX_ACPI_MEMORY = 1, VX_ACPI_IO = 2, VX_ACPI_PCI = 3 };

typedef struct vx_acpi_mint {
  vx_msg_header h;
  uint32_t kind; // VX_ACPI_MEMORY, _IO or _PCI
  uint32_t reserved;
  uint64_t base; // memory: page-aligned; I/O: the first port; PCI: segment << 16 | requester ID
  uint64_t size; // memory: a whole number of pages; I/O: ports; PCI: 4096
} vx_acpi_mint;
