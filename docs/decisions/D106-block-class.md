# D106. The block class: one sd library over a disk's requests, virtio-blk under it, flush through ctl (2026-10-18, decided; extends D82, D105)

D82 gives the block class sd(3)'s directory, `/dev/sdXX/{ctl,raw,data}` and a
file per partition, with bulk on the one ring. D105 puts it first in V4.
Today only ramdisk(4) serves it, by hand: a NodeTree memory file for
`data` and a `ctl` text, with no partitions, no flush and no `raw`. Our
virtio-blk is its constants. todhchai's virtio-blk driver works (M3i),
but over its typed block service (`BlockIPC.Device`, its own ring and
attached buffers), which D82 replaced.

- **One library, `drivers/block/lib` (Sd), serves a disk's unit
  directory** from a `Disk`:
  - its sector count and size, whether it is read-only, and whether it
    has a cache to flush;
  - `start`, which begins a read or write of whole sectors into or from a
    buffer and calls `done` when it is finished, from any thread;
  - `flush`, which calls `done` once what was written before it is
    durable.

  The files are NodeTree `service` nodes, each channel a session of the
  library's, as fs(4)'s are:
  - `ctl` reads as Plan 9's: `inquiry`, `geometry`, `alignment`, and a
    `part NAME START END` line for each partition, `data` first. It
    takes `flush`.
  - `data` is the whole disk, and each partition is a file of its own.
    Reads may be at any offset (the sectors around them read and cut).
    Writes are whole sectors, else `invalid`. Both are bounded by the
    partition.
  - Each channel serves Node's `attach` through NodeRing: an entry is a
    disk request, started on the dispatcher's thread and answered when
    the disk says, in any order.
  - `raw` (SCSI's commands) isn't served.
- **Partitions are GPT's**, read when the unit starts: each partition is
  named by its GPT name (UTF-16 made UTF-8, a name sd can hold, a second
  of the same name numbered). With no GPT there is only `data`. The ctl
  takes no `part` or `delpart` yet: partitions are the disk's.
- **Flush is a ctl line.** A client's writes are done when they are
  answered, so a `flush` written to ctl makes durable everything
  answered before it: the device's cache flush, after the writes still
  under way. Taisce's barrier (`BlockDevice.flush`) is fs(4) writing
  `flush` to the unit's ctl, beside the partition it opened. On a disk
  with no cache to flush (ramdisk(4), a write-through device) it is
  answered at once.
- **ramdisk(4) moves onto it**: its Disk is its VMO, each request done
  on the spot. Its `data` stops being a memory file. Nothing mapped it:
  fs(4) reads and writes through the ring.
- **virtio-blk** (`drivers/block/virtio-blk`, `match pci 1af4:1042` and
  the transitional `1af4:1001`):
  - It lifts todhchai's VirtioBlockBackend (IMPORTS.tsv) for the
    device's queue and requests, made to keep many requests under way
    on queue 0 rather than one. Each request is the header, the data
    and the status byte, its data in pinned memory the device reaches
    through its BTI.
  - The ring's bytes are copied there and back. Pinning the client's
    data area itself is left for when a budget asks.
  - Completions come on MSI-X, else INTx.
  - It negotiates `FLUSH` (a flush is `VIRTIO_BLK_T_FLUSH`, sent once
    the writes before it are done), `BLK_SIZE` and `RO`.
- **devmgr binds the unit**, as it does a NIC's ether(3) directory: the
  driver serves `sd` in its tree, and devmgr mounts it at
  `/dev/sd<letter><n>`. The letter is the driver's (a match record,
  `sd F`: 9front's for virtio), and `n` counts that letter's units. So
  the first virtio disk is `/dev/sdF0`.

**Checks.**
- BlockTests (hosted), over a memory Disk that records its requests:
  - `ctl`'s lines;
  - a GPT image's partitions, their bounds, and a duplicate name;
  - reads at odd offsets, and writes refused unless whole;
  - ring entries finished out of order;
  - a `flush` started only once the writes answered before it are done.
  
  Then Taisce's crash harness over what that disk recorded, written
  through the library by fs(4)'s device: the harness's barriers are
  the block class's.
- VirtioTests: a request's descriptors and its status.
- boot-launch (amended in the building: one image fewer, and devmgr
  runs there): qemu.sh's `--disk FILE` attaches a virtio-blk disk
  `vx disk` makes, and launch-test finds `/dev/sdF0`, its partition in
  `ctl`, and a MiB written on the ring, flushed, read back through the
  partition and through `data` where it starts.
- launch-test and boot-cpu go on with ramdisk(4) under the library.

**Not here** (D105's later steps): Taisce on a virtio disk across
reboots, and `vx`'s mkfs and disk image; NVMe (V6).

Rejected: a flush entry on the ring (an operation only disks have, in
the one ring's set; ctl is the control a flush is, and writes are already
waited for). Rejected: todhchai's typed block service (D82 replaced
it). Rejected: ramdisk(4)'s `data` staying a memory file beside the
library (two ways to serve a disk).
