# The walker: `kernel/smmu`, and the `dma` file

This is the design for the fourth of the five things `docs/HARDWARE.md`
section 3 gives the kernel, written before its code. The plan's argument
is in that document's section 4. A device walks the process's own page
tables. A pointer is then a pointer, and there is no second address space
to allocate from or translate between. This document says how that
argument becomes registers, tables, one list on a space, and one file
under `/dev/tree`.

It covers three places:

    kernel/smmu            the Arm SMMUv3 driver, the one walker QEMU has
    kernel/tree            the `dma` file a node grows, and the fault stream
    kernel/mem/space.odin  the list of walkers a space carries, and the
                           two calls that keep it true

Step 0 of `docs/HARDWARE.md` is where this lands, on QEMU's `virt` board
with `iommu=smmuv3`. `servers/blkfs`, the ring 3 disk driver, is the first
client and the proof. It is designed at the end of this document and built
after it.

---

## 1. The part, as QEMU models it

The `virt` board with `iommu=smmuv3` puts one SMMUv3 in front of the PCIe
root. The tree names it, and everything the driver needs is a read of that
node:

    smmuv3@9050000
        compatible        "arm,smmu-v3"
        reg               <0x00 0x9050000 0x00 0x20000>
        interrupts        <0 74 1  0 75 1  0 76 1  0 77 1>
        interrupt-names   "eventq", "priq", "cmdq-sync", "gerror"
        dma-coherent
        #iommu-cells      <1>
        phandle           <0x8004>

    pcie@10000000
        iommu-map         <0x00 0x8004 0x00 0x10000>

The `iommu-map` line is the whole of the PCI binding. A requester id is
the bus, device and function packed as `bus<<8 | dev<<3 | fn`. The map
says that id is the same number as a stream id on the SMMU with phandle
`0x8004`, for all 65536 of them. A board device names its stream
directly, `iommus = <&smmu 0x1e>`, and the NPU's line in
`docs/HARDWARE.md` section 5 is one.

The four lines are shared peripheral interrupts 74 to 77, so their ids at
the GIC are 106 to 109. Only two are used. The event queue line is the
fault path, and the global error line reports a broken queue. The command
queue completes by a poll here, so its sync line stays unrouted. The part
has no page request interface, so that line stays unrouted too.

**What the model answers in its id registers,** from QEMU's
`hw/arm/smmuv3.c`, and what the driver requires of any part:

    IDR0  S1P=1        stage 1 supported.               Required.
          TTF=2        AArch64 table format.            Required.
          COHACC=1     table walks snoop the caches.    Read, and reported.
          ASID16=1     16-bit ASIDs.                    Used.
          STALL_MODEL=1  a fault terminates, no stall.  Assumed either way.
          STLEVEL=1    two-level stream table.          Used.
    IDR1  SIDSIZE=16   stream ids are 16 bits.          Table sized from it.
          CMDQS=19, EVENTQS=19   the largest queues.    Smaller ones are used.
    IDR3  RIL=1        range invalidation.              Not used yet.
    IDR5  OAS=44 bits, GRAN4K=1.                        4 KiB required.

A part may lack stage 1, the AArch64 format or the 4 KiB granule. Such a
part is left disabled with a line on the log, and no node grows a `dma`
file. A stage 2 table, the address translation service, the page request
interface and stalled faults are not used. Each is a thing the board may
add and this design does not need.

**The reset state.** QEMU resets the global bypass register with its abort
bit clear, so every transaction passes untranslated until the driver sets
`SMMUEN`. That is why `kernel/sd` works today on a machine line that has no
SMMU and will keep working on one that does. The specification lets a part
reset with abort set, and a board's firmware may leave it either way. So
`smmu.init` runs before any kernel driver's first transfer, straight after
the PCI scan, and the `virt` order does not depend on the reset value.

## 2. The tables

Everything the walker reads from memory is one of four things. Each is
sized here so that a reader can check the allocation against the number.

