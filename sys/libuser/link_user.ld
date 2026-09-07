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
 *
 * `.init_array` holds the constructors a C++ program registers, and `crt0`
 * runs them between its two bounds. `.tdata`/`.tbss` are the initial
 * thread-local image, and `__tdata_start`/`__tbss_end` are the bounds
 * `crt0` copies for a per-proc thread pointer -- see `docs/DEVTOOLS.md`
 * section 3. Both sit in the data segment, so no new permission boundary
 * is made.
 */
ENTRY(_start)
SECTIONS {
	. = 0x400000;
	.text : { *(.text .text.*) }
	. = ALIGN(0x1000);
	.rodata : { *(.rodata .rodata.* .srodata .srodata.*) }
	. = ALIGN(0x1000);
	.data : { *(.data .data.* .sdata .sdata.*) *(.got .got.*) }
	.init_array : {
		__init_array_start = .;
		KEEP(*(.init_array .init_array.* .ctors))
		__init_array_end = .;
	}
	.tdata : {
		__tdata_start = .;
		*(.tdata .tdata.*)
		__tdata_end = .;
	}
	.tbss : {
		*(.tbss .tbss.*)
		__tbss_end = .;
	}
	.bss : { *(.bss .bss.* .sbss .sbss.*) *(COMMON) }
	/DISCARD/ : { *(.comment .note.* .eh_frame .eh_frame_hdr) }
}
