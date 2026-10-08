// vx-dl: the dynamic loader's mapping and binding (ADR-0047), which /lib/ld-vx
// uses to start a dynamic program, and the hot-reload host will to map a code
// image into a running one.
//
// The executable is mapped at its link address (vx_elf_load, as a spawn maps
// a static program); each library in a reservation of its own span with a
// page left unmapped on each side, at a random base. Libraries are loaded
// breadth first from the executable's DT_NEEDED, each once: the list of
// objects is the queue. A symbol binds to the first definition in that order,
// the executable first. Every relocation is applied before the program runs
// (-z now); then each object's PT_GNU_RELRO is made read-only. TLS is static:
// each object's block follows the one before it, away from the thread
// pointer, at its own alignment.
//
// Every address taken from an object is checked to lie inside its mapped
// span, so a damaged library is refused, not followed.

#pragma once

#include <stdckdint.h>

#include "../../abi/vx/dl.h"
#include "../vx-rt/elf.h"
#include "../vx-rt/spawn.c" // vx_elf_load, and vx-rt's calls

// C strings, as vx-rt has no string.h past mem*: equal, and a name's length.
static bool vxdl_eq(const char *a, const char *b) {
  vx_str x = vx_cstr(a), y = vx_cstr(b);
  return x.len == y.len && memcmp(x.ptr, y.ptr, x.len) == 0;
}

static constexpr uint32_t VXDL_OBJECTS = 32;
static constexpr uint32_t VXDL_NEEDED = 16;

typedef struct vxdl_obj {
  uint64_t lo, hi; // the span its segments are mapped in, base included
  uint64_t tls_p_align;
  const vx_elf_sym *symtab;
  const char *strtab;
  uint64_t strsz;
  const uint32_t *hash, *gnu_hash;
  const vx_elf_rela *rela, *jmprel;
  uint64_t rela_size, jmprel_size;
  const uint64_t *relr;
  uint64_t relr_size;
  uint64_t relro, relro_size;
  uint64_t needed[VXDL_NEEDED]; // DT_NEEDED's names, as strtab offsets
  uint32_t needed_count;
  bool textrel;
  char name[64];
} vxdl_obj;

typedef struct vxdl {
  vxdl_obj obj[VXDL_OBJECTS];
  vx_dl_object pub[VXDL_OBJECTS]; // the handover's list (vx/dl.h), filled as objects load
  uint32_t count;
  // Reads the whole of a file of the namespace: its bytes, which may be let
  // go once vxdl_load returns.
  vx_status (*read)(void *ctx, const char *path, const uint8_t **data, size_t *size);
  void *ctx;
  int64_t tls_next; // where the next object's TLS block goes, from the thread pointer
  uint64_t tls_size, tls_align;
  char why[160]; // what failed
} vxdl;

static void vxdl_say(vxdl *dl, const char *a, const char *b) {
  size_t n = 0;
  for (const char *s = a; s && *s && n + 1 < sizeof dl->why; s++) dl->why[n++] = *s;
  for (const char *s = b; s && *s && n + 1 < sizeof dl->why; s++) dl->why[n++] = *s;
  dl->why[n] = 0;
}

static uint64_t vxdl_up(uint64_t v, uint64_t a) { return (v + a - 1) & ~(a - 1); }

// Whether [addr, addr + n) lies inside an object's span.
static bool vxdl_inside(const vxdl_obj *o, uint64_t addr, uint64_t n) {
  uint64_t end;
  return addr >= o->lo && !ckd_add(&end, addr, n) && end <= o->hi;
}

// --- Mapping ---

static bool vxdl_header(const uint8_t *image, size_t size, uint16_t type, vx_elf_header *eh) {
  uint64_t table_end;
  if (size < sizeof *eh) return false;
  memcpy(eh, image, sizeof *eh);
  return memcmp(eh->ident,
                "\x7f"
                "ELF",
                4) == 0 &&
         eh->ident[4] == 2 && eh->ident[5] == 1 && eh->type == type && eh->machine == VX_ELF_MACHINE &&
         eh->phentsize == sizeof(vx_elf_phdr) &&
         !ckd_mul(&table_end, (uint64_t)eh->phnum, sizeof(vx_elf_phdr)) &&
         !ckd_add(&table_end, table_end, eh->phoff) && table_end <= size;
}

