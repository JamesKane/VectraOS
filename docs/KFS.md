# kfs, a filesystem of Vectra's own

`servers/kfs` is the filesystem the machine calls home. FAT keeps a file's
bytes and its name and nothing else the namespace promises: no owner, no
permission bits past read-only, no version on the qid, a four-gigabyte
ceiling. This keeps the rest, on the scratch disk `build.odin` makes, in a
shape of our own. Named for Plan 9's `kfs`, which played the same part.

    kfs [-r] device [srvname]

    disk.odin   the shape on the disk: superblock, bitmap, inode table, blocks
    main.odin   the 9P tree over it, and the start that reams, posts and forks

## The shape

    block 0        the superblock: magic, block size, where the tables are
    bitmap         one bit per block of the volume, set when taken
    inode table    1024 inodes of 128 bytes: mode, version, size, mtime,
                   twelve direct block numbers, one indirect, one double
                   indirect, and the owner
    journal        forty blocks: a header, then a log a transaction's
                   changed blocks are written to before they land
    data           everything else, handed out by the bitmap

Blocks are 4 KiB and every structure is a whole number of them, so a block
is the unit of every read and write and nothing straddles two. A directory
is a file whose blocks hold 128-byte entries, an inode number and a name of
up to 123 bytes; an empty entry has inode zero, which is never handed out.
Twelve direct blocks, an indirect table of 1024 more, and a double indirect
table of 1024 such tables make a file of four gigabytes. The tables are
walked a slot at a time and never held across an allocation, because the
cache may evict a table to make room for the block being allocated. A read
of a block the file never wrote answers zeros: a file may have holes, and a
truncate that grows makes one -- which is how the boot proves the double
level for the price of three blocks rather than a thousand writes.

The qid's path is the inode number and its version the inode's, which moves
on every write, so a client that cached a file can tell it changed. The mode
is the inode's, Plan 9's permission bits and directory bit, kept as given.
`mtime` is the second since 1970 at the last write, read from `/dev/time`
as a file is made, written or truncated, and answered as every date in a
`Tgetattr` -- kfs keeps one. The clock it reads is the bootloader's date
counted forward by the tick, so a file has a real date from the first boot
with no clock driver; a volume from before this has zeros there, and a zero
is still `nobody wrote a date`.

## Write-through, in an order

Every change is written when it is made, and the order is the one that
leaves the volume whole if the machine stops between any two writes:

- a block is marked taken in the bitmap before anything points at it;
- a new file's inode is written whole before the directory entry that names
  it;
- a file's blocks hold their bytes before the inode's size says the file
  reaches them;
- a removed file's entry is cleared before its inode and blocks are freed.

That order is still kept, and it is no longer the whole story. Every
request that changes the volume is now one **transaction**: its writes are
held until the request has succeeded, then landed through a journal all at
once, so a stop leaves either every one of them on the disk or none. A
request refused part way lands nothing -- the order alone used to leave its
first writes behind. What a stop can still leave, then, is only a
transaction's worth of work undone, never a half-done one.

## The journal, and the cache it made honest

The journal is forty blocks between the inode table and the data: a header
and a log. A commit writes the changed blocks to the log, then the header --
their block numbers, a count, and a magic at each end, so a header torn
mid-write does not read as a commit -- then the blocks to their homes, then
clears the header. A mount that finds a committed header copies the log home
before it reads anything else; a torn or empty one is nothing to do, since no
home block is touched before the header is whole. `MAX_TXN` bounds the
distinct blocks one request may dirty at thirty-two, many times what a
write, a create or a truncate touches; past it a request writes straight
home, not atomic, and says so.

**Holding writes back is what made the cache a problem, and the transaction
is what fixed it.** The cache is thirty-two slots direct-mapped by block
number, good only until the next read that maps to a slot. With every write
going straight to the disk that was harmless: a block evicted and read again
came back with its change. With writes held it would not -- a bitmap block a
truncate clears bit after bit would come back from the disk with the first
bits still set, and the change would be lost inside the request that made
it. So a transaction keeps its own copy of every block it has written, and
`bread` answers from that copy first: the overlay is the truth for a block
the request changed, and the cache is a read accelerator and no more. When
the transaction ends, committed or not, the cache is dropped whole, so no
slot can serve a copy it took before an eviction and a re-read.

There is no barrier between the log write and the header write, which real
hardware would want before trusting the header; QEMU's disk is ordered
enough for the story to be checked, and the gap is this paragraph's to name.

## The check

