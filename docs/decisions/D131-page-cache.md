# D131. File data is cached once, in a pager VMO per file that fs(4) serves: pages faulted in with read-ahead from a pager thread, written back at Taisce's commit, evicted by the kernel when clean, and charged to fs's account (2026-10-24, proposed; for the owner's review; extends D8, D37, D99, D105, D127; ends K15a's v1 exemption for pager VMOs; takes NeoVectra's storage §8)

A file's bytes are cached in two places today, and in neither is the
cache in charge of memory:

- **Taisce's `dataCache`** (`fs/taisce/lib/FileSystem.swift:18`): 4096
  verified blocks, direct-mapped by physical block, each its own
  `[UInt8]`, 16 MiB whatever the machine. Every Node or ring read is
  served from it or the device, then copied four or five times on its
  way into the ring slot.
- **fs(4)'s mapped files** (M3l, `services/fs/server/MappedFiles.swift`):
  on the first `File.map`, the whole file (64 MiB at most) is read into
  an anonymous VMO behind a header page, and every later write is
  copied into it. The service's list has no limit and drops an entry
  only when its file is unlinked, outgrows its VMO or anything is
  renamed. Only tests and launch-test's file budgets use it.

There is also `SharedCache`, Taisce's verified-bytes cache for reader
threads (S1f), which fs(4) never builds because it runs no readers.

The kernel already has what a page cache needs: the user pager (K13d),
resizable pager VMOs (K13h), dirty tracking with WRITEBACK_BEGIN/END and
`query_dirty_ranges`, eviction of clean pager pages under pressure
(K14a), zero intervals (K14k), and loaned pages (K14f), which only a
pager's clean pages may borrow. todhchai planned this replacement ("A
pager (data faulted in, not copied up front) replaces the filling once
croi has one", its filesystem.md §7), and the syscall audit kept the
pager's seven calls for "when Taisce is the user". Nothing in user
space uses the pager yet.

D127 makes it urgent. Its cached rows (`small_read`, `read_4k`, a
`tree_walk` of 100k entries, a `grep_tree` over 200 MB) measure a page
cache against Linux's and FreeBSD's, which grow to the board's memory.
A fixed 16 MiB block cache would make `grep_tree` a device benchmark.

**The decision (proposed).**

- **One cache: a pager VMO per file, owned by fs(4).**
  - It holds the file's bytes at their own offsets: VMO offset 0 is
    file offset 0, and its content size is the file's size (the
    property D21 kept for this).
  - It replaces both Taisce's `dataCache` and the mapped files'
    anonymous VMOs, and `SharedCache`'s half for file blocks goes with
    them (principle 1).
  - Taisce keeps its node caches (`Store`'s decoded nodes, and
    `SharedCache`'s half for nodes as stored, for its readers), because
    metadata isn't file data. Host tools (mkfs, fsck, the hosted tests)
    read the device uncached.
  - It is created resizable. A file's size changes move the VMO's size
    with it, so shrinking drops the pages past the end and growing
    reads as zeros (a zero interval).
- **Reads go through it.**
  - fs(4) maps each file VMO into its own address space. Node `read`
    and ring reads copy from that mapping into the reply or the ring
    slot, one copy where today there are four or five.
  - `File.map` hands the client a read-only REFERENCE child of the
    file's VMO. Node `memory` hands it a snapshot child
    (SNAPSHOT_AT_LEAST_ON_WRITE) instead of a copy. `executable` stays
    refused: running programs from Taisce isn't this decision.
  - Files over 64 MiB are mapped too: the VMO is sparse, and the
    address space holds them. Directories still aren't mapped.
- **Faults are answered by a pager thread.**
  - fs(4) gets a second thread that answers only the pager's READ
    packets. It reads through Taisce's epoch reader (`FileReader`, S1f)
    at the last commit, so it never waits on the dispatcher. Its
    device is a second channel on the partition's ring (`NodeDevice`
    becomes `ConcurrentReadable`).
  - The dispatcher writes into pages through its own mapping, and may
    fault on a page that isn't resident. That fault waits only on the
    pager thread, which never waits on the dispatcher, so it can't
    deadlock.
  - The snapshot is the right one. A page that isn't resident is
    either clean, and so equal to the last commit, or a zero interval
    the pager is never asked for. Dirty pages and pages awaiting clean
    are never evicted.
