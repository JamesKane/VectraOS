/*
The PCI bus: what is on it, and where each thing's registers are.

Configuration space is the one thing every PCI function has: 256 bytes of
registers at a bus, device and function number, holding a vendor id, a
class, up to six base address registers that say where the function's
memory is, and a list of capabilities. The architecture reaches it through
ports on a PC and through a memory window on the boards; this package reads
it the same way on all three, and answers the two questions a driver asks.
Which functions are here, and where is this one's BAR n.

## What is assumed

That the firmware has already assigned every BAR. It has: the firmware
that loaded this kernel read it off a disk on this bus. A BAR that reads
zero is reported as unassigned rather than given an address, because the
board's windows are the next thing this kernel would have to know, and
nothing needs it yet.

That the devices are on bus 0. The `virt` boards have one root bus and no
bridges, and q35 puts what `-device` adds on its root bus. `scan` looks at
bus 0 and says how many functions it found; a bridge's secondary bus would
be a recursion here.

Nothing locks, for the reason `kernel/arch/amd64/pci.odin` gives: the bus
is read at boot on one core.
*/
package pci

import "kernel:arch"

// A function's address on the bus.
Address :: struct {
	bus: u8,
	dev: u8,
	fn:  u8,
}

// What the header says about a function.
Device :: struct {
	at:       Address,
	vendor:   u16,
	device:   u16,
	class:    u8,
	subclass: u8,
	prog_if:  u8,
	header:   u8, // Header type, without the multi-function bit
}

// Where a function's registers are.
Bar :: struct {
	phys:  uintptr,
	size:  u64,
	io:    bool, // A port range rather than memory
	wide:  bool, // 64 bits, occupying this BAR and the next
}

// Header registers.
VENDOR_ID :: u16(0x00)
COMMAND :: u16(0x04)
CLASS :: u16(0x08)
HEADER_TYPE :: u16(0x0C)
BAR0 :: u16(0x10)
SUBSYSTEM_ID :: u16(0x2C)
CAPABILITIES :: u16(0x34)

HEADER_MULTI_FUNCTION :: u8(0x80)

// Command bits.
COMMAND_IO :: u16(1 << 0)
COMMAND_MEMORY :: u16(1 << 1)
COMMAND_BUS_MASTER :: u16(1 << 2)

// Capability ids.
CAP_VENDOR :: u8(0x09)

NO_DEVICE :: u16(0xFFFF)

read32 :: proc "contextless" (at: Address, offset: u16) -> u32 {
	return arch.pci_read32(at.bus, at.dev, at.fn, offset)
}

write32 :: proc "contextless" (at: Address, offset: u16, value: u32) {
	arch.pci_write32(at.bus, at.dev, at.fn, offset, value)
}

// read16 and read8 pick their bytes out of the aligned word.
read16 :: proc "contextless" (at: Address, offset: u16) -> u16 {
	return u16(read32(at, offset) >> (8 * uint(offset & 2)))
}

read8 :: proc "contextless" (at: Address, offset: u16) -> u8 {
	return u8(read32(at, offset) >> (8 * uint(offset & 3)))
}

write16 :: proc "contextless" (at: Address, offset: u16, value: u16) {
	shift := 8 * uint(offset & 2)
	word := read32(at, offset) & ~(u32(0xFFFF) << shift)
	write32(at, offset, word | u32(value) << shift)
}

// present reports whether anything answers at `at`.
present :: proc "contextless" (at: Address) -> bool {
	return read16(at, VENDOR_ID) != NO_DEVICE
}

// describe reads a function's header into a Device.
describe :: proc "contextless" (at: Address) -> Device {
	id := read32(at, VENDOR_ID)
	class := read32(at, CLASS)
	return Device {
		at       = at,
		vendor   = u16(id),
		device   = u16(id >> 16),
		class    = u8(class >> 24),
		subclass = u8(class >> 16),
		prog_if  = u8(class >> 8),
		header   = read8(at, HEADER_TYPE) & ~HEADER_MULTI_FUNCTION,
	}
}

/*
scan lists the functions on bus 0 into `out`, in address order, and answers
how many there were, which may be more than `out` holds. A device whose
header says single-function has its other seven skipped, because a
single-function device answers for all eight and would be listed eight
times.
*/
scan :: proc "contextless" (out: []Device) -> int {
	if !arch.pci_available() {
		return 0
	}
	n := 0
	for dev in 0 ..< 32 {
		at := Address{bus = 0, dev = u8(dev)}
		if !present(at) {
			continue
		}
		functions := read8(at, HEADER_TYPE) & HEADER_MULTI_FUNCTION != 0 ? 8 : 1
		for fn in 0 ..< functions {
			at.fn = u8(fn)
			if !present(at) {
				continue
			}
			if n < len(out) {
				out[n] = describe(at)
			}
			n += 1
		}
	}
	return n
}

/*
bar reads base address register `index` and measures it.

The size is found the way the specification says and every operating
system does: write all ones, read back which bits stayed writable, and put
the address back. Memory decoding is off for the duration, so a device does
not answer at the all-ones address in between. A 64-bit BAR is this one and
the next, and the next is then not a BAR of its own, which is what `wide`
tells a caller stepping through them.

An unassigned BAR answers `ok` false, as does an index that is not a BAR.
*/
bar :: proc "contextless" (at: Address, index: int) -> (b: Bar, ok: bool) {
	if index < 0 || index > 5 {
		return
	}
	offset := BAR0 + u16(index) * 4
	low := read32(at, offset)
	if low == 0 {
		return
	}
	b.io = low & 1 != 0
	b.wide = !b.io && (low >> 1) & 3 == 2
	mask := b.io ? u32(0xFFFF_FFFC) : u32(0xFFFF_FFF0)

	command := read16(at, COMMAND)
	write16(at, COMMAND, command & ~(COMMAND_IO | COMMAND_MEMORY))
	defer write16(at, COMMAND, command)

	write32(at, offset, 0xFFFF_FFFF)
	probe := read32(at, offset) & mask
	write32(at, offset, low)

	b.phys = uintptr(low & mask)
	if b.wide {
		high := read32(at, offset + 4)
		write32(at, offset + 4, 0xFFFF_FFFF)
		probe_high := read32(at, offset + 4)
		write32(at, offset + 4, high)
		b.phys |= uintptr(high) << 32
		b.size = ~(u64(probe_high) << 32 | u64(probe)) + 1
	} else {
		// A 32-bit BAR's high bits are all one, so the complement measures
		// the low half and the range never exceeds 4 GiB.
		b.size = u64(~probe) + 1
	}
	return b, b.phys != 0 && b.size != 0
}

// enable lets a function decode memory accesses and issue its own, which a
// virtio device does for every ring it reads.
enable :: proc "contextless" (at: Address) {
	command := read16(at, COMMAND)
	write16(at, COMMAND, command | COMMAND_MEMORY | COMMAND_BUS_MASTER)
}

/*
Capabilities: a linked list in configuration space, each a byte of id, a
byte of next pointer, and the capability's own registers after. `first_cap`
is the head from the header; a pointer of zero ends the list.
*/
first_cap :: proc "contextless" (at: Address) -> u8 {
	return read8(at, CAPABILITIES) & 0xFC
}

next_cap :: proc "contextless" (at: Address, cap: u8) -> u8 {
	return read8(at, u16(cap) + 1) & 0xFC
}

cap_id :: proc "contextless" (at: Address, cap: u8) -> u8 {
	return read8(at, u16(cap))
}
