// vx/dl.h: the dynamic loader's handover to a program's vx-rt (ADR-0047).
//
// /lib/ld-vx loads a dynamic program's executable and libraries, binds them,
// and jumps to the executable's entry with a vx_dl_handover in the second
// argument register (rsi, x1) and no bootstrap handle in the first. A static
// program's second argument is 0. Everything the handover points at stays
// mapped for the life of the process.

#pragma once

#include <stdint.h>

#include "abi.h"

enum : uint32_t {
  VX_DL_MAGIC = 0x786c6476, // "vdlx"
  VX_DL_VERSION = 1,
};

// One loaded object: the executable (first), or a shared library.
typedef struct vx_dl_object {
  const char *name;  // "" for the executable; else its DT_NEEDED name
  uint64_t base;     // what its addresses are relative to: 0 for the executable
  uint64_t phdr;     // its program headers, mapped
  uint32_t phnum;    // how many
  uint32_t reserved; // 0
  uint64_t dynamic;  // its PT_DYNAMIC, mapped; 0 if it has none
  uint64_t tls_init; // its PT_TLS image, mapped; tls_memsz 0: none
  uint64_t tls_filesz, tls_memsz, tls_align;
  int64_t tls_offset;              // where its block begins, from the thread pointer
  uint64_t init_array, init_count; // DT_INIT_ARRAY: functions, run in order
  uint64_t fini_array, fini_count; // DT_FINI_ARRAY: run in reverse
} vx_dl_object;

typedef struct vx_dl_handover {
  uint32_t magic;       // VX_DL_MAGIC
  uint32_t version;     // VX_DL_VERSION
  const uint8_t *spawn; // the spawn message, as read from the bootstrap channel
  uint64_t spawn_bytes;
  const vx_handle *handles; // its handles, in the message's order
  uint32_t handle_count;
  uint32_t object_count; // the executable first, then the libraries in load order
  const vx_dl_object *objects;
  uint64_t tls_size;  // the static TLS the objects need, past the thread control block
  uint64_t tls_align; // their largest alignment
} vx_dl_handover;
