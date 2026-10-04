// vx-slots: the ESP's boot slots (docs/06 §7, M5 step 9d), as install
// writes them and distd changes them. Three slots, \EFI\vectra\{a,b,c}\, each
// a release's kernel, root task modules and bootfs; one Limine, at the
// firmware's fallback path, whose configuration has an entry per slot in
// use, each path with its file's BLAKE2b-512 hash (which Limine checks), and
// the slot that boots as its default_entry. No UEFI boot entries: choosing
// a slot is rewriting the configuration (decided 2026-10-04; 06 §9.3's
// BootNext trial boot waits for M12).
//
// The table, \EFI\vectra\slots.ndb, says what each slot holds:
//
//   slot=a release=1 tree=b2:... kernel=<128 hex> svcd=... ktest=... bootfs=...
//   slot=b release=2 tree=b2:... ...
//   boot=b previous=a cmdline="vx.skip=gsh"
//
// and the configuration is made from it alone, so the two never disagree.
// Each entry's command line is vx.system vx.slot=X, then the table's cmdline.

#pragma once

#include "../../abi/vx/abi.h"
#include "../vx-ndb/ndb.c"

#if __STDC_HOSTED__
#include <string.h>
#else
#include "../vx-mem/mem.h"
#endif

static constexpr int VX_SLOTS = 3;
static constexpr int VX_SLOT_FILES = 4;
static constexpr int VX_SLOT_HASH = 128;

static const char *const VX_SLOT_FILE_NAMES[VX_SLOT_FILES] = {"kernel.elf", "svcd", "ktest", "bootfs.tar"};
static const char *const VX_SLOT_FILE_KEYS[VX_SLOT_FILES] = {"kernel", "svcd", "ktest", "bootfs"};

typedef struct vx_slot {
  bool used;
  uint64_t release;
  char tree[3 + 64 + 1];
  char hash[VX_SLOT_FILES][VX_SLOT_HASH + 1]; // each file's BLAKE2b-512, hex
} vx_slot;

typedef struct vx_slots {
  vx_slot slot[VX_SLOTS];
  int boot, previous; // 0, 1, 2 for a, b, c; -1 for none
  char cmdline[256];  // what each entry's command line has after vx.system vx.slot=X
} vx_slots;

static char vx_slot_name(int i) { return (char)('a' + i); }

static vx_str vx_slots_str(const char *s) {
  size_t n = 0;
  while (s[n]) n++;
  return (vx_str){s, n};
}

static void vx_slots_copy(char *out, size_t cap, vx_str v) {
  size_t n = v.len < cap - 1 ? v.len : cap - 1;
  memcpy(out, v.ptr, n);
  out[n] = 0;
}

// The table from its text: INVALID if it is not one.
[[maybe_unused]] static vx_status vx_slots_parse(vx_slots *s, vx_str text, char *scratch, size_t cap) {
  *s = (vx_slots){.boot = -1, .previous = -1};
  vx_ndb_reader r = {.src = text, .scratch = scratch, .scratch_cap = cap};
  vx_ndb_record rec;
  vx_ndb_result res;
  while ((res = vx_ndb_next(&r, &rec)) == VX_NDB_RECORD) {
    r.scratch_used = 0;
    vx_str name = vx_ndb_get(&rec, "slot");
    if (name.len == 1 && name.ptr[0] >= 'a' && name.ptr[0] < 'a' + VX_SLOTS) {
      vx_slot *sl = &s->slot[name.ptr[0] - 'a'];
      sl->used = vx_ndb_get_u64(&rec, "release", &sl->release);
      vx_slots_copy(sl->tree, sizeof sl->tree, vx_ndb_get(&rec, "tree"));
      for (int f = 0; f < VX_SLOT_FILES; f++) {
        vx_str h = vx_ndb_get(&rec, VX_SLOT_FILE_KEYS[f]);
        if (h.len != VX_SLOT_HASH) sl->used = false;
        vx_slots_copy(sl->hash[f], sizeof sl->hash[f], h);
      }
      continue;
    }
    vx_str boot = vx_ndb_get(&rec, "boot"), prev = vx_ndb_get(&rec, "previous");
    if (boot.len == 1 && boot.ptr[0] >= 'a' && boot.ptr[0] < 'a' + VX_SLOTS) s->boot = boot.ptr[0] - 'a';
    if (prev.len == 1 && prev.ptr[0] >= 'a' && prev.ptr[0] < 'a' + VX_SLOTS) s->previous = prev.ptr[0] - 'a';
    if (vx_ndb_has(&rec, "cmdline"))
      vx_slots_copy(s->cmdline, sizeof s->cmdline, vx_ndb_get(&rec, "cmdline"));
  }
  if (res != VX_NDB_END || s->boot < 0 || !s->slot[s->boot].used) return VX_ERR_INVALID;
  if (s->previous >= 0 && !s->slot[s->previous].used) s->previous = -1;
  return VX_OK;
}