**The stream table, two levels.** A stream id has sixteen bits. A linear
table would be 65536 entries of 64 bytes, four megabytes for a board that
uses a few hundred. So the table is two-level with a split at bit 8. The
first level is 256 descriptors of 8 bytes, one 2 KiB run in one page. Each
descriptor names a second-level block of 256 entries, 16 KiB, aligned to
its own size.

A block is allocated the first time a stream in it is touched.

On `virt` every device is on bus 0, so one block is ever allocated. A
descriptor left invalid makes every stream under it report
`C_BAD_STREAMID` and abort. That is the state a stream nobody drives
should be in.

**A stream table entry** is 64 bytes and is in one of four states:

    invalid    V=0. Never touched. The transaction aborts.
    bypass     V=1, Config=0b100. The device sees physical memory. This is
               the state every function the PCI scan found gets at init.
               The kernel's own drivers, `kernel/sd` and the virtio ones,
               still hand the device physical addresses, and they stay
               until the board. See section 8.
    translate  V=1, Config=0b101. Stage 1 translates, stage 2 bypasses.
               `S1ContextPtr` names the context descriptor. `S1CDMax` is
               zero, one descriptor per stream. `S1Fmt` is linear. Faults
               are recorded (`S1STALLD` set, no stall). The walk's
               cacheability and shareability say write-back, inner.
    abort      V=1, Config=0b000. A stream that was attached and then
               detached. A device still in flight gets `F_STREAM_DISABLED`
               on the event queue, which section 5 turns into a line.

