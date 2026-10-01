/* The kernel's layout (aarch64). Limine loads it in the top 2 GiB. Each segment
   has one set of permissions, so no mapping is both writable and executable. */
OUTPUT_FORMAT(elf64-littleaarch64)
ENTRY(_start)

PHDRS {
    text   PT_LOAD FLAGS(5);   /* R X */
    rodata PT_LOAD FLAGS(4);   /* R   */
    data   PT_LOAD FLAGS(6);   /* R W */
}

SECTIONS {
    . = 0xffffffff80000000;

    .text : { *(.text .text.*) } :text

    . = ALIGN(CONSTANT(MAXPAGESIZE));
    .rodata : { *(.rodata .rodata.*) } :rodata
    .note.gnu.build-id : { *(.note.gnu.build-id) } :rodata

    . = ALIGN(CONSTANT(MAXPAGESIZE));
    .data : {
        /* Limine looks for its requests between these markers (kernel/boot.c). */
        KEEP(*(.limine_requests_start))
        KEEP(*(.limine_requests))
        KEEP(*(.limine_requests_end))
        *(.data .data.*)
    } :data
    .bss : { *(.bss .bss.*) *(COMMON) } :data

    /DISCARD/ : { *(.eh_frame*) *(.note.GNU-stack) *(.comment) }
}
