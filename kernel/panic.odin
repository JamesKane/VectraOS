/*
The panic screen.

A fault the kernel cannot continue past gets the same chassis the boot splash
draws. An alert band takes the place of the copper bar's calm. The whole report
renders into the console well underneath it. Deliberately the same object: a
machine that panics should look like the machine that booted, not like a
different program took over.

Everything here also goes to the serial port. The panic that matters most is
the one on a machine whose framebuffer is the reason it panicked.

Three rules the code has to keep and the comments have to justify:

  - Nothing allocates. The heap may be the thing that broke, and by the time
    a page fault handler is deciding what to say there is no safe way to ask
    for memory.
  - Nothing can fault twice. A fault raised inside the panic path would arrive
    back here and loop forever, drawing over itself, so the re-entry guard is
    checked before anything touches the framebuffer.
  - Nothing returns. `panic_trap` hands `false` back to the arch dispatcher,
    which halts. `panic_stop` halts directly.
*/
package kernel

import "base:intrinsics"

import "kernel:arch"
import "kernel:drivers/console"
import "kernel:drivers/fb"
import "kernel:drivers/uart"
import "kernel:mem"
import "vsys:libodin"

// The console the panic report is drawn into. A global rather than a local
// because the logger is pointed at it and outlives the frame that made it.
@(private = "file") pcon: console.Console

/*
Re-entry guard.

Set before the first pixel goes down. A fault inside the drawing code then
comes back here, finds the flag, and stops with one line on the serial port.

That covers an unmapped framebuffer, and a console whose bounds no longer fit.
Without the flag it would recurse until the stack ran out.
*/
// The core that is reporting a fault, as its id plus one, or zero. A claim,
// because two cores can fault at once. The second to arrive is a second
// reporter, not a fault inside the panic handler, and it halts. Only the core
// that holds the claim writes the screen and the serial line.
@(private = "file") panic_core: u32

// claim_panic takes the report for this core. It answers true when this core
// already holds it, which is the panic path faulting inside itself. It halts
// when another core holds it, because one report is enough.
@(private = "file")
claim_panic :: proc "contextless" () -> (nested: bool) {
	me := u32(arch.percpu_id()) + 1
	if _, won := intrinsics.atomic_compare_exchange_strong(&panic_core, 0, me); won {
		return false
	}
	if intrinsics.atomic_load(&panic_core) == me {
		return true
	}
	arch.halt_forever()
}

// panicking reports whether any core holds the report, for the handlers that
// stop the other cores.
@(private = "file")
panicking :: proc "contextless" () -> bool {
	return intrinsics.atomic_load(&panic_core) != 0
}

/*
Set by the boot self-test around a deliberate `int3`.

The only trap Vectra currently expects to survive. As narrow as it looks. It is
armed immediately before the breakpoint, and the first breakpoint that arrives
disarms it. A stray #BP from anywhere else still panics.
*/
@(private = "file") expect_breakpoint: bool

arm_breakpoint_test :: proc "contextless" () {
	expect_breakpoint = true
}

breakpoint_test_fired :: proc "contextless" () -> bool {
	return !expect_breakpoint
}

/*
panic_trap is the handler `arch` calls for every trap that reaches the kernel.

Returns true to resume the interrupted instruction stream and false to stop the
machine. The only thing it ever resumes is the breakpoint the boot self-test
arms for itself. Everything else is a fault. A kernel with no scheduler and no
fault recovery has nothing useful to do with one but explain it.
*/
panic_trap :: proc "contextless" (t: ^arch.Trap) -> bool {
	if t.kind == .Breakpoint && expect_breakpoint {
		expect_breakpoint = false
		return true
	}

	if claim_panic() {
		// Second time through on this core: the panic path itself faulted.
		// Say so on the one sink that cannot be the cause and stop.
		if serial.present {
			uart.write_string(&serial, "\n[ FAIL ] fault inside the panic handler -- halting\n")
		}
		arch.halt_forever()
	}
	stop_other_cores()
	seize_log(&klog)

	open_panic_screen(t.name)

	sink := begin(&klog)
	libodin.put_str(&sink, t.name)
	libodin.put_str(&sink, " (vector ")
	libodin.put_uint(&sink, t.vector)
	libodin.put_str(&sink, ")")
	// Which ring the fault came from, because it changes what the report means.
	// A fault in the kernel is a bug in this image. A fault in a program that
	// reaches this screen is a program nothing claimed. Every address below it
	// is then in a space the kernel does not control.
	if t.user {
		libodin.put_str(&sink, " in a program, at ring 3")
	}
	emit(&klog, .Fault, &sink)

	sink = begin(&klog)
	libodin.put_str(&sink, "error code: ")
	arch.describe_error(&sink, t)
	if t.has_error && t.kind != .Double_Fault {
		libodin.put_str(&sink, " (raw ")
		libodin.put_hex(&sink, t.error_code, 0)
		libodin.put_str(&sink, ")")
	}
	emit(&klog, .Warn, &sink)

	if t.kind == .Page_Fault {
		report_faulting_address(t)
	}

	sink = begin(&klog)
	libodin.put_str(&sink, "at ")
	libodin.put_hex(&sink, u64(t.ip), 16)
	libodin.put_str(&sink, " on stack ")
	libodin.put_hex(&sink, u64(t.sp), 16)
	emit(&klog, .Warn, &sink)

	log_line(&klog, .Trace, "")
	for i in 0 ..< arch.REGISTER_LINES {
		sink = begin(&klog)
		arch.register_line(&sink, t, i)
		emit(&klog, .Trace, &sink)
	}

	report_backtrace(t)

	log_line(&klog, .Fault, "halted")
	return false
}