**A context descriptor** is 64 bytes, and 64 of them fill a page. One is
written per attached stream. It is the process's translation control
register said again, field for field, with the value
`kernel/arch/arm64/paging.odin` programs:

    T0SZ=17  TG0=4K  IR0=OR0=write-back  SH0=inner  EPD0=0  EPD1=1
    AA64=1   IPS=min(the CPU's PARange, IDR5.OAS)
    TTB0     the space's root, `space.root`
    ASID     the walker's own tag for this attach, section 3
    MAIR0, MAIR1   `arm64.MAIR_VALUE`, byte for byte
    R=1      record faults          S=0  no stall
    A=1      report an access flag fault rather than update the flag

`EPD1` is set because the kernel half was never named, which is section 4's
sentence about `TTBR1` made literal. `MAIR` is the boot-time invariant the
plan asks for. The kernel writes one constant into the CPU's register and
the same constant into every descriptor. So index 0 means write-back,
index 1 non-cacheable and index 2 device in both. There is nothing to
check at boot because there is one constant.

The access flag is set on every leaf `space.odin` writes, so the walker
never takes that fault. QEMU's model checks the descriptor as it decodes
it. `T0SZ` must be between 16 and 39, the granule 4, 16 or 64 KiB, and the
root aligned. All three hold.

**The queues.** The command queue is 256 entries of 16 bytes, one page.
The event queue is 128 entries of 32 bytes, one page. Each base is aligned
to the larger of 32 bytes and the queue's size, which one page satisfies
for both. The priority queue is not enabled.

**One allocator call is missing.** `mem.alloc_pages` finds contiguous
frames and promises no alignment past a page. A second-level block wants
16 KiB alignment. `mem.alloc_pages_aligned(count, align)` is the addition,
a scan that steps by the alignment. It is the whole of what `kernel/mem`
adds for the tables.

## 3. Attach, detach, and the ASID

An attach is one stream bound to one address space, and it is four writes
in this order:

1. Allocate an ASID from the walker's own pool and a context descriptor
   slot. Fill the descriptor as section 2 says, with `TTB0 = space.root`.
2. Write the stream table entry as `translate`, naming the descriptor.
   Data barrier first, so the entry is in memory before the part can
   fetch it.
3. Issue `CFGI_STE` for the stream, so a cached copy of the old entry goes.
4. Link a `Walker` record onto the space, section 4.

A detach is the reverse. Unlink the record. Write the entry as `abort` and
issue `CFGI_STE`. Issue `TLBI_NH_ASID` for the ASID and a `CMD_SYNC`. Only
then return the ASID and the descriptor slot to their pools. The order
matters: an ASID returned early could be handed to the next attach while
the part still holds entries tagged with it.

**Why the walker has ASIDs when the CPU does not use them.** Every user
leaf carries `nG`, and the kernel runs every process under ASID 0 and
invalidates by address across all ASIDs. That is fine for the CPU, whose
TLB is flushed on the address that changed. The SMMU's TLB is one cache
shared by every attached stream, and an invalidate has to name whose
translations go. So the walker's ASID is the attach's own tag, from a pool
of sixteen bits. It never needs to agree with anything the CPU does.

Two streams attached to one space share nothing but the root. Each gets
its own ASID, which keeps a detach of one from touching the other.

**The command path.** A command is a 16-byte write at the producer index,
a data barrier, and a store to the producer register. `cmd_sync` writes
`CMD_SYNC` and spins until the consumer index reaches the producer. Every
turn of that spin reads the global error register. A broken queue then
stops the machine with a reason rather than a hang.

The queue is under a spinlock, and nothing under that lock sleeps. A full
queue spins for a free slot the same way. Two hundred and fifty-six
entries is more than any one caller issues, so the spin is for the part,
not for another core.

## 4. What `kernel/mem` learns

The plan says a space carries the list of walkers attached to it, and
that an unmap sends each one its own invalidate. This is the shape of that.

    Walker :: struct {
        invalidate: proc "contextless" (w: ^Walker, virt: uintptr, pages: int),
        detach:     proc "contextless" (w: ^Walker),
        next:       ^Walker,
    }

    Address_Space :: struct {
        root:    uintptr,
        lock:    sync.Spinlock,
        walkers: ^Walker,       // nil for every space that has none
    }

`kernel/mem` knows nothing about the SMMU. `kernel/smmu` owns the records,
fills the two procedures and links them under `space.lock`. The GPU's own
unit, `docs/HARDWARE.md` section 7, is a second implementation of the same
two procedures. That is why they are procedure values rather than a stream
number.

**The invalidate is told where the entry changes, not from `shoot`.**
The first draft of this section put it on `mem.shoot`, after the cores.
That is the wrong place. `shoot` runs after every lock is gone, because
it waits for other cores. Its quiet callers keep a root rather than a
space across that gap, since the space may die in it. A list on a space
that may be dead cannot be walked.

So the walk is at the change. Each procedure that narrows an entry,
`unmap_user` and its quiet form, `protect_user` and `remap_user`, walks
`space.walkers` under `space.lock` before that lock is dropped. The space
is certainly alive there. `shoot` keeps its root and is not changed.

The SMMU's `invalidate` issues one `TLBI_NH_VA` per page, or
`TLBI_NH_ASID` for a run past sixteen pages, then `CMD_SYNC`. It returns
once the part answers. That wait is a spin on a register and touches no
other core, so it is safe under `space.lock`. The list is walked under
that lock, so a detach cannot pull a record out from under the walk.

A space with no walker pays one nil test on the unmap path. That is the
cost the plan promised and it is the only one.

**A space that dies detaches first.** `space_destroy` walks the list
before it frees a single table and calls each `detach`. The stream is
aborted and its translations gone before the tables go. A device still in
flight then faults into the event queue rather than reads a recycled
frame. A process that ends and a process that `exec`s both reach
`space_destroy`. So a driver that replaces itself loses its device, which
is the right answer.

**The cache clean stays in the plan.** QEMU's walker snoops (`COHACC=1`,
`dma-coherent`), so no line is cleaned here. The board's GPU does not
snoop, and `docs/HARDWARE.md` section 4 says `map_at` and `unmap` clean
the entry they wrote when such a walker is attached. The hook for that is
a third procedure on `Walker`, `clean`. It is nil for the SMMU and for
every walker on `virt`, and the write site tests it the way it tests
`walkers`. It is named here so that the board does not add a second list.

## 5. Faults, and the event queue

