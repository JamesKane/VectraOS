/*
Bindings for the Limine boot protocol as implemented by Limine v12.6.1.

Vectra requests **base revision 6**. What that buys us, and what it costs:

  - Request delimiters are honoured, so the bootloader stops scanning the image
    outside `.limine_requests` (see `markers.odin`).
  - The HHDM is restrictive: only usable, bootloader-reclaimable, executable,
    framebuffer, reserved-mapped, ACPI reclaimable and ACPI NVS regions are
    mapped. Nothing else may be dereferenced through the HHDM offset.
  - Memory below 0x1000 may legitimately be marked usable.
  - Every `cr0`/`cr4`/`EFER` bit not required by the protocol is *cleared* on
    entry -- `CR4.OSFXSR` included. `arch.early_init` is what puts SSE back,
    and it has to run before any other Odin statement.

Vectra only declares the requests it actually consumes. An unused request is
not free. The bootloader must still find and service it. A response nothing
reads occupies bootloader-reclaimable memory, and nothing can reclaim that
until it is clear nobody wants it.

Reference: limine-protocol/PROTOCOL.md at tag v12.6.1.
*/
package limine

COMMON_MAGIC_1 :: 0xc7b1dd30df4c8b88
COMMON_MAGIC_2 :: 0x0a82e883a194f07b

// -- Base revision -----------------------------------------------------------

BASE_REVISION :: 6

BASE_REVISION_MAGIC_1 :: 0xf9562b2d5c95a6c8
BASE_REVISION_MAGIC_2 :: 0x6a7b384944536bdc

/*
The base revision tag is a three-word handshake, not a request.

The kernel writes its desired revision into word 2, and the bootloader answers
in place. Zero means `supported`. Unchanged means `too new for me, you were
loaded as something else`. `markers.odin` owns the tag itself. The helpers here
read the answer.
*/
Base_Revision_Tag :: [3]u64

base_revision_supported :: proc "contextless" (tag: ^Base_Revision_Tag) -> bool {
	return tag[2] == 0
}

/*
loaded_base_revision reports what the bootloader actually used.

Only meaningful once the bootloader stamps word 1. A bootloader too old to know
about base revisions leaves the magic there, which is what `ok` reports.
Anything that behaves differently across base revisions -- HHDM coverage above
all -- must branch on this rather than on BASE_REVISION.
*/
loaded_base_revision :: proc "contextless" (tag: ^Base_Revision_Tag) -> (revision: u64, ok: bool) {
	if tag[1] == BASE_REVISION_MAGIC_2 {
		return 0, false
	}
	return tag[1], true
}

// -- Request delimiters ------------------------------------------------------

REQUESTS_START_MARKER :: [4]u64 {
	0xf6b8f4b39de7d1ae,
	0xfab91a6940fcb9cf,
	0x785c6ed015d3e316,
	0x181e920a7852b9d9,
}

REQUESTS_END_MARKER :: [2]u64{0xadc0e0531bb10d03, 0x9572709f31764c62}

// -- Common structures -------------------------------------------------------

UUID :: struct {
	a: u32,
	b: u16,
	c: u16,
	d: [8]u8,
}

Media_Type :: enum u32 {
	Generic = 0,
	Optical = 1,
	TFTP    = 2,
}

File :: struct {
	revision:        u64,
	address:         rawptr,
	size:            u64,
	path:            cstring,
	string:          cstring,
	media_type:      Media_Type,
	unused:          u32,
	tftp_ipv4:       [4]u8,
	tftp_port:       u32,
	partition_index: u32,
	mbr_disk_id:     u32,
	gpt_disk_uuid:   UUID,
	gpt_part_uuid:   UUID,
	part_uuid:       UUID,
}

// -- Bootloader info ---------------------------------------------------------

BOOTLOADER_INFO_REQUEST :: [4]u64 {
	COMMON_MAGIC_1,
	COMMON_MAGIC_2,
	0xf55038d8e2a1202f,
	0x279426fcf5f59740,
}

Bootloader_Info_Response :: struct {
	revision: u64,
	name:     cstring,
	version:  cstring,
}

Bootloader_Info_Request :: struct {
	id:       [4]u64,
	revision: u64,
	response: ^Bootloader_Info_Response,
}

// -- Firmware type -----------------------------------------------------------

FIRMWARE_TYPE_REQUEST :: [4]u64 {
	COMMON_MAGIC_1,
	COMMON_MAGIC_2,
	0x8c2f75d90bef28a8,
	0x7045a4688eac00c3,
}

Firmware_Type :: enum u64 {
	X86_BIOS = 0,
	EFI32    = 1,
	EFI64    = 2,
	SBI      = 3,
}

Firmware_Type_Response :: struct {
	revision:      u64,
	firmware_type: Firmware_Type,
}

Firmware_Type_Request :: struct {
	id:       [4]u64,
	revision: u64,
	response: ^Firmware_Type_Response,
}

// -- Higher-half direct map --------------------------------------------------

HHDM_REQUEST :: [4]u64 {
	COMMON_MAGIC_1,
	COMMON_MAGIC_2,
	0x48dcf1cb8ad2b852,
	0x63984e959a98244b,
}

HHDM_Response :: struct {
	revision: u64,
	offset:   u64,
}

HHDM_Request :: struct {
	id:       [4]u64,
	revision: u64,
	response: ^HHDM_Response,
}

// -- Framebuffer -------------------------------------------------------------

FRAMEBUFFER_REQUEST :: [4]u64 {
	COMMON_MAGIC_1,
	COMMON_MAGIC_2,
	0x9d5827dcd881dd75,
	0xa3148604f6fab11b,
}

