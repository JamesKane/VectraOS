# 9Px extension `map`

Status: draft, M5 step 5c. Frozen when M5 lands (02 §3.3).

A file's range as a VMO, which the client maps: `mmap` of files (01 §5, docs/11 §8). A connection asks for it in `Tversion` (`9P2000.x/1 +map`); `fsd`, started as a pager, has it, and no other server yet.

## The client code that uses it

The musl back end (`ports/musl/vx/memory.c`), through vx-9p's client (`p9c_map`):

| POSIX call | Message | Back end |
|---|---|---|
| `mmap` of a file, `MAP_SHARED` | `Tmap` | `mem_map_file` |
| `mmap` of a file, `MAP_PRIVATE` and not writable | `Tmap` (no copy) | `mem_map_file` |
| `mmap` of a file, `MAP_PRIVATE` and writable, or on a server without `map` | `Tread` into a VMO of its own | `mem_map` |

## Messages

| Message | Fields |
|---|---|
| `Tmap` 158 / `Rmap` 159 | `fid[4] offset[8] length[8] prot[4]` / `offset[8] length[8]` |

- **`prot`** is read 1, write 2, exec 4. Write and exec together are refused (01 §11).
- **The fid** must be open, and not a directory. A mapping needs it open for reading (`OREAD`, `ORDWR` or `OEXEC`); a writable one needs `ORDWR`, as POSIX's `mmap` asks of a descriptor.
- **The VMO** comes back beside the reply, not in it: on the ring transport, in one of the ring's handle slots (`ring_xfer_handles`), which the completion names (`P9_CQE_HANDLE` in its flags, the slot in `aux`; lib/vx-9p/ring.c). Its rights are what `prot` asks for and no more: `READ` and `MAP`, with `WRITE` or `EXEC` as asked.
- **`Rmap`'s offset** is where in the VMO the file's `offset` is, and its length how many bytes the VMO has from there, which is less than asked for past the file's last page. The client maps that much, and leaves the rest of its range unmapped.

## Semantics

- **One VMO per file.** `fsd` answers every `Tmap` of a file, from any connection and any user, with the same pager-backed VMO, the file's page cache (docs/11 §8). Its size is the file's, in whole pages (one at least), and follows the file's: only the pager resizes it (`pager_op RESIZE`), never a client, so no one can shrink it under the others or grow it with pages of zeros.
- **Coherence.** Writes through mappings reach the file: `fsd` writes them back before each commit, before a `Tread` of the file, and before its size changes. A `Twrite` goes to the VMO's pages as well as to the volume. Every mapping and every reader sees one file.
- **Past the end.** Past the file's last page there is nothing mapped, so a touch faults (`SIGSEGV`, where POSIX says `SIGBUS`). In the last page, bytes past the end read as zeros, and what is written there is not kept.
- **A removed file** stays while it is mapped: the VMO keeps it open, as a mapping keeps a removed file's data in POSIX.
- **Trust.** Only a task `svcd` made a pager (its manifest's `pager`) can make pager-backed VMOs, and every page it is asked for comes before a deadline or the faulting thread takes `PAGER_TIMEOUT` (`SIGBUS`) (01 §5). A server that is not a pager can only answer with an anonymous VMO, which a client could not tell from a copy; 02 §3.3's private copy for remote servers comes with the network transport.
