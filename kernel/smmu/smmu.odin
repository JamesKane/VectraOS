/*
smmu -- the SMMUv3 in front of the PCIe root, driven as `docs/SMMU.md` says.

A device's memory management unit. A stream, one requester on the bus, is bound
to one process's address space. From then on every address the device puts on
the bus is a virtual address in that space. The process's own page tables
translate it. A page the process never mapped faults into the event queue.
That is `docs/HARDWARE.md` section 4's argument made into a part.

**Three states a stream is in,** and every transition is here:

- `bypass`: the device sees physical memory. Every function the PCI scan found
  gets this at init, so `kernel/sd` and the virtio drivers keep handing the
  device physical addresses, section 8.
- `translate`: a program attached it. A context descriptor names the space's
  root and the attach's own ASID, and a `Walker` record on the space tells this
  package about every entry that narrows, section 4.
- `abort`: it was attached and then detached, by the program or by the space
  dying under it. A device still in flight faults rather than reads a recycled
  frame.

**What is arch-neutral and what is not.** The registers, the tables, the
queues and the commands are the same bytes on any machine, and this file is
all of them. The context descriptor is the arm64 table format said again, and
`arch_arm64.odin` beside this file fills it. Every other architecture has a
stub that is never reached, because `init` finds no node.

**Nothing here sleeps.** The unit's lock is a spinlock, a command completes by
a spin on the consumer register, and a walker's `invalidate` runs under
`space.lock`. The wait is on the part, not on another core. `docs/SMMU.md`
section 3.
*/
package smmu

import "base:intrinsics"

import "kernel:arch"
import "kernel:drivers/pci"
import "kernel:mem"
import "kernel:sync"

// -- The registers, at their offsets from the node's window -------------------

@(private) IDR0 :: uintptr(0x00)
@(private) IDR1 :: uintptr(0x04)
@(private) IDR3 :: uintptr(0x0C)
@(private) IDR5 :: uintptr(0x14)
@(private) CR0 :: uintptr(0x20)
@(private) CR0ACK :: uintptr(0x24)
@(private) CR1 :: uintptr(0x28)
@(private) CR2 :: uintptr(0x2C)
@(private) GBPA :: uintptr(0x44)
@(private) IRQ_CTRL :: uintptr(0x50)
@(private) IRQ_CTRLACK :: uintptr(0x54)
@(private) GERROR :: uintptr(0x60)
@(private) GERRORN :: uintptr(0x64)
@(private) STRTAB_BASE :: uintptr(0x80)
@(private) STRTAB_BASE_CFG :: uintptr(0x88)
@(private) CMDQ_BASE :: uintptr(0x90)
@(private) CMDQ_PROD :: uintptr(0x98)
@(private) CMDQ_CONS :: uintptr(0x9C)
@(private) EVENTQ_BASE :: uintptr(0xA0)
@(private) EVENTQ_PROD :: uintptr(0xA8)
@(private) EVENTQ_CONS :: uintptr(0xAC)

// IDR0, the fields section 1 requires or reads.
@(private) IDR0_S1P :: u32(1) << 1
@(private) IDR0_TTF_SHIFT :: 2 // 2 bits: 0b10 AArch64, 0b11 both
@(private) IDR0_COHACC :: u32(1) << 4
@(private) IDR0_ASID16 :: u32(1) << 12
@(private) IDR0_STLEVEL_SHIFT :: 27 // 2 bits: 0b01 two-level supported

// IDR1: the size of a stream id and of the largest queues.
@(private) IDR1_SIDSIZE_MASK :: u32(0x3F)
@(private) IDR1_EVENTQS_SHIFT :: 16
@(private) IDR1_CMDQS_SHIFT :: 21
@(private) IDR1_QS_MASK :: u32(0x1F)

// IDR5: the output address size code and the 4 KiB granule.
@(private) IDR5_OAS_MASK :: u32(0x7)
@(private) IDR5_GRAN4K :: u32(1) << 4

// CR0, and CR0ACK answering it bit for bit.
@(private) CR0_SMMUEN :: u32(1) << 0
@(private) CR0_EVENTQEN :: u32(1) << 2
@(private) CR0_CMDQEN :: u32(1) << 3

// CR1: the cacheability and shareability of the table and queue walks.
// Write-back, inner shareable, for both.
@(private) CR1_VALUE :: u32(3) << 10 | u32(1) << 8 | u32(1) << 6 | u32(3) << 4 | u32(1) << 2 | u32(1)

// CR2: private TLB maintenance, since every invalidate is issued here, and a
// bad stream id is recorded rather than dropped.
@(private) CR2_PTM :: u32(1) << 2
@(private) CR2_RECINVSID :: u32(1) << 1

// GERROR bits a queue reports.
@(private) GERROR_CMDQ_ERR :: u32(1) << 0
@(private) GERROR_EVENTQ_ABT_ERR :: u32(1) << 2
@(private) GERROR_SFM_ERR :: u32(1) << 8

// IRQ_CTRL, and IRQ_CTRLACK answering it: the event queue's line and the
// global error line. The command queue completes by a poll, and the part has
// no page request interface, so the other two stay unrouted, section 1.
@(private) IRQ_CTRL_GERROR :: u32(1) << 0
@(private) IRQ_CTRL_EVENTQ :: u32(1) << 2

