/*
Vectra kernel entry point.

Boot order is load-bearing and deliberately short:

  1. arch.early_init  -- SSE on, before any Odin that touches a struct
  2. Odin runtime     -- globals initialised, @(init) blocks run
  3. serial           -- a sink that works even if step 4 does not
  4. base revision    -- confirm the bootloader honoured what we asked for
  5. framebuffer      -- the chassis, then the console inside it
  6. survey           -- report what the bootloader handed us

Steps 3 onward each degrade rather than fail: no serial port still boots, no
framebuffer still logs, and an unsupported base revision is reported rather
than assumed away.
*/
package kernel

import "base:runtime"

import "kernel:arch"
import "kernel:boot/limine"
import "kernel:drivers/console"
import "kernel:drivers/fb"
import "kernel:drivers/uart"
import "kernel:mem"
import "vsys:libodin"

VERSION :: "0.1.0-pre"

// -- Bootloader requests -----------------------------------------------------
//
// Every one of these MUST carry `link_section = ".limine_requests"`. Vectra
// asks for base revision 6, under which the request delimiters in
// `kernel/boot/limine/markers.odin` are binding rather than advisory: a
// request placed anywhere else in the image is never scanned, and its
// `response` silently stays nil.

@(export, link_section = ".limine_requests")
framebuffer_request := limine.Framebuffer_Request {
	id       = limine.FRAMEBUFFER_REQUEST,
	revision = 0,
}

@(export, link_section = ".limine_requests")
memmap_request := limine.Memmap_Request {
	id       = limine.MEMMAP_REQUEST,
	revision = 0,
}

@(export, link_section = ".limine_requests")
hhdm_request := limine.HHDM_Request {
	id       = limine.HHDM_REQUEST,
	revision = 0,
}

@(export, link_section = ".limine_requests")
executable_address_request := limine.Executable_Address_Request {
	id       = limine.EXECUTABLE_ADDRESS_REQUEST,
	revision = 0,
}

@(export, link_section = ".limine_requests")
bootloader_info_request := limine.Bootloader_Info_Request {
	id       = limine.BOOTLOADER_INFO_REQUEST,
	revision = 0,
}

@(export, link_section = ".limine_requests")
firmware_type_request := limine.Firmware_Type_Request {
	id       = limine.FIRMWARE_TYPE_REQUEST,
	revision = 0,
}

/*
Pin the paging mode rather than accepting whatever the firmware left on.

Limine will happily hand us 5-level paging on a machine that supports it, which
changes the shape of every page table walk and the position of the canonical
hole. Vectra's VMM will be written for one layout at a time; asking for exactly
4-level here means the day we add 5-level support is a deliberate change to
this request, not a machine-dependent surprise.
*/
@(export, link_section = ".limine_requests")
paging_mode_request := limine.Paging_Mode_Request {
	id       = limine.PAGING_MODE_REQUEST,
	revision = 0,
	mode     = limine.X86_64_PAGING_4LVL,
	max_mode = limine.X86_64_PAGING_4LVL,
	min_mode = limine.X86_64_PAGING_4LVL,
}

// -- Global kernel state -----------------------------------------------------
//
// Statically allocated because there is no allocator yet, and reachable from a
// fault handler because that is the point of a log.

serial: uart.Port
screen: fb.Surface
klog: Logger
kcon: console.Console

// The chassis rectangles, kept because the lamp row is drawn twice: once at
// framebuffer bring-up with MEM dark, and again once memory is actually up.
chassis: Chassis

// The memory map, translated out of Limine's vocabulary into one `kernel/mem`
// understands. Kept for the lifetime of the kernel because reclaiming the
// bootloader's memory later needs it, and it is the only copy that survives
// the reclaim.
boot_mem: mem.Boot_Memory

// Whether `mem.init` has completed. Read by the panic screen, which can ask the
// VMM what was mapped at a faulting address only once there is a VMM to ask.
memory_online: bool

