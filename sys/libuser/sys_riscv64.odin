#+build riscv64
package libuser

/*
The door, and the instruction written as its four bytes.

`ecall` is `0x00000073`. The checker behind `asm` models the mnemonic as one
nothing returns from. That is the truth for a kernel and not for a program,
and the bytes say the same instruction without the claim.

The bindings are the convention every RISC-V kernel uses: the number in
`a7`, the arguments in `a0` to `a4`, and the answer back in `a0`. The kernel
keeps every other register, because the trap frame holds every register.
Each argument is tied to an output the wrapper drops, because the checker
counts a use per instruction and a byte is not one. One door of six
arguments, and `sys.odin` makes the narrower five out of it.

This file is the riscv64 half of `sys.odin`. `kernel/arch/riscv64/frame.odin`
is the other side of the agreement.
*/
@(private)
raw6 :: proc "contextless" (nr, a0, a1, a2, a3, a4, a5: u64) -> i64 {
	r, _, _, _, _, _, _ := asm(nr, a0, a1, a2, a3, a4, a5: u64) -> (r: i64, n: u64, x1: u64, x2: u64, x3: u64, x4: u64, x5: u64) [nr -> n = %a7, a0 -> r = %a0, a1 -> x1 = %a1, a2 -> x2 = %a2, a3 -> x3 = %a3, a4 -> x4 = %a4, a5 -> x5 = %a5, #clobber memory, #volatile] { #byte 0x73, 0x00, 0x00, 0x00 }(nr, a0, a1, a2, a3, a4, a5)
	return r
}
