# D143. Taisce's file system keeps the names and inodes it reads, dropped by the batch that changes them, as Fxfs keeps its dirent cache (2026-10-26, decided)

After D142 and the path cleaned once, small_read (open, read, close of
a 64-byte file) was ~26.5 µs on the Orange Pi 6 Plus. fs(4) spends
~14 µs of CPU on each, and its largest part is Taisce: each name a
walk passes is a B-tree descent for its directory entry and another for
its inode, decoded from the node's bytes, every time, though the same
file is opened 10,000 times.

Fuchsia, the peer whose structure ours shares (an open is a request to
the file system's process), answers this in the server: Fxfs keeps a
`DirentCache` (`src/storage/fxfs/platform/src/fuchsia/dirent_cache.rs`),
an LRU of (directory, name) to the node, consulted before its tree on
every lookup, and keeps open nodes in memory. Linux's dcache and inode
cache do the same job in its kernel.

Taisce's caches today are for nodes of the B-tree (`Store`, D140) and
file blocks (`dataCache`, going to D131's pager VMOs): the bytes a
lookup reads, not what it found. D131 keeps metadata caching in Taisce
("metadata isn't file data"); this is that, one step up.

**The decision.**

- **`FileSystem` keeps two tables (`MetadataCache`):**
  - names: (directory, name) to the node it names;
  - inodes: a node's inode, decoded.

  Each is direct-mapped, 4096 slots, like `dataCache`: a name's slot is
  chosen by its directory and its name's bucket hash (the hash its
  directory entry is keyed by), an inode's by its number. A new entry
  replaces whatever held its slot; there is no LRU. Together they hold
  under a megabyte.
- **`stat` and `lookup` look there first**, and fill it from what they
  read. They are `FileReading`'s, shared with `FileReader`, which keeps
  no cache (its readers run at a past commit).
- **Every change drops what it changes, before it lands.** All of
  `FileSystem`'s changes to its tree go through one batch
  (`applyChanges`). Each key of the tree begins with a node's number and
  a kind: an inode key drops that node's inode; a directory entry's key
  (directory, name hash) drops that slot's name. A batch that fails has
  dropped them too, which costs only a later read. Nothing else writes
  the file tree; a volume mounted again starts with empty tables.
- **Not cached:** misses (a name not there), listings (`stats`, which
  would push out the names in use), attributes, and a `FileReader`'s
  reads.

**Rejected.**

- **The cache in fs(4)**, as Fxfs has it in its platform layer. fs
  changes the volume from many places (Node, FsIPC, rings, mapped
  writes, the journal), and each would have to drop entries; Taisce's
  one batch sees them all.
- **An LRU**, Fxfs's. A direct-mapped table needs no list and no
  allocation per hit; its collisions cost a B-tree read, which is what
  every lookup costs now.
- **Caching in the clients, or a table they map** (sketched for
  small_read on 2026-10-26). That goes further than Fuchsia does; it
  can build on this one, and is the owner's to choose.

**Checks.** Taisce's tests: a stat and a lookup come from the tables
after the first, and each kind of change (write, create, remove,
rename, link, a node's times or mode) is seen by the next stat or
lookup. The board's small_read is the measure (D127's row).

**Measured** (the board, six runs after a warm boot): small_read
23.0-25.6 µs (one row 59.1), a median of ~24.4 where it was ~26.5;
tree_walk 1.63-1.88 and read_4k 1.47-1.64 unchanged. fs's CPU over a
small_read run (10,100 iterations) 118-123 ms, from 142-164: ~12 µs a
request, from ~15. In a profile the walk is 131 samples, from 819.