@(export, link_name = "_start")
kmain :: proc "sysv" () {
	arch.early_init()

	// `context` must exist before any Odin call that can touch it. With
	// -default-to-nil-allocator this is an empty context: allocation faults
	// loudly instead of silently succeeding against a heap we do not have.
	context = {}
	#force_no_inline runtime._startup_runtime()

	serial = uart.init(uart.COM1)
	klog.serial = &serial
	uart.write_string(&serial, "\n\n")
	log_line(&klog, .Info, "Vectra " + VERSION + " (" + arch.NAME + ") entering kmain")

	check_base_revision()
	init_traps()

	if !init_screen() {
		log_line(&klog, .Warn, "no framebuffer from bootloader; serial only")
	}

	report_bootloader()
	report_paging_mode()
	report_kernel_layout()

	if !survey_memory() {
		panic_stop("cannot survey physical memory")
	}
	report_memory()
	if !init_memory() {
		panic_stop("cannot bring up memory management")
	}

	// From here on, ordinary Odin allocation works. Everything before this
	// point had to make do with static storage and the caller's buffer.
	context.allocator = mem.allocator()
	verify_memory()

	log_line(&klog, .Ok, "boot complete -- halting (no scheduler yet)")
	arch.halt_forever()
}

/*
check_base_revision verifies the bootloader honoured our request.

Two separate failures hide here. The bootloader may not support base revision 6
at all, in which case word 2 comes back unchanged and we are running under
whatever it picked. Or it may support it and still have loaded us as something
else -- word 1 tells us which. Both matter to code that assumes base revision 6
semantics, most of all the restrictive HHDM: under an older revision, more of
the memory map is HHDM-mapped than we would otherwise be entitled to touch, so
we would be building on a guarantee we do not actually have.

We report and continue. Nothing in Milestone 0 dereferences an HHDM address, so
this is a warning today and will become a hard stop the moment the VMM starts
trusting the map.
*/
check_base_revision :: proc "contextless" () {
	tag := &limine.base_revision_tag

	if !limine.base_revision_supported(tag) {
		sink := begin(&klog)
		libodin.put_str(&sink, "bootloader does not support base revision ")
		libodin.put_uint(&sink, limine.BASE_REVISION)
		emit(&klog, .Fault, &sink)
	}

	loaded, ok := limine.loaded_base_revision(tag)
	if !ok {
		log_line(&klog, .Warn, "bootloader predates base revision tags; assuming revision 0 semantics")
		return
	}

	sink := begin(&klog)
	libodin.put_str(&sink, "base revision ")
	libodin.put_uint(&sink, loaded)
	if loaded == limine.BASE_REVISION {
		libodin.put_str(&sink, " as requested")
		emit(&klog, .Ok, &sink)
		return
	}
	libodin.put_str(&sink, " granted, but ")
	libodin.put_uint(&sink, limine.BASE_REVISION)
	libodin.put_str(&sink, " was requested")
	emit(&klog, .Warn, &sink)
}

/*
init_traps installs the GDT, TSS and IDT, then proves they work.

The proof is a breakpoint the kernel raises on itself. It is the only exception
that can be armed, taken and resumed from, so it exercises the whole path end to
end -- the stub pushing the right vector, the tail building a frame the
dispatcher can read, the handler recognising it, and `iretq` landing back on the
instruction after the `int3`. Anything wrong anywhere in that chain shows up
here, three lines into the boot, rather than as an unexplained reset during
whatever is written next.

There is no graceful failure. If the IDT is wrong the `int3` triple faults and
the machine resets before the check below runs; if it is merely mis-wired the
check reports it and the boot goes on, because a kernel that cannot report
faults is still worth booting far enough to say so.
*/
init_traps :: proc "contextless" () {
	arch.init_traps()
	arch.set_trap_handler(panic_trap)

	arm_breakpoint_test()
	arch.breakpoint()

	cs := arch.code_selector()
	tr := arch.task_selector()
	vectors := u64(arch.idt_limit() + 1) / 16
	ok := cs == arch.KERNEL_CODE_SELECTOR && tr == arch.TASK_SELECTOR && breakpoint_test_fired()

	sink := begin(&klog)
	libodin.put_str(&sink, "traps: cs ")
	libodin.put_hex(&sink, u64(cs), 0)
	libodin.put_str(&sink, ", tr ")
	libodin.put_hex(&sink, u64(tr), 0)
	libodin.put_str(&sink, ", ")
	libodin.put_uint(&sink, vectors)
	libodin.put_str(&sink, " vectors, #BP round-trip ")
	libodin.put_str(&sink, breakpoint_test_fired() ? "ok" : "LOST")
	emit(&klog, ok ? .Ok : .Fault, &sink)
}