A transaction the walker cannot complete terminates. The part writes a
32-byte record on the event queue and raises the queue's line. The
handler runs in interrupt context and does four things.

It reads every record between the consumer and producer indexes. It
decodes each. It appends a line to the fault ring of the node whose
stream the record names, and wakes that node's readers. Then it stores
the consumer index and acknowledges the line.

The decode takes three fields and reports them by name:

    type       F_TRANSLATION, F_PERMISSION, F_ACCESS, F_ADDR_SIZE,
               F_WALK_EABT, F_STREAM_DISABLED, C_BAD_STREAMID, C_BAD_STE,
               C_BAD_CD, F_CD_FETCH, F_STE_FETCH, F_UUT, F_CFG_CONFLICT
    stream     the id, and through the node's map, the slot
    address    the input address, for the types that carry one
    direction  read or write, from the record's `RnW` bit

A record may name a stream no node maps, which a broken descriptor could
produce. It goes to the log with the same words and to nobody's ring.

Each node that has a `dma` file has a ring of sixteen lines. A fault past
the sixteenth while nobody reads is dropped and counted, and the count
appears in the next line as `dropped N`. A ring rather than a queue that
grows, because the handler runs where nothing may allocate.

The global error line is the other interrupt. It means the part refused a
command or could not write an event, and a driver cannot recover from
either. The handler logs the error register and acknowledges through
`GERRORN`. It marks the walker broken, after which every `dma` write
answers `EIO` and every parked read returns. It does not panic. The
machine's other work is not the device's.

## 6. The `dma` file

A node grows a `dma` file when the tree gives it a walker. That is an
`iommus` property naming the SMMU and a stream, or an `iommu-map` on a
PCI host naming a range of them. `kernel/tree`'s `walk` resolves the
phandle against the SMMU node's own and refuses a phandle that names
anything else. On `virt` one node qualifies, `pcie@10000000`, and its
slots are requester ids. A board device with one `iommus` entry has one
slot, number zero.

The file is a stream in the shape of `irq`, and it takes writes.

**Write.** Two words, one line per write, the `ctl` convention
`docs/DEVFS.md` keeps:

    attach <slot> <pid>     bind the slot's stream to that process's space
    detach <slot>           abort the stream and forget the binding

The errors are the convention's:

    EINVAL   a word nothing recognises, or a slot the map does not cover
    ESRCH    no such process
    EPERM    the process is not the writer and holds no file the writer
             serves, section 7
    EBUSY    the slot is attached. Detach first. A rebind is not silent.
    EIO      the walker is broken, section 5
    ENOMEM   no descriptor slot, no ASID, or no second-level block

**Read.** A read parks until the node has a line and answers one line.
Three kinds:

    fault <slot> <type> <address> <read|write> [dropped N]
    detached <slot> exit        the attached process ended or exec'd,
                                and `space_destroy` took the stream
    broken                      the walker took a global error

The `detached` line is how a driver that bound a client's space learns
the client went. Nothing else tells it, because the process that ended is
not the driver's to wait for.

**Close.** The last close of a node's `dma` file detaches every slot that
file attached. A driver that dies takes its device's mastery with it
twice over. Once through its space, once through its descriptor, and both
paths end at the same `detach`. A read parked at that moment returns
`EINTR` through `tree_abort`, as an `irq` read does.

**Coherence is a property, not a line.** The plan's section 3 says the
`dma` file reports on read whether the device's port snoops. That is
already a file. A node that snoops carries `dma-coherent`, and a driver
tests for it with one `open`. A stream file that answered a status line
first would be two files in one. `docs/DEVFS.md` refuses that, so the
read is the fault stream and nothing else.

This is the one place this document moves the plan's wording.

## 7. The capability check, and who wrote the line

`attach` refuses unless the target process is the writer itself or holds
a file the writer serves. That check is what makes the line a capability
rather than a privilege. It needs two facts the kernel does not join
today: which process wrote the line, and which server a chan came from.