// An event record, section 5, in four words. The type is the low byte of
// the first and the stream its high half. The direction is in the second,
// and the input address is the third.
@(private) EVT0_TYPE_MASK :: u64(0xFF)
@(private) EVT0_STREAM_SHIFT :: 32
@(private) EVT1_RNW :: u64(1) << 35

// The stream table configuration, section 2: two-level with a split at bit 8.
@(private) STRTAB_FMT_2LEVEL :: u32(1) << 16
@(private) STRTAB_SPLIT :: 8
@(private) STRTAB_BASE_RA :: u64(1) << 62
@(private) QUEUE_BASE_RA :: u64(1) << 62
@(private) ADDR_MASK :: u64(0x000F_FFFF_FFFF_FFC0) // bits 51:6

// The queues, section 2: 256 commands of 16 bytes in one page, and 1024
// events of 32 bytes in eight, aligned to their own size. A device retries a
// transfer the walker refused, and every retry is a record. QEMU's
// virtio-blk made a hundred and twenty-nine of one refused sector. That
// overflowed a queue of 128 in one burst before a core could drain it.
@(private) CMDQ_LOG2 :: 8
@(private) CMDQ_ENTRIES :: 1 << CMDQ_LOG2
@(private) EVENTQ_LOG2 :: 10
@(private) EVENTQ_ENTRIES :: 1 << EVENTQ_LOG2
@(private) EVENTQ_PAGES :: EVENTQ_ENTRIES * 32 / mem.PAGE_SIZE

// The commands this issues, by opcode in the low byte of the first word.
@(private) CMD_CFGI_STE :: u64(0x03)
@(private) CMD_CFGI_ALL :: u64(0x04)
@(private) CMD_TLBI_NH_ASID :: u64(0x11)
@(private) CMD_TLBI_NH_VA :: u64(0x12)
@(private) CMD_TLBI_NSNH_ALL :: u64(0x30)
@(private) CMD_SYNC :: u64(0x46)

// The stream table entry, section 2, in eight words. The first holds the
// valid bit, the configuration and the context descriptor pointer. The second
// holds the stage 1 walk's attributes and the stall disable.
@(private) STE_V :: u64(1)
@(private) STE_CONFIG_SHIFT :: 1
@(private) STE_CONFIG_ABORT :: u64(0b000)
@(private) STE_CONFIG_BYPASS :: u64(0b100)
@(private) STE_CONFIG_S1 :: u64(0b101)
@(private) STE_CONFIG_MASK :: u64(0b111) << STE_CONFIG_SHIFT
// Word 1: S1CIR, S1COR write-back, S1CSH inner, SHCFG incoming. S1STALLD,
// bit 27, stays clear. A part whose IDR0 says faults terminate never
// stalls, and QEMU's model refuses an entry with the bit set as a bad STE.
// That made every transaction on the stream abort. `docs/SMMU.md` section 2.
@(private) STE1_S1_WALK :: u64(1) << 2 | u64(1) << 4 | u64(3) << 6
@(private) STE1_SHCFG_INCOMING :: u64(1) << 44
@(private) STE_BYTES :: 64
@(private) STE_PER_BLOCK :: 1 << STRTAB_SPLIT
@(private) BLOCK_PAGES :: STE_PER_BLOCK * STE_BYTES / mem.PAGE_SIZE // 4: 16 KiB, aligned to itself
@(private) L1_SPAN :: u64(STRTAB_SPLIT + 1) // 2^(span-1) streams under one descriptor

// Context descriptors: 64 bytes, 64 to a page. One page is 64 attached streams.
@(private) CD_BYTES :: 64
@(private) SLOTS :: mem.PAGE_SIZE / CD_BYTES

// Past this many pages an invalidate names the ASID rather than each page.
@(private) INVALIDATE_BY_ASID_PAST :: 16

// How many turns a register is polled before the part is called broken.
@(private) PATIENCE :: 1 << 20

// Every function the scan finds gets a bypass entry. `virt` has a handful.
@(private) MAX_FUNCTIONS :: 32

/*
An attach: one stream bound to one space, and the walker record the space
holds for it. The ASID is the slot's own, one past its index so it is never
the zero the CPU runs every process under. The record is embedded here, so a
walker callback finds its attach by the pointer it was given.

`orphaned` is set when the space died first, section 4. `space_destroy`
called `detach` on the record and the stream is `abort`. The slot then waits
for the program's own `detach` to come back, and `space` is nil until then.
*/
Attach :: struct {
	using w:  mem.Walker,
	stream:   u32,
	asid:     u16,
	space:    ^mem.Address_Space,
	used:     bool,
	orphaned: bool,
}

// What an attach or detach answers, in the shape the `dma` file turns into an
// errno: section 6's table.
Error :: enum {
	None,
	Not_Present, // no unit on this machine
	Broken,      // the part took a global error
	Bad_Stream,  // a stream id past the table
	Busy,        // the stream is attached; detach first
	No_Memory,   // no slot, or no second-level block
	Bad_Handle,  // a handle that names no attach
}

