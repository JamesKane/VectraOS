# D140. Taisce's nodes are pages, the same bytes in memory as on disk: format 5 (2026-10-26, decided; amends D8's format)

A Taisce B+tree node was 16 KiB on disk, a header and its cells packed
after it, and decoded whole on every cache miss into a `Node` of arrays:
`keys: [[UInt8]]`, `values: [[UInt8]]`, `children`. Each key and value
was an array of its own, so a node handed out retained them, a lookup
chased a pointer for every key it compared, and freeing a listing
released them one by one. On the Orange Pi 6 Plus walking D127's 100,000
entry tree, `swift_release` was ~23% of fs's time (bench/peers/
2026-10-25-vectraos/NOTES.md, finding 5), and each boot's first walk was
about two and a half times slower than the rest while the cache filled
with decoded nodes.

The file systems and stores that page their B-trees keep a node as its
page and work on it in place: SQLite's and LMDB's pages (a header, an
array of 2-byte cell offsets in key order, cells packed from the page's
end), btrfs's leaves (an item array, data from the end), APFS's nodes (a
table of contents of key and value locations). What they learned, and
we take:
- **Offsets move, cells don't.** An insert or delete shifts the 2-byte
  offsets; a removed cell's bytes are dead until a cell doesn't fit the
  free space, and then the cells are packed (SQLite's defragmentation),
  where moving cells on every insert (btrfs's leaf data) costs a copy of
  up to the page.
- **Check a page whole when it is read.** btrfs trusted its items'
  offsets until fuzzed images crashed it, and added its tree checker.
  Ours checks every offset and length, and that the live cells and
  dead bytes fill the cell area exactly, after the checksum, so
  lookups read the page without checking again.
- **Not yet: prefix compression** (bcachefs's packed keys, InnoDB's):
  FSKey's keys share their node's first 8 bytes and more, which would
  shrink a node, but it changes every compare and split.

**The owner's choice (2026-10-26):** the offsets on disk, format 5
(`Superblock.version`), over keeping format 4 and building them on each
read. Volumes made at 4 are refused (`unsupportedVersion`) and fs(4)
doesn't format over them; the board's `/data` was made again (its
superblock slots zeroed from FreeBSD, then fs's `--format`).

**What changed:**
- `Node` holds one `[UInt8]` page (Node.swift): the header (magic,
  level, count, the cell area's start, its dead bytes, an internal
  node's first child), the slots, the cells. It is still a value, so a
  reader's snapshot shares changed nodes as before, at one reference
  count a node, not one a key.
- A change that overfills a node is made in a page twice the size and
  split from there, as the tree split an overfull decoded node before.
  A delete can split an internal node now (a longer separator after a
  rebalance), and an insert that shrinks a leaf (a shorter value)
  rebalances it, as a delete does: the random model test with values of
  every size found nodes left under a quarter full.
- Reading: `BTree.withValue`, `get(sorted:_:_:)` and `scan(...)` with
  a body give keys and values as `Span`s of the page; stat, lookup, a
  listing and its stats read inodes and directory buckets in place.
  `get`, `scan` and `floor` still return arrays, copied out, for the
  other callers.
- The key compare reads the slot and length from the page and compares
  8 bytes at a time.

**Measured** (the board, six runs each, `/data` remade and the tree made
again, then a warm boot): tree_walk 1.64–1.93 µs/entry (from 2.04–2.18),
the first row after the boot 1.68 (it was ~5.2); small_read 48.9–51.6
and read_4k 1.45–1.53 µs unchanged. In a profile fs fell from 0.97 to
0.87 times the walker's samples and `swift_release` from 1,384 to
~1,030, now mostly the fs service's own listing arrays and the IPC
encoder, not Taisce's.