**The writer.** `#t` is worker-backed, so the handler runs on a
`kernel/mnt` worker and `sched.current` is not the client. The transport
already keeps one `Rpc` slot per request in flight, and `mnt.flushed`
looks that slot up by tag. The slot grows one field, the client thread
that submitted the request, set where the client parks on `settled`.
`mnt.requester(conn, tag)` answers it. `vfs.server_requester(sv, tag)`
wraps it the way `server_flushed` wraps `flushed`, and `kernel/user` turns
a thread into a pid.

A request the kernel sent itself has no process and is refused with
`EPERM`. That is right: the kernel attaches nothing on a program's behalf.

**The server.** A ring 3 server is a posted pipe end, and `pipe.server_for`
builds the `vfs.Server` a mount uses from it. The posting is recorded in
`srv.Service`, and the `Server` built from it records the posting process's
pid. `user.holds_server_of(pid, poster)` walks the target's descriptor
table for a chan whose server carries that pid, under the table's lock.
The self case, `pid` equal to the writer, is answered before the walk.

`blkfs` attaches its own space and takes the first branch. The GPU driver
of `docs/HARDWARE.md` section 7 attaches a game's space and takes the
second. The fields are laid down now so that step does not lay them down
twice.

## 8. What the kernel's own drivers do meanwhile

Enabling the SMMU changes the meaning of every physical address the
kernel's drivers hand a device. `kernel/sd`, `virtio-net`, `virtio-rng`
and `virtio-sound` all do, and they stay until the board. So `smmu.init`
writes a `bypass` entry for every function the PCI scan found, and only
then sets `SMMUEN`. Those drivers do not know the walker exists.

A stream a program attaches leaves bypass. From that write on, the kernel
driver's next transfer to that device faults into the event queue. A
driver that polls for completion would poll forever. `kernel/sd` is the
one that matters, and it takes one rule. `transfer` asks
`smmu.stream_owned` first and answers `EIO` for a disk whose stream a
program holds. A disk a program attached is no longer the kernel's, and
`#S` says so rather than hangs.

That is also how the step's comparison runs. `sd` reads the scratch disk's
marker at boot through bypass. `blkfs` attaches the same disk later and
reads the same sector through the walker. The self-test compares the two.
The kernel's tests that write the scratch sector run before ring 3 does,
so the order is already right.

If it ever is not, the alternative is a third `virtio-blk-pci` on the
machine line with its own image. This document names it so the choice is
a line rather than a rewrite.

## 9. Ports, and a machine with no walker

`kernel/smmu` reads the part's registers through `mem.map_mmio` at the
base the tree names. That is the fifth thing in the driver model, a base
read rather than assumed. The register and queue code is arch-neutral.
The context descriptor is the arm64 table format said again, and that
part is under `when ODIN_ARCH == .arm64`.

amd64 has no tree and riscv64's tree has no SMMU. On both `smmu.init`
finds nothing, no node grows a `dma` file, and `Address_Space.walkers`
stays nil everywhere. One nil test at each change is the whole cost. riscv64's
own IOMMU is a second `Walker` when it is wanted, in the same two
procedures.

## 10. The self-tests

**Ring 0, `verify_smmu`,** on arm64 where the node is. The id registers
answer what section 1 requires. A `CMD_SYNC` completes. A read of a
stream table entry nobody attached is invalid. Every check names what it
saw.

**Ring 3, `treedma`,** a program in the shape of `treeirq`, before
`blkfs` exists:

- `pcie@10000000/dma` opens.
- `attach 16 <self>` succeeds, for the scratch disk's requester id.
- A second `attach 16 <self>` is `EBUSY`.
- `attach 16 1`, for a process that holds nothing of ours, is `EPERM`.
- `attach 70000 <self>`, past the map, is `EINVAL`.
- `detach 16` returns the slot, and a kernel-side check reads that
  stream's entry as `abort`.

**With `blkfs`,** the two proofs `docs/HARDWARE.md` step 0 lists:

