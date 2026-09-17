#+build freestanding
package sysinfo

// Freestanding backend for `core:sys/info`.
//
// Odin's stock `core:sys/info` has no freestanding build, so its per-OS
// backends (`_cpu_core_count`, `_ram_stats`, `_os_version`, and on arm64/riscv64
// the CPU feature/name detection) are undeclared for the freestanding targets
// Vectra builds. That gap blocks every `core:crypto` package with a
// hardware-accelerated dispatch path -- sha2, hmac, hkdf, aes, aead, ecdsa,
// rsa, ed25519, x509 -- because each imports this package to read the CPU's
// features and pick a code path.
//
// This file supplies the missing symbols, gated to freestanding so a hosted
// build never sees them. Every stub reports "nothing detected": no cores, no
// RAM figures, no OS version, and an empty CPU_Features set. An empty feature
// set makes each crypto package select its portable, constant-time software
// implementation, which is exactly what a kernel-less target wants.
//
// `build.odin` copies this file into `<odin-root>/core/sys/info/` before it
// compiles, so it survives a toolchain that ships without it. The source of
// truth is `toolchain/` in the Vectra tree.

import "base:runtime"

@(private)
_cpu_core_count :: proc "contextless" () -> (physical: int, logical: int, ok: bool) {
	return 0, 0, false
}

@(private)
_ram_stats :: proc "contextless" () -> (total_ram, free_ram, total_swap, free_swap: i64, ok: bool) {
	return 0, 0, 0, 0, false
}

@(private)
_os_version :: proc(allocator: runtime.Allocator, loc := #caller_location) -> (res: OS_Version, ok: bool) {
	return {}, false
}

// On i386/amd64 `cpu_intel.odin` provides the feature and name detection
// unguarded by OS, so those targets need nothing more. The arm and riscv
// equivalents live in OS-gated files, so freestanding supplies the stubs.
when ODIN_ARCH == .arm64 || ODIN_ARCH == .arm32 {
	@(private)
	_cpu_features :: proc "contextless" () -> (features: CPU_Features) {
		return {}
	}

	@(private)
	_init_cpu_features :: proc "contextless" () {}
}

when ODIN_ARCH == .riscv64 {
	@(private)
	_cpu_features :: proc "contextless" () -> (features: CPU_Features) {
		return {}
	}

	@(private)
	_init_cpu_features :: proc "contextless" () {}

	@(private)
	_cpu_name :: proc() -> (name: string) {
		return ""
	}

	@(private)
	_init_cpu_name :: proc "contextless" () {}
}
