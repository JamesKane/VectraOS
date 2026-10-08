// ld-vx: the dynamic loader (ADR-0047), /lib/ld-vx. A spawn maps it in place
// of a program with PT_INTERP, and gives it the program's image as the VMO
// dl.exe. It builds the namespace from the spawn message, as any program
// does (the connectors it uses stay the process's), loads and binds the
// program and the libraries it needs from /lib (lib/vx-dl), then jumps to the
// program's entry with the handover: the spawn message as it read it, with
// its handles, and the loaded objects. It never returns there; its own pages
// stay mapped.
//
// It is linked at a fixed address below where the kernel places mappings,
// so it needs no relocation of its own.

#include "../lib/vx-rt/rt.c"
#include "../lib/vx-ns/spawn.c"
#include "../lib/vx-dl/dl.c"

static vx_ns ns;

// The whole of a file of the namespace, in the process heap.
static vx_status ld_read(void *ctx, const char *path, const uint8_t **data, size_t *size) {
  vx_ns_file f;
  vx_status st = vx_ns_open((vx_ns *)ctx, vx_cstr(path), P9_OREAD, &f);
  if (st != VX_OK) return st;
  size_t cap = 256ul * 1024, len = 0;
  uint8_t *buf = vx_heap_alloc(vx_heap_process(), cap);
  int64_t n = buf ? 1 : VX_ERR_NO_MEMORY;
  while (buf && n > 0) {
    if (len == cap) { // twice the room
      uint8_t *more = vx_heap_alloc(vx_heap_process(), cap * 2);
      if (more) memcpy(more, buf, len);
      vx_heap_free(vx_heap_process(), buf);
      buf = more, cap *= 2;
      if (!buf) break;
    }
    n = vx_ns_read(&f, buf + len, (uint32_t)(cap - len > 65536 ? 65536 : cap - len));
    if (n > 0) len += (size_t)n;
  }
  vx_ns_close(&f);
  if (!buf) return VX_ERR_NO_MEMORY;
  if (n < 0) {
    vx_heap_free(vx_heap_process(), buf);
    return (vx_status)n;
  }
  *data = buf, *size = len;
  return VX_OK;
}

// The program's image from dl.exe: its headers first, then as much as its
// segments and headers reach.
static const uint8_t *ld_image(vx_handle exe, size_t *size) {
  uint8_t head[4096];
  vx_elf_header eh;
  if (vx_vmo_rw(exe, VX_VMO_READ, 0, head, sizeof head) != VX_OK) return nullptr;
  memcpy(&eh, head, sizeof eh);
  uint64_t end = eh.phoff + (uint64_t)eh.phnum * sizeof(vx_elf_phdr);
  if (eh.phentsize != sizeof(vx_elf_phdr) || end > sizeof head) return nullptr;
  for (uint16_t i = 0; i < eh.phnum; i++) {
    vx_elf_phdr ph;
    memcpy(&ph, head + eh.phoff + (uint64_t)i * sizeof ph, sizeof ph);
    if ((ph.type == VX_PT_LOAD || ph.type == VX_PT_TLS || ph.type == VX_PT_INTERP) &&
        ph.offset + ph.filesz > end)
      end = ph.offset + ph.filesz;
  }
  uint8_t *image = vx_heap_alloc(vx_heap_process(), end);
  if (!image || vx_vmo_rw(exe, VX_VMO_READ, 0, image, end) != VX_OK) return nullptr;
  *size = end;
  return image;
}

static vxdl dl;
static vx_dl_handover handover;

const char *vx_main(void) {
  static char why[200];
  vx_handle exe = vx_spawn_take("dl.exe");
  if (!exe) return "ld-vx: no program to load (it is the loader, run by a spawn)";
  size_t size = 0;
  const uint8_t *image = ld_image(exe, &size);
  if (!image) return "ld-vx: cannot read the program's image";
  if (vx_ns_from_spawn(&ns) != VX_OK) return "ld-vx: no namespace";
  dl.read = ld_read, dl.ctx = &ns;
  uint64_t entry = 0;
  if (!vxdl_load(&dl, image, size, &entry, &handover)) {
    vx_str name = vx_spawn.name;
    size_t n = 0;
    for (const char *s = "ld-vx: "; *s; s++) why[n++] = *s;
    for (size_t i = 0; i < name.len && n + 2 < sizeof why; i++) why[n++] = name.ptr[i];
    why[n++] = ':', why[n++] = ' ';
    for (const char *s = dl.why; *s && n + 1 < sizeof why; s++) why[n++] = *s;
    why[n] = 0;
    return why;
  }
  // The program reads the spawn message as this read it; dl.exe was this one's.
  vx_handle_close(exe);
  for (uint32_t i = 0; i < vx_spawn_raw.handle_count; i++)
    if (vx_spawn_raw.handles[i] == exe) vx_spawn_raw.handles[i] = VX_HANDLE_NONE;
  handover.spawn = vx_spawn_msg, handover.spawn_bytes = vx_spawn_raw.bytes;
  handover.handles = vx_spawn_raw.handles, handover.handle_count = vx_spawn_raw.handle_count;
  vx_stdout_flush();
  ((void (*)(vx_handle, const vx_dl_handover *))entry)(VX_HANDLE_NONE, &handover);
  return "ld-vx: the program returned to its loader";
}
