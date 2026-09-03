// The aarch64 paging modes, and the one Vectra pins. See `docs/PORTS.md`.
#+build arm64
package limine

PAGING_4LVL :: u64(0)
PAGING_5LVL :: u64(1)

// 4-level with a 4 KiB granule, which is the one layout the VMM walks.
PAGING_MODE_PINNED :: PAGING_4LVL

paging_mode_name :: proc "contextless" (mode: u64) -> string {
	switch mode {
	case PAGING_4LVL: return "4-level"
	case PAGING_5LVL: return "5-level"
	}
	return ""
}
