# fatfs, a filesystem the host can read

`servers/fatfs` is a FAT filesystem server in ring 3: 9front's `dossrv`
in Odin. It opens a partition of the disk `docs/DISK.md` brought up, reads
the volume the firmware booted from, and serves it over 9P. The boot
mounts it at `/n/esp` and binds its `vectra/bin` before `/bin`, and from
then on the tools a shell runs are files on the disk, staged there by the
build, rather than bytes in the kernel image. The image lost a third of its
size the day this landed.

    fatfs device [srvname]

    fat.odin    the volume: geometry, the allocation table, clusters, a sector cache
    dir.odin    directory entries, short names, long names, and writing all three
    main.odin   the 9P tree over them, and the start that posts and forks

## FAT12, FAT16, FAT32

One volume shape with two knobs. The allocation table's entries are 12, 16
or 28 bits wide, decided by the cluster count as the specification says
and not by the label the formatter wrote. The root directory is a fixed run
of sectors before the data on the first two and a cluster chain on the
third. `fat.odin` absorbs both: `fat_get` and `fat_set` know the width, and
`slot` in `dir.odin` finds entry `i` of a directory in either kind of root
without its caller knowing which it has.

## Sectors

The table and directory sectors go through a direct-mapped cache of
sixty-four sectors and are written through it, straight to the disk, on
every change. File data goes around it a cluster run at a time. The
write-through is not caution for its own sake: the volume is QEMU's `vvfat`
view of `build/esp` on the host, and a change that sits in a cache is a
change the host may never see. `vvfat` reads the guest's writes back into
host files as they land, which is what makes a file a tool wrote appear in
the build directory when the machine stops.

## Names

Every entry is 32 bytes: an uppercase 8.3 name, an attribute byte, the
first cluster, the size. A name that does not fit that form is spelled out
in long-name entries before it, thirteen UTF-16 characters each, last piece
first, each carrying a checksum of the short name. `vvfat` writes one for
every name it stages, `EFI` included, so long-name decoding is the path
every file takes. A new file gets long-name entries whenever its name is
not already a valid uppercase 8.3 name, and a short name built as Windows
builds one: the name uppercased and squeezed to six characters, then `~n`
for the smallest `n` no entry in the directory has. All the entries of a
new file are written before any of their sectors is flushed, so a host
watching never sees the pieces without the file.

Matching is FAT's: case-insensitive for ASCII, so `Echo` and `echo` are
one file and creating the second is `EEXIST`.

## Nodes, as in memfs

A fid names a `Node` on the heap: the file's long name, its first cluster
and size, and where its directory entry is so the entry can be rewritten
when the size changes. A directory's children are read from the disk the
first time anything asks and kept, which is safe because nothing else
writes the volume while this serves it. The 9P half of `main.odin` is
`servers/memfs` with the disk where the heap was, and a reader of one
can read the other.

A file is read by walking its chain to the cluster holding the offset,
from a hint left by the last read so a program loading in order walks the
chain once. A write extends the chain as it must, zero-fills any gap a
write past the end opens, and rewrites the directory entry's size. A
truncate frees the clusters past the new end. A remove frees the chain and
marks the entries deleted; a directory must be empty first.

## How the boot uses it

`init_fatfs` in `kernel/main.odin` is a shell's three lines in kernel
terms. `user.start_server` spawns `/bin/fatfs /dev/sd0/dos /srv/esp` from
the boot namespace and waits for the parent to exit, which the memfs
convention makes the moment the name is posted. `srv.mount` mounts
`/srv/esp` at `/n/esp`. Two binds put `/n/esp/vectra/bin` before `/bin` and
`/n/esp/vectra/lib` before `/lib`. The device is `/dev/sd0/esp` when the
partition table names an EFI system partition and `/dev/sd0/dos` for the
FAT partition `vvfat` makes, which is the one this build sees.

`build.odin` stages the disk: every program image under
`build/esp/vectra/bin` by its `/bin` name, `rcmain` and the test script
under `lib`, an empty `tmp` wiped each build. The kernel's own pak holds
only `fatfs` and `rc` -- what it takes to reach the disk and run a script
off it -- and `#b` is two files.

## What changed elsewhere

`/bin` and `/lib` became unions, and two things assumed they were not.
`create_path` never chose a member for a union, so a create in `/bin` went
to whichever tree was first -- the disk, now -- rather than to the member
flagged for creation as `union_create_target` always documented. It now
asks, and a union with no such member answers `EPERM`. And the user
suite's process count is measured against the processes alive before it
ran, because a filesystem server is one.

`#S`'s reads and writes moved to a page of sectors per device request; a
program loading over this path reads hundreds of eight-kilobyte pages, and
one round trip per page is eight times fewer than one per sector.

## Checked by

`verify_fatfs` in `kernel/main.odin` lists `/n/esp/vectra/bin` and finds
the forty staged programs, `echo` and `cleanname` among them -- the second
by its long name -- and reads the test script off the disk byte for byte
against the copy the kernel carries. `tests/tools.rc` does the writes, as
tools: it lists the disk, writes `hello disk` into `tmp/written` and reads
it back, and makes and removes a directory. After the machine stops,
`build/esp/vectra/tmp/written` on the host says `hello disk`.

The user suite runs entirely off the disk now: every `exec` of a tool is a
9P read from a ring 3 server over a polled virtio queue. On amd64 the tool
script went from 3500 to 4700 ticks and the shell script from 155 to 231;
riscv64's 5900 is well inside the suite's patience.

## What is not here

- **GPT.** Only the MBR is read for the partition, and `#S` is where that
  lives. The volume itself does not care.
- **Timestamps.** Every entry this program writes is dated 1980-01-01,
  for want of a clock that knows the date.
- **Rename.** `Trename` is not served; `mv` copies and removes.
- **`vvfat`'s directory names.** A directory this program creates appears
  on the host by its short name, `d~1` for `d`, and a directory it removes
  stays on the host. Files are named and removed correctly. This is
  `vvfat`'s reading of the guest's writes, which is why `tmp` is wiped each
  build.
- **Depth.** One request at a time, on `libuser.serve`. A read that parks
  on the disk parks every client. `serve_mux` is there for the day it
  matters.