A stop before a commit loses that transaction and nothing else, and leaves
nothing behind. What the order could leave before the journal -- a block
taken and never pointed at, an inode written before the entry that names it
-- the journal now prevents; `kfs -c` remains, a mark from the root and a
sweep of what it did not reach, for a volume from before the journal or a
disk that lied. The boot runs both controls (`kfs -t`): a block leaked on
purpose that the check must reclaim, and a commit faked as stopped after its
record -- the log written and the header committed, the home untouched --
that replay must finish. Each is net zero on the disk and each can fail, which
is what makes them tests. `servers/kfs/fsck.odin`, and the transaction in
`disk.odin`.

## The cache

Thirty-two blocks, direct-mapped by block number, in the program's own
memory. The superblock, the bitmap and the inode table are the blocks
touched again and again; file data passes through the same slots, because
a 9P read is two blocks and a second read of the same file is rare. A slot
holds bytes a caller may change and `bwrite` puts on the disk, and is good
only until the next `bread` that maps to it -- which is why an inode is
copied out of its block into an `Inode` and back rather than edited in
place, and why a directory scan re-reads its block per entry.

## Ream

`-r` lays a fresh volume over whatever the device holds: the tables, an
empty root, and a `glenda` directory in it. Without `-r` the device must
hold a volume, and one that holds none is reamed anyway, once, with a line
on the console saying so. The scratch disk is blank the first time the
build makes it, and a boot that stopped on that would be a boot nobody
wanted. The superblock counts reams, so a reformatted disk is a new one to
anything that kept a qid.

## The server

The shape `servers/fatfs` has, and `servers/memfs` before it: a node on
the heap per file seen, a directory's children read once from its blocks
and kept, the parent exiting once the name is posted, `remove_stops` off.
Where fatfs assembled a name from a chain of entries, this reads an inode.
A listing's cookie is the entry's ordinal in its directory plus one, which
a removal between two reads does not move.

## How the boot uses it

`init_kfs` in `kernel/main.odin` runs after `init_fatfs`, because `kfs` is
a program on the FAT disk. `user.start_server` spawns `/bin/kfs
/dev/sd1/plan9 /srv/kfs` and waits for the parent to exit; `srv.mount`
puts `/srv/kfs` at `/usr`. `rcmain` sets `$home` to `/usr/glenda`. The
device is the second partition of `build/disk.img`, type `0x39`, which `#S`
names `plan9` and which the build now makes: sixty-four megabytes, a small
FAT-typed partition for the disk self-test and the Plan 9 one from sector
2048 to the end. An image of the old shape is remade.

## Checked by

`verify_kfs` keeps a count on the disk: `/usr/glenda/boots` holds a number,
which each boot reads, adds one to, writes, and reads back through a fresh
open. The boot line says `boot N of this volume`, and N grows across runs
and across architectures, since the three boards boot the same image -- the
persistence the step is for, on the line. Then the two things FAT could not
keep: a file made 0600 stats as 0600, and its qid version moves when it is
written. `tests/tools.rc` writes into `$home` and reads it back as a tool
would, and checks that `$home` is `/usr/glenda`.

## What is not here

- **A write barrier.** The journal orders the log write before the header
  write in program order and nothing more; a disk that reorders them could
  present a committed header over a log that had not landed. QEMU's does
  not, and a board's driver is where the barrier belongs.
- **Rename across servers.** Within kfs, `Trename` moves an entry and
  keeps the inode, across directories, and `mv` uses it; a name on another
  server answers EXDEV and `mv` copies and removes, as it does for a server
  that does not rename at all (memfs, the static tree: EOPNOTSUPP). The
  entry leaves its old directory before it lands in the new, so a stop
  between the two leaves an unnamed inode rather than one named twice.
- **A third indirect level.** Two reach four gigabytes: twelve direct
  blocks, a table of a thousand, and a table of tables. The double
  pointer sits at byte 92 of the inode, a slot that was spare, so a volume
  from before it reads as zero there and needs no ream. A third level is
  the same recursion again and waits for a file that wants it.
- **Groups.** A file has an owner (bytes 96 to 123 of the inode, the user
  that made it) and a mode the server checks against the attaching user,
  but no group; `/adm/users` is not read.
- **A write-back cache in normal running.** A transaction is write-back
  within itself -- its blocks are held and land at commit -- but between
  transactions the cache is dropped, so a block touched by two requests is
  read twice. A cache that survived across requests would save that, at
  the cost of knowing which of its blocks a crash may not have committed.
