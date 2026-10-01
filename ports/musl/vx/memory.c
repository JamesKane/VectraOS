// memory.c: mmap and its relatives, over VMOs. Part of backend.c.
//
// An anonymous mapping is a VMO of its own, mapped where the kernel picks or
// at a fixed address. A private mapping of a file is its bytes read into one:
// what MAP_PRIVATE promises a reader, without a pager. Shared file mappings
// come with 9Px's Tmap (02 §3), as does the change of permissions that
// as_protect will give (docs/milestones.md).

static long mem_map(long addr, size_t len, int prot, int flags, int fd, long offset) {
  if (!len || (addr & 4095) || (offset & 4095)) return -EINVAL;
  uint64_t size;
  if (ckd_add(&size, (uint64_t)len, 4095)) return -ENOMEM;
  size &= ~(uint64_t)4095;
  if ((prot & PROT_WRITE) && (prot & PROT_EXEC)) return -EACCES; // W^X (01 §11)
  bool anon = flags & MAP_ANONYMOUS;
  if (!anon && (flags & MAP_TYPE) != MAP_PRIVATE) return -ENODEV;
  const ofd *o = anon ? nullptr : fd_get(fd);
  if (!anon && (!o || o->kind != OFD_FILE || o->dir)) return o ? -EACCES : -EBADF;

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
  if ((addr & 4095) || !new_len) return -EINVAL;
  uint64_t old_size = ((uint64_t)old_len + 4095) & ~(uint64_t)4095;
  uint64_t new_size = ((uint64_t)new_len + 4095) & ~(uint64_t)4095;
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
  return vx_errno(vx_as_unmap(vx_self, (uint64_t)addr, len));
}

// Until as_protect: nothing changes, and saying so is the answer musl's malloc
// expects (see mem_map). Asking for read-write after PROT_NONE gets what it
// asked for anyway.
static long mem_protect(int prot) {
  (void)prot;
  return -ENOSYS;
}