/*
The unit. One per machine, because `virt` has one and the board has one.

`base` is the register window through `mem.map_mmio`. The tables are physical
addresses the part reads, kept beside their kernel-visible views. `l2` is the
second-level block per first-level descriptor, allocated the first time a
stream under it is touched and never freed, section 2.
*/
@(private)
Unit :: struct {
	lock:      sync.Spinlock,
	present:   bool,
	enabled:   bool,
	broken:    bool,
	coherent:  bool, // the node's `dma-coherent`
	phys:      uintptr,
	base:      uintptr,
	idr0:      u32,
	idr1:      u32,
	idr3:      u32,
	idr5:      u32,
	sid_bits:  int,
	ips:       u32, // the output address size code the descriptors carry
	eventq_spi: int,
	gerror_spi: int,

	l1_phys:   uintptr,
	l1:        [^]u64,
	l1_count:  int,
	l2:        [1 << 9]uintptr, // 2^(sid_bits-8) descriptors; 17-bit ids at most

	cmdq_phys: uintptr,
	cmdq:      [^][2]u64,
	cmdq_prod: u32,
	commands:  u64, // issued, for a self-test to count

	eventq_phys: uintptr,
	eventq:    [^][4]u64,
	eventq_cons: u32,
	events:    u64, // records taken off the event queue
	lost:      u64, // times the queue overflowed and the part dropped a record
	by_type:   [256]u64, // of each type, for a self-test that names them
	sink:      Sink,

	cd_phys:   uintptr,
	cds:       [^][8]u64,
	attaches:  [SLOTS]Attach,
	attached:  int,
	bypassed:  int,
	generation: u64, // attaches ever, for a kernel driver that shares a device
}

@(private)
unit: Unit

// sync_acquire and sync_release take the unit's lock for the self-test, which
// lives in another file of this package and issues a command of its own.
@(private)
sync_acquire :: proc "contextless" () -> sync.Guard {
	return sync.acquire(&unit.lock)
}

@(private)
sync_release :: proc "contextless" (g: sync.Guard) {
	sync.release(&unit.lock, g)
}

// -- Register access ------------------------------------------------------------

@(private)
read32 :: proc "contextless" (off: uintptr) -> u32 {
	return intrinsics.volatile_load(cast(^u32)(unit.base + off))
}

@(private)
write32 :: proc "contextless" (off: uintptr, v: u32) {
	intrinsics.volatile_store(cast(^u32)(unit.base + off), v)
}

@(private)
write64 :: proc "contextless" (off: uintptr, v: u64) {
	intrinsics.volatile_store(cast(^u64)(unit.base + off), v)
}

// wait_ack writes CR0 and spins until CR0ACK answers the same, or gives up
// and marks the part broken.
@(private)
wait_ack :: proc "contextless" (v: u32) -> bool {
	write32(CR0, v)
	for _ in 0 ..< PATIENCE {
		if read32(CR0ACK) == v {
			return true
		}
	}
	unit.broken = true
	return false
}

// -- The command queue ---------------------------------------------------------------

// queue_full is the producer one wrap ahead of the consumer at the same index.
@(private)
queue_full :: proc "contextless" (prod, cons: u32) -> bool {
	mask := u32(CMDQ_ENTRIES * 2 - 1)
	return (prod & mask) ~ (cons & mask) == u32(CMDQ_ENTRIES)
}

/*
issue writes one command at the producer index and tells the part. With the
lock held. A full queue spins for a slot the way `cmd_sync` spins. A part
with an error raised stops the spin rather than the machine.
*/
@(private)
issue :: proc "contextless" (w0, w1: u64) -> bool {
	if unit.broken {
		return false
	}
	for queue_full(unit.cmdq_prod, read32(CMDQ_CONS)) {
		if gerror_pending() {
			unit.broken = true
			return false
		}
	}
	idx := unit.cmdq_prod & u32(CMDQ_ENTRIES - 1)
	unit.cmdq[idx][0] = w0
	unit.cmdq[idx][1] = w1
	barrier()
	unit.cmdq_prod = (unit.cmdq_prod + 1) & u32(CMDQ_ENTRIES * 2 - 1)
	write32(CMDQ_PROD, unit.cmdq_prod)
	unit.commands += 1
	return true
}

// gerror_pending: a bit set in GERROR the driver has not acknowledged in
// GERRORN, other than a lost event. The line's handler counts and
// acknowledges that one on its own. Any other means a queue the part
// refused.
@(private)
gerror_pending :: proc "contextless" () -> bool {
	return (read32(GERROR) ~ read32(GERRORN)) & ~GERROR_EVENTQ_ABT_ERR != 0
}

/*
cmd_sync issues `CMD_SYNC` and spins until the consumer index reaches the
producer, section 3. Every turn reads the global error register, so a broken
queue ends in a false answer and a `broken` unit rather than a hang. With the
lock held.
*/
@(private)
cmd_sync :: proc "contextless" () -> bool {
	if !issue(CMD_SYNC, 0) {
		return false
	}
	for _ in 0 ..< PATIENCE {
		if read32(CMDQ_CONS) & u32(CMDQ_ENTRIES * 2 - 1) == unit.cmdq_prod {
			return true
		}
		if gerror_pending() {
			break
		}
	}
	unit.broken = true
	return false
}

// -- The stream table ------------------------------------------------------------------

/*
ste answers the entry for a stream, allocating the second-level block under
it on first touch. With the lock held. The block is 16 KiB on 16 KiB, which is
what `mem.alloc_pages_aligned` exists for. Its descriptor is written with a
barrier before the part can read it.
*/
@(private)
ste :: proc "contextless" (stream: u32) -> (e: ^[8]u64, ok: bool) {
	hi := int(stream >> STRTAB_SPLIT)
	lo := int(stream & (STE_PER_BLOCK - 1))
	if hi >= unit.l1_count {
		return nil, false
	}
	block := unit.l2[hi]
	if block == 0 {
		phys, got := mem.alloc_pages_aligned(BLOCK_PAGES, BLOCK_PAGES)
		if !got {
			return nil, false
		}
		zero_pages(phys, BLOCK_PAGES)
		unit.l2[hi] = phys
		barrier()
		unit.l1[hi] = u64(phys) & ADDR_MASK | L1_SPAN
		barrier()
		block = phys
	}
	view := cast([^][8]u64)mem.phys_to_virt(block)
	return &view[lo], true
}