- A transfer aimed outside the driver's space is refused with a fault
  line and nothing else changes. `blkfs` submits a read whose data
  descriptor names an address below `USER_MAX` it never mapped. The `dma`
  read answers `fault 16 F_TRANSLATION <that address> write`. QEMU marks
  the device as needing a reset, `blkfs` resets it and rebuilds its
  queue, and the marker sector reads correctly after.
- A page the driver gave back is not readable by the device. `blkfs` maps
  a buffer and writes a sector from it, so the walker's TLB holds the
  translation. It frees the buffer with `segfree` and writes the sector
  from the same address again. The second transfer faults.
- The negative control for that proof is `-define:VECTRA_SMMU_NO_INVALIDATE`,
  which skips the walker's call at every change. Under it the second transfer
  lands, the sector holds the freed page's bytes, and the check fails,
  which is what a control is for. The control uses a device read of
  memory rather than a device write into it. A stale translation then
  reads a recycled frame rather than corrupts one.

**The comparison.** `sd`'s reading of the marker and `blkfs`'s agree byte
for byte, section 8.

## 11. `blkfs`, in outline

The first client, and the rest of step 0. A ring 3 program embedded the
way `servers/ramfs` is. `init` starts it, and it is mounted where `#S` is
today, serving `sdN/data` and `sdN/ctl` in the shape `docs/DISK.md` gives
them.

It opens three things under `pcie@10000000`. `mmio` for the ECAM window,
through which it finds the device, enables bus mastering and reads the
BARs. `dma`, to which it writes `attach <rid> <self>`. And the device's
interrupt line, which is one more file `kernel/tree` grows.

The PCI host node has no `interrupts`. It has `interrupt-map`, and the
four legacy pins route to shared lines 3 to 6 rotated by device number.
So the host node grows `irq0` to `irq3`, and a device at slot `d` on pin
A reads `irq<(d + 0) mod 4>`. The message-signalled path through the ITS
is a later step, and the ITS is not on this machine line.

The virtqueue is memory from `segalloc`, and the addresses it hands the
device are the addresses it wrote them at. That is the sentence the whole
design exists for. The device's BAR is a second `segattach`, of the window
the ECAM names. `mmio` covers it because the BAR falls inside the host
node's `ranges`. About nine hundred lines with the two proofs, and
`kernel/sd` stays beside it until the board.

## 12. The order of commits

1. `mem.alloc_pages_aligned`. `Walker`, `Address_Space.walkers`, the
   invalidate at each change, and the detach in `space_destroy`. No SMMU yet. The
   kernel builds and boots on all three with a nil list. About 120 lines.
2. `kernel/smmu`: the probe from the tree, the id registers, the tables,
   the queues, bypass entries from the PCI scan, `SMMUEN`, and
   `verify_smmu`. The `iommu=smmuv3` flag goes on both arm64 machine
   lines in `build.odin`. About 500 lines.
3. `mnt.Rpc.client`, `mnt.requester`, `vfs.server_requester`, the
   poster's pid on a served `Server`, and `user.holds_server_of`. About
   80 lines.
4. The `dma` file: the tree's resolve of `iommus` and `iommu-map`, attach
   and detach, the event handler and the fault ring, the read that parks,
   the close, and `treedma`. About 350 lines.
5. `irq0` to `irq3` on a PCI host node from `interrupt-map`. About 80
   lines.
6. `servers/blkfs`, the `sd` rule, and the two proofs. About 900 lines,
   and the step closes.

## See also

- `docs/HARDWARE.md` -- the plan this is one section of: the driver
  model in section 3, the argument in section 4, and step 0.
- `docs/SPACE.md` -- the space this adds a list to.
- `docs/SMP.md` -- the shootdown the walker joins.
- `docs/DEVFS.md` -- the `ctl` convention and the stream shape `dma`
  keeps.
- `docs/TRANSPORT.md` -- the request slot that learns who sent it.
- `docs/DISK.md` -- the marker the comparison reads, and `#S`.
- `docs/TESTING.md` -- the control that must fail.
