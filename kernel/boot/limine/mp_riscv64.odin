/*
The multiprocessor response as riscv64 lays it out.

A core is a hart, named by its hart id. The flags word is always zero.
*/
#+build riscv64
package limine

MP_ID_NAME :: "hart"

// One core, as the bootloader parked it. `goto_address` releases it with a
// pointer to this record in `a0`, on a bootloader stack of the default
// 64 KiB, in supervisor mode with the bootloader's page tables.
MP_Info :: struct {
	processor_id:   u64, // ACPI processor UID
	hartid:         u64,
	reserved:       u64,
	goto_address:   proc "c" (info: ^MP_Info) -> !,
	extra_argument: u64,
}

MP_Response :: struct {
	revision:   u64,
	flags:      u64, // Always zero
	bsp_hartid: u64,
	cpu_count:  u64,
	cpus:       [^]^MP_Info,
}

mp_cpu_id :: proc "contextless" (info: ^MP_Info) -> u64 {
	return info.hartid
}

mp_bsp_id :: proc "contextless" (r: ^MP_Response) -> u64 {
	return r.bsp_hartid
}

mp_x2apic :: proc "contextless" (r: ^MP_Response) -> bool {
	_ = r
	return false
}