/*
init_screen brings up the chassis and the console inside it.

Returns false when the bootloader gave us no framebuffer, in which case the
logger keeps its serial sink and the screen sink stays nil.
*/
init_screen :: proc "contextless" () -> bool {
	response := framebuffer_request.response
	if response == nil || response.framebuffer_count == 0 {
		return false
	}

	screen = fb.from_limine(response.framebuffers[0])
	chassis = draw_chassis(&screen, "VECTRA", "BOOT " + VERSION)

	well := fb.inset_of(chassis.well, WELL_D + PAD / 2)
	kcon = console.init(&screen, well, fb.AMBER, fb.SLATE)

	// attach_screen rather than `klog.screen = &kcon`: everything logged
	// before this point -- the banner and the base revision handshake -- gets
	// replayed onto the console, so the screen carries the whole boot and not
	// just the part that happened after there was somewhere to draw it.
	attach_screen(&klog, &kcon)

	draw_lamps(memory = false)

	sink := begin(&klog)
	libodin.put_str(&sink, "framebuffer ")
	libodin.put_uint(&sink, u64(screen.width))
	libodin.put_str(&sink, "x")
	libodin.put_uint(&sink, u64(screen.height))
	libodin.put_str(&sink, " @ ")
	libodin.put_uint(&sink, u64(screen.bytes_pp * 8))
	libodin.put_str(&sink, "bpp, pitch ")
	libodin.put_uint(&sink, u64(screen.pitch))
	libodin.put_str(&sink, " -> ")
	libodin.put_ptr(&sink, rawptr(screen.pixels))
	emit(&klog, .Ok, &sink)

	sink = begin(&klog)
	libodin.put_str(&sink, "console ")
	libodin.put_uint(&sink, u64(kcon.cols))
	libodin.put_str(&sink, " cols x ")
	libodin.put_uint(&sink, u64(kcon.rows))
	libodin.put_str(&sink, " rows")
	emit(&klog, .Info, &sink)

	return true
}

/*
draw_lamps repaints the indicator strip.

Called twice: once from `init_screen` with the memory lamp dark, and again after
`mem.init` returns with it lit. Redrawing the whole row rather than the one lamp
that changed keeps the strip's layout in a single place -- the labels and their
spacing are computed by `draw_lamp_row`, and a caller that poked at one lamp
would have to duplicate that arithmetic to know where it was.
*/
draw_lamps :: proc "contextless" (memory: bool) {
	if screen.pixels == nil {
		return
	}
	draw_lamp_row(
		&screen,
		chassis.strip,
		{"PWR", "FB", "SER", "MEM"},
		{fb.PHOSPHOR, fb.CYAN, fb.AMBER, fb.PHOSPHOR},
		{true, true, serial.present, memory},
	)
}

report_bootloader :: proc "contextless" () {
	info := bootloader_info_request.response
	if info == nil {
		log_line(&klog, .Warn, "bootloader did not identify itself")
		return
	}

	sink := begin(&klog)
	libodin.put_str(&sink, "booted by ")
	libodin.put_str(&sink, string(info.name))
	libodin.put_str(&sink, " ")
	libodin.put_str(&sink, string(info.version))

	// Firmware type rides along on the same line: on its own it is one word,
	// and it is only ever interesting next to who booted us.
	if fw := firmware_type_request.response; fw != nil {
		libodin.put_str(&sink, " via ")
		switch fw.firmware_type {
		case .X86_BIOS: libodin.put_str(&sink, "legacy BIOS")
		case .EFI32:    libodin.put_str(&sink, "UEFI (32-bit)")
		case .EFI64:    libodin.put_str(&sink, "UEFI (64-bit)")
		case .SBI:      libodin.put_str(&sink, "SBI")
		case:           libodin.put_str(&sink, "unknown firmware")
		}
	}
	emit(&klog, .Info, &sink)
}

