// memory.c: mmap and its relatives, over VMOs. Part of backend.c.
//
// An anonymous mapping is a VMO of its own, mapped where the kernel picks or
// at a fixed address. A file's mapping, on a server with 9Px's map extension
// (fsd), is the VMO Tmap gives (docs/proto/map.md): its page cache, which
// every process mapping the file shares, so MAP_SHARED writes reach the file
// and the others, and a read-only MAP_PRIVATE costs no copy. A private
// mapping that may be written, or one from a server without the extension,
// is the file's bytes read into a VMO of its own. Shared mappings of other
// servers' files are refused. A MAP_SHARED anonymous mapping is mapped
// VX_MAP_SHARED, so a forked child maps the same VMO; PROT_NONE is
// VX_MAP_NOACCESS, and mprotect is as_protect (ADR-0042, M6 step 6e1a2).

// The kernel's flags for prot: PROT_NONE is no access at all; W^X holds.
static uint32_t mem_vflags(int prot) {
  if (prot == PROT_NONE) return VX_MAP_NOACCESS;
  return (prot & PROT_WRITE ? VX_MAP_WRITE : 0) | (prot & PROT_EXEC ? VX_MAP_EXEC : 0);
}

// A file's pages as its server's VMO (Tmap), mapped. Past the file's last
// page there is no VMO to map: those pages are left unmapped, so a touch
// there faults (SIGSEGV, where POSIX says SIGBUS).
static long mem_map_file(const ofd *o, uint64_t size, int prot, int flags, long offset, long addr) {
  uint32_t p9prot =
      P9_PROT_READ | (prot & PROT_WRITE ? P9_PROT_WRITE : 0) | (prot & PROT_EXEC ? P9_PROT_EXEC : 0);
  vx_handle vmo;
  uint64_t from, avail;
  vx_status st = p9c_map(o->f.c, o->f.fid, (uint64_t)offset, size, p9prot, &vmo, &from, &avail);
  if (st != VX_OK) return vx_errno(st);
  bool shared = (flags & MAP_TYPE) != MAP_PRIVATE; // kept across fork as it is (a pager's VMO is anyway)
  uint32_t vflags = mem_vflags(prot) | (shared ? VX_MAP_SHARED : 0);
  uint64_t at = (flags & (MAP_FIXED | MAP_FIXED_NOREPLACE)) ? (uint64_t)addr : 0;
  if (flags & MAP_FIXED) vx_as_unmap(vx_self, at, size);
  st = vx_as_map(vx_self, vmo, from, avail < size ? avail : size, vflags, &at);
  vx_handle_close(vmo); // the mapping keeps it
  if (st == VX_ERR_EXISTS && (flags & MAP_FIXED_NOREPLACE)) return -EEXIST;
  if (st != VX_OK) return vx_errno(st);
  return (long)at;
}

static long mem_map(long addr, size_t len, int prot, int flags, int fd, long offset) {
  if (!len || (addr & 4095) || (offset & 4095) || offset < 0) return -EINVAL;
  uint64_t size;
  if (ckd_add(&size, (uint64_t)len, 4095)) return -ENOMEM;
  size &= ~(uint64_t)4095;
  if ((prot & PROT_WRITE) && (prot & PROT_EXEC)) return -EACCES; // W^X (01 §11)
  bool anon = flags & MAP_ANONYMOUS;
  bool shared = (flags & MAP_TYPE) == MAP_SHARED || (flags & MAP_TYPE) == MAP_SHARED_VALIDATE;
  if ((flags & MAP_TYPE) != MAP_PRIVATE && !shared) return -EINVAL;
  const ofd *o = anon ? nullptr : fd_get(fd);
  if (!anon && (!o || o->kind != OFD_FILE || o->dir)) return o ? -EACCES : -EBADF;
  bool mappable = !anon && (o->f.c->extensions & P9_EXT_MAP);
  if (shared && !anon && !mappable) return -ENODEV; // a file on a server that cannot share its pages
  if (mappable && (shared || !(prot & ~(PROT_READ | PROT_EXEC)))) {
    if ((o->flags & O_ACCMODE) == O_WRONLY) return -EACCES;
    if (shared && (prot & PROT_WRITE) && (o->flags & O_ACCMODE) != O_RDWR) return -EACCES;
    return mem_map_file(o, size, prot, flags, offset, addr);
  }

  uint32_t vflags = mem_vflags(prot) | (shared ? VX_MAP_SHARED : 0); // shared: anonymous, kept across fork
  uint64_t at = (flags & (MAP_FIXED | MAP_FIXED_NOREPLACE)) ? (uint64_t)addr : 0;
  if (flags & MAP_FIXED) vx_as_unmap(vx_self, at, size); // Linux's MAP_FIXED replaces what is there
  vx_handle vmo;
  vx_status st = vx_vmo_create(size, 0, &vmo);
  if (st != VX_OK) return -ENOMEM;
  // A file's bytes go in first, through a writable mapping of the VMO's own.
  if (!anon) {
    uint64_t fill = 0;
    st = vx_as_map(vx_self, vmo, 0, size, VX_MAP_WRITE, &fill);
    for (uint64_t done = 0; st == VX_OK && done < len;) {
      uint32_t k = len - done < (1u << 20) ? (uint32_t)(len - done) : 1u << 20;
      int64_t r = p9c_read(o->f.c, o->f.fid, (uint64_t)offset + done, (void *)(fill + done), k);
      if (r < 0) st = (vx_status)r;
      if (r <= 0) break; // the file ends here: the rest stays zero, as POSIX has it
      done += (uint64_t)r;
    }
    if (fill) vx_as_unmap(vx_self, fill, size);
  }
  if (st == VX_OK) st = vx_as_map(vx_self, vmo, 0, size, vflags, &at);
  vx_handle_close(vmo); // the mapping keeps it
  if (st == VX_ERR_EXISTS && (flags & MAP_FIXED_NOREPLACE)) return -EEXIST;
  if (st != VX_OK) return vx_errno(st);
  return (long)at;
}

