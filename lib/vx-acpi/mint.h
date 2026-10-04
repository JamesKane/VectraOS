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

// VX_ACPI_DEVICE (M5 step 7d): bus-acpi says, with a channel_write and no
// reply, a present device's hardware ID and its _CRS resources, which devmgr
// matches against match=acpi records and grants the matched driver exactly
// (ADR-0024 item 3). Memory and I/O are base and size; an interrupt is its
// line (an ISA IRQ or GSI on x86_64, a GIC INTID on aarch64) in base.
enum : uint32_t { VX_ACPI_DEVICE = 0x6365'7664 }; // "dvec"
enum : uint32_t { VX_ACPI_RES_MEMORY = 1, VX_ACPI_RES_IO = 2, VX_ACPI_RES_IRQ = 3 };
static constexpr uint32_t VX_ACPI_MAX_RES = 8;

typedef struct vx_acpi_res {
  uint32_t kind, reserved;
  uint64_t base, size;
} vx_acpi_res;

typedef struct vx_acpi_device {
  vx_msg_header h;
  char hid[16];   // the hardware ID, NUL-terminated: PNP0B00
  char path[48];  // the namespace path, NUL-terminated (cut short if longer): \_SB.PCI0.SF8.RTC
  uint32_t count; // resources
  uint32_t reserved;
  vx_acpi_res res[VX_ACPI_MAX_RES];
} vx_acpi_device;

// /srv/acpi, bus-acpi's post: a client's request, by channel_call, is a
// vx_msg_header with this ordinal. VX_ACPI_POWER_OFF: the machine off (S5,
// or PSCI through devmgr); the reply, with the status in flags, comes only if
// it did not happen.
enum : uint32_t { VX_ACPI_POWER_OFF = 0x6666'6f70 }; // "poff"