/*
report_paging_mode confirms we got the paging layout we pinned.

Limine clamps to what the hardware supports, so a mismatch here is not a
bootloader bug -- it means the VMM about to be written would be walking a
different number of levels than it was designed for.
*/
report_paging_mode :: proc "contextless" () {
	response := paging_mode_request.response
	if response == nil {
		log_line(&klog, .Warn, "no paging mode response; layout is whatever the firmware left")
		return
	}

	sink := begin(&klog)
	libodin.put_str(&sink, "paging ")
	switch response.mode {
	case limine.X86_64_PAGING_4LVL: libodin.put_str(&sink, "4-level")
	case limine.X86_64_PAGING_5LVL: libodin.put_str(&sink, "5-level (LA57)")
	case:
		libodin.put_str(&sink, "mode ")
		libodin.put_uint(&sink, response.mode)
	}

	if response.mode == paging_mode_request.mode {
		emit(&klog, .Ok, &sink)
		return
	}
	libodin.put_str(&sink, " -- not the mode requested")
	emit(&klog, .Warn, &sink)
}

report_kernel_layout :: proc "contextless" () {
	if addr := executable_address_request.response; addr != nil {
		sink := begin(&klog)
		libodin.put_str(&sink, "kernel phys ")
		libodin.put_hex(&sink, addr.physical_base, 16)
		libodin.put_str(&sink, " virt ")
		libodin.put_hex(&sink, addr.virtual_base, 16)
		emit(&klog, .Info, &sink)
	}

	if hhdm := hhdm_request.response; hhdm != nil {
		sink := begin(&klog)
		libodin.put_str(&sink, "hhdm offset ")
		libodin.put_hex(&sink, hhdm.offset, 16)
		emit(&klog, .Info, &sink)
	}
}

/*
survey_memory translates Limine's memory map into `kernel/mem`'s vocabulary.

This is the only place in Vectra that knows both, and it exists so that nothing
below it knows either: `kernel/mem` is handed a `Boot_Memory` and never learns
which bootloader filled it in. Booting some other way -- a different protocol, a
hypervisor handing over directly -- means rewriting this one procedure.

The three responses read here are not optional the way the rest of the survey
is. Without a memory map there is nothing to allocate from, and without the HHDM
offset or the load address there is no way to reach it or to rebuild the
kernel's own mapping. Each missing one is fatal and says so.
*/
survey_memory :: proc "contextless" () -> bool #no_bounds_check {
	memmap := memmap_request.response
	if memmap == nil {
		log_line(&klog, .Fault, "no memory map -- cannot bring up the PMM")
		return false
	}
	hhdm := hhdm_request.response
	if hhdm == nil {
		log_line(&klog, .Fault, "no HHDM offset -- cannot reach physical memory")
		return false
	}
	addr := executable_address_request.response
	if addr == nil {
		log_line(&klog, .Fault, "no executable address -- cannot map the kernel image")
		return false
	}

	boot_mem.hhdm = hhdm.offset
	boot_mem.kernel_phys = addr.physical_base
	boot_mem.kernel_virt = addr.virtual_base

	for i in 0 ..< memmap.entry_count {
		entry := memmap.entries[i]
		mem.add_region(&boot_mem, entry.base, entry.length, region_kind(entry.type))
	}

	/*
	The framebuffer, if the map did not already account for it.

	Base revision 6 guarantees the framebuffer is in the direct map; it does not
	guarantee the firmware described it as a memory map entry, and OVMF is not
	consistent about it. Discovering the difference the hard way means the VMM
	builds an address space with no framebuffer in it, and the machine dies on
	the first character drawn after the switch -- with the console being the
	thing that would have said so.
	*/
	if response := framebuffer_request.response; response != nil && response.framebuffer_count > 0 {
		f := response.framebuffers[0]
		base := u64(uintptr(f.address)) - hhdm.offset
		length := f.pitch * f.height
		if !mem.covers(&boot_mem, base, length) {
			mem.add_region(&boot_mem, base, length, .Framebuffer)
			log_line(&klog, .Warn, "framebuffer absent from the memory map; added by hand")
		}
	}

	if boot_mem.dropped > 0 {
		sink := begin(&klog)
		libodin.put_str(&sink, "memory map has more than ")
		libodin.put_uint(&sink, mem.MAX_REGIONS)
		libodin.put_str(&sink, " entries; ")
		libodin.put_uint(&sink, u64(boot_mem.dropped))
		libodin.put_str(&sink, " dropped")
		emit(&klog, .Fault, &sink)
		return false
	}
	return true
}

