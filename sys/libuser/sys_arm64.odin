#+build arm64
package libuser

/*
The door, six widths of it, and the instruction written as its four bytes.

`svc #0` is `0xD4000001`. The checker behind `asm` models the mnemonic as
one nothing returns from. That is the truth for a kernel and not for a
program, and the bytes say the same instruction without the claim.

The bindings are the convention every AArch64 kernel uses: the number in
`x8`, the arguments in `x0` to `x4`, and the answer back in `x0`. The kernel
keeps every other register, because the trap frame holds every register.
Each argument is tied to an output the wrapper drops, because the checker
counts a use per instruction and a byte is not one.

This file is the arm64 half of `sys.odin`. `kernel/arch/arm64/frame.odin`
is the other side of the agreement.
*/
@(private)
raw1 :: proc "contextless" (nr, a0: u64) -> i64 {
	r, _ := asm(nr, a0: u64) -> (r: i64, n: u64) [nr -> n = %x8, a0 -> r = %x0, #clobber memory, #volatile] { #byte 0x01, 0x00, 0x00, 0xD4 }(nr, a0)
	return r
}

@(private)
raw2 :: proc "contextless" (nr, a0, a1: u64) -> i64 {
	r, _, _ := asm(nr, a0, a1: u64) -> (r: i64, n: u64, x1: u64) [nr -> n = %x8, a0 -> r = %x0, a1 -> x1 = %x1, #clobber memory, #volatile] { #byte 0x01, 0x00, 0x00, 0xD4 }(nr, a0, a1)
	return r
}

@(private)
raw3 :: proc "contextless" (nr, a0, a1, a2: u64) -> i64 {
	r, _, _, _ := asm(nr, a0, a1, a2: u64) -> (r: i64, n: u64, x1: u64, x2: u64) [nr -> n = %x8, a0 -> r = %x0, a1 -> x1 = %x1, a2 -> x2 = %x2, #clobber memory, #volatile] { #byte 0x01, 0x00, 0x00, 0xD4 }(nr, a0, a1, a2)
	return r
}

@(private)
raw4 :: proc "contextless" (nr, a0, a1, a2, a3: u64) -> i64 {
	r, _, _, _, _ := asm(nr, a0, a1, a2, a3: u64) -> (r: i64, n: u64, x1: u64, x2: u64, x3: u64) [nr -> n = %x8, a0 -> r = %x0, a1 -> x1 = %x1, a2 -> x2 = %x2, a3 -> x3 = %x3, #clobber memory, #volatile] { #byte 0x01, 0x00, 0x00, 0xD4 }(nr, a0, a1, a2, a3)
	return r
}

@(private)
raw5 :: proc "contextless" (nr, a0, a1, a2, a3, a4: u64) -> i64 {
	r, _, _, _, _, _ := asm(nr, a0, a1, a2, a3, a4: u64) -> (r: i64, n: u64, x1: u64, x2: u64, x3: u64, x4: u64) [nr -> n = %x8, a0 -> r = %x0, a1 -> x1 = %x1, a2 -> x2 = %x2, a3 -> x3 = %x3, a4 -> x4 = %x4, #clobber memory, #volatile] { #byte 0x01, 0x00, 0x00, 0xD4 }(nr, a0, a1, a2, a3, a4)
	return r
}

@(private)
raw6 :: proc "contextless" (nr, a0, a1, a2, a3, a4, a5: u64) -> i64 {
	r, _, _, _, _, _, _ := asm(nr, a0, a1, a2, a3, a4, a5: u64) -> (r: i64, n: u64, x1: u64, x2: u64, x3: u64, x4: u64, x5: u64) [nr -> n = %x8, a0 -> r = %x0, a1 -> x1 = %x1, a2 -> x2 = %x2, a3 -> x3 = %x3, a4 -> x4 = %x4, a5 -> x5 = %x5, #clobber memory, #volatile] { #byte 0x01, 0x00, 0x00, 0xD4 }(nr, a0, a1, a2, a3, a4, a5)
	return r
}
