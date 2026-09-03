/*
The multiprocessor response as aarch64 lays it out.

A core is its MPIDR, affinity fields only. The flags word is always zero, and
the request's own flags mean nothing here.
*/
#+build arm64
package limine

MP_ID_NAME :: "mpidr"

// One core, as the bootloader parked it. `goto_address` releases it with a
// pointer to this record in `x0`, on a bootloader stack of the default
// 64 KiB, in the machine state the boot core got.
MP_Info :: struct {
	processor_id:   u32, // ACPI processor UID
	reserved1:      u32,
	mpidr:          u64, // MPIDR_EL1 with everything but the affinity fields masked
	reserved:       u64,
	goto_address:   proc "c" (info: ^MP_Info) -> !,
	extra_argument: u64,
}

MP_Response :: struct {
	revision:  u64,
	flags:     u64, // Always zero
	bsp_mpidr: u64,
	cpu_count: u64,
	cpus:      [^]^MP_Info,
}

mp_cpu_id :: proc "contextless" (info: ^MP_Info) -> u64 {
	return info.mpidr
}

mp_bsp_id :: proc "contextless" (r: ^MP_Response) -> u64 {
	return r.bsp_mpidr
}

mp_x2apic :: proc "contextless" (r: ^MP_Response) -> bool {
	_ = r
	return false
}