/*
region_kind maps a Limine memory type onto what the kernel may do with it.

Reserved and bad memory both collapse to `.Unmapped`: the distinction matters to
firmware and to a diagnostic tool, but to a kernel that will neither allocate
from them nor place them in the direct map they are the same thing.
*/
region_kind :: proc "contextless" (type: limine.Memmap_Type) -> mem.Region_Kind {
	switch type {
	case .Usable:                 return .Usable
	case .Bootloader_Reclaimable: return .Reclaimable
	case .Executable_And_Modules: return .Executable
	case .Framebuffer:            return .Framebuffer
	case .ACPI_Reclaimable:       return .ACPI_Reclaimable
	case .ACPI_NVS:               return .ACPI_NVS
	case .Reserved_Mapped:        return .Reserved_Mapped
	case .Reserved, .Bad_Memory:  return .Unmapped
	}
	return .Unmapped
}

/*
report_memory summarises the surveyed map.

Only the totals and the largest usable region are printed: a full dump is
twenty-odd lines that push everything else off the screen, and once the PMM is
up its own figures are the ones worth reading.
*/
report_memory :: proc "contextless" () {
	usable, reclaimable, total: u64
	largest_base, largest_len: u64

	for r in mem.regions(&boot_mem) {
		total += r.length
		#partial switch r.kind {
		case .Usable:
			usable += r.length
			if r.length > largest_len {
				largest_len = r.length
				largest_base = r.base
			}
		case .Reclaimable:
			reclaimable += r.length
		}
	}

	sink := begin(&klog)
	libodin.put_str(&sink, "memory map: ")
	libodin.put_uint(&sink, u64(boot_mem.region_count))
	libodin.put_str(&sink, " entries spanning ")
	libodin.put_size(&sink, total)
	emit(&klog, .Info, &sink)

	sink = begin(&klog)
	libodin.put_str(&sink, "usable ")
	libodin.put_size(&sink, usable)
	libodin.put_str(&sink, ", reclaimable ")
	libodin.put_size(&sink, reclaimable)
	emit(&klog, .Ok, &sink)

	sink = begin(&klog)
	libodin.put_str(&sink, "largest usable region ")
	libodin.put_size(&sink, largest_len)
	libodin.put_str(&sink, " at ")
	libodin.put_hex(&sink, largest_base, 16)
	emit(&klog, .Info, &sink)
}

/*
init_memory brings up all three memory layers and reports what each one built.

The address space switch happens inside `mem.init`, between the second and third
lines logged here. That the fourth line reaches the screen at all is the proof
that the new tables cover the framebuffer, the kernel image and the stack --
which is worth more than any check that could be written for it, because a
kernel that got that wrong would not survive to print a failure.
*/
init_memory :: proc "contextless" () -> bool {
	if err := mem.init(&boot_mem); err != .None {
		sink := begin(&klog)
		libodin.put_str(&sink, "memory bring-up failed: ")
		libodin.put_str(&sink, mem.describe(err))
		emit(&klog, .Fault, &sink)
		return false
	}

	pmm := mem.pmm_stats()
	sink := begin(&klog)
	libodin.put_str(&sink, "pmm ")
	libodin.put_uint(&sink, u64(pmm.usable_frames))
	libodin.put_str(&sink, " frames free of ")
	libodin.put_uint(&sink, u64(pmm.total_frames))
	libodin.put_str(&sink, " tracked, bitmap ")
	libodin.put_size(&sink, u64(pmm.bitmap_bytes))
	libodin.put_str(&sink, " at ")
	libodin.put_hex(&sink, u64(pmm.bitmap_phys), 16)
	emit(&klog, .Ok, &sink)

	vmm := mem.vmm_stats()
	sink = begin(&klog)
	libodin.put_str(&sink, "vmm root ")
	libodin.put_hex(&sink, u64(vmm.root), 16)
	libodin.put_str(&sink, ", mapped ")
	libodin.put_size(&sink, vmm.mapped_bytes)
	libodin.put_str(&sink, " in ")
	libodin.put_uint(&sink, u64(vmm.table_frames))
	libodin.put_str(&sink, " tables (")
	libodin.put_size(&sink, u64(vmm.table_frames) * mem.PAGE_SIZE)
	libodin.put_str(&sink, ")")
	emit(&klog, .Ok, &sink)

	sink = begin(&klog)
	libodin.put_str(&sink, "vmm nx ")
	libodin.put_str(&sink, vmm.nx ? "on" : "off")
	libodin.put_str(&sink, ", global pages ")
	libodin.put_str(&sink, vmm.global ? "on" : "off")
	libodin.put_str(&sink, ", largest leaf ")
	libodin.put_size(&sink, u64(1) << uint(12 + 9 * (vmm.max_leaf - 1)))
	emit(&klog, .Info, &sink)

	log_line(&klog, .Ok, "heap online -- context.allocator is live")
	memory_online = true
	draw_lamps(memory = true)
	return true
}