static vx_elf_phdr vxdl_phdr(const uint8_t *image, const vx_elf_header *eh, uint16_t i) {
  vx_elf_phdr ph;
  memcpy(&ph, image + eh->phoff + (uint64_t)i * sizeof ph, sizeof ph);
  return ph;
}

// The address a file offset is mapped at (through the PT_LOAD that holds it),
// or 0.
static uint64_t vxdl_mapped_at(const uint8_t *image, const vx_elf_header *eh, uint64_t base, uint64_t off) {
  for (uint16_t i = 0; i < eh->phnum; i++) {
    vx_elf_phdr ph = vxdl_phdr(image, eh, i);
    if (ph.type == VX_PT_LOAD && off >= ph.offset && off < ph.offset + ph.filesz)
      return base + ph.vaddr + (off - ph.offset);
  }
  return 0;
}

// What a loaded object's headers say, once its segments are mapped: its
// program headers, dynamic section and TLS block, into the handover's record.
static void vxdl_describe(vxdl *dl, uint32_t k, const uint8_t *image, const vx_elf_header *eh) {
  vxdl_obj *o = &dl->obj[k];
  vx_dl_object *p = &dl->pub[k];
  p->phdr = vxdl_mapped_at(image, eh, p->base, eh->phoff);
  p->phnum = eh->phnum;
  for (uint16_t i = 0; i < eh->phnum; i++) {
    vx_elf_phdr ph = vxdl_phdr(image, eh, i);
    if (ph.type == VX_PT_DYNAMIC) p->dynamic = p->base + ph.vaddr;
    if (ph.type == VX_PT_GNU_RELRO) o->relro = p->base + ph.vaddr, o->relro_size = ph.memsz;
    if (ph.type == VX_PT_TLS && ph.memsz) {
      p->tls_init = p->base + ph.vaddr;
      p->tls_filesz = ph.filesz, p->tls_memsz = ph.memsz;
      p->tls_align = ph.align ? ph.align : 1;
    }
  }
}

// The executable, at its link address.
static bool vxdl_load_exe(vxdl *dl, const uint8_t *image, size_t size, uint64_t *entry) {
  vx_elf_header eh;
  if (!vxdl_header(image, size, VX_ET_EXEC, &eh))
    return vxdl_say(dl, "the program is not an executable", ""), false;
  vx_status st = vx_elf_load(vx_self, image, size, entry);
  if (st != VX_OK) return vxdl_say(dl, "cannot map the program", ""), false;
  vxdl_obj *o = &dl->obj[0];
  o->lo = UINT64_MAX;
  for (uint16_t i = 0; i < eh.phnum; i++) {
    vx_elf_phdr ph = vxdl_phdr(image, &eh, i);
    if (ph.type != VX_PT_LOAD || !ph.memsz) continue;
    if (ph.vaddr < o->lo) o->lo = ph.vaddr;
    if (ph.vaddr + ph.memsz > o->hi) o->hi = ph.vaddr + ph.memsz;
  }
  dl->pub[0].name = "";
  dl->count = 1;
  vxdl_describe(dl, 0, image, &eh);
  return true;
}

