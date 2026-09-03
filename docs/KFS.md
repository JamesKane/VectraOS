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
                   twelve direct block numbers and one indirect
    data           everything else, handed out by the bitmap

Blocks are 4 KiB and every structure is a whole number of them, so a block
is the unit of every read and write and nothing straddles two. A directory
is a file whose blocks hold 128-byte entries, an inode number and a name of
up to 123 bytes; an empty entry has inode zero, which is never handed out.
Twelve direct blocks and an indirect block of 1024 more make a file of a
little over four megabytes, which is the ceiling until a second level is
added. A read of a block the file never wrote answers zeros: a file may have
holes, and a truncate that grows makes one.

The qid's path is the inode number and its version the inode's, which moves
on every write, so a client that cached a file can tell it changed. The mode
is the inode's, Plan 9's permission bits and directory bit, kept as given.
`mtime` is a field with nothing to fill it: the kernel has no clock that
knows the date.

## Write-through, in an order

Every change is written when it is made, and the order is the one that
leaves the volume whole if the machine stops between any two writes:

- a block is marked taken in the bitmap before anything points at it;
- a new file's inode is written whole before the directory entry that names
  it;
- a file's blocks hold their bytes before the inode's size says the file
  reaches them;
- a removed file's entry is cleared before its inode and blocks are freed.

A stop loses the last operation and nothing before it. The one leak it can
leave is a block taken and never pointed at, which a scan at the next ream
would reclaim. There is no journal; `docs/SHELL.md` step 7 says one comes
when a crash costs something, and this is the shape it would journal.

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

- **A journal**, and a check program. The write order above is the whole
  crash story.
- **Files past four megabytes.** One indirect level.
- **Rename.** `mv` copies and removes, as it does everywhere here.
- **Owners.** Every file is glenda's; `uid` and `gid` are zero on the wire.
  The inode has no field for them yet because nothing has a second user.
- **Dates.** `mtime` is written as zero.
- **A bigger cache, or a write-back one.** Write-through costs a device
  request per changed block, which a boot of a few hundred writes does not
  notice.
