# ADR-0025: The system volume's file system is our own, after gefs: copy-on-write Bε trees in `lib/vx-fs`, served by `fsd`

Status: proposed, 2026-10-02. Decides 04 §6's "a decision on a copy-on-write FS (native log-structured, or a port)" for M5. The design is docs/11-storage.md.

## Context

The system volume must do more than store files:
- 06 snapshots `/cfg` and `/home` before every update and rolls `/cfg` back.
- 06 also shows dated read-only trees.
- `auditfs` undoes an agent's session (03 §8.5).
- `fsd` is the trusted pager behind `mmap` (01 §5).

It must survive a power cut and detect bad media. FAT32, which the EFI system partition needs, does none of this.

The candidates, surveyed 2026-10-02:
- **OpenZFS** has every feature. But it is CDDL-licensed, very large, and runs only on its Solaris porting layer (SPL), the kind of compatibility layer rule 13 refuses.
- **btrfs and bcachefs** are GPL and woven into Linux's kernel interfaces.
- **HAMMER2** is BSD-licensed, but bound to DragonFly's kernel.
- **ext4,** through lwext4, is mature but not copy-on-write, so it has no snapshots.
- **gefs** (9front, Ori Bernstein; MIT, as 9front is) is a crash-safe, corruption-detecting, snapshotting file system in under 9,000 lines.
  - **Design:** it is built on copy-on-write Bε trees, with ZFS-style deadlists, and it serves 9P from user space, as `fsd` does.
  - **Status:** it is written in Plan 9 C, its disk format is still changing, its author calls it not yet ready for important data, and it is being ported to OpenBSD.

## Decision

1. **`fsd`'s format is our own, after gefs's design.**
   - **Taken from gefs:** Bε trees with upserts, the flat key schema (`Kdat`, `Kent`, `Kup`), the snapshot tree with labels and branches, deadlists with bases, the seven-phase commit, arenas with allocation logs, and epoch-based reclamation.
   - **Written:** in C23 in `lib/vx-fs`, host-built and fuzzed, and served by `fsd` over `vx-9p`.
   - **Credit:** gefs, in the sources and in docs/11-storage.md, as `lib/vx-rc` credits rc. Nothing is vendored. The design is learned from gefs's paper, code and manual pages in 9front's tree.
2. **The disk format is not gefs's.** It adds what VectraOS needs:
   - POSIX times (`ctime`, `btime`);
   - numeric owners;
   - symbolic links;
   - `Korphan`, for files removed while open;
   - the pager.
   
   Its integers are little-endian and its block hash is XXH64 (first-party). Interoperability with 9front is over 9P, not by sharing disks.
3. **16 KiB blocks, values up to 512 bytes inline, a commit every 5 s and on `fsync`.** Branches are the subvolumes: `store`, `cfg`, `home` and `adm`.
4. **Single-threaded in M5,** one event loop with asynchronous device I/O. Epoch reclamation is kept so that readers move onto threads after M6.
5. **The verified base tree is `distd`'s** (06 §16 question 2). `distd` checks the store's blobs against the release's SHA-256 hash trees as a trusted pager of its own. `fsd`'s block hashes catch media errors and bugs, not tampering.
6. **FAT and ISO 9660 are separate small servers,** `dosfs` and `isofs`, reimplemented after 9front's `dossrv` and `9660srv`, for the EFI system partition, removable media and install media. They are never the system volume.

## Consequences

- M5 writes about 10–15k lines for `lib/vx-fs` and `fsd`, plus the `block` class, its drivers, the kernel's pager objects, `dosfs` and `isofs`. The format and the commit protocol are proven by gefs, so the risk is in our implementation, which the host power-cut test (11 §14) is for.
- No dependency enters `third_party/` for the file system, and none is owed review.
- A gefs volume cannot be mounted by `fsd`, nor ours by gefs. Moving data between them goes through 9P.
- Encryption, compression, several devices and growing a volume are left room in the format (11 §12) but not built.
- docs/11-storage.md replaces 04 §6's open choice, and settles 06 §16 question 2.