// A shared object's segments, in a reservation of their span and a guard
// page on each side.
static bool vxdl_map_lib(vxdl *dl, vxdl_obj *o, vx_dl_object *p, const uint8_t *image, size_t size,
                         const vx_elf_header *eh) {
  uint64_t lo = UINT64_MAX, hi = 0;
  for (uint16_t i = 0; i < eh->phnum; i++) {
    vx_elf_phdr ph = vxdl_phdr(image, eh, i);
    uint64_t end;
    if (ph.type != VX_PT_LOAD || !ph.memsz) continue;
    if (ph.filesz > ph.memsz || ckd_add(&end, ph.offset, ph.filesz) || end > size ||
        ckd_add(&end, ph.vaddr, ph.memsz) || ((ph.flags & VX_PF_W) && (ph.flags & VX_PF_X)))
      return vxdl_say(dl, o->name, ": a bad segment"), false;
    if ((ph.vaddr & ~4095ull) < lo) lo = ph.vaddr & ~4095ull;
    if (vxdl_up(end, 4096) > hi) hi = vxdl_up(end, 4096);
  }
  if (lo >= hi) return vxdl_say(dl, o->name, ": no segments"), false;
  uint64_t at = 0;
  vx_status st = vx_as_reserve(vx_self, hi - lo + 2ull * 4096, 0, 0, &at);
  if (st != VX_OK) return vxdl_say(dl, o->name, ": cannot reserve its addresses"), false;
  p->base = at + 4096 - lo;
  o->lo = p->base + lo, o->hi = p->base + hi;
  for (uint16_t i = 0; i < eh->phnum && st == VX_OK; i++) {
    vx_elf_phdr ph = vxdl_phdr(image, eh, i);
    if (ph.type != VX_PT_LOAD || !ph.memsz) continue;
    uint64_t start = ph.vaddr & ~4095ull, len = vxdl_up(ph.vaddr + ph.memsz, 4096) - start,
             va = p->base + start;
    vx_handle vmo = VX_HANDLE_NONE;
    st = vx_vmo_create(len, 0, &vmo);
    if (st == VX_OK && ph.filesz)
      st = vx_vmo_rw(vmo, VX_VMO_WRITE, ph.vaddr - start, (void *)(image + ph.offset), ph.filesz);
    // Writable while it is bound: RELRO is made read-only after.
    if (st == VX_OK)
      st = vx_as_map(vx_self, vmo, 0, len,
                     (ph.flags & VX_PF_W ? VX_MAP_WRITE : 0) | (ph.flags & VX_PF_X ? VX_MAP_EXEC : 0), &va);
    if (vmo) vx_handle_close(vmo);
    if (st == VX_OK && va != p->base + start) st = VX_ERR_INVALID;
  }
  if (st != VX_OK) return vxdl_say(dl, o->name, ": cannot map its segments"), false;
  return true;
}

// The library /lib/NAME, unless it is loaded already.
static bool vxdl_load_lib(vxdl *dl, const char *name) {
  for (uint32_t i = 1; i < dl->count; i++)
    if (vxdl_eq(dl->obj[i].name, name)) return true;
  if (dl->count == VXDL_OBJECTS) return vxdl_say(dl, "too many libraries, at ", name), false;
  size_t len = vx_cstr(name).len;
  bool slash = false;
  for (size_t i = 0; i < len; i++) slash = slash || name[i] == '/';
  if (!len || len >= sizeof dl->obj[0].name || slash)
    return vxdl_say(dl, "a bad library name: ", name), false;
  char path[80] = "/lib/";
  memcpy(path + 5, name, len + 1);
  const uint8_t *image = nullptr;
  size_t size = 0;
  vx_status st = dl->read(dl->ctx, path, &image, &size);
  if (st != VX_OK) return vxdl_say(dl, "cannot read ", path), false;
  vxdl_obj *o = &dl->obj[dl->count];
  vx_dl_object *p = &dl->pub[dl->count];
  *o = (vxdl_obj){};
  *p = (vx_dl_object){};
  memcpy(o->name, name, len + 1);
  p->name = o->name;
  vx_elf_header eh;
  if (!vxdl_header(image, size, VX_ET_DYN, &eh)) return vxdl_say(dl, path, " is not a shared library"), false;
  if (!vxdl_map_lib(dl, o, p, image, size, &eh)) return false;
  vxdl_describe(dl, dl->count, image, &eh);
  dl->count++;
  return true;
}

// --- The dynamic section ---

// An address the dynamic section gives, relocated and checked: 0 if outside.
static uint64_t vxdl_ptr(const vxdl_obj *o, uint64_t base, uint64_t v, uint64_t n) {
  uint64_t a = base + v;
  return vxdl_inside(o, a, n) ? a : 0;
}

