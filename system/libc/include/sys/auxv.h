// SPDX-License-Identifier: BSD-3-Clause

// <sys/auxv.h>: the CPU's features as Linux's getauxval and FreeBSD's
// elf_aux_info give them (D128), from the topology page's record.

#pragma once

#define AT_NULL 0
#define AT_PAGESZ 6
#define AT_HWCAP 16
#define AT_HWCAP2 26

#ifdef __cplusplus
extern "C" {
#endif

unsigned long getauxval(unsigned long type);
int elf_aux_info(int type, void *buffer, int length);

#ifdef __cplusplus
}
#endif
