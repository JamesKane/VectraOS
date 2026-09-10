/*
The 8042 keyboard controller, as far as two drivers drive it.

The keyboard is on its first port and the mouse on its second. Both drivers
talk to the controller through the same two I/O ports. The waits below are
bounded, and every caller names its own bound. A controller that never
answers is a machine with no such device, and not a reason to stop the boot.
*/
package kbd

import "kernel:arch"

// The 8042's two ports. Data carries scancodes in and commands out. The second
// is status when read and command when written.
PORT_DATA :: u16(0x60)
PORT_STATUS :: u16(0x64)

// The status bits the drivers read. Output full means the controller has a
// byte for us, and reading the data port with it clear returns whatever was
// there last time. Input full means the controller has not yet taken the last
// byte written to it. A command written while it is set is lost.
STATUS_OUTPUT_FULL :: u8(0x01)
STATUS_INPUT_FULL :: u8(0x02)

// wait_input waits, bounded, until the controller will take a byte.
wait_input :: proc "contextless" (bound: int) -> bool {
	for _ in 0 ..< bound {
		if arch.inb(PORT_STATUS) & STATUS_INPUT_FULL == 0 {
			return true
		}
	}
	return false
}

// wait_output waits, bounded, for a byte from the controller, and answers
// it. What it answers may be the keyboard's rather than the mouse's, and
// a caller that cares asks for the acknowledgement it expects.
wait_output :: proc "contextless" (bound: int) -> (b: u8, ok: bool) {
	for _ in 0 ..< bound {
		if arch.inb(PORT_STATUS) & STATUS_OUTPUT_FULL != 0 {
			return arch.inb(PORT_DATA), true
		}
	}
	return 0, false
}

// controller_command writes one command to the controller once it will take
// one, and reports whether it did.
controller_command :: proc "contextless" (cmd: u8, bound: int) -> bool {
	if !wait_input(bound) {
		return false
	}
	arch.outb(PORT_STATUS, cmd)
	return true
}
