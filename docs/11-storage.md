# Phase 11 — Storage: `fsd` and its file system

_Blueprint v0, 2026-10-02. Built in M5 (§13). The format is our own, after 9front's gefs (ADR-0025). It fixes the intended shape and is rewritten against the code each piece produces._

## 1. The position

**The system volume needs a file system that keeps its promises.** The rest of the blueprint already leans on one:
- 06 snapshots `/cfg` and `/home` before every update, rolls `/cfg` back, and shows dated read-only trees as Plan 9's dump did (06 §10).
- `auditfs` undoes an agent's session with one click (03 §8.5).
- `fsd` is the trusted pager behind `mmap` and the page cache (01 §5).
- 00 §8 has budgets for cached and uncached reads and for large directories.

None of that works on FAT32, and none of it should be bolted onto a file system that was not built for it.

**gefs shows the shape.** Ori Bernstein's gefs, in 9front, is a crash-safe, corruption-detecting, snapshotting file system in under 9,000 lines, serving 9P from user space, which is what `fsd` is. It does this with one idea: the whole file system is a key-value store in a forest of copy-on-write Bε trees, and everything else falls out of that. Its paper (9front's `/sys/doc/gefs.ms`) is the source for most of this document.

**The format is ours, not gefs's.** gefs is Plan 9 C, its disk format is still changing, and its author calls it unready for data people care about. VectraOS needs what gefs leaves out: POSIX attributes, symbolic links, files removed while open, a pager, and a single-threaded server until M6 brings threads. So `fsd` reimplements gefs's design in C23, as `lib/vx-rc` reimplemented rc's, crediting it, and its disks are not gefs disks (ADR-0025). What the two systems share across the wire is 9P, not a block format.

**FAT32 stays where the outside world needs it.** The EFI system partition, USB sticks and SD cards are FAT; install media are ISO 9660. Small servers read and write those (§11); none of them is the system volume.

## 2. Goals

In order, as gefs ranks them:
1. **Crash safe.** A power cut loses at most the last few seconds of writes, never the file system. There is no `fsck` repair step, because there is nothing to repair.
2. **Corruption detecting.** Every block is checked against a hash its parent holds. A bad sector or a bug that writes garbage is reported, never returned as data.
3. **Simple.** One data structure, one commit protocol, no soft-update ordering rules.
4. **Snapshots are cheap,** so updates, undo and the dump use them freely.
5. **Fast enough** for 00 §8's budgets.

Non-goals for M5: RAID or several devices, compression, encryption, deduplication, quotas, hard links, and growing a mounted volume. The format leaves room for the first three (§12).

## 3. The data structure: Bε trees

A Bε tree is a B+ tree whose pivot nodes also hold a write buffer:
- **Upserts.** A change is a message addressed to a key: insert, delete, or a modification such as "add 1 to the version, set mtime". It goes into the root's buffer.
- **Flushes.** When the root's buffer is full, the messages bound for the child with the most of them are pushed down into it, recursively, until they reach a leaf and are applied.
- **Reads.** A lookup walks to the leaf and applies, on the way back up, any messages still waiting in the buffers along the path.

This suits copy-on-write. Most writes copy only the root, so write amplification is far lower than in a copy-on-write B-tree. Any batch of upserts that fits in the root's buffer is atomic: a rename, a write with its new length and mtime, a create with its directory's new version.

Following gefs:
- **Block size.** Every block is one size, **16 KiB**. That is the file system's block; the content store's 64 KiB verification chunks (06 §4, §16 question 3) sit above it and are unaffected.
- **Node layout.** Keys and values in a node are variable-length, reached through a sorted table of 2-byte offsets. The offsets grow from the front of the block and the data from the back.
- **No sibling pointers.** Balance is relaxed: nodes may be less full than a B-tree's and merge opportunistically. Fill levels are kept in the parent, so siblings never point at each other and a copy never ripples sideways.
- **Inline data.** Values up to 512 bytes are stored inline, so small files and symbolic links take no data block.

## 4. The file system as keys

**Each tree is one flat key-value store.** A tree holds one version of one file system: no directory blocks, no inode table, no indirect blocks. Its keys are gefs's three, with one added (gefs's paper, §4):