// ste_write sets an entry's state, with the part told to drop its cached copy.
// The valid bit goes with the rest of its word, after the other words. So the
// part never sees a valid entry that is half written. With the lock held.
@(private)
ste_write :: proc "contextless" (stream: u32, e: ^[8]u64, w0, w1: u64) -> bool {
	e[0] = 0
	barrier()
	e[1] = w1
	for i in 2 ..< 8 {
		e[i] = 0
	}
	barrier()
	e[0] = w0
	barrier()
	if !unit.enabled {
		return true
	}
	if !issue(CMD_CFGI_STE | u64(stream) << 32, 1) {
		return false
	}
	return cmd_sync()
}

// ste_config answers the state of a stream's entry, for the self-test and for
// `stream_owned`: whether it is valid, and its configuration bits.
@(private)
ste_state :: proc "contextless" (stream: u32) -> (valid: bool, config: u64) {
	hi := int(stream >> STRTAB_SPLIT)
	if hi >= unit.l1_count || unit.l2[hi] == 0 {
		return false, 0
	}
	view := cast([^][8]u64)mem.phys_to_virt(unit.l2[hi])
	w0 := intrinsics.volatile_load(&view[stream & (STE_PER_BLOCK - 1)][0])
	return w0 & STE_V != 0, (w0 & STE_CONFIG_MASK) >> STE_CONFIG_SHIFT
}

@(private)
zero_pages :: proc "contextless" (phys: uintptr, pages: int) {
	p := cast([^]u64)mem.phys_to_virt(phys)
	for i in 0 ..< pages * mem.PAGE_SIZE / 8 {
		p[i] = 0
	}
}

// -- What the walker reports, and to whom ---------------------------------------------

/*
An event the part reports, section 5, in the shape the `dma` file turns into
a line. `Fault` is a record off the event queue: the stream, the type, the
input address for the types that carry one, and the direction. `Orphaned` is
the attach whose space died, from `walker_detach`, named by handle. `Broken`
is the global error line: the part refused a command or could not write an
event, and every attach is dead with it.
*/
Event_Kind :: enum {
	Fault,
	Orphaned,
	Broken,
}

Event :: struct {
	kind:   Event_Kind,
	stream: u32,
	fault:  u32, // the event type, `fault_name` spells it
	addr:   u64,
	write:  bool,
	handle: int,
}

// A sink runs in interrupt context, or under `space.lock` and the unit's
// lock for an orphan. It may take a lock nothing above it takes, may wake a
// sleeper, and may not allocate or sleep.
Sink :: proc "contextless" (e: Event)

// set_sink names who is told. `kernel/tree` sets it when it has a `dma` file
// to tell. Nil drops every event, which is what a machine with no tree does.
set_sink :: proc "contextless" (s: Sink) {
	unit.sink = s
}

// fault_name spells an event type as the specification names it, and a type
// this does not know as unknown.
fault_name :: proc "contextless" (kind: u32) -> string {
	switch kind {
	case 0x01: return "F_UUT"
	case 0x02: return "C_BAD_STREAMID"
	case 0x03: return "F_STE_FETCH"
	case 0x04: return "C_BAD_STE"
	case 0x05: return "F_BAD_ATS_TREQ"
	case 0x06: return "F_STREAM_DISABLED"
	case 0x07: return "F_TRANSL_FORBIDDEN"
	case 0x08: return "C_BAD_SUBSTREAMID"
	case 0x09: return "F_CD_FETCH"
	case 0x0A: return "C_BAD_CD"
	case 0x0B: return "F_WALK_EABT"
	case 0x10: return "F_TRANSLATION"
	case 0x11: return "F_ADDR_SIZE"
	case 0x12: return "F_ACCESS"
	case 0x13: return "F_PERMISSION"
	case 0x20: return "F_TLB_CONFLICT"
	case 0x21: return "F_CFG_CONFLICT"
	case 0x24: return "E_PAGE_REQUEST"
	}
	return "F_UNKNOWN"
}

/*
on_event is the event queue's line. It reads every record between the
consumer and producer indexes and decodes each. It hands each to the sink,
then stores the consumer index and acknowledges the line. In interrupt context,
so it takes the unit's lock and nothing else, and the sink is held to the
same rule.
*/
@(private)
on_event :: proc "contextless" (r: arch.Resume) -> arch.Resume {
	drain_events()
	arch.irq_ack()
	return r
}

@(private)
drain_events :: proc "contextless" () {
	guard := sync.acquire(&unit.lock)
	defer sync.release(&unit.lock, guard)
	mask := u32(EVENTQ_ENTRIES * 2 - 1)
	prod := read32(EVENTQ_PROD) & mask
	for unit.eventq_cons != prod {
		rec := &unit.eventq[unit.eventq_cons & u32(EVENTQ_ENTRIES - 1)]
		barrier()
		e := Event {
			kind   = .Fault,
			stream = u32(rec[0] >> EVT0_STREAM_SHIFT),
			fault  = u32(rec[0] & EVT0_TYPE_MASK),
			addr   = rec[2],
			write  = rec[1] & EVT1_RNW == 0,
		}
		unit.events += 1
		unit.by_type[e.fault] += 1
		unit.eventq_cons = (unit.eventq_cons + 1) & mask
		if unit.sink != nil {
			unit.sink(e)
		}
	}
	write32(EVENTQ_CONS, unit.eventq_cons)
}

