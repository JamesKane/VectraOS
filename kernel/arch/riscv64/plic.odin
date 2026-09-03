/*
The platform-level interrupt controller -- how a device interrupt reaches a
hart here.

Every device line is a *source*, numbered from 1, with a priority. Every
hart has a *context* per privilege level, with an enable bit per source, a
threshold, and a claim register: reading it answers the highest-priority
pending source and marks it in service, and writing the number back
completes it. The `virt` board's PLIC is at `0x0C00_0000`, with hart `h`'s
supervisor context numbered `2h + 1`.

Nothing here locks. Routing happens once per device during boot, before the
line it routes is unmasked. The claim and the complete are per hart by
construction.

The base address is assumed rather than discovered, as the other two
controllers' are. The device tree says, and the day something reads it for
this is the day `early.odin` grows a second lookup.
*/
package riscv64

import "base:intrinsics"

PLIC_PHYS :: uintptr(0x0C00_0000)

// Far enough to cover the supervisor context of the eighth hart.
PLIC_MMIO_SIZE :: u64(0x21_0000)

PLIC_PRIORITY :: uintptr(0x0000)   // One word per source
PLIC_ENABLE :: uintptr(0x2000)     // One bit per source, 0x80 bytes per context
PLIC_CONTEXT :: uintptr(0x20_0000) // Threshold, then claim/complete, 0x1000 per context

PLIC_SOURCES :: 96

@(private = "file") mmio: rawptr

// The hart each source is routed to, so masking finds the right context.
@(private = "file") targets: [PLIC_SOURCES]u64

@(private = "file")
plic_read :: proc "contextless" (offset: uintptr) -> u32 {
	return intrinsics.volatile_load(cast(^u32)(uintptr(mmio) + offset))
}

@(private = "file")
plic_write :: proc "contextless" (offset: uintptr, value: u32) {
	intrinsics.volatile_store(cast(^u32)(uintptr(mmio) + offset), value)
}

@(private = "file")
context_of :: proc "contextless" (hart: u64) -> uintptr {
	return uintptr(2 * hart + 1)
}

plic_physical_base :: proc "contextless" () -> uintptr {
	return PLIC_PHYS
}

/*
plic_attach takes the mapped register pages and masks every source.

Every source gets priority 1, so a source that is enabled is a source that
can be claimed, and every context this kernel might use gets threshold 0,
so priority 1 clears it. What decides whether a line delivers is then its
enable bit alone, which is what `plic_set_mask` flips.
*/
plic_attach :: proc "contextless" (virt: rawptr) {
	mmio = virt
	for source in 1 ..< PLIC_SOURCES {
		plic_write(PLIC_PRIORITY + uintptr(source) * 4, 1)
	}
	for hart in u64(0) ..< PERCPU_MAX {
		ctx := context_of(hart)
		for word in uintptr(0) ..< (PLIC_SOURCES + 31) / 32 {
			plic_write(PLIC_ENABLE + ctx * 0x80 + word * 4, 0)
		}
		plic_write(PLIC_CONTEXT + ctx * 0x1000, 0)
	}
}

plic_attached :: proc "contextless" () -> bool {
	return mmio != nil
}

plic_available :: proc "contextless" () -> bool {
	return mmio != nil
}

plic_lines :: proc "contextless" () -> int {
	return mmio == nil ? 0 : PLIC_SOURCES
}

plic_version :: proc "contextless" () -> u32 {
	return 0
}

@(private = "file")
source_valid :: proc "contextless" (gsi: int) -> bool {
	return mmio != nil && gsi > 0 && gsi < PLIC_SOURCES
}

// plic_route aims one source at one hart and leaves it masked.
plic_route :: proc "contextless" (gsi: int, vector: u8, hart: u32) #no_bounds_check {
	_ = vector
	if !source_valid(gsi) {
		return
	}
	targets[gsi] = u64(hart)
}

plic_set_mask :: proc "contextless" (gsi: int, masked: bool) #no_bounds_check {
	if !source_valid(gsi) {
		return
	}
	ctx := context_of(targets[gsi])
	word := PLIC_ENABLE + ctx * 0x80 + uintptr(gsi / 32) * 4
	bit := u32(1) << u32(gsi % 32)
	v := plic_read(word)
	if masked {
		v &~= bit
	} else {
		v |= bit
	}
	plic_write(word, v)
}

plic_masked :: proc "contextless" (gsi: int) -> bool #no_bounds_check {
	if !source_valid(gsi) {
		return true
	}
	ctx := context_of(targets[gsi])
	word := PLIC_ENABLE + ctx * 0x80 + uintptr(gsi / 32) * 4
	return plic_read(word) & (u32(1) << u32(gsi % 32)) == 0
}

plic_vector_of :: proc "contextless" (gsi: int) -> u8 {
	if !source_valid(gsi) {
		return 0
	}
	return u8(VECTOR_IRQ_BASE + gsi)
}

// plic_claim takes the pending source for this hart, or zero for none.
plic_claim :: proc "contextless" () -> u32 {
	if mmio == nil {
		return 0
	}
	return plic_read(PLIC_CONTEXT + context_of(percpu_hart()) * 0x1000 + 4)
}

plic_complete :: proc "contextless" (source: u32) {
	if mmio != nil && source != 0 {
		plic_write(PLIC_CONTEXT + context_of(percpu_hart()) * 0x1000 + 4, source)
	}
}
