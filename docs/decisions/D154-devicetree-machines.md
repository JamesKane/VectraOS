# D154. Devicetree machines: the kernel reads tables the loader makes, devmgr reads the devicetree as a bus, and the trees are ours, built from upstream sources by our own compiler (2026-10-31, decided by the owner; extends D51, amends architecture §2)

D51 had the RV2's loader read the DTB that U-Boot passes and make the
ACPI tables the kernel reads, so the kernel stays ACPI-only
(`lib/dtacpi`, d6313a4). That covers the kernel. It doesn't cover the
rest of the board: the RV2's EMAC, SDHCI, PCIe and DWC3 are described
only by the tree, and so are those of the next boards, the Orange Pi 5
Plus (RK3588) and the StarFive VisionFive 2 (JH7110, D155). Their
firmware is U-Boot with a devicetree (the owner, 2026-10-31: U-Boot
with DT for the Orange Pi 5 Plus, not the community EDK2's ACPI).

A devicetree has two consumers, and they need different things:
- **The kernel** needs a dozen standard facts: the CPUs, the interrupt
  controller, the timer, the console, PSCI or SBI, an IOMMU and an ECAM
  if there are any. ACPI's static tables say all of them.
- **devmgr** needs the whole SoC: each device's registers and
  interrupts, and the graph of clocks, resets, pins, regulators and
  power domains between them. ACPI has no standard form for that graph;
  the Sky1 hides it behind SCMI and AML, and older boards don't.

## The decision

1. **The kernel stays ACPI-only, and sees no devicetree.** `lib/dtacpi`
   makes the tables for each arch from the tree:
   - rv64: what it makes now (RSDP, XSDT, FADT, empty DSDT, MADT with a
     RINTC per hart and the PLIC, RHCT, SPCR), with APLIC and IMSIC
     entries for AIA boards, and harts skipped that have no S mode (no
     `mmu-type`: the JH7110's S7).
   - arm64: MADT entries for the GICC per CPU (MPIDR from `reg`), the
     GICD, GICR and ITS; a GTDT from `arm,armv8-timer`; a FADT whose
     ARM boot flags and conduit come from `/psci`; an SPCR from
     `stdout-path`; a PPTT from `cpu-map`; an IORT from each host
     bridge's `iommu-map` onto an `arm,smmu-v3`.
   - Both: an MCFG only for a plain ECAM host (`pci-host-ecam-generic`).
     A vendor's PCIe host (DesignWare, PLDA) is a devmgr driver.
2. **The devicetree reaches devmgr as boot data.** The loader passes the
   tree, as the kernel will be given it (item 5), beside the RSDP. The
   kernel copies it into a VMO with the rest of firmware's boot data and
   never parses it. `Fdt` moves from `lib/dtacpi` to `lib/fdt`, shared
   by the loader, devmgr and `vx dtc`.
3. **devmgr reads the tree as a bus.** `drivers/bus/dt` sits beside
   `bus/acpi` and `bus/pci`, as one more source of devmgr's one device
   record. It walks the enabled nodes that have a `compatible`: `reg`
   gives the device's ranges (translated through each parent's
   `ranges`), `interrupts` resolves through `interrupt-parent` and
   `interrupt-map` to a GSI on a controller the kernel owns, and
   `iommus` names the unit. A controller the kernel doesn't own (a GPIO
   block's interrupts) is a provider (item 4). Manifests gain
   `match dt VENDOR,DEVICE`, matched in the node's `compatible` order,
   at the level `acpi-compatible` has now.
4. **The provider graph is devmgr's one link mechanism.** The links
   `lib/Platform.swift` builds from the Sky1's `_DSD` (`shmem`,
   `mboxes`) and CIX's `RSTL` become one record, which a tree's phandles
   also fill: `clocks`, `resets`, `pinctrl-N`, `*-supply`,
   `power-domains`, `phys`, `interrupts-extended` onto a provider's
   controller. A provider is a driver that serves a tree; devmgr binds a
   consumer after its providers and mounts each provider's tree in the
   consumer's namespace, with the specifier cells saying which clock or
   reset is the consumer's. ACPI's links and the tree's are read
   differently and used one way.