/*
report_backtrace scans the kernel stack for return addresses and prints them.

The registers say where the fault was. A backtrace says how it got there, which
a fault report was missing. This kernel keeps no frame pointer -- `rbp` is a
callee-saved register, not a frame link -- so there is no chain to follow.

The honest alternative is a scan. It reads the stack upward from the fault's
`rsp`. Every eight-byte slot whose value lands in the kernel's own text is a
probable return address. It over-reports, because a code pointer pushed as data reads the
same as a return address, and it says so by calling the line `maybe`.

**Every slot is validated before it is read.** A scan that ran off the mapped
stack would fault into the panic path, where a second fault truncates the
report the `panicking` guard protects. So `mem.translate` gates each read, and
the scan stops at the first unmapped slot or after `SCAN_SLOTS`.
*/
@(private = "file")
SCAN_SLOTS :: 256

@(private = "file")
BACKTRACE_MAX :: 16

@(private = "file")
report_backtrace :: proc "contextless" (t: ^arch.Trap) {
	if !memory_online {
		return
	}
	_ = scan_stack(t.sp, mem.kernel_address_space(), true)
}

/*
scan_stack reads up to `SCAN_SLOTS` eight-byte slots from `sp`, prints the ones
in kernel text when `show`, and answers how many it printed. `backtrace_depth`
is the same scan without the printing, for a self-test that has no fault to
provoke.
*/
@(private = "file")
scan_stack :: proc "contextless" (sp: uintptr, space: ^mem.Address_Space, show: bool) -> int {
	lo, hi := mem.kernel_text_range()
	at := sp & ~uintptr(7)
	found := 0
	for _ in 0 ..< SCAN_SLOTS {
		if found >= BACKTRACE_MAX {
			break
		}
		if _, ok := mem.translate(space, at); !ok {
			break
		}
		v := uintptr((^u64)(rawptr(at))^)
		if v >= lo && v < hi {
			if show {
				sink := begin(&klog)
				libodin.put_str(&sink, found == 0 ? "maybe " : "      ")
				libodin.put_hex(&sink, u64(v), 16)
				emit(&klog, .Trace, &sink)
			}
			found += 1
		}
		at += 8
	}
	return found
}

// backtrace_depth scans the live stack from `sp` and reports how many probable
// return addresses it found, without printing. A self-test hands it
// `arch.current_sp` from inside a chain of calls and checks the scan finds
// them. See `kernel/verify_sync.odin`.
backtrace_depth :: proc "contextless" (sp: u64) -> int {
	if !memory_online {
		return 0
	}
	return scan_stack(uintptr(sp), mem.kernel_address_space(), false)
}

/*
report_faulting_address says what was mapped at CR2, not just where it was.

The address alone rarely settles anything. 0x0 could be a null dereference, or
a jump through a nil proc pointer. An address in the middle of the kernel could
be a stray write, or a stack that ran off its end. What was actually mapped
there, and with what permissions, usually does settle it. `nothing mapped` and
`mapped read-only and you wrote to it` are different bugs that produce the same
CR2.
*/
@(private = "file")
report_faulting_address :: proc "contextless" (t: ^arch.Trap) {
	sink := begin(&klog)
	libodin.put_str(&sink, "faulting address ")
	libodin.put_hex(&sink, u64(t.fault_address), 16)
	emit(&klog, .Fault, &sink)

	// Only ask the VMM once it exists. Before `mem.init` the kernel is on
	// Limine's tables, which are not ours to walk and not described by anything
	// we could print.
	if !memory_online {
		return
	}

	space := mem.kernel_address_space()
	phys, mapped := mem.translate(space, t.fault_address)

	sink = begin(&klog)
	if !mapped {
		libodin.put_str(&sink, "  nothing is mapped there")
		emit(&klog, .Warn, &sink)
		return
	}

	flags, _ := mem.permissions(space, t.fault_address)
	libodin.put_str(&sink, "  mapped to ")
	libodin.put_hex(&sink, u64(phys), 16)
	// The familiar rwx triple, so "wrote to a read-only page" is one glance
	// rather than a sentence to parse.
	libodin.put_str(&sink, " r")
	libodin.put_str(&sink, .Write in flags ? "w" : "-")
	libodin.put_str(&sink, .No_Execute in flags ? "-" : "x")
	libodin.put_str(&sink, .User in flags ? " user" : " supervisor")
	if .Global in flags {
		libodin.put_str(&sink, " global")
	}
	emit(&klog, .Warn, &sink)
}

