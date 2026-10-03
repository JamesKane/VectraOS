// memory.c: mmap and its relatives, over VMOs. Part of backend.c.
//
// An anonymous mapping is a VMO of its own, mapped where the kernel picks or
// at a fixed address. A file's mapping, on a server with 9Px's map extension
// (fsd), is the VMO Tmap gives (docs/proto/map.md): its page cache, which
// every process mapping the file shares, so MAP_SHARED writes reach the file
// and the others, and a read-only MAP_PRIVATE costs no copy. A private
// mapping that may be written, or one from a server without the extension,
// is the file's bytes read into a VMO of its own. Shared mappings of other
// servers' files are refused. Changing permissions waits for as_protect
// (docs/milestones.md).

// A file's pages as its server's VMO (Tmap), mapped. PROT_NONE is mapped
// read-only: what it reserves stays reserved. Past the file's last page
// there is no VMO to map: those pages are left unmapped, so a touch there
// faults (SIGSEGV, where POSIX says SIGBUS).
static long mem_map_file(const ofd *o, uint64_t size, int prot, int flags, long offset, long addr) {
  uint32_t p9prot =
      P9_PROT_READ | (prot & PROT_WRITE ? P9_PROT_WRITE : 0) | (prot & PROT_EXEC ? P9_PROT_EXEC : 0);
  vx_handle vmo;
  uint64_t from, avail;
  vx_status st = p9c_map(o->f.c, o->f.fid, (uint64_t)offset, size, p9prot, &vmo, &from, &avail);
  if (st != VX_OK) return vx_errno(st);
  uint32_t vflags = (prot & PROT_WRITE ? VX_MAP_WRITE : 0) | (prot & PROT_EXEC ? VX_MAP_EXEC : 0);
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
  // Anonymous shared mappings wait for shared VMOs across fork: refused,
  // rather than made private where a program counts on another process
  // seeing its writes.
  bool shared = (flags & MAP_TYPE) == MAP_SHARED || (flags & MAP_TYPE) == MAP_SHARED_VALIDATE;
  if ((flags & MAP_TYPE) != MAP_PRIVATE && !shared) return -EINVAL;
  if (shared && anon) return -EINVAL;
  const ofd *o = anon ? nullptr : fd_get(fd);
  if (!anon && (!o || o->kind != OFD_FILE || o->dir)) return o ? -EACCES : -EBADF;
  bool mappable = !anon && (o->f.c->extensions & P9_EXT_MAP);
  if (shared && !mappable) return -ENODEV;
  if (mappable && (shared || !(prot & ~(PROT_READ | PROT_EXEC)))) {
    if ((o->flags & O_ACCMODE) == O_WRONLY) return -EACCES;
    if (shared && (prot & PROT_WRITE) && (o->flags & O_ACCMODE) != O_RDWR) return -EACCES;
    return mem_map_file(o, size, prot, flags, offset, addr);
  }

  // Until as_protect, PROT_NONE is mapped read-write: what it reserves stays
  // reserved, but a guard page does not fault. That is what musl's malloc
  // expects where mprotect is missing: it reserves with PROT_NONE, and takes
  // mprotect's ENOSYS to mean the pages are usable as they are.
  uint32_t vflags =
      (prot & PROT_WRITE || prot == PROT_NONE ? VX_MAP_WRITE : 0) | (prot & PROT_EXEC ? VX_MAP_EXEC : 0);
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

// realloc's large blocks, which are musl's own anonymous mappings: moved to a
// new mapping and copied. Without MREMAP_MAYMOVE, only shrinking can be done.
static long mem_remap(long addr, size_t old_len, size_t new_len, int flags) {
  if ((addr & 4095) || !new_len || (flags & ~MREMAP_MAYMOVE)) return -EINVAL; // MREMAP_FIXED: not yet
  uint64_t old_size, new_size;
  if (ckd_add(&old_size, (uint64_t)old_len, 4095) || ckd_add(&new_size, (uint64_t)new_len, 4095))
    return -ENOMEM;
  old_size &= ~(uint64_t)4095, new_size &= ~(uint64_t)4095;
  if (new_size <= old_size) {
    if (new_size < old_size) vx_as_unmap(vx_self, (uint64_t)addr + new_size, old_size - new_size);
    return addr;
  }
  if (!(flags & MREMAP_MAYMOVE)) return -ENOMEM;
  long to = mem_map(0, new_len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  if (to < 0) return to;
  memcpy((void *)to, (const void *)addr, old_len);
  vx_as_unmap(vx_self, (uint64_t)addr, old_size);
  return to;
}

static long mem_unmap(long addr, size_t len) {
  if ((addr & 4095) || !len) return -EINVAL;
  uint64_t size; // the pages it touches, as Linux takes it
  if (ckd_add(&size, (uint64_t)len, 4095)) return -EINVAL;
  return vx_errno(vx_as_unmap(vx_self, (uint64_t)addr, size & ~(uint64_t)4095));
}

// Until as_protect: nothing changes, and saying so is the answer musl's malloc
// expects (see mem_map). Asking for read-write after PROT_NONE gets what it
// asked for anyway.
static long mem_protect(int prot) {
  (void)prot;
  return -ENOSYS;
}
