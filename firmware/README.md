| The Orange Pi RV2's tree as it boots: upstream's, included untouched, the vendor's nodes for the K1's EHCI controllers and their USB 2 PHYs, which upstream doesn't describe (D157), and the CPUs' operating points and supply (D161) | `firmware/dts/vectraos/spacemit/k1-orangepi-rv2.dts` | ours, the EHCI nodes after the vendor's `x1.dtsi` (Orange Pi's `orange-pi-6.6-ky` kernel), the points from chinese-wall's spacemit-k1 14 |# Firmware

Code that the hardware itself runs, which VectraOS loads into a device but
didn't write (D4), and the devicetrees that describe our boards (D154).
Each is listed here with where it came from, its licence, and what loads
it. Nothing else third-party goes on a device.

| What | Where in the tree | Source | Licence | Loaded by |
|---|---|---|---|---|
| Realtek RTL8126_2: the MAC microcontroller's breakpoints (339 register writes) and the PHY's RAM code (2449 writes, version 0x0060) | `drivers/net/rge/lib/RTL8126Code.swift`, generated, not edited | FreeBSD `sys/dev/rge/if_rge_microcode.h` at `b9585475ee62` (`rtl8126_2_mac_bps_regs`, `rtl8126_2_mac_bps_vals`, `mac_r26_2_mcu`), OpenBSD's Kevin Lo, "hardware programming portions from Realtek Semiconductor" | BSD-2-Clause (OpenBSD's ISC-style text), kept in the file's header | rge(3), each time it starts a chip that doesn't already hold that version |

Without the RTL8126_2's code a gigabit link partner took 16 s to link,
the 2.5 and 5 Gb/s training stalling, as the Orange Pi 6 Plus showed;
FreeBSD, which loads it, links in about a second.

## Devicetrees

The boards whose firmware gives a devicetree run on trees of our own
(D154), built from Linux's devicetree sources as FreeBSD's
`sys/contrib/device-tree` builds its own. `firmware/dts/` holds only the
files our boards include, byte-identical to upstream's
`devicetree-rebasing` tree at `v7.3-dts` (`44ab80381f47`), under its
layout (`src/` dropped). Each is taken under its non-GPL licence; a
GPL-only file is not imported, and a header of our own stands in for one
whose constants a tree needs. `vx dtc` compiles each board's tree, which
`docs/hardware/support.tsv` names, into the ESP's
`dtb/<vendor>/<board>.dtb`. A new tag is its own change, with the
drivers' bindings checked against it. Where upstream describes nothing of a
board's device, a board file of ours under `firmware/dts/vectraos/`
includes upstream's and adds the vendor's nodes for it (D157); then
`support.tsv` names that file.

| What | Where in the tree | Source | Licence | Loaded by |
|---|---|---|---|---|
| The Orange Pi RV2's tree, and the SpacemiT K1's it includes | `firmware/dts/riscv/spacemit/` (`k1-orangepi-rv2.dts`, `k1.dtsi`, `k1-pinctrl.dtsi`, `k1-pdma.h`) | `src/riscv/spacemit/` | MIT (`GPL-2.0 OR MIT`); `k1-pdma.h` BSD-2-Clause (`GPL-2.0-only OR BSD-2-Clause`) | `vx dtc`, onto the ESP |
| The bindings' constants the K1's tree uses | `firmware/dts/include/dt-bindings/` (`clock/spacemit,k1-syscon.h`, `gpio/gpio.h`) | `include/dt-bindings/` | BSD-2-Clause (`GPL-2.0-only OR BSD-2-Clause`, `GPL-2.0 OR BSD-2-Clause`) | `vx dtc`, at build time |
| The Orange Pi RV2's tree as it boots: upstream's, included untouched, and the vendor's nodes for the K1's EHCI controllers and their USB 2 PHYs, which upstream doesn't describe (D157) | `firmware/dts/vectraos/spacemit/k1-orangepi-rv2.dts` | ours, the nodes after the vendor's `x1.dtsi` (Orange Pi's `orange-pi-6.6-ky` kernel) | MIT (the vendor's `GPL-2.0 OR MIT`) | `vx dtc`, onto the ESP |
| `PHY_TYPE_USB3`, in place of upstream's `phy/phy.h` (GPL-2.0-only) | `firmware/dts/include/dt-bindings/phy/phy.h` | ours | BSD-3-Clause | `vx dtc`, at build time |
