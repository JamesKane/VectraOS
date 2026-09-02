/*
The kernel log.

Any core may write, and two sinks. The serial port works before the
framebuffer, and after a compositor crash.

The on-screen console is the only sink a user with no serial cable can read.
Both are best-effort. Neither may block boot.

Formatting goes through a fixed 512-byte line buffer per core. Nothing here
allocates, so this is safe to call from a fault handler. A line is built on the
caller's own core, with no lock held. The lock is taken for the length of the
write to the sinks. Two cores that log at once therefore produce two whole
lines in some order, and never one line made of both.

The buffer is per core rather than per caller, because a caller that has a `Sink` has nowhere else to
keep it. It is per core rather than shared, because a shared one is exactly
what a second core would write into.

Before the first core has a record behind `GS` there is one core, and it
formats into core 0's buffer. See `begin`.

A replay buffer holds the lines logged before the framebuffer exists, and
redraws them when the console attaches. The screen therefore shows the whole
boot, rather than the tail of it. Serial is unaffected -- it already received
them live.
*/
package kernel

import "kernel:arch"
import "kernel:drivers/console"
import "kernel:drivers/fb"
import "kernel:drivers/uart"
import "kernel:sched"
import "kernel:sync"
import "vsys:libodin"

Log_Level :: enum {
	Trace,
	Info,
	Ok,
	Warn,
	Fault,
}

/*
One buffered line, held until a screen exists to draw it on.

Sized well under the 512-byte formatting buffer on purpose. These are boot
survey lines, and the ones that matter are short. Those are the ones the screen
is missing. A longer line is kept up to the limit and marked, which beats
dropping it whole.
*/
EARLY_LINE_MAX :: 128
EARLY_LINES_MAX :: 16

Early_Line :: struct {
	level:     Log_Level,
	text:      [EARLY_LINE_MAX]u8,
	len:       int,
	truncated: bool,
}

Logger :: struct {
	serial: ^uart.Port,
	screen: ^console.Console,
	line:   [sched.MAX_CPUS][512]u8,

	// Over the sinks and the early buffer, never over the formatting. Held
	// for one line's writes. The panic path seizes it rather than takes it,
	// because the holder may be a core the panic just stopped.
	lock:   sync.Spinlock,

	// Replay buffer for lines emitted before `screen` was attached.
	early:          [EARLY_LINES_MAX]Early_Line,
	early_count:    int,
	early_overflow: bool,
}

@(private = "file")
log_tag :: proc "contextless" (level: Log_Level) -> (tag: string, color: fb.RGB) {
	switch level {
	case .Trace: return "  ..  ", fb.MAGNESIUM_LIT
	case .Info:  return "  --  ", fb.CYAN
	case .Ok:    return "  ok  ", fb.PHOSPHOR
	case .Warn:  return "  !!  ", fb.AMBER
	case .Fault: return " FAIL ", fb.ALERT
	}
	return "  ??  ", fb.MAGNESIUM_LIT
}

/*
begin starts a log line and returns the sink to format into.

The two-step begin and emit shape lets a caller build a line out of mixed
strings and numbers, with no varargs formatter. A formatter would need an
allocator, and there is none this early.
*/
begin :: proc "contextless" (l: ^Logger) -> libodin.Sink #no_bounds_check {
	id := 0
	if arch.percpu_ready() {
		id = arch.percpu_id()
	}
	return libodin.sink_from(l.line[id][:])
}