/*
panic_stop is the panic for things that are not traps.

A subsystem that cannot come up -- no memory map, no usable memory -- is just as
fatal as a fault and deserves the same screen. Separate from `panic_trap` only
because there is no register state to report.
*/
panic_stop :: proc "contextless" (reason: string) -> ! {
	if claim_panic() {
		arch.halt_forever()
	}
	stop_other_cores()
	seize_log(&klog)

	open_panic_screen("SYSTEM FAULT")
	log_line(&klog, .Fault, reason)
	log_line(&klog, .Fault, "halted")
	arch.halt_forever()
}

/*
open_panic_screen repaints the machine in its alert state and points the log at
it.

Redraws the whole chassis, rather than writes over the boot log. A panic screen
that is half old log and half new report is ambiguous about which lines belong
to the fault. The boot log is already on the serial port for anyone who wants
both.

`klog.screen` is assigned rather than passed to `attach_screen`. This is the
one place in the kernel where that difference matters.

`attach_screen` replays the early buffer. The boot replayed onto a panic screen
would push the fault off the top of it.
*/
@(private = "file")
open_panic_screen :: proc "contextless" (headline: string) {
	if screen.pixels == nil {
		// No framebuffer. The logger keeps its serial sink, and everything below
		// still reports. There is simply nothing to draw on.
		return
	}

	c := draw_chassis(&screen, "VECTRA", "FAULT")

	// The alert band takes the top of the well. It is styled as the copper title
	// bar's angry twin, so the two read as one control in two states.
	band := fb.Rect{c.well.x, c.well.y, c.well.w, TITLE_H}
	fb.gradient_v(&screen, band, fb.ALERT, fb.ALERT_DIM)
	fb.bevel_edges(&screen, band, .Raised, fb.mix(fb.ALERT, fb.AMBER_HOT, 90), fb.ALERT_DIM, 1)
	ty := band.y + (TITLE_H - console.FONT_HEIGHT) / 2
	draw_spaced(&screen, band.x + PAD, ty, headline, fb.SLATE_DEEP, 3, .Engraved)

	well := fb.inset_of(fb.Rect{c.well.x, band.y + band.h, c.well.w, c.well.h - band.h}, PAD)
	// Amber body text, not red. The band, the FAIL tags and the lamp already
	// carry the alarm. The report itself is mostly hex that a reader has to take
	// slowly, and a wall of red is the worst way to present it.
	pcon = console.init(&screen, well, fb.AMBER_HOT, fb.SLATE)
	klog.screen = &pcon

	draw_lamp_row(
		&screen,
		c.strip,
		{"PWR", "FB", "SER", "MEM", "FAULT"},
		{fb.PHOSPHOR, fb.CYAN, fb.AMBER, fb.PHOSPHOR, fb.ALERT},
		{true, true, serial.present, memory_online, true},
	)
}

/*
stop_other_cores halts every core but the one that is panicking.

A non-maskable interrupt to each, because a core may have interrupts off, and a
panic is not a thing to wait for. `on_nmi` is what the other cores run when it
lands: they see `panicking` set and halt where they are. The screen and the
serial line have no lock, so a core that kept running while this one painted
the fault could write over it. A core that kept running could also make the
fault worse. Nothing after this line has a second core to contend with.
*/
@(private = "file")
stop_other_cores :: proc "contextless" () {
	arch.ipi_stop_others()
}

/*
on_nmi is a non-maskable interrupt arriving on any core.

Two meanings and one flag between them. With `panicking` set, another core is
reporting a fault and this core is told to stop. It halts, on the NMI's own
stack, holding whatever it held. Without the flag, nothing in this kernel sends
an NMI. One is then hardware reporting something this kernel does not handle,
and that is a panic of its own.
*/
on_nmi :: proc "contextless" (r: arch.Resume) -> arch.Resume {
	if panicking() {
		arch.halt_forever()
	}
	panic_stop("unexpected non-maskable interrupt")
}
