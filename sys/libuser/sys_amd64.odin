#+build amd64
package libuser

/*
The door, six widths of it, and the instruction written as its two bytes.

`syscall` is `0x0F 0x05`. The checker behind `asm` models the mnemonic as
one nothing returns from. That is the truth for a kernel and not for a
program, and the bytes say the same instruction without the claim.

The bindings are the System V syscall convention. The number and the answer
are in `rax`, and the arguments in `rdi`, `rsi`, `rdx`, `r10` and `r8`. The
instruction has `rcx` and `r11` for itself, to park the return address and
the flags. Each argument is tied to an output the wrapper drops. The
checker counts a use per instruction, and a byte is not one.

This file is the amd64 half of `sys.odin`. A port supplies its own five
doors under its own suffix and changes nothing above them.
*/
@(private)
raw1 :: proc "contextless" (nr, a0: u64) -> i64 {
	r, _ := asm(nr, a0: u64) -> (r: i64, x0: u64) [nr -> r = %rax, a0 -> x0 = %rdi, #clobber %rcx, #clobber %r11, #clobber memory, #volatile] { #byte 0x0F, 0x05 }(nr, a0)
	return r
}

@(private)
raw2 :: proc "contextless" (nr, a0, a1: u64) -> i64 {
	r, _, _ := asm(nr, a0, a1: u64) -> (r: i64, x0: u64, x1: u64) [nr -> r = %rax, a0 -> x0 = %rdi, a1 -> x1 = %rsi, #clobber %rcx, #clobber %r11, #clobber memory, #volatile] { #byte 0x0F, 0x05 }(nr, a0, a1)
	return r
}

@(private)
raw3 :: proc "contextless" (nr, a0, a1, a2: u64) -> i64 {
	r, _, _, _ := asm(nr, a0, a1, a2: u64) -> (r: i64, x0: u64, x1: u64, x2: u64) [nr -> r = %rax, a0 -> x0 = %rdi, a1 -> x1 = %rsi, a2 -> x2 = %rdx, #clobber %rcx, #clobber %r11, #clobber memory, #volatile] { #byte 0x0F, 0x05 }(nr, a0, a1, a2)
	return r
}

@(private)
raw4 :: proc "contextless" (nr, a0, a1, a2, a3: u64) -> i64 {
	r, _, _, _, _ := asm(nr, a0, a1, a2, a3: u64) -> (r: i64, x0: u64, x1: u64, x2: u64, x3: u64) [nr -> r = %rax, a0 -> x0 = %rdi, a1 -> x1 = %rsi, a2 -> x2 = %rdx, a3 -> x3 = %r10, #clobber %rcx, #clobber %r11, #clobber memory, #volatile] { #byte 0x0F, 0x05 }(nr, a0, a1, a2, a3)
	return r
}

@(private)
raw5 :: proc "contextless" (nr, a0, a1, a2, a3, a4: u64) -> i64 {
	r, _, _, _, _, _ := asm(nr, a0, a1, a2, a3, a4: u64) -> (r: i64, x0: u64, x1: u64, x2: u64, x3: u64, x4: u64) [nr -> r = %rax, a0 -> x0 = %rdi, a1 -> x1 = %rsi, a2 -> x2 = %rdx, a3 -> x3 = %r10, a4 -> x4 = %r8, #clobber %rcx, #clobber %r11, #clobber memory, #volatile] { #byte 0x0F, 0x05 }(nr, a0, a1, a2, a3, a4)
	return r
}

@(private)
raw6 :: proc "contextless" (nr, a0, a1, a2, a3, a4, a5: u64) -> i64 {
	r, _, _, _, _, _, _ := asm(nr, a0, a1, a2, a3, a4, a5: u64) -> (r: i64, x0: u64, x1: u64, x2: u64, x3: u64, x4: u64, x5: u64) [nr -> r = %rax, a0 -> x0 = %rdi, a1 -> x1 = %rsi, a2 -> x2 = %rdx, a3 -> x3 = %r10, a4 -> x4 = %r8, a5 -> x5 = %r9, #clobber %rcx, #clobber %r11, #clobber memory, #volatile] { #byte 0x0F, 0x05 }(nr, a0, a1, a2, a3, a4, a5)
	return r
}