- **Read-ahead is the pager's** (D37: the kernel asks for one page a
  fault).
  - The first miss in a file supplies 64 KiB around the page, cut to
    the file's end and to its extent.
  - Each miss that follows the last range supplied doubles it, up to
    one extent (128 blocks, 512 KiB, Taisce's largest), and a miss
    anywhere else starts again at 64 KiB.
  - An extent is read in one device request and checked block by block
    against its BLAKE3-128s. A block that fails supplies nothing for
    its page, and FAIL answers it with IO_DATA_INTEGRITY, which the
    fault reports as its synth code (D37).
- **Writes land in the VMO and are written back at commit** (NeoVectra
  storage §8).
  - A Node or ring write patches the pages through fs's mapping, and
    the kernel marks them dirty.
  - Taisce's group commit asks for the dirty ranges
    (`query_dirty_ranges`), calls WRITEBACK_BEGIN on them, which unmaps
    them so a write meanwhile dirties again, writes their blocks
    copy-on-write, and commits. Only then does it call WRITEBACK_END.
  - fsync is a commit now, as it is today. A write of part of a block
    no longer reads the block back from the device when its page is
    resident.
  - The crash harness models it: dirty pages are lost at a crash, and
    WRITEBACK_END comes only after the superblock that holds the
    blocks is durable.
- **Clients' reads stay whole.** The header page moves out of the data
  (offset 0 must be the file's, for tier 1's mmap and the loader)
  into one read-only table per volume. Each slot has the seqlock
  generation, the size and the gone flag; the replaced flag goes,
  because the VMO grows instead.
  - `File.map` returns the reference child and its slot, and a client
    maps the table once.
  - fs bumps the slot's generation around each write's pages, so
    FileCache's copy is kept only if the generation was even and
    unchanged, as it is today. `fs.read_4k` keeps its path: a slot
    read, a copy from the mapping, and a slot read.
  - A plain mapping, such as tier 1's mmap later, sees writes as they
    land, as on any Unix.
  - FileCache evicts the entry least recently used, not the first
    path.
- **Unlinked files keep their data for whoever holds them.**
  - Unlink sets the slot's gone flag, so a path cache looks again.
    The VMO lives while a client holds a child, and fs detaches it
    once ZERO_CHILDREN fires.
  - A rename marks gone only the slots under the renamed name, not
    every slot.
- **Which VMOs fs keeps.**
  - fs keeps a file's VMO while any client holds a child of it, while
    it has dirty pages, or while it is among the 4096 idle files used
    last. Past that number it detaches the oldest; detaching drops its
    clean pages (K13d).
  - The number bounds the objects fs holds, not memory. Memory is the
    kernel's to take back.
- **Memory pressure is the kernel's eviction, charged to fs.**
  - Pager VMOs are charged to their creator's account (`committedPages`,
    eviction included), which ends K15a's "pager VMOs (v1)" exemption.
  - The kernel takes clean pager pages first under pressure, as K14a
    does now, oldest first and DONT_NEED before them. An account at
    its warning level has its own clean pager pages taken before a
    commit against it fails.
  - fs is in D99's essential band, so the launcher never ends it for
    pressure. Its account's limit is its manifest's `memory limit`, by
    default all of memory less the kernel's reserve.
  - fs keeps no LRU of its own: the kernel's ages (accessed bits) are
    the only ones.
- **The system shows it** (principle 19). fs(4)'s `status` replaces
  `mapped N` with `files N resident BYTES dirty BYTES`, and its account
  shows the cache's charge in /proc.

**Budgets.**
- `fs.read_4k` (< 5 µs) and `fs.readers_4_x100` (≤ 1.5×) stay, with
  the same limits and the same checks, now through a reference child
  and a slot.
- New, with its check in launch-test's `fileBudgets`:
  - `fs.refault_4k`: a 4 KiB read of a page evicted with DONT_NEED.
    That is one pager round trip and one device read, < 100 µs under
    KVM.
  - `fs.seq_read_64m`: 64 MiB read cold through Node, which judges the
    read-ahead and has no limit until a board run sets one.
  
  Both are judged at V6's exit, with D127's file rows.
- `services.rss` (< 32 MiB) would count the cache. **Open:** count fs
  without its file VMOs and report `fs.cache_bytes` beside it (which
  changes what a budget measures, so it is the owner's call), or leave
  the cache in it and set fs's account limit under it on QEMU.

**Kernel changes.**
- Charging pager VMOs to their account, and an account at warning
  having its clean pager pages taken first (K15a, K14a; memory.md's
  accounts and reclamation sections).
- memory.md's K13d note that pager VMOs can't be resizable is out of
  date since K13h; it is corrected with this work.
- Nothing else: the fault's request size, supply, dirty tracking,
  writeback and REFERENCE children are as built.

**Tests.**
- Kernel (a suite in `user/test/swift`):
  - a pager VMO's committed pages are charged to its creator's
    account, and leave the charge when evicted;
  - an account at warning has its clean pager pages taken before a
    commit against it fails.
- Hosted:
  - read-ahead's ranges (first miss, doubling, a jump, a file's end,
    an extent's end);
  - writeback's order through the crash harness: a crash before
    WRITEBACK_END loses nothing that was committed, and nothing
    uncommitted survives;
  - the slot table's seqlock against a writer, as `MappedHeader`'s is
    today;
  - FileCache's eviction of the entry used least recently.
- launch-test (boot-launch):
  - a read after DONT_NEED comes back whole;
  - a file shrunk and then written past a gap reads zeros in the gap,
    where today's mapped file shows old bytes (found while drafting
    this);
  - an unlinked file's data stays readable through a child held
    across the unlink;
  - a block whose checksum fails gives IO_DATA_INTEGRITY through a
    mapping;
  - a file over 64 MiB maps.
- boot-persist: writes through the cache survive a cold boot and a
  warm one.

**Order.** In V6, before D127's file rounds:
1. the kernel's charge;
2. the pager thread over `FileReader`;
3. reads and `File.map` through the file VMOs, with the slot table;
4. writes and writeback, after which `dataCache` and the mapped files'
   VMOs go;
5. the budgets.

Each step keeps the tests passing.

**Rejected.**
- **Keeping `dataCache` and sizing it to memory.** It is a second copy
  beside any mapping, its blocks aren't the kernel's to evict, and its
  reads copy several times.
- **Writing through to Taisce and copying into the VMO**, as M3l does.
  fs's writes into a pager VMO dirty its pages anyway, so the dirty
  ranges would still need writing back; writing back at commit is the
  same work done once.
- **A cache of fs's own with an LRU and a pressure port.** That would
  be a second ager beside the kernel's, and a cache that answers
  pressure only as fast as fs runs.
- **Swap** stays rejected (D99). Only clean file pages leave memory.

**Not now.**
- Writable shared mappings for clients (tier 1's `MAP_SHARED`); the
  dirty tracking already supports them.
- Hints (`willneed`, `dontneed`, `sequential`) from clients.
- Executable mappings from Taisce.
- Direct (uncached) I/O on the ring.
- Compressed pages.
- Eviction in 64 KiB blocks as Zircon does (zircon-divergences:
  "Single pages").
