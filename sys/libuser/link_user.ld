/*
 * The layout of a ring 3 program, for every program alike.
 *
 * Text at the address the loader has always used, then each change of
 * permission on its own page boundary. The alignment is load-bearing: the
 * kernel maps whole pages, and a segment that starts mid-page would share a
 * page with bytes that want different flags. build.odin refuses an unaligned
 * segment rather than map one, and this script is why it never sees one.
 *
 * The small-data sections are RISC-V's, and they go where their full-sized
 * namesakes go. Left out, the linker places them on its own, in a segment of
 * their own, at whatever address follows -- which is the unaligned segment
 * above.
 */
ENTRY(_start)
SECTIONS {
	. = 0x400000;
	.text : { *(.text .text.*) }
	. = ALIGN(0x1000);
	.rodata : { *(.rodata .rodata.* .srodata .srodata.*) }
	. = ALIGN(0x1000);
	.data : { *(.data .data.* .sdata .sdata.*) *(.got .got.*) }
	.bss : { *(.bss .bss.* .sbss .sbss.*) *(COMMON) }
	/DISCARD/ : { *(.comment .note.* .eh_frame .eh_frame_hdr) }
}