static bool vxdl_dynamic(vxdl *dl, uint32_t k) {
  vxdl_obj *o = &dl->obj[k];
  vx_dl_object *p = &dl->pub[k];
  if (!p->dynamic) return true; // nothing to bind: a static library, or a program that needs none
  uint64_t strtab = 0, symtab = 0, rela = 0, jmprel = 0, relr = 0, init = 0, fini = 0, hash = 0, gnu_hash = 0;
  uint64_t init_size = 0, fini_size = 0, pltrel = VX_DT_RELA;
  for (const vx_elf_dyn *d = (const vx_elf_dyn *)p->dynamic; vxdl_inside(o, (uint64_t)d, sizeof *d) && d->tag;
       d++) {
    switch (d->tag) {
    case VX_DT_NEEDED:
      if (o->needed_count == VXDL_NEEDED) return vxdl_say(dl, o->name, ": too many libraries needed"), false;
      o->needed[o->needed_count++] = d->val;
      break;
    case VX_DT_STRTAB: strtab = d->val; break;
    case VX_DT_STRSZ: o->strsz = d->val; break;
    case VX_DT_SYMTAB: symtab = d->val; break;
    case VX_DT_HASH: hash = d->val; break;
    case VX_DT_GNU_HASH: gnu_hash = d->val; break;
    case VX_DT_RELA: rela = d->val; break;
    case VX_DT_RELASZ: o->rela_size = d->val; break;
    case VX_DT_JMPREL: jmprel = d->val; break;
    case VX_DT_PLTRELSZ: o->jmprel_size = d->val; break;
    case VX_DT_PLTREL: pltrel = (int64_t)d->val; break;
    case VX_DT_RELR: relr = d->val; break;
    case VX_DT_RELRSZ: o->relr_size = d->val; break;
    case VX_DT_INIT_ARRAY: init = d->val; break;
    case VX_DT_INIT_ARRAYSZ: init_size = d->val; break;
    case VX_DT_FINI_ARRAY: fini = d->val; break;
    case VX_DT_FINI_ARRAYSZ: fini_size = d->val; break;
    case VX_DT_TEXTREL: o->textrel = true; break;
    case VX_DT_REL: return vxdl_say(dl, o->name, ": REL relocations (only RELA)"), false;
    default: break;
    }
  }
  if (o->textrel || pltrel != VX_DT_RELA) return vxdl_say(dl, o->name, ": text or REL relocations"), false;
  uint64_t b = p->base;
  o->strtab = (const char *)vxdl_ptr(o, b, strtab, o->strsz);
  o->symtab = (const vx_elf_sym *)vxdl_ptr(o, b, symtab, sizeof(vx_elf_sym));
  o->hash = (const uint32_t *)vxdl_ptr(o, b, hash, 8);
  o->gnu_hash = (const uint32_t *)vxdl_ptr(o, b, gnu_hash, 16);
  o->rela = (const vx_elf_rela *)vxdl_ptr(o, b, rela, o->rela_size);
  o->jmprel = (const vx_elf_rela *)vxdl_ptr(o, b, jmprel, o->jmprel_size);
  o->relr = (const uint64_t *)vxdl_ptr(o, b, relr, o->relr_size);
  p->init_array = init_size ? vxdl_ptr(o, b, init, init_size) : 0,
  p->init_count = p->init_array ? init_size / 8 : 0;
  p->fini_array = fini_size ? vxdl_ptr(o, b, fini, fini_size) : 0,
  p->fini_count = p->fini_array ? fini_size / 8 : 0;
  if ((strtab && !o->strtab) || (symtab && !o->symtab) || (rela && !o->rela) || (jmprel && !o->jmprel) ||
      (relr && !o->relr) || (init_size && !p->init_array) || (fini_size && !p->fini_array))
    return vxdl_say(dl, o->name, ": its dynamic section points outside it"), false;
  for (uint32_t i = 0; i < o->needed_count; i++)
    if (!o->strtab || o->needed[i] >= o->strsz) return vxdl_say(dl, o->name, ": a bad DT_NEEDED"), false;
  return true;
}

// --- Symbols ---

static const char *vxdl_name(const vxdl_obj *o, uint32_t off) {
  return o->strtab && off < o->strsz ? o->strtab + off : "";
}

// A symbol defined in o, by GNU's hash table or else the SysV one.
static const vx_elf_sym *vxdl_lookup_in(const vxdl_obj *o, const char *name) {
  if (!o->symtab || !o->strtab) return nullptr;
  if (o->gnu_hash) {
    uint32_t h = 5381;
    for (const char *s = name; *s; s++) h = h * 33 + (uint8_t)*s;
    const uint32_t *t = o->gnu_hash;
    uint32_t nbuckets = t[0], symoffset = t[1], bloom = t[2];
    if (!nbuckets || !vxdl_inside(o, (uint64_t)t, 16 + (uint64_t)bloom * 8 + (uint64_t)nbuckets * 4))
      return nullptr;
    const uint32_t *buckets = t + 4 + (size_t)bloom * 2, *chain = buckets + nbuckets;
    for (uint32_t i = buckets[h % nbuckets]; i && i >= symoffset; i++) {
      if (!vxdl_inside(o, (uint64_t)&chain[i - symoffset], 4)) return nullptr;
      uint32_t c = chain[i - symoffset];
      const vx_elf_sym *sym = &o->symtab[i];
      if ((c | 1) == (h | 1) && vxdl_inside(o, (uint64_t)sym, sizeof *sym) &&
          vxdl_eq(vxdl_name(o, sym->name), name))
        return sym;
      if (c & 1) break;
    }
    return nullptr;
  }
  if (o->hash) {
    uint32_t h = 0;
    for (const char *s = name; *s; s++) {
      h = (h << 4) + (uint8_t)*s;
      uint32_t g = h & 0xf0000000;
      h = (h ^ (g >> 24)) & ~g;
    }
    uint32_t nbucket = o->hash[0], nchain = o->hash[1];
    if (!nbucket || !vxdl_inside(o, (uint64_t)o->hash, 8 + ((uint64_t)nbucket + nchain) * 4)) return nullptr;
    const uint32_t *bucket = o->hash + 2, *chain = bucket + nbucket;
    for (uint32_t i = bucket[h % nbucket], n = 0; i && i < nchain && n < nchain; i = chain[i], n++)
      if (vxdl_eq(vxdl_name(o, o->symtab[i].name), name)) return &o->symtab[i];
  }
  return nullptr;
}