/*
on_gerror is the global error line, section 5, and it says one of two
things. An event the part could not write, because the queue was full, is
a record lost. It is counted and acknowledged, the queue is drained, and
the part goes on, the way the tree's ring counts a line it dropped.

A command the part refused, or a fault in the part itself, is a unit a
driver cannot recover. The bits are acknowledged through `GERRORN` and
the unit is marked broken. After that every attach answers `Broken`, and
the sink is told once. The machine's other work is not the device's, so
this does not panic.
*/
@(private)
on_gerror :: proc "contextless" (r: arch.Resume) -> arch.Resume {
	fatal := false
	{
		guard := sync.acquire(&unit.lock)
		defer sync.release(&unit.lock, guard)
		pending := read32(GERROR) ~ read32(GERRORN)
		if pending & GERROR_EVENTQ_ABT_ERR != 0 {
			unit.lost += 1
		}
		if pending & ~GERROR_EVENTQ_ABT_ERR != 0 {
			unit.broken = true
			fatal = true
		}
		write32(GERRORN, read32(GERROR))
	}
	if !fatal {
		drain_events()
	} else if unit.sink != nil {
		unit.sink(Event{kind = .Broken})
	}
	arch.irq_ack()
	return r
}

// lost answers how many times the part dropped a record for a full queue.
lost :: proc "contextless" () -> u64 {
	return unit.lost
}

// stream_config answers a stream's entry as the part reads it: bit 0 valid,
// then the configuration field, or 0xFF for a stream past the table. For a
// self-test that says what state an entry is in rather than that it is wrong.
stream_config :: proc "contextless" (stream: u32) -> u64 {
	if !unit.present {
		return 0xFF
	}
	guard := sync.acquire(&unit.lock)
	defer sync.release(&unit.lock, guard)
	valid, config := ste_state(stream)
	return (valid ? 1 : 0) | config << 1
}

// registers answers CR0ACK, GERROR and GERRORN, for a self-test's line.
registers :: proc "contextless" () -> (cr0ack, gerror, gerrorn: u32) {
	if !unit.present {
		return 0, 0, 0
	}
	return read32(CR0ACK), read32(GERROR), read32(GERRORN)
}

// poll drains the event queue without waiting for its line, for a self-test
// that asks whether records are there that no interrupt delivered.
poll :: proc "contextless" () {
	if unit.present && unit.enabled {
		drain_events()
	}
}

// events answers how many records came off the queue, for a self-test.
events :: proc "contextless" () -> u64 {
	return unit.events
}

// events_of answers how many records of one type came off the queue. A
// self-test can then say which kind of fault it saw rather than that it
// saw one.
events_of :: proc "contextless" (kind: u32) -> u64 {
	return unit.by_type[kind & 0xFF]
}

// -- Bring-up ----------------------------------------------------------------------------

// The node, as `kernel/tree` read it: where the registers are, whether the
// walks snoop, and the two shared lines section 5 uses. `kernel/main` fills
// it, because this package is below the tree.
Node :: struct {
	phys:       uintptr,
	size:       u64,
	coherent:   bool,
	eventq_spi: int,
	gerror_spi: int,
}

// What `init` found, for the boot line.
Status :: enum {
	No_Node,    // no `arm,smmu-v3` in the tree, or no tree; nothing done
	No_Window,  // the node has no `reg`, or it would not map
	Unsupported, // the part lacks stage 1, the AArch64 format or 4 KiB pages
	No_Memory,  // a table would not allocate
	Broken,     // the part did not acknowledge its enable
	Enabled,
}

Info :: struct {
	status:    Status,
	phys:      uintptr,
	sid_bits:  int,
	coherent:  bool,
	functions: int, // PCI functions given a bypass entry
	oas:       u32,
}

