# 9Px extensions `posix` and `xattr`

Status: draft, M4 steps 4a and 4b. Frozen when M4 lands (02 §3.3).

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
| `read`, `write` on a file, at its offset | `Tread`, `Twrite` at `P9_OFFSET_CURRENT` | `fd_read`, `file_write` |
| `lseek` | `Tseek` | `fd_lseek` |
| `O_APPEND`, `fcntl(F_SETFL)` | `Tdesc` | `fd_openat`, `fd_fcntl` |
| a child's descriptors: `fork`, `posix_spawn`, `execve` | `Tshare`, then `Tjoin` in the child | `fd_before_fork`, `fd_records`, `file_join` |
| `fcntl(F_GETLK, F_SETLK, F_SETLKW)` | `Tgetlock`, `Tlock` | `fd_lock` |

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
| `Tlock` 52 / `Rlock` 53 | posix | `fid[4] type[1] flags[4] start[8] length[8] proc_id[4] client_id[s]` / `status[1]` |
| `Tgetlock` 54 / `Rgetlock` 55 | posix | `fid[4] type[1] start[8] length[8] proc_id[4] client_id[s]` / the same, without `fid` |
| `Tshare` 150 / `Rshare` 151 | posix (9Px's own) | `fid[4] holds[4]` / `token[16]` |
| `Tjoin` 152 / `Rjoin` 153 | posix (9Px's own) | `newfid[4] token[16]` / `qid[13] iounit[4]` |
| `Tseek` 154 / `Rseek` 155 | posix (9Px's own) | `fid[4] offset[8] whence[1]` / `offset[8]` |
| `Tdesc` 156 / `Rdesc` 157 | posix (9Px's own) | `fid[4] flags[4]` (1: append) / — |

`Rgetattr`'s `mode` is POSIX's (`S_IFDIR`, `S_IFREG`, `S_IFLNK` and the permissions); `valid` is `P9_GETATTR_BASIC` (0x7ff) from a server that knows no more. `Tsetattr`'s `valid` bits are Linux's: `ATIME` and `MTIME` without `ATIME_SET` and `MTIME_SET` mean now.

## Semantics

- **Rename** replaces what is at the new name as POSIX's `rename` does: a file by a file, a directory by an empty directory. Moving a directory into itself is refused. Both directories are on one connection: across servers the client reports `EXDEV`.
- **Symbolic links** are made and read by the server and **followed by the client**, as a 9P server walks names only. A link is no directory, so a `Twalk` through one fails; the client then looks for a link among the path's prefixes, expands it, and walks again, at most 40 times (`ELOOP`). In `Tstat`, a link's mode has 9P2000.u's `DMSYMLINK` (0x02000000).
- **Tfsync** is answered when the file's writes are where the server keeps them. `tmpfs` and the others write before `Rwrite`, so they have nothing to wait for. `fsd` commits, and answers once the commit is durable (docs/11 §6).
- **Open files.** With posix, a server keeps an open file for each fid it opens that is not a directory: the node, the mode, an offset and whether writes append. `Tread` and `Twrite` at offset `P9_OFFSET_CURRENT` (all ones) use that offset and move it on; at any other offset they do as 9P2000 does and leave it alone. A write at the current offset of a file that appends goes to its end, at once: a server answers one request at a time. `Topen`'s mode bit 0x80 (`P9_OAPPEND`) makes the open file append from the start; `Tdesc` sets or clears it later; `Tseek` moves the offset (whence: set 0, current 1, end 2) and answers where it is.
- **Sharing one.** `Tshare` gives a 16-byte token for a fid's open file, good for `holds` joins (at most 64 at once). `Tjoin`, on any of the server's connections, makes `newfid` a fid open on that same open file: its offset, its appending, its mode. Holds are good for 10 seconds from the last `Tshare` on the file, or from its last fid's going, whichever is later: they keep the open file for their joins that long after its last fid has gone, so a child can join after its parent has closed it or exited, as an `exec` does at once; holds never used then run out, open file or not, so a client that gave out tokens no child took cannot fill the file's 64. A join opens the file again at the server as a join (the open file may have been removed since: a joined fid still reaches it), not as a new open. Tokens come from the server's random generator (lib/vx-rand), seeded with the entropy its spawn message gives it; a server without one refuses `Tshare`, since a token anyone could guess would let a connection reach an open file it could not open. Tokens are compared whole, in constant time.
- **Locks** are POSIX's byte-range locks, kept by the server: `Tlock` takes or lets go of a read or write lock over `[start, start + length)` (`length` 0: to the end), owned by the connection and `proc_id`, replacing what that owner held of the range; it answers `BLOCKED` when another owner's lock is in the way, and the client asks again (`F_SETLKW`, every 10 ms), and `ERROR` when the server has no room for it, having changed nothing. A read lock needs a fid open for reading and a write lock one open for writing, as POSIX has it (an error otherwise). `Tgetlock` names the first lock in the way, or answers with type unlock. A connection's locks on a file go when it lets go of any open fid on it, as a POSIX process's go when it closes a descriptor of the file; the back end lets go of its fid when the open file's last descriptor in the process closes, and unlocks the whole file (`Tlock` unlock, 0 to the end) when another of its descriptors closes.