5. **The trees are ours, as the BSDs ship theirs.** FreeBSD vendors
   Linux's devicetree sources (`sys/contrib/device-tree`, "extracted
   from the Linux kernel source tree"), builds the boards' DTBs, keeps
   them in `/boot/dtb`, and has its own `dtc` (`usr.bin/dtc`).
   - **Sources:** only the files our boards include, from the
     `devicetree-rebasing` tree at a pinned tag: each board's `.dts`,
     its `.dtsi` files and the `dt-bindings` headers they include, in
     `firmware/dts/`, with their row in `firmware/README.md` (D4). A
     tree describes hardware and runs nothing, but it is third-party.
     The RK3588's are `GPL-2.0+ OR MIT` and the JH7110's `GPL-2.0 OR
     MIT`; we take them under MIT, and a GPL-only file isn't imported.
     A new tag is its own change, with the drivers' bindings checked
     against it.
   - **One binding set:** drivers match upstream's bindings only. A
     vendor's tree (the RV2's U-Boot 2022.10 carries one) never decides
     what a driver reads.
   - **Placement:** CMake builds the DTB of each DT board in
     `docs/hardware/support.tsv` onto the ESP as `dtb/VENDOR/BOARD.dtb`,
     and a check fails if a DT board has none.
6. **The compiler is ours: `vx dtc`.** CLAUDE.md allows nothing on the
   host beyond the Swift toolchain, CMake, Ninja, QEMU and bash, and
   `dtc` isn't on this machine. D4 lets a third-party compiler make our
   own artifacts, and a DTB isn't one. So, as FreeBSD did, we write
   ours, in Swift: the bundled clang's `-E` runs the `#include` and
   `#define` lines, and `vx dtc` parses the source (nodes, labels,
   phandle references, `&label { }` overrides, `/delete-node/`,
   `/delete-property/`, `/include/`), checks it, and writes the flat
   tree through `lib/fdt`'s writer. Its host tests round-trip every
   board's tree through `lib/fdt`'s reader. It compiles the overlays
   item 8 may need.
7. **The loader picks our tree, and the firmware's identifies the
   board.** It reads the root `compatible` of the tree U-Boot passes and
   loads the ESP's DTB whose root `compatible` matches. With no match it
   uses the firmware's and says so on the console; such a board stays
   at research (D66). It then copies a fixed list of values firmware
   knows and a static tree can't from the firmware's tree into ours:
   - `local-mac-address` and `mac-address` of each Ethernet node,
   - `/chosen`'s `kaslr-seed` and `rng-seed`,
   - `reserved-memory` nodes, checked against the UEFI memory map,
   - `serial-number`,
   - the `status` of a CPU node firmware disabled (a binned part).

   An entry joins the list when a board needs it, with that board's name
   beside it. Nothing else is merged.
8. **One description per machine.** When firmware gives an RSDP whose
   DSDT has devices, the machine is ACPI and a devicetree, if also
   given, is ignored. When the loader made the tables, the tree
   describes the devices. The two are never merged. There are no
   overlays until a board needs one (a HAT); then the loader applies
   those listed on the ESP, after our tree is picked.
9. **UEFI stays the one boot protocol.** U-Boot's `bootefi`, which
   passes the tree as a configuration table, as on the RV2. No
   `booti`, no Linux image header. A board whose U-Boot has no EFI is
   unsupported.

## Not chosen

- **The tree as AML** (a DSDT of `PRP0001` devices with `_DSD`): a
  second layer over the first (principle 1). The loader has no heap
  and would need an AML encoder, phandle graphs have no standard ACPI
  form, so we would invent one, and devmgr would decode it back to the
  tree.
- **ACPI firmware for each board** (EDK2 with tables we write or the
  community's): one board at a time, and the RK3588's community tables
  leave out CPU performance states and thermal zones (its Orange Pi 5
  Max fork's notes). The Orange Pi 5 Plus runs U-Boot with DT (the
  owner).
- **A kernel DT path:** D51 ruled it out, and nothing here needs it.

This is Fuchsia's split, our goal post: its boot shim turns the tree
into the kernel's items, and a driver in user space reads the tree for
the board's devices.

## Follow-ups, each its own change

1. `lib/fdt` (the reader moved, a writer added) and the tree in the
   boot data.
2. `vx dtc`, its tests, `firmware/dts/` at a pinned tag, and the DTBs on
   the ESP; the loader's pick and its fixups.
3. arm64's tables in `lib/dtacpi`, tested on QEMU's `virt` given a tree
   and no ACPI (`-machine virt,acpi=off` with edk2).
4. `drivers/bus/dt` and `match dt`, first on the RV2 (its EMAC and SDHCI,
   V6b).
5. Links from phandles, and the first providers: the K1's APBC and APMU
   clocks and resets.
6. Each comes with its pages (D86): devmgr's, the bus's and `vx dtc`'s.
   Architecture §2 and `docs/kernel/rules.md`'s scope say this decision
   from today.
