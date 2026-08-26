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
@(private = "file") panicking: bool

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

	if panicking {
		// Second time through: the panic path itself faulted. Say so on the
		// one sink that cannot be the cause and stop.
		if serial.present {
			uart.write_string(&serial, "\n[ FAIL ] fault inside the panic handler -- halting\n")
		}
		arch.halt_forever()
	}
	panicking = true

	open_panic_screen(t.name)

	sink := begin(&klog)
	libodin.put_str(&sink, t.name)
	libodin.put_str(&sink, " (vector ")
	libodin.put_uint(&sink, t.vector)
	libodin.put_str(&sink, ")")
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

	log_line(&klog, .Fault, "halted")
	return false
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
	if panicking {
		arch.halt_forever()
	}
	panicking = true

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