// The table's text into w.
[[maybe_unused]] static bool vx_slots_print(const vx_slots *s, vx_ndb_writer *w) {
  for (int i = 0; i < VX_SLOTS; i++) {
    const vx_slot *sl = &s->slot[i];
    if (!sl->used) continue;
    char n[2] = {vx_slot_name(i), 0};
    vx_ndb_put(w, "slot", (vx_str){n, 1});
    vx_ndb_put_u64(w, "release", sl->release);
    vx_ndb_put(w, "tree", vx_slots_str(sl->tree));
    for (int f = 0; f < VX_SLOT_FILES; f++) vx_ndb_put(w, VX_SLOT_FILE_KEYS[f], vx_slots_str(sl->hash[f]));
    vx_ndb_end(w);
  }
  char b[2] = {vx_slot_name(s->boot), 0}, p[2] = "-";
  if (s->previous >= 0) p[0] = vx_slot_name(s->previous);
  vx_ndb_put(w, "boot", (vx_str){b, 1});
  vx_ndb_put(w, "previous", (vx_str){p, 1});
  vx_ndb_put(w, "cmdline", vx_slots_str(s->cmdline));
  return vx_ndb_end(w);
}

static void vx_slots_put(char *out, size_t cap, size_t *n, const char *s) {
  for (; *s && *n + 1 < cap; s++) out[(*n)++] = *s;
  out[*n] = 0;
}

// Limine's configuration for the table: its length in out (0 if it does not fit).
[[maybe_unused]] static size_t vx_slots_limine(const vx_slots *s, char *out, size_t cap) {
  size_t n = 0;
  int entry = 0, def = 0;
  for (int i = 0; i < VX_SLOTS; i++) {
    if (!s->slot[i].used) continue;
    entry++;
    if (i == s->boot) def = entry;
  }
  char num[24];
  vx_slots_put(
      out, cap, &n,
      "# Written from \\EFI\\vectra\\slots.ndb (install, distd: M5 step 9). One entry for each slot in use;\n"
      "# each path carries its file's BLAKE2b hash, which Limine checks. The default is the slot that "
      "boots.\n"
      "\ntimeout: 0\ndefault_entry: ");
  num[0] = (char)('0' + def), num[1] = 0;
  vx_slots_put(out, cap, &n, num);
  vx_slots_put(out, cap, &n, "\n");
  for (int i = 0; i < VX_SLOTS; i++) {
    const vx_slot *sl = &s->slot[i];
    if (!sl->used) continue;
    char slot[2] = {vx_slot_name(i), 0};
    vx_slots_put(out, cap, &n, "\n/VectraOS (slot ");
    vx_slots_put(out, cap, &n, slot);
    vx_slots_put(out, cap, &n, ", release ");
    int nd = 0;
    char d[24];
    for (uint64_t v = sl->release; nd == 0 || v; v /= 10) d[nd++] = (char)('0' + v % 10);
    for (int k = 0; k < nd; k++) num[k] = d[nd - 1 - k];
    num[nd] = 0;
    vx_slots_put(out, cap, &n, num);
    vx_slots_put(out, cap, &n, ")\n    protocol: limine\n");
    for (int f = 0; f < VX_SLOT_FILES; f++) {
      vx_slots_put(out, cap, &n,
                   f ? "    module_path: boot():/EFI/vectra/" : "    path: boot():/EFI/vectra/");
      vx_slots_put(out, cap, &n, slot);
      vx_slots_put(out, cap, &n, "/");
      vx_slots_put(out, cap, &n, VX_SLOT_FILE_NAMES[f]);
      vx_slots_put(out, cap, &n, "#");
      vx_slots_put(out, cap, &n, sl->hash[f]);
      vx_slots_put(out, cap, &n, "\n");
    }
    vx_slots_put(out, cap, &n, "    cmdline: vx.system vx.slot=");
    vx_slots_put(out, cap, &n, slot);
    if (s->cmdline[0]) vx_slots_put(out, cap, &n, " "), vx_slots_put(out, cap, &n, s->cmdline);
    vx_slots_put(out, cap, &n, "\n");
  }
  return n + 1 < cap ? n : 0;
}

// The slot a new release goes to: neither the one that boots nor the previous; -1 if none (fewer than 3).
[[maybe_unused]] static int vx_slots_free(const vx_slots *s) {
  for (int i = 0; i < VX_SLOTS; i++)
    if (i != s->boot && i != s->previous) return i;
  return -1;
}
