/*
Vectra kernel entry point.

Boot order is load-bearing and deliberately short:

  1. arch.early_init  -- the vector unit on, before any Odin that touches a struct
  2. Odin runtime     -- globals initialised, @(init) blocks run
  3. serial           -- a sink that works even if step 4 does not
  4. base revision    -- confirm the bootloader honoured what we asked for
  5. framebuffer      -- the chassis, then the console inside it
  6. survey           -- report what the bootloader handed us

Steps 3 onward each degrade rather than fail. No serial port still boots. No
framebuffer still logs. An unsupported base revision gets reported, rather than
assumed away.
*/
package kernel

import "base:runtime"

import "kernel:arch"
import "kernel:boot/limine"
import "kernel:devfs"
import "kernel:env"
import "kernel:drivers/console"
import "kernel:drivers/kbd"
import "kernel:drivers/fb"
import "kernel:drivers/uart"
import "kernel:mem"
import "kernel:pipe"
import "kernel:procfs"
import "kernel:sched"
import "kernel:srv"
import "kernel:sync"
import "kernel:user"
import "kernel:vfs"
import "vsys:libodin"
import "vsys:vectra9"

VERSION :: "0.1.0-pre"

// -- Bootloader requests -----------------------------------------------------
//
// Every one of these MUST carry `link_section = ".limine_requests"`. Vectra
// asks for base revision 6. Under that revision, the request delimiters in
// `kernel/boot/limine/markers.odin` are binding rather than advisory. Nothing
// scans a request placed anywhere else in the image, and its `response`
// silently stays nil.

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

Limine will happily hand over 5-level paging on a machine that supports it.
That changes the shape of every page table walk, and the position of the
canonical hole. Vectra's VMM is written for one layout at a time. A request for
exactly the one mode each architecture pins makes the day another arrives a
deliberate change to that file, rather than a machine-dependent surprise.
*/
@(export, link_section = ".limine_requests")
paging_mode_request := limine.Paging_Mode_Request {
	id       = limine.PAGING_MODE_REQUEST,
	revision = 0,
	mode     = limine.PAGING_MODE_PINNED,
	max_mode = limine.PAGING_MODE_PINNED,
	min_mode = limine.PAGING_MODE_PINNED,
}

// The device tree, on the two architectures whose firmware describes the
// machine that way. x86-64 answers nothing, and the architecture that reads
// it is the one that needs it -- riscv64's clock rate is in there and nowhere
// else. See `arch.set_device_tree`.
@(export, link_section = ".limine_requests")
dtb_request := limine.DTB_Request {
	id       = limine.DTB_REQUEST,
	revision = 0,
}