MEMORY_MODEL_RGB :: u8(1)

Video_Mode :: struct {
	pitch:            u64,
	width:            u64,
	height:           u64,
	bpp:              u16,
	memory_model:     u8,
	red_mask_size:    u8,
	red_mask_shift:   u8,
	green_mask_size:  u8,
	green_mask_shift: u8,
	blue_mask_size:   u8,
	blue_mask_shift:  u8,
}

Framebuffer :: struct {
	address:          rawptr,
	width:            u64,
	height:           u64,
	pitch:            u64,
	bpp:              u16,
	memory_model:     u8,
	red_mask_size:    u8,
	red_mask_shift:   u8,
	green_mask_size:  u8,
	green_mask_shift: u8,
	blue_mask_size:   u8,
	blue_mask_shift:  u8,
	unused:           [7]u8,
	edid_size:        u64,
	edid:             rawptr,
	// Response revision 1 and above.
	mode_count:       u64,
	modes:            [^]^Video_Mode,
}

Framebuffer_Response :: struct {
	revision:          u64,
	framebuffer_count: u64,
	framebuffers:      [^]^Framebuffer,
}

Framebuffer_Request :: struct {
	id:       [4]u64,
	revision: u64,
	response: ^Framebuffer_Response,
}

// -- Paging mode -------------------------------------------------------------

PAGING_MODE_REQUEST :: [4]u64 {
	COMMON_MAGIC_1,
	COMMON_MAGIC_2,
	0x95c1a0edab0944cb,
	0xa4e5cb3842f7488a,
}

/*
Paging mode numbering is per-architecture: 0 means 4-level on x86-64 and
aarch64 but Sv39 on riscv64. `paging_mode_amd64.odin` and its two siblings
carry each architecture's spellings, the mode Vectra pins, and the name a
boot line prints for a mode.
*/

Paging_Mode_Response :: struct {
	revision: u64,
	mode:     u64,
}

Paging_Mode_Request :: struct {
	id:       [4]u64,
	revision: u64,
	response: ^Paging_Mode_Response,
	mode:     u64,
	max_mode: u64,
	min_mode: u64,
}

// -- Memory map --------------------------------------------------------------

MEMMAP_REQUEST :: [4]u64 {
	COMMON_MAGIC_1,
	COMMON_MAGIC_2,
	0x67cf3d9d378a806f,
	0xe304acdfc50c3c62,
}

Memmap_Type :: enum u64 {
	Usable                 = 0,
	Reserved               = 1,
	ACPI_Reclaimable       = 2,
	ACPI_NVS               = 3,
	Bad_Memory             = 4,
	Bootloader_Reclaimable = 5,
	Executable_And_Modules = 6, // Was Kernel_And_Modules before the v9 renames
	Framebuffer            = 7,
	Reserved_Mapped        = 8, // New in base revision 4: reserved, but HHDM-mapped
}

Memmap_Entry :: struct {
	base:   u64,
	length: u64,
	type:   Memmap_Type,
}

Memmap_Response :: struct {
	revision:    u64,
	entry_count: u64,
	entries:     [^]^Memmap_Entry,
}

Memmap_Request :: struct {
	id:       [4]u64,
	revision: u64,
	response: ^Memmap_Response,
}

// -- Executable load address -------------------------------------------------
//
// Called `kernel address` before the v9 rename. The magic is unchanged, so an
// old binding compiles happily against a new bootloader. Only the naming gives
// away that it is stale.

EXECUTABLE_ADDRESS_REQUEST :: [4]u64 {
	COMMON_MAGIC_1,
	COMMON_MAGIC_2,
	0x71ba76863cc55f63,
	0xb2644a48c516a487,
}

Executable_Address_Response :: struct {
	revision:      u64,
	physical_base: u64,
	virtual_base:  u64,
}

Executable_Address_Request :: struct {
	id:       [4]u64,
	revision: u64,
	response: ^Executable_Address_Response,
}

// -- Multiprocessor ----------------------------------------------------------
//
// Called `SMP` before the v9 rename. The magic is unchanged. The presence of
// the request is what makes the bootloader start the other cores at all: they
// are parked in bootloader-reclaimable memory, each spinning on its own
// `goto_address`, in the same machine state the bootstrap processor got.
// Writing an address there releases one. See `docs/SMP.md`.
//
// The response and the per-core record differ by architecture -- a core is
// named by its LAPIC id, its MPIDR affinity or its hart id -- so the three
// layouts live in `mp_amd64.odin` and its siblings, behind `mp_cpu_id` and
// `mp_bsp_id`. The request is the same everywhere.

MP_REQUEST :: [4]u64 {
	COMMON_MAGIC_1,
	COMMON_MAGIC_2,
	0x95a67b819a1b857e,
	0xa0b61b723b6a73e0,
}

MP_Request :: struct {
	id:       [4]u64,
	revision: u64,
	response: ^MP_Response,
	flags:    u64,
}

// -- Device tree -------------------------------------------------------------
//
// The flattened device tree the firmware handed the bootloader, on the two
// architectures that have one. No response on x86-64, and none where the
// firmware gave the bootloader ACPI tables and no tree. Memory nodes are
// stripped: the memory map is the only word on memory.

DTB_REQUEST :: [4]u64 {
	COMMON_MAGIC_1,
	COMMON_MAGIC_2,
	0xb40ddb48fb54bac7,
	0x545081493f81ffb7,
}

DTB_Response :: struct {
	revision: u64,
	dtb:      rawptr, // Virtual, through the HHDM, in bootloader-reclaimable memory
}

DTB_Request :: struct {
	id:       [4]u64,
	revision: u64,
	response: ^DTB_Response,
}
