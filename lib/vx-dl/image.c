// image.c: vx_image_open and vx_image_symbol (vx/image.h, ADR-0056), code
// images mapped into a running process with vx-dl, for hot reload (03 §6.1).
//
// The first open rebuilds vx-dl's view of the process from ld-vx's handover
// (vx_dl, crt1.c): each loaded object's span from its program headers, its
// symbols from its dynamic section. A static program has none, so its
// images bind against themselves alone. An image is mapped as a library is,
// but never from the file's own pages: each open copies it into fresh
// memory at a new base, so two opens of one path are two images. It takes
// the slot past the loaded objects while it is bound, so its references
// resolve to them first and itself last, then leaves it: no image binds
// against another. Its .fini_array never runs, as it is never unmapped.

#pragma once

#include "../vx-rt/rt.c"
#include "../vx-ns/nsapi.c"
#include "dl.c"

struct vx_image {
  vxdl_obj obj;
  uint64_t base;
};

static vxdl vx_image_dl;
static int vx_image_ready; // 0 until the first open, then 1, or -1: the process's objects did not read
static vx_lock_t vx_image_lock;

static vx_status vx_image_fail(vx_str path, const char *why) {
  char buf[VX_ERRMAX];
  size_t n = vx_bfmt((vx_bytes){(uint8_t *)buf, sizeof buf}, "image %.*s: %s", VX_FMT(path), why);
  vx_err_set((vx_str){buf, n});
  return VX_ERR_INVALID;
}

// vx-dl's objects from the handover, once: their spans and dynamic sections.
static bool vx_image_start(vxdl *dl) {
  for (uint32_t k = 0; vx_dl && k < vx_dl->object_count && k < VXDL_OBJECTS; k++) {
    vxdl_obj *o = &dl->obj[k];
    vx_dl_object *p = &dl->pub[k];
    *p = vx_dl->objects[k];
    *o = (vxdl_obj){.lo = UINT64_MAX};
    size_t len = vx_cstr(p->name).len;
    if (len >= sizeof o->name) len = sizeof o->name - 1;
    memcpy(o->name, p->name, len);
    p->name = o->name;
    const vx_elf_phdr *ph = (const vx_elf_phdr *)p->phdr;
    for (uint32_t i = 0; ph && i < p->phnum; i++) {
      if (ph[i].type != VX_PT_LOAD || !ph[i].memsz) continue;
      uint64_t lo = p->base + (ph[i].vaddr & ~4095ull),
               hi = p->base + vxdl_up(ph[i].vaddr + ph[i].memsz, 4096);
      if (lo < o->lo) o->lo = lo;
      if (hi > o->hi) o->hi = hi;
    }
    for (uint32_t i = 0; ph && i < p->phnum; i++)
      if (ph[i].type == VX_PT_GNU_RELRO) o->relro = p->base + ph[i].vaddr, o->relro_size = ph[i].memsz;
    dl->count = k + 1;
    if (!vxdl_dynamic(dl, k)) return false;
  }
  return true;
}

// The whole file at path, in the process heap.
static vx_status vx_image_read(vx_str path, uint8_t **data, size_t *size) {
  vx_fd fd = vx_open(path, VX_OREAD);
  if (fd < 0) return (vx_status)fd;
  int64_t len = vx_seek(fd, 0, VX_SEEK_END);
  uint8_t *buf = len > 0 ? vx_heap_alloc(vx_heap_process(), (size_t)len) : nullptr;
  int64_t got = 0, n = 1;
  while (buf && got < len && n > 0) {
    n = vx_pread(fd, (vx_bytes){buf + got, (size_t)(len - got)}, (uint64_t)got);
    if (n > 0) got += n;
  }
  vx_close(fd);
  if (!buf || got != len) {
    if (buf) vx_heap_free(vx_heap_process(), buf);
    if (len < 0) return (vx_status)len;
    return n < 0 ? (vx_status)n : VX_ERR_IO;
  }
  *data = buf, *size = (size_t)len;
  return VX_OK;
}