/*
Ask for the other cores.

The request's presence is what starts them. Without it the bootloader leaves
every application processor wherever firmware left it, and there is no
protocol-level way to reach one afterwards. With it, each core is parked on
its own `goto_address`, in the bootstrap processor's machine state, and a
single store releases it. No x2APIC: the LAPIC driver is xAPIC, and a
bootloader that cannot turn x2APIC off refuses to boot rather than hand over
a mode nothing here can speak. See `docs/SMP.md`.
*/
@(export, link_section = ".limine_requests")
mp_request := limine.MP_Request {
	id       = limine.MP_REQUEST,
	revision = 0,
	flags    = 0,
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

// Whether `mem.init` finished. Read by the panic screen, which can ask the VMM
// what was mapped at a faulting address only once there is a VMM to ask.
memory_online: bool

@(export, link_name = "_start")
kmain :: proc "c" () {
	arch.early_init()

	// `context` must exist before any Odin call that can touch it. With
	// -default-to-nil-allocator this is an empty context: allocation faults
	// loudly instead of silently succeeding against a heap we do not have.
	context = {}
	#force_no_inline runtime._startup_runtime()

	// The bootloader's word on where memory is, handed to the architecture
	// before anything else: one port has to map the way to its console with
	// it, and another names buffers to its firmware by physical address.
	hhdm, kphys, kvirt: u64
	if r := hhdm_request.response; r != nil {
		hhdm = r.offset
	}
	if r := executable_address_request.response; r != nil {
		kphys, kvirt = r.physical_base, r.virtual_base
	}
	arch.set_boot_layout(hhdm, kphys, kvirt)
	serial = uart.init(arch.serial_console())
	klog.serial = &serial
	uart.write_string(&serial, "\n\n")
	log_line(&klog, .Info, "Vectra " + VERSION + " (" + arch.NAME + ") entering kmain")

	check_base_revision()
	if r := dtb_request.response; r != nil {
		arch.set_device_tree(r.dtb)
	}
	// The boot core's name goes with the tables, for the architecture that
	// cannot read its own: a hart learns its id from whoever started it, and
	// that was the bootloader.
	boot_cpu := u64(0)
	if mp := mp_request.response; mp != nil {
		boot_cpu = limine.mp_bsp_id(mp)
	}
	init_traps(boot_cpu)

	// `kernel:sync` sits below the panic screen and cannot call it. A broken
	// locking rule is not a recoverable condition, so it is given a way to
	// stop the machine and name the rule -- see `kernel/sync/sleep.odin`.
	sync.set_panic(panic_stop)

	if !init_screen() {
		log_line(&klog, .Warn, "no framebuffer from bootloader; serial only")
	}

	report_bootloader()
	report_cpus()
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
	verify_protocol()

	init_namespace()
	verify_namespace()

	if init_scheduler() {
		verify_scheduler()
		if init_timer() {
			verify_preemption()
			verify_sleep_lock()
			verify_rw_lock()
			verify_sleep_queue()
			verify_flush()
			verify_payload()
			verify_vfs_mnt()
			verify_vfs_threads()

			// Last, and only here. devfs is the first server whose reads
			// park. It needs workers, a clock and a rendezvous, and the block
			// above just finished proving all three.
			if init_devfs() {
				verify_devfs()
			}
			if init_srv() {
				verify_srv()
			}
			// The environment device holds nothing until a process writes
			// it; the user suite is what exercises it, from ring 3. The
			// process device is exercised the same way, by ps, kill and ns.
			init_env()
			init_proc()

			// The pipe needs nothing above the scheduler, and the wire needs
			// the pipe. Both come before userland, because a posted pipe is
			// what a process's service will be. A machine that cannot keep
			// that contract should say so before inviting one.
			if init_pipe() {
				verify_pipe()
				verify_wire()
				verify_posted()
			}

			// The programs become files here, after the namespace has its
			// conventional directories and before anything asks to run one.
			// The loader below then has something to load.
			init_bin()

			// Last of all, because a keystroke needs somewhere to go. The
			// bottom half hands its bytes to `/dev/cons`, which has to exist
			// before the first interrupt is let through.
			if init_keyboard() {
				verify_keyboard()
			}
			verify_space()

			// Last, because ring 3 needs everything above it. A space to run
			// in, a scheduler to preempt it, a clock behind the preemption,
			// and a fault path with somewhere to report to.
			init_user()
			verify_user()

			// Last of all, the other cores. Every self-test above was written
			// for one core and says so wherever it counts something, so they
			// all run before a second core can change what they count.
			if init_smp() {
				verify_smp()
			}
		}
	}

	log_line(&klog, .Ok, "boot complete -- idling")
	sched.exit()
}

/*
check_base_revision verifies the bootloader honoured our request.

Two separate failures hide here. The bootloader may not support base revision 6
at all. Word 2 then comes back unchanged, and the kernel runs under whatever it
picked. Or it may support it, and still load the kernel as something else. Word
1 says which. Both matter to code that assumes base revision 6 semantics, most
of all the restrictive HHDM.

Under an older revision, the HHDM maps more of the memory map than this kernel
is entitled to touch. It would then stand on a guarantee it does not have.

We report and continue. Nothing in Milestone 0 dereferences an HHDM address, so
this is a warning today. It becomes a hard stop the moment the VMM starts to
trust the map.
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
something can arm, take and resume from, so it exercises the whole path end to
end.

The stub pushes the right vector. The tail builds a frame the dispatcher can
read. The handler recognises it. And `iretq` lands back on the instruction
after the `int3`. Anything wrong anywhere in that chain shows up here, three
lines into the boot, rather than as an unexplained reset during whatever is
written next.

There is no graceful failure. If the IDT is wrong, the `int3` triple faults,
and the machine resets before the check below runs.

If it is merely mis-wired, the check reports it and the boot goes on. A kernel
that cannot report faults is still worth a boot far enough to say so.
*/
init_traps :: proc "contextless" (boot_cpu: u64) {
	arch.init_traps(boot_cpu)
	arch.set_trap_handler(panic_trap)
	arch.set_interrupt_handler(arch.VECTOR_NMI, on_nmi)

	arm_breakpoint_test()
	arch.breakpoint()

	// The tables read back, in the architecture's own words: selectors and a
	// vector count on amd64, a vector base and an exception level elsewhere.
	sink := begin(&klog)
	libodin.put_str(&sink, "traps: ")
	took := arch.describe_traps(&sink)
	libodin.put_str(&sink, ", ")
	libodin.put_str(&sink, arch.BREAKPOINT_NAME)
	libodin.put_str(&sink, " round-trip ")
	libodin.put_str(&sink, breakpoint_test_fired() ? "ok" : "LOST")
	emit(&klog, took && breakpoint_test_fired() ? .Ok : .Fault, &sink)
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

	// attach_screen rather than `klog.screen = &kcon`. Everything logged before
	// this point replays onto the console, which is the banner and the base
	// revision handshake.
	//
	// The screen therefore carries the whole boot, and not just the part after
	// there was somewhere to draw it.
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

Called twice: once from `init_screen` with the memory lamp dark, and again
after `mem.init` returns with it lit. A redraw of the whole row, rather than
the one lamp that changed, keeps the strip's layout in a single place.

`draw_lamp_row` computes the labels and their spacing. A caller that poked at
one lamp would have to duplicate that arithmetic to find it.
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

	// Firmware type rides along on the same line. On its own it is one word, and
	// it is only ever interesting next to who did the boot.
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
report_cpus says how many cores the bootloader parked, and which one this is.

Reported here rather than when they start, because the count is a fact about
the machine and the start is a decision the kernel makes much later, after
every self-test that assumes one core has run. A machine with one core still
answers, with a list of one. A bootloader without the feature answers nothing,
and that is a warning rather than a fault: the kernel runs on one core either
way.
*/
report_cpus :: proc "contextless" () {
	mp := mp_request.response
	if mp == nil {
		log_line(&klog, .Warn, "bootloader lists no cores; running on one")
		return
	}

	sink := begin(&klog)
	libodin.put_str(&sink, "cpus: ")
	libodin.put_uint(&sink, mp.cpu_count)
	libodin.put_str(&sink, mp.cpu_count == 1 ? " core, bsp " : " cores, bsp ")
	libodin.put_str(&sink, limine.MP_ID_NAME)
	libodin.put_str(&sink, " ")
	libodin.put_uint(&sink, limine.mp_bsp_id(mp))
	libodin.put_str(&sink, ", ")
	libodin.put_str(&sink, limine.MP_ID_NAME)
	libodin.put_str(&sink, " ids")
	for i in 0 ..< int(mp.cpu_count) {
		libodin.put_str(&sink, " ")
		libodin.put_uint(&sink, limine.mp_cpu_id(mp.cpus[i]))
	}
	if limine.mp_x2apic(mp) {
		libodin.put_str(&sink, ", x2apic on")
	}
	emit(&klog, .Info, &sink)
}

/*
report_paging_mode confirms we got the paging layout we pinned.

Limine clamps to what the hardware supports, so a mismatch here is not a
bootloader bug. It means the VMM about to be written would walk a different
number of levels than its design assumed.
*/
report_paging_mode :: proc "contextless" () {
	response := paging_mode_request.response
	if response == nil {
		log_line(&klog, .Warn, "no paging mode response; layout is whatever the firmware left")
		return
	}

	sink := begin(&klog)
	libodin.put_str(&sink, "paging ")
	if name := limine.paging_mode_name(response.mode); name != "" {
		libodin.put_str(&sink, name)
	} else {
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

	// The device tree, where there is one. Its size is the second word of
	// its header, big-endian, which is the one thing worth reading here:
	// a tree of a few bytes is a tree the firmware did not really pass.
	if dtb := dtb_request.response; dtb != nil && dtb.dtb != nil {
		b := cast([^]u8)dtb.dtb
		size := u64(b[4]) << 24 | u64(b[5]) << 16 | u64(b[6]) << 8 | u64(b[7])
		sink := begin(&klog)
		libodin.put_str(&sink, "device tree at ")
		libodin.put_ptr(&sink, dtb.dtb)
		libodin.put_str(&sink, ", ")
		libodin.put_size(&sink, size)
		emit(&klog, .Info, &sink)
	}
}

/*
survey_memory translates Limine's memory map into `kernel/mem`'s vocabulary.

This is the only place in Vectra that knows both, and it exists so nothing
below it knows either. `kernel/mem` receives a `Boot_Memory`, and never learns
which bootloader filled it in. Booting some other way -- a different protocol,
a hypervisor handing over directly -- means rewriting this one procedure.

The three responses read here are not optional the way the rest of the survey
is. With no memory map there is nothing to allocate from. With no HHDM offset,
and no load address, there is no way to reach it or to rebuild the kernel's own
mapping. Each missing one is fatal and says so.
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

	Base revision 6 guarantees the framebuffer is in the direct map. It does not
	guarantee the firmware described it as a memory map entry, and OVMF is not
	consistent about it. Found the hard way, the difference means the VMM builds
	an address space with no framebuffer in it. The machine then dies on the first
	character drawn after the switch. The console is the thing that would have
	said so.
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

Reserved and bad memory both collapse to `.Unmapped`. The distinction matters
to firmware, and to a diagnostic tool. To a kernel that will neither allocate
from them nor put them in the direct map, they are the same thing.
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

Only the totals and the largest usable region are printed. A full dump is
twenty-odd lines that push everything else off the screen. Once the PMM is up,
its own figures are the ones worth reading.
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

The address space switch happens inside `mem.init`, between the second and
third lines logged here. The fourth line's arrival on the screen is itself the
proof that the new tables cover the framebuffer, the kernel image and the
stack.

That is worth more than any check written for it. A kernel that got it wrong
would not survive to print a failure.
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

	// A console reached through a window the bootloader's tables held has
	// to move onto the kernel's own before the next line is logged.
	if phys, needs := uart.needs_mapping(&serial); needs {
		if virt, err := mem.map_mmio(phys, u64(arch.PAGE_SIZE)); err == .None {
			uart.rebase(&serial, uintptr(virt))
		}
	}

	log_line(&klog, .Ok, "heap online -- context.allocator is live")
	memory_online = true
	draw_lamps(memory = true)
	return true
}

/*
verify_memory exercises each layer once, on the machine that will run it.

Not a substitute for tests, which there is nowhere to run. It is here because
the three ways this subsystem fails are all silent at the point of failure.

A PMM that hands the same frame out twice. A page table that translates to the
wrong place. And an allocator that is installed, but hands back memory nobody
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

	// VMM: a walk of the kernel's own tables for a kernel global has to land on
	// the physical address the bootloader put it at. And the direct map has to
	// agree with itself.
	space := mem.kernel_address_space()
	global_virt := uintptr(&klog)
	expect := uintptr(boot_mem.kernel_phys + (u64(global_virt) - boot_mem.kernel_virt))
	found, found_ok := mem.translate(space, global_virt)
	ok = ok && found_ok && found == expect

	direct, direct_ok := mem.translate(space, uintptr(mem.phys_to_virt(expect)))
	ok = ok && direct_ok && direct == expect

	// And the segment permissions the linker script implied are the ones the
	// hardware will actually enforce. The check reads them back out of the
	// tables, rather than trusts the code that wrote them.
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

/*
verify_protocol checks the Vectra9 wire codec on the machine.

Deliberately after `verify_memory`, and deliberately on the heap. The scratch
buffer comes from `make`.

This is therefore also the allocator's first real customer. A heap that only
ever satisfied its own self-test would be suspicious.

A re-encode checks the codec. Every message kind is encoded, decoded and
encoded again, and the two byte strings must match. See
`sys/vectra9/verify.odin` for why that is a better oracle than comparing the
decoded structs.
*/
verify_protocol :: proc() {
	scratch := make([]u8, 4096)
	if scratch == nil {
		log_line(&klog, .Fault, "vectra9 self-test skipped -- no memory for a scratch buffer")
		return
	}
	defer delete(scratch)

	result := vectra9.verify(scratch)
	ok := result.failures == 0 && result.kinds_tested > 0

	sink := begin(&klog)
	libodin.put_str(&sink, "vectra9 ")
	libodin.put_str(&sink, vectra9.VERSION)
	libodin.put_str(&sink, ": ")
	libodin.put_uint(&sink, u64(result.kinds_tested))
	if ok {
		libodin.put_str(&sink, " message kinds round-trip, both transports agree")
		emit(&klog, .Ok, &sink)
		return
	}

	libodin.put_str(&sink, " kinds tested, ")
	libodin.put_uint(&sink, u64(result.failures))
	libodin.put_str(&sink, " FAILED -- first ")
	libodin.put_str(&sink, vectra9.kind_name(result.first_failure))
	libodin.put_str(&sink, ": ")
	libodin.put_str(&sink, vectra9.describe(result.first_error))
	emit(&klog, .Fault, &sink)
}

/*
init_namespace stands up the root device and the namespace every process will
inherit.

Last in the boot, because it needs everything before it. That is the heap for
chans and fid tables, and Vectra9 for the messages that reach the root server.
The root is an ordinary server reached through `#/`, rather than a special case
in the walker. See docs/VECTRA9.md section 7.2.

So if this line prints, something already exercised the escape hatch a `Clean`
namespace depends on.
*/
init_namespace :: proc() {
	if err := vfs.init(); err != vfs.OK {
		sink := begin(&klog)
		libodin.put_str(&sink, "namespace: root device failed -- ")
		libodin.put_str(&sink, vectra9.errno_name(err))
		emit(&klog, .Fault, &sink)
		return
	}

	sink := begin(&klog)
	libodin.put_str(&sink, "namespace: #/ attached as /, ")
	libodin.put_uint(&sink, u64(vfs.ROOT_DIRECTORIES))
	libodin.put_str(&sink, " conventional directories")
	emit(&klog, .Ok, &sink)
}

/*
verify_namespace exercises the namespace layer against two real servers.

Binds, unions, `..` across a mount point, and both fork modes -- all on the
machine, all over real 9P traffic. See `kernel/vfs/verify.odin` for what each
check is for. This only reports.
*/
verify_namespace :: proc() {
	scratch := make([]u8, 1024)
	if scratch == nil {
		log_line(&klog, .Fault, "namespace self-test skipped -- no memory for a scratch buffer")
		return
	}
	defer delete(scratch)

	/*
	Heap stats bracket it, because the namespace layer is the first thing in
	Vectra that allocates and frees in volume. Its failure mode is a reference
	count rather than a crash. A leaked chan is a fid the server never gets back.
	A chan freed twice is a fid given out again while somebody still holds it.
	Neither shows up as a failed check -- both show up here.

	Every allocation the self-test makes is also released by it, so the only
	correct answer is zero.
	*/
	before := mem.live_objects(mem.heap_stats())
	result := vfs.verify(scratch)
	leaked := mem.live_objects(mem.heap_stats()) - before

	ok := libodin.passed(result.tally) && leaked == 0

	sink := report_begin("vfs", result.checks)
	if ok {
		libodin.put_str(&sink, " namespace checks passed -- union of ")
		libodin.put_uint(&sink, u64(result.union_entries))
		libodin.put_str(&sink, " names over two servers, ")
		libodin.put_uint(&sink, u64(result.mounts))
		libodin.put_str(&sink, " mount point")
		if result.mounts != 1 {
			libodin.put_str(&sink, "s")
		}
		libodin.put_str(&sink, ", heap balanced")
		emit(&klog, .Ok, &sink)
		return
	}

	report_failed(&sink, result.tally, leaked)
}

/*
init_scheduler adopts the boot context as a thread and gives the core an idle
one.

From here on `kmain` is thread 0, rather than the only thing running. Something
can preempt every line after this. That is why the heap grew a lock, and why
this comes after everything that has to happen exactly once.
*/
init_scheduler :: proc() -> bool {
	if !sched.init() {
		log_line(&klog, .Fault, "scheduler: no memory for the boot thread")
		return false
	}

	s := sched.stats()
	sink := begin(&klog)
	libodin.put_str(&sink, "sched cpu0 ")
	libodin.put_str(&sink, class_name(s.class))
	libodin.put_str(&sink, ", capacity ")
	libodin.put_uint(&sink, u64(s.capacity))
	libodin.put_str(&sink, "/1024, slice ")
	libodin.put_uint(&sink, u64(s.slice))
	libodin.put_str(&sink, " ticks, ")
	libodin.put_uint(&sink, u64(sched.PRIORITY_LEVELS))
	libodin.put_str(&sink, " priority levels")
	emit(&klog, .Ok, &sink)
	return true
}

// class_name renders a core's class for the boot line. Every amd64 core is
// `.Performance`. The other two exist so an arm64 part can report what it
// really has, and the scheduler learns no new vocabulary first.
class_name :: proc "contextless" (class: arch.Cpu_Class) -> string {
	switch class {
	case .Efficiency:  return "efficiency"
	case .Performance: return "performance"
	case .Prime:       return "prime"
	}
	return "unknown"
}

/*
verify_scheduler runs the cooperative half of the self-test.

Before the timer, deliberately: a cooperative scheduler is deterministic, so a
failure here is reproducible. See `kernel/sched/verify.odin`.
*/
verify_scheduler :: proc() {
	result := sched.verify()
	report_sched(result, "sched", proc(sink: ^libodin.Sink, r: sched.Verify_Result) {
		libodin.put_str(sink, " scheduler checks passed -- ")
		libodin.put_uint(sink, r.switches)
		libodin.put_str(sink, " switches, round-robin and priority verified")
	})
}

/*
init_timer maps the local timer, calibrates it and starts the tick.

On amd64 that is the local APIC, measured against the PIT. On arm64 the
generic timer's rate is a register, and on riscv64 it is a line in the device
tree. `arch.TIMER_REFERENCE` says which on the boot line.

This is where interrupts come on for the first time in Vectra's life. Everything
before it ran with them masked from the moment the bootloader handed over.
*/
init_timer :: proc() -> bool {
	if !arch.timer_available() {
		sink := begin(&klog)
		libodin.put_str(&sink, "no ")
		libodin.put_str(&sink, arch.TIMER_NAME)
		libodin.put_str(&sink, " timer; running without preemption")
		emit(&klog, .Warn, &sink)
		return false
	}

	// A timer reached through registers in memory has a page to map first.
	// One reached through system registers says so with a size of zero,
	// which maps nothing and answers an address nothing reads.
	phys := arch.timer_physical_base()
	virt, err := mem.map_mmio(phys, arch.TIMER_MMIO_SIZE)
	if err != .None {
		sink := begin(&klog)
		libodin.put_str(&sink, arch.TIMER_NAME)
		libodin.put_str(&sink, ": cannot map registers at ")
		libodin.put_hex(&sink, u64(phys), 16)
		libodin.put_str(&sink, " -- ")
		libodin.put_str(&sink, mem.describe(err))
		emit(&klog, .Fault, &sink)
		return false
	}

	arch.timer_attach(virt)
	init_irq_controller()
	if !sched.start_timer(TICK_HZ) {
		sink := begin(&klog)
		libodin.put_str(&sink, arch.TIMER_NAME)
		libodin.put_str(&sink, ": timer would not calibrate; running without preemption")
		emit(&klog, .Fault, &sink)
		return false
	}

	t := sched.timer_stats()
	sink := begin(&klog)
	libodin.put_str(&sink, arch.TIMER_NAME)
	libodin.put_str(&sink, " timer ")
	libodin.put_uint(&sink, t.hz)
	libodin.put_str(&sink, " Hz -- clock ")
	libodin.put_uint(&sink, t.frequency / 1_000_000)
	libodin.put_str(&sink, ".")
	libodin.put_uint(&sink, (t.frequency / 100_000) % 10)
	libodin.put_str(&sink, " MHz ")
	libodin.put_str(&sink, arch.TIMER_REFERENCE)
	libodin.put_str(&sink, ", ")
	libodin.put_uint(&sink, u64(t.count))
	libodin.put_str(&sink, " counts per tick")
	emit(&klog, .Ok, &sink)
	return true
}

TICK_HZ :: 1000

/*
verify_preemption is the half that needs the timer.

Three threads that never yield, and the boot thread as a fourth. On a kernel
that did not preempt, the first one dispatched would still be running.
*/
verify_preemption :: proc() {
	result: sched.Verify_Result
	sched.verify_preemption(&result)
	// And the idle thread's reap, which needs the timer for the same reason:
	// the checker has to park for idle to run at all.
	sched.verify_idle_reap(&result)
	report_sched(result, "sched preemption", proc(sink: ^libodin.Sink, r: sched.Verify_Result) {
		libodin.put_str(sink, " checks passed -- ")
		libodin.put_uint(sink, u64(r.preempted))
		libodin.put_str(sink, " threads preempted, none starved (")
		libodin.put_uint(sink, r.min_progress)
		libodin.put_str(sink, "-")
		libodin.put_uint(sink, r.max_progress)
		libodin.put_str(sink, " rounds), decayed to ")
		libodin.put_uint(sink, u64(r.decayed_to))
		libodin.put_str(sink, ", ")
		libodin.put_uint(sink, u64(r.fpu_checked))
		libodin.put_str(sink, " fpu accumulators intact")
	})
}

/*
report_begin opens a self-test line: the subsystem's name and its check count.

Eight callers wrote these three statements, and the eight failure tails below
them drifted into four spellings of one sentence, and one lost its colon. A
reader goes down a boot log by eye, in a column. A line that words itself
differently reads as a different kind of event.
*/
report_begin :: proc(label: string, checks: int) -> libodin.Sink {
	sink := begin(&klog)
	libodin.put_str(&sink, label)
	libodin.put_byte(&sink, ' ')
	libodin.put_uint(&sink, u64(checks))
	return sink
}

/*
report_failed writes the tail of a self-test line that did not pass, and emits
it.

Two failures, and they are not the same failure. A check that failed has a name
worth printing, and `docs/TESTING.md` explains why it is the *first* name. A run
where every check passed and the heap did not come back has no name at all.
Saying `0 FAILED` about that would be worse than saying nothing.

So the count decides which sentence this is. A run that did both gets the check
and the leak, because the leak is usually what the failed check was about.
*/
report_failed :: proc(sink: ^libodin.Sink, t: libodin.Tally, leaked := 0) {
	libodin.put_str(sink, " checks, ")
	if t.failures > 0 {
		libodin.put_uint(sink, u64(t.failures))
		libodin.put_str(sink, " FAILED -- first: ")
		libodin.put_str(sink, t.first_failure)
		if leaked != 0 {
			libodin.put_str(sink, " (leaked ")
			libodin.put_int(sink, i64(leaked))
			libodin.put_str(sink, ")")
		}
	} else {
		libodin.put_str(sink, "all passed but ")
		libodin.put_int(sink, i64(leaked))
		libodin.put_str(sink, " objects LEAKED")
	}
	emit(&klog, .Fault, sink)

	// The failures after the first, beneath the line, as far as the tally
	// kept them. The first is still the one to read; these say how far its
	// consequences reached, and which check ends the run of them.
	for i in 0 ..< t.later_count {
		s := begin(&klog)
		libodin.put_str(&s, "  also: ")
		libodin.put_str(&s, t.later[i])
		emit(&klog, .Trace, &s)
	}
	if t.failures > t.later_count + 1 {
		s := begin(&klog)
		libodin.put_str(&s, "  and ")
		libodin.put_uint(&s, u64(t.failures - t.later_count - 1))
		libodin.put_str(&s, " more")
		emit(&klog, .Trace, &s)
	}
}

// report_sched prints one self-test result. The success wording differs
// between the two halves, and the failure wording does not. That is the whole
// reason this takes a procedure, rather than a format string there is no
// formatter for.
report_sched :: proc(
	r: sched.Verify_Result,
	label: string,
	success: proc(sink: ^libodin.Sink, r: sched.Verify_Result),
) {
	ok := libodin.passed(r.tally)

	sink := report_begin(label, r.checks)
	if ok {
		success(&sink, r)
		emit(&klog, .Ok, &sink)
		return
	}

	report_failed(&sink, r.tally)
}

/*
init_devfs brings up `#c` and binds it at `/dev`.

The first device server on the machine. It is also the first thing in the boot
that makes a path lead to hardware rather than to a table.

It gets the same console and the same serial port the kernel log writes to. That
is what makes `/dev/cons` the console, rather than a copy of it.

Last in the boot order, because it needs everything before it. Workers are
threads, a parked reader waits on a rendezvous, and a reader that gives up needs
a clock to give up against.
*/
init_devfs :: proc() -> bool {
	if err := devfs.init(vfs.boot_namespace, &kcon, &serial, &screen); err != vfs.OK {
		sink := begin(&klog)
		libodin.put_str(&sink, "devfs: #c would not come up -- ")
		libodin.put_str(&sink, vectra9.errno_name(err))
		emit(&klog, .Fault, &sink)
		return false
	}

	sink := begin(&klog)
	libodin.put_str(&sink, "devfs #c bound at /dev, ")
	libodin.put_uint(&sink, u64(devfs.DEV_FILES))
	libodin.put_str(&sink, " devices on ")
	libodin.put_uint(&sink, u64(devfs.WORKERS))
	libodin.put_str(&sink, " workers, cooked console, input ")
	libodin.put_str(&sink, devfs.input_started() ? "live" : "absent")
	emit(&klog, .Ok, &sink)
	return true
}

/*
verify_devfs reads and writes the machine's own `/dev/cons`.

Over the real mount, through the real transport, on the boot namespace. The two
checks that matter are a read that parks until a byte arrives and a read that
gives up and flushes. See `kernel/devfs/verify.odin`.
*/
verify_devfs :: proc() {
	scratch := make([]u8, 512)
	if scratch == nil {
		log_line(&klog, .Fault, "devfs self-test skipped -- no memory for a scratch buffer")
		return
	}
	defer delete(scratch)

	result := devfs.verify(scratch)
	ok := libodin.passed(result.tally)

	sink := report_begin("devfs", result.checks)
	if ok {
		libodin.put_str(&sink, " device checks passed -- ")
		libodin.put_uint(&sink, u64(result.listed))
		libodin.put_str(&sink, " files under /dev, ")
		libodin.put_uint(&sink, u64(result.written))
		libodin.put_str(&sink, " bytes written to cons, ")
		libodin.put_uint(&sink, result.lines)
		libodin.put_str(&sink, " lines cooked over ")
		libodin.put_uint(&sink, result.edits)
		libodin.put_str(&sink, " edits, ")
		libodin.put_uint(&sink, result.parked)
		libodin.put_str(&sink, " reads parked, a read gave up after ")
		libodin.put_uint(&sink, result.gave_up)
		libodin.put_str(&sink, " ticks")
		emit(&klog, .Ok, &sink)
		return
	}

	report_failed(&sink, result.tally)
}

/*
init_env brings up `#e` and binds it at `/env`. One directory per process,
and every process's is empty until it or its parent sets something. See
`docs/ENV.md`.
*/
init_env :: proc() -> bool {
	if err := env.init(vfs.boot_namespace); err != vfs.OK {
		sink := begin(&klog)
		libodin.put_str(&sink, "env: #e would not come up -- ")
		libodin.put_str(&sink, vectra9.errno_name(err))
		emit(&klog, .Fault, &sink)
		return false
	}
	sink := begin(&klog)
	libodin.put_str(&sink, "env #e bound at /env, ")
	libodin.put_uint(&sink, u64(env.MAX_GROUPS))
	libodin.put_str(&sink, " groups of ")
	libodin.put_uint(&sink, u64(env.MAX_VARS))
	libodin.put_str(&sink, " variables, values to ")
	libodin.put_uint(&sink, u64(env.VALUE_MAX))
	libodin.put_str(&sink, " bytes")
	emit(&klog, .Ok, &sink)
	return true
}

// init_proc brings up `#p` and binds it at `/proc`: a directory per live
// process, with status, ns, note and ctl in it. See `docs/PROC.md`.
init_proc :: proc() -> bool {
	if err := procfs.init(vfs.boot_namespace); err != vfs.OK {
		sink := begin(&klog)
		libodin.put_str(&sink, "proc: #p would not come up -- ")
		libodin.put_str(&sink, vectra9.errno_name(err))
		emit(&klog, .Fault, &sink)
		return false
	}
	log_line(&klog, .Ok, "proc #p bound at /proc, a directory per process: status, ns, note, ctl")
	return true
}

/*
init_srv brings up `#s` and binds it at `/srv`.

Empty, and it stays empty until something posts. Plan 9's `/srv` works the same
way. The kernel is not the thing that decides which of its own services deserve
a public name. Nothing in this boot needs to mount another kernel service by
one.

Synchronous, unlike `#c`. Every message this server answers is a table lookup,
so there is nothing for a worker thread to be doing while a caller waits.
*/
init_srv :: proc() -> bool {
	if err := srv.init(vfs.boot_namespace); err != vfs.OK {
		sink := begin(&klog)
		libodin.put_str(&sink, "srv: #s would not come up -- ")
		libodin.put_str(&sink, vectra9.errno_name(err))
		emit(&klog, .Fault, &sink)
		return false
	}

	sink := begin(&klog)
	libodin.put_str(&sink, "srv #s bound at /srv, ")
	libodin.put_uint(&sink, u64(srv.count()))
	libodin.put_str(&sink, " services posted, ")
	libodin.put_uint(&sink, u64(srv.MAX_SERVICES))
	libodin.put_str(&sink, " slots")
	emit(&klog, .Ok, &sink)
	return true
}

/*
verify_srv posts, lists, mounts and removes, against the boot namespace.

The check worth naming is the listing cookie. `/srv` is the first directory in
Vectra whose contents change, so it is the first whose cookie may not be a
position. See `kernel/srv/verify.odin`.
*/
verify_srv :: proc() {
	scratch := make([]u8, 1024)
	if scratch == nil {
		log_line(&klog, .Fault, "srv self-test skipped -- no memory for a scratch buffer")
		return
	}
	defer delete(scratch)

	before := mem.live_objects(mem.heap_stats())
	result := srv.verify(scratch)
	leaked := mem.live_objects(mem.heap_stats()) - before

	ok := libodin.passed(result.tally) && leaked == 0

	sink := report_begin("srv", result.checks)
	if ok {
		libodin.put_str(&sink, " service checks passed -- ")
		libodin.put_uint(&sink, u64(result.posted))
		libodin.put_str(&sink, " posted, ")
		libodin.put_uint(&sink, u64(result.listed))
		libodin.put_str(&sink, " listed across ")
		libodin.put_uint(&sink, u64(result.passes))
		libodin.put_str(&sink, " passes with one removed under them, ")
		libodin.put_uint(&sink, u64(result.mounted))
		libodin.put_str(&sink, " mounted, ")
		libodin.put_uint(&sink, u64(result.reserved))
		libodin.put_str(&sink, " name reserved pending, heap balanced")
		emit(&klog, .Ok, &sink)
		return
	}

	report_failed(&sink, result.tally, leaked)
}

/*
init_pipe brings the pipe server up. Nothing binds it and nothing registers
it. A pipe end is reachable only through a descriptor the kernel handed out,
which is the same privilege boundary `/srv` posting enforces.
*/
init_pipe :: proc() -> bool {
	if !pipe.init() {
		log_line(&klog, .Fault, "pipe: the pipe server would not come up")
		return false
	}

	sink := begin(&klog)
	libodin.put_str(&sink, "pipe #| ready, ")
	libodin.put_uint(&sink, u64(pipe.MAX_PIPES))
	libodin.put_str(&sink, " slots, ")
	libodin.put_uint(&sink, u64(pipe.RING_SIZE))
	libodin.put_str(&sink, " bytes per direction")
	emit(&klog, .Ok, &sink)
	return true
}

/*
verify_pipe moves bytes both ways across a real pipe, and parks a reader and
a writer. Then it closes the two ends, to see EOF and EPIPE come out the
right sides. See `kernel/pipe/verify.odin`.
*/
verify_pipe :: proc() {
	scratch := make([]u8, 4096)
	if scratch == nil {
		log_line(&klog, .Fault, "pipe self-test skipped -- no memory for a scratch buffer")
		return
	}
	defer delete(scratch)

	// Threads earlier suites left dead are heap objects `pipe.verify`'s own
	// reap would otherwise free inside the measured window.
	sched.reap()
	before := mem.live_objects(mem.heap_stats())
	result := pipe.verify(scratch)
	leaked := mem.live_objects(mem.heap_stats()) - before

	ok := libodin.passed(result.tally) && leaked == 0

	sink := report_begin("pipe", result.checks)
	if ok {
		libodin.put_str(&sink, " checks passed -- ")
		libodin.put_uint(&sink, u64(result.moved))
		libodin.put_str(&sink, " bytes crossed, ")
		libodin.put_uint(&sink, u64(result.parked))
		libodin.put_str(&sink, " threads parked and woken, heap balanced")
		emit(&klog, .Ok, &sink)
		return
	}

	report_failed(&sink, result.tally, leaked)
}

/*
init_irq_controller maps the interrupt controller and masks every line on it.

This is how a device interrupt reaches a core, and until this milestone nothing
needed one. The timer is the only interrupt Vectra had, and the kernel armed it
rather than received it. The I/O APIC on amd64, the GIC on arm64, the PLIC on
riscv64: `arch.IRQ_CONTROLLER_NAME` says which.

Reported rather than fatal. A machine with no controller still boots, still
schedules and still has a console over the serial line. What it does not get is
a keyboard, and `init_keyboard` says so on its own line.

The address is assumed rather than discovered, because Vectra parses no ACPI
tables. `kernel/arch/amd64/ioapic.odin` says exactly which assumption that is
and what would retire it.
*/
init_irq_controller :: proc() -> bool {
	virt, err := mem.map_mmio(arch.irq_physical_base(), arch.IRQ_MMIO_SIZE)
	if err != .None {
		sink := begin(&klog)
		libodin.put_str(&sink, arch.IRQ_CONTROLLER_NAME)
		libodin.put_str(&sink, ": cannot map registers at ")
		libodin.put_hex(&sink, u64(arch.irq_physical_base()), 16)
		libodin.put_str(&sink, " -- ")
		libodin.put_str(&sink, mem.describe(err))
		emit(&klog, .Warn, &sink)
		return false
	}

	arch.irq_attach(virt)
	if !arch.irq_available() {
		sink := begin(&klog)
		libodin.put_str(&sink, "no ")
		libodin.put_str(&sink, arch.IRQ_CONTROLLER_NAME)
		libodin.put_str(&sink, "; running without device interrupts")
		emit(&klog, .Warn, &sink)
		return false
	}

	sink := begin(&klog)
	libodin.put_str(&sink, arch.IRQ_CONTROLLER_NAME)
	libodin.put_str(&sink, " version ")
	libodin.put_hex(&sink, u64(arch.irq_version()), 2)
	libodin.put_str(&sink, ", ")
	libodin.put_uint(&sink, u64(arch.irq_lines()))
	libodin.put_str(&sink, " lines, all masked")
	emit(&klog, .Ok, &sink)
	return true
}

/*
init_keyboard routes IRQ 1 and puts the first real device interrupt on it.

Every interrupt before this one was the LAPIC timer, which this kernel asked
for. A keystroke arrives because somebody outside the machine decided it
should.

The bytes go to `/dev/cons`, alongside the ones the serial poller delivers.
Nothing above the console's ring can tell which producer filled it, which is
what makes the line discipline one implementation rather than two.
*/
init_keyboard :: proc() -> bool {
	vector := arch.VECTOR_IRQ_BASE + kbd.KBD_IRQ
	if !kbd.init(vector, devfs.keyboard_sink, devfs.scancode_tap) {
		log_line(&klog, .Warn, "no keyboard; console input is the serial line only")
		return false
	}

	sink := begin(&klog)
	libodin.put_str(&sink, "kbd ps/2 on irq ")
	libodin.put_uint(&sink, u64(kbd.KBD_IRQ))
	libodin.put_str(&sink, " -> vector ")
	libodin.put_hex(&sink, u64(vector), 2)
	libodin.put_str(&sink, ", scancode set 1, us layout")
	emit(&klog, .Ok, &sink)
	return true
}

/*
verify_keyboard checks the translation, and then makes the controller interrupt.

The state machine is a pure question and is checked against a keyboard of the
test's own. The interrupt path is not. Instead, the check asks the 8042 to
deliver a byte as though somebody typed it. See `kernel/drivers/kbd/verify.odin`.
*/
verify_keyboard :: proc() {
	result := kbd.verify()
	ok := libodin.passed(result.tally)

	sink := report_begin("kbd", result.checks)
	if ok {
		s := kbd.stats()
		libodin.put_str(&sink, " keyboard checks passed -- ")
		libodin.put_uint(&sink, u64(result.translated))
		libodin.put_str(&sink, " scancodes translated, ")
		libodin.put_uint(&sink, s.interrupts)
		libodin.put_str(&sink, " interrupts taken, an injected key reached the sink")
		emit(&klog, .Ok, &sink)
		return
	}

	report_failed(&sink, result.tally)
}

/*
init_bin publishes the kernel's own programs as files.

`#b` at `/bin` is the smallest filesystem with a program in it, and the
loader's whole reason to exist. Two files today, each a header and a page of
text. The day a build stages a real filesystem image, this server is the
thing it replaces.
*/
init_bin :: proc() -> bool {
	if err := user.bin_init(vfs.boot_namespace); err != vfs.OK {
		sink := begin(&klog)
		libodin.put_str(&sink, "bin: #b would not come up -- ")
		libodin.put_str(&sink, vectra9.errno_name(err))
		emit(&klog, .Fault, &sink)
		return false
	}
	if err := user.lib_init(vfs.boot_namespace); err != vfs.OK {
		sink := begin(&klog)
		libodin.put_str(&sink, "lib: #l would not come up -- ")
		libodin.put_str(&sink, vectra9.errno_name(err))
		emit(&klog, .Fault, &sink)
		return false
	}

	sink := begin(&klog)
	libodin.put_str(&sink, "bin #b bound at /bin, ")
	libodin.put_uint(&sink, u64(user.bin_programs()))
	libodin.put_str(&sink, " programs as files, formats VECTRA01 and 02; #l at /lib")
	emit(&klog, .Ok, &sink)
	return true
}

/*
init_user claims the fault path for programs.

One line of code and a milestone of consequence. Until it runs, a trap from
ring 3 falls through to `panic_trap` and stops the machine. That is the right
default for a privilege level nothing owns yet. After it, a program's fault
ends the program.

There is nothing to report that is not a self-test result, so this says nothing
on its own line. See `verify_user`.
*/
init_user :: proc() -> bool {
	if !user.init(vfs.boot_namespace) {
		log_line(&klog, .Warn, "syscall: this CPU has no SYSCALL instruction -- a program can only fault")
		return false
	}

	sink := begin(&klog)
	libodin.put_str(&sink, "syscall armed -- entry at ")
	libodin.put_hex(&sink, u64(arch.syscall_entry_address()), 16)
	libodin.put_str(&sink, ", /dev/cons is descriptor 1")
	emit(&klog, .Ok, &sink)
	return true
}

/*
console_column reports where the boot console's cursor is.

Handed to `user.verify` so it can check that a program's write reached the
screen, rather than that the write returned a number. This file is the only one
that owns a console, which is why the check reaches for a procedure rather than
an import.
*/
@(private = "file")
console_column :: proc "contextless" () -> int {
	return kcon.col
}

/*
verify_user runs seventeen processes in ring 3.

Four of them are refused something. Four ask the kernel for something. Three
open files by name in a namespace of their own. The loader brings three of
them out of files under `/bin`. One of those starts two more itself, the
only processes in the boot the kernel did not build.

The first is still the one that matters most. It runs, the timer takes the core
away from it, the kernel does work, and it gets the core back. Everything after
that is a rule being enforced, which is only interesting once there is
something running to enforce it against.
*/
verify_user :: proc() {
	result := user.verify(console_column)
	ok := libodin.passed(result.tally)

	sink := report_begin("user", result.checks)
	if ok {
		libodin.put_str(&sink, " userland checks passed -- ")
		libodin.put_uint(&sink, u64(result.programs))
		libodin.put_str(&sink, " processes, ")
		libodin.put_uint(&sink, u64(result.spawned))
		libodin.put_str(&sink, " started by another process, ")
		libodin.put_uint(&sink, result.rounds)
		libodin.put_str(&sink, " preempted rounds, ")
		libodin.put_uint(&sink, u64(result.calls))
		libodin.put_str(&sink, " system calls, ")
		libodin.put_uint(&sink, result.answered)
		libodin.put_str(&sink, " 9P requests answered by a process, a shell script in ")
		libodin.put_uint(&sink, u64(result.shell_ticks))
		libodin.put_str(&sink, " ticks and the tools in ")
		libodin.put_uint(&sink, u64(result.tools_ticks))
		libodin.put_str(
			&sink,
			", a typed line served by a process that forked",
		)
		emit(&klog, .Ok, &sink)
		return
	}

	report_failed(&sink, result.tally, result.leaked)
}
