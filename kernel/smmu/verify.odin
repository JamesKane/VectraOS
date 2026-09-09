/*
The ring 0 self-test, `docs/SMMU.md` section 10. The id registers answer what
section 1 requires, a sync completes, and an entry nobody attached is invalid.
A stream attached to a fresh space is told, orphaned and given back, with the
entry in the state each step says.

No device drives a transaction through the entry here. That is `blkfs`'s half,
the two proofs of `docs/HARDWARE.md` step 0, and the negative control they
need. What this can see from ring 0 is the tables and the queue, and it reads
them back rather than trusts the writes.
*/
package smmu

import "kernel:arch"
import "kernel:mem"
import "vsys:libodin"

Result :: struct {
	using tally: libodin.Tally,
	commands:    u64,
}

@(private = "file")
check :: proc "contextless" (r: ^Result, ok: bool, what: string) -> bool {
	return libodin.tally(&r.tally, ok, what)
}

// A stream no function on `virt` has: bus 0, device 31, function 7.
@(private = "file")
NOBODY :: u32(0xFF)
// A stream the test attaches: bus 0, device 31, function 0, under the block
// the scan already allocated, so no frame is spent on it.
@(private = "file")
TEST_STREAM :: u32(0xF8)
@(private = "file")
USER_VA :: uintptr(0x2000_0000)

verify :: proc "contextless" () -> Result {
	r: Result
	if !check(&r, unit.present && unit.enabled, "the part is present and enabled") {
		return r
	}

	// -- The id registers ---------------------------------------------------------------
	ttf := (unit.idr0 >> IDR0_TTF_SHIFT) & 3
	check(&r, unit.idr0 & IDR0_S1P != 0 && ttf & 2 != 0, "the part answers stage 1 in the AArch64 format")
	check(&r, unit.idr5 & IDR5_GRAN4K != 0, "and the 4 KiB granule")
	check(&r, (unit.idr0 >> IDR0_STLEVEL_SHIFT) & 3 == 1 && unit.sid_bits >= STRTAB_SPLIT, "and a two-level stream table")
	check(&r, (unit.idr0 & IDR0_COHACC != 0) == unit.coherent, "and its walks snoop as the node's dma-coherent says")
	check(&r, read32(CR0ACK) == CR0_SMMUEN | CR0_EVENTQEN | CR0_CMDQEN, "CR0ACK says the part and both queues are enabled")

	// -- The command queue ------------------------------------------------------------
	{
		guard := sync_acquire()
		before := unit.commands
		ok := cmd_sync()
		sync_release(guard)
		check(&r, ok && unit.commands == before + 1, "a CMD_SYNC completes")
	}
	check(&r, !gerror_pending() && !unit.broken, "and the error register is clean")

	// -- Entries nobody attached ------------------------------------------------------
	valid, config := ste_state(NOBODY)
	check(&r, !valid, "a stream nobody attached is invalid")
	valid, config = ste_state(0)
	check(&r, valid && config == STE_CONFIG_BYPASS, "and the host bridge the scan found is in bypass")
	check(&r, !stream_owned(0), "which no program owns")

	// -- An attach ---------------------------------------------------------------------
	free_before := mem.pmm_stats().free_frames
	space, err := mem.space_new()
	if !check(&r, err == .None && space != nil, "a fresh space is built to attach") {
		return r
	}
	handle, aerr := attach(TEST_STREAM, space)
	if !check(&r, aerr == .None && handle >= 0, "a stream attaches to it") {
		mem.space_destroy(space)
		return r
	}
	valid, config = ste_state(TEST_STREAM)
	check(&r, valid && config == STE_CONFIG_S1, "and its entry reads back as stage 1 translate")
	cd := &unit.cds[handle]
	check(&r, cd[0] >> 31 & 1 == 1 && u16(cd[0] >> 48) == unit.attaches[handle].asid, "the descriptor is valid and carries the attach's own ASID")
	check(&r, cd[1] & 0x000F_FFFF_FFFF_FFF0 == u64(space.root), "and names the space's root")
	check(&r, mem.walker_count(space) == 1, "and the space counts one walker")
	check(&r, stream_owned(TEST_STREAM), "and a program owns the stream")
	_, again := attach(TEST_STREAM, space)
	check(&r, again == .Busy, "a second attach of the same stream is refused as busy")

	// -- The walker told -----------------------------------------------------------------
	frame, got := mem.alloc_page_zeroed()
	if check(&r, got, "a frame to map under the walker") {
		flags := arch.Page_Flags{.Write, .No_Execute}
		before := unit.commands
		check(&r, mem.map_user(space, USER_VA, frame, flags, 1) == .None, "maps")
		check(&r, unit.commands == before, "and a mapping that widens issues no command")
		check(&r, mem.unmap_user(space, USER_VA, 1) == .None, "an unmap")
		check(&r, unit.commands == before + 2, "issues one TLBI_NH_VA and one CMD_SYNC")
		mem.free_page(frame)
	}

	// -- A detach ----------------------------------------------------------------------
	check(&r, detach(handle) == .None, "the stream detaches")
	valid, config = ste_state(TEST_STREAM)
	check(&r, valid && config == STE_CONFIG_ABORT, "and its entry reads back as abort")
	check(&r, mem.walker_count(space) == 0, "and the space counts no walker")
	check(&r, !stream_owned(TEST_STREAM), "and nobody owns the stream")
	check(&r, detach(handle) == .Bad_Handle, "a second detach names no attach")

	// -- The space dying first ----------------------------------------------------------
	handle, aerr = attach(TEST_STREAM, space)
	if check(&r, aerr == .None, "the stream attaches again") {
		mem.space_destroy(space)
		space = nil
		check(&r, space_gone(handle), "and a space destroyed under it orphans the attach")
		valid, config = ste_state(TEST_STREAM)
		check(&r, valid && config == STE_CONFIG_ABORT, "with the entry already abort")
		check(&r, stream_owned(TEST_STREAM), "and the slot still held until the program gives it back")
		check(&r, detach(handle) == .None, "which it does")
		check(&r, !space_gone(handle), "and the slot is free")
	}
	if space != nil {
		mem.space_destroy(space)
	}
	check(&r, mem.pmm_stats().free_frames == free_before, "and every frame comes back")
	check(&r, !unit.broken && !gerror_pending(), "with the part still whole")

	r.commands = unit.commands
	return r
}