| Key | Value | Use |
|---|---|---|
| `Kdat qid[8] off[8]` | a block pointer, or inline data | A file's data, by block-aligned offset. A missing key reads as zeros: files are sparse for free. |
| `Kent pqid[8] name[]` | the entry (§4.1) | A name in a directory. A directory's entries sort together, so listing it is one range scan and a lookup is O(log n), never a scan. |
| `Kup qid[8]` | the parent's `Kent` key | `..`, for directories only. |
| `Korphan qid[8]` | nothing | Ours: a file removed while it was open. Its data is freed when the last fid on it goes, and on the next mount if the machine crashed first. |

A **block pointer** is `addr[8] hash[8] gen[8]`: where the block is, the hash of its contents, and the generation it was written in.

### 4.1 The entry

gefs's directory record, with what POSIX needs added. gefs's record ends at `muid`:

`flags[8] qid.path[8] qid.vers[4] qid.type[1] mode[4] atime[8] mtime[8] ctime[8] btime[8] length[8] uid[4] gid[4] muid[4]`

- **Times** are nanoseconds. `ctime` (the entry's last change) and `btime` (creation) are ours; `Tgetattr` reports both (docs/proto/posix.md).
- **Owners.** `uid` and `gid` are numbers, so POSIX `stat` needs no lookup. Names come from `/adm/users`, in Plan 9's users(6) format, until `keyd` holds identities (M10).
- **Symbolic links** are ours: a qid type bit, with the target as the file's inline data. `Tsymlink` and `Treadlink` reach them.
- **No hard links,** as no VectraOS server has them (`Tlink` is refused). That keeps "one entry, one file", which renames and `Kup` depend on.

### 4.2 Operations

Every operation is one atomic batch of upserts:
- **Walk** looks up `Kent(pqid, name)`, step by step.
- **Read** looks up `Kdat` and fetches the block. **Write** upserts the new `Kdat` with an `Owstat` message for length, version, mtime and muid, without reading the entry first.
- **Create** inserts the `Kent`, and a `Kup` for a directory.
- **Remove** deletes the `Kent`, and clears the file's data and `Kup` in the background (§7). A file still open gets a `Korphan` instead, until its last fid goes.
- **Rename** across directories (`Trenameat`) deletes one `Kent`, inserts another, and updates a moved directory's `Kup`, all in one batch. A rename that would put a directory inside itself is refused.

## 5. Snapshots and branches

A **snapshot tree** holds the snapshots, their labels and their deadlists (gefs's paper, §5):
- `Ksnap id[8]` holds a tree's root, generation, predecessor, successor, base and reference counts.
- `Klabel name[]` holds a snapshot id.
- `Kdlist snap[8] gen[8]` holds a deadlist's head and tail.

The snapshot tree is itself copy-on-write, but is never snapshotted.

**Branches and snapshots:**
- **A branch is a mutable label.** It moves to the newest snapshot at every commit. Every other label names an immutable snapshot. A branch can be forked from any snapshot.
- **Branches are the subvolumes 06 asks for.** A system volume holds `store` (`/dist/store`), `cfg` (`/cfg`), `home` (`/home`) and `adm` (the administrative files, §9). Each can be snapshotted, rolled back and mounted on its own, and all of them share one pool of space.
- **Mounting** is by the attach name, as in gefs: `mount /srv/fsd /cfg cfg`.
- **Rolling back** forks a new branch from the chosen snapshot and moves the label.
- **The dump is a view of labels.** Dated snapshots are labels named `home@2027-03-14`, and the `dump` attach serves them as `/n/snap/2027/0314/home/...`, read-only, as 06 §10.2 wants.
- **Retention is policy, not format.** A commit every 5 s gives a snapshot that is dropped when the next one lands. `/cfg` says which dated snapshots are kept and for how long, and 06 says what updates keep (06 §10.3). `auditfs` labels a snapshot before each agent session, and undo forks from it.

**Deleting a snapshot reclaims what only it held,** through deadlists, as ZFS does:
- Every block pointer carries its birth generation. A block freed in the snapshot it was born in is free at once. One born earlier goes on the current snapshot's deadlist.
- When a snapshot is deleted, its deadlists are merged into its successor's, and blocks born after the deleted snapshot's predecessor are freed.
- Deadlists are sharded by birth generation, so a delete scans only lists that are wholly free.
- A snapshot's `base` is the start of its branch. Blocks born before the base belong to another branch's history, which frees them, so two branches never free one block twice.

There is no garbage collection pass and no per-block reference count.

## 6. Committing

**Commits happen every 5 s, and on `fsync`.** A commit makes everything written so far durable at once. `Tfsync` forces one and waits for it; several waiting calls share one commit. Up to 5 s of writes can be lost in a crash; a program that needs less calls `fsync`, as everywhere.

**The protocol** is gefs's seven phases (its paper, §6). The device needs only an ordered barrier, the block class's `FLUSH` (§10):
1. **Update the snapshots.** A barrier makes the data writes land first; then the snapshot tree is pointed at each dirty branch's new root.
2. **Prepare.** The superblock and arena headers are built in memory, and each arena's allocation log gets a generation marker, so a replay after a crash discards anything later. Mutation may go on from here.
3. **Write the arena headers,** then a barrier.
4. **Write the superblock,** then a barrier. This is the write that commits.
5. **Write the arena footers.** Headers and footers back each other up across a crash.
6. **Wait** for every write to land.
7. **Free.** Blocks that were dead within the commit are made reusable. That becomes durable at the next commit.

**A crash at any point loses nothing committed:**
- Before phase 4, the old superblock still describes a consistent tree.
- During phase 3, the headers do not match the superblock, so the footers are used.
- After phase 4, the headers match.
- Between phases 4 and 7, blocks can leak, not be lost. `fsd -c` reports leaks, and a later version reclaims them.

**There are two superblocks,** in the first and last blocks of the volume, and either one is enough to mount.

**Space comes from arenas.** Each arena keeps an append-only log of allocations and frees, replayed at mount into an in-memory map and compacted now and then. A compacted log is new blocks that hold only the free ranges. The old chain's blocks stay unused until the commit that points the arena at the new log is durable, because a crash before then replays the old one. The arena is chosen round-robin, offset by block type, so data, pivot and leaf blocks each tend to stay sequential. Freed ranges are sent to the device as `DISCARD` in batches.

## 7. `fsd`, the server

**`fsd` serves 9Px over the shared server framework,** like `tmpfs`:
- 9P2000, with the `posix` and `xattr` extensions (docs/proto/posix.md) and the `map` and `dref` extensions (02 §3.3).
- Shared open files, locks and `O_APPEND` come from `vx-9p`'s server framework, as in `tmpfs`.
- One `fsd` serves one volume.

**Single-threaded until M6.** gefs runs a mutator, readers, syncers and a sweeper as separate processes. `fsd` in M5 is one event loop:
- the mutator's work in the loop;
- writes to the device as asynchronous ring submissions, the syncers' job;
- long deletions and snapshot cleanup in slices between requests, the sweeper's.

It keeps gefs's discipline anyway: blocks that leave the mutator are immutable, and freed blocks wait in limbo by epoch. So once M6 brings threads, readers can move onto threads of their own without a change of design. gefs's epoch-based reclamation is the plan for that.

**Caches.**
- **Tree nodes** are cached in `fsd`, which sizes the cache from its memory budget (01 §5).
- **File data** is cached in the page cache: pager-backed VMOs, one per open file (§8).
- `Tread` and `Twrite` go through the same VMOs as `mmap`, so all three see one copy and stay coherent.

**Checking.**
- `fsd -c` walks every tree and the snapshot tree, checks every hash, and reports what is wrong or leaked.
- `fsd -r USER` reams a new volume.
- `host/vxfs`, built from the same library, makes, inspects and checks volume images on the build machine, so `./build` can make disk images for tests and releases.

## 8. The pager and `mmap`

**`fsd` is the system's trusted pager** (01 §5). `Tmap` answers with a pager-backed VMO for a range of a file, and libc maps it.
- **Faults.** The kernel asks `fsd` for missing pages, and `fsd` supplies them with `pager_supply` before a deadline. A missed deadline is a `PAGER_TIMEOUT` exception (`SIGBUS`), not a hang.
- **Writeback.** `MAP_SHARED` writes dirty the VMO's pages. At each commit `fsd` asks the kernel for the dirty ranges (`pager_op`), writes them to new blocks, upserts their `Kdat`, and marks the pages clean.
- **Eviction.** Clean pages of these VMOs are the first memory the kernel takes back under pressure (01 §5).
- **`dref`.** A `Tread` into a client's `Buffer` is served by mapping the page-cache pages, not copying them (02 §3.3).

**The kernel's pager objects are built in M5 for this:** `pager_create`, `pager_supply`, `pager_op` (dirty ranges, clean, hints), supply deadlines, and `vmo_op resize`. They are in 01 §3's syscall list but not yet implemented.

**The verified base tree is `distd`'s,** which settles 06 §16 question 2:
- `distd` serves `/boot`, `/bin` and the rest of a release's read-only tree as its own trusted pager. It reads the store's blobs from `fsd`'s `store` branch and checks each block against the release's SHA-256 hash trees (06 §4) before supplying it.
- `fsd` gains no verified mode. Its 64-bit block hashes catch failing media and bugs; `distd`'s SHA-256 catches tampering.

Keeping the two apart keeps `fsd` free of release formats, and keeps the trust decision in one place.

## 9. Administration

**The `adm` branch** holds the administrative files, as in gefs, mounted at `/adm` by `svcd`:
- **`users`**, in users(6) format;
- **`status`**, an ndb record: space used and free by branch, the last commit, cache sizes;
- **`ctl`**, which takes one command per write and answers errors in the write's reply.

The `ctl` commands:

| Command | Does |
|---|---|
| `snap BRANCH LABEL` | An immutable snapshot of a branch, labelled |
| `fork LABEL BRANCH` | A new branch from a snapshot |
| `del LABEL` | Delete a label; space its snapshot alone held is reclaimed |
| `rollback BRANCH LABEL` | Point a branch at a fork of the snapshot, keeping the old head as `BRANCH@before-…` |
| `sync` | Commit now, and wait |
| `check` | `fsd -c` on the mounted volume, reported to `status` |
| `halt` | Commit, then refuse further writes, for shutdown |

**Permissions:**
- Permissions are checked against the attaching user, as in Plan 9.
- An attach name starting with `%` mounts a branch permissively (no permission checks; any attribute may be changed), for members of the `adm` group only, as gefs does.
- Until `keyd` (M10), the user is the one the spawn message names, as for every server.

## 10. Disks: the `block` class

**Block drivers speak the `block` class protocol** (`docs/proto/block.md`, written in M5 step 1), a ring session per client:
- **Requests:** `READ` and `WRITE` into or out of the client's own buffer arena (01 §4.3); `FLUSH`, a barrier that completes once everything before it is durable; `WRITE` with `FUA`; `DISCARD`.
- **`INFO`** gives the sector size, the capacity and whether the device has a volatile write cache.
- **Restarts.** A driver that restarts loses nothing the client has not seen completed. The client resubmits what was in flight (01 §7.4).

**Partitions are windows.**
- A session reaches one window of the disk, fixed when it is opened, and the session is the capability.
- `partd` holds the whole disk's connector, reads the GPT (`lib/vx-gpt`), and claims a post for each partition its manifest names. A `CONNECT` there opens a session narrowed to that partition (docs/proto/block.md §6). `fsd` connects to the system volume's post, and `dosfs` to the EFI system partition's.
- No server sees sectors it was not given. `svcd` and `devmgr` stay as they are: a broker of its own, not `svcd` reading disks in its one loop before their drivers have started.
- The system volume's partition has a VectraOS GPT type GUID, fixed in `docs/proto/block.md`.

**The drivers.** `drv-virtio-blk` comes first, then NVMe (`drv-nvme`) with its several queues. Both put their DMA behind the IOMMU once M5 enforces it (01 §7.1).

## 11. The interchange file systems

| Server | Formats | Use | Drawn from |
|---|---|---|---|
| `dosfs` | FAT12, FAT16 and FAT32, read and write, long names | The EFI system partition (boot slots, 06 §7), USB sticks, SD cards | 9front's `dossrv` (4.2k lines) |
| `isofs` | ISO 9660 with Joliet and Rock Ridge, read-only | Install media (06 §8), CD images | 9front's `9660srv` (2.1k lines) |

Both are small 9Px servers over a `block` session, reimplemented in C23 as `fsd` is, with no snapshots, no pager and no `posix` extension beyond what the format has.

exFAT (large removable media) and ext4 read-only (Linux disks) are Known gaps until something needs them.

## 12. What the format leaves room for

| Later | How the format allows it |
|---|---|
| **Encryption** (06 §16 question 9) | Per-tree flags, and the block pointer's room: an authenticated cipher per block, keyed by `keyd` (M10) and sealed to the boot chain (M12), with the generation in the nonce |
| **Compression** | A flag in the block pointer, and the hash taken over the stored bytes |
| **Several devices, mirroring** | The arena table: arenas on more than one device, and a second copy of each block |
| **Growing a volume** | Arenas added at the end, as gefs's `-g` does, on an unmounted volume first |
| **Parallel readers** | Epoch-based reclamation, kept from the start (§7) |

**The superblock's header is `vxfs` with a format version,** and a format change bumps it. `fsd` refuses a volume whose version it does not know, rather than guess.

**All integers are little-endian,** like 9P and both machines (gefs's are big-endian).

**The block hash is XXH64,** written first-party from its specification and checked against values from the reference implementation (`tests/host/vxfs_test.c`). It is a 64-bit, non-cryptographic hash, as gefs's MetroHash64 is. Media errors and bugs are what it is for; tampering is `distd`'s concern (§8).

## 13. Where the pieces land

All in M5 (04 §6). The steps are in `docs/milestones.md`.

| Step | Pieces |
|---|---|
| 1 | `docs/proto/block.md`; `drv-virtio-blk`; `lib/vx-gpt`; `partd`, handing out partitions as windows |
| 2 | `lib/vx-fs`, part one: the block layer and arenas, the Bε tree with upserts, keys and messages; host tests and a fuzz target |
| 3 | `lib/vx-fs`, part two: snapshots, labels, deadlists, the commit protocol, the checker; a host power-cut test (§14); `host/vxfs` |
| 4 | `fsd`: the 9Px server, users, the `adm` files, the dump view; ctest run against `fsd` as well as `tmpfs` |
| 5 | The kernel's pager objects; `Tmap` and `dref`; `MAP_SHARED` in the musl back end |
| 6 | NVMe; IOMMU enforcement; driver hot restart under I/O load |
| 7 | ACPICA and `bus-acpi` (04 §6) |
| 8 | `dosfs` and `isofs` |
| 9 | Monocypher; the content store, `distd` with verified reads, `install` from the ISO, boot slots (06 §14) |

## 14. Testing

- **The library is host-built.** `lib/vx-fs` runs on the build machine against a file standing in for the disk, under ASan and UBSan, with its own tests and a fuzz target fed hostile blocks and message streams, as gefs's `fuzz.c` does.
- **Power cuts on the host.** A fake device records every write and barrier. The test replays a workload, cuts power at every barrier and at random points between them (keeping any subset of the writes not yet flushed), then mounts and checks. Every cut must mount to the last commit, with `check` clean apart from leaks.
- **Power cuts in QEMU.** A scenario writes under load and kills QEMU mid-commit. The next boot mounts, checks, and finds every file synced before the kill.
- **POSIX on `fsd`.** ctest's file checks run against `fsd` as well as `tmpfs`.
- **Snapshots.** A scenario snapshots `/cfg`, changes it, rolls back, and reads the dated view.

## 15. Budgets

00 §8's storage budgets apply from M5:
- a 4 KiB read already cached in under 5 µs;
- a 4 KiB read from NVMe within the device's latency plus 20 µs;
- `ls` of a directory with 10,000 entries in under 3 ms.

Ours as well:

| Measure | Target |
|---|---|
| A commit with nothing dirty | No writes |
| A commit after one small write | A handful of blocks (the root path and the logs), < 256 KiB written |
| Mount, after a clean shutdown or a crash | < 100 ms for a 1 TiB volume, beyond reading the allocation logs |
| Sequential write | Within half the device's bandwidth in M5; gefs reaches several hundred MB/s single-threaded |
| Deleting a snapshot | Proportional to the space it frees, not to the volume |

## 16. Heritage

| From | Taken | Left |
|---|---|---|
| gefs (9front) | Bε trees; the key schema; inline values; the snapshot tree, labels and branches; deadlists with bases; the seven-phase commit; arenas and allocation logs; epoch reclamation; the `adm` snapshot and permissive attach | Plan 9 C; big-endian integers; MetroHash64; its disk format |
| ZFS | Deadlists and birth generations, which gefs took first | The pool and its layers |
| Plan 9's dump (fossil, cwfs) | Dated read-only trees, browsable as directories | The separate archival store, and space that cannot be reclaimed |
| BetrFS | Bε trees as a file system | Its kernel and Linux's VFS |

## 17. Open questions

1. **The cache's share of memory.** gefs takes 25% of RAM. `fsd`'s tree cache and the page cache compete under one memory budget, and the right split comes from measurement.
2. **Retention defaults.** How many dated snapshots of `home` are kept, and for how long, before the user changes it.
3. **Discard.** Whether to issue `DISCARD` at every commit or in idle time, for devices where it is slow.
4. **When a volume is shared between machines.** A volume is one machine's. Shared trees are reached over 9Px (02 §6), not by two `fsd`s on one disk.
