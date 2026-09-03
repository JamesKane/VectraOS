// The paging modes of the two architectures whose modes are 4-level and
// 5-level, and the one Vectra pins. See `docs/BOOT.md` and `docs/PORTS.md`.
#+build amd64, arm64
package limine

PAGING_4LVL :: u64(0)
PAGING_5LVL :: u64(1)

// 4-level. Limine would otherwise hand over 5-level on a machine that has it,
// which moves the canonical hole and changes every table walk.
PAGING_MODE_PINNED :: PAGING_4LVL

paging_mode_name :: proc "contextless" (mode: u64) -> string {
	switch mode {
	case PAGING_4LVL: return "4-level"
	case PAGING_5LVL: return ODIN_ARCH == .amd64 ? "5-level (LA57)" : "5-level"
	}
	return ""
}
