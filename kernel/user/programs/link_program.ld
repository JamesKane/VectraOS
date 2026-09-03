/*
 * The layout of a test program: one segment, at the address the loader
 * copies it to, with its read-only data behind its text. The entry is the
 * first byte, because the loader jumps to the page's start. build.odin
 * refuses a program that links with a second segment, which is what a
 * global would produce, and this script is why a correct one never has.
 */
ENTRY(_start)
SECTIONS {
	. = 0x400000;
	.text : {
		KEEP(*(.text.start))
		*(.text .text.*)
		*(.rodata .rodata.* .srodata .srodata.*)
	}
	.data : { *(.data .data.* .sdata .sdata.*) *(.got .got.*) }
	.bss : { *(.bss .bss.* .sbss .sbss.*) *(COMMON) }
	/DISCARD/ : { *(.comment .note.* .eh_frame .eh_frame_hdr .riscv.attributes) }
}
