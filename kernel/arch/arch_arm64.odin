/*
The aarch64 binding of the architecture interface.

Not yet implemented. The file exists so a `-target:freestanding_arm64` build
fails at the missing bodies below, rather than at a missing package. The port
stays a matter of blanks to fill in.
*/
#+build arm64
package arch

NAME :: "arm64"
PAGE_SIZE :: 4096

halt_forever :: proc "contextless" () -> ! {
	for {}
}

disable_interrupts :: proc "contextless" () {}
enable_interrupts :: proc "contextless" () {}
wait_for_interrupt :: proc "contextless" () {}
spin_hint :: proc "contextless" () {}
early_init :: proc "contextless" () {}