// Maps, binds and starts the image in the slot past the loaded objects.
static vx_status vx_image_load(vxdl *dl, vx_str path, const uint8_t *data, size_t size, vx_image *im) {
  if (dl->count == VXDL_OBJECTS) return vx_image_fail(path, "too many objects loaded");
  uint32_t k = dl->count;
  vxdl_obj *o = &dl->obj[k];
  vx_dl_object *p = &dl->pub[k];
  *o = (vxdl_obj){};
  *p = (vx_dl_object){.name = o->name};
  size_t at = path.len;
  while (at && path.ptr[at - 1] != '/') at--;
  size_t len = path.len - at < sizeof o->name ? path.len - at : sizeof o->name - 1;
  memcpy(o->name, path.ptr + at, len); // its name in vx-dl's words: the path's last element
  vx_elf_header eh;
  if (!vxdl_header(data, size, VX_ET_DYN, &eh)) return vx_image_fail(path, "not a shared library");
  // Copied, never the file's pages: a later build renamed over the path
  // leaves this copy as it was.
  if (!vxdl_map_lib(dl, o, p, data, size, &eh, VX_HANDLE_NONE)) return vx_image_fail(path, dl->why);
  vxdl_describe(dl, k, data, &eh);
  if (p->tls_memsz) return vx_image_fail(path, "it has TLS, which an image may not (ADR-0047 item 6)");
  if (!vxdl_dynamic(dl, k)) return vx_image_fail(path, dl->why);
  for (uint32_t i = 0; i < o->needed_count; i++) {
    const char *need = vxdl_name(o, (uint32_t)o->needed[i]);
    bool loaded = false;
    for (uint32_t j = 1; j < k && !loaded; j++) loaded = vxdl_eq(dl->obj[j].name, need);
    if (!loaded) return vxdl_say(dl, "it needs a library not loaded: ", need), vx_image_fail(path, dl->why);
  }
  dl->count++; // itself last in the search, for this bind only
  bool bound = vxdl_relocate(dl, k);
  dl->count--;
  if (!bound) return vx_image_fail(path, dl->why);
  uint64_t lo = o->relro & ~4095ull, hi = (o->relro + o->relro_size) & ~4095ull;
  if (o->relro_size && hi > lo && vx_as_protect(vx_self, lo, hi - lo, 0) != VX_OK)
    return vx_image_fail(path, "cannot make its RELRO read-only");
  *im = (vx_image){.obj = *o, .base = p->base};
  vx_run_array(p->init_array, p->init_count, false);
  return VX_OK;
}

VX_API vx_status vx_image_open(vx_str path, vx_image **image) {
  *image = nullptr;
  vx_image *im = vx_heap_alloc(vx_heap_process(), sizeof *im);
  if (!im) return VX_ERR_NO_MEMORY;
  uint8_t *data = nullptr;
  size_t size = 0;
  vx_status st = vx_image_read(path, &data, &size);
  if (st != VX_OK) {
    vx_heap_free(vx_heap_process(), im);
    return vx_file_fail("image", path, st);
  }
  vx_lock(&vx_image_lock);
  if (!vx_image_ready) vx_image_ready = vx_image_start(&vx_image_dl) ? 1 : -1;
  if (vx_image_ready < 0)
    st = vx_image_fail(path, vx_image_dl.why); // none ever will bind
  else
    st = vx_image_load(&vx_image_dl, path, data, size, im);
  vx_unlock(&vx_image_lock);
  vx_heap_free(vx_heap_process(), data);
  if (st != VX_OK) {
    vx_heap_free(vx_heap_process(), im); // what it mapped stays reserved: an image is never unmapped
    return st;
  }
  *image = im;
  return VX_OK;
}

VX_API void *vx_image_symbol(const vx_image *image, const char *name) {
  const vx_elf_sym *s = image ? vxdl_lookup_in(&image->obj, name) : nullptr;
  if (!s || !s->shndx || (s->info >> 4) == VX_STB_LOCAL) return nullptr;
  uint32_t type = s->info & 15;
  if (type != 1 && type != 2) return nullptr; // STT_OBJECT, STT_FUNC: not TLS, sections or files
  return (void *)(image->base + s->value);
}
