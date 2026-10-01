# 9Px extensions `posix` and `xattr`

Status: draft, M4 step 4a. Frozen when M4 lands (02 §3.3). Open-file state shared between connections (4b) and byte-range locks are still to come; until then they are not part of either extension.

## The client code that uses them

The musl back end (`ports/musl/vx`), through vx-9p's client (`lib/vx-9p/client.c`):

| POSIX call | Message | Back end |
|---|---|---|
| `stat`, `lstat`, `fstat` | `Tgetattr` (else `Tstat`) | `fd_stat_fid` |
| `chmod`, `fchmod`, `chown`, `truncate`, `ftruncate`, `utimensat`, `futimens` | `Tsetattr` | `fd_setattr` |
| `rename`, `renameat`, `renameat2` (no flags) | `Trenameat` | `fd_renameat` |
| `symlink`, `symlinkat` | `Tsymlink` | `fd_symlinkat` |
| `readlink`, `readlinkat`, and following links in every path | `Treadlink` | `fd_readlinkat`, `fd_resolve` |
| `fsync`, `fdatasync` | `Tfsync` | `fd_fsync` |

A connection asks for both in `Tversion` (`9P2000.x/1 +posix +xattr`); a server answers with what it has. `tmpfs` has both; `bootfs` and `nullfs` have `xattr`, so `stat` is `Tgetattr` everywhere.

## Messages

Each is 9P2000.L's, unchanged on the wire, and answered only once its extension is negotiated; before that, and from a server without the operation, it is an `Rerror`. Errors are 9P2000's `Rerror` strings, not 9P2000.L's `Rlerror` numbers: a 9Px session is one dialect.

| Message | Extension | Fields |
|---|---|---|
| `Tgetattr` 24 / `Rgetattr` 25 | xattr | `fid[4] request_mask[8]` / `valid[8] qid[13] mode[4] uid[4] gid[4] nlink[8] rdev[8] size[8] blksize[8] blocks[8] atime_sec[8] atime_nsec[8] mtime_sec[8] mtime_nsec[8] ctime_sec[8] ctime_nsec[8] btime_sec[8] btime_nsec[8] gen[8] data_version[8]` |
| `Tsetattr` 26 / `Rsetattr` 27 | xattr | `fid[4] valid[4] mode[4] uid[4] gid[4] size[8] atime_sec[8] atime_nsec[8] mtime_sec[8] mtime_nsec[8]` / — |
| `Trenameat` 74 / `Rrenameat` 75 | posix | `olddirfid[4] oldname[s] newdirfid[4] newname[s]` / — |
| `Tsymlink` 16 / `Rsymlink` 17 | posix | `fid[4] name[s] symtgt[s] gid[4]` / `qid[13]` |
| `Treadlink` 22 / `Rreadlink` 23 | posix | `fid[4]` / `target[s]` |
| `Tfsync` 50 / `Rfsync` 51 | posix | `fid[4] datasync[4]` / — |
| `Tlink` 70 / `Rlink` 71 | posix | `dfid[4] fid[4] name[s]` / —; no server has hard links yet, and every one refuses it |

`Rgetattr`'s `mode` is POSIX's (`S_IFDIR`, `S_IFREG`, `S_IFLNK` and the permissions); `valid` is `P9_GETATTR_BASIC` (0x7ff) from a server that knows no more. `Tsetattr`'s `valid` bits are Linux's: `ATIME` and `MTIME` without `ATIME_SET` and `MTIME_SET` mean now.

## Semantics

- **Rename** replaces what is at the new name as POSIX's `rename` does: a file by a file, a directory by an empty directory. Moving a directory into itself is refused. Both directories are on one connection: across servers the client reports `EXDEV`.
- **Symbolic links** are made and read by the server and **followed by the client**, as a 9P server walks names only. A link is no directory, so a `Twalk` through one fails; the client then looks for a link among the path's prefixes, expands it, and walks again, at most 40 times (`ELOOP`). In `Tstat`, a link's mode has 9P2000.u's `DMSYMLINK` (0x02000000).
- **Tfsync** is answered when the file's writes are where the server keeps them; every server so far writes before `Rwrite`, so it has nothing to wait for.
