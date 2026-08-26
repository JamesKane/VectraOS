/*
The riscv64 binding of the architecture interface. Not yet implemented; see
`arch_arm64.odin` for the rationale behind the stub.
*/
#+build riscv64
package arch

NAME :: "riscv64"
PAGE_SIZE :: 4096

halt_forever :: proc "contextless" () -> ! {
	for {}
}

disable_interrupts :: proc "contextless" () {}
enable_interrupts :: proc "contextless" () {}
wait_for_interrupt :: proc "contextless" () {}
spin_hint :: proc "contextless" () {}
early_init :: proc "contextless" () {}
