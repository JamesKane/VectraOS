# The disk

A machine with no disk is a machine that forgets everything when it stops.
Step 5 of `docs/SHELL.md` gives Vectra one, in three pieces that stack: the
PCI bus, a virtio-blk driver over it, and `#S`, the device that makes a disk
a set of files.

    kernel/drivers/pci       what is on the bus, and where its registers are
    kernel/drivers/virtio    virtio-blk: sectors on and off a disk
    kernel/sd                #S at /dev/sd0: the disk as files

## One transport, three boards

Every board this kernel runs on has a PCI bus, and QEMU puts a
`virtio-blk-pci` device on it when `build.odin` asks. That is the whole
reason the disk is one driver rather than three. Where today the console and
the timer differ between q35 and the two `virt` boards, the disk does not:
the same `virtio` code drives it on all three, because the one thing that
differs -- how a driver reaches PCI configuration space -- `kernel/drivers/
pci` hides behind two procedures.

**Configuration space** is 256 bytes of registers per function: a vendor id,
a class, the base address registers that say where the function's memory is,
and a capability list. The PC reaches it through two ports, `0xCF8` for an
address and `0xCFC` for the data there, as it has since 1992. The boards
reach it through ECAM, a memory window where each function's registers are a
page at a computed offset. `arch.pci_read32` and `arch.pci_write32` are the
seam: the same driver above them, a different way to the register below.

The ECAM base is assumed, the way the GIC's and the PLIC's are: it is in the
device tree, and nothing here reads the tree for it yet. The bases are the
`virt` boards' own -- `0x4010000000` on arm64, `0x30000000` on riscv64 --
and a wrong one reads `0xFFFF` as every vendor id, which the scan reports as
an empty bus rather than driving.

## virtio, the modern way

A virtio device is driven through a *virtqueue*: a ring of descriptors in
memory that the driver fills and the device drains. `kernel/drivers/virtio`
speaks the 1.0 layout only, where the control registers, the doorbell and
the device-specific registers are each found through a PCI capability rather
than at a fixed port. `disable-legacy=on` in `build.odin` is what makes QEMU
present that device and only that one, so the driver never has a legacy path
to carry.

A block request is three descriptors: a header the device reads, a data
buffer it reads on a write and writes on a read, and a status byte it writes.
The driver puts them in the ring, rings the doorbell, and **polls** the used
ring until the device hands the chain back. Nothing else on the core has
anything to do while a boot waits for its disk, so a poll is the whole
mechanism. An interrupt is the optimisation for the day a second thread has
something better to do, and the driver is written so that swap is one
procedure -- the poll loop -- and not a rewrite.

One request is outstanding at a time. The queue is sixteen descriptors, far
more than one request needs, and a lock around the exchange is what lets two
callers share it without filling the same descriptors. The lock is a
spinlock and the poll does not sleep, so a disk read is safe from anywhere,
including a device handler that holds a lock of its own.

## `#S`: the disk as files

`kernel/sd` is Plan 9's `#S` and `9front`'s `sd`. Each disk the driver
brought up is a directory under `/dev`:

    /dev/sd0/data    the whole disk, byte-addressable, read and write
    /dev/sd0/ctl     one line of geometry: the sector count and the size
    /dev/sd0/esp     a partition, when the disk's table names one
    /dev/sd0/dos     its neighbours, one file each

QEMU's `vvfat` gives the ESP a table with one partition of type 6, so on
this build the volume is `/dev/sd0/dos`, and that is what `fatfs` mounts.

`data` is the disk with nothing interpreted. The partition files are windows
onto it, read out of the master boot record at sector zero: a file that
begins where its partition begins and is exactly as long as the partition
is. A write to `/dev/sd0/esp` writes inside that window and cannot reach past
it, which is the whole reason `disk/prep` hands a filesystem a partition
rather than the disk.

**Bound into `/dev`.** `#S` is a union member of `/dev`, searched after the
console device. `/dev/cons` is the console's; `/dev/sd0` is this one's;
neither device knows the other is there. A program that lists `/dev` reads
both, one member at a time, which is the one thing a directory reader must
be written to expect once a directory is a union.

**A read is a transfer, off the fid lock.** A read of `data` is a disk
transfer, which the virtio driver does by polling. The poll does not sleep,
so it would be safe under the device's spinlock, but it can take a while, and
a lock held across it stalls every other core. So the fid is resolved under
the lock, the lock is dropped, and the transfer happens on the caller's own
thread, the way `kernel/procfs` renders a status line. A bounce page carries
the sectors, because a caller's buffer is not always somewhere the device can
reach by physical address.

**Telling a table from a filesystem.** A FAT volume's own boot sector ends in
the same `0x55AA` signature a partition table does. The two are told apart by
their first byte: a partition table's bootstrap area is code or zero, a FAT
volume's is a jump instruction. A sector that jumps is a filesystem, and its
partition-entry region is really the BIOS parameter block, so `#S` leaves it
alone and the disk has no partitions. GPT is not read yet; a protective MBR
would today yield one partition of the wrong type rather than the GPT's own.

## What the build stages

`build.odin` attaches two disks over `virtio-blk-pci` on every board:

- **`sd0`, the ESP**, QEMU's `vvfat` view of `build/esp`. The firmware boots
  from it, and its sector zero is the FAT volume boot record the self-test
  reads. Its `vvfat` backend maps writes back to host files, so a raw write
  to a scratch sector of it does not reliably persist -- which is why the
  write proof uses the other disk.
- **`sd1`, a scratch image**, `build/disk.img`, a plain 64 MiB raw file the
  build makes once with an MBR naming two partitions: a small FAT-typed one
  with a marker at its first sector, for the self-test, and a Plan 9 one
  from sector 2048 to the end, which `kfs` reams and keeps (`docs/KFS.md`).
  It is a real block device: a write to it is still there the next boot,
  which is the persistence the self-test's round trip rests on. An image of
  an older shape is remade.

## Checked by

`verify_disk` in `kernel/main.odin` makes three claims, from ring 0 through
the namespace the machine will use:

- the first sector of `sd0` is a boot sector -- bytes 510 and 511 are `0x55`
  and `0xAA`;
- a scratch sector of `sd1` reads back the bytes a write put there, which is
  the block driver's round trip;
- `sd1`'s DOS partition file reads the marker the build wrote at the
  partition's first sector, not the disk's -- which is the window working.

## What is not here

- **GPT.** Only the MBR is read. A GUID partition table is a header at sector
  one and an array of entries after it, and the day a disk carries one is the
  day this reads it.
- **An interrupt.** Completion is polled. The driver is written so the swap
  is the poll loop and nothing above it.
- **A second queue, or several requests in flight.** One request at a time is
  what a synchronous boot needs. A filesystem server that wants depth is the
  thing that will ask for more.
- **Write-back caching, flush, or barriers past the ring fence.** A write is
  a write; the device's own cache is QEMU's to manage.
