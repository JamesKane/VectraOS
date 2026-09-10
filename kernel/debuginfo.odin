/*
The kernel's own debug table, and the names it puts on a backtrace.

`build.odin` writes `vectra.vxd` from the linked kernel, the same file it
writes beside every program (`docs/DEVTOOLS.md` section 6), and
`limine.conf` names it as a module. Limine loads it into memory before
`kmain` runs, so the panic screen can name an address from the first
instruction on, with no disk and no allocator. `sys/libdebug` reads it;
this file finds the module, keeps it, and corrects for the slide the
bootloader loaded the kernel at.

Bootloader memory is reclaimable, and the module lives in it. It is copied
into the heap once there is one, and read in place before then.
*/
package kernel

import "vsys:libdebug"
import "vsys:libodin"

// Where every kernel links, on every architecture: `kernel/link_*.ld`.
KERNEL_LINK_BASE :: u64(0xffff_ffff_8000_0000)

@(private = "file")
kdebug: libdebug.Debug
@(private = "file")
kdebug_ok: bool
@(private = "file")
kdebug_slide: u64

/*
debuginfo_init finds the module and opens it, where the bootloader put
it. `debuginfo_keep` then moves it onto the heap, before the bootloader's
memory is given back. Both are harmless when the module is missing, which is a
kernel with no names on its panic screen and nothing else.
*/
debuginfo_init :: proc "contextless" () {
	r := module_request.response
	if r == nil {
		return
	}
	for i in 0 ..< int(r.module_count) {
		f := r.modules[i]
		if f == nil || f.address == nil || !ends_with(string(f.path), "vectra.vxd") {
			continue
		}
		data := ([^]u8)(f.address)[:f.size]
		if d, ok := libdebug.open(data); ok {
			kdebug = d
			kdebug_ok = true
		}
		break
	}
	if boot_facts.has_layout {
		kdebug_slide = boot_facts.kernel_virt - KERNEL_LINK_BASE
	}
}

// debuginfo_keep copies the table onto the heap, so the bootloader's
// memory may go. Nothing to do when there is no table.
debuginfo_keep :: proc() {
	if !kdebug_ok {
		return
	}
	kept := make([]u8, len(kdebug.data))
	if kept == nil {
		kdebug_ok = false
		return
	}
	copy(kept, kdebug.data)
	if d, ok := libdebug.open(kept); ok {
		kdebug = d
	} else {
		kdebug_ok = false
	}
}

@(private = "file")
ends_with :: proc "contextless" (s, tail: string) -> bool {
	return len(s) >= len(tail) && s[len(s) - len(tail):] == tail
}

// debug_name names the kernel procedure a running address is inside, and
// how far into it. False with no table, or for an address outside every
// procedure.
debug_name :: proc "contextless" (addr: uintptr) -> (name: string, offset: u64, ok: bool) {
	if !kdebug_ok {
		return "", 0, false
	}
	linked := u64(addr) - kdebug_slide
	found_name, low, found := libdebug.proc_at(&kdebug, linked)
	if !found {
		return "", 0, false
	}
	return found_name, linked - low, true
}

// debug_line answers the source file and line a running kernel address
// was compiled from.
debug_line :: proc "contextless" (addr: uintptr) -> (file: string, line: u32, ok: bool) {
	if !kdebug_ok {
		return "", 0, false
	}
	return libdebug.line_at(&kdebug, u64(addr) - kdebug_slide)
}

// debug_address answers where a kernel procedure runs, by its full name.
debug_address :: proc "contextless" (name: string) -> (addr: uintptr, ok: bool) {
	if !kdebug_ok {
		return 0, false
	}
	low, _, found := libdebug.lookup(&kdebug, name)
	if !found {
		return 0, false
	}
	return uintptr(low + kdebug_slide), true
}

debuginfo_present :: proc "contextless" () -> bool {
	return kdebug_ok
}

debuginfo_procs :: proc "contextless" () -> int {
	if !kdebug_ok {
		return 0
	}
	return libdebug.count(&kdebug, .Procs)
}

/*
verify_debuginfo is the boot check `docs/DEVTOOLS.md` section 6 asks for.
The table is there, and a known procedure resolves by name to the address
it runs at. An address inside one names it, with a line of its file.
*/
verify_debuginfo :: proc() {
	result: libodin.Tally
	libodin.tally(&result, debuginfo_present(), "the kernel's debug table came with the boot")
	me := uintptr(rawptr(verify_debuginfo))
	addr, found := debug_address("kernel::verify_debuginfo")
	libodin.tally(&result, found && addr == me, "a procedure resolves by name to the address it runs at")
	name, off, named := debug_name(me + 8)
	libodin.tally(&result, named && name == "kernel::verify_debuginfo" && off == 8, "and an address inside one names it")
	file, line, lined := debug_line(me + 8)
	libodin.tally(&result, lined && ends_with(file, "kernel/debuginfo.odin") && line > 0, "with the line of this file it came from")

	sink := report_begin("debug", result.checks)
	if libodin.passed(result) {
		libodin.put_str(&sink, " ")
		libodin.put_uint(&sink, u64(debuginfo_procs()))
		libodin.put_str(&sink, " kernel procedures named by vectra.vxd, and a name resolves both ways")
		emit(&klog, .Ok, &sink)
		return
	}
	report_failed(&sink, result)
}
