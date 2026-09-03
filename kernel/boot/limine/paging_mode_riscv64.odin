// The riscv64 paging modes, and the one Vectra pins. See `docs/PORTS.md`.
#+build riscv64
package limine

PAGING_SV39 :: u64(0)
PAGING_SV48 :: u64(1)
PAGING_SV57 :: u64(2)

// Sv48: four levels of 512 entries, the same tree the other two walk. Sv39
// would be three levels and a different canonical hole.
PAGING_MODE_PINNED :: PAGING_SV48

paging_mode_name :: proc "contextless" (mode: u64) -> string {
	switch mode {
	case PAGING_SV39: return "Sv39"
	case PAGING_SV48: return "Sv48"
	case PAGING_SV57: return "Sv57"
	}
	return ""
}
