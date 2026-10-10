// vx/file.h: files (09 §5.5; ADR-0004 libvx v0). Plan 9's file calls, on a
// vx_fd: an index and a generation into the process's table of open files,
// so a closed one's number finds nothing. Paths are the process's namespace;
// symbolic links are followed (vx_lstat and vx_readlink look at one itself).
// A call that cannot gives a negative vx_status, and the detail in vx_errstr.

#pragma once

#include "api.h"

typedef struct vx_arena vx_arena;

// A file: >= 0, or a negative vx_status from the call that should have
// made it. 0, 1 and 2 are standard input, output and error.
typedef int32_t vx_fd;
enum : vx_fd { VX_STDIN = 0, VX_STDOUT = 1, VX_STDERR = 2 };

// How a file is opened: 9P's modes, and two of the system's own.
typedef uint32_t vx_mode;
enum : vx_mode {
  VX_OREAD = 0,
  VX_OWRITE = 1,
  VX_ORDWR = 2,
  VX_OEXEC = 3,
  VX_OTRUNC = 0x10,   // emptied first
  VX_ORCLOSE = 0x40,  // removed when closed
  VX_OAPPEND = 0x100, // each write at the end, whatever the offset
  VX_OEXCL = 0x1000,  // vx_create: fail with VX_ERR_EXISTS if it is there
};

// A file's mode bits beside its permissions: 9P's.
enum : uint32_t {
  VX_DMDIR = 0x8000'0000,
  VX_DMAPPEND = 0x4000'0000,
  VX_DMEXCL = 0x2000'0000,
  VX_DMSYMLINK = 0x0200'0000,
  VX_DMDEVICE = 0x0080'0000,
};

// Which file: the server's path for it, and its version, which a change
// moves on. Two names are one file when their dev and qid.path agree.
typedef struct vx_qid {
  uint64_t path;
  uint32_t vers;
  uint8_t type;
} vx_qid;

// What a file is. The strings are in the arena the call was given. For
// vx_wstat, vx_dir_keep's values change nothing: set only what is to change.
typedef struct vx_dir {
  vx_str name, uid, gid, muid;
  vx_qid qid;
  uint64_t dev;            // its server's connection in this process
  uint32_t mode;           // permissions and VX_DM bits
  uint64_t length;         // in bytes
  vx_instant atime, mtime; // UTC, nanoseconds since 1970 (seconds where the server keeps no more)
} vx_dir;

VX_API vx_dir vx_dir_keep(void);

VX_API vx_fd vx_open(vx_str path, vx_mode mode);
// A new file (a directory with VX_DMDIR in perm), open in mode; a file that
// is there already is emptied and opened, as Plan 9's create does, unless
// mode has VX_OEXCL.
VX_API vx_fd vx_create(vx_str path, vx_mode mode, uint32_t perm);
VX_API vx_status vx_close(vx_fd fd);

// At the file's offset, which moves on: how many bytes, 0 at the end of a
// read, or a negative vx_status. One request: fewer than asked for is not an
// error.
VX_API int64_t vx_read(vx_fd fd, vx_bytes buf);
VX_API int64_t vx_write(vx_fd fd, vx_str data);
// At off, the file's offset unmoved.
VX_API int64_t vx_pread(vx_fd fd, vx_bytes buf, uint64_t off);
VX_API int64_t vx_pwrite(vx_fd fd, vx_str data, uint64_t off);
enum : uint32_t { VX_SEEK_SET = 0, VX_SEEK_CUR = 1, VX_SEEK_END = 2 };
// The file's offset moved (from its start, from where it is, from its end):
// the new offset, or a negative vx_status.
VX_API int64_t vx_seek(vx_fd fd, int64_t off, uint32_t whence);

VX_API vx_status vx_stat(vx_str path, vx_arena *a, vx_dir *out);
VX_API vx_status vx_lstat(vx_str path, vx_arena *a, vx_dir *out); // a link itself
VX_API vx_status vx_fstat(vx_fd fd, vx_arena *a, vx_dir *out);
VX_API vx_status vx_wstat(vx_str path, const vx_dir *d);
// A directory's entries from where its reading is, all of them, into a
// array in a: how many, or a negative vx_status.
VX_API int64_t vx_dirread(vx_fd fd, vx_arena *a, vx_dir **out);

VX_API vx_status vx_remove(vx_str path);
// from becomes to, what was at to replaced; across directories of one
// server, VX_ERR_UNSUPPORTED across servers.
VX_API vx_status vx_rename(vx_str from, vx_str to);
// A symbolic link at path to target; vx_readlink's into a. There are no
// hard links.
VX_API vx_status vx_symlink(vx_str target, vx_str path);
VX_API vx_status vx_readlink(vx_str path, vx_arena *a, vx_str *target);
// What was written to fd reaches stable storage before it returns.
VX_API vx_status vx_sync(vx_fd fd);

// len bytes of the file from off (a page multiple), its server's own pages
// (01 §5), shared: what is written to them is the file's. prot is
// VX_MAP_WRITE or VX_MAP_EXEC (never both) or 0 for read only. vx_unmap
// lets go of them.
VX_API vx_status vx_map(vx_fd fd, uint64_t off, size_t len, uint32_t prot, void **addr);
VX_API vx_status vx_unmap(void *addr, size_t len);

// The same requests through a loop (F-217): vx_io_submit takes n of them,
// all or none (VX_ERR_SHOULD_WAIT when the loop has no room for them all),
// and each completes as a VX_EV_IO with its key and its count, bytes or a
// negative vx_status. buf is the caller's until then. The flags are cache
// hints for the server, not yet carried (a later level, 9Px hint).
typedef struct vx_loop vx_loop;
typedef enum vx_io_op : uint32_t { VX_IO_READ = 1, VX_IO_WRITE, VX_IO_SYNC } vx_io_op;
enum : uint32_t { VX_IO_UNCACHED = 1, VX_IO_ONCE = 2, VX_IO_PREFETCH = 4 };
typedef struct vx_io {
  vx_fd fd;
  uint32_t op; // vx_io_op
  uint32_t flags;
  uint64_t off; // where: a request is positioned, as vx_pread is
  vx_bytes buf; // read into, or written from
  uint64_t key;
} vx_io;

VX_API vx_status vx_io_submit(vx_loop *l, const vx_io *ops, size_t n);
// VX_EV_CHANGED with key on l when the file, or a directory's entries,
// change (9Px notify), until l is freed; for VX_STDIN, one VX_EV_READY when
// there is input to read (watch again after reading).
VX_API vx_status vx_watch(vx_loop *l, vx_fd fd, uint64_t key);

// One ctl message to the file at path, formatted, in one write.
[[gnu::format(printf, 2, 3)]] VX_API vx_status vx_ctl(vx_str path, const char *fmt, ...);

#if VX_TARGET_ABI >= 2
// Level 2 (ADR-0056). A file whose server answers an open with a channel
// (9Px's srv extension, 02 §3.3: a window from /wsys/new, a posted service):
// its channel in *channel. The file is closed once the channel is had.
VX_API vx_status vx_open_post(vx_str path, vx_handle *channel);
#endif
