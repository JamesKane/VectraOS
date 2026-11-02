# D157. The vendor's nodes where upstream describes nothing: a board file of ours adds them beside upstream's tree, untouched (2026-11-01, decided by the owner; amends D154)

D154 made the trees ours: upstream's `devicetree-rebasing` sources,
byte-identical at a pinned tag, and drivers matching upstream's
bindings only ("a vendor's tree never decides what a driver reads").
The Orange Pi RV2's two white USB ports break that: they are the
SpacemiT K1's two ChipIdea EHCI host controllers, at `0xc0900100` and
`0xc0980100`, each with a USB 2 PHY of its own, and upstream's K1 tree
at `v7.3-dts` describes none of them. No binding for them was found
posted upstream either (2026-11-01). The vendor's tree (Orange Pi's
`orange-pi-6.6-ky` kernel, `x1.dtsi`, `GPL-2.0 OR MIT`) describes all
four. The owner, asked how to describe them: "We should use the
vendor's own."

## The decision

1. **Where upstream describes a device, upstream's nodes and bindings
   stay the only ones** (D154 unchanged). Where it describes nothing,
   the vendor's nodes are used: their compatibles and properties as
   the vendor's tree gives them, taken under MIT as upstream's are.
2. **Upstream's files stay byte-identical.** The vendor's nodes go in a
   board file of ours, `firmware/dts/vectraos/<vendor>/<board>.dts`,
   which includes upstream's board file and adds them, rewritten only
   where the vendor's tree names its own clock, reset and interrupt
   controllers (`&ccu`, `&reset`, `&intc`): those become upstream's
   (`&syscon_apmu`, the PLIC), with upstream's numbers for the same
   clocks and resets. The DTB keeps the board's name
   (`dtb/<vendor>/<board>.dtb`), and `docs/hardware/support.tsv` names
   our board file. `firmware/README.md` has its row.
3. **What the vendor's tree says through a node we don't take** is said
   in upstream's way: the RV2's first EHCI port's VBUS, which the
   vendor switches through its OTG controller's `vbus-gpios`, is a
   `regulator-fixed` of ours (GPIO 126) named by the EHCI's
   `vbus-supply`. The OTG and device-mode controllers (`ky,mv-otg`,
   `ky,mv-udc`) aren't taken: the ports are hosts only.
4. **Drivers match the vendor's compatibles** (`ky,mv-ehci`, and
   `ky,usb2-phy` beside upstream's `spacemit,k1-usb2-phy` for the same
   PHY). When upstream describes a device, a new tag moves the board
   file's node to upstream's, and its driver to upstream's binding, in
   one change; the vendor's node and match go.

## Not chosen

- **Editing upstream's `k1.dtsi`.** It would no longer diff clean
  against its tag, and every new tag would have to carry the edit.
- **Compatibles of our own in upstream's style** (`spacemit,k1-ehci`).
  They would look upstream's and aren't; the vendor's name says where
  the description came from.
- **Waiting for upstream.** The ports would stay dead with no date.
