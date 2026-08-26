/*
The kernel log.

One writer, two sinks: the serial port (which works before the framebuffer and
after a compositor crash) and the on-screen console (which is the only sink a
user without a serial cable can read). Both are best-effort; neither is allowed
to block boot.

Formatting goes through a fixed 512-byte line buffer. Nothing here allocates,
so this is safe to call from a fault handler.

Lines logged before the framebuffer exists are held in a replay buffer and
re-drawn when the console attaches, so the screen shows the whole boot rather
than the tail of it. Serial is unaffected -- it already received them live.
*/
package kernel

import "kernel:drivers/console"
import "kernel:drivers/fb"
import "kernel:drivers/uart"
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

Sized well under the 512-byte formatting buffer on purpose: these are boot
survey lines, and the ones that matter -- the ones the screen is missing -- are
short. A longer line is kept up to the limit and marked, which beats dropping
it whole.
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
	line:   [512]u8,

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

The two-step begin/emit shape exists so a caller can build a line out of mixed
strings and numbers without a varargs formatter -- which would need an
allocator we do not have this early.
*/
begin :: proc "contextless" (l: ^Logger) -> libodin.Sink {
	return libodin.sink_from(l.line[:])
}

/*
emit writes a completed line to whichever sinks exist.

Serial gets it immediately; the console gets it now if attached, or on replay
from `attach_screen` if the framebuffer is not up yet. Colour is a screen-only
concern, so it is looked up in `draw_line` rather than here.
*/
emit :: proc "contextless" (l: ^Logger, level: Log_Level, s: ^libodin.Sink) {
	tag, _ := log_tag(level)
	body := libodin.str(s)

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

Called instead of assigning `screen` directly: the assignment alone would leave
everything logged before the framebuffer came up visible only on serial, which
is exactly the half of the boot a user without a serial cable most wants.
*/
attach_screen :: proc "contextless" (l: ^Logger, con: ^console.Console) #no_bounds_check {
	l.screen = con

	for i in 0 ..< l.early_count {
		slot := &l.early[i]
		draw_line(l, slot.level, string(slot.text[:slot.len]), slot.truncated)
	}

	if l.early_overflow {
		log_line(l, .Warn, "early log replay buffer overflowed; some boot lines are serial-only")
	}

	// The buffer has done its job. Reset it so a later re-attach -- a panic
	// screen taking over, say -- does not redraw the whole boot again.
	l.early_count = 0
	l.early_overflow = false
}

// log_line is the common case: a level and one fixed string.
log_line :: proc "contextless" (l: ^Logger, level: Log_Level, text: string) {
	sink := begin(l)
	libodin.put_str(&sink, text)
	emit(l, level, &sink)
}
