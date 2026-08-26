/*
The 8253/8254 interval timer, used for one thing only.

Vectra does not schedule on the PIT -- the LAPIC timer is per-CPU and the PIT is
not -- but the LAPIC timer runs at an undocumented frequency derived from the
bus clock, and something has to tell it what a second is. The PIT is the one
clock on a PC whose rate is a constant of the architecture rather than a
property of the machine, so it is the ruler and the LAPIC is what gets measured.

Channel 2 rather than channel 0, because channel 2's gate is under software
control through port 0x61 and its output is readable there. That means a
calibration can be *polled* -- start it, spin, read it -- with no interrupt
handler, no vector, and nothing that has to be true about the PIC. Channel 0
would need all three, at a point in the boot before any of them are ready.
*/
package amd64

// 1.193182 MHz: the NTSC colourburst divided by three, which is why it is not a
// round number and why every PC has kept it for forty years.
PIT_FREQUENCY :: 1_193_182

PIT_CHANNEL2 :: u16(0x42)
PIT_COMMAND :: u16(0x43)

/*
Port 0x61 -- the "system control port", of which three bits matter here:

    bit 0   channel 2 gate: the counter only counts while this is high
    bit 1   speaker enable: left clear, or the calibration is audible
    bit 5   channel 2 output: what mode 0 drives high when the count expires
*/
PIT_CONTROL_PORT :: u16(0x61)
PIT_GATE :: u8(1 << 0)
PIT_SPEAKER :: u8(1 << 1)
PIT_OUTPUT :: u8(1 << 5)

// Channel 2, access lobyte then hibyte, mode 0 (interrupt on terminal count),
// binary. Mode 0 is the one that holds its output low from the moment the
// control word is written until the count runs out, which is exactly the shape
// of "tell me when this much time has passed".
PIT_MODE0_CHANNEL2 :: u8(0b10_11_000_0)

/*
pit_count_for_micros converts microseconds to counter ticks.

Clamped rather than wrapped. A request longer than the 16-bit counter can hold
-- about 54.9 ms -- becomes the longest interval it can, which makes a
calibration less precise; letting it wrap would make one silently wrong.
*/
pit_count_for_micros :: proc "contextless" (micros: u64) -> u16 {
	count := (u64(PIT_FREQUENCY) * micros) / 1_000_000
	if count > 0xFFFF {
		return 0xFFFF
	}
	if count == 0 {
		return 1
	}
	return u16(count)
}

/*
pit_gate_arm loads the counter with the gate held low, so nothing starts yet.

Split from `pit_gate_start` because whatever is being measured has to be
started too, and the two starts should be as close together as the instruction
stream allows. Everything slow -- three port writes, each of which is a bus
transaction -- happens here.
*/
pit_gate_arm :: proc "contextless" (count: u16) {
	control := inb(PIT_CONTROL_PORT) & ~(PIT_GATE | PIT_SPEAKER)
	outb(PIT_CONTROL_PORT, control)

	outb(PIT_COMMAND, PIT_MODE0_CHANNEL2)
	io_wait()
	outb(PIT_CHANNEL2, u8(count))
	io_wait()
	outb(PIT_CHANNEL2, u8(count >> 8))
}

// pit_gate_start raises the gate. The counter begins on this write.
pit_gate_start :: proc "contextless" () {
	control := inb(PIT_CONTROL_PORT) & ~PIT_SPEAKER
	outb(PIT_CONTROL_PORT, control | PIT_GATE)
}

pit_gate_expired :: proc "contextless" () -> bool {
	return inb(PIT_CONTROL_PORT) & PIT_OUTPUT != 0
}

// pit_gate_stop drops the gate and leaves the speaker off, which is the state
// the firmware handed us and the state anything else expects to find.
pit_gate_stop :: proc "contextless" () {
	outb(PIT_CONTROL_PORT, inb(PIT_CONTROL_PORT) & ~(PIT_GATE | PIT_SPEAKER))
}