/*
init finds the part in the tree and checks it against section 1. It builds
section 2's tables, gives every function the PCI scan found a bypass entry,
and sets `SMMUEN`. It runs before any kernel driver's first transfer, straight
after the PCI scan has its window. `kernel/main` keeps that order.

A machine with no node, which is every amd64 and riscv64 machine and an arm64
one without `iommu=smmuv3`, does nothing and says so. A part this cannot drive
is left as it reset, with its reason on the log, and no stream is ever
attached to it.
*/
init :: proc "contextless" (node: Node, found: bool) -> Info {
	info: Info
	if !found {
		info.status = .No_Node
		return info
	}
	if node.size < 0x20000 {
		info.status = .No_Window
		return info
	}
	info.phys = node.phys
	virt, err := mem.map_mmio(node.phys, node.size)
	if err != .None {
		info.status = .No_Window
		return info
	}
	unit.phys = node.phys
	unit.base = uintptr(virt)
	unit.coherent = node.coherent
	info.coherent = unit.coherent
	unit.eventq_spi = node.eventq_spi
	unit.gerror_spi = node.gerror_spi

	unit.idr0 = read32(IDR0)
	unit.idr1 = read32(IDR1)
	unit.idr3 = read32(IDR3)
	unit.idr5 = read32(IDR5)
	unit.present = true

	ttf := (unit.idr0 >> IDR0_TTF_SHIFT) & 3
	stlevel := (unit.idr0 >> IDR0_STLEVEL_SHIFT) & 3
	unit.sid_bits = int(unit.idr1 & IDR1_SIDSIZE_MASK)
	info.sid_bits = unit.sid_bits
	info.oas = unit.idr5 & IDR5_OAS_MASK
	if unit.idr0 & IDR0_S1P == 0 || ttf & 2 == 0 || unit.idr5 & IDR5_GRAN4K == 0 || stlevel != 1 || unit.sid_bits < STRTAB_SPLIT || unit.sid_bits > 17 {
		info.status = .Unsupported
		return info
	}
	unit.ips = ips_code(info.oas)

	// The tables and the queues, one page each. The first level's page holds
	// 2^(sid_bits-8) descriptors of 8 bytes, at most 4 KiB.
	if !alloc_page(&unit.l1_phys) || !alloc_page(&unit.cmdq_phys) || !alloc_page(&unit.cd_phys) {
		info.status = .No_Memory
		return info
	}
	if eq, got := mem.alloc_pages_aligned(EVENTQ_PAGES, EVENTQ_PAGES); got {
		zero_pages(eq, EVENTQ_PAGES)
		unit.eventq_phys = eq
	} else {
		info.status = .No_Memory
		return info
	}
	unit.l1 = cast([^]u64)mem.phys_to_virt(unit.l1_phys)
	unit.l1_count = 1 << uint(unit.sid_bits - STRTAB_SPLIT)
	unit.cmdq = cast([^][2]u64)mem.phys_to_virt(unit.cmdq_phys)
	unit.eventq = cast([^][4]u64)mem.phys_to_virt(unit.eventq_phys)
	unit.cds = cast([^][8]u64)mem.phys_to_virt(unit.cd_phys)
	for i in 0 ..< SLOTS {
		unit.attaches[i].asid = u16(i + 1)
	}

	// Bypass for every function the scan found, before the part is enabled,
	// so no kernel driver's transfer meets an invalid entry: section 8.
	found_fns: [MAX_FUNCTIONS]pci.Device
	n := min(pci.scan(found_fns[:]), MAX_FUNCTIONS)
	{
		guard := sync.acquire(&unit.lock)
		defer sync.release(&unit.lock, guard)
		for i in 0 ..< n {
			at := found_fns[i].at
			stream := u32(at.bus) << 8 | u32(at.dev) << 3 | u32(at.fn)
			if e, ok := ste(stream); ok {
				_ = ste_write(stream, e, STE_V | STE_CONFIG_BYPASS << STE_CONFIG_SHIFT, STE1_SHCFG_INCOMING)
				unit.bypassed += 1
			}
		}
		info.functions = unit.bypassed

		if !enable() {
			info.status = .Broken
			return info
		}
	}
	arm_lines()
	info.status = .Enabled
	return info
}

/*
arm_lines routes the event queue's line and the global error line to their
handlers and lets the part raise them. Both are edge lines on `virt`, so a
handler acknowledges and does not mask. A part whose lines the tree did not
name is left to be polled, which `drain_events` allows.
*/
@(private)
arm_lines :: proc "contextless" () {
	if unit.eventq_spi <= 0 || unit.gerror_spi <= 0 {
		return
	}
	// Both lines are pulses, which the tree's `interrupts` flags say. So
	// each is made an edge after the route makes it a level. A pulse on a
	// level line is a fire the controller may drop before a core sees it.
	arch.set_interrupt_handler(arch.VECTOR_IRQ_BASE + unit.eventq_spi, on_event)
	arch.irq_route(unit.eventq_spi, arch.irq_vector_of(unit.eventq_spi), 0)
	arch.irq_set_edge(unit.eventq_spi)
	arch.irq_set_mask(unit.eventq_spi, false)
	arch.set_interrupt_handler(arch.VECTOR_IRQ_BASE + unit.gerror_spi, on_gerror)
	arch.irq_route(unit.gerror_spi, arch.irq_vector_of(unit.gerror_spi), 0)
	arch.irq_set_edge(unit.gerror_spi)
	arch.irq_set_mask(unit.gerror_spi, false)
	write32(IRQ_CTRL, IRQ_CTRL_EVENTQ | IRQ_CTRL_GERROR)
	for _ in 0 ..< PATIENCE {
		if read32(IRQ_CTRLACK) == IRQ_CTRL_EVENTQ | IRQ_CTRL_GERROR {
			return
		}
	}
}

@(private)
alloc_page :: proc "contextless" (phys: ^uintptr) -> bool {
	p, ok := mem.alloc_page_zeroed()
	if ok {
		phys^ = p
	}
	return ok
}

