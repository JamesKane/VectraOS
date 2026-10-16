// SPDX-License-Identifier: BSD-3-Clause

// <link.h>'s dl_iterate_phdr (as glibc and the BSDs have it, M6d): calls
// back once for each loaded object, its load bias and program headers;
// unwinders and the Swift runtime find their sections through it. A
// program is static (one object, unbiased), natively the floor's.

#pragma once
#include <elf.h>
#include <stddef.h>

#define ElfW(type) Elf64_##type

#ifdef __cplusplus
extern "C" {
#endif

struct dl_phdr_info {
  Elf64_Addr dlpi_addr;
  const char *dlpi_name;
  const Elf64_Phdr *dlpi_phdr;
  Elf64_Half dlpi_phnum;
  unsigned long long dlpi_adds;
  unsigned long long dlpi_subs;
  size_t dlpi_tls_modid;
  void *dlpi_tls_data;
};

int dl_iterate_phdr(int (*callback)(struct dl_phdr_info *info, size_t size, void *data), void *data);

#ifdef __cplusplus
}
#endif
