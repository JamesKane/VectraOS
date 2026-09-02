/*
 * vectra_load_gdt(pointer, code, data): load the GDT and reload every segment
 * register from it. CS by a far return onto the label below, the rest by
 * `mov`. `gdt.odin` explains the table this points at.
 */
	.text
	.balign 16
	.globl vectra_load_gdt
vectra_load_gdt:
	lgdt (%rdi)
	pushq %rsi
	leaq 1f(%rip), %rax
	pushq %rax
	lretq
1:
	movw %dx, %ax
	movw %ax, %ds
	movw %ax, %es
	movw %ax, %ss
	xorw %ax, %ax
	movw %ax, %fs
	movw %ax, %gs
	ret