// The first definition of name from object `from` on; *def its object.
static const vx_elf_sym *vxdl_find(vxdl *dl, const char *name, uint32_t from, uint32_t *def) {
  for (uint32_t i = from; i < dl->count; i++) {
    const vx_elf_sym *s = vxdl_lookup_in(&dl->obj[i], name);
    if (s && s->shndx && (s->info >> 4) != VX_STB_LOCAL) return *def = i, s;
  }
  return nullptr;
}

// --- TLS ---

// Each object's block after the one before it: below the thread pointer on
// x86_64 (variant II: the executable's ends there), above it on aarch64
// (variant I: past the two words there), at its own alignment.
static void vxdl_tls(vxdl *dl) {
  dl->tls_align = 16;
#ifdef __x86_64__
  dl->tls_next = 0;
#else
  dl->tls_next = 16;
#endif
  for (uint32_t i = 0; i < dl->count; i++) {
    vx_dl_object *p = &dl->pub[i];
    if (!p->tls_memsz) continue;
    uint64_t a = p->tls_align;
    if (a > dl->tls_align) dl->tls_align = a;
#ifdef __x86_64__
    p->tls_offset = -(int64_t)vxdl_up((uint64_t)-dl->tls_next + p->tls_memsz, a);
    dl->tls_next = p->tls_offset;
    dl->tls_size = (uint64_t)-dl->tls_next;
#else
    p->tls_offset = (int64_t)vxdl_up((uint64_t)dl->tls_next, a);
    dl->tls_next = p->tls_offset + (int64_t)p->tls_memsz;
    dl->tls_size = (uint64_t)dl->tls_next;
#endif
  }
}

// --- Relocation ---

static bool vxdl_apply(vxdl *dl, uint32_t k, const vx_elf_rela *r) {
  vxdl_obj *o = &dl->obj[k];
  vx_dl_object *p = &dl->pub[k];
  uint32_t type = (uint32_t)r->info, symi = (uint32_t)(r->info >> 32);
  uint64_t where = p->base + r->offset;
  if (type == VX_R_NONE) return true;
  // A copy writes its symbol's size, checked below; the rest a word.
  if (type != VX_R_COPY && !vxdl_inside(o, where, 8))
    return vxdl_say(dl, o->name, ": a relocation outside it"), false;
  uint64_t *slot = (uint64_t *)where;
  if (type == VX_R_RELATIVE) return *slot = p->base + (uint64_t)r->addend, true;
  const vx_elf_sym *sym = nullptr, *ds = nullptr;
  uint32_t def = k;
  if (symi) {
    if (!o->symtab || !vxdl_inside(o, (uint64_t)&o->symtab[symi], sizeof *sym))
      return vxdl_say(dl, o->name, ": a bad symbol index"), false;
    sym = &o->symtab[symi];
    const char *name = vxdl_name(o, sym->name);
    if ((sym->info >> 4) == VX_STB_LOCAL)
      ds = sym; // its own
    else
      ds = vxdl_find(dl, name, type == VX_R_COPY ? 1 : 0, &def); // a copy comes from a library
    if (!ds && (sym->info >> 4) != VX_STB_WEAK) return vxdl_say(dl, "undefined symbol ", name), false;
  }
  uint64_t value = ds ? dl->pub[def].base + ds->value : 0;
  switch (type) {
  case VX_R_ABS64:
  case VX_R_GLOB_DAT:
  case VX_R_JUMP_SLOT: *slot = value + (uint64_t)r->addend; return true;
  case VX_R_COPY:
    if (!ds || ds->size != sym->size || !vxdl_inside(o, where, sym->size) ||
        !vxdl_inside(&dl->obj[def], value, ds->size))
      return vxdl_say(dl, o->name, ": a bad copy relocation"), false;
    memcpy((void *)where, (const void *)value, sym->size);
    return true;
  case VX_R_TPOFF64:
    if (!dl->pub[def].tls_memsz) return vxdl_say(dl, o->name, ": TLS where there is none"), false;
    *slot = (uint64_t)(dl->pub[def].tls_offset + (int64_t)(ds ? ds->value : 0) + r->addend);
    return true;
  case VX_R_DTPMOD64: *slot = def + 1; return true;
  case VX_R_DTPOFF64: *slot = (ds ? ds->value : 0) + (uint64_t)r->addend; return true;
  default: return vxdl_say(dl, o->name, ": a relocation of a kind the loader does not take"), false;
  }
}

