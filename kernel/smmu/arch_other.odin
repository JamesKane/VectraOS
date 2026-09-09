/*
The other architectures' half: never reached, because no tree on amd64 and no
`arm,smmu-v3` node on riscv64 means `init` returns before a descriptor is
filled. The stubs are here so the neutral file type-checks everywhere.
*/
#+build !arm64
package smmu

import "base:intrinsics"

@(private)
cd_fill :: proc "contextless" (cd: ^[8]u64, root: uintptr, asid: u16, ips: u32) {
	cd[0] = 0
}

@(private)
ips_code :: proc "contextless" (oas: u32) -> u32 {
	return oas
}

@(private)
barrier :: proc "contextless" () {
	intrinsics.atomic_thread_fence(.Seq_Cst)
}
