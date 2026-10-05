// vx-rt's ELF: the headers spawn.c loads images by and thread.c finds a
// program's TLS image in (its own, through __ehdr_start).

#pragma once

#include "../../abi/vx/abi.h"

typedef struct vx_elf_header {
  uint8_t ident[16];
  uint16_t type, machine;
  uint32_t version;
  uint64_t entry, phoff, shoff;
  uint32_t flags;
  uint16_t ehsize, phentsize, phnum, shentsize, shnum, shstrndx;
} vx_elf_header;

typedef struct vx_elf_phdr {
  uint32_t type, flags;
  uint64_t offset, vaddr, paddr, filesz, memsz, align;
} vx_elf_phdr;

enum : uint32_t { VX_PT_LOAD = 1, VX_PT_TLS = 7, VX_PF_X = 1, VX_PF_W = 2 };