static bool vxdl_relocate(vxdl *dl, uint32_t k) {
  vxdl_obj *o = &dl->obj[k];
  uint64_t base = dl->pub[k].base, where = 0;
  for (uint64_t i = 0; o->relr && i < o->relr_size / 8; i++) { // packed relative relocations
    uint64_t e = o->relr[i];
    if (!(e & 1)) {
      where = base + e;
      if (!vxdl_inside(o, where, 8)) return vxdl_say(dl, o->name, ": a relocation outside it"), false;
      *(uint64_t *)where += base;
      where += 8;
      continue;
    }
    for (uint32_t bit = 1; bit < 64; bit++) {
      uint64_t at = where + (uint64_t)(bit - 1) * 8;
      if (!((e >> bit) & 1)) continue;
      if (!vxdl_inside(o, at, 8)) return vxdl_say(dl, o->name, ": a relocation outside it"), false;
      *(uint64_t *)at += base;
    }
    where += 63ull * 8;
  }
  for (uint64_t i = 0; o->rela && i < o->rela_size / sizeof *o->rela; i++)
    if (!vxdl_apply(dl, k, &o->rela[i])) return false;
  for (uint64_t i = 0; o->jmprel && i < o->jmprel_size / sizeof *o->jmprel; i++)
    if (!vxdl_apply(dl, k, &o->jmprel[i])) return false;
  return true;
}

// --- The whole ---

// Loads the executable image and every library it needs, binds them, and
// fills *h, the handover (vx/dl.h) but for the spawn message. false, with
// dl->why, on any failure.
[[maybe_unused]] static bool vxdl_load(vxdl *dl, const uint8_t *image, size_t size, uint64_t *entry,
                                       vx_dl_handover *h) {
  if (!vxdl_load_exe(dl, image, size, entry)) return false;
  for (uint32_t k = 0; k < dl->count; k++) { // the list is the queue: breadth first
    if (!vxdl_dynamic(dl, k)) return false;
    for (uint32_t i = 0; i < dl->obj[k].needed_count; i++)
      if (!vxdl_load_lib(dl, vxdl_name(&dl->obj[k], (uint32_t)dl->obj[k].needed[i]))) return false;
  }
  vxdl_tls(dl);
  // The libraries first, the executable last: its COPY relocations copy a
  // library's data (stdout's pointer, say) only once that is relocated.
  for (uint32_t k = 1; k <= dl->count; k++)
    if (!vxdl_relocate(dl, k % dl->count)) return false;
  for (uint32_t k = 0; k < dl->count; k++) { // bound: RELRO read-only now
    const vxdl_obj *o = &dl->obj[k];
    uint64_t lo = o->relro & ~4095ull, hi = (o->relro + o->relro_size) & ~4095ull;
    if (o->relro_size && hi > lo && vx_as_protect(vx_self, lo, hi - lo, 0) != VX_OK)
      return vxdl_say(dl, o->name, ": cannot make its RELRO read-only"), false;
  }
  *h = (vx_dl_handover){.magic = VX_DL_MAGIC,
                        .version = VX_DL_VERSION,
                        .object_count = dl->count,
                        .objects = dl->pub,
                        .tls_size = dl->tls_size,
                        .tls_align = dl->tls_align};
  return true;
}
