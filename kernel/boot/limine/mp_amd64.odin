/*
The multiprocessor response as x86-64 lays it out.

A core is its LAPIC id. Request bit 0 asks for x2APIC, and Vectra leaves it
clear: the LAPIC driver speaks the memory-mapped xAPIC, and a bootloader that
cannot leave x2APIC off refuses to boot rather than hand over a mode nothing
here can drive.
*/
#+build amd64
package limine

MP_X2APIC :: u64(1) << 0

// How the boot log names a core's id on this architecture.
MP_ID_NAME :: "lapic"

// One core, as the bootloader parked it. `goto_address` is the release: an
// atomic store of an entry point sends the core there with a pointer to this
// record in `rdi`, on a bootloader stack of the default 64 KiB. `reserved` is
// the bootloader's own, and holds that stack pointer while the core waits.
MP_Info :: struct {
	processor_id:   u32, // ACPI processor UID, from the MADT
	lapic_id:       u32,
	reserved:       u64,
	goto_address:   proc "c" (info: ^MP_Info) -> !,
	extra_argument: u64,
}

MP_Response :: struct {
	revision:     u64,
	flags:        u32, // Bit 0: x2APIC was enabled after all
	bsp_lapic_id: u32,
	cpu_count:    u64, // Every core, the bootstrap processor included
	cpus:         [^]^MP_Info,
}

mp_cpu_id :: proc "contextless" (info: ^MP_Info) -> u64 {
	return u64(info.lapic_id)
}

mp_bsp_id :: proc "contextless" (r: ^MP_Response) -> u64 {
	return u64(r.bsp_lapic_id)
}

// mp_x2apic reports whether the bootloader turned x2APIC on after all, which
// the request asked it not to.
mp_x2apic :: proc "contextless" (r: ^MP_Response) -> bool {
	return r.flags & u32(MP_X2APIC) != 0
}
