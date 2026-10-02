// vx-debug elf: an ELF64 image's sections, as the index builder needs them
// (debug.h). Every header and section is checked to lie inside the image.

#pragma once

#include "debug.h"

static uint16_t elf_u16(const uint8_t *p) { return (uint16_t)(p[0] | p[1] << 8); }
static uint32_t elf_u32(const uint8_t *p) {
  return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}
static uint64_t elf_u64(const uint8_t *p) { return elf_u32(p) | (uint64_t)elf_u32(p + 4) << 32; }

// Whether name (NUL-terminated within strtab) is s.
static bool elf_name_is(vxd_bytes strtab, uint32_t name, const char *s) {
  size_t i = 0;
  for (; name + i < strtab.n && s[i]; i++)
    if (strtab.p[name + i] != (uint8_t)s[i]) return false;
  return !s[i] && name + i < strtab.n && strtab.p[name + i] == 0;
}

static const char *const ELF_SECTION_NAMES[VXD_SECTIONS] = {
    [VXD_INFO] = ".debug_info", [VXD_ABBREV] = ".debug_abbrev",     [VXD_LINE] = ".debug_line",
    [VXD_STR] = ".debug_str",   [VXD_LINE_STR] = ".debug_line_str", [VXD_STR_OFFSETS] = ".debug_str_offsets",
    [VXD_ADDR] = ".debug_addr", [VXD_RNGLISTS] = ".debug_rnglists", [VXD_LOCLISTS] = ".debug_loclists",
    [VXD_SYMTAB] = ".symtab",   [VXD_STRTAB] = ".strtab",
};

// Reads image: a little-endian ELF64 file. False if it is not one, or its
// headers lie outside it. Sections it does not have are empty.
[[maybe_unused]] static bool vxd_elf_open(vxd_elf *e, const void *image, size_t size) {
  const uint8_t *b = image;
  *e = (vxd_elf){};
  static const uint8_t magic[4] = {0x7f, 'E', 'L', 'F'};
  if (size < 64 || memcmp(b, magic, 4) != 0 || b[4] != 2 || b[5] != 1) return false; // ELF64, little-endian
  e->machine = elf_u16(b + 18);
  uint64_t shoff = elf_u64(b + 40);
  uint16_t shentsize = elf_u16(b + 58), shnum = elf_u16(b + 60), shstrndx = elf_u16(b + 62);
  if (shentsize < 64 || shstrndx >= shnum || shoff > size || (uint64_t)shnum * shentsize > size - shoff)
    return false;
  const uint8_t *sh = b + shoff;
  vxd_bytes names = {};
  { // the section names
    const uint8_t *s = sh + (size_t)shstrndx * shentsize;
    uint64_t off = elf_u64(s + 24), len = elf_u64(s + 32);
    if (off > size || len > size - off) return false;
    names = (vxd_bytes){b + off, (size_t)len};
  }
  for (uint16_t i = 0; i < shnum; i++) {
    const uint8_t *s = sh + (size_t)i * shentsize;
    uint32_t name = elf_u32(s), type = elf_u32(s + 4);
    uint64_t off = elf_u64(s + 24), len = elf_u64(s + 32);
    if (type == 8 /* SHT_NOBITS */ || off > size || len > size - off) continue;
    vxd_bytes sec = {b + off, (size_t)len};
    for (uint32_t k = 0; k < VXD_SECTIONS; k++)
      if (elf_name_is(names, name, ELF_SECTION_NAMES[k])) e->sec[k] = sec;
    if (type == 7 /* SHT_NOTE */ && elf_name_is(names, name, ".note.gnu.build-id") && len >= 16) {
      uint32_t namesz = elf_u32(sec.p), descsz = elf_u32(sec.p + 4), kind = elf_u32(sec.p + 8);
      size_t desc = 12 + ((namesz + 3) & ~3u);
      if (kind == 3 && namesz == 4 && descsz <= sizeof e->build_id && desc <= len && descsz <= len - desc) {
        memcpy(e->build_id, sec.p + desc, descsz);
        e->build_id_len = descsz;
      }
    }
  }
  return true;
}