/*
emit writes a completed line to whichever sinks exist.

Serial gets it immediately. The console gets it now if it is attached, or on
replay from `attach_screen` if the framebuffer is not up yet. Colour is a
screen-only concern, so it is looked up in `draw_line` rather than here.
*/
emit :: proc "contextless" (l: ^Logger, level: Log_Level, s: ^libodin.Sink) {
	tag, _ := log_tag(level)
	body := libodin.str(s)

	// The lock names its holder by core, and a core has no name until its
	// record is behind `GS`. The first lines of the boot are logged before
	// that, by the only core there is, so they go unlocked. The first
	// `sync.acquire` of any kind in this kernel is here.
	guard, taken := lock_log(l)
	defer unlock_log(l, guard, taken)

	if l.serial != nil {
		uart.write_string(l.serial, "[")
		uart.write_string(l.serial, tag)
		uart.write_string(l.serial, "] ")
		uart.write_string(l.serial, body)
		if s.overflowed {
			uart.write_string(l.serial, " <truncated>")
		}
		uart.write_string(l.serial, "\n")
	}

	if l.screen == nil {
		stash_early(l, level, body, s.overflowed)
		return
	}
	draw_line(l, level, body, s.overflowed)
}

// draw_line puts one tagged line on the console.
@(private = "file")
draw_line :: proc "contextless" (l: ^Logger, level: Log_Level, body: string, truncated: bool) {
	tag, color := log_tag(level)

	// The tag is drawn in its own colour, the body in the console's, so a
	// column of status tags scans vertically at a glance.
	saved := l.screen.fg
	l.screen.fg = color
	console.write_string(l.screen, "[")
	console.write_string(l.screen, tag)
	console.write_string(l.screen, "] ")
	l.screen.fg = saved
	console.write_string(l.screen, body)
	if truncated {
		console.write_string(l.screen, " <truncated>")
	}
	console.write_string(l.screen, "\n")
}

@(private = "file")
stash_early :: proc "contextless" (l: ^Logger, level: Log_Level, body: string, truncated: bool) #no_bounds_check {
	if l.early_count >= EARLY_LINES_MAX {
		l.early_overflow = true
		return
	}

	slot := &l.early[l.early_count]
	l.early_count += 1

	slot.level = level
	slot.truncated = truncated
	n := min(len(body), EARLY_LINE_MAX)
	for i in 0 ..< n {
		slot.text[i] = body[i]
	}
	slot.len = n
	if n < len(body) {
		slot.truncated = true
	}
}

/*
attach_screen points the logger at a console and replays what it missed.

Called rather than a direct assignment to `screen`. The assignment alone would
leave everything logged before the framebuffer visible only on serial. That is
exactly the half of the boot a user with no serial cable most wants.
*/
attach_screen :: proc "contextless" (l: ^Logger, con: ^console.Console) #no_bounds_check {
	guard, taken := lock_log(l)
	l.screen = con

	for i in 0 ..< l.early_count {
		slot := &l.early[i]
		draw_line(l, slot.level, string(slot.text[:slot.len]), slot.truncated)
	}
	overflowed := l.early_overflow

	// The buffer did its job. Reset it so a later re-attach -- a panic screen
	// taking over, say -- does not redraw the whole boot again.
	l.early_count = 0
	l.early_overflow = false
	unlock_log(l, guard, taken)

	if overflowed {
		log_line(l, .Warn, "early log replay buffer overflowed; some boot lines are serial-only")
	}
}

// lock_log and unlock_log are the log's lock, taken only once a core has a
// record to name itself by. Before that there is one core and nothing to
// exclude, and a lock that asked the core's name would read address zero.
@(private = "file")
lock_log :: proc "contextless" (l: ^Logger) -> (guard: sync.Guard, taken: bool) {
	if !arch.percpu_ready() {
		return {}, false
	}
	return sync.acquire(&l.lock), true
}

@(private = "file")
unlock_log :: proc "contextless" (l: ^Logger, guard: sync.Guard, taken: bool) {
	if taken {
		sync.release(&l.lock, guard)
	}
}

// seize_log takes the log away from a core the panic path stopped, so the
// report can be written. Only that path calls it. See `sync.seize`.
seize_log :: proc "contextless" (l: ^Logger) {
	sync.seize(&l.lock)
}

// log_line is the common case: a level and one fixed string.
log_line :: proc "contextless" (l: ^Logger, level: Log_Level, text: string) {
	sink := begin(l)
	libodin.put_str(&sink, text)
	emit(l, level, &sink)
}