// mremap, of a private mapping (realloc's large blocks, which are musl's own
// anonymous mappings): shrunk in place; grown in place, with a VMO of its
// own after it, where the pages after it are free; else, with
// MREMAP_MAYMOVE, moved to a new mapping (at new_addr with MREMAP_FIXED)
// and copied. A shared mapping cannot be grown or moved: a copy would not be
// shared, and the VMO's handle is gone (EINVAL).
static long mem_remap(long addr, size_t old_len, size_t new_len, int flags, long new_addr) {
  if ((addr & 4095) || !new_len || (flags & ~(MREMAP_MAYMOVE | MREMAP_FIXED))) return -EINVAL;
  if ((flags & MREMAP_FIXED) && (!(flags & MREMAP_MAYMOVE) || (new_addr & 4095))) return -EINVAL;
  uint64_t old_size, new_size;
  if (ckd_add(&old_size, (uint64_t)old_len, 4095) || ckd_add(&new_size, (uint64_t)new_len, 4095))
    return -ENOMEM;
  old_size &= ~(uint64_t)4095, new_size &= ~(uint64_t)4095;
  if (new_size <= old_size && !(flags & MREMAP_FIXED)) {
    if (new_size < old_size) vx_as_unmap(vx_self, (uint64_t)addr + new_size, old_size - new_size);
    return addr;
  }
  vx_map_info mi;
  if (vx_as_query(vx_self, (uint64_t)addr, &mi) != VX_OK || mi.base > (uint64_t)addr) return -EFAULT;
  if (mi.flags & VX_MAP_SHARED) return -EINVAL;
  if ((flags & MREMAP_FIXED) && (uint64_t)new_addr < (uint64_t)addr + old_size &&
      (uint64_t)addr < (uint64_t)new_addr + new_size)
    return -EINVAL; // the new place overlaps the old, as Linux refuses
  int prot = mi.flags & VX_MAP_NOACCESS ? PROT_NONE : PROT_READ | (mi.flags & VX_MAP_WRITE ? PROT_WRITE : 0);
  // Grown in place only while it is one mapping: a second growth moves it
  // into one again, so a buffer grown step by step never takes more than
  // two of the task's mappings (the review of 2026-10-07).
  bool single = mi.base == (uint64_t)addr && mi.size == old_size;
  if (!(flags & MREMAP_FIXED) && single) { // the pages after it, if they are free
    long more = mem_map(addr + (long)old_size, new_size - old_size, prot,
                        MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED_NOREPLACE, -1, 0);
    if (more >= 0) return addr;
  }
  if (!(flags & MREMAP_MAYMOVE)) return -ENOMEM;
  int at_flags = MAP_PRIVATE | MAP_ANONYMOUS | (flags & MREMAP_FIXED ? MAP_FIXED : 0);
  long to = mem_map(flags & MREMAP_FIXED ? new_addr : 0, new_len, PROT_READ | PROT_WRITE, at_flags, -1, 0);
  if (to < 0) return to;
  if (prot == PROT_NONE) vx_as_protect(vx_self, (uint64_t)addr, old_size, 0); // readable, to copy
  memcpy((void *)to, (const void *)addr, old_size < new_size ? old_size : new_size);
  if (prot != (PROT_READ | PROT_WRITE)) vx_as_protect(vx_self, (uint64_t)to, new_size, mem_vflags(prot));
  vx_as_unmap(vx_self, (uint64_t)addr, old_size);
  return to;
}

static long mem_unmap(long addr, size_t len) {
  if ((addr & 4095) || !len) return -EINVAL;
  uint64_t size; // the pages it touches, as Linux takes it
  if (ckd_add(&size, (uint64_t)len, 4095)) return -EINVAL;
  return vx_errno(vx_as_unmap(vx_self, (uint64_t)addr, size & ~(uint64_t)4095));
}

// mprotect: as_protect, each mapping in the range within the rights its VMO's
// handle gave (a file opened read-only stays so: EACCES); a hole is ENOMEM.
static long mem_protect(long addr, size_t len, int prot) {
  if ((addr & 4095) || (prot & ~(PROT_READ | PROT_WRITE | PROT_EXEC))) return -EINVAL;
  if ((prot & PROT_WRITE) && (prot & PROT_EXEC)) return -EACCES; // W^X (01 §11)
  uint64_t size;
  if (ckd_add(&size, (uint64_t)len, 4095)) return -ENOMEM;
  size &= ~(uint64_t)4095;
  if (!size) return 0;
  vx_status st = vx_as_protect(vx_self, (uint64_t)addr, size, mem_vflags(prot));
  if (st == VX_ERR_NOT_FOUND || st == VX_ERR_RANGE) return -ENOMEM;
  return vx_errno(st);
}