/*
enable programs the queues and the table and sets `SMMUEN`, in the order the
specification gives. The command queue comes first, since the invalidate-all
that clears a part's stale state is a command. Then the event queue, then the
stream table, then the enable. Each step waits for its acknowledgement. With
the lock held.
*/
@(private)
enable :: proc "contextless" () -> bool {
	// Anything the firmware left running is stopped first.
	if !wait_ack(0) {
		return false
	}
	write32(CR1, CR1_VALUE)
	write32(CR2, CR2_PTM | CR2_RECINVSID)

	write64(CMDQ_BASE, u64(unit.cmdq_phys) & ADDR_MASK | QUEUE_BASE_RA | u64(CMDQ_LOG2))
	unit.cmdq_prod = 0
	write32(CMDQ_PROD, 0)
	write32(CMDQ_CONS, 0)
	if !wait_ack(CR0_CMDQEN) {
		return false
	}
	unit.enabled = true
	if !issue(CMD_CFGI_ALL, 31) || !issue(CMD_TLBI_NSNH_ALL, 0) || !cmd_sync() {
		unit.enabled = false
		return false
	}

	write64(EVENTQ_BASE, u64(unit.eventq_phys) & ADDR_MASK | QUEUE_BASE_RA | u64(EVENTQ_LOG2))
	unit.eventq_cons = 0
	write32(EVENTQ_PROD, 0)
	write32(EVENTQ_CONS, 0)
	if !wait_ack(CR0_CMDQEN | CR0_EVENTQEN) {
		unit.enabled = false
		return false
	}

	write64(STRTAB_BASE, u64(unit.l1_phys) & ADDR_MASK | STRTAB_BASE_RA)
	write32(STRTAB_BASE_CFG, STRTAB_FMT_2LEVEL | u32(STRTAB_SPLIT) << 6 | u32(unit.sid_bits))
	barrier()
	if !wait_ack(CR0_CMDQEN | CR0_EVENTQEN | CR0_SMMUEN) {
		unit.enabled = false
		return false
	}
	return true
}

// -- Attach and detach ------------------------------------------------------------------

/*
attach binds a stream to a space: section 3's four writes in its order. The
descriptor first, the entry naming it, the part told to drop its cached copy,
and only then the walker on the space's list. The unit's lock covers the
tables, and is dropped before the space's lock is taken. That is the order
`walker_invalidate` keeps from the other side, and it never inverts.

The handle answered is the slot, which `detach` and `space_gone` take back.
The caller keeps the space alive across the call.
*/
attach :: proc "contextless" (stream: u32, space: ^mem.Address_Space) -> (handle: int, err: Error) {
	if !unit.present || !unit.enabled {
		return -1, .Not_Present
	}
	if space == nil || stream >= u32(1) << uint(unit.sid_bits) {
		return -1, .Bad_Stream
	}
	slot := -1
	{
		guard := sync.acquire(&unit.lock)
		defer sync.release(&unit.lock, guard)
		if unit.broken {
			return -1, .Broken
		}
		for i in 0 ..< SLOTS {
			a := &unit.attaches[i]
			if a.used && a.stream == stream {
				return -1, .Busy
			}
			if !a.used && slot < 0 {
				slot = i
			}
		}
		if slot < 0 {
			return -1, .No_Memory
		}
		e, ok := ste(stream)
		if !ok {
			return -1, .No_Memory
		}
		a := &unit.attaches[slot]
		a.stream = stream
		a.space = space
		a.used = true
		a.orphaned = false
		a.invalidate = walker_invalidate
		a.detach = walker_detach
		a.clean = nil
		a.next = nil

		cd_fill(&unit.cds[slot], space.root, a.asid, unit.ips)
		barrier()
		cd := u64(unit.cd_phys) + u64(slot * CD_BYTES)
		if !ste_write(stream, e, STE_V | STE_CONFIG_S1 << STE_CONFIG_SHIFT | cd & ADDR_MASK, STE1_S1_WALK | STE1_SHCFG_INCOMING) {
			a.used = false
			a.space = nil
			return -1, .Broken
		}
		unit.attached += 1
		unit.generation += 1
	}
	mem.walker_attach(space, &unit.attaches[slot].w)
	return slot, .None
}

// attach_generation answers how many attaches there have ever been. A kernel
// driver whose device a program may have reset compares it with the count
// it last saw, section 8. A change brings the device up again on its own
// rings.
attach_generation :: proc "contextless" () -> u64 {
	return intrinsics.volatile_load(&unit.generation)
}

/*
detach is the reverse, section 3. The record comes off the space's list
first, if the space did not already take it. Then the entry goes to `abort`,
and the part drops the entry and every translation tagged with the ASID. The
slot is free only after the sync answers. A stream the space orphaned takes
the same path without touching the space, which is gone.

The caller keeps the space alive across the call when it is not orphaned,
the same rule `attach` has.
*/
detach :: proc "contextless" (handle: int) -> Error {
	if !unit.present {
		return .Not_Present
	}
	if handle < 0 || handle >= SLOTS {
		return .Bad_Handle
	}
	a := &unit.attaches[handle]
	space: ^mem.Address_Space
	{
		guard := sync.acquire(&unit.lock)
		defer sync.release(&unit.lock, guard)
		if !a.used {
			return .Bad_Handle
		}
		if !a.orphaned {
			space = a.space
		}
	}
	if space != nil {
		_ = mem.walker_detach(space, &a.w)
	}
	guard := sync.acquire(&unit.lock)
	defer sync.release(&unit.lock, guard)
	abort_stream(a)
	a.space = nil
	a.orphaned = false
	a.used = false
	unit.attached -= 1
	return unit.broken ? .Broken : .None
}

// abort_stream writes the entry as `abort` and drops the stream's translations.
// With the lock held. The record may or may not still be on a space's list.
@(private)
abort_stream :: proc "contextless" (a: ^Attach) {
	if e, ok := ste(a.stream); ok {
		_ = ste_write(a.stream, e, STE_V | STE_CONFIG_ABORT << STE_CONFIG_SHIFT, 0)
	}
	_ = issue(CMD_TLBI_NH_ASID | u64(a.asid) << 48, 0)
	_ = cmd_sync()
}

