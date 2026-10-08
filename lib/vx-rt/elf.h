// vx-rt's ELF: the headers spawn.c loads images by and thread.c finds a
// program's TLS image in (its own, through __ehdr_start); and what the
// dynamic loader reads (ADR-0047, lib/vx-dl).

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

enum : uint32_t {
  VX_PT_LOAD = 1,
  VX_PT_DYNAMIC = 2,
  VX_PT_INTERP = 3,
  VX_PT_TLS = 7,
  VX_PT_GNU_EH_FRAME = 0x6474e550, // .eh_frame_hdr: C++ exceptions' index of unwind tables
  VX_PT_GNU_RELRO = 0x6474e552,
  VX_PF_X = 1,
  VX_PF_W = 2,
};

enum : uint16_t { VX_ET_EXEC = 2, VX_ET_DYN = 3 };

// The dynamic section, symbols and relocations (ADR-0047's loader, lib/vx-dl).
typedef struct vx_elf_dyn {
  int64_t tag;
  uint64_t val;
} vx_elf_dyn;

enum : int64_t {
  VX_DT_NULL = 0,
  VX_DT_NEEDED = 1,
  VX_DT_PLTRELSZ = 2,
  VX_DT_HASH = 4,
  VX_DT_STRTAB = 5,
  VX_DT_SYMTAB = 6,
  VX_DT_RELA = 7,
  VX_DT_RELASZ = 8,
  VX_DT_STRSZ = 10,
  VX_DT_REL = 17,
  VX_DT_PLTREL = 20,
  VX_DT_TEXTREL = 22,
  VX_DT_JMPREL = 23,
  VX_DT_INIT_ARRAY = 25,
  VX_DT_FINI_ARRAY = 26,
  VX_DT_INIT_ARRAYSZ = 27,
  VX_DT_FINI_ARRAYSZ = 28,
  VX_DT_RELRSZ = 35,
  VX_DT_RELR = 36,
  VX_DT_GNU_HASH = 0x6ffffef5,
};

typedef struct vx_elf_sym {
  uint32_t name;
  uint8_t info, other;
  uint16_t shndx;
  uint64_t value, size;
} vx_elf_sym;

enum : uint8_t { VX_STB_LOCAL = 0, VX_STB_GLOBAL = 1, VX_STB_WEAK = 2, VX_STT_TLS = 6 };

typedef struct vx_elf_rela {
  uint64_t offset, info;
  int64_t addend;
} vx_elf_rela;

// The relocations the loader takes, by architecture.
#ifdef __x86_64__
enum : uint32_t {
  VX_R_NONE = 0,
  VX_R_ABS64 = 1,
  VX_R_COPY = 5,
  VX_R_GLOB_DAT = 6,
  VX_R_JUMP_SLOT = 7,
  VX_R_RELATIVE = 8,
  VX_R_DTPMOD64 = 16,
  VX_R_DTPOFF64 = 17,
  VX_R_TPOFF64 = 18,
};
#else
enum : uint32_t {
  VX_R_NONE = 0,
  VX_R_ABS64 = 257,
  VX_R_COPY = 1024,
  VX_R_GLOB_DAT = 1025,
  VX_R_JUMP_SLOT = 1026,
  VX_R_RELATIVE = 1027,
  VX_R_DTPMOD64 = 1028,
  VX_R_DTPOFF64 = 1029,
  VX_R_TPOFF64 = 1030,
};
#endif
