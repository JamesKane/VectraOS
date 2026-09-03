/*
 * Vectra riscv64 kernel image layout for the Limine boot protocol.
 *
 * The same layout as `link_amd64.ld`, for the same reasons, and with the same
 * segment bounds exported: `kernel/mem/vmm.odin` maps the image from them on
 * every architecture. What differs is the object format, the relocation type
 * the bootloader applies (R_RISCV_RELATIVE), and the small-data sections the
 * RISC-V ABI adds, which go where their full-sized namesakes go. Read the
 * amd64 script for the argument behind each section.
 *
 * The kernel is a static-PIE ELF loaded into the topmost 2GiB of the address
 * space. The bootloader applies our relocations, so the .rela sections must
 * survive into the image; discarding them the way a non-PIE kernel would leaves
 * every global pointer pointing at its link-time address.
 *
 * Each output segment is page-aligned into its own PT_LOAD so that Limine can
 * map .text as execute-only-ish, .rodata read-only, and .data writable, rather
 * than mapping the whole image RWX.
 *
 * The .limine_requests* sections are ordered start / body / end and placed in
 * the writable segment. Under base revision 2 and above the delimiters are
 * binding: the bootloader reads only what falls between them, and it writes
 * response pointers and the base revision answer back into that memory.
 *
 * Each segment's bounds are exported as __<name>_start/__<name>_end symbols and
 * padded out to a page. kernel/mem/vmm.odin maps the kernel image a segment at
 * a time using them, so the permissions the VMM installs are derived from this
 * file rather than restated in Odin and left to drift out of step with it. The
 * symbols are declared inside their output sections deliberately: defined
 * between sections instead, they become orphans that ld is free to attach to
 * whichever segment it likes.
 */

OUTPUT_FORMAT(elf64-littleriscv)
OUTPUT_ARCH(riscv)
ENTRY(_start)

PHDRS
{
    text    PT_LOAD    FLAGS((1 << 0) | (1 << 2)) ; /* R+X */
    rodata  PT_LOAD    FLAGS((1 << 2)) ;            /* R   */
    data    PT_LOAD    FLAGS((1 << 1) | (1 << 2)) ; /* R+W */
    dynamic PT_DYNAMIC FLAGS((1 << 1) | (1 << 2)) ;
}

SECTIONS
{
    /* Top 2GiB: where the protocol says to be, and within the +-2GiB reach
       of the auipc pairs the compiler emits for a position-independent image. */
    . = 0xffffffff80000000;

    .text : {
        __text_start = .;
        *(.text .text.*)
        . = ALIGN(CONSTANT(MAXPAGESIZE));
        __text_end = .;
    } :text

    . += CONSTANT(MAXPAGESIZE);

    .rodata : {
        __rodata_start = .;
        *(.rodata .rodata.* .srodata .srodata.*)
    } :rodata

    /* Relocations live with .rodata: read-only, but they must be present in
       the loaded image for the bootloader to walk. */
    .rela : {
        *(.rela .rela.*)
        . = ALIGN(CONSTANT(MAXPAGESIZE));
        __rodata_end = .;
    } :rodata

    . += CONSTANT(MAXPAGESIZE);

    /* Order is load-bearing: the bootloader honours the *last* start marker
       and the *first* end marker it finds, so everything it must see has to
       sit between these two. KEEP() because nothing references the markers
       from code and --gc-sections would otherwise be right to drop them. */
    .limine_requests : {
        __data_start = .;
        KEEP(*(.limine_requests_start))
        KEEP(*(.limine_requests))
        KEEP(*(.limine_requests_end))
    } :data

    .data : {
        *(.data .data.* .sdata .sdata.*)
        *(.got .got.plt)
    } :data

    .dynamic : {
        *(.dynamic)
    } :data :dynamic

    /* .bss last in :data -- anything mapped after it would force the zero fill
       to be written out to the image on disk. */
    .bss : {
        *(.bss .bss.* .sbss .sbss.*)
        *(COMMON)
        . = ALIGN(CONSTANT(MAXPAGESIZE));
        __data_end = .;
    } :data

    /DISCARD/ : {
        *(.eh_frame*)
        *(.note .note.*)
        *(.comment)
    }
}