/*
stream_release gives a stream back to the kernel's own driver, section 8.
A stream a program held is `abort` after its detach, so a device still in
flight faults rather than reads a recycled frame. The kernel driver that
shares the device resets it, and only then, with nothing in flight, asks
here. An entry that is `abort` and that no attach holds goes back to
`bypass`, which is what the driver's physical addresses need. An entry a
program holds, or one never bypassed, is left as it is, and the answer says
whether the entry is bypass now.
*/
stream_release :: proc "contextless" (stream: u32) -> bool {
	if !unit.present || !unit.enabled {
		return false
	}
	guard := sync.acquire(&unit.lock)
	defer sync.release(&unit.lock, guard)
	for i in 0 ..< SLOTS {
		a := &unit.attaches[i]
		if a.used && a.stream == stream {
			return false
		}
	}
	valid, config := ste_state(stream)
	if valid && config == STE_CONFIG_BYPASS {
		return true
	}
	if !valid || config != STE_CONFIG_ABORT {
		return false
	}
	e, ok := ste(stream)
	if !ok {
		return false
	}
	return ste_write(stream, e, STE_V | STE_CONFIG_BYPASS << STE_CONFIG_SHIFT, STE1_SHCFG_INCOMING)
}

// stream_aborted answers whether a stream's entry is `abort`: attached once
// and given back, or taken by a space that died. For a self-test.
stream_aborted :: proc "contextless" (stream: u32) -> bool {
	if !unit.present {
		return false
	}
	guard := sync.acquire(&unit.lock)
	defer sync.release(&unit.lock, guard)
	valid, config := ste_state(stream)
	return valid && config == STE_CONFIG_ABORT
}

// stream_count answers how many stream ids the table holds, `2^sid_bits`, so
// a caller can refuse one past it before asking.
stream_count :: proc "contextless" () -> u32 {
	if !unit.present {
		return 0
	}
	return u32(1) << uint(unit.sid_bits)
}

// space_gone answers whether the attach's space died under it, section 6's
// `detached <slot> exit` line. A handle that names no attach answers false.
space_gone :: proc "contextless" (handle: int) -> bool {
	if handle < 0 || handle >= SLOTS {
		return false
	}
	guard := sync.acquire(&unit.lock)
	defer sync.release(&unit.lock, guard)
	a := &unit.attaches[handle]
	return a.used && a.orphaned
}

// stream_owned answers whether a program holds the stream, section 8's rule
// for `kernel/sd`: a disk a program attached is no longer the kernel's.
stream_owned :: proc "contextless" (stream: u32) -> bool {
	if !unit.present {
		return false
	}
	guard := sync.acquire(&unit.lock)
	defer sync.release(&unit.lock, guard)
	for i in 0 ..< SLOTS {
		a := &unit.attaches[i]
		if a.used && a.stream == stream {
			return true
		}
	}
	return false
}

// -- The walker's two procedures ---------------------------------------------------------

/*
walker_invalidate drops the stream's translations for a run of pages, one
`TLBI_NH_VA` per page or one `TLBI_NH_ASID` past sixteen, then `CMD_SYNC`.
Under `space.lock`, by `kernel/mem`, so it takes the unit's lock inside it
and never the other way round.
*/
@(private)
walker_invalidate :: proc "contextless" (w: ^mem.Walker, virt: uintptr, pages: int) {
	a := cast(^Attach)w
	guard := sync.acquire(&unit.lock)
	defer sync.release(&unit.lock, guard)
	if !a.used || unit.broken {
		return
	}
	asid := u64(a.asid) << 48
	if pages > INVALIDATE_BY_ASID_PAST {
		_ = issue(CMD_TLBI_NH_ASID | asid, 0)
	} else {
		for i in 0 ..< pages {
			va := u64(virt) + u64(i) * u64(mem.PAGE_SIZE)
			_ = issue(CMD_TLBI_NH_VA | asid, va & ~u64(mem.PAGE_SIZE - 1) | 1)
		}
	}
	_ = cmd_sync()
}

/*
walker_detach is `space_destroy`'s call, with the record already unlinked and
`space.lock` held. The space is going, so the stream goes to `abort` now,
before a table is freed. The slot is left for the program's own `detach` to
give back. It does not call `mem.walker_detach`, which would take the space's
lock again.
*/
@(private)
walker_detach :: proc "contextless" (w: ^mem.Walker) {
	a := cast(^Attach)w
	guard := sync.acquire(&unit.lock)
	defer sync.release(&unit.lock, guard)
	if !a.used {
		return
	}
	abort_stream(a)
	a.space = nil
	a.orphaned = true
	if unit.sink != nil {
		unit.sink(Event{kind = .Orphaned, stream = a.stream, handle = int(uintptr(a) - uintptr(&unit.attaches[0])) / size_of(Attach)})
	}
}

// -- What the rest of the kernel reads ----------------------------------------------------

present :: proc "contextless" () -> bool {
	return unit.present && unit.enabled
}

broken :: proc "contextless" () -> bool {
	return unit.broken
}

coherent :: proc "contextless" () -> bool {
	return unit.coherent
}

// The shared line numbers the node named, for the handler section 5 describes.
event_line :: proc "contextless" () -> int {
	return unit.eventq_spi
}

error_line :: proc "contextless" () -> int {
	return unit.gerror_spi
}
