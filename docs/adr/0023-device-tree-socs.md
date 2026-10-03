# ADR-0023: Device-tree SoCs: a boot stage that keeps the kernel DT-free, references turned into grants, and the classes such SoCs need

Status: proposed, 2026-10-02; **parked** the same day, until a tiered board needs a device tree. ACPI is the direction (00 §5): the T1 boards boot with it, and the board this ADR was written for, the RK3588, was dropped. Nothing here is scheduled; it is kept so a DT board, when one comes, starts from it. Found by surveying the RK3588 in FreeBSD, Fuchsia and Linux. It applies to any SoC described by a device tree rather than ACPI: the RK3588, the CIX Sky1 in DT mode, and later boards.

## Context

The blueprint was shaped by machines whose firmware does much of the work: a PC's ACPI, the Q8B's RPMh, GMU and ADSP. A device-tree SoC is the opposite. The RK3588 boots from UEFI (edk2-rk3588), but its ACPI mode is developed for Windows and exposes only boot-critical devices: no GPU, NPU or display controller, and nothing behind a PCIe switch. So it must be booted with its device tree. The OS then runs everything the firmware does not:
- clocks and resets (the CRU);
- power domains, which need voltage regulators first (`domain-supply`);
- regulators on PMICs reached over I²C and SPI (RK8602, RK806);
- CPU frequency, which is an SCMI call to the trusted firmware after a regulator change (`clocks = <&scmi_clk …>`, `cpu-supply`);
- pin multiplexing in named states;
- shared register files written by many drivers (the GRF);
- IOMMUs per device;
- PCIe root complexes that need link-up;
- USB-C power delivery.

FreeBSD's tree has only the RK3588's GIC erratum. Linux has full support, about 80k lines across Rockchip SoCs for the pieces the RK3588 needs. Fuchsia has no Rockchip board, but it has already solved the design problems for DT SoCs with user-space drivers:
- a boot shim that turns the device tree into boot items, so Zircon never parses it (`zircon/kernel/phys/lib/boot-shim/devicetree-*`);
- devicetree visitors that turn each kind of reference (clocks, GPIOs, pin states, power domains, regulators, resets, registers, interrupts) into a parent the driver binds through (`sdk/lib/driver/devicetree/visitors/`);
- protocols for each:
  - `fuchsia.hardware.clock`: enable, `SetRate`, `QuerySupportedRate`, `SetInput`;
  - `fuchsia.hardware.vreg`;
  - `fuchsia.hardware.registers`: masked access to named fields, with overlap checks;
  - `fuchsia.hardware.pin`, whose `PinStates` selects a pin state by name;
- CPU frequency scaled from user space through a clock and a regulator (`aml-cpu`);
- NPUs driven through Magma, as GPUs are (`msd-vsi-vip`);
- a Mali CSF driver whose page tables the driver builds (`msd-arm-mali-csf`).

## Decision

1. **A DT boot stage, so the kernel stays DT-free.** The kernel reads the MADT, GTDT, PPTT and IORT itself on ACPI machines (01 §7.1). On a DT machine, a boot stage reads the same facts from the device tree into the same internal **platform items**, and the kernel proper consumes only those:
   - the GIC's distributor, redistributors and ITS;
   - the generic timer and any always-on memory-mapped timer;
   - the PSCI conduit (SMC or HVC);
   - CPUs with their MPIDRs, capacities and clusters;
   - `idle-states`;
   - SMMUs.

   The stage lives in `kernel/boot/`, runs before the kernel's `main`, and is freed after boot. It is the only code in the kernel image that reads the DT, and it counts in the kernel's budget. **Errata** are keyed on the root `compatible` and recorded as flags on the items. The first is RK3588001: the GIC-600's ITS and redistributor tables must be mapped non-shareable, with cache maintenance on every update, as Linux and FreeBSD do. The whole DTB still goes to `devmgr` as a read-only VMO (01 §7.2).
2. **References become grants.** `bus-dt` turns each device node's references into the grants of its match record, one translator per kind of reference, as Fuchsia's visitors do:

   | DT reference | Grant | Served by |
   |---|---|---|
   | `clocks`, `assigned-clocks`, `assigned-clock-rates` | `clock=` names, and their rates applied at spawn | `clock` (v2) |
   | `resets` | `reset=` names | `clock` (v2) |
   | `power-domains` | `domain=` names | `clock` (v2) |
   | `*-supply` | `regulator=` names | `regulator` |
   | `pinctrl-N` with `pinctrl-names` | `pinstate=` names; `default` applied before the driver is spawned | `gpio` |
   | `*-gpios` | `gpio=` names | `gpio` |
   | `interrupts`, `interrupts-extended` | `Irq` objects for the GIC, `Counter`s for cascaded controllers | kernel, `gpio` |
   | `iommus` | a `DmaDomain` | kernel |
   | a syscon phandle (`rockchip,grf`) | `registers=` fields from the board record | `registers` |
   | `phys` | a channel to the PHY driver's post | the PHY driver |

   Names are `consumer.label`, where the label comes from `clock-names`, `reset-names` and the like (`vop2.aclk`, `gpu.core`). Each provider publishes what it serves keyed by phandle and specifier, and `bus-dt` maps one to the other. **Order follows the references.** `devmgr` spawns a consumer only once every provider its grants name has posted. A dependency cycle is a record error, reported, never spawned around.

   **Board records** on DT machines are keyed by the root `compatible` (`xunlong,orangepi-5`), not by SMBIOS. They carry what the DT does not: register-field grants, firmware choices, and what a remote processor owns. They may correct the DT as they correct ACPI on the Q8B (01 §7.2), and every correction is listed.
