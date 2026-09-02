/*
The other cores, and how each one arrives.

The bootloader parks every core but the first, each spinning on a word of its
own. A store to that word sends the core to the address stored, in the
machine state the first core got: long mode, the bootloader's page tables, a
bootloader stack, interrupts off, no IDT and no TSS. Everything the first core
did in `kmain` before it had a scheduler, this core does in `ap_main`, in the
same order and for the same reasons. `docs/SMP.md` argues the whole of it.

    ap_entry     on the bootloader's stack and tables: SSE on, then leave both
    ap_main      on the kernel's: traps, paging bits, syscall, APIC, a
                 scheduler record, a timer, and then exit into idle

**The cores start last.** Every self-test in `kmain` was written for one
core, and each says so where it counts something. They all run first, and the
cores come up after, so that what they check stays what they checked. The
boot core reports for every core, because the log has no lock and a core
that logged for itself would interleave with the boot core's line.
*/
package kernel

import "base:intrinsics"
import "base:runtime"

import "kernel:arch"
import "kernel:boot/limine"
import "kernel:mem"
import "kernel:sched"
import "kernel:sync"
import "vsys:libodin"

// A core's kernel stack, on which its arrival thread runs until it exits
// into idle. The scheduler's default, because the arrival does a spawn.
AP_STACK_SIZE :: sched.DEFAULT_STACK_SIZE

// How many ticks the boot core gives the last core to report. A core that
// takes longer than this is a core that is not coming.
SMP_PATIENCE :: 200

// What the boot core prepares for one core and the core reads on arrival.
// Filled in before the release store, which is what makes it visible.
Ap_Boot :: struct {
	stack:  []u8,
	id:     int,
	lapic:  u32,
	online: bool,
}

@(private = "file")
ap_boots: [sched.MAX_CPUS]Ap_Boot

// How many cores were released. Ids 1 through this number, in list order.
@(private = "file")
ap_released: int

/*
ap_entry is where a released core lands, with the bootloader's stack under
it and the bootloader's page tables around it.

Two things and no more. SSE on, because the next Odin statement may use an
XMM register for an ordinary move, exactly as `kmain`'s first line does. Then
onto this core's own stack and the kernel's tables, through `arch.ap_switch`,
which is the only way out of a stack. The record it needs is in the kernel's
image, which both sets of tables map at the same address. The stack it moves
to is heap memory only the kernel's tables map, and its address is all this
side reads.
*/
@(private = "file")
ap_entry :: proc "sysv" (info: ^limine.MP_Info) -> ! {
	arch.early_init()
	b := &ap_boots[int(info.extra_argument)]
	arch.ap_switch(
		arch.kernel_stack_top(b.stack),
		mem.space_root(mem.kernel_address_space()),
		ap_main,
		b,
	)
}

/*
ap_main is `kmain` for a core that is not the first, from the point the two
diverge.

The order is the boot core's. Traps before anything that can fault. The
paging bits, because the bootloader clears every one it does not need, and
`CR0.WP` and `EFER.NXE` are what make the kernel's own mappings mean what
they say. The syscall MSRs, because they are per core and a program may be
dispatched here. The APIC, per core for its enable bit, on the page the boot
core mapped. Then a scheduler record, a timer at the rate the boot core
measured, and the report.

`cpu_online` comes after the timer, because a core that dispatches has to
preempt, and before `exit`, because the arrival thread's exit is what puts
the idle thread on the core. The exit is the arrival's whole future: the
stack it stands on goes back to the heap when the idle thread reaps it.
*/
@(private = "file")
ap_main :: proc "sysv" (arg: rawptr) -> ! {
	b := cast(^Ap_Boot)arg

	arch.init_traps_ap(b.id)
	arch.enable_paging_features()
	_ = arch.syscall_init()
	arch.timer_attach_here()

	context = runtime.default_context()
	context.allocator = mem.allocator()

	if !sched.init_ap(b.id, b.stack) || !sched.start_timer_here() {
		// No thread to become and no clock to be preempted by. This core
		// stays silent, and the boot core reports it missing.
		arch.halt_forever()
	}

	intrinsics.volatile_store(&b.online, true)
	sched.cpu_online()
	sched.exit()
}

/*
init_smp releases every core the bootloader listed, and waits for each to
report.

A stack per core first, from the heap, because the bootloader's is not
ours. Then the record, then the id in `extra_argument`, and then the store to
`goto_address`, atomic, so that a core sees the record whole or not at all.
The wait is bounded. A core that never reports is reported missing rather
than waited for, and the machine runs on the cores that came.

Reports false when no second core was released, which is a one-core machine
or a bootloader without the feature. The kernel is complete on one core, so
that is a fact and not a fault.
*/
init_smp :: proc() -> bool {
	mp := mp_request.response
	if mp == nil || mp.cpu_count <= 1 {
		log_line(&klog, .Info, "smp: one core, and nothing to start")
		return false
	}

	next := 1
	for i in 0 ..< int(mp.cpu_count) {
		info := mp.cpus[i]
		if info.lapic_id == mp.bsp_lapic_id {
			continue
		}
		if next >= sched.MAX_CPUS {
			break
		}
		stack := make([]u8, AP_STACK_SIZE)
		if stack == nil {
			break
		}
		b := &ap_boots[next]
		b.stack = stack
		b.id = next
		b.lapic = info.lapic_id
		b.online = false
		info.extra_argument = u64(next)
		intrinsics.atomic_store(
			cast(^u64)&info.goto_address,
			u64(uintptr(rawptr(ap_entry))),
		)
		next += 1
	}
	ap_released = next - 1
	if ap_released == 0 {
		log_line(&klog, .Warn, "smp: the bootloader listed cores, and none could be released")
		return false
	}

	all := sync.await(all_online, nil, SMP_PATIENCE)

	sink := begin(&klog)
	libodin.put_str(&sink, "smp: ")
	libodin.put_uint(&sink, u64(sched.online_count()))
	libodin.put_str(&sink, " of ")
	libodin.put_uint(&sink, u64(ap_released + 1))
	libodin.put_str(&sink, " cores online -- lapic ids")
	for i in 0 ..= ap_released {
		libodin.put_str(&sink, " ")
		libodin.put_uint(&sink, u64(i == 0 ? mp.bsp_lapic_id : ap_boots[i].lapic))
		if i > 0 && !intrinsics.volatile_load(&ap_boots[i].online) {
			libodin.put_str(&sink, "(missing)")
		}
	}
	emit(&klog, all ? .Ok : .Fault, &sink)
	return all
}

@(private = "file")
all_online :: proc "contextless" (arg: rawptr) -> bool {
	_ = arg
	for i in 1 ..= ap_released {
		if !intrinsics.volatile_load(&ap_boots[i].online) {
			return false
		}
	}
	return true
}
