/*
Which generic interrupt controller this build drives.

`gic.odin` is version 2, the one QEMU's `virt` board defaults to. `gic3.odin`
is version 3, the one the OrangePi's GIC-700 is and the one `virt` gives with
`gic-version=3`. The two speak differently to a core -- v2 through a mapped CPU
interface page, v3 through system registers and a redistributor per core -- so
neither is a special case of the other, and a build picks one.

`-define:VECTRA_GIC=3` selects version 3; anything else, including the absence
of the define, is version 2. `build.odin`'s `--gic=3` sets it, and the same
flag swaps QEMU's machine line to match, because a v3 driver on a v2 board
reads a distributor that is not there. The board will read the version from the
tree's `compatible` when it is a board; for now it is one number at build time.

Every name below is the one the rest of the kernel calls -- the facade in
`arch_arm64.odin`, the dispatch in `traps.odin`, the bring-up in `timer.odin`.
The `when` binds each to the chosen version's implementation, so nothing above
this file knows which controller answered.
*/
package arm64

// The controller version, from the build. Two unless told three.
GIC_VERSION :: #config(VECTRA_GIC, 2)

when GIC_VERSION == 3 {
	GIC_PHYS :: GICV3_DIST_PHYS
	GIC_MMIO_SIZE :: GICV3_MMIO_SIZE

	gic_physical_base :: gicv3_physical_base
	gic_attach :: gicv3_attach
	gic_attach_here :: gicv3_attach_here
	gic_attached :: gicv3_attached
	gic_available :: gicv3_available
	gic_lines :: gicv3_lines
	gic_version :: gicv3_version
	gic_acknowledge :: gicv3_acknowledge
	gic_eoi :: gicv3_eoi
	gic_ack :: gicv3_ack
	gic_cpu_number :: gicv3_cpu_number
	gic_route :: gicv3_route
	gic_set_edge :: gicv3_set_edge
	gic_set_mask :: gicv3_set_mask
	gic_masked :: gicv3_masked
	gic_vector_of :: gicv3_vector_of
	gic_send :: gicv3_send
	gic_stop_others :: gicv3_stop_others
} else {
	GIC_PHYS :: GICV2_PHYS
	GIC_MMIO_SIZE :: GICV2_MMIO_SIZE

	gic_physical_base :: gicv2_physical_base
	gic_attach :: gicv2_attach
	gic_attach_here :: gicv2_attach_here
	gic_attached :: gicv2_attached
	gic_available :: gicv2_available
	gic_lines :: gicv2_lines
	gic_version :: gicv2_version
	gic_acknowledge :: gicv2_acknowledge
	gic_eoi :: gicv2_eoi
	gic_ack :: gicv2_ack
	gic_cpu_number :: gicv2_cpu_number
	gic_route :: gicv2_route
	gic_set_edge :: gicv2_set_edge
	gic_set_mask :: gicv2_set_mask
	gic_masked :: gicv2_masked
	gic_vector_of :: gicv2_vector_of
	gic_send :: gicv2_send
	gic_stop_others :: gicv2_stop_others
}