/*
verify_memory exercises each layer once, on the machine that will run it.

Not a substitute for tests, which there is nowhere to run. It is here because
the three ways this subsystem fails are all silent at the point of failure: a
PMM that hands the same frame out twice, a page table that translates to the
wrong place, and an allocator that is installed but hands back memory nobody
owns. Each of those surfaces much later as a corrupted structure with no trail
back. A dozen lines at boot turns all three into one line in the log.
*/
verify_memory :: proc() {
	ok := true

	// PMM: two allocations are distinct, and a freed frame is reused. The
	// reuse is a real invariant, not luck -- `free_pages` aims the search hint
	// back at whatever it just released.
	first, first_ok := mem.alloc_page()
	second, second_ok := mem.alloc_page()
	ok = ok && first_ok && second_ok && first != second

	mem.free_page(second)
	again, again_ok := mem.alloc_page()
	ok = ok && again_ok && again == second
	mem.free_page(again)
	mem.free_page(first)

	// VMM: walking our own tables for a kernel global has to land on the
	// physical address the bootloader loaded it at, and the direct map has to
	// agree with itself.
	space := mem.kernel_address_space()
	global_virt := uintptr(&klog)
	expect := uintptr(boot_mem.kernel_phys + (u64(global_virt) - boot_mem.kernel_virt))
	found, found_ok := mem.translate(space, global_virt)
	ok = ok && found_ok && found == expect

	direct, direct_ok := mem.translate(space, uintptr(mem.phys_to_virt(expect)))
	ok = ok && direct_ok && direct == expect

	// And the segment permissions the linker script implied are the ones the
	// hardware will actually enforce -- read back out of the tables rather than
	// taken on trust from the code that wrote them.
	ok = ok && mem.vmm_verify()

	// Heap, through Odin's own interface: if `make` works, so does every core
	// container built on it. Written and read back because an allocator that
	// returns overlapping blocks passes every check that does not touch them.
	sample := make([]u32, 4096)
	ok = ok && sample != nil
	if sample != nil {
		for i in 0 ..< len(sample) {
			sample[i] = u32(i) * 2654435761
		}
		for i in 0 ..< len(sample) {
			ok = ok && sample[i] == u32(i) * 2654435761
		}
		delete(sample)
	}

	// An over-aligned allocation, which is the case the block header exists to
	// make possible at all.
	aligned, aligned_ok := mem.alloc(64, 256)
	ok = ok && aligned_ok && uintptr(aligned) & 255 == 0
	mem.free(aligned)

	heap := mem.heap_stats()
	sink := begin(&klog)
	libodin.put_str(&sink, "memory self-test ")
	libodin.put_str(&sink, ok ? "passed" : "FAILED")
	libodin.put_str(&sink, " -- ")
	libodin.put_uint(&sink, u64(heap.slab_frames))
	libodin.put_str(&sink, " slab pages, ")
	libodin.put_uint(&sink, u64(heap.large_blocks))
	libodin.put_str(&sink, " large blocks live")
	emit(&klog, ok ? .Ok : .Fault, &sink)
}