3. **A `regulator` class** (`docs/proto/regulator.md`): `on` and `off` votes, and voltage ranges that the server satisfies with the lowest voltage inside every holder's range. Regulators the firmware left on are adopted, and `regulator-always-on` is never turned off. Regulator drivers sit on I²C and SPI.
4. **`clock` version 2** (`docs/proto/clock.md`):
   - arbitrary rates, with `query` for the nearest one the hardware can make;
   - mux selection (`parent`);
   - reset lines (`assert`, `deassert`);
   - power domains that depend on regulators. The clock server holds its own `regulator` votes for them, so the GPU's domain comes up only after `vdd_gpu_s0` does.
5. **A `registers` class** (`docs/proto/registers.md`) for register files that several drivers write, as Fuchsia's protocol does. Each client is granted named fields (offset and mask), the board record lists them, and overlapping grants are refused when the record loads. On Rockchip's write-masked registers, the server composes the write-enable half itself.
6. **`i2c` and `spi` bus classes.** Regulator, PMIC, USB-C controller (FUSB302) and RTC drivers are clients of a bus driver. A bus client's grant names its bus and address (`i2c=i2c0@0x42`), and the bus driver serves transfers to that address only. The specs come with their first users.
7. **CPU frequency through firmware and regulators** amends ADR-0020:
   - **Delegated domains.** A domain's level may be set by a user-space platform driver. The kernel writes the level it wants into a page shared with that driver and signals a `Counter`. The driver raises the regulator before raising the clock, and lowers the regulator after lowering the clock. It then writes back the level now in force, which the kernel's policy uses from then on. One request is outstanding at a time, and newer requests replace pending ones.
   - **SCMI.** Messages to the firmware become named operations in `svcd`'s platform service (01 §7.1), over SMC with the shared-memory carve-out the DT names.
   - **DT idle states.** The boot stage's `idle-states` items are a source for idle tables, beside `_LPI` and `_CST`.

   Fuchsia goes further and scales CPU frequency entirely in user space. We keep the policy in the kernel (ADR-0020's reasons) and delegate only the actuation.
8. **Switched domains for device MMUs.** A GPU such as the Mali-G610 has its own MMU, with no system IOMMU behind it, and its driver selects tables by writing address-space registers. So a switched domain's parent may be a **device-MMU domain**: a `DmaDomain` that `devmgr` creates from the record, in the device MMU's table format (AArch64 4K stage-1, with the device's memory-attribute indices), attached to no IOMMU. The kernel still builds every table, and ADR-0018 item 9's trust rule applies unchanged. Fuchsia's CSF driver builds its own tables instead. We keep kernel-built tables, for the reasons ADR-0019 §3 gives.
9. **NPUs speak `accel`.** An NPU's user-space driver runs in the client, as a GPU's does (Mesa's Rocket driver under the Teflon delegate), and needs a submit interface, not `ctl` files. So `drv-npu-*` serves `accel` (`docs/proto/accel.md`), and `/dev/accel/npuN/` keeps `info` and `status` for discovery. Loading a model and running it from a shell is `aid`'s job, under `/ai/models/` (02 §5.3, §5.6). Fuchsia drives VeriSilicon's NPU through Magma in the same way.

## Consequences

- The kernel image gains a DT reader that only the boot stage runs. The kernel proper sees the same items on ACPI and DT machines.
- `bus-dt` becomes the largest bus driver: a translator per reference kind, and the dependency order.
- Three class protocols are new (`regulator`, `registers`, and `i2c`/`spi` to come) and one is revised (`clock` v2). Each follows `clock`'s shape: 9Px files, one-line commands, connections that `devmgr` opens and limits.
- ADR-0020 gains delegated domains, SCMI and DT idle states. 01 §7.1 gains device-MMU domains.
- 02 §5.3's NPU `ctl` files move to `aid`. The remote-NPU example becomes a model's `clone` under `/ai/models/`.
- A DT SoC costs much more than a firmware-heavy one: the RK3588's first-party subset is perhaps 25–35k lines, against about 10k for the Q8B's GPU and platform pieces (ADR-0019). That figure is an estimate from Linux's sizes, not a measurement. This ADR is generic, so the CIX Sky1 or any later DT board reuses it whether or not the RK3588 stays in T1.
